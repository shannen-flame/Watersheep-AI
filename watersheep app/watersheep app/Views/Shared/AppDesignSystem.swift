import SwiftUI

struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.black,
                Color(red: 0.05, green: 0.08, blue: 0.13),
                Color(red: 0.03, green: 0.13, blue: 0.16),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct GlassCard<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [Color.white.opacity(0.11), Color.white.opacity(0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
    }
}

struct StatusChip: View {
    enum Tone {
        case neutral
        case success
        case warning
        case danger

        var color: Color {
            switch self {
            case .neutral: return .white
            case .success: return .green
            case .warning: return .orange
            case .danger: return .red
            }
        }
    }

    let title: String
    let tone: Tone

    init(_ title: String, tone: Tone = .neutral) {
        self.title = title
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tone.color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}

struct FloatingActionButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(title)
                    .fontWeight(.semibold)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: isEnabled ? [.cyan, .blue] : [.gray, .gray.opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

struct DebugPanel<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    init(title: String = "Debug", isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    content
                }
            }
        }
    }
}

struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.45))
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.88))
                .textSelection(.enabled)
        }
    }
}
