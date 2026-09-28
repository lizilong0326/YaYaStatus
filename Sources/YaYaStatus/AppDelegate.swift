import AppKit
import SwiftUI

final class FloatingStatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            DragDiagnostics.shared.record("panel.sendEvent.\(event.type)",
                                          window: self, event: event)
            super.sendEvent(event)
            DragDiagnostics.shared.record("panel.sendEvent.return.\(event.type)",
                                          window: self, event: event)
        default:
            super.sendEvent(event)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let taskCollection = TaskCollectionStore()
    private lazy var codexStore = CodexStatusStore(collection: taskCollection)
    private lazy var workBuddyStore = WorkBuddyStatusStore(collection: taskCollection)
    private lazy var kimiWorkStore = KimiWorkStatusStore(collection: taskCollection)
    private lazy var doubaoWorkStore = DoubaoWorkStatusStore(collection: taskCollection)
    private lazy var grokBotStore = GrokBotStatusStore(collection: taskCollection)
    private lazy var piAgentStore = PiAgentStatusStore(collection: taskCollection)
    private lazy var deepSeekWebStore = DeepSeekWebStatusStore(collection: taskCollection)
    private var panel: FloatingStatusPanel!
    private var statusItem: NSStatusItem!
    private var pendingFrameSave: Task<Void, Never>?
    private static let savedFrameKey = "floating-panel-frame-v1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installPanel()
        DragDiagnostics.shared.record("app.launch", window: panel,
                                      details: "movableByBackground=\(panel.isMovableByWindowBackground)")
        installMenuBar()
        codexStore.start()
        workBuddyStore.start()
        kimiWorkStore.start()
        doubaoWorkStore.start()
        grokBotStore.start()
        piAgentStore.start()
        deepSeekWebStore.start()
        showPanel()
        savePanelFrame()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DragDiagnostics.shared.record("app.terminate", window: panel)
        pendingFrameSave?.cancel()
        savePanelFrame()
        codexStore.stop()
        workBuddyStore.stop()
        kimiWorkStore.stop()
        doubaoWorkStore.stop()
        grokBotStore.stop()
        piAgentStore.stop()
        deepSeekWebStore.stop()
    }

    func windowDidMove(_ notification: Notification) {
        DragDiagnostics.shared.record("window.didMove", window: panel)
        schedulePanelFrameSave()
    }

    func windowDidResize(_ notification: Notification) {
        DragDiagnostics.shared.record("window.didResize", window: panel)
        schedulePanelFrameSave()
    }

    private func schedulePanelFrameSave() {
        pendingFrameSave?.cancel()
        pendingFrameSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.savePanelFrame()
        }
    }

    private func savePanelFrame() {
        guard panel != nil else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.savedFrameKey)
    }

    private func installPanel() {
        let isCollapsed = UserDefaults.standard.bool(forKey: "yayastatus-is-collapsed")
        let size = isCollapsed
            ? NSSize(width: StatusOrbMetrics.windowSide, height: StatusOrbMetrics.windowSide)
            : NSSize(width: 350, height: 220)
        let initialFrame = restoredFrame(size: size)
        panel = FloatingStatusPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "丫丫状态"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Expanded panels use background dragging; the orb hands its mouse-down to AppKit.
        panel.isMovableByWindowBackground = !isCollapsed
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: StatusOrbMetrics.windowSide,
                               height: StatusOrbMetrics.windowSide)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: StatusPanelView(
            store: codexStore,
            collection: taskCollection,
            onRefresh: { [weak self] in self?.refreshAll() },
            onSizeChange: { [weak self] size in self?.resizePanel(to: size) }
        ))
    }

    private func resizePanel(to size: NSSize) {
        guard panel != nil else { return }
        DragDiagnostics.shared.record("panel.resize.request", window: panel,
                                      details: "size=(\(size.width),\(size.height))")
        panel.isMovableByWindowBackground = size.width > StatusOrbMetrics.windowSide
        guard panel.frame.size != size else { return }
        let frame = panel.frame
        let area = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let originX = min(max(frame.maxX - size.width, area.minX + 8), area.maxX - size.width - 8)
        let originY = min(max(frame.maxY - size.height, area.minY + 8), area.maxY - size.height - 8)
        panel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height),
                       display: true)
        DragDiagnostics.shared.record("panel.resize.applied", window: panel)
        savePanelFrame()
    }

    private func restoredFrame(size: NSSize) -> NSRect {
        if let value = UserDefaults.standard.string(forKey: Self.savedFrameKey) {
            let frame = NSRectFromString(value)
            if frame.width >= 40, frame.height >= 40,
               let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                let area = screen.visibleFrame
                return NSRect(
                    x: min(max(frame.maxX - size.width, area.minX + 8), area.maxX - size.width - 8),
                    y: min(max(frame.maxY - size.height, area.minY + 8), area.maxY - size.height - 8),
                    width: size.width,
                    height: size.height
                )
            }
        }
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: area.maxX - size.width - 24,
            y: area.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
    }

    private func installMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = BrandIcon.menuBar
            ?? NSImage(systemSymbolName: "circle.grid.2x2.fill", accessibilityDescription: "丫丫状态")
        statusItem.button?.toolTip = "丫丫状态"
        let menu = NSMenu()
        menu.addItem(withTitle: "显示悬浮框", action: #selector(showPanelFromMenu), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "刷新全部工作台", action: #selector(refreshFromMenu), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出丫丫状态", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    private func showPanel() {
        panel.orderFrontRegardless()
    }

    @objc private func showPanelFromMenu() { showPanel() }
    private func refreshAll() {
        codexStore.refreshNow()
        Task {
            await workBuddyStore.refresh()
            await kimiWorkStore.refresh()
            await doubaoWorkStore.refresh(forceStatusCheck: true)
            await grokBotStore.refresh()
            await piAgentStore.refresh()
            await deepSeekWebStore.refresh()
        }
    }

    @objc private func refreshFromMenu() { refreshAll() }
    @objc private func quit() { NSApp.terminate(nil) }
}
