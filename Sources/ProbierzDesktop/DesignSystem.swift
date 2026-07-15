import AppKit
import SwiftUI

enum ProbierzTheme {
    static let minimumWidth: CGFloat = 980
    static let minimumHeight: CGFloat = 680
    static let sidebarMinimumWidth: CGFloat = 210
    static let sidebarIdealWidth: CGFloat = 228
    static let contentMaximumWidth: CGFloat = 1_120

    enum Space {
        static let x1: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        static let x6: CGFloat = 24
        static let x8: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
    }

    static let accent = Color(nsColor: .systemOrange)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let raisedSurface = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let muted = Color(nsColor: .tertiaryLabelColor)
    static let success = Color(nsColor: .systemGreen)
    static let danger = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)
    static let inactive = Color(nsColor: .systemGray)

    static func color(for status: RunStatus) -> Color {
        switch status {
        case .passed: success
        case .failed: danger
        case .blocked: warning
        case .canceled, .incomplete: inactive
        }
    }
}

struct ProbierzPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(ProbierzTheme.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProbierzTheme.surface, in: RoundedRectangle(cornerRadius: ProbierzTheme.Radius.medium))
            .overlay {
                RoundedRectangle(cornerRadius: ProbierzTheme.Radius.medium)
                    .stroke(ProbierzTheme.border, lineWidth: 1)
            }
    }
}

struct StatusBadge: View {
    let status: RunStatus

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(ProbierzTheme.color(for: status))
            .padding(.horizontal, ProbierzTheme.Space.x2)
            .padding(.vertical, ProbierzTheme.Space.x1)
            .background(ProbierzTheme.color(for: status).opacity(0.1), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct AvailabilityBadge: View {
    let isAvailable: Bool
    let availableTitle: String
    let unavailableTitle: String

    var body: some View {
        Label(
            isAvailable ? availableTitle : unavailableTitle,
            systemImage: isAvailable ? "checkmark.circle.fill" : "minus.circle.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(isAvailable ? ProbierzTheme.success : ProbierzTheme.warning)
        .accessibilityElement(children: .combine)
    }
}

struct SectionHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: ProbierzTheme.Space.x1) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(ProbierzTheme.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EmptyFilterView: View {
    let clear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No matching metadata", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Adjust the search or status filter to show local metadata.")
        } actions: {
            Button("Clear Filters", action: clear)
                .buttonStyle(.borderedProminent)
        }
    }
}
