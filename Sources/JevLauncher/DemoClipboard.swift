import AppKit
import LauncherCore

/// Invented clipboard entries for `--snapshot-ui`. Images are drawn in code; files are the empty demo files.
@MainActor
enum DemoClipboard {
    static let imageID = UUID(uuidString: "00000000-0000-0000-0000-00000000C11A")!
    static let codeID = UUID(uuidString: "00000000-0000-0000-0000-00000000C11B")!

    static func entries(now: Date = Date()) -> [(ClipEntry, [String: Data])] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func text(_ value: String, _ minutes: Double, _ app: (String, String), id: UUID = UUID(), pinned: Bool = false) -> (ClipEntry, [String: Data]) {
            var made = ClipboardCapture.text(value, source: ClipSource(bundleID: app.0, name: app.1), now: ago(minutes))
            made.entry.id = id
            made.entry.pinned = pinned
            return (made.entry, made.blobs)
        }
        let notes = ("com.apple.Notes", "Notes"), safari = ("com.apple.Safari", "Safari"), xcode = ("com.apple.dt.Xcode", "Xcode")
        let mail = ("com.apple.mail", "Mail"), preview = ("com.apple.Preview", "Preview"), finder = ("com.apple.finder", "Finder")
        let code = """
        struct LaunchPlan: Codable {
            let name: String
            var milestones: [Milestone]

            func next(after date: Date) -> Milestone? {
                milestones
                    .filter { $0.due > date }
                    .min { $0.due < $1.due }
            }
        }
        """
        var list: [(ClipEntry, [String: Data])] = [
            text("Meeting moved to Thursday at 10:00\nRoom 4B, bring the printed agenda", 2, notes),
            text(code, 6, xcode, id: codeID),
            text("https://github.com/RyanErkal/jevcast", 11, safari, pinned: true),
            text("#5B8CFF", 18, safari),
            text("hello@example.com", 64, mail),
            text("£1,240.00", 95, notes),
            text("""
            {"team": "Design", "members": 6, "offsite": {"city": "Lisbon", "days": 3}}
            """, 180, safari)
        ]
        list.insert(image(at: ago(4), source: preview), at: 1)
        list.append(file("Downloads/Product demo.mov", category: .video, uti: "com.apple.quicktime-movie", size: 48_200_000,
                         duration: 94, thumb: poster(), at: ago(30), source: finder))
        list.append(file("Downloads/Quarterly report Q3.pdf", category: .pdf, uti: "com.adobe.pdf", size: 2_400_000,
                         duration: nil, thumb: pdfPage(), at: ago(140), source: finder))
        return list
    }

    private static func image(at date: Date, source: (String, String)) -> (ClipEntry, [String: Data]) {
        let data = draw(width: 1600, height: 1000) { context, size in
            let colors = [NSColor(srgbRed: 0.36, green: 0.55, blue: 1, alpha: 1).cgColor, NSColor(srgbRed: 0.78, green: 0.42, blue: 0.95, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            context.fillEllipse(in: CGRect(x: 980, y: 260, width: 420, height: 420))
            context.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            context.fill(CGRect(x: 180, y: 300, width: 620, height: 90))
            context.fill(CGRect(x: 180, y: 440, width: 460, height: 60))
            text("Launch Plan", at: CGPoint(x: 180, y: 620), size: 110, weight: .bold)
        }
        var made = ClipboardCapture.image(data, uti: "public.png", source: ClipSource(bundleID: source.0, name: source.1), now: date)!
        made.entry.id = imageID
        made.entry.ocrText = "Launch Plan"
        return (made.entry, made.blobs)
    }

    private static func file(_ relative: String, category: ClipFileCategory, uti: String, size: Int64, duration: Double?, thumb: Data,
                             at date: Date, source: (String, String)) -> (ClipEntry, [String: Data]) {
        let path = DemoData.home + "/" + relative
        let name = (relative as NSString).lastPathComponent
        let file = ClipFile(path: path, name: name, uti: uti, size: size, category: category, duration: duration)
        let entry = ClipEntry(hash: "f:" + path, kind: .files, copiedAt: date, text: path, files: [file], hasThumbnail: true,
                              sourceBundleID: source.0, sourceName: source.1, byteSize: Int64(thumb.count))
        return (entry, [ClipEntry.Blob.thumbnail: thumb])
    }

    private static func poster() -> Data {
        draw(width: 960, height: 540) { context, size in
            let colors = [NSColor(srgbRed: 0.08, green: 0.1, blue: 0.2, alpha: 1).cgColor, NSColor(srgbRed: 0.1, green: 0.35, blue: 0.45, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            context.setFillColor(NSColor(srgbRed: 1, green: 0.75, blue: 0.3, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: 640, y: 300, width: 140, height: 140))
            context.setFillColor(NSColor(srgbRed: 0.05, green: 0.2, blue: 0.25, alpha: 1).cgColor)
            context.move(to: CGPoint(x: 0, y: 0)); context.addLine(to: CGPoint(x: 320, y: 260)); context.addLine(to: CGPoint(x: 560, y: 120))
            context.addLine(to: CGPoint(x: 820, y: 300)); context.addLine(to: CGPoint(x: 960, y: 180)); context.addLine(to: CGPoint(x: 960, y: 0))
            context.fillPath()
            text("Product demo", at: CGPoint(x: 60, y: 440), size: 44, weight: .semibold)
        }
    }

    private static func pdfPage() -> Data {
        draw(width: 420, height: 560) { context, size in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            text("Quarterly report", at: CGPoint(x: 36, y: 480), size: 30, weight: .bold, color: .black)
            text("Q3 2026", at: CGPoint(x: 36, y: 446), size: 18, weight: .regular, color: .darkGray)
            context.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
            for line in 0..<9 { context.fill(CGRect(x: 36, y: 400 - line * 22, width: line % 3 == 2 ? 220 : 348, height: 8)) }
            let bars: [(CGFloat, NSColor)] = [(80, .systemBlue), (120, .systemTeal), (95, .systemBlue), (150, .systemIndigo)]
            for (index, bar) in bars.enumerated() {
                context.setFillColor(bar.1.cgColor)
                context.fill(CGRect(x: 60 + CGFloat(index) * 80, y: 40, width: 46, height: bar.0))
            }
        }
    }

    private static func text(_ value: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor = .white) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        NSAttributedString(string: value, attributes: attributes).draw(at: point)
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext, CGSize) -> Void) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        body(context.cgContext, CGSize(width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
