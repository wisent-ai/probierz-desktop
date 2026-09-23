import SwiftUI
import WisentDesignSystem

/// Journeys as Probierz means them: the named user paths a run covers.
///
/// The baseline had no idea journeys existed — its run table was flat and
/// carried neither the journey names in `appManifest.journeys` nor the ones
/// declared in `probierz/apps`. A journey with no evidence at all could not be
/// seen anywhere in the application.
struct JourneysView: View {
    @ObservedObject var model: ProbierzModel

    var body: some View {
        let visible = model.visibleJourneys

        return WisentScreen(
            title: "Journeys",
            scope: model.scopeLabel,
            freshness: model.freshnessLabel,
            actions: [
                WisentAction(
                    "Refresh",
                    symbol: "arrow.clockwise",
                    kind: .secondary,
                    isEnabled: model.workspaceRoot != nil,
                    isBusy: model.isRefreshing
                ) {
                    Task { await model.refresh() }
                }
            ],
            scrolls: false,
            constrainsWidth: false
        ) {
            HStack(spacing: 0) {
                WisentFacetRail(
                    groups: facetGroups,
                    footerTitle: "Selection",
                    footerDetail: "\(visible.count.formatted(.number)) of \(model.journeys.count.formatted(.number)) journeys"
                )
                centre(visible: visible)
                inspector
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search journey or product")
    }

    private var facetGroups: [WisentFacetGroup] {
        let noEvidence = model.journeys.lazy.filter { $0.runCount == 0 || $0.bestEvidenceLevel == nil }.count
        let attention = model.journeys.lazy.filter { $0.latestStatus?.needsAttention ?? true }.count
        let recorded = model.journeys.lazy.filter { $0.bestEvidenceLevel == .e3 }.count
        return [
            WisentFacetGroup(
                "Coverage",
                facets: ProbierzModel.JourneyFilter.allCases.map { filter in
                    let count = switch filter {
                    case .all: model.journeys.count
                    case .noEvidence: noEvidence
                    case .needsAttention: attention
                    case .recorded: recorded
                    }
                    return WisentFacet(
                        id: "journey.\(filter.rawValue)",
                        label: filter.title,
                        count: count,
                        tone: (filter == .noEvidence && noEvidence > 0) ? .warning : .neutral,
                        isSelected: model.journeyFilter == filter
                    ) {
                        model.journeyFilter = filter
                    }
                }
            )
        ]
    }

    @ViewBuilder
    private func centre(visible: [JourneyRecord]) -> some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
            ProbierzSnapshotGate(
                model: model,
                readingLabel: "Loading journeys",
                // Six columns and a header, like the journeys table below.
                readingShape: .table(columns: 6)
            ) {
                if model.journeys.isEmpty {
                    WisentEmptyPanel(
                        title: "No journey declared or recorded",
                        detail: "No journey is available for \(model.scopeLabel.lowercased()).",
                        symbol: "point.topleft.down.curvedto.point.bottomright.up"
                    )
                    Spacer(minLength: 0)
                } else if visible.isEmpty {
                    WisentEmptyPanel(
                        title: "No journey matches this selection",
                        detail: "The scope holds \(model.journeys.count.formatted(.number)) journeys. The facet and search term in force exclude every one of them.",
                        symbol: "line.3.horizontal.decrease.circle",
                        action: WisentAction("Clear filters", kind: .secondary) {
                            model.journeyFilter = .all
                            model.query = ""
                        }
                    )
                    Spacer(minLength: 0)
                } else {
                    table(visible: visible)
                }
            }
        }
        .padding(WisentDesign.Space.x5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func table(visible: [JourneyRecord]) -> some View {
        WisentTableFrame {
            Table(visible, selection: $model.selectedJourneyID) {
                TableColumn("JOURNEY") { journey in
                    Text(journey.name)
                        .font(WisentTypeScale.identifier())
                        .foregroundStyle(WisentDesign.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(journey.name)
                        .denseRow()
                }
                .width(min: 140, ideal: 176)
                TableColumn("PRODUCT") { journey in
                    Text(journey.appID)
                        .font(WisentTypeScale.body())
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                }
                .width(min: 70, ideal: 88)
                TableColumn("RUNS") { journey in
                    Text(journey.runCount.formatted(.number))
                        .font(WisentTypeScale.identifierSmall())
                        .monospacedDigit()
                        .foregroundStyle(WisentDesign.secondary)
                }
                .width(38)
                TableColumn("PASS") { journey in
                    Text(ProbierzFormat.percent(journey.passRate))
                        .font(WisentTypeScale.identifierSmall())
                        .monospacedDigit()
                        .foregroundStyle(WisentDesign.secondary)
                }
                .width(44)
                TableColumn("BEST") { journey in
                    if let level = journey.bestEvidenceLevel {
                        EvidenceLevelCell(level: level)
                    } else {
                        WisentStatusChip(text: "None", tone: .warning)
                    }
                }
                .width(min: 44, ideal: 56)
                TableColumn("LAST") { journey in
                    Text(ProbierzFormat.shortTimestamp(journey.latestStartedAt))
                        .font(WisentTypeScale.identifierSmall())
                        .monospacedDigit()
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                }
                .width(min: 76, ideal: 88)
            }
            .tableStyle(.inset)
            .accessibilityLabel("Probierz journeys")
            // A click in this table already means "select this journey" and a
            // drag means "extend that selection", so selectable cell text would
            // compete with both. The index opts out of the window's selection
            // rule; the inspector beside it states the same values selectably.
            .textSelection(.disabled)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let journey = model.selectedJourney {
            WisentInspector(
                eyebrow: "Journey coverage",
                title: journey.name,
                badges: badges(for: journey)
            ) {
                if journey.runCount == 0 {
                    WisentAlertPanel(
                        tone: .warning,
                        title: "This journey has no evidence",
                        detail: "No recorded run covers this journey. A merge decision needs evidence."
                    )
                }
                WisentField(label: "Product", value: journey.appID)
                if let purpose = journey.purpose {
                    WisentField(label: "Declared purpose", value: purpose)
                }
                if let owner = journey.owner {
                    WisentField(label: "Declared owner", value: owner)
                }
                WisentField(label: "Runs recorded", value: journey.runCount.formatted(.number))
                WisentField(
                    label: "Verdict spread",
                    value: [
                        "passed \(journey.passed)",
                        "failed \(journey.failed)",
                        "blocked \(journey.blocked)",
                        "canceled \(journey.canceled)",
                        "incomplete \(journey.incomplete)",
                    ].joined(separator: "\n")
                )
                WisentField(label: "Pass rate", value: ProbierzFormat.percent(journey.passRate))
                if let best = journey.bestEvidenceLevel {
                    WisentField(label: "Best result", value: "\(best.title) — \(best.detail)", tone: best.tone)
                }
                if let status = journey.latestStatus {
                    WisentField(label: "Last verdict", value: status.title, tone: status.tone)
                }
                WisentField(label: "Last run started", value: ProbierzFormat.timestamp(journey.latestStartedAt))
                if let runID = journey.latestRunID {
                    WisentField(label: "Last run id", value: runID)
                    WisentAction("Open Run", symbol: "list.bullet.rectangle", kind: .secondary) {
                        model.selectedRunID = runID
                        model.destination = .runs
                    }
                    .asButton()
                }
                WisentAction("Open Verdict", symbol: "checkmark.seal", kind: .secondary) {
                    model.selectedVerdictID = journey.id
                    model.destination = .verdicts
                }
                .asButton()
            }
        } else {
            WisentInspector(eyebrow: "Journey coverage", title: "No journey selected") {
                Text("Select a journey to read how many runs cover it, how they ended, the strongest evidence it has reached and its last run.")
                    .font(WisentTypeScale.body())
                    .foregroundStyle(WisentDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func badges(for journey: JourneyRecord) -> [(String, WisentTone)] {
        var badges: [(String, WisentTone)] = []
        if let status = journey.latestStatus {
            badges.append((status.title, status.tone))
        } else {
            badges.append(("No evidence", .warning))
        }
        if let best = journey.bestEvidenceLevel { badges.append((best.title, best.tone)) }
        return badges
    }
}
