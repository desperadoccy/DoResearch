import SwiftUI

extension LinkCondition {
    var tint: Color {
        switch self {
        case .always: Color.secondary
        case .good: Color.green
        case .bad: Color.red
        }
    }

    var symbol: String {
        switch self {
        case .always: "arrow.right"
        case .good: "checkmark"
        case .bad: "xmark"
        }
    }
}

/// The handle at a link's midpoint. A plain link shows only a small dot until hovered; a conditional link shows a
/// solid ✓ or ✗ disc; a loop shows the loop glyph. Hovering grows it a little to show it can be clicked.
struct LinkBadge: View {
    var link: ChecklistLink
    var hot = false
    /// Faded when the step it leaves is done and took the other branch.
    var faded = false

    private var quiet: Bool { link.condition == .always && !link.loop && !hot }

    var body: some View {
        ZStack {
            if quiet {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1))
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(fill)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(hot ? 0.25 : 0.12), radius: hot ? 3 : 1.5, y: 0.5)
                    .frame(width: 16, height: 16)
                Image(systemName: glyph)
                    .font(.system(size: link.loop && link.condition == .always ? 8 : 7.5, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(Circle())
        .scaleEffect(hot ? 1.15 : 1)
        .opacity(faded ? 0.4 : 1)
        .animation(.easeOut(duration: 0.12), value: hot)
    }

    private var glyph: String {
        if link.condition == .always { return link.loop ? "arrow.counterclockwise" : "ellipsis" }
        return link.condition.symbol
    }

    private var fill: Color {
        switch link.condition {
        case .always: link.loop ? Color.purple.opacity(0.85) : Color.secondary
        case .good: Color.green
        case .bad: Color.red
        }
    }
}

/// Popover for one link: when it is followed, and removing it.
struct LinkEditor: View {
    var fromTitle: String
    var toTitle: String
    var link: ChecklistLink
    var onCondition: (LinkCondition) -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if link.loop { Image(systemName: "arrow.counterclockwise").foregroundStyle(.purple) }
                Text(fromTitle).lineLimit(1)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Text(toTitle).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 260, alignment: .leading)

            VStack(spacing: 2) {
                ForEach(LinkCondition.allCases, id: \.self) { c in
                    Button { onCondition(c) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: c.symbol)
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(c == .always ? Color.secondary : c.tint))
                            Text(c.label)
                            Spacer()
                            if link.condition == c { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 6).fill(link.condition == c ? Color.accentColor.opacity(0.12) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            Button(role: .destructive, action: onRemove) {
                Label("Remove Link", systemImage: "trash")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 240)
    }
}
