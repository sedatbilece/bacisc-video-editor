import Foundation

/// A term to keep as written in transcripts, with the spellings a model hears it as.
struct GlossaryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Written form, e.g. "buffer"; sent to the model as a keyterm.
    var term = ""
    /// Comma-separated heard spellings, e.g. "bafır, bufır"; replaced by `term` after transcription.
    var heardAs = ""

    var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    var variants: [String] {
        heardAs.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Applies a glossary to transcripts: keyterms for the request, variant replacement for the result.
struct Glossary {
    private struct Rule {
        let regex: NSRegularExpression
        let term: String
    }

    private static let turkish = Locale(identifier: "tr")

    /// Unique written forms within OpenRouter's limits (1–100 characters, at most 1000).
    let keyterms: [String]
    private let rules: [Rule]

    init(_ entries: [GlossaryEntry]) {
        var seen = Set<String>()
        keyterms = Array(entries.map(\.trimmedTerm)
            .filter { !$0.isEmpty && $0.count <= 100 && seen.insert($0.lowercased(with: Self.turkish)).inserted }
            .prefix(1000))

        // Longer variants first, so "bafır ayarı" wins over "bafır".
        rules = entries
            .filter { !$0.trimmedTerm.isEmpty }
            .flatMap { entry in entry.variants.map { (variant: $0, term: entry.trimmedTerm) } }
            .sorted { $0.variant.count > $1.variant.count }
            .compactMap { item in
                // A variant matches at the start of a word; trailing letters are a suffix.
                let pattern = "(?<![\\p{L}\\p{N}])" + Self.caseInsensitivePattern(item.variant) + "(\\p{L}*)"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
                return Rule(regex: regex, term: item.term)
            }
    }

    var isEmpty: Bool { keyterms.isEmpty }

    /// "bafır" → "buffer", "bafırda" → "buffer'da"; a capitalized match capitalizes an all-lowercase term.
    func apply(to text: String) -> String {
        rules.reduce(text) { text, rule in
            let source = text as NSString
            var result = ""
            var location = 0
            for match in rule.regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: location, length: match.range.location - location))
                let matched = source.substring(with: match.range)
                let suffix = source.substring(with: match.range(at: 1))
                var term = rule.term
                if let first = matched.first, first.isUppercase, term == term.lowercased(with: Self.turkish) {
                    term = term.prefix(1).uppercased(with: Self.turkish) + term.dropFirst()
                }
                result += suffix.isEmpty ? term : "\(term)'\(suffix)"
                location = match.range.location + match.range.length
            }
            return result + source.substring(from: location)
        }
    }

    /// Each letter matches its Turkish and default upper/lowercase forms (ı/I, i/İ); spaces match any whitespace.
    private static func caseInsensitivePattern(_ variant: String) -> String {
        var pattern = ""
        var lastWasSpace = false
        for character in variant {
            if character.isWhitespace {
                if !lastWasSpace { pattern += "\\s+" }
                lastWasSpace = true
                continue
            }
            lastWasSpace = false
            let text = String(character)
            let forms = [text, text.lowercased(with: turkish), text.uppercased(with: turkish), text.lowercased(), text.uppercased()]
            var unique: [String] = []
            for form in forms where form.count == 1 && !unique.contains(form) { unique.append(form) }
            let escaped = unique.map { NSRegularExpression.escapedPattern(for: $0) }
            pattern += escaped.count == 1 ? escaped[0] : "(?:" + escaped.joined(separator: "|") + ")"
        }
        return pattern
    }
}
