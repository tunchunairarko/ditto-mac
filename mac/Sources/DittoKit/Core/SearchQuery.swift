import Foundation

/// Port of `CFormatSQL` (FormatSQL.cpp) - turning what the user types in the
/// search box into a SQL `WHERE` clause.
///
/// Ditto's search language is kept as-is:
///   * words are ANDed together; `OR` and `AND` between them change that
///   * `NOT` or `!` before a word negates it
///   * `"a phrase"` keeps spaces together
///   * `*` is a wildcard
///   * a leading `/f ` searches the clip contents, `/q ` the quick paste text
/// Two option switches replace the parser: "simple" treats the whole box as one
/// literal phrase, "regex" hands it to a regular expression.
///
/// One difference from Windows: matching goes through the `ditto_like` and
/// `regexp` functions registered in `SQLiteDatabase`, not SQL's own `LIKE`.
/// Clip contents are stored as UTF-16 blobs (that is the Windows layout, and
/// this port keeps it), and SQL `LIKE` cannot see inside those - which is why
/// full text search is unreliable on Windows. The helper functions decode the
/// blob first, so `/f` searches actually work here.
struct SearchQuery {

    enum Scope {
        case description        // Main.mText
        case quickPaste         // Main.QuickPasteText
        case fullText           // Data.ooData
    }

    /// What the user typed, minus any `/f` or `/q` prefix.
    let text: String
    /// Which columns the prefix asked for, if any.
    let forcedScope: Scope?

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()

        if lowered.hasPrefix("/f ") || lowered.hasPrefix("\\f ") {
            text = String(trimmed.dropFirst(3))
            forcedScope = .fullText
        } else if lowered.hasPrefix("/q ") || lowered.hasPrefix("\\q ") {
            text = String(trimmed.dropFirst(3))
            forcedScope = .quickPaste
        } else {
            text = trimmed
            forcedScope = nil
        }
    }

    var isEmpty: Bool {
        return text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Which scopes this search covers, given the options and any prefix.
    var scopes: [Scope] {
        if let forced = forcedScope { return [forced] }

        let options = Options.shared
        var result: [Scope] = []
        if options.searchDescription { result.append(.description) }
        if options.searchQuickPaste { result.append(.quickPaste) }
        if options.searchFullText { result.append(.fullText) }
        // Ditto's rule: if nothing else is on, always search the description.
        if result.isEmpty { result = [.description] }
        return result
    }

    var needsDataJoin: Bool {
        return scopes.contains(.fullText)
    }

    /// A search that reaches into the Data table returns one row per matching
    /// format, so the query needs DISTINCT.
    var needsDistinct: Bool {
        return needsDataJoin
    }

    private static func column(for scope: Scope) -> String {
        switch scope {
        case .description: return "Main.mText"
        case .quickPaste: return "Main.QuickPasteText"
        case .fullText: return "Data.ooData"
        }
    }

    /// Escape a value for embedding in a SQL string literal, the way
    /// `CFormatSQL::Parse` does (`'` becomes `''`).
    static func escapeLiteral(_ value: String) -> String {
        return value.replacingOccurrences(of: "'", with: "''")
    }

    /// Escape the wildcard characters we do not want the user's text to mean.
    private static func escapeWildcards(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func caseFlag() -> String {
        return Options.shared.caseSensitiveSearch ? "1" : "0"
    }

    private func likeTest(_ column: String, _ word: String, negated: Bool) -> String {
        // The user's `*` is the wildcard; everything else is literal.
        var pattern = SearchQuery.escapeWildcards(word)
        pattern = pattern.replacingOccurrences(of: "*", with: "%")
        let literal = SearchQuery.escapeLiteral(pattern)
        let call = "ditto_like(\(column), '%\(literal)%', \(caseFlag()))"
        return negated ? "NOT \(call)" : call
    }

    /// Build the WHERE fragment for one scope.
    private func condition(for scope: Scope) -> String? {
        let column = SearchQuery.column(for: scope)
        let options = Options.shared
        var body = text
        guard body.isEmpty == false else { return nil }

        if options.regExTextSearch {
            return "ditto_regexp('\(SearchQuery.escapeLiteral(body))', \(column), \(caseFlag()))"
        }

        if options.simpleTextSearch {
            let pattern = SearchQuery.escapeWildcards(body)
            let literal = SearchQuery.escapeLiteral(pattern)
            return "ditto_like(\(column), '%\(literal)%', \(caseFlag()))"
        }

        // Ditto strips [ and ] before it starts tokenising.
        body = body
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")

        var clause = ""
        var current = ""
        var inQuotes = false
        var pendingNot = false
        var pendingJoin = "AND"

        func flush() {
            let word = current.trimmingCharacters(in: .whitespaces)
            current = ""
            guard word.isEmpty == false else { return }

            switch word.uppercased() {
            case "NOT", "!":
                pendingNot = true
                return
            case "OR":
                pendingJoin = "OR"
                return
            case "AND":
                pendingJoin = "AND"
                return
            default:
                break
            }

            let test = likeTest(column, word, negated: pendingNot)
            if clause.isEmpty {
                clause = test
            } else {
                clause += " \(pendingJoin) " + test
            }
            pendingNot = false
            pendingJoin = "AND"
        }

        for character in body {
            switch character {
            case "\"":
                inQuotes.toggle()
            case " ":
                if inQuotes {
                    current.append(character)
                } else {
                    flush()
                }
            default:
                current.append(character)
            }
        }
        flush()

        return clause.isEmpty ? nil : clause
    }

    /// The complete search filter, or nil when the box is empty.
    func whereClause() -> String? {
        guard isEmpty == false else { return nil }

        var parts: [String] = []
        for scope in scopes {
            guard var condition = condition(for: scope) else { continue }
            if scope == .fullText {
                // Only the text rows are worth decoding.
                condition = "(Data.strClipBoardFormat = '\(ClipFormat.unicodeText)' AND (\(condition)))"
            } else {
                condition = "(\(condition))"
            }
            parts.append(condition)
        }

        guard parts.isEmpty == false else { return nil }
        return "(" + parts.joined(separator: " OR ") + ")"
    }
}
