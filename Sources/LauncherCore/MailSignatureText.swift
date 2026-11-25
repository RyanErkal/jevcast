import Foundation

/// A signature that Jevcast puts at the end of a draft's text, below a blank line. While the
/// signature is still there exactly as put in, it can be swapped for another account's or taken
/// out, and it does not count as text you typed. Once you change it, it is yours and stays.
public enum MailSignatureText {
    /// The blank line between your text and the signature.
    public static let separator = "\n\n"

    /// The signature as it goes in: without blank lines or spaces around it.
    public static func clean(_ signature: String) -> String {
        signature.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Your text without the signature and its blank line, or nil when the text does not end with
    /// exactly the blank line and `signature` that Jevcast put in. Words of your own that happen
    /// to end like the signature, such as "Please call Lee", are never taken for it.
    public static func typedPart(of body: String, signature: String) -> String? {
        let tail = separator + signature
        guard !signature.isEmpty, body.hasSuffix(tail) else { return nil }
        return String(body.dropLast(tail.count))
    }

    /// Your text with `signature` below it. An empty signature leaves the text as it is.
    public static func signed(_ typed: String, signature: String) -> String {
        signature.isEmpty ? typed : typed + separator + signature
    }

    /// Where the text cursor starts: at the end of your text, above the signature. UTF-16 units,
    /// as text views count. Nil when there is no intact signature.
    public static func cursor(in body: String, signature: String?) -> Int? {
        guard let signature, let typed = typedPart(of: body, signature: signature) else { return nil }
        return typed.utf16.count
    }
}
