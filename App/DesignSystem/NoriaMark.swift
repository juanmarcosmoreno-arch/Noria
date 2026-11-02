import SwiftUI

/// Geometry of the Noria mark: a five-blade water wheel turning around a hub,
/// with water flowing underneath. Coordinates are in units of the wheel radius,
/// centered on the hub, y pointing down; angles in degrees, clockwise from 12 o'clock.
/// Tools/make_app_icon.py draws the app icon from the same numbers.
enum NoriaMarkGeometry {
    static let blades = 5
    static let hubRadius = 0.24       // blades start here
    static let tipRadius = 0.90       // blades end here
    static let curl = 72.0            // how far a blade turns from hub to tip
    static let bladeWidth = 0.80      // maximum width of a blade
    static let lean = 0.62            // share of the width on the trailing side
    static let ringRadius = 0.31      // clear ring around the hub
    static let coreRadius = 0.17
    static let bladeGap = 0.05        // clear outline between overlapping blades
    static let waterGap = 0.08

    struct Wave {
        var midRadius: Double, thickness: Double, fromAngle: Double, toAngle: Double, lift: Double
    }
    static let water = Wave(midRadius: 0.86, thickness: 0.36, fromAngle: 256, toAngle: 74, lift: 0.10)
    static let crest = Wave(midRadius: 0.79, thickness: 0.15, fromAngle: 238, toAngle: 92, lift: 0.12)

    static func polar(_ radius: Double, _ degrees: Double) -> CGPoint {
        let angle = (degrees - 90) * .pi / 180
        return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
    }

    static func spine(_ phi: Double, _ t: Double) -> CGPoint {
        polar(hubRadius + (tipRadius - hubRadius) * t, phi + curl * pow(t, 1.15))
    }

    /// Outline of one blade around its curved spine, rounded at the tip.
    static func blade(phi: Double, width: Double = bladeWidth, lean: Double = lean, shift: Double = 0, samples: Int = 64) -> [CGPoint] {
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0...samples {
            let t = 1 - pow(1 - Double(i) / Double(samples), 2) // denser near the tip
            let p = spine(phi + shift, t)
            let a = spine(phi + shift, max(0, t - 0.001)), b = spine(phi + shift, min(1, t + 0.001))
            let length = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
            let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
            let h = width * (0.30 + 0.70 * pow(t, 0.8)) * sqrt(max(0, 1 - pow(t, 3.2)))
            left.append(CGPoint(x: p.x + normal.x * h * lean, y: p.y + normal.y * h * lean))
            right.append(CGPoint(x: p.x - normal.x * h * (1 - lean), y: p.y - normal.y * h * (1 - lean)))
        }
        return left + right.reversed()
    }

    /// Outer and inner edges of a tapered wave hugging the bottom of the wheel.
    static func wave(_ wave: Wave, samples: Int = 96) -> (outer: [CGPoint], inner: [CGPoint]) {
        var outer: [CGPoint] = [], inner: [CGPoint] = []
        for i in 0...samples {
            let u = Double(i) / Double(samples)
            let angle = wave.fromAngle + (wave.toAngle - wave.fromAngle) * u
            let r = wave.midRadius + wave.lift * u * u
            let h = wave.thickness * pow(sin(.pi * u), 0.7)
            outer.append(polar(r + h / 2, angle))
            inner.append(polar(r - h / 2, angle))
        }
        return (outer, inner)
    }

    /// Everything outside the water's outer edge, so no blade shows below the water.
    static func belowWater(samples: Int = 96) -> [CGPoint] {
        let edge = wave(water, samples: samples).outer
        let far = (0...samples).map { i -> CGPoint in
            polar(1.6, water.fromAngle + (water.toAngle - water.fromAngle) * Double(i) / Double(samples))
        }
        return edge + far.reversed()
    }
}

