import AVFoundation
import AppKit
import CryptoKit
import ImageIO
import LauncherCore
import QuickLookThumbnailing
import UniformTypeIdentifiers
import Vision

/// Turns one pasteboard read into an entry and its blobs. Runs on the clipboard worker, never the main thread.
enum ClipboardCapture {
    struct Made {
        var entry: ClipEntry
        var blobs: [String: Data]
    }
    enum Outcome {
        case made(Made)
        case skipped(String)
    }

    /// Images at or under this size keep their original bytes; larger ones are re-encoded.
    static let keepOriginalBytes = 2_000_000
    static let thumbnailPixels = 512

    static func make(_ raw: ClipRaw, source: ClipSource?, settings: ClipboardSettings, now: Date) async -> Outcome {
        if !raw.fileURLs.isEmpty {
            guard settings.recordFiles else { return .skipped("files off") }
            return .made(await files(raw.fileURLs, source: source, now: now))
        }
        let text = raw.string ?? raw.url
        let hasText = !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let imageFirst = raw.types.first.map { ClipRaw.imageTypes.contains($0) } ?? false
        if raw.imageTooLarge, !hasText || imageFirst { return .skipped("image too large") }
        if let image = raw.image, !hasText || imageFirst {
            guard settings.recordImages else { return .skipped("images off") }
            guard image.data.count <= ClipboardSettings.maxImageBytes else { return .skipped("image too large") }
            if let made = self.image(image.data, uti: image.uti, source: source, now: now) { return .made(made) }
        }
        guard let text, hasText else { return .skipped("empty") }
        guard settings.recordText else { return .skipped("text off") }
        guard text.utf8.count <= ClipboardSettings.maxTextBytes else { return .skipped("text too large") }
        guard (raw.rtf?.count ?? 0) <= ClipboardSettings.maxTextBytes,
              (raw.html?.count ?? 0) <= ClipboardSettings.maxTextBytes else { return .skipped("formatting too large") }
        let rich = settings.recordRichText
        return .made(self.text(text, rtf: rich ? raw.rtf : nil, html: rich ? raw.html : nil, source: source, now: now))
    }

    // MARK: Text

    static func text(_ text: String, rtf: Data? = nil, html: Data? = nil, source: ClipSource?, now: Date) -> Made {
        var (kind, language) = ClipClassifier.classify(text)
        if kind == .text, rtf != nil || html != nil { kind = .richText }
        var blobs: [String: Data] = [:]
        if let rtf { blobs[ClipEntry.Blob.rtf] = rtf }
        if let html { blobs[ClipEntry.Blob.html] = html }
        let long = text.count > ClipEntry.indexTextLimit
        if long { blobs[ClipEntry.Blob.text] = Data(text.utf8) }
        let size = Int64(long ? 0 : text.utf8.count) + blobs.values.reduce(0) { $0 + Int64($1.count) }
        let fingerprint = sha(Data(text.utf8)) + ":" + (rtf.map(sha) ?? "") + ":" + (html.map(sha) ?? "")
        let entry = ClipEntry(hash: "t:" + sha(Data(fingerprint.utf8)), kind: kind, copiedAt: now,
                              text: long ? String(text.prefix(ClipEntry.indexTextLimit)) : text, textLength: text.count,
                              textInBlob: long, language: language, hasRTF: rtf != nil, hasHTML: html != nil,
                              sourceBundleID: source?.bundleID, sourceName: source?.name, byteSize: size)
        return Made(entry: entry, blobs: blobs)
    }

    // MARK: Images

    static func image(_ data: Data, uti: String, source: ClipSource?, now: Date) -> Made? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // A small compressed file can still expand to gigabytes during encoding.
        guard width > 0, height > 0, width <= 64_000_000 / height else { return nil }
        var stored = data, storedType = uti
        let keep = uti == UTType.gif.identifier || (data.count <= keepOriginalBytes && uti != UTType.tiff.identifier)
        if !keep, let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
            if let heic = encode(image, as: UTType.heic.identifier, quality: 0.85), heic.count < data.count {
                stored = heic; storedType = UTType.heic.identifier
            } else if let png = encode(image, as: UTType.png.identifier), png.count < data.count {
                stored = png; storedType = UTType.png.identifier
            }
        }
        var blobs = [ClipEntry.Blob.image: stored]
        if let thumb = thumbnail(imageSource) { blobs[ClipEntry.Blob.thumbnail] = thumb }
        let info = ClipImageInfo(width: width, height: height, uti: storedType, byteSize: stored.count)
        let entry = ClipEntry(hash: "i:" + sha(data), kind: .image, copiedAt: now, image: info, hasThumbnail: blobs[ClipEntry.Blob.thumbnail] != nil,
                              sourceBundleID: source?.bundleID, sourceName: source?.name,
                              byteSize: blobs.values.reduce(0) { $0 + Int64($1.count) })
        return Made(entry: entry, blobs: blobs)
    }

    static func thumbnail(_ source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(thumb, as: UTType.png.identifier)
    }

    static func encode(_ image: CGImage, as uti: String, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, uti as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Any stored image as PNG, for Save Image and for apps that cannot read HEIC.
    static func png(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return encode(image, as: UTType.png.identifier)
    }

    /// A decoded image no wider or taller than `maxPixels`, for previews.
    static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Files

    static func files(_ urls: [URL], source: ClipSource?, now: Date) async -> Made {
        var files: [ClipFile] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            let category = self.category(type, isDirectory: values?.isDirectory ?? false)
            var file = ClipFile(path: url.path, name: url.lastPathComponent,
                                bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                                uti: type?.identifier, size: values?.fileSize.map(Int64.init), category: category)
            if category == .video || category == .audio { file.duration = await duration(of: url) }
            files.append(file)
        }
        var blobs: [String: Data] = [:]
        if let first = files.first(where: { [.image, .video, .pdf].contains($0.category) }),
           let thumb = await quickLookThumbnail(URL(fileURLWithPath: first.path)) {
            blobs[ClipEntry.Blob.thumbnail] = thumb
        }
        let paths = files.map(\.path).joined(separator: "\n")
        let entry = ClipEntry(hash: "f:" + sha(Data(paths.utf8)), kind: .files, copiedAt: now, text: paths, files: files,
                              hasThumbnail: !blobs.isEmpty, sourceBundleID: source?.bundleID, sourceName: source?.name,
                              byteSize: Int64(paths.utf8.count) + blobs.values.reduce(0) { $0 + Int64($1.count) })
        return Made(entry: entry, blobs: blobs)
    }

    static func category(_ type: UTType?, isDirectory: Bool) -> ClipFileCategory {
        guard let type else { return isDirectory ? .folder : .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .package) && type.conforms(to: .application) { return .other }
        if isDirectory || type.conforms(to: .folder) || type.conforms(to: .directory) { return .folder }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .presentation) || type.conforms(to: .content) { return .document }
        return .other
    }

    static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration), time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    static func quickLookThumbnail(_ url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 256, height: 256), scale: 2, representationTypes: .thumbnail)
        guard let thumb = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        return encode(thumb.cgImage, as: UTType.png.identifier)
    }

    // MARK: Text in images

    /// Text Vision finds in an image, on this Mac. Nil when there is none.
    static func recognizeText(in data: Data) -> String? {
        guard let image = decode(data, maxPixels: 4096) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
