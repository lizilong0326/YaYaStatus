import AppKit
import SwiftUI

final class FloatingStatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let taskCollection = TaskCollectionStore()
    private lazy var codexStore = CodexStatusStore(collection: taskCollection)
    private lazy var workBuddyStore = WorkBuddyStatusStore(collection: taskCollection)
    private lazy var kimiWorkStore = KimiWorkStatusStore(collection: taskCollection)
    private lazy var doubaoWorkStore = DoubaoWorkStatusStore(collection: taskCollection)
    private lazy var grokBotStore = GrokBotStatusStore(collection: taskCollection)
    private var panel: FloatingStatusPanel!
    private var statusItem: NSStatusItem!
    private static let savedFrameKey = "floating-panel-frame-v1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installPanel()
        installMenuBar()
        codexStore.start()
        workBuddyStore.start()
        kimiWorkStore.start()
        doubaoWorkStore.start()
        grokBotStore.start()
        showPanel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        codexStore.stop()
        workBuddyStore.stop()
        kimiWorkStore.stop()
        doubaoWorkStore.stop()
        grokBotStore.stop()
    }

    func windowDidMove(_ notification: Notification) {
        guard panel != nil else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.savedFrameKey)
    }

    private func installPanel() {
        let size = NSSize(width: 390, height: 570)
        let initialFrame = restoredFrame(size: size)
        panel = FloatingStatusPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "丫丫状态"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: StatusPanelView(
            store: codexStore,
            collection: taskCollection,
            onRefresh: { [weak self] in self?.refreshAll() }
        ))
    }

    private func restoredFrame(size: NSSize) -> NSRect {
        if let value = UserDefaults.standard.string(forKey: Self.savedFrameKey) {
            let frame = NSRectFromString(value)
            if frame.width > 200, frame.height > 200,
               let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                let area = screen.visibleFrame
                return NSRect(
                    x: min(max(frame.minX, area.minX + 8), area.maxX - size.width - 8),
                    y: min(max(frame.minY, area.minY + 8), area.maxY - size.height - 8),
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
        statusItem.button?.image = NSImage(systemSymbolName: "circle.grid.2x2.fill", accessibilityDescription: "丫丫状态")
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
            await doubaoWorkStore.refresh()
            await grokBotStore.refresh()
        }
    }

    @objc private func refreshFromMenu() { refreshAll() }
    @objc private func quit() { NSApp.terminate(nil) }
}
