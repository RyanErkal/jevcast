import AppKit
import SwiftUI

/// Borderless key panel with a rounded glass surface (material before macOS 26). Height follows the
/// content's reported ideal height while the top edge stays anchored.
///
/// Non-activating: the panel becomes key and takes typing without the app
/// being granted activation, which macOS 14+ can refuse for a hotkey-driven
/// accessory app. The app is not activated when the panel opens.
final class LauncherPanel: NSPanel {
    static let width: CGFloat = 680
    static let cornerRadius = LauncherMetrics.panelRadius
    static let resizeDuration: TimeInterval = 0.12
    private let surface: PanelSurface

    /// `glass: false` keeps the pre-26 material, for snapshots: a view capture cannot draw glass vibrancy.
    init(glass: Bool = true) {
        surface = PanelSurface(glass: glass)
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = AppIdentity.name
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        isMovableByWindowBackground = false
        level = .popUpMenu; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false; isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        contentView = surface
    }
    /// False for snapshot runs, so an off-screen panel never takes the user's typing.
    var acceptsKey = true
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
    /// The SwiftUI content at its own ideal height, for snapshots.
    private(set) var hostedView: NSView?

    func host<Content: View>(_ view: Content) {
        let hosting = MeasuringHostingView(rootView: view)
        // SwiftUI reports its ideal height; the panel applies it so the top edge stays put.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onIdealHeight = { [weak self] height in self?.resize(toHeight: height) }
        // Intrinsic width must never drive the window narrower than the panel width.
        hosting.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let content = surface.content
        content.addSubview(hosting)
        hostedView = hosting
        // Top-pinned at its own ideal height, so content never floats while the frame catches up.
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: content.topAnchor)
        ])
    }
    /// Places the panel in the upper part of the screen holding the pointer.
    func place(on screen: NSScreen?) {
        guard let frame = screen?.visibleFrame else { return }
        setFrameTopLeftPoint(NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - max(40, frame.height * 0.12)))
    }
    private var pendingHeight: CGFloat = 0
    private var shownAt: CFTimeInterval = 0
    override func makeKeyAndOrderFront(_ sender: Any?) {
        if !isVisible { shownAt = CACurrentMediaTime() }
        super.makeKeyAndOrderFront(sender)
        refreshShadowSoon()
    }
    /// The shadow is taken from the drawn shape. A shadow taken before the glass drew is square, so
    /// it is taken again once the first frame is on screen.
    func refreshShadowSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.displayIfNeeded(); self?.invalidateShadow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self?.invalidateShadow() }
        }
    }
    override func orderFrontRegardless() {
        if !isVisible { shownAt = CACurrentMediaTime() }
        super.orderFrontRegardless()
    }
    /// Called from a layout pass, so the frame change waits for the next turn.
    /// A visible panel eases to the new height unless Reduce Motion is on. The
    /// top edge stays put: origin and height share one timing curve, so maxY is
    /// constant even when a new height arrives mid-animation.
    func resize(toHeight height: CGFloat) {
        let rounded = ceil(height)
        guard rounded > 0, rounded != pendingHeight else { return }
        pendingHeight = rounded
        DispatchQueue.main.async { [weak self] in
            // A newer height from the same layout burst replaces this one.
            guard let self, self.pendingHeight == rounded else { return }
            var next = self.frame
            next.origin.y = self.frame.maxY - rounded
            next.size.height = rounded
            // The first layout after opening applies at once; later changes animate.
            let settled = CACurrentMediaTime() - self.shownAt > 0.2
            if self.isVisible && settled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.resizeDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.animator().setFrame(next, display: true)
                } completionHandler: { [weak self] in self?.refreshShadowSoon() }
            } else {
                self.setFrame(next, display: true, animate: false)
                self.refreshShadowSoon()
            }
            if CommandLine.arguments.contains("--trace-interaction") {
                print("[Jev interaction] resized size=\(Int(next.width))x\(Int(next.height))"); fflush(stdout)
            }
        }
    }
}

/// Reports the SwiftUI ideal height after each layout so the panel can follow it.
private final class MeasuringHostingView<Content: View>: NSHostingView<Content> {
    var onIdealHeight: ((CGFloat) -> Void)?
    override func layout() {
        super.layout()
        onIdealHeight?(intrinsicContentSize.height)
    }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIdealHeight?(intrinsicContentSize.height)
    }
}

/// The panel background: Liquid Glass on macOS 26, the popover material on
/// macOS 14 and 15. A 0.5pt hairline sits above it; Increase Contrast draws
/// the hairline at full strength. `content` holds the SwiftUI view.
private final class PanelSurface: NSView {
    let content = NSView()
    private let border = NSView()
    private var contrastObserver: NSObjectProtocol?

    init(glass: Bool) {
        super.init(frame: .zero)
        let background: NSView
        if #available(macOS 26, *), glass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = LauncherMetrics.panelRadius
            glass.contentView = content
            // Pinned so the content always fills the glass, whatever the glass does with its frame.
            content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                content.topAnchor.constraint(equalTo: glass.topAnchor),
                content.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
            ])
            background = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = LauncherMetrics.panelRadius
            material.layer?.cornerCurve = .continuous
            material.layer?.masksToBounds = true
            fill(material, with: content)
            background = material
        }
        // Content clips to the same continuous corners as the surface.
        content.wantsLayer = true
        content.layer?.cornerRadius = LauncherMetrics.panelRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        border.wantsLayer = true
        border.layer?.cornerRadius = LauncherMetrics.panelRadius
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = LauncherMetrics.panelBorderWidth
        fill(self, with: background)
        fill(self, with: border)
        // The whole surface clips to the rounded shape, so nothing square is ever drawn. The window
        // shadow, and its light rim in Dark Mode, follow what is drawn, so they stay rounded too.
        wantsLayer = true
        layer?.cornerRadius = LauncherMetrics.panelRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func fill(_ parent: NSView, with child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }
    /// The hairline never takes clicks meant for the content below it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === border ? nil : hit
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard contrastObserver == nil else { return }
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateBorder() } }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }
    func updateBorder() {
        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
        // Resolve the dynamic colour in this view's appearance before taking its CGColor.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            border.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(alpha).cgColor
        }
    }
}