/// The Noria mark. `rotation` turns the wheel; the water stays put. Gaps are
/// transparent, so the mark works on any background.
struct NoriaMark: View {
    var rotation: Double = 0
    var showsWater = true
    var monochrome = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let unit = side * 0.44
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func path(_ points: [CGPoint]) -> Path {
                var path = Path()
                path.addLines(points.map { CGPoint(x: center.x + $0.x * unit, y: center.y + $0.y * unit) })
                path.closeSubpath()
                return path
            }
            func circle(_ radius: Double) -> Path {
                let r = radius * unit
                return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
            let start = CGPoint(x: center.x - unit, y: center.y - unit)
            let end = CGPoint(x: center.x + unit, y: center.y + unit)
            let water: GraphicsContext.Shading = monochrome ? .color(.primary)
                : .linearGradient(Gradient(colors: [Color(hex: 0x28AAEC), Color(hex: 0x0550A0)]), startPoint: start, endPoint: end)
            let foam: GraphicsContext.Shading = monochrome ? .color(.primary.opacity(0.55))
                : .linearGradient(Gradient(colors: [Color(hex: 0x96E1FA), Color(hex: 0x2496E1)]), startPoint: start, endPoint: end)
            let geometry = NoriaMarkGeometry.self

            context.drawLayer { layer in
                for index in 0..<geometry.blades {
                    let phi = rotation + Double(index) * 360 / Double(geometry.blades)
                    let blade = path(geometry.blade(phi: phi))
                    // Clear an outline around the blade so it reads apart from the one below.
                    layer.blendMode = .destinationOut
                    layer.fill(blade, with: .color(.black))
                    layer.stroke(blade, with: .color(.black), style: StrokeStyle(lineWidth: geometry.bladeGap * unit, lineJoin: .round))
                    layer.blendMode = .normal
                    layer.fill(blade, with: water)
                    layer.drawLayer { inner in
                        inner.clip(to: blade)
                        inner.fill(path(geometry.blade(phi: phi, width: geometry.bladeWidth * 0.62, lean: 1, shift: 3)), with: foam)
                    }
                }
                if showsWater {
                    let edges = geometry.wave(geometry.water)
                    let wave = path(edges.outer + edges.inner.reversed())
                    layer.blendMode = .destinationOut
                    layer.fill(path(geometry.belowWater()), with: .color(.black))
                    layer.fill(wave, with: .color(.black))
                    layer.stroke(wave, with: .color(.black), style: StrokeStyle(lineWidth: geometry.waterGap * unit, lineJoin: .round))
                    layer.blendMode = .normal
                    layer.fill(wave, with: water)
                    let crest = geometry.wave(geometry.crest)
                    layer.drawLayer { inner in
                        inner.clip(to: wave)
                        inner.fill(path(crest.outer + crest.inner.reversed()), with: foam)
                    }
                }
                layer.blendMode = .destinationOut
                layer.fill(circle(geometry.ringRadius), with: .color(.black))
                layer.blendMode = .normal
                layer.fill(circle(geometry.coreRadius), with: monochrome ? .color(.primary) : .color(Color(hex: 0x1C98E0)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Integrates angular velocity so the wheel speeds up and slows down smoothly.
/// Not observable on purpose: it is advanced from the timeline and never triggers renders.
final class WheelSpin {
    private(set) var angle: Double = 0
    private var velocity: Double = 0
    private var lastDate: Date?

    /// Returns the wheel angle in degrees.
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

/// The animated wheel. It turns while `isSpinning` is true, slows down afterwards
/// and is completely static when Reduce Motion is enabled. The timeline is paused
/// whenever the wheel is at rest, so it costs no CPU when idle.
struct WheelView: View {
    var isSpinning: Bool
    /// Multiplier on the base speed; Noria uses up to ~1.3 while a scan is busy.
    var speed: Double = 1
    var showsWater = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = WheelSpin()
    @State private var timelineActive = false
    /// Incremented on every start/stop so a pending stop from an earlier run is ignored.
    @State private var runGeneration = 0

    private let baseVelocity = 120.0 // degrees per second

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !timelineActive || reduceMotion)) { timeline in
            NoriaMark(rotation: reduceMotion ? 0 : spin.advance(to: timeline.date, target: isSpinning ? baseVelocity * speed : 0),
                      showsWater: showsWater)
        }
        .onChange(of: isSpinning, initial: true) { _, spinning in
            runGeneration += 1
            if spinning {
                timelineActive = true
            } else {
                let generation = runGeneration
                Task { @MainActor in
                    // Long enough for the wheel to come to rest, then stop the timeline.
                    try? await Task.sleep(for: .seconds(4))
                    if runGeneration == generation { timelineActive = false }
                }
            }
        }
    }
}

/// The wheel inside a progress ring. `progress == nil` shows an indeterminate ring.
struct WheelProgressView: View {
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
                        .stroke(AngularGradient(colors: [NoriaColor.foam, NoriaColor.sky, NoriaColor.ocean], center: .center),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: progress)
                } else if isActive {
                    IndeterminateArc(lineWidth: lineWidth)
                }
            }
            WheelView(isSpinning: isActive, speed: isActive ? 1.3 : 1)
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
                .stroke(NoriaColor.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? -90 : phase * 360 - 90))
        }
    }
}

/// Logo lockup: mark + lowercase wordmark, optionally with the tagline.
struct NoriaLogo: View {
    var size: CGFloat = 32
    var showsTagline = false

    var body: some View {
        HStack(spacing: NoriaSpacing.xs) {
            NoriaMark().frame(width: size, height: size)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "noria")
                    .font(.system(size: size * 0.72, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if showsTagline {
                    Text(verbatim: "MAKE SPACE.")
                        .font(NoriaFont.tagline)
                        .tracking(2.4)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Noria"))
    }
}
