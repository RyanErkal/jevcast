import Foundation

extension MIMEMessage: Codable {
    private struct Header: Codable { let name: String; let value: String }
    private enum CodingKeys: String, CodingKey { case headers, plainText, html, attachments, inlineImages }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headers = try container.decode([Header].self, forKey: .headers).map { ($0.name, $0.value) }
        plainText = try container.decodeIfPresent(String.self, forKey: .plainText)
        html = try container.decodeIfPresent(String.self, forKey: .html)
        attachments = try container.decode([Attachment].self, forKey: .attachments)
        inlineImages = try container.decode([String: InlineImage].self, forKey: .inlineImages)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(headers.map { Header(name: $0.name, value: $0.value) }, forKey: .headers)
        try container.encodeIfPresent(plainText, forKey: .plainText)
        try container.encodeIfPresent(html, forKey: .html)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(inlineImages, forKey: .inlineImages)
    }
}
