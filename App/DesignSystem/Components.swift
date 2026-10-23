import NoriaCore
import SwiftUI

/// Rounded surface used for every dashboard block.
struct Card<Content: View>: View {
    var padding: CGFloat = NoriaSpacing.l
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoriaColor.cardBackground, in: RoundedRectangle(cornerRadius: NoriaRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NoriaRadius.card, style: .continuous).strokeBorder(NoriaColor.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

/// Section heading with an optional trailing accessory.
struct CardHeader<Accessory: View>: View {
    var title: LocalizedStringKey
    var systemImage: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: NoriaSpacing.xs) {
            Image(systemName: systemImage)
                .foregroundStyle(NoriaColor.accent)
            Text(title).font(NoriaFont.sectionTitle)
            Spacer()
            accessory
        }
    }
}

extension CardHeader where Accessory == EmptyView {
    init(title: LocalizedStringKey, systemImage: String) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

/// Prominent gradient button ("Analyze My Mac", "Clean").
struct PrimaryButtonStyle: ButtonStyle {
    /// Large, full-width call to action ("Analyze My Mac").
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: prominent ? 12 : 8, style: .continuous)
        return configuration.label
            .font(.system(size: prominent ? 19 : 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, NoriaSpacing.l)
            .padding(.vertical, prominent ? NoriaSpacing.m : NoriaSpacing.s - 2)
            .frame(maxWidth: prominent ? .infinity : nil)
            .background(shape.fill(NoriaColor.woodGradient))
            .shadow(color: NoriaColor.wood.opacity(prominent ? 0.3 : 0), radius: 8, y: 3)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .contentShape(shape)
    }
}

/// Secondary capsule button ("Cancel").
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, NoriaSpacing.l)
            .padding(.vertical, NoriaSpacing.xs + 2)
            .background(Capsule().fill(NoriaColor.subtleFill))
            .overlay(Capsule().strokeBorder(NoriaColor.separator))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// SAFE / REVIEW / PROTECTED badge.
struct RiskBadge: View {
    var risk: RiskLevel

    var body: some View {
        Text(risk.title)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(risk.color)
            .background(risk.color.opacity(0.14), in: Capsule())
            .accessibilityLabel(Text("Risk: \(risk.title)"))
    }
}

/// Label + big number.
struct MetricView: View {
    var title: LocalizedStringKey
    var value: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(NoriaFont.caption).foregroundStyle(.secondary)
            Text(value).font(NoriaFont.metric)
            if let caption {
                Text(caption).font(NoriaFont.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Horizontal capacity bar.
struct CapacityBar: View {
    var fraction: Double
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(NoriaColor.subtleFill)
                Capsule()
                    .fill(LinearGradient(colors: [NoriaColor.woodLight, NoriaColor.wood], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Small rounded icon tile used in category rows (as in the reference design).
struct CategoryIcon: View {
    var category: CleanCategory
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: category.systemImage)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(category.tint)
            .frame(width: size, height: size)
            .background(category.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Empty / informational state.
struct EmptyStateView: View {
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    var systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}
