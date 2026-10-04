import Foundation

/// Completed ordinary contacts, never an override of secret content or focus policy.
/// Deliberately narrow: formatted North American numbers; other numeric strings stay ambiguous.
public enum ContactShape {
    public static func email(_ value: String) -> Bool {
        guard value.utf8.count <= 254, value.unicodeScalars.allSatisfy({ $0.isASCII }),
              !value.contains(where: \.isWhitespace) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = String(parts[0]), domain = String(parts[1])
        guard !local.isEmpty, local.utf8.count <= 64, !local.hasPrefix("."), !local.hasSuffix("."),
              !local.contains(".."),
              local.range(of: #"^[A-Za-z0-9!#$%&'*+/=?^_\x60{|}~.-]+$"#, options: .regularExpression) != nil else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let top = labels.last, (2...63).contains(top.count),
              top.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
    public static func phone(_ value: String) -> Bool {
        value.trimmingCharacters(in:CharacterSet(charactersIn:"\"'[]{}<>.,;:!?")).range(of: #"^(?:\+1[ -]?)?(?:\([2-9][0-9]{2}\)[ ]?[2-9][0-9]{2}[- ][0-9]{4}|[2-9][0-9]{2}[-. ][2-9][0-9]{2}[-. ][0-9]{4})$"#, options: .regularExpression) != nil
    }
    /// Sentence punctuation may surround contacts; a leading local-part dot must not be trimmed into validity.
    static func tokenEmail(_ raw: String) -> Bool {
        let outer = CharacterSet(charactersIn: "\"'()[]{}<>,;:!?\u{201C}\u{201D}\u{2018}\u{2019}")
        let token = raw.trimmingCharacters(in: outer)
        guard !token.hasPrefix(".") else { return false }
        return email(token) || (token.hasSuffix(".") && email(String(token.dropLast())))
    }
}
