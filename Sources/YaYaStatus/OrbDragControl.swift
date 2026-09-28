import AppKit
import SwiftUI

struct OrbDragControl: NSViewRepresentable {
    let accessibilityLabel: String
    let toolTip: String
    let onActivate: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onActivate: onActivate)
    }

    func makeNSView(context: Context) -> OrbWindowDragButton {
        let button = OrbWindowDragButton()
        button.title = ""
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate)
        return button
    }

    func updateNSView(_ button: OrbWindowDragButton, context: Context) {
        context.coordinator.onActivate = onActivate
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = toolTip
    }

    final class Coordinator: NSObject {
        var onActivate: () -> Void

        init(onActivate: @escaping () -> Void) {
            self.onActivate = onActivate
        }

        @objc func activate() {
            onActivate()
        }
    }
}

final class OrbWindowDragButton: NSButton {
    private var originalMouseDown: NSEvent?
    private var startedWindowDrag = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        originalMouseDown = event
        startedWindowDrag = false
        DragDiagnostics.shared.record("orb.mouseDown", window: window, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        DragDiagnostics.shared.record("orb.mouseDragged", window: window, event: event)
        guard !startedWindowDrag, let originalMouseDown else { return }
        let distance = event.locationInWindow - originalMouseDown.locationInWindow
        guard distance.width * distance.width + distance.height * distance.height >= 16 else { return }
        startedWindowDrag = true
        DragDiagnostics.shared.record("orb.performDrag.begin", window: window,
                                      event: originalMouseDown)
        window?.performDrag(with: originalMouseDown)
        DragDiagnostics.shared.record("orb.performDrag.return", window: window,
                                      event: event)
    }

    override func mouseUp(with event: NSEvent) {
        DragDiagnostics.shared.record("orb.mouseUp", window: window, event: event,
                                      details: "startedWindowDrag=\(startedWindowDrag)")
        defer {
            originalMouseDown = nil
            startedWindowDrag = false
        }
        if !startedWindowDrag, originalMouseDown != nil {
            DragDiagnostics.shared.record("orb.activate", window: window, event: event)
            performClick(nil)
        }
    }
}

private extension NSPoint {
    static func - (lhs: NSPoint, rhs: NSPoint) -> CGSize {
        CGSize(width: lhs.x - rhs.x, height: lhs.y - rhs.y)
    }
}
