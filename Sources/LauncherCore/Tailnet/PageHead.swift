import Foundation

public enum HTMLTitle {
    /// The text of the first `<title>` in the start of a page, on one line.
    public static func find(in data: Data) -> String? {
        let text = PageHead.text(data)
        var searchFrom = text.startIndex
        while let open = text.range(of: "<title", options: .caseInsensitive, range: searchFrom..<text.endIndex) {
            searchFrom = open.upperBound
            // "<titlebar>" is another tag.
            guard open.upperBound < text.endIndex, text[open.upperBound] == ">" || text[open.upperBound].isWhitespace,
                  let close = text.range(of: ">", range: open.upperBound..<text.endIndex),
                  let end = text.range(of: "</title", options: .caseInsensitive, range: close.upperBound..<text.endIndex) else { continue }
            let title = PageHead.entities(String(text[close.upperBound..<end.lowerBound])).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return title.isEmpty ? nil : String(title.prefix(120))
        }
        return nil
    }
}

/// A page's site icon, from its `<link rel="icon">` tags.
public enum HTMLIcon {
    /// Icon references in page order, raster images before SVG, then "/favicon.ico".
    public static func candidates(in data: Data) -> [String] {
        var raster: [String] = [], vector: [String] = []
        for tag in PageHead.tags("link", in: PageHead.text(data)) {
            let rel = (tag["rel"] ?? "").lowercased()
            guard let href = tag["href"], !href.isEmpty, rel.split(separator: " ").contains(where: { $0 == "icon" || $0 == "apple-touch-icon" }) else { continue }
            let svg = href.lowercased().hasSuffix(".svg") || (tag["type"] ?? "").lowercased().contains("svg") || href.hasPrefix("data:image/svg")
            if svg { vector.append(href) } else { raster.append(href) }
        }
        let found = raster + vector
        return found.contains("/favicon.ico") ? found : found + ["/favicon.ico"]
    }

    /// The path to ask the page's own server for. Nil for another server, or for a `data:` icon.
    public static func path(_ href: String, hosts: Set<String>, port: Int, secure: Bool) -> String? {
        if href.hasPrefix("data:") { return nil }
        if href.hasPrefix("//") || href.contains("://") {
            guard let url = URL(string: href.hasPrefix("//") ? (secure ? "https:" : "http:") + href : href),
                  let host = url.host(percentEncoded: false), hosts.contains(host.lowercased()),
                  (url.port ?? (url.scheme == "https" ? 443 : 80)) == port else { return nil }
            let query = url.query(percentEncoded: true).map { "?" + $0 } ?? ""
            return (url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)) + query
        }
        guard !href.contains(" ") else { return nil }
        if href.hasPrefix("/") { return href }
        return "/" + (href.hasPrefix("./") ? String(href.dropFirst(2)) : href)
    }

    /// The bytes of a base64 `data:` icon.
    public static func inline(_ href: String) -> Data? {
        guard href.hasPrefix("data:image/"), let comma = href.firstIndex(of: ","), href[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(href[href.index(after: comma)...]).trimmingCharacters(in: .whitespaces))
    }
}

enum PageHead {
    /// The start of a page, where the head is.
    static func text(_ data: Data) -> String { String(decoding: data.prefix(65_536), as: UTF8.self) }

    static func entities(_ text: String) -> String {
        var text = text
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }

    /// The attributes of each `<name …>` tag, with lowercased names and entities read.
    static func tags(_ name: String, in text: String) -> [[String: String]] {
        var found: [[String: String]] = []
        var searchFrom = text.startIndex
        while let open = text.range(of: "<" + name, options: .caseInsensitive, range: searchFrom..<text.endIndex) {
            searchFrom = open.upperBound
            guard open.upperBound < text.endIndex, text[open.upperBound].isWhitespace,
                  let close = text.range(of: ">", range: open.upperBound..<text.endIndex) else { continue }
            found.append(attributes(String(text[open.upperBound..<close.lowerBound])))
            searchFrom = close.upperBound
        }
        return found
    }

    /// `rel="icon" href='/a.png' sizes=32x32` as a dictionary.
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var rest = Substring(text)
        while let equals = rest.firstIndex(of: "=") {
            let key = rest[..<equals].split(whereSeparator: { $0.isWhitespace || $0 == "/" }).last.map { $0.lowercased() } ?? ""
            var value = rest[rest.index(after: equals)...].drop { $0.isWhitespace }
            let quote = value.first
            if quote == "\"" || quote == "'" {
                value = value.dropFirst()
                let end = value.firstIndex(of: quote!) ?? value.endIndex
                if !key.isEmpty { result[key] = entities(String(value[..<end])) }
                rest = end < value.endIndex ? value[value.index(after: end)...] : ""
            } else {
                let end = value.firstIndex { $0.isWhitespace } ?? value.endIndex
                if !key.isEmpty { result[key] = entities(String(value[..<end])) }
                rest = value[end...]
            }
        }
        return result
    }
}
