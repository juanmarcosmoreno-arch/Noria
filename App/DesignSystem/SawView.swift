import SwiftUI

/// Geometry of the Noria mark: a twelve-tooth circular saw blade cutting a wood
/// shaving, with a few chips flying off. Coordinates are polar (radius relative
/// to the blade's outer radius; angle in degrees, clockwise from 12 o'clock).
/// The app icon is the brand artwork (Design/noria-icon-source.webp); this
/// vector version is used inside the app, where the blade has to spin.
enum SawGeometry {
    static let teeth = 12
    // One tooth, starting at a gullet: curved back up to the tip, a hooked face,
    // then a rounded gullet into the next tooth.
    static let base = (r: 0.78, deg: 0.0)
    static let backControl = (r: 0.97, deg: 8.0)
    static let tip = (r: 1.0, deg: 21.0)
    static let face = (r: 0.83, deg: 23.0)
    static let gulletControl = (r: 0.70, deg: 27.0)

    static let discRadius = 0.60
    static let collarRadius = 0.26
    static let boreRadius = 0.15

    /// Layout inside the mark's square: blade center and blade radius (fractions of the side).
    static let center = CGPoint(x: 0.48, y: 0.48)
    static let scale = 0.34

    static func point(_ polar: (r: Double, deg: Double), rotation: Double, center: CGPoint, scale: CGFloat) -> CGPoint {
        let angle = (polar.deg + rotation - 90) * .pi / 180
        return CGPoint(x: center.x + CGFloat(polar.r * cos(angle)) * scale,
                       y: center.y + CGFloat(polar.r * sin(angle)) * scale)
    }

    static func blade(rotation: Double, center: CGPoint, scale: CGFloat) -> Path {
        var path = Path()
        let span = 360.0 / Double(teeth)
        for index in 0..<teeth {
            let offset = rotation + Double(index) * span
            func p(_ polar: (r: Double, deg: Double)) -> CGPoint { point(polar, rotation: offset, center: center, scale: scale) }
            if index == 0 { path.move(to: p(base)) }
            path.addQuadCurve(to: p(tip), control: p(backControl))
            path.addLine(to: p(face))
            path.addQuadCurve(to: p((base.r, span)), control: p(gulletControl))
        }
        path.closeSubpath()
        return path
    }

    /// Crescent-shaped shaving around the lower left of the blade.
    static func shaving(center: CGPoint, scale: CGFloat) -> Path {
        var outer: [CGPoint] = []
        var inner: [CGPoint] = []
        let steps = 48
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let angle = 140 + t * 150
            let radius = 1.10 + 0.10 * sin(.pi * t)
            let thickness = 0.16 * pow(sin(.pi * t), 0.8)
            outer.append(point((radius + thickness / 2, angle), rotation: 0, center: center, scale: scale))
            inner.append(point((radius - thickness / 2, angle), rotation: 0, center: center, scale: scale))
        }
        var path = Path()
        path.addLines(outer + inner.reversed())
        path.closeSubpath()
        return path
    }

    static let chips: [[(r: Double, deg: Double)]] = [
        [(1.10, 66), (1.26, 72), (1.14, 78)],
        [(1.12, 94), (1.30, 100), (1.16, 107)],
        [(1.10, 121), (1.24, 128), (1.10, 133)],
        [(1.32, 112), (1.38, 116), (1.31, 119)],
    ]

    static func chip(_ corners: [(r: Double, deg: Double)], center: CGPoint, scale: CGFloat) -> Path {
        var path = Path()
        path.addLines(corners.map { point($0, rotation: 0, center: center, scale: scale) })
        path.closeSubpath()
        return path
    }
}

/// The Noria mark. `rotation` turns only the blade; the shaving and chips stay put.
struct SawMark: View {
    var rotation: Double = 0
    var showsShavings = true
    var monochrome = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            let center = CGPoint(x: origin.x + side * SawGeometry.center.x, y: origin.y + side * SawGeometry.center.y)
            let scale = side * SawGeometry.scale

