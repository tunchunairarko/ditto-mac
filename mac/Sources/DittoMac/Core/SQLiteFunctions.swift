import Foundation
import SQLite3

/// Custom SQL functions used by the search.
///
/// `Data.ooData` holds the Windows byte layout - CF_UNICODETEXT is UTF-16 with
/// a NUL terminator - so SQL's own `LIKE` cannot see the characters inside it.
/// These functions decode the value first, which is what makes `/f` (search
/// clip contents) reliable here.
/// `SQLITE_UTF8 | SQLITE_DETERMINISTIC`, spelled out so the code does not
/// depend on the macro being imported by the SQLite3 module.
private let dittoFunctionFlags: Int32 = SQLITE_UTF8 | 0x800

extension SQLiteDatabase {

    func registerSearchFunctions() {
        sync {
            guard let handle = rawHandle else { return }

            // ditto_like(value, pattern, caseSensitive) -> 0 or 1
            sqlite3_create_function_v2(
                handle, "ditto_like", 3,
                dittoFunctionFlags, nil,
                { context, argc, argv in
                    guard argc == 3, let argv = argv else {
                        sqlite3_result_int(context, 0)
                        return
                    }
                    guard let subject = dittoDecodeValue(argv[0]),
                          let pattern = dittoDecodeValue(argv[1]) else {
                        sqlite3_result_int(context, 0)
                        return
                    }
                    let caseSensitive = sqlite3_value_int(argv[2]) != 0
                    let matched = DittoPatternMatcher.matches(subject: subject,
                                                              pattern: pattern,
                                                              caseSensitive: caseSensitive)
                    sqlite3_result_int(context, matched ? 1 : 0)
                },
                nil, nil, nil)

            // ditto_regexp(pattern, value, caseSensitive) -> 0 or 1
            sqlite3_create_function_v2(
                handle, "ditto_regexp", 3,
                dittoFunctionFlags, nil,
                { context, argc, argv in
                    guard argc == 3, let argv = argv else {
                        sqlite3_result_int(context, 0)
                        return
                    }
                    guard let pattern = dittoDecodeValue(argv[0]),
                          let subject = dittoDecodeValue(argv[1]) else {
                        sqlite3_result_int(context, 0)
                        return
                    }
                    let caseSensitive = sqlite3_value_int(argv[2]) != 0
                    let matched = DittoPatternMatcher.matchesRegex(subject: subject,
                                                                   pattern: pattern,
                                                                   caseSensitive: caseSensitive)
                    sqlite3_result_int(context, matched ? 1 : 0)
                },
                nil, nil, nil)

            // REGEXP, so `column REGEXP 'pattern'` also works in ad hoc queries.
            sqlite3_create_function_v2(
                handle, "regexp", 2,
                dittoFunctionFlags, nil,
                { context, argc, argv in
                    guard argc == 2, let argv = argv,
                          let pattern = dittoDecodeValue(argv[0]),
                          let subject = dittoDecodeValue(argv[1]) else {
                        sqlite3_result_int(context, 0)
                        return
                    }
                    let matched = DittoPatternMatcher.matchesRegex(subject: subject,
                                                                   pattern: pattern,
                                                                   caseSensitive: false)
                    sqlite3_result_int(context, matched ? 1 : 0)
                },
                nil, nil, nil)
        }
    }
}

/// Turn a sqlite value into a Swift string, decoding the UTF-16 blobs Ditto
/// writes for text formats.
private func dittoDecodeValue(_ value: OpaquePointer?) -> String? {
    guard let value = value else { return nil }

    switch sqlite3_value_type(value) {
    case SQLITE_NULL:
        return nil

    case SQLITE_TEXT:
        guard let raw = sqlite3_value_text(value) else { return nil }
        return String(cString: raw)

    case SQLITE_BLOB:
        let length = Int(sqlite3_value_bytes(value))
        guard length > 0, let raw = sqlite3_value_blob(value) else { return "" }
        let data = Data(bytes: raw, count: length)
        return DittoPatternMatcher.decodeBlob(data)

    case SQLITE_INTEGER:
        return String(sqlite3_value_int64(value))

    case SQLITE_FLOAT:
        return String(sqlite3_value_double(value))

    default:
        return nil
    }
}

/// The matching itself, plus a small cache so a search that touches thousands
/// of rows compiles each pattern once.
enum DittoPatternMatcher {

    private static let lock = NSLock()
    private static var regexCache: [String: NSRegularExpression] = [:]

    /// Blobs are usually CF_UNICODETEXT (UTF-16 little endian). Fall back to
    /// UTF-8 and then to Latin-1 so nothing is ever unsearchable.
    static func decodeBlob(_ data: Data) -> String {
        // A UTF-16 buffer of mostly-ASCII text has a NUL in every other byte.
        if data.count >= 4 {
            let sampleCount = min(data.count, 64)
            var oddNulls = 0
            var index = 1
            while index < sampleCount {
                if data[data.startIndex + index] == 0 { oddNulls += 1 }
                index += 2
            }
            if oddNulls > sampleCount / 4 {
                return ClipFormat.decodeUnicodeText(data)
            }
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(decoding: data, as: UTF8.self)
    }

    /// SQL `LIKE` semantics: `%` is any run of characters, `_` any one
    /// character, `\` escapes either of them.
    static func matches(subject: String, pattern: String, caseSensitive: Bool) -> Bool {
        // The overwhelmingly common shape is `%needle%`, which a plain
        // substring search answers far more cheaply than a regex.
        if let needle = plainContainsNeedle(pattern) {
            if needle.isEmpty { return true }
            let options: String.CompareOptions = caseSensitive
                ? []
                : [.caseInsensitive, .diacriticInsensitive]
            return subject.range(of: needle, options: options) != nil
        }

        let regexPattern = "^" + likePatternToRegex(pattern) + "$"
        return matchesRegex(subject: subject,
                            pattern: regexPattern,
                            caseSensitive: caseSensitive,
                            anchored: true)
    }

    /// Return the literal inside a `%literal%` pattern, or nil if the pattern
    /// has wildcards of its own.
    private static func plainContainsNeedle(_ pattern: String) -> String? {
        guard pattern.hasPrefix("%"), pattern.hasSuffix("%"), pattern.count >= 2 else {
            return nil
        }
        let body = String(pattern.dropFirst().dropLast())

        var literal = ""
        var escaped = false
        for character in body {
            if escaped {
                literal.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "%", "_":
                return nil          // a real wildcard - fall back to the regex
            default:
                literal.append(character)
            }
        }
        return literal
    }

    private static func likePatternToRegex(_ pattern: String) -> String {
        var result = ""
        var escaped = false
        for character in pattern {
            if escaped {
                result += NSRegularExpression.escapedPattern(for: String(character))
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "%":
                result += "[\\s\\S]*"
            case "_":
                result += "[\\s\\S]"
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        if escaped { result += "\\\\" }
        return result
    }

    static func matchesRegex(subject: String,
                             pattern: String,
                             caseSensitive: Bool,
                             anchored: Bool = false) -> Bool {
        guard let regex = compile(pattern, caseSensitive: caseSensitive) else { return false }
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        return regex.firstMatch(in: subject, options: [], range: range) != nil
    }

    private static func compile(_ pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        let key = (caseSensitive ? "s:" : "i:") + pattern

        lock.lock()
        if let cached = regexCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if caseSensitive == false { options.insert(.caseInsensitive) }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }

        lock.lock()
        if regexCache.count > 128 { regexCache.removeAll() }
        regexCache[key] = regex
        lock.unlock()
        return regex
    }
}
