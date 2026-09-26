import Foundation

/// Sorts copied text into a kind with fixed rules. No model is involved.
public enum ClipClassifier {
    public static func classify(_ text: String) -> (kind: ClipKind, language: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return (.text, nil) }
        let oneLine = !value.contains(where: \.isNewline)
        if oneLine {
            if ClipColor.parse(value) != nil { return (.color, nil) }
            if isLink(value) { return (.link, nil) }
            if matches(value, #"^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$"#) { return (.email, nil) }
            if isPhone(value) { return (.phone, nil) }
            if matches(value, #"^[£$€¥]?\s?-?[0-9][0-9.,\s]*%?$"#) { return (.number, nil) }
            if isJSON(value) { return (.code, "JSON") }
        }
        if let language = codeLanguage(value) { return (.code, language) }
        return (.text, nil)
    }

    public static func isLink(_ value: String) -> Bool {
        matches(value, #"^(https?://|www\.)\S+$"#)
    }

    /// Seven to fifteen digits with a leading + or at least one separator, so a plain number stays a number.
    static func isPhone(_ value: String) -> Bool {
        guard matches(value, #"^\+?\(?[0-9][0-9 ()\-.]{5,}[0-9]$"#) else { return false }
        let digits = value.filter(\.isNumber).count
        guard (7...15).contains(digits) else { return false }
        return value.hasPrefix("+") || value.contains(" ") || value.contains("-") || value.contains("(")
    }

    /// A label for multi-line text that looks like code, or nil.
    public static func codeLanguage(_ value: String) -> String? {
        let lines = value.split(whereSeparator: \.isNewline)
        guard lines.count >= 2 else { return nil }
        let rules: [(String, [String])] = [
            ("Swift", ["import SwiftUI", "import Foundation", "func ", "guard let ", "@MainActor", "struct "]),
            ("Python", ["def ", "import ", "elif ", "self.", "print("]),
            ("TypeScript", ["interface ", ": string", ": number", "export type ", "import type "]),
            ("JavaScript", ["function ", "const ", "=> ", "console.log", "require("]),
            ("Go", ["package main", "func main()", ":= ", "fmt."]),
            ("Rust", ["fn ", "let mut ", "impl ", "println!"]),
            ("PHP", ["<?php"]),
            ("C", ["#include", "int main("]),
            ("Java", ["public class ", "System.out", "public static void"]),
            ("SQL", ["SELECT ", "INSERT INTO ", "CREATE TABLE ", "UPDATE "]),
            ("HTML", ["<!DOCTYPE", "<html", "</div>", "<div"]),
            ("Shell", ["#!/bin/", "#!/usr/bin/env", "echo ", "export "]),
            ("CSS", ["{\n", "px;", "color:", "margin:"])
        ]
        var best: (String, Int)?
        for (name, markers) in rules {
            let hits = markers.filter { value.contains($0) }.count
            // Python and Shell words are common in prose, so they need two markers.
            let needed = ["Python", "Shell", "CSS", "Swift", "JavaScript", "Rust"].contains(name) ? 2 : 1
            if hits >= needed, hits > (best?.1 ?? 0) { best = (name, hits) }
        }
        if let best { return best.0 }
        if isJSON(value) { return "JSON" }
        // Code without a known language: most lines end with code punctuation or are indented.
        let codeLike = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(";") || trimmed.hasSuffix("{") || trimmed.hasSuffix("}") || trimmed.hasSuffix(")")
                || line.hasPrefix("    ") || line.hasPrefix("\t")
        }.count
        return codeLike * 2 > lines.count && value.range(of: #"[{};=()<>]"#, options: .regularExpression) != nil ? "Code" : nil
    }

    /// An object or array that parses as JSON.
    static func isJSON(_ value: String) -> Bool {
        guard let first = value.first, first == "{" || first == "[", value.count > 2, let data = value.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// A colour written as #hex, rgb(), or hsl().
public struct ClipColor: Equatable, Sendable {
    /// 0...1 components.
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public static func parse(_ text: String) -> ClipColor? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { return hex(String(value.dropFirst())) }
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let name = value[..<open].trimmingCharacters(in: .whitespaces)
        let inner = value[value.index(after: open)..<value.index(before: value.endIndex)]
        let parts = inner.replacingOccurrences(of: "/", with: " ").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func number(_ part: String) -> Double? { Double(part.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "deg", with: "")) }
        guard let values = Optional(parts.compactMap(number)), values.count == parts.count else { return nil }
        let alpha = values.count == 4 ? (parts[3].hasSuffix("%") ? values[3] / 100 : values[3]) : 1
        guard (0...1).contains(alpha) else { return nil }
        switch name {
        case "rgb", "rgba":
            let channels = (0..<3).map { parts[$0].hasSuffix("%") ? values[$0] / 100 : values[$0] / 255 }
            guard channels.allSatisfy({ (0...1).contains($0) }) else { return nil }
            return ClipColor(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
        case "hsl", "hsla":
            let s = values[1] / 100, l = values[2] / 100
            guard (0...1).contains(s), (0...1).contains(l) else { return nil }
            return fromHSL(h: values[0], s: s, l: l, alpha: alpha)
        default: return nil
        }
    }

    private static func hex(_ digits: String) -> ClipColor? {
        guard [3, 4, 6, 8].contains(digits.count), let raw = UInt64(digits, radix: 16) else { return nil }
        let short = digits.count <= 4
        let count = short ? digits.count : digits.count / 2
        var components: [Double] = []
        for index in 0..<count {
            let shift = UInt64((count - 1 - index) * (short ? 4 : 8))
            let part = (raw >> shift) & (short ? 0xF : 0xFF)
            components.append(short ? Double(part * 17) / 255 : Double(part) / 255)
        }
        return ClipColor(red: components[0], green: components[1], blue: components[2], alpha: components.count == 4 ? components[3] : 1)
    }

    static func fromHSL(h: Double, s: Double, l: Double, alpha: Double) -> ClipColor {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        guard s > 0 else { return ClipColor(red: l, green: l, blue: l, alpha: alpha) }
        return ClipColor(red: channel(hue + 1.0 / 3), green: channel(hue), blue: channel(hue - 1.0 / 3), alpha: alpha)
    }

    private func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }

    public var hexString: String {
        let base = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha < 1 ? base + String(format: "%02X", byte(alpha)) : base
    }
    public var rgbString: String {
        alpha < 1 ? "rgba(\(byte(red)), \(byte(green)), \(byte(blue)), \(Self.short(alpha)))" : "rgb(\(byte(red)), \(byte(green)), \(byte(blue)))"
    }
    public var hslString: String {
        let maxValue = max(red, green, blue), minValue = min(red, green, blue)
        let l = (maxValue + minValue) / 2
        var h = 0.0, s = 0.0
        let d = maxValue - minValue
        if d > 0 {
            s = l > 0.5 ? d / (2 - maxValue - minValue) : d / (maxValue + minValue)
            if maxValue == red { h = (green - blue) / d + (green < blue ? 6 : 0) }
            else if maxValue == green { h = (blue - red) / d + 2 }
            else { h = (red - green) / d + 4 }
            h *= 60
        }
        let body = "\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%"
        return alpha < 1 ? "hsla(\(body), \(Self.short(alpha)))" : "hsl(\(body))"
    }
    private static func short(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
