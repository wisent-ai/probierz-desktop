import SwiftUI
import WisentDesignSystem

/// Merge eligibility per journey: the evidence level of its last run against
/// the floor its product declares.
///
/// The baseline had no surface for this at all — evidence levels, blocking
/// reasons and the E-scale existed only in the CLI. Every sentence in
/// `blockingReasons` is `probierz status`' own phrasing, reproduced from the
/// same manifest facts.
struct VerdictsView: View {
    @ObservedObject var model: ProbierzModel

    var body: some View {
        let visible = model.visibleVerdicts

        return WisentScreen(
            title: "Verdicts",
            scope: model.scopeLabel,
            freshness: model.freshnessLabel,
            actions: [
                WisentAction(
                    "Refresh",
                    symbol: "arrow.clockwise",
                    kind: .secondary,
                    isEnabled: !model.isRefreshing && model.workspaceRoot != nil
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
                    footerTitle: "Freshness",
                    footerDetail: "HEAD comparison needs git and is not run here"
                )
                centre(visible: visible)
                inspector
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search journey or product")
    }

    private var facetGroups: [WisentFacetGroup] {
        let blocking = model.blockingVerdicts.count
        return [
            WisentFacetGroup(
                "Eligibility",
                facets: ProbierzModel.VerdictFilter.allCases.map { filter in
                    let count = switch filter {
                    case .all: model.verdicts.count
                    case .blocking: blocking
                    case .eligible: model.verdicts.count - blocking
                    }
                    return WisentFacet(
                        id: "verdict.\(filter.rawValue)",
                        label: filter.title,
                        count: count,
                        tone: filter == .blocking && blocking > 0 ? .warning : .neutral,
                        isSelected: model.verdictFilter == filter
                    ) {
                        model.verdictFilter = filter
                    }
                }
            )
        ]
    }

    @ViewBuilder
    private func centre(visible: [VerdictRecord]) -> some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
            ProbierzSnapshotGate(
                model: model,
                readingTitle: "Reading merge eligibility",
                readingDetail: "Composing declared journeys from probierz/apps with the newest run manifest that covers each."
            ) {
                if model.verdicts.isEmpty {
                    WisentEmptyPanel(
                        title: "No journey declared or recorded",
                        detail: "A verdict needs a journey. None is declared in probierz/apps for \(model.scopeLabel.lowercased()), and no run manifest names one.",
                        symbol: "checkmark.seal"
                    )
                    Spacer(minLength: 0)
                } else if visible.isEmpty {
                    WisentEmptyPanel(
                        title: "No journey matches this selection",
                        detail: "The scope holds \(model.verdicts.count.formatted(.number)) journeys. The facet and search term in force exclude every one of them.",
                        symbol: "line.3.horizontal.decrease.circle",
                        action: WisentAction("Clear filters", kind: .secondary) {
                            model.verdictFilter = .all
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

    private func table(visible: [VerdictRecord]) -> some View {
        WisentTableFrame {
            Table(visible, selection: $model.selectedVerdictID) {
                TableColumn("JOURNEY") { verdict in
                    Text(verdict.journey)
                        .font(WisentTypeScale.identifier())
                        .foregroundStyle(WisentDesign.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(verdict.journey)
                        .denseRow()
                }
                .width(min: 140, ideal: 176)
                TableColumn("PRODUCT") { verdict in
                    Text(verdict.appID)
                        .font(WisentTypeScale.body())
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                }
                .width(min: 70, ideal: 88)
                TableColumn("LVL") { verdict in
                    if let level = verdict.latestEvidenceLevel {
                        EvidenceLevelCell(level: level)
                    } else {
                        Text("—")
                            .font(WisentTypeScale.identifierSmall())
                            .foregroundStyle(WisentDesign.muted)
                    }
                }
                .width(30)
                TableColumn("FLOOR") { verdict in
                    Text(verdict.minimumEvidence.title)
                        .font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(WisentDesign.muted)
                }
                .width(38)
                TableColumn("VERDICT") { verdict in
                    if verdict.isBlocking {
                        WisentStatusChip(text: "Blocking", tone: .warning)
                    } else {
                        Text("Eligible")
                            .font(WisentTypeScale.body())
                            .foregroundStyle(WisentDesign.secondary)
                    }
                }
                .width(min: 68, ideal: 80)
                TableColumn("LAST RUN") { verdict in
                    Text(ProbierzFormat.shortTimestamp(verdict.latestStartedAt))
                        .font(WisentTypeScale.identifierSmall())
                        .monospacedDigit()
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                }
                .width(min: 76, ideal: 88)
            }
            .tableStyle(.inset)
            .accessibilityLabel("Probierz merge verdicts")
            // A click in this table already means "select this verdict" and a
            // drag means "extend that selection", so selectable cell text would
            // compete with both. The index opts out of the window's selection
            // rule; the inspector beside it states the same values selectably.
            .textSelection(.disabled)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let verdict = model.selectedVerdict {
            WisentInspector(
                eyebrow: "Merge eligibility",
                title: verdict.journey,
                badges: [
                    verdict.isBlocking ? ("Blocking", WisentTone.warning) : ("Eligible", WisentTone.success),
                    (verdict.minimumEvidence.title + " floor", WisentTone.neutral),
                ]
            ) {
                if verdict.isBlocking {
                    WisentAlertPanel(
                        tone: .warning,
                        title: "This journey would block a merge",
                        detail: verdict.blockingReasons.joined(separator: "\n")
                    )
                }
                WisentField(label: "Product", value: verdict.appID)
                WisentField(
                    label: "Evidence floor",
                    value: "\(verdict.minimumEvidence.title) — \(verdict.minimumEvidence.detail)"
                )
                if let level = verdict.latestEvidenceLevel {
                    WisentField(
                        label: "Evidence of the last run",
                        value: "\(level.title) — \(level.detail)",
                        tone: level.tone
                    )
                }
                if let status = verdict.latestStatus {
                    WisentField(label: "Last verdict", value: status.title, tone: status.tone)
                }
                WisentField(label: "Last run started", value: ProbierzFormat.timestamp(verdict.latestStartedAt))
                if let runID = verdict.latestRunID {
                    WisentField(label: "Last run id", value: runID)
                }
                ForEach(verdict.recordedSources) { repository in
                    WisentField(
                        label: "Recorded source \(repository.name)",
                        value: repository.isDirty
                            ? "\(repository.gitSHA ?? "Not recorded") (dirty worktree)"
                            : (repository.gitSHA ?? "Not recorded"),
                        tone: repository.isDirty ? .warning : .neutral
                    )
                }
                if verdict.headFreshnessUnknown {
                    WisentField(
                        label: "Freshness against HEAD",
                        value: "Not evaluated here. The commit above is what the run recorded; comparing it to HEAD needs git, which this viewer does not run. probierz status \(verdict.appID) is authoritative."
                    )
                }
                if let runID = verdict.latestRunID {
                    WisentAction("Open Run", symbol: "list.bullet.rectangle", kind: .secondary) {
                        model.selectedRunID = runID
                        model.destination = .runs
                    }
                    .asButton()
                }
            }
        } else {
            WisentInspector(eyebrow: "Merge eligibility", title: "No journey selected") {
                Text("Select a journey to read its evidence floor, the level its last run reached, and the reasons that would block a merge.")
                    .font(WisentTypeScale.body())
                    .foregroundStyle(WisentDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
