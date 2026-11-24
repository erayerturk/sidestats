import AppKit
import SwiftUI

final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the right-edge panel: reveals it when the pointer rests on the screen's right edge,
/// hides it when the pointer leaves (unless pinned).
@MainActor
final class EdgePanelController: ObservableObject {
    static let width: CGFloat = 360
    private let margin: CGFloat = 8

    @Published private(set) var isVisible = false
    @Published var isPinned = UserDefaults.standard.bool(forKey: "pinned") {
        didSet { UserDefaults.standard.set(isPinned, forKey: "pinned") }
    }

    let panel: SidebarPanel
    private let store: MetricsStore
    private var monitors: [Any] = []
    private var edgeSince: Date?
    private var outsideSince: Date?
    private var currentScreen: NSScreen?

    init(store: MetricsStore, widgets: WidgetStore, openSettings: @escaping (SettingsTab) -> Void) {
        self.store = store
        panel = SidebarPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                             styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let root = SidebarView(openSettings: openSettings)
            .environmentObject(store)
            .environmentObject(widgets)
            .environmentObject(self)
        let host = NSHostingView(rootView: root)
        let blur = NSVisualEffectView()
        blur.material = .sidebar
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur

        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { e in handler(e); return e }) {
            monitors.append(m)
        }
        // Mouse-moved events stop when the cursor rests; a slow timer completes dwell/leave checks.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isVisible == true { self?.show(animated: false) } }
        }
        if isPinned { show(animated: false) }
    }

    private func screen(at p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    private func targetFrame(on screen: NSScreen, shown: Bool) -> NSRect {
        let vf = screen.visibleFrame
        let x = shown ? vf.maxX - Self.width - margin : screen.frame.maxX + 2
        return NSRect(x: x, y: vf.minY + margin, width: Self.width, height: vf.height - margin * 2)
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        if !isVisible {
            guard let s = screen(at: p) else { return }
            let atEdge = p.x >= s.frame.maxX - 2
                // ignore the corners (Hot Corners, Notification Center)
                && p.y > s.frame.minY + 40 && p.y < s.frame.maxY - 40
                // only on the right-most edge of the whole desktop
                && !NSScreen.screens.contains { $0 != s && $0.frame.minX >= s.frame.maxX - 1 && $0.frame.minY < p.y && $0.frame.maxY > p.y }
            if atEdge && NSEvent.pressedMouseButtons == 0 {
                edgeSince = edgeSince ?? Date()
                if Date().timeIntervalSince(edgeSince!) * 1000 >= Double(store.config.edgeDelayMs) {
                    currentScreen = s
                    show()
                }
            } else {
                edgeSince = nil
            }
        } else if !isPinned && store.config.autoHide {
            let inside = panel.frame.insetBy(dx: -24, dy: -24).contains(p) || p.x >= (currentScreen?.frame.maxX ?? .infinity) - 2
            if inside || panel.attachedSheet != nil || NSApp.modalWindow != nil {
                outsideSince = nil
            } else {
                outsideSince = outsideSince ?? Date()
                if Date().timeIntervalSince(outsideSince!) > 0.35 { hide() }
            }
        }
    }

    func toggle() { isVisible ? hide() : show() }

    func show(animated: Bool = true) {
        let s = currentScreen ?? screen(at: NSEvent.mouseLocation) ?? NSScreen.main!
        currentScreen = s
        outsideSince = nil
        if !isVisible { panel.setFrame(targetFrame(on: s, shown: false), display: false) }
        panel.orderFrontRegardless()
        isVisible = true
        let target = targetFrame(on: s, shown: true)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        if store.status.values.allSatisfy({ $0.lastSuccess.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true }),
           !store.isLoading, store.hasAnySource {
            Task { await store.refresh() }
        }
    }

    func hide() {
        guard isVisible, let s = currentScreen else { return }
        isVisible = false
        edgeSince = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(targetFrame(on: s, shown: false), display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.isVisible == false { self?.panel.orderOut(nil); self?.currentScreen = nil }
            }
        })
    }
}
