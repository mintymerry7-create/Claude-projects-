import SwiftUI
import OpeningDatabase
import Learning

// MARK: - Card

struct CardModifier: ViewModifier {
    var padding: CGFloat = KA.Spacing.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KA.Palette.surface, in: RoundedRectangle(cornerRadius: KA.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: KA.Radius.card, style: .continuous).stroke(KA.Palette.stroke, lineWidth: 0.5))
    }
}

extension View {
    func card(padding: CGFloat = KA.Spacing.l) -> some View { modifier(CardModifier(padding: padding)) }

    /// Standard screen background.
    func screenBackground() -> some View {
        background(KA.Palette.background.ignoresSafeArea())
    }
}

// MARK: - Headers

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.medium))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Progress

struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 6
    var showsLabel = true

    var body: some View {
        ZStack {
            Circle().stroke(KA.Palette.accent.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(KA.Palette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: progress)
            if showsLabel {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .minimumScaleFactor(0.6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var symbol: String?
    var tint: Color = KA.Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint).font(.headline)
            }
            Text(value).font(.title2.weight(.bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(KA.Palette.textSecondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: KA.Spacing.m)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tags

struct Tag: View {
    let text: String
    var tint: Color = KA.Palette.accent

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

extension Difficulty {
    var tint: Color {
        switch self {
        case .beginner: return KA.Palette.accent
        case .intermediate: return KA.Palette.info
        case .advanced: return KA.Palette.warning
        }
    }
}

extension CardStatus {
    var tint: Color {
        switch self {
        case .new: return KA.Palette.textSecondary
        case .learning: return KA.Palette.info
        case .reviewing: return KA.Palette.warning
        case .mastered: return KA.Palette.accent
        }
    }
}

struct SideBadge: View {
    let isWhite: Bool

    var body: some View {
        Circle()
            .fill(isWhite ? Color.white : Color.black)
            .overlay(Circle().stroke(KA.Palette.stroke, lineWidth: 1))
            .frame(width: 12, height: 12)
            .accessibilityLabel(isWhite ? "White" : "Black")
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(KA.Palette.accent.opacity(isEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(KA.Palette.accent)
            .background(KA.Palette.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// Compact icon + label button used in board toolbars.
struct ToolButton: View {
    let title: String
    let symbol: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? KA.Palette.danger : Color.primary)
        .accessibilityLabel(title)
    }
}

// MARK: - Feedback banner

struct FeedbackBanner: View {
    enum Kind { case success, error, info, warning }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.headline)
            Text(text).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch kind {
        case .success: return KA.Palette.accent
        case .error: return KA.Palette.danger
        case .info: return KA.Palette.info
        case .warning: return KA.Palette.warning
        }
    }

    private var symbol: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "lightbulb.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

/// A bulleted list section used on opening pages.
struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(KA.Palette.accent).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(item).font(.body).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Chip used for filters and option pickers.
struct ChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? KA.Palette.accent : KA.Palette.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
