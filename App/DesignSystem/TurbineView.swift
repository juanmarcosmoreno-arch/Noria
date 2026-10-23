import SwiftUI

/// Geometry of the Noria turbine (five swept blades around a hub).
///
/// The same numbers are used by `Tools/generate_icon.py`, which renders the
/// provisional app icon, so the in-app mark and the icon always match.
/// Coordinates are polar (radius in unit circle, angle in degrees, y pointing down).
enum TurbineGeometry {
    static let bladeCount = 5
    static let base0 = (r: 0.28, deg: -12.0)
    static let control1 = (r: 0.72, deg: -42.0)
    static let control2 = (r: 1.12, deg: 38.0)
    static let tip = (r: 0.93, deg: 100.0)
    static let control3 = (r: 0.66, deg: 96.0)
    static let control4 = (r: 0.46, deg: 62.0)
    static let base1 = (r: 0.28, deg: 46.0)
    static let hubRadius = 0.17
    static let hubGapRadius = 0.27
    static let gapWidth = 0.045

    static func point(_ polar: (r: Double, deg: Double), rotation: Double, center: CGPoint, scale: CGFloat) -> CGPoint {
        let angle = (polar.deg + rotation) * .pi / 180
        return CGPoint(x: center.x + CGFloat(polar.r * cos(angle)) * scale,
                       y: center.y + CGFloat(polar.r * sin(angle)) * scale)
    }

    static func blade(rotation: Double, center: CGPoint, scale: CGFloat) -> Path {
        func p(_ polar: (r: Double, deg: Double)) -> CGPoint { point(polar, rotation: rotation, center: center, scale: scale) }
        var path = Path()
        path.move(to: p(base0))
        path.addCurve(to: p(tip), control1: p(control1), control2: p(control2))
        path.addCurve(to: p(base1), control1: p(control3), control2: p(control4))
        path.closeSubpath()
        return path
    }

    static func leadingEdge(rotation: Double, center: CGPoint, scale: CGFloat) -> Path {
        func p(_ polar: (r: Double, deg: Double)) -> CGPoint { point(polar, rotation: rotation, center: center, scale: scale) }
        var path = Path()
        path.move(to: p(base0))
        path.addCurve(to: p(tip), control1: p(control1), control2: p(control2))
        return path
    }
}

/// Static drawing of the turbine. Gaps between blades are transparent, so the
/// mark works on any background and in light or dark mode.
struct TurbineMark: View {
    var monochrome = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = side / 2 * 0.98
            let gap = max(1, scale * TurbineGeometry.gapWidth)
            let stops: [Gradient.Stop] = monochrome
                ? [.init(color: .primary.opacity(0.55), location: 0), .init(color: .primary, location: 1)]
                : [.init(color: NoriaColor.sky, location: 0), .init(color: NoriaColor.brightBlue, location: 0.35),
                   .init(color: NoriaColor.primaryBlue, location: 0.7), .init(color: NoriaColor.deepBlue, location: 1)]

            context.drawLayer { layer in
                for index in 0..<TurbineGeometry.bladeCount {
                    let rotation = Double(index) * 360 / Double(TurbineGeometry.bladeCount) - 90
                    let blade = TurbineGeometry.blade(rotation: rotation, center: center, scale: scale)
                    let edge = TurbineGeometry.leadingEdge(rotation: rotation, center: center, scale: scale)
                    // Cut a gap into the blades already drawn, then draw this blade on top.
                    layer.blendMode = .destinationOut
                    layer.stroke(edge, with: .color(.black), style: StrokeStyle(lineWidth: gap * 2, lineCap: .round, lineJoin: .round))
                    layer.fill(blade, with: .color(.black))
                    layer.blendMode = .normal
                    let start = TurbineGeometry.point((0.32, 25), rotation: rotation, center: center, scale: scale)
                    let end = TurbineGeometry.point(TurbineGeometry.tip, rotation: rotation, center: center, scale: scale)
                    layer.fill(blade, with: .linearGradient(Gradient(stops: stops), startPoint: start, endPoint: end))
                }
                let cut = scale * TurbineGeometry.hubGapRadius
                layer.blendMode = .destinationOut
                layer.fill(Path(ellipseIn: CGRect(x: center.x - cut, y: center.y - cut, width: cut * 2, height: cut * 2)), with: .color(.black))
                layer.blendMode = .normal
                let hub = scale * TurbineGeometry.hubRadius
                let hubRect = CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)
                let hubColors: [Color] = monochrome ? [.primary.opacity(0.6), .primary] : [NoriaColor.sky, NoriaColor.brightBlue, NoriaColor.primaryBlue]
                layer.fill(Path(ellipseIn: hubRect), with: .radialGradient(
                    Gradient(colors: hubColors),
                    center: CGPoint(x: center.x - hub * 0.3, y: center.y - hub * 0.3),
                    startRadius: 0, endRadius: hub * 1.6))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Integrates angular velocity so the turbine accelerates and decelerates smoothly.
/// Not observable on purpose: it is advanced from the timeline and never triggers renders.
final class TurbineSpin {
    private(set) var angle: Double = 0
    private var velocity: Double = 0
    private var lastDate: Date?

