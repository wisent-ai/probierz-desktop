import Combine
@preconcurrency import Foundation
import SwiftUI
import WisentOnboarding
import WisentDesignSystem

struct ProbierzOnboardingCard: View {
    let screen: JourneyScreen
    let isWorking: Bool
    let adoptionOutcome: WisentMutationOutcome
    let conflicts: [ProjectAdoptionConflict]
    let adoptionAccepted: Bool
    let action: () -> Void
    let skip: () -> Void
    let replace: () -> Void
    let dismissOutcome: () -> Void

    var body: some View {
        WisentPanel {
            VStack(alignment: .leading, spacing: WisentDesign.Space.x3) {
                HStack(alignment: .top, spacing: WisentDesign.Space.x4) {
                    Image(systemName: symbol)
                        .font(.system(size: WisentDesign.Space.x5, weight: .semibold))
                        .foregroundStyle(WisentDesign.brand)
                        .frame(width: WisentDesign.Space.x10, height: WisentDesign.Space.x10)
                        .background(
                            WisentDesign.brandSoft,
                            in: RoundedRectangle(cornerRadius: WisentDesign.Radius.medium)
                        )
                    VStack(alignment: .leading, spacing: WisentDesign.Space.x2) {
                        WisentBadge("Getting started", symbol: "sparkles", tone: .brand)
                        Text(title)
                            .font(WisentTypography.heading(18))
                            .foregroundStyle(WisentDesign.ink)
                        Text(bodyText)
                            .font(WisentTypography.body(13))
                            .foregroundStyle(WisentDesign.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: WisentDesign.Space.x4)
                    if isProjectImport {
                        VStack(alignment: .trailing, spacing: WisentDesign.Space.x2) {
                            WisentAction(actionLabel, kind: .primary, isBusy: isWorking, perform: action)
                                .asButton()
                            if !adoptionAccepted {
                                Button("Skip", action: skip)
                                    .buttonStyle(WisentSecondaryButtonStyle())
                                    .disabled(isWorking)
                            }
                        }
                    } else {
                        WisentAction(actionLabel, kind: .primary, isBusy: isWorking, perform: action)
                            .asButton()
                    }
                }
                if isProjectImport, adoptionOutcome != .idle {
                    WisentMutationBar(outcome: adoptionOutcome) { dismissOutcome() }
                }
                if isProjectImport, !conflicts.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: WisentDesign.Space.x1) {
                            ForEach(conflicts) { conflict in
                                Text("\(conflict.path) — \(conflict.reason)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(WisentDesign.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 112)
                    Button("Replace these reviewed definitions", action: replace)
                        .buttonStyle(WisentSecondaryButtonStyle())
                        .disabled(isWorking)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Probierz first-use journey")
    }

    private var isProjectImport: Bool {
        screen.screenId == "adopt-existing-project"
    }

    private var title: String {
        switch screen.titleKey {
        case "probierz.first_use.adopt.title":
            "Bring your existing project"
        case "probierz.first_use.read_only.title":
            "Review a run"
        case "probierz.first_use.provenance.title":
            "Check a result"
        case "probierz.first_use.inspect.title":
            "Open a result"
        default:
            screen.transitions.isEmpty ? "Open a result" : "Review results"
        }
    }

    private var bodyText: String {
        switch screen.bodyKey {
        case "probierz.first_use.adopt.body":
            "Adopt validated application manifests and specs without running them. Existing files stay unchanged unless you review conflicts and explicitly replace them."
        case "probierz.first_use.read_only.body":
            "See what happened and retry a failed run."
        case "probierz.first_use.provenance.body":
            "Each result shows when it ran and what it produced."
        case "probierz.first_use.inspect.body":
            "Open Artifacts and choose a result."
        default:
            screen.transitions.isEmpty
                ? "Choose a result to see its details."
                : "Continue to see how results are presented."
        }
    }

    private var actionLabel: String {
        if isProjectImport { return adoptionAccepted ? "Continue" : "Choose project" }
        return screen.transitions.isEmpty ? "Show results" : "Continue"
    }

    private var symbol: String {
        switch screen.titleKey {
        case "probierz.first_use.adopt.title": "square.and.arrow.down"
        case "probierz.first_use.read_only.title": "lock.open.display"
        case "probierz.first_use.provenance.title": "point.3.connected.trianglepath.dotted"
        default: "doc.text.magnifyingglass"
        }
    }
}
