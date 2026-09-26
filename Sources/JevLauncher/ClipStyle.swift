import AppKit
import LauncherCore
import SwiftUI

/// Labels, symbols, and measures for clipboard entries.
enum ClipStyle {
    static func symbol(_ entry: ClipEntry) -> String {
        switch entry.kind {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .link: return "link"
        case .email: return "envelope"
        case .phone: return "phone"
        case .color: return "paintpalette"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .number: return "number"
        case .image: return "photo"
        case .files:
            guard entry.files.count == 1, let file = entry.files.first else { return "doc.on.doc" }
            switch file.category {
            case .image: return "photo"
            case .video: return "film"
            case .audio: return "waveform"
            case .pdf: return "doc.richtext"
            case .folder: return "folder"
            case .document: return "doc.text"
            case .other: return "doc"
            }
        }
    }

    static func kindLabel(_ entry: ClipEntry) -> String {
        switch entry.kind {
        case .text: return "Text"
        case .richText: return "Rich Text"
        case .link: return "Link"
        case .email: return "Email Address"
        case .phone: return "Phone Number"
        case .color: return "Color"
        case .code: return entry.language.map { $0 == "Code" ? "Code" : "\($0) Code" } ?? "Code"
        case .number: return "Number"
        case .image: return "Image"
        case .files:
            guard entry.files.count == 1, let file = entry.files.first else { return "\(entry.files.count) Files" }
            switch file.category {
            case .image: return "Image File"
            case .video: return "Video"
            case .audio: return "Audio"
            case .pdf: return "PDF"
            case .folder: return "Folder"
            case .document: return "Document"
            case .other: return "File"
            }
        }
    }

    /// Size, dimensions, duration, or character count.
    static func measure(_ entry: ClipEntry) -> String? {
        switch entry.kind {
        case .image:
            guard let image = entry.image else { return nil }
            return "\(image.width) × \(image.height)"
        case .files:
            if entry.files.count > 1 { return "\(entry.files.count) files" }
            guard let file = entry.files.first else { return nil }
            if let duration = file.duration { return self.duration(duration) }
            return file.size.map(bytes)
        case .color, .link, .email, .phone, .number: return nil
        default:
            let count = entry.textLength
            return count == 1 ? "1 character" : "\(count.formatted()) characters"
        }
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func typeName(_ uti: String?) -> String? {
        guard let uti else { return nil }
        switch uti {
        case "public.png": return "PNG"
        case "public.jpeg": return "JPEG"
        case "public.heic": return "HEIC"
        case "public.tiff": return "TIFF"
        case "com.compuserve.gif": return "GIF"
        default: return UTType(uti)?.localizedDescription
        }
    }

    static func color(_ entry: ClipEntry) -> Color? {
        guard entry.kind == .color, let parsed = entry.text.flatMap(ClipColor.parse) else { return nil }
        return Color(.sRGB, red: parsed.red, green: parsed.green, blue: parsed.blue, opacity: parsed.alpha)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

import UniformTypeIdentifiers
