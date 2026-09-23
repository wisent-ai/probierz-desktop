import SwiftUI
import WisentDesignSystem

/// Which workspace produced everything on screen, and how complete the read of
/// it was.
///
/// A destination because it answers a verification question: an operator
/// reading a verdict has to know it came from the workspace they think it did,
/// and whether the scan saw every manifest or stopped at its limit.
struct WorkspaceView: View {
    @ObservedObject var model: ProbierzModel
    @ObservedObject var onboarding: ProbierzOnboarding
    let chooseWorkspace: () -> Void
    let adoptProject: () -> Void

    @State private var walkthrough: WisentMutationOutcome = .idle

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
                    isEnabled: model.workspaceRoot != nil,
                    isBusy: model.isRefreshing
                ) {
                    Task { await model.refresh() }
                },
            ]
        ) {
            ProbierzSnapshotGate(
                model: model,
                readingLabel: "Loading workspace",
                // The inventory counter row lands first: four counters, each
                // with a caption under its value.
                readingShape: .metrics(cells: 4, detail: true),
                chooseWorkspace: chooseWorkspace
            ) {
                if model.snapshot?.manifestsTruncated == true {
                    WisentAlertPanel(
                        tone: .warning,
                        title: "Only recent runs were loaded",
                        detail: "The newest \(model.snapshot?.manifestLimit.formatted(.number) ?? "0") runs are shown. Counts may omit older runs.",
                        actions: [
                            WisentAction("Re-read", symbol: "arrow.clockwise", kind: .secondary) {
                                Task { await model.refresh() }
                            }
                        ]
                    )
                }
                inventory
                identity
                projectAdoption
                firstRunWalkthrough
            }
        }
    }

    private var inventory: some View {
        WisentCounterRow(counters: [
            WisentCounterRow.Counter(
                "Runs",
                value: (model.snapshot?.runs.count ?? 0).formatted(.number),
                detail: "recorded",
                tone: .neutral
            ),
            WisentCounterRow.Counter(
                "Artifacts",
                value: (model.snapshot?.artifacts.count ?? 0).formatted(.number),
                detail: ProbierzFormat.bytes(model.snapshot?.summary(for: nil).artifactBytes ?? 0),
                tone: .neutral
            ),
            WisentCounterRow.Counter(
                "Products",
                value: (model.snapshot?.productIDs.count ?? 0).formatted(.number),
                detail: "available",
                tone: .neutral
            ),
            WisentCounterRow.Counter(
                "Protected bundles",
                value: (model.snapshot?.summary(for: nil).protectedBundleCount ?? 0).formatted(.number),
                detail: "available",
                tone: .brand
            ),
        ])
    }

    private var identity: some View {
        WisentSectionBox(
            title: "Workspace details",
            detail: "The workspace used for this view.",
            trailing: model.snapshot == nil ? "Not selected" : "Selected"
        ) {
            WisentPanel {
                VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
                    WisentField(
                        label: "Workspace",
                        value: model.workspaceRoot?.lastPathComponent ?? "Not selected"
                    )
                    WisentField(
                        label: "Last read",
                        value: ProbierzFormat.timestamp(model.snapshot?.loadedAt)
                    )
                    WisentField(
                        label: "Run limit",
                        value: "\((model.snapshot?.manifestLimit ?? MetadataLoader.maximumManifests).formatted(.number)) per refresh"
                    )
                }
            }
        }
    }

    private var projectAdoption: some View {
        WisentSectionBox(
            title: "Adopt existing project",
            detail: "Import validated app manifests and established spec directories. Adoption never runs a journey.",
            trailing: "\(model.projectAdoptions?.sources.count ?? 0) source(s)"
        ) {
            WisentPanel {
                VStack(alignment: .leading, spacing: WisentDesign.Space.x3) {
                    Button("Choose Probierz project", action: adoptProject)
                        .buttonStyle(WisentPrimaryButtonStyle())
                        .disabled(model.isAdopting)
                    if model.adoptionOutcome != .idle {
                        WisentMutationBar(outcome: model.adoptionOutcome) {
                            model.clearAdoptionOutcome()
                        }
                    }
                    if let result = model.projectAdoption, !result.conflicts.isEmpty {
                        VStack(alignment: .leading, spacing: WisentDesign.Space.x2) {
                            Text("No definitions changed. Review every conflict:")
                                .font(WisentTypography.bodyMedium(12))
                                .foregroundStyle(WisentDesign.ink)
                            ForEach(result.conflicts) { conflict in
                                Text("\(conflict.path) — \(conflict.reason)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(WisentDesign.secondary)
                                    .textSelection(.enabled)
                            }
                            Button("Replace these reviewed definitions") {
                                Task {
                                    _ = await model.adoptProject(
                                        from: URL(fileURLWithPath: result.sourceRoot, isDirectory: true),
                                        replace: true
                                    )
                                }
                            }
                            .buttonStyle(WisentSecondaryButtonStyle())
                            .disabled(model.isAdopting)
                        }
                    }
                    Divider()
                    if let sources = model.projectAdoptions?.sources, !sources.isEmpty {
                        ForEach(sources) { source in
                            VStack(alignment: .leading, spacing: WisentDesign.Space.x1) {
                                Text(source.sourceRoot)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(WisentDesign.ink)
                                    .textSelection(.enabled)
                                Text("\(source.fileCount) definitions · \(source.applications.count) applications · SHA-256 \(source.sourceDigest.prefix(12))…")
                                    .font(WisentTypography.body(11))
                                    .foregroundStyle(WisentDesign.secondary)
                            }
                        }
                    } else {
                        Text("No existing project has been adopted. Skipping leaves this workspace empty and usable.")
                            .font(WisentTypography.body(12))
                            .foregroundStyle(WisentDesign.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The one control on this screen that writes something instead of
    /// reporting something, so it sits last, under the facts it does not
    /// change.
    private var firstRunWalkthrough: some View {
        WisentSectionBox(
            title: "First-run walkthrough",
            detail: "See the walkthrough this product shows on a first run."
        ) {
            WisentPanel {
                VStack(alignment: .leading, spacing: WisentDesign.Space.x3) {
                    WisentAction("Show it again", kind: .secondary, isBusy: isReplaying) {
                        showWalkthroughAgain()
                    }
                    .asButton()
                    if walkthrough != .idle {
                        WisentMutationBar(outcome: walkthrough) { walkthrough = .idle }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var isReplaying: Bool { onboarding.isWorking || walkthrough.isWorking }

    /// Resets the journey and lets the shell present it.
    ///
    /// Nothing here reaches for a sheet: the walkthrough has exactly one
    /// presentation in this app, the card `ProbierzRootView` stacks above the
    /// open destination on a first run, and the reset is what puts it back.
    /// The outcome is held by this screen rather than by the journey, so
    /// leaving Workspace clears the line instead of carrying a stale "Started."
    /// onto Runs.
    ///
    /// The local `.working` line is what closes the control, not
    /// `onboarding.isWorking`: the journey does not raise that flag until the
    /// task below is scheduled, and a second press lands in the gap.
    @MainActor
    private func showWalkthroughAgain() {
        guard !isReplaying else { return }
        walkthrough = .working("Starting the walkthrough…")
        Task { walkthrough = await onboarding.replay() }
    }
}
