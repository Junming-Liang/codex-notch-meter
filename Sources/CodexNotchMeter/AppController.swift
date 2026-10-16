#if os(macOS)
import AppKit
import SwiftUI
import Combine
import CoreGraphics
import ColorSync
import NotchCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = MeterModel(demo: CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--contour-test") || CommandLine.arguments.contains("--alignment-test") || CommandLine.arguments.contains("--motion-test") || CommandLine.arguments.contains("--display-test") || CommandLine.arguments.contains("--collapse-test") || CommandLine.arguments.contains("--update-test") || CommandLine.arguments.contains("--music-test"))
    private lazy var loginSettings = LoginSettingsModel(synthetic: model.demo)
    private let smokeMode = CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--contour-test") || CommandLine.arguments.contains("--alignment-test") || CommandLine.arguments.contains("--motion-test") || CommandLine.arguments.contains("--display-test") || CommandLine.arguments.contains("--collapse-test") || CommandLine.arguments.contains("--update-test") || CommandLine.arguments.contains("--music-test")
    private var smokeReady = false
    private var smokeGeometryValid = false
    private var smokeTimer: Timer?
    private var smokeIsland: IslandPanelController?
    private var contourHarness: ContourRenderHarness?
    private var alignmentHarness: AlignmentRenderHarness?
    private var motionHarness: NativeMotionHarness?
    private var displayHarness: DisplayCompatibilityHarness?
    private var collapseHarness: CollapseRenderHarness?
    private var updateHarness: UpdateRenderHarness?
    private var musicHarness: MusicRenderHarness?
    private var animationHarness: SkinAnimationHarness?
    private var animationComplete = false
    private var animationValid = false
    private var retiredSmokeIsland: IslandPanelController?
    private var retiredSmokeFrame: CGRect = .zero
    private var smokePhase = 0
    private var smokeStarted: TimeInterval = 0
    private var smokePhaseStarted: TimeInterval = 0
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private lazy var displayCoordinator = DisplayCoordinator(model: model,
        snapshots: { NativeDisplays.snapshot() }, activity: { [weak self] in self?.displayActivity ?? DisplayActivity() },
        makeIsland: { [unowned self] in self.makeIsland(geometry: $0) },
        changed: { [weak self] in self?.updateSkinActivity() })
    private var islands: [IslandPanelController] { displayCoordinator.islands }
    private var displayActivity: DisplayActivity {
        var state = DisplayActivity()
        state.overlayEnabled = model.overlayEnabled; state.systemSleeping = sleeping
        state.displaysSleeping = displaySleeping; state.sessionActive = sessionActive
        state.applicationHidden = NSApp.isHidden; state.terminating = terminating
        return state
    }
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var sleeping = false
    private var displaySleeping = false
    private var sessionActive = true
    private var terminating = false
    private var quitRequested = false
    private var pendingNotice: RefreshNotice?
    private var menuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        SmokeDiagnostics.mark("didFinishLaunching entered")
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Codex quota")
            button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Codex 剩余额度 · 点击查看 / 退出，右键打开菜单"
        }
        popover.behavior = .transient; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: makeDetailView())
        model.$snapshot.combineLatest(model.$error, model.$preferredBucket).sink { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.updateStatus(); self?.updateSkinActivity(); self?.rebuildIslands()
                if let self, self.popover.isShown, let view = self.popover.contentViewController?.view {
                    self.popover.contentSize = NSSize(width: 340, height: min(590, max(280, view.fittingSize.height)))
                }
            }
        }.store(in: &cancellables)
        model.$preferredQuota.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateSkinActivity() }
        }.store(in: &cancellables)
        model.$now.sink { [weak self] _ in self?.updateStatus(); self?.deliverPendingNotice() }.store(in: &cancellables)
        model.$refreshNotice.sink { [weak self] notice in
            DispatchQueue.main.async {
                guard let self, !self.smokeMode else { return }
                self.pendingNotice = notice
                if notice == nil { self.islands.forEach { $0.dismissRefreshNotice() } }
                self.deliverPendingNotice()
            }
        }.store(in: &cancellables)
        model.$refreshNoticesEnabled.removeDuplicates().sink { [weak self] enabled in
            DispatchQueue.main.async {
                guard let self, !enabled else { return }
                self.pendingNotice = nil; self.islands.forEach { $0.dismissRefreshNotice() }
            }
        }.store(in: &cancellables)
        model.$overlayEnabled.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildIslands() }
        }.store(in: &cancellables)
        model.$horizontalCalibrations.combineLatest(model.$shapeCalibrations).sink { [weak self] _, _ in
            // Rebuilding cancels old hit regions and animation timers before moving the contour.
            DispatchQueue.main.async { self?.rebuildIslands() }
        }.store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildIslands() }
        })
        model.$theme.combineLatest(model.$skinMotionEnabled, model.$skinSpeed).sink { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.updateSkinActivity() }
        }.store(in: &cancellables)
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.updateSkinActivity() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.model.wake(); self?.rebuildIslands(); self?.updateSkinActivity() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.model.sleep(); self?.rebuildIslands(); self?.updateSkinActivity() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildIslands() }
        })
        for (name, change) in [
            (NSWorkspace.screensDidSleepNotification, 0), (NSWorkspace.screensDidWakeNotification, 1),
            (NSWorkspace.sessionDidResignActiveNotification, 2), (NSWorkspace.sessionDidBecomeActiveNotification, 3),
            (NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, 4)
        ] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if change == 0 { self.displaySleeping = true }
                    if change == 1 { self.displaySleeping = false }
                    if change == 2 { self.sessionActive = false }
                    if change == 3 { self.sessionActive = true }
                    self.rebuildIslands(); self.updateSkinActivity()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let window = note.object as? NSWindow, self.displayCoordinator.owns(window) else { return }
                self.rebuildIslands()
            }
        })
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rebuildIslands() }
            })
        }
        model.start(); rebuildIslands(); updateStatus(); updateSkinActivity()
        if smokeMode {
            if CommandLine.arguments.contains("--music-test") { runMusicTest() }
            else if CommandLine.arguments.contains("--update-test") { runUpdateTest() }
            else if CommandLine.arguments.contains("--collapse-test") { runCollapseTest() }
            else if CommandLine.arguments.contains("--display-test") { runDisplayTest() }
            else if CommandLine.arguments.contains("--motion-test") { runMotionTest() }
            else if CommandLine.arguments.contains("--alignment-test") { runAlignmentTest() }
            else if CommandLine.arguments.contains("--contour-test") { runContourTest() }
            else { runSmokeTest() }
        }
        SmokeDiagnostics.mark("didFinishLaunching returned")
    }
    func popoverDidClose(_ notification: Notification) { updateSkinActivity() }
    func popoverDidShow(_ notification: Notification) { updateSkinActivity() }
    func applicationDidBecomeActive(_ notification: Notification) { loginSettings.refresh() }
    private func configureMainMenu() {
        let bar = NSMenu()
        let app = NSMenuItem()
        let menu = NSMenu(title: "Codex Notch Meter")
        let quit = menu.addItem(withTitle: "退出 Codex Notch Meter", action: #selector(requestQuit), keyEquivalent: "q")
        quit.target = self
        app.submenu = menu; bar.addItem(app); NSApp.mainMenu = bar
    }
    /// Always leave an active dispatch/SwiftUI callback before entering terminateLater.
    @objc private func requestQuit() {
        guard !quitRequested, !terminating else { return }
        quitRequested = true
        perform(#selector(performQuit), with: nil, afterDelay: 0)
    }
    @objc private func performQuit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SmokeDiagnostics.mark("applicationShouldTerminate entered")
        guard !terminating else { return .terminateLater }
        terminating = true
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        smokeTimer?.invalidate(); smokeTimer = nil
        contourHarness?.stop(); alignmentHarness?.stop(); motionHarness?.stop(); displayHarness?.stop(); collapseHarness?.stop(); updateHarness?.stop(); musicHarness?.stop(); animationHarness?.stop()
        stopIslands(); smokeIsland?.stop()
        Task {
            SmokeDiagnostics.mark("model shutdown started")
            await model.shutdown()
            SmokeDiagnostics.mark("model shutdown completed")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        SmokeDiagnostics.mark("applicationWillTerminate entered")
        model.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if smokeMode {
            print(smokeReady ? "SMOKE_OK: native island geometry, expansion and orderly shutdown completed; demo-only" : "SMOKE_FAILED: native island checks failed")
        }
    }
    private func stopIslands() { displayCoordinator.stop() }
    private func rebuildIslands() {
        guard !smokeMode, !terminating else { return }
        displayCoordinator.refresh()
    }
    private func updateSkinActivity() {
        model.music.setActive(!sleeping && !displaySleeping && sessionActive && !terminating && !NSApp.isHidden)
        islands.forEach { $0.setMusicPresentationAllowed(passiveMusicAllowed) }
        let coloredPrimary = (model.primaryWindow?.remainingPercent ?? 0) > 25
        let visibleIsland = islands.contains { (coloredPrimary || $0.displaysColoredDetails) && $0.panel.isVisible && $0.panel.occlusionState.contains(.visible) }
        // A visible details header is also a color consumer; empty/zero collapsed contours are not.
        let visibleDetails = popover.isShown
        model.updateSkinActivity(SkinMotionPolicy(theme: model.theme, motionEnabled: model.skinMotionEnabled,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            asleep: sleeping || displaySleeping || terminating, overlayEnabled: model.overlayEnabled,
            hasVisibleOwnedSurface: !NSApp.isHidden && (visibleIsland || visibleDetails), sessionActive: sessionActive))
    }
    private func makeIsland(geometry: IslandGeometry, polling: Bool = true, reducedMotion: Bool? = nil) -> IslandPanelController {
        IslandPanelController(model: model, geometry: geometry, startPolling: polling, reducedMotionOverride: reducedMotion,
            musicPresentationAllowed: passiveMusicAllowed,
            activityChanged: { [weak self] in self?.updateSkinActivity() },
            hovered: { [weak self] in self?.model.hover() },
            refresh: { [weak self] in self?.model.refresh() },
            settings: { [weak self] in self?.showSettings() },
            quit: { [weak self] in self?.requestQuit() })
    }
    private var passiveMusicAllowed: Bool {
        displayActivity.permitsOverlay && !menuOpen && !popover.isShown && settingsWindow?.isVisible != true
    }
    private func deliverPendingNotice() {
        guard let notice = pendingNotice else { return }
        let age = Date().timeIntervalSince(notice.receivedAt)
        guard notice.isEligible, model.refreshNoticesEnabled, age >= 0, age <= 10 else { pendingNotice = nil; return }
        guard !smokeMode, !terminating, displayActivity.permitsOverlay, !menuOpen,
              !popover.isShown, settingsWindow?.isVisible != true, !islands.contains(where: \.isInteracting) else { return }
        if let island = islands.first, island.showRefreshNotice(notice) { pendingNotice = nil }
    }
    private func updateStatus() {
        statusItem?.button?.title = " " + model.compactLabel
        let pending = model.bucket?.windows.contains(where: { $0.resetPending(at: model.now) }) ?? false
        statusItem?.button?.setAccessibilityLabel("Codex 剩余额度，点击可查看或退出")
        statusItem?.button?.setAccessibilityValue(model.compactLabel + "。" + model.status + (pending ? "。等待重置确认" : ""))
    }
    private func makeDetailView() -> DetailView {
        DetailView(model: model, hovered: { _ in }, refresh: { [weak self] in self?.model.refresh() },
            settings: { [weak self] in self?.showSettings() }, quit: { [weak self] in self?.requestQuit() })
    }
    @objc private func statusClicked() {
        defer { updateSkinActivity() }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp, let button = statusItem.button {
            let menu = makeStatusMenu()
            menuOpen = true; islands.forEach { $0.setMusicPresentationAllowed(false); $0.collapse() }
            defer { menuOpen = false; updateSkinActivity(); deliverPendingNotice() }
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return
        }
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { islands.forEach { $0.setMusicPresentationAllowed(false); $0.collapse() }; popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); model.hover() }
    }
    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let refresh = menu.addItem(withTitle: "刷新额度", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        let settings = menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Codex Notch Meter", action: #selector(requestQuit), keyEquivalent: "q")
        quit.target = self
        return menu
    }
    @objc private func refreshNow() { model.refresh() }
    @objc private func showSettings() {
        popover.performClose(nil); islands.forEach { $0.setMusicPresentationAllowed(false); $0.collapse() }
        loginSettings.refresh()
        if settingsWindow == nil {
            let view = SettingsView(model: model, login: loginSettings, chooseExecutable: { [weak self] in self?.chooseExecutable() }, quit: { [weak self] in self?.requestQuit() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Codex Notch Meter 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        updateSkinActivity()
    }
    private func chooseExecutable() {
        let open = NSOpenPanel()
        open.title = "选择官方 Codex 应用或 CLI"
        open.message = "可选择已安装且信任的 Codex 桌面应用，或官方 codex CLI。仅通过 app-server 读取账户额度。"
        open.canChooseDirectories = false; open.canChooseFiles = true; open.allowsMultipleSelection = false
        open.treatsFilePackagesAsDirectories = false
        if open.runModal() == .OK, let url = open.url { model.setExecutable(url.path) }
    }
    private func runSmokeTest() {
        animationHarness = SkinAnimationHarness { [weak self] valid in
            self?.animationComplete = true; self?.animationValid = valid
        }
        showSettings()
        guard let screen = NSScreen.main else { requestQuit(); return }
        let frame = screen.frame
        let inset: CGFloat = 32, width: CGFloat = 220
        guard let notch = NotchGeometry.calculate(screen: frame, topInset: inset,
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - inset, width: (frame.width - width) / 2, height: inset),
            auxiliaryRight: CGRect(x: frame.midX + width / 2, y: frame.maxY - inset, width: (frame.width - width) / 2, height: inset)) else { requestQuit(); return }
        let island = makeIsland(geometry: IslandGeometry(notch: notch, screen: frame, backingScale: screen.backingScaleFactor), polling: false, reducedMotion: false)
        smokeIsland = island
        let loginSafety = loginSettings.verifySyntheticSafety()
        smokeGeometryValid = island.verifyNativeGeometry() && loginSafety
        island.beginSmokeExpansion()
        animationHarness?.start()
        smokeStarted = ProcessInfo.processInfo.systemUptime
        smokePhaseStarted = smokeStarted
        smokeTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self,
            selector: #selector(advanceSmokeTest(_:)), userInfo: nil, repeats: true)
    }
    private func runDisplayTest() {
        guard let screen = NSScreen.main else { requestQuit(); return }
        displayHarness = DisplayCompatibilityHarness(model: model, screen: screen, menuAvailable: { [weak self] in self?.statusItem?.button != nil }) { [weak self] valid in
            self?.smokeReady = valid; self?.requestQuit()
        }
        displayHarness?.start()
    }
    private func runMusicTest() {
        guard let screen = NSScreen.main else { requestQuit(); return }
        musicHarness = MusicRenderHarness(screen: screen) { [weak self] valid in
            self?.smokeReady = valid; self?.requestQuit()
        }
        musicHarness?.start()
    }
    private func runUpdateTest() {
        guard let screen = NSScreen.main else { requestQuit(); return }
        updateHarness = UpdateRenderHarness(model: model, screen: screen) { [weak self] valid in
            self?.smokeReady = valid; self?.requestQuit()
        }
        updateHarness?.start()
    }
    private func runCollapseTest() {
        guard let screen = NSScreen.main else { requestQuit(); return }
        let frame = screen.frame, left = frame.midX - 110 + 0.25, right = left + 220
        guard let notch = NotchGeometry.calculate(screen: frame, topInset: 32,
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - 32, width: left - frame.minX, height: 32),
            auxiliaryRight: CGRect(x: right, y: frame.maxY - 32, width: frame.maxX - right, height: 32)) else { requestQuit(); return }
        collapseHarness = CollapseRenderHarness(model: model,
            geometry: IslandGeometry(notch: notch, screen: frame, backingScale: screen.backingScaleFactor)) { [weak self] valid in
                self?.smokeReady = valid; self?.requestQuit()
            }
        collapseHarness?.start()
    }
    private func runMotionTest() {
        guard let screen = NSScreen.main else { requestQuit(); return }
        let frame = screen.frame, left = frame.midX - 110 + 0.25, right = left + 220
        guard let notch = NotchGeometry.calculate(screen: frame, topInset: 32,
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - 32, width: left - frame.minX, height: 32),
            auxiliaryRight: CGRect(x: right, y: frame.maxY - 32, width: frame.maxX - right, height: 32)) else { requestQuit(); return }
        motionHarness = NativeMotionHarness(model: model,
            geometry: IslandGeometry(notch: notch, screen: frame, backingScale: screen.backingScaleFactor, horizontalAdjustment: 2.5)) { [weak self] valid in
                self?.smokeReady = valid; self?.requestQuit()
            }
        motionHarness?.start()
    }
    private func runAlignmentTest() {
        guard let screen = NSScreen.main else { requestQuit(); return }
        alignmentHarness = AlignmentRenderHarness(model: model, screen: screen) { [weak self] valid in
            self?.smokeReady = valid; self?.requestQuit()
        }
        alignmentHarness?.start()
    }
    private func runContourTest() {
        guard let screen = NSScreen.main else { requestQuit(); return }
        let frame = screen.frame, inset: CGFloat = 32, width: CGFloat = 220
        guard let notch = NotchGeometry.calculate(screen: frame, topInset: inset,
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - inset, width: (frame.width - width) / 2, height: inset),
            auxiliaryRight: CGRect(x: frame.midX + width / 2, y: frame.maxY - inset, width: (frame.width - width) / 2, height: inset)) else { requestQuit(); return }
        let island = makeIsland(geometry: IslandGeometry(notch: notch, screen: frame, backingScale: screen.backingScaleFactor), polling: false, reducedMotion: true)
        smokeIsland = island
        contourHarness = ContourRenderHarness(model: model, island: island) { [weak self] valid in
            self?.smokeReady = valid; self?.requestQuit()
        }
        contourHarness?.start()
    }
    @objc private func advanceSmokeTest(_ timer: Timer) {
        guard let island = smokeIsland else { requestQuit(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - smokeStarted
        let phaseElapsed = now - smokePhaseStarted
        switch smokePhase {
        case 0 where phaseElapsed >= 0.45:
            smokeGeometryValid = smokeGeometryValid && island.smokeProgress > 0
            island.smokePointer(inside: false, now: elapsed); smokePhase = 1; smokePhaseStarted = now
        case 1 where phaseElapsed >= 0.27:
            island.smokePointer(inside: false, now: elapsed)
            smokeGeometryValid = smokeGeometryValid && !island.smokeTargetExpanded; smokePhase = 2; smokePhaseStarted = now
        case 2 where phaseElapsed >= 0.10:
            smokeGeometryValid = smokeGeometryValid && island.smokeProgress > 0 && island.smokeProgress < 1
            island.smokePointer(inside: true, now: elapsed); smokePhase = 3; smokePhaseStarted = now
        case 3 where phaseElapsed >= 0.16:
            island.smokePointer(inside: true, now: elapsed)
            smokeGeometryValid = smokeGeometryValid && island.smokeTargetExpanded; smokePhase = 4; smokePhaseStarted = now
        case 4 where phaseElapsed >= 1.12:
            let expanded = island.smokeExpanded
            let routing = island.verifySmokeClickRouting()
            SmokeDiagnostics.mark("motion checkpoint elapsed=\(elapsed) expanded=\(expanded) routing=\(routing) prior=\(smokeGeometryValid)")
            smokeGeometryValid = [smokeGeometryValid, expanded, routing].allSatisfy { $0 }
            retiredSmokeFrame = island.panel.frame; island.stop(); retiredSmokeIsland = island
            let replacement = makeIsland(geometry: island.geometry, polling: false, reducedMotion: true)
            smokeIsland = replacement; replacement.beginSmokeExpansion(); smokePhase = 5; smokePhaseStarted = now
        case 5 where phaseElapsed >= 0.30 && animationComplete:
            timer.invalidate(); smokeTimer = nil
            let expanded = island.smokeExpanded
            let routing = island.verifySmokeClickRouting()
            SmokeDiagnostics.mark("reduced-motion checkpoint elapsed=\(elapsed) expanded=\(expanded) routing=\(routing) retiredStopped=\(retiredSmokeIsland?.smokeStopped == true)")
            smokeReady = model.demo && smokeGeometryValid && animationValid && expanded && routing
                && retiredSmokeIsland?.smokeStopped == true && retiredSmokeIsland?.panel.frame == retiredSmokeFrame
                && settingsWindow?.isVisible == true && statusItem.button != nil
            SmokeDiagnostics.mark(smokeReady ? "native hover reversal, teardown, reduced motion and Quit checks passed" : "native island checks failed")
            if CommandLine.arguments.contains("--smoke-empty") {
                let menu = makeStatusMenu(); menu.performActionForItem(at: menu.numberOfItems - 1)
            } else if CommandLine.arguments.contains("--smoke-many"),
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: settingsWindow?.windowNumber ?? 0, context: nil,
                    characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12) {
                if NSApp.mainMenu?.performKeyEquivalent(with: event) != true { smokeReady = false; requestQuit() }
            } else {
                // The shared SwiftUI button route must also survive an active main-queue callback.
                DispatchQueue.main.async { [weak self] in self?.requestQuit(); self?.requestQuit() }
            }
        default: break
        }
    }
}
#endif
