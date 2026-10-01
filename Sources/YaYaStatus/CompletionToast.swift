import AppKit
import SwiftUI

enum CompletionToastPlacement {
    static let size = NSSize(width: 164, height: 31)
    private static let gap: CGFloat = 10
    private static let edgeInset: CGFloat = 8

    private enum Side {
        case left, right, above, below
    }

    static func frame(beside orb: NSRect, within visible: NSRect) -> NSRect {
        placement(beside: orb, within: visible).frame
    }

    static func entryFrame(beside orb: NSRect, within visible: NSRect) -> NSRect {
        let (frame, side) = placement(beside: orb, within: visible)
        let distance: CGFloat = 14
        switch side {
        case .left: return frame.offsetBy(dx: distance, dy: 0)
        case .right: return frame.offsetBy(dx: -distance, dy: 0)
        case .above: return frame.offsetBy(dx: 0, dy: -distance)
        case .below: return frame.offsetBy(dx: 0, dy: distance)
        }
    }

    private static func placement(beside orb: NSRect, within visible: NSRect) -> (frame: NSRect, side: Side) {
        let spaces: [(Side, CGFloat, CGFloat)] = [
            (.left, orb.minX - visible.minX, size.width),
            (.right, visible.maxX - orb.maxX, size.width),
            (.above, visible.maxY - orb.maxY, size.height),
            (.below, orb.minY - visible.minY, size.height)
        ]
        let fitting = spaces.filter { $0.1 >= $0.2 + gap + edgeInset }
        let side = (fitting.isEmpty ? spaces : fitting).max(by: { $0.1 < $1.1 })!.0
        let preferredX: CGFloat
        let preferredY: CGFloat
        switch side {
        case .left:
            preferredX = orb.minX - gap - size.width
            preferredY = orb.midY - size.height / 2
        case .right:
            preferredX = orb.maxX + gap
            preferredY = orb.midY - size.height / 2
        case .above:
            preferredX = orb.midX - size.width / 2
            preferredY = orb.maxY + gap
        case .below:
            preferredX = orb.midX - size.width / 2
            preferredY = orb.minY - gap - size.height
        }
        let x = min(max(preferredX, visible.minX + edgeInset),
                    visible.maxX - size.width - edgeInset)
        let y = min(max(preferredY, visible.minY + edgeInset),
                    visible.maxY - size.height - edgeInset)
        return (NSRect(origin: NSPoint(x: x, y: y), size: size), side)
    }
}

struct CompletionToastView: View {
    @AppStorage("yayastatus-is-dark-mode") private var isDarkMode = true

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemGreen))
            Text("有任务完成")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDarkMode ? Color.white : Color.black.opacity(0.88))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: CompletionToastPlacement.size.width,
               height: CompletionToastPlacement.size.height)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isDarkMode ? Color(red: 0.17, green: 0.17, blue: 0.19).opacity(0.80)
                                 : Color.white.opacity(0.84))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isDarkMode ? Color.white.opacity(0.13)
                                   : Color.black.opacity(0.1), lineWidth: 1)
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .accessibilityLabel("有任务完成")
    }
}