    func advance(to date: Date, target: Double) -> Double {
        let dt = min(1.0 / 15.0, max(0, date.timeIntervalSince(lastDate ?? date)))
        lastDate = date
        let timeConstant = target > velocity ? 0.6 : 0.9
        velocity += (target - velocity) * (1 - exp(-dt / timeConstant))
        if target == 0, velocity < 0.02 { velocity = 0 }
        angle = (angle + velocity * dt).truncatingRemainder(dividingBy: 2 * .pi)
        return angle
    }

    var isAtRest: Bool { velocity == 0 }
}

/// The animated turbine. It spins while `isSpinning` is true, eases to a stop
/// afterwards and is completely static when Reduce Motion is enabled. The
/// timeline is paused whenever the turbine is at rest, so it costs no CPU when idle.
struct TurbineView: View {
    var isSpinning: Bool
    /// Multiplier on the base speed; Noria uses up to ~1.4 while a scan is busy.
    var speed: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = TurbineSpin()
    @State private var timelineActive = false
    /// Incremented on every start so a pending stop from an earlier run is ignored.
    @State private var runGeneration = 0

    private let baseVelocity = 2.4 // radians per second

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !timelineActive || reduceMotion)) { timeline in
            TurbineMark()
                .rotationEffect(.radians(reduceMotion ? 0 : spin.advance(to: timeline.date, target: isSpinning ? baseVelocity * speed : 0)))
        }
        .onChange(of: isSpinning, initial: true) { _, spinning in
            runGeneration += 1
            if spinning {
                timelineActive = true
            } else {
                let generation = runGeneration
                Task { @MainActor in
                    // Long enough for the deceleration to finish, then stop the timeline.
                    try? await Task.sleep(for: .seconds(4))
                    if runGeneration == generation { timelineActive = false }
                }
            }
        }
    }
}

/// Turbine inside a progress ring. `progress == nil` shows an indeterminate ring.
struct TurbineProgressView: View {
    var isActive: Bool
    var progress: Double?
    var lineWidth: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(NoriaColor.subtleFill, lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, progress)))
                    .stroke(AngularGradient(colors: [NoriaColor.sky, NoriaColor.brightBlue, NoriaColor.primaryBlue], center: .center),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: progress)
            } else if isActive {
                IndeterminateArc(lineWidth: lineWidth)
            }
            TurbineView(isSpinning: isActive, speed: isActive ? 1.3 : 1)
                .padding(lineWidth * 3.2)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Scan progress"))
        .accessibilityValue(progress.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text(isActive ? LocalizedStringKey("In progress") : LocalizedStringKey("Idle")))
    }
}

private struct IndeterminateArc: View {
    var lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(NoriaColor.brightBlue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? -90 : phase * 360 - 90))
        }
    }
}

/// Logo lockup used in the sidebar: turbine + lowercase wordmark.
struct NoriaLogo: View {
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: NoriaSpacing.xs) {
            TurbineMark().frame(width: size, height: size)
            Text(verbatim: "noria")
                .font(NoriaFont.wordmark)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Noria"))
    }
}
