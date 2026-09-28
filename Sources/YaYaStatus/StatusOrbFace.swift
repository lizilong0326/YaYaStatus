import AppKit
import SwiftUI

enum StatusOrbMetrics {
    static let scale: CGFloat = 0.7
    static let windowSide: CGFloat = 64 * scale
    static let faceSide: CGFloat = 60 * scale
}

struct StatusOrbFace: View {
    let activeTaskCount: Int
    let workingTaskCount: Int
    let showWorkingBeam: Bool
    let finishCue: OrbTaskFinishCue?
    let hasSourceError: Bool
    let isDarkMode: Bool

    private var background: Color {
        isDarkMode ? Color.black.opacity(0.8)
                   : Color(nsColor: .windowBackgroundColor).opacity(0.92)
    }

    var body: some View {
        ZStack {
            Circle().fill(background)
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1)

            if let finishCue {
                FinishedOrbRing(outcome: finishCue.outcome)
                    .id(finishCue.id)
                if activeTaskCount > 0 { countBadge }
            } else if workingTaskCount > 0 {
                WorkingOrbRing(animate: showWorkingBeam)
                countLabel
            } else if activeTaskCount > 0 {
                Circle()
                    .trim(from: 0, to: 0.76)
                    .stroke(Color.orange.opacity(0.8),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(5)
                countLabel
            } else {
                Circle().stroke(Color.gray.opacity(0.5), lineWidth: 2.5).padding(5)
                if let mark = BrandIcon.mark {
                    Image(nsImage: mark)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
            }

            if hasSourceError {
                Circle()
                    .fill(Color(nsColor: .systemRed))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(background, lineWidth: 1.5))
                    .offset(x: 19, y: -19)
            }
        }
        .frame(width: 60, height: 60)
        .scaleEffect(StatusOrbMetrics.scale)
        .frame(width: StatusOrbMetrics.faceSide, height: StatusOrbMetrics.faceSide)
        .contentShape(Circle())
    }

    private var countLabel: some View {
        Text(activeTaskCount > 9 ? "9+" : String(activeTaskCount))
            .font(.custom("AvenirNext-DemiBold", size: activeTaskCount > 9 ? 16 : 22))
            .monospacedDigit()
            .foregroundStyle(Color.primary)
    }

    private var countBadge: some View {
        Text(activeTaskCount > 9 ? "9+" : String(activeTaskCount))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.primary)
            .frame(width: 21, height: 21)
            .background(Circle().fill(background))
            .overlay(Circle().stroke(Color.orange, lineWidth: 1.5))
            .offset(x: 19, y: 19)
    }
}

private struct WorkingOrbRing: View {
    let animate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var flowingGradient: AngularGradient {
        let isDark = colorScheme == .dark
        let base = Color(red: 0.24, green: 0.30, blue: 0.61).opacity(isDark ? 0.32 : 0.28)
        let violet = isDark
            ? Color(red: 0.62, green: 0.43, blue: 1)
            : Color(red: 0.40, green: 0.25, blue: 0.75)
        let blue = isDark
            ? Color(red: 0.30, green: 0.62, blue: 1)
            : Color(red: 0.13, green: 0.40, blue: 0.79)
        let ice = isDark
            ? Color(red: 0.67, green: 0.90, blue: 1)
            : Color(red: 0.03, green: 0.51, blue: 0.72)
        let star = isDark ? Color.white : Color(red: 0.07, green: 0.32, blue: 0.58)
        return AngularGradient(
            gradient: Gradient(stops: [
                .init(color: base, location: 0),
                .init(color: base, location: 0.50),
                .init(color: violet, location: 0.67),
                .init(color: blue, location: 0.81),
                .init(color: ice, location: 0.92),
                .init(color: star, location: 0.96),
                .init(color: blue, location: 0.985),
                .init(color: base, location: 1)
            ]),
            center: .center
        )
    }

    var body: some View {
        if animate && !reduceMotion {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 3.6) / 3.6 * 360
                flowingRing(angle: phase)
            }
        } else {
            flowingRing(angle: 0)
        }
    }

    private func flowingRing(angle: Double) -> some View {
        ZStack {
            Circle()
                .stroke(flowingGradient, lineWidth: 4)
                .blur(radius: 3)
                .opacity(0.75)
            Circle()
                .stroke(flowingGradient, lineWidth: 3)
        }
        .padding(5)
        .rotationEffect(.degrees(angle))
    }
}

private struct FinishedOrbRing: View {
    let outcome: OrbTaskOutcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var color: Color {
        switch outcome {
        case .completed: Color(nsColor: .systemGreen)
        case .ended, .interrupted: Color(nsColor: .systemGray)
        case .failed: Color(nsColor: .systemRed)
        }
    }

    private var symbol: String {
        switch outcome {
        case .completed: "checkmark"
        case .ended, .interrupted: "stop.fill"
        case .failed: "exclamationmark"
        }
    }

    var body: some View {
        let visible = reduceMotion || appeared
        ZStack {
            Circle().stroke(color.opacity(0.75), lineWidth: 2.5).padding(5)
            Circle()
                .stroke(color, lineWidth: 2)
                .padding(7)
                .scaleEffect(visible ? 1.17 : 0.72)
                .opacity(visible ? 0 : 0.7)
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
                .scaleEffect(visible ? 1 : 0.4)
                .opacity(visible ? 1 : 0)
        }
        .onAppear {
            if !reduceMotion {
                withAnimation(.easeOut(duration: 0.55)) { appeared = true }
            }
        }
    }
}
