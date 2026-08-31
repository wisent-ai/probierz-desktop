import SwiftUI
import WisentDesignSystem

/// Run history as a data screen: facets with counts, a dense table, and the
/// selected run's full provenance beside it.
///
/// The baseline had no selection at all — a run's verdict was a badge in a
/// 96 pt column and nothing else, and the loader never decoded the manifest's
/// reason fields, so a failure had no reason to show. The inspector here reads
/// them: `evidence.errors`, `reportValidation.error`, `setupError`,
/// `spawnFailure`, `resourceLock` and `preflight`, each verbatim.
struct RunsView: View {
    @ObservedObject var model: ProbierzModel

    var body: some View {
        let visible = model.visibleRuns

        return WisentScreen(
            title: "Runs",
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
            VStack(spacing: 0) {
                if model.repairOutcome != .idle {
                    WisentMutationBar(outcome: model.repairOutcome) {
                        model.clearRepairOutcome()
                    }
                    .padding(.horizontal, WisentDesign.Space.x4)
                    .padding(.top, WisentDesign.Space.x3)
                }
                HStack(spacing: 0) {
                    WisentFacetRail(
                        groups: facetGroups,
                        footerTitle: "Selection",
                        footerDetail: "\(visible.count.formatted(.number)) of \(model.runs.count.formatted(.number)) manifests"
                    )
                    centre(visible: visible)
                    inspector
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .searchable(
            text: $model.query,
            placement: .toolbar,
            prompt: "Search run id, target, product, kind or journey"
        )
    }

    // MARK: - Facets

    /// Counts come from the aggregate computed once at load, so opening this
    /// screen never recounts 123 manifests to label five facets.
    private var facetGroups: [WisentFacetGroup] {
        let status = model.summary.status
        let evidence = model.summary.evidence
        return [
            WisentFacetGroup(
                "Verdict",
                facets: [
                    WisentFacet(
                        id: "verdict.all",
                        label: "All verdicts",
                        count: status.total,
                        isSelected: model.runStatusFilter == nil
                    ) {
                        model.runStatusFilter = nil
                    }
                ] + RunStatus.allCases.map { value in
                    WisentFacet(
                        id: "verdict.\(value.rawValue)",
                        label: value.title,
                        count: status.count(of: value),
                        tone: value.needsAttention ? value.tone : .neutral,
                        isSelected: model.runStatusFilter == value
                    ) {
                        model.runStatusFilter = value
                    }
                }
            ),
            WisentFacetGroup(
                "Evidence level",
                facets: [
                    WisentFacet(
                        id: "level.all",
                        label: "Any level",
                        count: evidence.total,
                        isSelected: model.runEvidenceFilter == nil
                    ) {
                        model.runEvidenceFilter = nil
                    }
                ] + EvidenceLevel.allCases.map { level in
                    WisentFacet(
                        id: "level.\(level.rawValue)",
                        label: level.title,
                        count: evidence.count(of: level),
                        tone: level == .e0 ? .warning : .neutral,
                        isSelected: model.runEvidenceFilter == level
                    ) {
                        model.runEvidenceFilter = level
                    }
                }
            ),
        ]
    }

    // MARK: - Centre

    @ViewBuilder
    private func centre(visible: [RunRecord]) -> some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
            if let errorMessage = model.errorMessage, model.snapshot != nil {
                WisentErrorBanner(
                    title: "Refresh failed",
                    detail: errorMessage,
                    action: WisentAction("Retry", symbol: "arrow.clockwise", kind: .secondary) {
                        Task { await model.refresh() }
                    }
                )
            }
            ProbierzSnapshotGate(
                model: model,
                readingTitle: "Reading run manifests",
                readingDetail: "Scanning probierz/test-results for run-manifest.json, up to \(MetadataLoader.maximumManifests.formatted(.number)) files."
            ) {
                if model.runs.isEmpty {
                    WisentEmptyPanel(
                        title: "No run manifest here",
                        detail: "Probierz writes one run-manifest.json per run under probierz/test-results. None exists for \(model.scopeLabel.lowercased()).",
                        symbol: "tray"
                    )
                    Spacer(minLength: 0)
                } else if visible.isEmpty {
                    WisentEmptyPanel(
                        title: "No run matches this selection",
                        detail: "The scope holds \(model.runs.count.formatted(.number)) manifests. The facets and search term in force exclude every one of them.",
                        symbol: "line.3.horizontal.decrease.circle",
                        action: WisentAction("Clear filters", kind: .secondary) { model.clearRunFilters() }
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

    /// Five columns, ideals summing under the middle zone's width: 1280 less the
    /// 236 pt sidebar, 168 pt rail and 320 pt inspector leaves 556 pt. Duration,
    /// artifact count and host live one line down in the inspector, where the
    /// rest of the run already is.
    private func table(visible: [RunRecord]) -> some View {
        WisentTableFrame {
            Table(visible, selection: $model.selectedRunID) {
                TableColumn("RUN ID") { run in
                    Text(run.runID)
                        .font(WisentTypeScale.identifier())
                        .foregroundStyle(WisentDesign.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(run.runID)
                        .denseRow()
                }
                .width(min: 150, ideal: 180)
                TableColumn("TARGET") { run in
                    Text(run.target)
                        .font(WisentTypeScale.body())
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                }
                .width(min: 70, ideal: 84)
                TableColumn("VERDICT") { run in
                    RunVerdictCell(status: run.status)
                }
                .width(min: 62, ideal: 74)
                TableColumn("LVL") { run in
                    EvidenceLevelCell(level: run.evidenceLevel)
                }
                .width(30)
                TableColumn("STARTED") { run in
                    Text(ProbierzFormat.shortTimestamp(run.startedAt))
                        .font(WisentTypeScale.identifierSmall())
                        .monospacedDigit()
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                }
                .width(min: 78, ideal: 92)
            }
            .tableStyle(.inset)
            .accessibilityLabel("Probierz run manifests")
            // A click in this table already means "select this run" and a drag
            // means "extend that selection", so selectable cell text would
            // compete with both. The index opts out of the window's selection
            // rule; the inspector beside it states the same values selectably.
            .textSelection(.disabled)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let run = model.selectedRun {
            WisentInspector(
                eyebrow: "Run provenance",
                title: run.runID,
                badges: badges(for: run)
            ) {
                if let failure = run.failure {
                    failureSection(run: run, failure: failure)
                }
                WisentField(label: "Product", value: run.appID)
                WisentField(label: "Target", value: run.target)
                WisentField(label: "Kind", value: run.kind)
                if let spec = run.spec {
                    WisentField(label: "Spec", value: spec)
                }
                WisentField(label: "Evidence level", value: "\(run.evidenceLevel.title) — \(run.evidenceLevel.detail)", tone: run.evidenceLevel.tone)
                WisentField(label: "Started", value: ProbierzFormat.timestamp(run.startedAt))
                WisentField(label: "Completed", value: ProbierzFormat.timestamp(run.completedAt))
                WisentField(label: "Duration", value: ProbierzFormat.duration(run.durationMilliseconds))
                WisentField(
                    label: "Artifacts",
                    value: "\(run.artifactCount.formatted(.number)) · \(ProbierzFormat.bytes(run.artifactBytes))"
                )
                if !run.journeys.isEmpty {
                    WisentField(label: "Journeys", value: run.journeys.joined(separator: "\n"))
                }
                hostSection(run: run)
                sourceSection(run: run)
                WisentAction("Open Artifacts", symbol: "archivebox", kind: .secondary) {
                    model.query = run.runID
                    model.destination = .artifacts
                }
                .asButton()
            }
        } else {
            WisentInspector(eyebrow: "Run provenance", title: "No run selected") {
                Text("Select a run to read its verdict, evidence level, recorded source identity and — when it failed — the manifest's own reason.")
                    .font(WisentTypeScale.body())
                    .foregroundStyle(WisentDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func badges(for run: RunRecord) -> [(String, WisentTone)] {
        var badges: [(String, WisentTone)] = [(run.status.title, run.status.tone)]
        badges.append((run.evidenceLevel.title, run.evidenceLevel.tone))
        if run.isRecorded { badges.append(("Recorded", .brand)) }
        if run.hasProtectedBundle { badges.append(("Protected", .brand)) }
        return badges
    }

    /// The reason, verbatim, then the reproducing command the manifest recorded.
    @ViewBuilder
    private func failureSection(run: RunRecord, failure: RunFailure) -> some View {
        WisentAlertPanel(
            tone: run.status == .blocked ? .warning : .danger,
            title: failure.headline,
            detail: failure.sentence,
            command: failure.command
        )
        if run.status == .failed {
            WisentAction(
                "Repair through Brama",
                symbol: "wrench.and.screwdriver",
                kind: .primary,
                isEnabled: !model.repairOutcome.isWorking
            ) {
                model.repair(run)
            }
            .asButton()
        }
        if failure.reasons.count > 1 {
            WisentField(
                label: "Every recorded reason",
                value: failure.reasons.joined(separator: "\n")
            )
        }
        if !failure.remediation.isEmpty {
            WisentField(
                label: "Remediation recorded by preflight",
                value: failure.remediation.joined(separator: "\n"),
                tone: .warning
            )
        }
        if let code = failure.code {
            WisentField(label: "Reason code", value: code, tone: .danger)
        }
        if !failure.facts.isEmpty {
            WisentField(label: "Recorded facts", value: failure.facts.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func hostSection(run: RunRecord) -> some View {
        if run.hostName != nil || run.hostPlatform != nil || run.deviceName != nil {
            WisentField(
                label: "Host",
                value: [run.hostName, run.hostPlatform].compactMap { $0 }.joined(separator: " · ")
            )
        }
        if let device = run.deviceName {
            WisentField(
                label: "Device",
                value: [device, run.deviceRuntime].compactMap { $0 }.joined(separator: " · ")
            )
        }
    }

    @ViewBuilder
    private func sourceSection(run: RunRecord) -> some View {
        if let harness = run.harnessGitSHA {
            WisentField(
                label: "Harness commit",
                value: run.harnessIsDirty ? "\(harness) (dirty worktree)" : harness,
                tone: run.harnessIsDirty ? .warning : .neutral
            )
        }
        ForEach(run.sourceRepositories) { repository in
            WisentField(
                label: "Source \(repository.name)",
                value: repository.isDirty
                    ? "\(repository.gitSHA ?? "Not recorded") (dirty worktree)"
                    : (repository.gitSHA ?? "Not recorded"),
                tone: repository.isDirty ? .warning : .neutral
            )
        }
    }
}

@MainActor
extension WisentAction {
    /// A single action rendered inline inside an inspector column.
    func asButton() -> some View {
        WisentActionButton(action: self)
    }
}
