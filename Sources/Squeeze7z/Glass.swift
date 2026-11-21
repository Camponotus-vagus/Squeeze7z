import SwiftUI

/// Liquid Glass for the elements that float above the content: the stats bar, banners, toasts and
/// the drop hint. Tables, forms and other content never get glass.
///
/// With Reduce Transparency the element becomes an opaque panel, and with Increase Contrast it
/// gains an outline, so the text on it stays readable whatever lies underneath.
struct FloatingGlass<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let shape: S
    var tint: Color?

    func body(content: Content) -> some View {
        content.modifier(FloatingGlassSurface(shape: shape, tint: tint, reduceTransparency: reduceTransparency,
                                              increasedContrast: contrast == .increased))
    }
}

/// `FloatingGlass` with the accessibility settings spelled out, so each variant can be rendered on demand.
struct FloatingGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    let reduceTransparency: Bool
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background {
                    ZStack {
                        shape.fill(Color(nsColor: .windowBackgroundColor))
                        if let tint { shape.fill(tint.opacity(0.18)) }
                    }
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                }
            } else if let tint {
                content.glassEffect(.regular.tint(tint.opacity(0.28)), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        }
        .overlay {
            if increasedContrast {
                shape.strokeBorder(.primary.opacity(0.55), lineWidth: 1)
            } else if reduceTransparency {
                shape.strokeBorder(.separator, lineWidth: 1)
            }
        }
    }
}

extension View {
    func floatingGlass<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(FloatingGlass(shape: shape, tint: tint))
    }
}

/// How a job status is shown: wording, symbol and semantic colour.
struct StatusStyle: Equatable {
    let title: String
    let systemImage: String
    let color: Color

    static func finished(_ status: JobStatus) -> StatusStyle? {
        switch status {
        case .queued: StatusStyle(title: "Queued", systemImage: "clock", color: .gray)
        case .running: nil
        case .done: StatusStyle(title: "Optimized", systemImage: "checkmark.circle.fill", color: .green)
        case .noGain: StatusStyle(title: "No gain", systemImage: "equal.circle.fill", color: .gray)
        case .failed: StatusStyle(title: "Failed", systemImage: "exclamationmark.triangle.fill", color: .red)
        case .cancelled: StatusStyle(title: "Cancelled", systemImage: "slash.circle.fill", color: .orange)
        }
    }
}

/// A capsule with a coloured symbol and plain text. The colour carries the meaning but never the
/// text itself, so the label keeps its contrast in light and dark mode.
struct StatusBadge: View {
    @Environment(\.colorSchemeContrast) private var contrast

    let style: StatusStyle
    /// Replaces the standard wording, for example with an error message.
    var detail: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: style.systemImage)
                .foregroundStyle(style.color)
                .imageScale(.small)
            Text(detail ?? style.title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(style.color.opacity(contrast == .increased ? 0.26 : 0.15), in: Capsule())
        .overlay {
            if contrast == .increased {
                Capsule().strokeBorder(style.color, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
