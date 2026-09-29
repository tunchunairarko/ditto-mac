import Foundation
import AppKit

/// Port of the paste transforms in `COleClipSource` (OleClipSource.cpp) and the
/// options that select them (`CSpecialPasteOptions`).
///
/// Windows Ditto rewrites the CF_UNICODETEXT format in place and lets the other
/// formats through untouched; the same rule applies here. When a transform runs,
/// the clip is pasted as plain text, because a transformed string no longer
/// matches the RTF or HTML the clip was carrying.
enum SpecialPaste {

    enum Transform: String, CaseIterable {
        case none
        case upperCase
        case lowerCase
        case capitalize
        case sentenceCase
        case invertCase
        case camelCase
        case removeLineFeeds
        case addOneLineFeed
        case addTwoLineFeeds
        case trimWhiteSpace
        case typoglycemia
        case slugify
        case asciiOnly
        case posixifyPaths
        case addCurrentTime
        case generateGUID

        /// The menu title, matching `ActionEnums::EnumDescription`.
        var title: String {
            switch self {
            case .none: return "Paste"
            case .upperCase: return "Paste Upper Case"
            case .lowerCase: return "Paste Lower Case"
            case .capitalize: return "Paste Capitalized"
            case .sentenceCase: return "Paste Sentence Case"
            case .invertCase: return "Paste Inverted Case"
            case .camelCase: return "Paste Camel Case"
            case .removeLineFeeds: return "Paste Removing Line Feeds"
            case .addOneLineFeed: return "Paste Adding One Line Feed"
            case .addTwoLineFeeds: return "Paste Adding Two Line Feeds"
            case .trimWhiteSpace: return "Paste Trimming White Space"
            case .typoglycemia: return "Paste Typoglycemia"
            case .slugify: return "Paste Slugified"
            case .asciiOnly: return "Paste ASCII Only"
            case .posixifyPaths: return "Paste Posixified Paths"
            case .addCurrentTime: return "Paste Adding Current Time"
            case .generateGUID: return "Paste a New GUID"
            }
        }

        /// A transform rewrites the text, so the other formats have to go.
        var forcesPlainText: Bool {
            return self != .none
        }
    }

    /// Apply a transform to one string.
    static func apply(_ transform: Transform, to text: String) -> String {
        switch transform {
        case .none:
            return text
        case .upperCase:
            return text.uppercased()
        case .lowerCase:
            return text.lowercased()
        case .capitalize:
            return capitalize(text)
        case .sentenceCase:
            return sentenceCase(text)
        case .invertCase:
            return invertCase(text)
        case .camelCase:
            return camelCase(text)
        case .removeLineFeeds:
            return removeLineFeeds(text)
        case .addOneLineFeed:
            return addLineFeeds(text, count: 1)
        case .addTwoLineFeeds:
            return addLineFeeds(text, count: 2)
        case .trimWhiteSpace:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .typoglycemia:
            return typoglycemia(text)
        case .slugify:
            return slugify(text)
        case .asciiOnly:
            return asciiOnly(text)
        case .posixifyPaths:
            return posixifyPaths(text)
        case .addCurrentTime:
            return addCurrentTime(text)
        case .generateGUID:
            return UUID().uuidString
        }
    }

    // MARK: - The transforms