            if showsShavings {
                let shaving = SawGeometry.shaving(center: center, scale: scale)
                let bounds = shaving.boundingRect
                context.fill(shaving, with: monochrome
                    ? .color(.secondary)
                    : .linearGradient(Gradient(colors: [NoriaColor.woodLight, NoriaColor.wood, NoriaColor.woodDark]),
                                      startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
                                      endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
                for corners in SawGeometry.chips {
                    context.fill(SawGeometry.chip(corners, center: center, scale: scale),
                                 with: .color(monochrome ? .secondary : NoriaColor.wood))
                }
            }

            context.drawLayer { layer in
                let blade = SawGeometry.blade(rotation: rotation, center: center, scale: scale)
                let top = CGPoint(x: center.x, y: center.y - scale)
                let bottom = CGPoint(x: center.x, y: center.y + scale)
                layer.fill(blade, with: monochrome
                    ? .color(.primary)
                    : .linearGradient(Gradient(colors: [NoriaColor.steelMid, NoriaColor.steelDark]), startPoint: top, endPoint: bottom))

                func circle(_ radius: Double) -> Path {
                    let r = scale * radius
                    return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                }
                // Brushed-steel disc: a conic gradient that turns with the blade.
                let brushed = Gradient(colors: [NoriaColor.steelLight, NoriaColor.steel, NoriaColor.steelLight,
                                                NoriaColor.steel, NoriaColor.steelLight])
                layer.fill(circle(SawGeometry.discRadius), with: monochrome
                    ? .color(.secondary)
                    : .conicGradient(brushed, center: center, angle: .degrees(rotation)))
                layer.fill(circle(SawGeometry.collarRadius), with: .color(monochrome ? .primary : NoriaColor.steelDark))
                layer.blendMode = .destinationOut
                layer.fill(circle(SawGeometry.boreRadius), with: .color(.black))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Integrates angular velocity so the blade spins up and winds down smoothly.
/// Not observable on purpose: it is advanced from the timeline and never triggers renders.
final class SawSpin {
    private(set) var angle: Double = 0
    private var velocity: Double = 0
    private var lastDate: Date?

    /// Returns the blade angle in degrees.
    func advance(to date: Date, target: Double) -> Double {
        let dt = min(1.0 / 15.0, max(0, date.timeIntervalSince(lastDate ?? date)))
        lastDate = date
        let timeConstant = target > velocity ? 0.6 : 0.9
        velocity += (target - velocity) * (1 - exp(-dt / timeConstant))
        if target == 0, velocity < 1 { velocity = 0 }
        angle = (angle + velocity * dt).truncatingRemainder(dividingBy: 360)
        return angle
    }
}

/// The animated saw. It spins while `isSpinning` is true, winds down afterwards
/// and is completely static when Reduce Motion is enabled. The timeline is paused
/// whenever the blade is at rest, so it costs no CPU when idle.
struct SawView: View {
    var isSpinning: Bool
    /// Multiplier on the base speed; Noria uses up to ~1.3 while a scan is busy.
    var speed: Double = 1
    var showsShavings = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = SawSpin()
    @State private var timelineActive = false
    /// Incremented on every start/stop so a pending stop from an earlier run is ignored.
    @State private var runGeneration = 0

    private let baseVelocity = 140.0 // degrees per second

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !timelineActive || reduceMotion)) { timeline in
            SawMark(rotation: reduceMotion ? 0 : spin.advance(to: timeline.date, target: isSpinning ? baseVelocity * speed : 0),
                    showsShavings: showsShavings)
        }
        .onChange(of: isSpinning, initial: true) { _, spinning in
            runGeneration += 1
            if spinning {
                timelineActive = true
            } else {
                let generation = runGeneration
                Task { @MainActor in
                    // Long enough for the wind-down to finish, then stop the timeline.
                    try? await Task.sleep(for: .seconds(4))
                    if runGeneration == generation { timelineActive = false }
                }
            }
        }
    }
}

/// Saw inside a progress ring. `progress == nil` shows an indeterminate ring.
struct SawProgressView: View {
    var isActive: Bool
    var progress: Double?
    var lineWidth: CGFloat = 8
    var showsRing = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if showsRing {
                Circle()
                    .stroke(NoriaColor.subtleFill, lineWidth: lineWidth)
                if let progress {
                    Circle()
                        .trim(from: 0, to: max(0.001, min(1, progress)))
                        .stroke(AngularGradient(colors: [NoriaColor.woodLight, NoriaColor.wood, NoriaColor.woodDark], center: .center),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: progress)
                } else if isActive {
                    IndeterminateArc(lineWidth: lineWidth)
                }
            }
            SawView(isSpinning: isActive, speed: isActive ? 1.3 : 1)
                .padding(showsRing ? lineWidth * 3 : 0)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Scan progress"))
        .accessibilityValue(progress.map { Text($0, format: .percent.precision(.fractionLength(0))) }
            ?? Text(isActive ? LocalizedStringKey("In progress") : LocalizedStringKey("Idle")))
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
                .stroke(NoriaColor.wood, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? -90 : phase * 360 - 90))
        }
    }
}

/// Logo lockup used in the sidebar: saw mark + lowercase wordmark.
struct NoriaLogo: View {
    var size: CGFloat = 32

    var body: some View {
        HStack(spacing: NoriaSpacing.xs) {
            SawMark().frame(width: size, height: size)
            Text(verbatim: "noria")
                .font(NoriaFont.wordmark)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Noria"))
    }
}
