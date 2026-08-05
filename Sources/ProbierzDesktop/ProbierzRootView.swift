import AppKit
import SwiftUI

struct ProbierzRootView: View {
    @ObservedObject var model: ProbierzModel
    @ObservedObject var onboarding: ProbierzOnboarding
    @State private var destination: ProbierzDestination? = .overview

    var body: some View {
        NavigationSplitView {
            List(ProbierzDestination.allCases, selection: $destination) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationTitle("Probierz")
            .navigationSplitViewColumnWidth(
                min: ProbierzTheme.sidebarMinimumWidth,
                ideal: ProbierzTheme.sidebarIdealWidth
            )
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            VStack(spacing: 0) {
                if let errorMessage = model.errorMessage {
                    errorBanner(errorMessage)
                        .padding(.horizontal, ProbierzTheme.Space.x6)
                        .padding(.top, ProbierzTheme.Space.x3)
                }
                if let screen = onboarding.screen {
                    ProbierzOnboardingCard(
                        screen: screen,
                        isWorking: onboarding.isWorking,
                        action: performOnboardingAction
                    )
                    .padding(.horizontal, ProbierzTheme.Space.x6)
                    .padding(.top, ProbierzTheme.Space.x3)
                }
                Group {
                    if let snapshot = model.snapshot {
                        destinationView(snapshot)
                    } else {
                        unavailableWorkspace
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(ProbierzTheme.canvas)
        }
        .frame(minWidth: ProbierzTheme.minimumWidth, minHeight: ProbierzTheme.minimumHeight)
        .searchable(text: $model.query, prompt: "Filter local metadata")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing Probierz metadata")
                }
                Button(action: chooseWorkspace) {
                    Label("Choose Workspace", systemImage: "folder")
                }
                .help("Select the Wisent workspace containing Probierz")

                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing || model.workspaceRoot == nil)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh local metadata")
            }
        }
        .task {
            await onboarding.start()
            if model.snapshot == nil, model.workspaceRoot != nil {
                await model.refresh()
            }
        }
        .sheet(item: evidenceBundleInspectorBinding) { artifact in
            EvidenceBundleInspector(artifact: artifact)
                .onAppear {
                    Task {
                        await onboarding.observeEvidenceBundleInspected(artifact)
                    }
                }
        }
    }

    @ViewBuilder
    private func destinationView(_ snapshot: ProbierzSnapshot) -> some View {
        switch destination ?? .overview {
        case .overview:
            overview(snapshot)
        case .configuration:
            configuration(snapshot)
        case .runs:
            runs(snapshot)
        case .artifacts:
            artifacts(snapshot)
        }
    }

    private func overview(_ snapshot: ProbierzSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ProbierzTheme.Space.x6) {
                overviewHeader(snapshot)
                aggregateStatus(snapshot)

                VStack(alignment: .leading, spacing: ProbierzTheme.Space.x3) {
                    Text("Surface readiness")
                        .font(.title3.weight(.semibold))
                    if model.filteredContracts.isEmpty, model.hasActiveFilter {
                        EmptyFilterView(clear: model.clearFilters)
                            .frame(minHeight: 240)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300), spacing: ProbierzTheme.Space.x3)],
                            spacing: ProbierzTheme.Space.x3
                        ) {
                            ForEach(model.filteredContracts) { contract in
                                contractRow(contract)
                            }
                        }
                    }
                }
                privacyBoundary
            }
            .frame(maxWidth: ProbierzTheme.contentMaximumWidth, alignment: .leading)
            .padding(ProbierzTheme.Space.x6)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("Overview")
    }

    private func overviewHeader(_ snapshot: ProbierzSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ProbierzTheme.Space.x4) {
            VStack(alignment: .leading, spacing: ProbierzTheme.Space.x1) {
                Label("Probierz", systemImage: "checkmark.seal")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(ProbierzTheme.accent)
                Text("Cross-platform verification readiness and evidence metadata.")
                    .font(.subheadline)
                    .foregroundStyle(ProbierzTheme.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: ProbierzTheme.Space.x1) {
                Text("Updated")
                    .font(.caption)
                    .foregroundStyle(ProbierzTheme.secondary)
                Text(snapshot.loadedAt, style: .relative)
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private func aggregateStatus(_ snapshot: ProbierzSnapshot) -> some View {
        ProbierzPanel {
            Grid(alignment: .leading, horizontalSpacing: ProbierzTheme.Space.x8, verticalSpacing: ProbierzTheme.Space.x2) {
                GridRow {
                    summaryMetric(
                        title: "Contracts",
                        value: "\(snapshot.availableContractCount)/\(snapshot.contracts.count)",
                        detail: "available locally"
                    )
                    summaryMetric(
                        title: "Configuration",
                        value: "\(snapshot.configuredCount)/\(snapshot.configurations.count)",
                        detail: "names present"
                    )
                    summaryMetric(
                        title: "Recorded runs",
                        value: snapshot.summary.total.formatted(),
                        detail: "manifest records"
                    )
                    summaryMetric(
                        title: "Artifact inventory",
                        value: snapshot.artifacts.count.formatted(),
                        detail: ByteCountFormatter.string(fromByteCount: snapshot.artifactBytes, countStyle: .file)
                    )
                }
            }
            Divider()
                .padding(.vertical, ProbierzTheme.Space.x2)
            HStack(spacing: ProbierzTheme.Space.x4) {
                summaryStatus(status: .passed, count: snapshot.summary.passed)
                summaryStatus(status: .failed, count: snapshot.summary.failed)
                summaryStatus(status: .blocked, count: snapshot.summary.blocked)
                summaryStatus(status: .canceled, count: snapshot.summary.canceled)
                summaryStatus(status: .incomplete, count: snapshot.summary.incomplete)
                Spacer()
                if snapshot.manifestsTruncated {
                    Label("Inventory limit reached", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(ProbierzTheme.warning)
                }
            }
        }
    }

    private func summaryMetric(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: ProbierzTheme.Space.x1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(ProbierzTheme.secondary)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(ProbierzTheme.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private func summaryStatus(status: RunStatus, count: Int) -> some View {
        Label {
            Text("\(count) \(status.title.lowercased())")
                .monospacedDigit()
        } icon: {
            Image(systemName: status.symbol)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(ProbierzTheme.color(for: status))
        .accessibilityElement(children: .combine)
    }

    private func contractRow(_ contract: ContractItem) -> some View {
        ProbierzPanel {
            HStack(alignment: .top, spacing: ProbierzTheme.Space.x3) {
                VStack(alignment: .leading, spacing: ProbierzTheme.Space.x2) {
                    Text(contract.title)
                        .font(.headline)
                    Text(contract.detail)
                        .font(.subheadline)
                        .foregroundStyle(ProbierzTheme.secondary)
                    Text(contract.relativePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(ProbierzTheme.muted)
                }
                Spacer(minLength: ProbierzTheme.Space.x3)
                VStack(alignment: .trailing, spacing: ProbierzTheme.Space.x2) {
                    AvailabilityBadge(
                        isAvailable: contract.isAvailable,
                        availableTitle: "Available",
                        unavailableTitle: "Unavailable"
                    )
                    if let modifiedAt = contract.modifiedAt {
                        Text(modifiedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(ProbierzTheme.muted)
                    }
                }
            }
        }
    }

    private func configuration(_ snapshot: ProbierzSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ProbierzTheme.Space.x6) {
                SectionHeading(
                    title: "Configuration inventory",
                    detail: "Presence only. Values are never retained or displayed."
                )
                ProbierzPanel {
                    VStack(alignment: .leading, spacing: ProbierzTheme.Space.x3) {
                        Label("Workspace", systemImage: "folder")
                            .font(.headline)
                        Text(snapshot.repositoryRoot.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(ProbierzTheme.secondary)
                            .textSelection(.enabled)
                        Divider()
                        LabeledContent("Declared names", value: snapshot.configurations.count.formatted())
                        LabeledContent("Present names", value: snapshot.configuredCount.formatted())
                    }
                }

                if model.filteredConfigurations.isEmpty, model.hasActiveFilter {
                    EmptyFilterView(clear: model.clearFilters)
                        .frame(minHeight: 320)
                } else {
                    ProbierzPanel {
                        VStack(spacing: 0) {
                            ForEach(Array(model.filteredConfigurations.enumerated()), id: \.element.id) { index, item in
                                HStack(spacing: ProbierzTheme.Space.x3) {
                                    Image(systemName: "key.horizontal")
                                        .foregroundStyle(ProbierzTheme.secondary)
                                    Text(item.name)
                                        .font(.callout.monospaced())
                                    Spacer()
                                    AvailabilityBadge(
                                        isAvailable: item.isPresent,
                                        availableTitle: "Present",
                                        unavailableTitle: "Not present"
                                    )
                                }
                                .padding(.vertical, ProbierzTheme.Space.x3)
                                if index < model.filteredConfigurations.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                privacyBoundary
            }
            .frame(maxWidth: ProbierzTheme.contentMaximumWidth, alignment: .leading)
            .padding(ProbierzTheme.Space.x6)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("Configuration")
    }

    private func runs(_ snapshot: ProbierzSnapshot) -> some View {
        VStack(alignment: .leading, spacing: ProbierzTheme.Space.x4) {
            HStack(alignment: .bottom, spacing: ProbierzTheme.Space.x4) {
                SectionHeading(
                    title: "Run status",
                    detail: "Normalized from the read-only run-manifest metadata boundary."
                )
                Spacer()
                Picker("Status", selection: $model.statusFilter) {
                    Text("All statuses").tag(RunStatus?.none)
                    ForEach(RunStatus.allCases) { status in
                        Text(status.title).tag(Optional(status))
                    }
                }
                .frame(width: 190)
                .labelsHidden()
            }

            if snapshot.runs.isEmpty {
                ContentUnavailableView(
                    "No run metadata",
                    systemImage: "checklist",
                    description: Text("Probierz has not recorded a run manifest in this workspace.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredRuns.isEmpty {
                EmptyFilterView(clear: model.clearFilters)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.filteredRuns) {
                    TableColumn("Status") { run in
                        StatusBadge(status: run.status)
                    }
                    .width(min: 104, ideal: 112)
                    TableColumn("Target") { run in
                        Text(run.target)
                            .lineLimit(1)
                    }
                    .width(min: 120, ideal: 160)
                    TableColumn("Started") { run in
                        if let date = run.startedAt {
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                        } else {
                            Text("Unavailable")
                                .foregroundStyle(ProbierzTheme.muted)
                        }
                    }
                    .width(min: 150, ideal: 170)
                    TableColumn("Duration") { run in
                        Text(durationLabel(run.durationMilliseconds))
                            .monospacedDigit()
                    }
                    .width(min: 80, ideal: 96)
                    TableColumn("Artifacts") { run in
                        Text(run.artifactCount.formatted())
                            .monospacedDigit()
                    }
                    .width(min: 72, ideal: 80)
                    TableColumn("Run ID") { run in
                        Text(run.runID)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .help(run.runID)
                    }
                    .width(min: 220, ideal: 320)
                }
                .accessibilityLabel("Probierz run metadata")
            }
        }
        .padding(ProbierzTheme.Space.x6)
        .navigationTitle("Runs")
    }

    private func artifacts(_ snapshot: ProbierzSnapshot) -> some View {
        VStack(alignment: .leading, spacing: ProbierzTheme.Space.x4) {
            SectionHeading(
                title: "Artifact metadata",
                detail: "Type, size, integrity availability, and timestamp only. Names, paths, and contents are excluded."
            )

            if snapshot.artifacts.isEmpty {
                ContentUnavailableView(
                    "No artifact metadata",
                    systemImage: "archivebox",
                    description: Text("No artifact descriptors are available in local run manifests.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredArtifacts.isEmpty {
                EmptyFilterView(clear: model.clearFilters)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.filteredArtifacts) {
                    TableColumn("Kind") { artifact in
                        Label(artifact.kind.title, systemImage: artifact.kind.symbol)
                    }
                    .width(min: 124, ideal: 150)
                    TableColumn("Format") { artifact in
                        Text(artifact.fileExtension)
                            .font(.caption.monospaced())
                    }
                    .width(min: 64, ideal: 80)
                    TableColumn("Size") { artifact in
                        Text(ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file))
                            .monospacedDigit()
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("SHA-256") { artifact in
                        AvailabilityBadge(
                            isAvailable: artifact.hasSHA256,
                            availableTitle: "Recorded",
                            unavailableTitle: "Unavailable"
                        )
                    }
                    .width(min: 110, ideal: 128)
                    TableColumn("Modified") { artifact in
                        if let date = artifact.modifiedAt {
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                        } else {
                            Text("Unavailable")
                                .foregroundStyle(ProbierzTheme.muted)
                        }
                    }
                    .width(min: 150, ideal: 170)
                    TableColumn("Evidence") { artifact in
                        if artifact.kind == .protectedBundle, artifact.isAvailableOnDisk {
                            Button("Inspect") {
                                model.inspectEvidenceBundle(id: artifact.id)
                            }
                            .buttonStyle(.borderless)
                            .help("Open the read-only evidence bundle inspector")
                        } else {
                            Text("—")
                                .foregroundStyle(ProbierzTheme.muted)
                        }
                    }
                    .width(min: 72, ideal: 82)
                    TableColumn("Run ID") { artifact in
                        Text(artifact.runID)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .help(artifact.runID)
                    }
                    .width(min: 220, ideal: 320)
                }
                .accessibilityLabel("Probierz artifact metadata")
            }
        }
        .padding(ProbierzTheme.Space.x6)
        .navigationTitle("Artifacts")
    }

    private var privacyBoundary: some View {
        ProbierzPanel {
            HStack(alignment: .top, spacing: ProbierzTheme.Space.x3) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(ProbierzTheme.accent)
                VStack(alignment: .leading, spacing: ProbierzTheme.Space.x1) {
                    Text("Read-only metadata boundary")
                        .font(.headline)
                    Text("Probierz Desktop reads configuration-name presence and the documented run-manifest projection. It never reads screenshots, videos, traces, logs, protected bundle contents, prompts, responses, payloads, account data, recipient data, credentials, or secret values.")
                        .font(.subheadline)
                        .foregroundStyle(ProbierzTheme.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: ProbierzTheme.Space.x2) {
            Divider()
            Label("Local inventory", systemImage: "internaldrive")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ProbierzTheme.accent)
            Text("Metadata only")
                .font(.caption)
                .foregroundStyle(ProbierzTheme.secondary)
            Text("No artifact contents")
                .font(.caption2)
                .foregroundStyle(ProbierzTheme.muted)
        }
        .padding(ProbierzTheme.Space.x4)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var unavailableWorkspace: some View {
        ContentUnavailableView {
            Label("Probierz metadata unavailable", systemImage: "questionmark.folder")
        } description: {
            Text("Choose the Wisent workspace containing probierz/package.json and agent/history.mjs.")
        } actions: {
            Button("Choose Workspace", action: chooseWorkspace)
                .buttonStyle(.borderedProminent)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(ProbierzTheme.warning)
            .padding(ProbierzTheme.Space.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ProbierzTheme.warning.opacity(0.1),
                in: RoundedRectangle(cornerRadius: ProbierzTheme.Radius.small)
            )
            .accessibilityElement(children: .combine)
    }

    private func durationLabel(_ milliseconds: Double) -> String {
        guard milliseconds > 0 else { return "—" }
        let seconds = milliseconds / 1_000
        if seconds < 60 { return seconds.formatted(.number.precision(.fractionLength(1))) + " s" }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    private var evidenceBundleInspectorBinding: Binding<ArtifactMetadata?> {
        Binding(
            get: { model.inspectedEvidenceBundle },
            set: { artifact in
                if artifact == nil {
                    model.closeEvidenceBundleInspector()
                }
            }
        )
    }

    private func performOnboardingAction() {
        Task {
            switch await onboarding.performPrimaryAction() {
            case .showEvidenceBundles:
                destination = .artifacts
            case .advanced, .unavailable:
                break
            }
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Wisent workspace"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.workspaceRoot
        if panel.runModal() == .OK, let url = panel.url {
            model.selectWorkspace(url)
        }
    }
}

private struct EvidenceBundleInspector: View {
    @Environment(\.dismiss) private var dismiss
    let artifact: ArtifactMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: ProbierzTheme.Space.x5) {
            HStack(alignment: .top, spacing: ProbierzTheme.Space.x3) {
                Image(systemName: "lock.doc")
                    .font(.title)
                    .foregroundStyle(ProbierzTheme.accent)
                VStack(alignment: .leading, spacing: ProbierzTheme.Space.x1) {
                    Text("Protected evidence bundle")
                        .font(.title2.weight(.semibold))
                    Text("Opened for read-only provenance inspection")
                        .foregroundStyle(ProbierzTheme.secondary)
                }
            }

            ProbierzPanel {
                Grid(alignment: .leading, horizontalSpacing: ProbierzTheme.Space.x5, verticalSpacing: ProbierzTheme.Space.x3) {
                    inspectorRow("Source run", artifact.runID, monospaced: true)
                    inspectorRow("Format", artifact.fileExtension, monospaced: true)
                    inspectorRow(
                        "Size",
                        ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file)
                    )
                    inspectorRow("SHA-256 field", artifact.hasSHA256 ? "Recorded" : "Unavailable")
                    inspectorRow(
                        "Modified",
                        artifact.modifiedAt?.formatted(
                            .dateTime.year().month().day().hour().minute().second()
                        ) ?? "Unavailable"
                    )
                }
            }

            Label(
                "The run manifest references a regular, non-symlink .pev file inside its run directory.",
                systemImage: "checkmark.shield"
            )
            .font(.subheadline)
            .foregroundStyle(ProbierzTheme.success)

            Text("Probierz Desktop does not read or decrypt the bundle payload, and it does not expose the local path. This inspector is the bundle's provenance projection only.")
                .font(.subheadline)
                .foregroundStyle(ProbierzTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ProbierzTheme.Space.x6)
        .frame(width: 580)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Protected evidence bundle inspector")
    }

    private func inspectorRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(ProbierzTheme.secondary)
            if monospaced {
                Text(value)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .textSelection(.enabled)
            }
        }
    }
}