    /// `Capitalize` - lower case throughout, then a capital after every space.
    static func capitalize(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for character in text.lowercased() {
            if character == " " {
                result.append(character)
                capitalizeNext = true
            } else if capitalizeNext {
                result.append(contentsOf: String(character).uppercased())
                capitalizeNext = false
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// `SentenceCase` - lower case throughout, then a capital after `.`, `!`
    /// and `?`, and at the very start.
    static func sentenceCase(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for character in text.lowercased() {
            if character == "." || character == "!" || character == "?" {
                result.append(character)
                capitalizeNext = true
            } else if capitalizeNext && character != " " && character.isNewline == false {
                result.append(contentsOf: String(character).uppercased())
                capitalizeNext = false
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// `InvertCase` - swap the case of every letter.
    static func invertCase(_ text: String) -> String {
        var result = ""
        for character in text {
            if character.isUppercase {
                result.append(contentsOf: String(character).lowercased())
            } else if character.isLowercase {
                result.append(contentsOf: String(character).uppercased())
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// `CamelCase` - capital at the start of every word, everything else lower,
    /// spaces removed.
    static func camelCase(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for character in text {
            if character == " " {
                capitalizeNext = true
                continue
            }
            if capitalizeNext {
                result.append(contentsOf: String(character).uppercased())
                capitalizeNext = false
            } else {
                result.append(contentsOf: String(character).lowercased())
            }
        }
        return result
    }

    /// `RemoveLineFeeds` - join the lines back into one.
    static func removeLineFeeds(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    /// `AddLineFeeds` - append line feeds, so successive pastes stack up.
    static func addLineFeeds(_ text: String, count: Int) -> String {
        return text + String(repeating: "\n", count: max(0, count))
    }

    /// `Typoglycemia` - shuffle the middle letters of every word longer than
    /// three characters, leaving the first and last in place. Trailing
    /// sentence punctuation is left alone, as in Ditto.
    static func typoglycemia(_ text: String) -> String {
        let words = text.components(separatedBy: " ")
        var result: [String] = []
        result.reserveCapacity(words.count)

        for word in words {
            var characters = Array(word)

            // Ignore any trailing . ! ? when working out where the word ends.
            var end = characters.count
            while end > 0 {
                let character = characters[end - 1]
                if character == "." || character == "!" || character == "?" {
                    end -= 1
                } else {
                    break
                }
            }

            guard end > 3 else {
                result.append(word)
                continue
            }

            var middle = Array(characters[1..<(end - 1)])
            middle.shuffle()
            for (offset, character) in middle.enumerated() {
                characters[1 + offset] = character
            }
            result.append(String(characters))
        }

        return result.joined(separator: " ")
    }

    /// `AsciiOnly` - drop everything above U+007F.
    static func asciiOnly(_ text: String) -> String {
        return String(text.unicodeScalars.filter { $0.value <= 0x7F })
    }

    /// `PosixifyPaths` - `C:\foo\bar` becomes `/c/foo/bar`, backslashes become
    /// forward slashes. Handy when pasting a Windows path into a shell.
    static func posixifyPaths(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // ConvertDrivesWide: a leading drive letter turns into /<letter>.
        let pattern = "(?:^|(?<=[\\s\"']))([A-Za-z]):\\\\"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result,
                                                    options: [],
                                                    range: range,
                                                    withTemplate: "/$1/")
        }

        return result.replacingOccurrences(of: "\\", with: "/")
    }

    /// `AddDateTime` - stamp the current date and time after the text.
    static func addCurrentTime(_ text: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return text + " " + formatter.string(from: Date())
    }

    /// Port of `slugify` (Slugify.h) - transliterate, then reduce to a
    /// lowercase, hyphen-separated slug.
    static func slugify(_ text: String, separator: String = "-") -> String {
        // The Windows version carries its own transliteration table; on macOS
        // the same job is one string transform.
        var value = text
        if let folded = value.applyingTransform(.toLatin, reverse: false) {
            value = folded
        }
        if let stripped = value.applyingTransform(.stripDiacritics, reverse: false) {
            value = stripped
        }

        value = value.lowercased()
        value = value.replacingOccurrences(of: "&", with: " and ")

        var slug = ""
        var lastWasSeparator = true     // avoids a leading separator
        for scalar in value.unicodeScalars {
            let character = Character(scalar)
            if character.isLetter || character.isNumber {
                slug.append(character)
                lastWasSeparator = false
            } else if lastWasSeparator == false {
                slug += separator
                lastWasSeparator = true
            }
        }
        while slug.hasSuffix(separator) {
            slug.removeLast(separator.count)
        }
        return slug
    }

    // MARK: - Applying to a clip

    /// Build the formats to put on the pasteboard for a clip and a transform.
    static func formats(for clip: Clip,
                        transform: Transform,
                        plainTextOnly: Bool) -> [ClipFormatData] {
        guard transform != .none else {
            return clip.formats
        }

        guard let text = clip.text else {
            // Nothing to transform - GENERATE_GUID still has something to say.
            if transform == .generateGUID {
                let guid = apply(transform, to: "")
                return [ClipFormatData(ClipFormat.unicodeText, ClipFormat.encodeUnicodeText(guid)),
                        ClipFormatData(ClipFormat.text, ClipFormat.encodeText(guid))]
            }
            return clip.formats
        }

        let transformed = apply(transform, to: text)
        var formats = [
            ClipFormatData(ClipFormat.unicodeText, ClipFormat.encodeUnicodeText(transformed)),
            ClipFormatData(ClipFormat.text, ClipFormat.encodeText(transformed))
        ]

        // Keep the files, if any: the transforms only concern the text.
        if plainTextOnly == false, let drop = clip.format(ClipFormat.fileDrop) {
            formats.append(drop)
        }
        return formats
    }

    /// Concatenate several clips for a multi-paste, as
    /// `CClipIDs::AggregateData` does. `reverse` matches
    /// `GetMultiPasteReverse`.
    static func aggregateText(_ clips: [Clip],
                              separator: String,
                              reverse: Bool) -> String {
        let ordered = reverse ? clips.reversed().map { $0 } : clips
        let parts = ordered.compactMap { $0.text }
        return parts.joined(separator: separator)
    }
}
