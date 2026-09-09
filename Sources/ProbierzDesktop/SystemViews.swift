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
                    isEnabled: model.workspaceRoot != nil,
                    isBusy: model.isRefreshing
                ) {
                    Task { await model.refresh() }
                }
            ]
        ) {
            ProbierzSnapshotGate(
                model: model,
                readingLabel: "Loading preflight results",
                // Preflight lands on panels and recorded checks: prose, not a
                // table of its own.
                readingShape: .prose(lines: 4)
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
                title: "No preflight results",
                detail: "No preflight result is available for this workspace.",
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
            lines.append("Missing: \(preflight.missing.map { requirementLabel(forName: $0) }.joined(separator: ", "))")
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
                detail: "Readiness checks and suggested fixes.",
                trailing: "\(preflight.checks.count.formatted(.number)) checks"
            ) {
                WisentPanel(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(preflight.checks) { check in
                            WisentQueueRow(
                                symbol: check.isSatisfied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                tone: check.isSatisfied ? .success : .warning,
                                title: requirementLabel(forName: check.name),
                                detail: check.hint.isEmpty ? "No suggestion recorded" : check.hint,
                                meta: check.isOwnedByProbierz ? "Setup" : "System"
                            )
                        }
                    }
                }
            }
        }
        WisentSectionBox(
            title: "Requirements on this Mac",
            detail: "Shows what this app can use now.",
            trailing: "\((model.snapshot?.conditions.count ?? 0).formatted(.number)) requirements"
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

    private func requirementLabel(forName name: String) -> String {
        return switch name {
        case "BASE_URL": "Web address"
        case "ELECTRON_APP_MAIN": "Electron app"
        case "APP_IOS": "iOS app"
        case "APP_ANDROID": "Android app"
        case "BUNDLE_ID": "iOS bundle"
        case "APP_PACKAGE": "Android package"
        case "IOS_DEVICE": "iOS device"
        case "IOS_VERSION": "iOS version"
        case "APPIUM_HOME": "Mobile support"
        case "MAC_BUNDLE_ID": "macOS app"
        case "WIN_APP": "Windows app"
        case "CUA_APP_EXECUTABLE": "Desktop app"
        case "TUI_CMD": "Terminal command"
        default: name == name.uppercased() ? "Required setting" : name
        }
    }

    private func conditionRow(_ condition: ConditionRecord) -> some View {
        HStack(spacing: WisentDesign.Space.x3) {
            Text(requirementLabel(forName: condition.name))
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
