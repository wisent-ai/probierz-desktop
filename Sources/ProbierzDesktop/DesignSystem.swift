import SwiftUI
import WisentDesignSystem

enum ProbierzLayout {
    static let minimumWindowWidth: CGFloat = 980
    static let minimumWindowHeight: CGFloat = 680
    static let inspectorWidth: CGFloat = 580
}

extension RunStatus {
    var wisentTone: WisentTone {
        switch self {
        case .passed: .success
        case .failed: .danger
        case .blocked: .warning
        case .canceled, .incomplete: .neutral
        }
    }
}

struct StatusBadge: View {
    let status: RunStatus

    var body: some View {
        WisentBadge(status.title, symbol: status.symbol, tone: status.wisentTone)
    }
}

struct AvailabilityBadge: View {
    let isAvailable: Bool
    let availableTitle: String
    let unavailableTitle: String

    var body: some View {
        WisentBadge(
            isAvailable ? availableTitle : unavailableTitle,
            symbol: isAvailable ? "checkmark.circle.fill" : "minus.circle.fill",
            tone: isAvailable ? .success : .warning
        )
    }
}

struct EmptyFilterView: View {
    let clear: () -> Void

    var body: some View {
        VStack(spacing: WisentDesign.Space.x4) {
            WisentEmptyState(
                title: "No matching metadata",
                detail: "Adjust the search or status filter to show local metadata.",
                symbol: "line.3.horizontal.decrease.circle"
            )
            Button("Clear Filters", action: clear)
                .buttonStyle(WisentSecondaryButtonStyle())
        }
    }
}
