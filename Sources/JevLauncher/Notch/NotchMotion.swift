import SwiftUI

/// Timing for the island. Out of the notch, width leads height; back into it, height leads width.
/// Springs are near critically damped, so the shape settles without a visible bounce and retargets smoothly.
enum NotchMotion {
    struct Spring: Equatable {
        let response: Double
        let damping: Double

        var animation: Animation { .spring(response: response, dampingFraction: damping, blendDuration: 0) }

        /// Peak overshoot as a fraction of the distance travelled. Zero at or above critical damping.
        var overshoot: Double {
            guard damping < 1 else { return 0 }
            return exp(-damping * .pi / (1 - damping * damping).squareRoot())
        }
    }

    static let growWidth = Spring(response: 0.45, damping: 0.88)
    static let growHeight = Spring(response: 0.5, damping: 0.9)
    static let retractWidth = Spring(response: 0.38, damping: 0.9)
    static let retractHeight = Spring(response: 0.34, damping: 0.92)

    /// Content waits until the shape is mostly open, then fades in, slides down, and sharpens.
    static let contentDelay: Double = 0.12
    static let contentIn: Double = 0.24
    /// Content fades out before the shape retracts.
    static let contentOut: Double = 0.12
    static let contentSlide: CGFloat = 5
    static let contentBlur: CGFloat = 3
    /// With Reduce Motion the island only cross-fades.
    static let reduceMotionFade: Double = 0.18

    static func width(closing: Bool, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : (closing ? retractWidth : growWidth).animation
    }

    static func height(closing: Bool, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : (closing ? retractHeight : growHeight).animation
    }

    /// The slower spring of a pair. Its completion means the whole shape has settled.
    static func slower(_ a: Spring, _ b: Spring) -> Spring { a.response >= b.response ? a : b }

    /// The transaction the controller waits on for a shape change.
    static func settle(closing: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: reduceMotionFade) }
        return closing ? slower(retractWidth, retractHeight).animation : slower(growWidth, growHeight).animation
    }

    static func contentHide(reduceMotion: Bool) -> Animation {
        .easeIn(duration: reduceMotion ? reduceMotionFade : contentOut)
    }

    static func contentTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: reduceMotionFade)) }
        return .asymmetric(
            insertion: .modifier(active: ContentReveal(hidden: true), identity: ContentReveal(hidden: false))
                .animation(.easeOut(duration: contentIn).delay(contentDelay)),
            removal: .opacity.animation(.easeIn(duration: contentOut)))
    }
}

/// Content arriving: transparent, a few points high, slightly soft.
struct ContentReveal: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? -NotchMotion.contentSlide : 0)
            .blur(radius: hidden ? NotchMotion.contentBlur : 0)
    }
}

/// Makes the completions of a close stale once something else takes over the panel.
struct NotchCloseSequence {
    private(set) var token = 0
    private(set) var active = false

    mutating func begin() -> Int { token += 1; active = true; return token }
    mutating func cancel() { token += 1; active = false }
    func isCurrent(_ value: Int) -> Bool { active && value == token }
    /// True once, for the current close.
    mutating func finish(_ value: Int) -> Bool {
        guard isCurrent(value) else { return false }
        active = false
        return true
    }
}
