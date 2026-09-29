import Foundation

/// IMAP mailbox names in modified UTF-7 (RFC 3501 5.1.3): printable ASCII stays as is, "&" is
/// "&-", and other text is UTF-16 in base64 with "," for "/", between "&" and "-".
public enum ModifiedUTF7 {
    public static func encode(_ text: String) -> String {
        var result = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            for unit in pending { bytes.append(UInt8(unit >> 8)); bytes.append(UInt8(unit & 0xFF)) }
            let base64 = Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "")
            result += "&" + base64 + "-"
            pending = []
        }
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                flush()
                result += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending += Array(String(scalar).utf16)
            }
        }
        flush()
        return result
    }

    /// Decodes a name. Text that is not valid modified UTF-7 comes back unchanged.
    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&" else { result.append(character); index = text.index(after: index); continue }
            guard let end = text[index...].firstIndex(of: "-") else { return text }
            let encoded = text[text.index(after: index)..<end]
            if encoded.isEmpty {
                result.append("&")
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                while base64.count % 4 != 0 { base64 += "=" }
                guard let data = Data(base64Encoded: base64), data.count % 2 == 0 else { return text }
                let units = stride(from: 0, to: data.count, by: 2).map { UInt16(data[data.startIndex + $0]) << 8 | UInt16(data[data.startIndex + $0 + 1]) }
                result += String(decoding: units, as: UTF16.self)
            }
            index = text.index(after: end)
        }
        return result
    }
}
