#if os(macOS)
import AppKit
import SwiftUI
import Combine
import NotchCore

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let model = MeterModel(demo: CommandLine.arguments.contains("--demo"))
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var rails: [NSPanel] = []
    private var detailPanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var hovered = Set<String>()
    private var hideWork: DispatchWorkItem?
    private var activeGeometry: NotchGeometry?
    private var activeScreenFrame: CGRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Codex quota")
            button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Codex remaining allowance · click for details, right-click for menu"
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: makeDetailView())
        model.$snapshot.combineLatest(model.$error, model.$preferredBucket).sink { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }.store(in: &cancellables)
        model.$now.sink { [weak self] _ in self?.updateStatus() }.store(in: &cancellables)
        model.$overlayEnabled.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildRails() }
        }.store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildRails() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.wake(); self?.rebuildRails() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.sleep(); self?.hideDetail() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildRails() }
        })
        model.start(); rebuildRails(); updateStatus()
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop(); hideWork?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        rails.forEach { $0.close() }; detailPanel?.close()
    }
    private func updateStatus() { statusItem?.button?.title = " " + model.compactLabel }
    private func makeDetailView() -> DetailView {
        DetailView(model: model, hovered: { [weak self] entered in
            self?.setHover("detail", entered: entered)
        }, refresh: { [weak self] in self?.model.refresh() }, settings: { [weak self] in self?.showSettings() })
    }
    private func panel(frame: CGRect) -> PassivePanel {
        let panel = PassivePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        return panel
    }
    private func rebuildRails() {
        hideDetail(); hovered.removeAll()
        rails.forEach { $0.close() }; rails.removeAll()
        guard model.overlayEnabled else { return }
        for (index, screen) in NSScreen.screens.enumerated() {
            guard let geometry = NotchGeometry.calculate(screen: screen.frame, topInset: screen.safeAreaInsets.top,
                auxiliaryLeft: screen.auxiliaryTopLeftArea, auxiliaryRight: screen.auxiliaryTopRightArea,
                scale: screen.backingScaleFactor) else { continue }
            for left in [true, false] {
                let identifier = "\(index):\(left)"
                let rail = panel(frame: left ? geometry.leftPanel : geometry.rightPanel)
                rail.contentView = NSHostingView(rootView: RailView(model: model, left: left, hovered: { [weak self] entered in
                    guard let self else { return }
                    if entered { activeGeometry = geometry; activeScreenFrame = screen.frame }
                    setHover(identifier, entered: entered)
                }))
                rail.orderFrontRegardless(); rails.append(rail)
            }
        }
    }
    private func setHover(_ id: String, entered: Bool) {
        if entered {
            hovered.insert(id); hideWork?.cancel()
            if id != "detail" { showDetail(); model.hover() }
        } else {
            hovered.remove(id)
            guard hovered.isEmpty else { return }
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovered.isEmpty else { return }
                self.hideDetail()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
    private func showDetail() {
        guard let geometry = activeGeometry, let screen = activeScreenFrame else { return }
        popover.performClose(nil)
        if detailPanel == nil {
            let panel = panel(frame: .zero)
            panel.hasShadow = true
            panel.contentView = NSHostingView(rootView: makeDetailView())
            detailPanel = panel
        }
        let size = CGSize(width: 340, height: min(540, max(260, detailPanel?.contentView?.fittingSize.height ?? 440)))
        detailPanel?.setFrame(geometry.detailFrame(size: size, screen: screen), display: true)
        detailPanel?.orderFrontRegardless()
    }
    private func hideDetail() { detailPanel?.orderOut(nil); hovered.remove("detail") }
    @objc private func statusClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp, let button = statusItem.button {
            let menu = NSMenu()
            let refresh = menu.addItem(withTitle: "Refresh quotas", action: #selector(refreshNow), keyEquivalent: "r")
            refresh.target = self
            let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Codex Notch Meter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return
        }
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { hideDetail(); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); model.hover() }
    }
    @objc private func refreshNow() { model.refresh() }
    @objc private func showSettings() {
        popover.performClose(nil); hideDetail()
        if settingsWindow == nil {
            let view = SettingsView(model: model, chooseExecutable: { [weak self] in self?.chooseExecutable() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Codex Notch Meter Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func chooseExecutable() {
        let open = NSOpenPanel()
        open.title = "Choose the official Codex CLI executable"
        open.message = "Only choose an installed Codex CLI that you trust. It will be run with the app-server argument to read quota data."
        open.canChooseDirectories = false; open.canChooseFiles = true; open.allowsMultipleSelection = false
        if open.runModal() == .OK, let url = open.url { model.setExecutable(url.path) }
    }
}
#endif
