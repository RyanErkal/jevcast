import XCTest
@testable import JevLauncher

/// The list's selection colours against the list, by the WCAG 2 contrast formula. The list's own
/// colours are measured from the `mail-workspace-bulk` snapshots (#ECECEC light, #323232 dark),
/// the accents are the system blue of each appearance, and secondary text is the label colour
/// (85% black or white) at `MailListWash.selectedTextOpacity`.
final class MailListContrastTests: XCTestCase {
    private struct Look { let list: [Double]; let accent: [Double]; let label: [Double] }
    private let light = Look(list: [236, 236, 236], accent: [0, 122, 255], label: [0, 0, 0])
    private let dark = Look(list: [50, 50, 50], accent: [10, 132, 255], label: [255, 255, 255])

    private func luminance(_ rgb: [Double]) -> Double {
        let channel = rgb.map { value -> Double in
            let c = value / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel[0] + 0.7152 * channel[1] + 0.0722 * channel[2]
    }

    private func contrast(_ a: [Double], _ b: [Double]) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func over(_ top: [Double], _ alpha: Double, _ bottom: [Double]) -> [Double] {
        zip(top, bottom).map { $0 * alpha + $1 * (1 - alpha) }
    }

    func testSelectedRowsReadClearly() {
        for look in [light, dark] {
            for opacity in [MailListWash.focusedOpacity, MailListWash.memberOpacity] {
                let wash = over(look.accent, opacity, look.list)
                let text = over(look.label, 0.85 * MailListWash.selectedTextOpacity, wash)
                XCTAssertGreaterThanOrEqual(contrast(text, wash), 4.5, "Secondary text on a selected row")
            }
            // The other rows of a selection have a 1-point accent outline: a non-text contrast of 3:1 or more.
            XCTAssertGreaterThanOrEqual(contrast(look.accent, look.list), 3)
            XCTAssertGreaterThan(MailListWash.focusedOpacity, MailListWash.memberOpacity, "The message on screen stands out most")
        }
    }

    /// Unselected rows: sender, subject, and preview each read at 4.5:1 or more, in both
    /// appearances, with the preview quietest and read rows quieter than unread ones.
    func testUnselectedRowsReadClearly() {
        for look in [light, dark] {
            for opacity in [MailListWash.readSubject, MailListWash.unreadPreview, MailListWash.readPreview] {
                let text = over(look.label, 0.85 * opacity, look.list)
                XCTAssertGreaterThanOrEqual(contrast(text, look.list), 4.5, "Quiet text at \(opacity) on an unselected row")
            }
        }
        XCTAssertLessThan(MailListWash.readPreview, MailListWash.unreadPreview, "A read row is quieter")
        XCTAssertLessThan(MailListWash.unreadPreview, 1, "The preview is quieter than the subject of an unread row")
        XCTAssertLessThan(MailListWash.readPreview, MailListWash.readSubject, "The preview is quieter than the subject")
    }
}
