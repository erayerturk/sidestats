import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = MetricsStore()
    let widgets = WidgetStore()
    let todos = TodoStore()
    var api: LocalAPIServer!
    var edge: EdgePanelController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ note: Notification) {
        api = LocalAPIServer(widgets: widgets, todos: todos)
        api.start()
        edge = EdgePanelController(store: store, widgets: widgets, todos: todos, openSettings: { [weak self] in self?.openSettings(tab: $0) })
        setupStatusItem()
        registerHotKey()
        if store.hasAnySource { Task { await store.refresh() } }
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            edge.show()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "SideStats")
        let menu = NSMenu()
        menu.addItem(item("Show / Hide Sidebar", #selector(toggle), "s", [.control, .option, .command]))
        menu.addItem(item("Refresh", #selector(refresh), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettingsMenu), ","))
        menu.addItem(item("GitHub / Help", #selector(openHelp), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit SideStats", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target ?? self
        return i
    }

    @objc func toggle() { edge.toggle() }
    @objc func refresh() { widgets.refreshAll(); Task { await store.refresh() } }
    @objc func openHelp() { NSWorkspace.shared.open(URL(string: Links.repo)!) }

    @objc func openSettingsMenu() { openSettings(tab: nil) }

    func openSettings(tab: SettingsTab?) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView().environmentObject(store).environmentObject(widgets).environmentObject(todos)))
            w.title = "SideStats Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.level = .floating + 1
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.level = .normal
        settingsWindow?.orderFrontRegardless()
    }

    /// ⌃⌥⌘S global shortcut via Carbon (needs no Accessibility permission).
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5344_5354), id: 1)  // 'SDST'
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

enum Links {
    static let repo = "https://github.com/erayerturk/sidestats"
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
