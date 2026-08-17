import SwiftUI
import WisentDesignSystem

/// Readiness, and what is stopping evidence from counting.
///
/// The one screen that answers "can this merge?" before the operator has to
/// open anything. Weight is layout here: a healthy fact is one line in the
/// signal strip, a failure is a full-width panel carrying the manifest's own
/// sentence and the command that produced it.
struct PostureView: View {
    @ObservedObject var model: ProbierzModel
    let chooseWorkspace: () -> Void

    /// Enough failures to show the shape of the problem without turning the
    /// screen into the Runs table.
    private static let alertLimit = 3

    var body: some View {
        WisentScreen(
            title: "Posture",
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
            ]
        ) {
            ProbierzSnapshotGate(
                model: model,
                readingTitle: "Reading the Probierz metadata projection",
                readingDetail: "Scanning probierz/test-results for run-manifest.json and probierz/apps for declared journeys.",
                chooseWorkspace: chooseWorkspace
            ) {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = model.errorMessage {
            WisentErrorBanner(
                title: "Refresh failed",
                detail: errorMessage,
                action: WisentAction("Retry", symbol: "arrow.clockwise", kind: .secondary) {
                    Task { await model.refresh() }
                }
            )
        }
        WisentSignalStrip(signals: signals)
        if model.summary.status.total == 0 {
            WisentEmptyPanel(
                title: "No run has been recorded here",
                detail: "Probierz writes a run manifest under probierz/test-results for every target it drives. This workspace holds none for \(model.scopeLabel.lowercased()), so there is no evidence to judge yet.",
                symbol: "tray"
            )
        } else {
            verdictCounters
            alerts
            queue
        }
    }

    // MARK: - Healthy signals

    private var signals: [WisentSignal] {
        let summary = model.summary
        var signals: [WisentSignal] = [
            WisentSignal(
                "Workspace",
                value: model.snapshot?.repositoryRoot.lastPathComponent ?? "Not selected",
                tone: model.snapshot == nil ? .warning : .success
            ),
            WisentSignal(
                "Runs recorded",
                value: summary.status.total.formatted(.number),
                tone: summary.status.total > 0 ? .success : .neutral
            ),
            WisentSignal(
                "Last verdict",
                value: summary.lastStatus?.title ?? "None",
                tone: summary.lastStatus?.tone ?? .neutral
            ),
            WisentSignal(
                "Last green",
                value: summary.lastGreenStartedAt.map(ProbierzFormat.shortTimestamp) ?? "Never",
                tone: summary.lastGreenRunID == nil ? .warning : .success
            ),
        ]
        if let snapshot = model.snapshot {
            signals.append(
                WisentSignal(
                    "Products",
                    value: snapshot.productIDs.count.formatted(.number),
                    tone: .neutral
                )
            )
        }
        return signals
    }

    private var verdictCounters: some View {
        WisentCounterRow(counters: [
            WisentCounterRow.Counter(
                "Passed",
                value: model.summary.status.passed.formatted(.number),
                detail: "manifests recording a pass",
                tone: .success
            ),
            WisentCounterRow.Counter(
                "Needs a decision",
                value: model.summary.status.needsAttention.formatted(.number),
                detail: "failed, blocked or never completed",
                tone: model.summary.status.needsAttention > 0 ? .danger : .neutral
            ),
            WisentCounterRow.Counter(
                "Recorded evidence",
                value: model.summary.evidence.e3.formatted(.number),
                detail: "runs reaching E3",
                tone: .brand
            ),
            WisentCounterRow.Counter(
                "Evidence inventory",
                value: ProbierzFormat.bytes(model.summary.artifactBytes),
                detail: "\(model.summary.artifactCount.formatted(.number)) descriptors",
                tone: .neutral
            ),
        ])
    }

    // MARK: - Failures, at failure size

    @ViewBuilder
    private var alerts: some View {
        if model.snapshot?.manifestsTruncated == true {
            WisentAlertPanel(
                tone: .warning,
                title: "The projection is incomplete",
                detail: "The scan stopped at its limit of \(model.snapshot?.manifestLimit.formatted(.number) ?? "0") run manifests, so every count on this screen is a lower bound. Older runs are on disk but outside this read.",
                actions: [
                    WisentAction("Open Workspace", symbol: "internaldrive", kind: .secondary) {
                        model.destination = .workspace
                    }
                ]
            )
        }
        ForEach(failingRuns) { run in
            if let failure = run.failure {
                RunFailurePanel(
                    run: run,
                    failure: failure,
                    action: WisentAction("Open Run", symbol: "list.bullet.rectangle", kind: .secondary) {
                        model.selectedRunID = run.id
                        model.destination = .runs
                    }
                )
            }
        }
        if !model.blockingVerdicts.isEmpty {
            WisentAlertPanel(
                tone: .warning,
                title: "\(model.blockingVerdicts.count.formatted(.number)) journeys would block a merge",
                detail: blockingDetail,
                actions: [
                    WisentAction("Open Verdicts", symbol: "checkmark.seal", kind: .secondary) {
                        model.destination = .verdicts
                    }
                ]
            )
        }
    }

    private var failingRuns: [RunRecord] {
        Array(model.unresolvedFailures.prefix(Self.alertLimit))
    }

    /// The reasons are `probierz status`' own sentences, reproduced from the same
    /// manifest facts rather than reworded.
    private var blockingDetail: String {
        model.blockingVerdicts
            .prefix(6)
            .flatMap(\.blockingReasons)
            .joined(separator: "\n")
    }

    // MARK: - Queue

    @ViewBuilder
    private var queue: some View {
        let untested = model.journeys.filter { $0.runCount == 0 }
        let weak = model.journeys.filter { $0.runCount > 0 && ($0.latestStatus?.needsAttention ?? false) }
        if !untested.isEmpty || !weak.isEmpty {
            WisentSectionBox(
                title: "Journeys waiting on evidence",
                detail: "Declared in probierz/apps and either never run, or last run without a pass.",
                trailing: "\((untested.count + weak.count).formatted(.number)) journeys"
            ) {
                WisentPanel(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(untested.prefix(6))) { journey in
                            queueRow(
                                journey: journey,
                                symbol: "questionmark.circle",
                                tone: .warning,
                                detail: "No run manifest references this journey"
                            )
                        }
                        ForEach(Array(weak.prefix(6))) { journey in
                            queueRow(
                                journey: journey,
                                symbol: journey.latestStatus?.symbol ?? "xmark.octagon.fill",
                                tone: journey.latestStatus?.tone ?? .danger,
                                detail: "Last run is \(journey.latestStatus?.title.lowercased() ?? "unresolved")"
                            )
                        }
                    }
                }
            }
        }
    }

    private func queueRow(
        journey: JourneyRecord,
        symbol: String,
        tone: WisentTone,
        detail: String
    ) -> some View {
        WisentQueueRow(
            symbol: symbol,
            tone: tone,
            title: journey.name,
            detail: detail,
            meta: journey.appID,
            action: WisentAction("Inspect", kind: .plain) {
                model.selectedJourneyID = journey.id
                model.destination = .journeys
            }
        )
    }
}
