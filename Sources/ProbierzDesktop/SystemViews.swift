import SwiftUI
import WisentDesignSystem

/// Toolchain readiness, as recorded by the host that actually ran.
///
/// The baseline's "Configuration" screen listed thirteen hardcoded variable
/// names and checked them against the environment of this GUI process — a value
/// that says nothing about the machine a run happens on. The authoritative
/// answer is the `preflight` block a blocked run manifest carries, so that is
/// what leads here; the viewer's own environment is labelled as such and kept
/// below it.
struct PreflightView: View {
    @ObservedObject var model: ProbierzModel

    var body: some View {
        WisentScreen(
            title: "Preflight",
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
                readingTitle: "Reading recorded preflight results",
                readingDetail: "A blocked run manifest carries the preflight that stopped it: its checks, what was missing and how to fix it."
            ) {
                blockedPanels
                readySignals
                conditionSection
            }
        }
    }

    private var preflights: [PreflightRecord] { model.snapshot?.preflights ?? [] }

    /// A blocked toolchain is a failure and gets a full-width panel carrying
    /// the remediation the backend itself printed, in `detail(for:)`.
    @ViewBuilder
    private var blockedPanels: some View {
        let blocked = preflights.filter { !$0.isReady }
        if blocked.isEmpty, preflights.isEmpty {
            WisentEmptyPanel(
                title: "No preflight has been recorded here",
                detail: "Probierz records a preflight block only when it refuses to spawn a run. No manifest in this workspace carries one, so there is nothing to report about this host from evidence alone. probierz check <target> is authoritative for the current machine.",
                symbol: "wrench.and.screwdriver"
            )
        }
        ForEach(blocked) { preflight in
            WisentAlertPanel(
                tone: .warning,
                title: "\(preflight.target) was blocked before the suite started",
                detail: detail(for: preflight),
                actions: [
                    WisentAction("Open Run", symbol: "list.bullet.rectangle", kind: .secondary) {
                        model.selectedRunID = preflight.runID
                        model.destination = .runs
                    }
                ]
            )
        }
    }

    private func detail(for preflight: PreflightRecord) -> String {
        var lines: [String] = []
        if !preflight.missing.isEmpty {
            lines.append("missing: \(preflight.missing.joined(separator: ", "))")
        }
        lines.append(contentsOf: preflight.remediation)
        lines.append("Recorded \(ProbierzFormat.timestamp(preflight.observedAt)) by run \(preflight.runID).")
        return lines.joined(separator: "\n")
    }

    /// A ready toolchain is one line, not a card.
    @ViewBuilder
    private var readySignals: some View {
        let ready = preflights.filter(\.isReady)
        if !ready.isEmpty {
            WisentSignalStrip(
                signals: ready.map { preflight in
                    WisentSignal(preflight.target, value: "Ready", tone: .success)
                }
            )
        }
    }

    @ViewBuilder
    private var conditionSection: some View {
        if let preflight = preflights.first(where: { !$0.isReady }), !preflight.checks.isEmpty {
            WisentSectionBox(
                title: "Checks recorded for \(preflight.target)",
                detail: "Every check the runner performed, with the hint it recorded for the ones that failed.",
                trailing: "\(preflight.checks.count.formatted(.number)) checks"
            ) {
                WisentPanel(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(preflight.checks) { check in
                            WisentQueueRow(
                                symbol: check.isSatisfied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                tone: check.isSatisfied ? .success : .warning,
                                title: check.name,
                                detail: check.hint.isEmpty ? "No hint recorded" : check.hint,
                                meta: check.isOwnedByProbierz ? "probierz setup" : "host"
                            )
                        }
                    }
                }
            }
        }
        WisentSectionBox(
            title: "Condition names in this viewer's environment",
            detail: "Presence only, never a value, and never a claim about the machine a run uses. A name that is absent here says nothing about the run host.",
            trailing: "\((model.snapshot?.conditions.count ?? 0).formatted(.number)) names"
        ) {
            // Rows, not a `Table`: this screen scrolls, and a `Table` inside a
            // `ScrollView` asks for the height of its contents. That is the
            // recorded defect that pushed a whole split view off the top edge.
            WisentPanel(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array((model.snapshot?.conditions ?? []).enumerated()), id: \.element.id) { index, condition in
                        if index > 0 {
                            Rectangle()
                                .fill(WisentDesign.border)
                                .frame(height: WisentDesign.hairline)
                        }
                        conditionRow(condition)
                    }
                }
            }
        }
    }

    private func conditionRow(_ condition: ConditionRecord) -> some View {
        HStack(spacing: WisentDesign.Space.x3) {
            Text(condition.name)
                .font(WisentTypeScale.identifier())
                .foregroundStyle(WisentDesign.ink)
                .lineLimit(1)
            Text(condition.surface)
                .font(WisentTypeScale.caption())
                .foregroundStyle(WisentDesign.muted)
                .lineLimit(1)
            Spacer(minLength: WisentDesign.Space.x4)
            // Absent is neutral and says "Not configured". Red is kept for a
            // failure that actually happened.
            ConditionPresenceCell(isPresent: condition.isPresentForViewer)
        }
        .padding(.horizontal, WisentDesign.Space.x4)
        .frame(height: WisentAppLayout.denseRowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// Which workspace produced everything on screen, and how complete the read of
/// it was.
///
/// A destination because it answers a verification question: an operator
/// reading a verdict has to know it came from the workspace they think it did,
/// and whether the scan saw every manifest or stopped at its limit.
struct WorkspaceView: View {
    @ObservedObject var model: ProbierzModel
    let chooseWorkspace: () -> Void

    var body: some View {
        WisentScreen(
            title: "Workspace",
            scope: model.scopeLabel,
            freshness: model.freshnessLabel,
            actions: [
                WisentAction("Choose Workspace", symbol: "folder", kind: .secondary, perform: chooseWorkspace),
                WisentAction(
                    "Refresh",
                    symbol: "arrow.clockwise",
                    kind: .primary,
                    isEnabled: !model.isRefreshing && model.workspaceRoot != nil
                ) {
                    Task { await model.refresh() }
                },
            ]
        ) {
            ProbierzSnapshotGate(
                model: model,
                readingTitle: "Reading the workspace",
                readingDetail: "Resolving probierz/package.json and agent/history.mjs, then scanning probierz/test-results.",
                chooseWorkspace: chooseWorkspace
            ) {
                if model.snapshot?.manifestsTruncated == true {
                    WisentAlertPanel(
                        tone: .warning,
                        title: "The scan stopped at its limit",
                        detail: "This read reached \(model.snapshot?.manifestLimit.formatted(.number) ?? "0") run manifests and stopped. Every count in this window is therefore a lower bound, and the oldest runs on disk are outside it.",
                        actions: [
                            WisentAction("Re-read", symbol: "arrow.clockwise", kind: .secondary) {
                                Task { await model.refresh() }
                            }
                        ]
                    )
                }
                inventory
                identity
            }
        }
    }

    private var inventory: some View {
        WisentCounterRow(counters: [
            WisentCounterRow.Counter(
                "Run manifests",
                value: (model.snapshot?.runs.count ?? 0).formatted(.number),
                detail: "read from probierz/test-results",
                tone: .neutral
            ),
            WisentCounterRow.Counter(
                "Artifact descriptors",
                value: (model.snapshot?.artifacts.count ?? 0).formatted(.number),
                detail: ProbierzFormat.bytes(model.snapshot?.summary(for: nil).artifactBytes ?? 0) + " declared",
                tone: .neutral
            ),
            WisentCounterRow.Counter(
                "Products",
                value: (model.snapshot?.productIDs.count ?? 0).formatted(.number),
                detail: "app manifests and recorded app ids",
                tone: .neutral
            ),
            WisentCounterRow.Counter(
                "Protected bundles",
                value: (model.snapshot?.summary(for: nil).protectedBundleCount ?? 0).formatted(.number),
                detail: "provenance records, payloads unread",
                tone: .brand
            ),
        ])
    }

    private var identity: some View {
        WisentSectionBox(
            title: "Metadata source",
            detail: "The directory every number in this window was read from.",
            trailing: model.snapshot == nil ? "Not resolved" : "Resolved"
        ) {
            WisentPanel {
                VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
                    WisentField(
                        label: "Probierz repository",
                        value: model.snapshot?.repositoryRoot.path ?? "Not resolved"
                    )
                    WisentField(
                        label: "Workspace root",
                        value: model.workspaceRoot?.path ?? "Not selected"
                    )
                    WisentField(
                        label: "Last read",
                        value: ProbierzFormat.timestamp(model.snapshot?.loadedAt)
                    )
                    WisentField(
                        label: "Scan ceiling",
                        value: "\((model.snapshot?.manifestLimit ?? MetadataLoader.maximumManifests).formatted(.number)) run manifests per read"
                    )
                }
            }
        }
    }
}
