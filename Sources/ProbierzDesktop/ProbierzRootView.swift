import AppKit
import SwiftUI
import WisentDesignSystem

struct ProbierzRootView: View {
    @ObservedObject var model: ProbierzModel
    @ObservedObject var onboarding: ProbierzOnboarding
    @State private var destination: ProbierzDestination? = .overview

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: WisentDesign.Space.x3) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: WisentDesign.Space.x4, weight: .semibold))
                        .foregroundStyle(WisentDesign.brandStrong)
                        .frame(width: WisentDesign.Space.x10, height: WisentDesign.Space.x10)
                        .background(
                            WisentDesign.brandSoft,
                            in: RoundedRectangle(cornerRadius: WisentDesign.Radius.medium)
                        )
                    VStack(alignment: .leading, spacing: WisentDesign.Space.x1) {
                        Text("Probierz")
                            .font(WisentTypography.heading(18))
                            .foregroundStyle(WisentDesign.ink)
                        Text("QUALITY EVIDENCE")
                            .font(WisentTypography.monoMedium(9))
                            .tracking(0.7)
                            .foregroundStyle(WisentDesign.muted)
                    }
                    Spacer()
                }
                .padding(WisentDesign.Space.x4)

                Divider()

                List(ProbierzDestination.allCases, selection: $destination) { item in
                    Label(item.title, systemImage: item.symbol)
                        .padding(.vertical, WisentDesign.Space.x1)
                        .tag(item)
                }
                .font(WisentTypography.bodyMedium(13))
                .scrollContentBackground(.hidden)

                sidebarFooter
            }
            .background(WisentDesign.canvasMuted)
            .navigationSplitViewColumnWidth(
                min: WisentDesign.Layout.sidebarMinimumWidth,
                ideal: WisentDesign.Layout.sidebarIdealWidth
            )
        } detail: {
            VStack(spacing: 0) {
                if let errorMessage = model.errorMessage {
                    errorBanner(errorMessage)
                        .padding(.horizontal, WisentDesign.Space.x6)
                        .padding(.top, WisentDesign.Space.x3)
                }
                if let screen = onboarding.screen {
                    ProbierzOnboardingCard(
                        screen: screen,
                        isWorking: onboarding.isWorking,
                        action: performOnboardingAction
                    )
                    .padding(.horizontal, WisentDesign.Space.x6)
                    .padding(.top, WisentDesign.Space.x3)
                }
                Group {
                    if let snapshot = model.snapshot {
                        destinationView(snapshot)
                    } else if model.isRefreshing {
                        loadingWorkspace
                    } else {
                        unavailableWorkspace
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background { WisentCanvasBackground() }
        }
        .frame(minWidth: ProbierzLayout.minimumWindowWidth, minHeight: ProbierzLayout.minimumWindowHeight)
        .tint(WisentDesign.brand)
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
            VStack(alignment: .leading, spacing: WisentDesign.Space.x6) {
                WisentPageHeader(
                    eyebrow: "Quality evidence",
                    title: "Probierz",
                    detail: "Cross-platform verification readiness, source identity, and evidence metadata.",
                    symbol: "checkmark.seal.fill"
                )
                aggregateStatus(snapshot)

                VStack(alignment: .leading, spacing: WisentDesign.Space.x3) {
                    WisentSectionHeader(
                        "Surface readiness",
                        detail: "Declared product surfaces and their local execution contracts.",
                        trailing: "\(model.filteredContracts.count) surfaces"
                    )
                    if model.filteredContracts.isEmpty, model.hasActiveFilter {
                        EmptyFilterView(clear: model.clearFilters)
                            .frame(minHeight: 240)
                    } else if snapshot.contracts.isEmpty {
                        WisentEmptyState(
                            title: "No surface contracts",
                            detail: "This workspace does not declare any Probierz product surfaces yet.",
                            symbol: "rectangle.3.group"
                        )
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300), spacing: WisentDesign.Space.x3)],
                            spacing: WisentDesign.Space.x3
                        ) {
                            ForEach(model.filteredContracts) { contract in
                                contractRow(contract)
                            }
                        }
                    }
                }
                privacyBoundary
            }
            .frame(maxWidth: WisentDesign.Layout.contentMaximumWidth, alignment: .leading)
            .padding(WisentDesign.Space.x6)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("Overview")
    }


    private func aggregateStatus(_ snapshot: ProbierzSnapshot) -> some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x3) {
            WisentSectionHeader(
                "Workspace snapshot",
                detail: "Readiness and inventory from the current local metadata projection.",
                trailing: "Updated \(snapshot.loadedAt.formatted(date: .abbreviated, time: .shortened))"
            )
            LazyVGrid(columns: metricColumns, spacing: WisentDesign.Space.x3) {
                WisentMetricCard(
                    title: "Contracts",
                    value: "\(snapshot.availableContractCount)/\(snapshot.contracts.count)",
                    detail: "available locally",
                    symbol: "checkmark.seal",
                    tone: snapshot.availableContractCount == snapshot.contracts.count ? .success : .warning
                )
                WisentMetricCard(
                    title: "Configuration",
                    value: "\(snapshot.configuredCount)/\(snapshot.configurations.count)",
                    detail: "declared names present",
                    symbol: "key.horizontal",
                    tone: snapshot.configuredCount == snapshot.configurations.count ? .success : .warning
                )
                WisentMetricCard(
                    title: "Recorded runs",
                    value: snapshot.summary.total.formatted(),
                    detail: "manifest records",
                    symbol: "checklist",
                    tone: snapshot.summary.failed > 0 ? .danger : .brand
                )
                WisentMetricCard(
                    title: "Artifact inventory",
                    value: snapshot.artifacts.count.formatted(),
                    detail: ByteCountFormatter.string(fromByteCount: snapshot.artifactBytes, countStyle: .file),
                    symbol: "archivebox",
                    tone: .info
                )
            }
            WisentPanel {
                HStack(spacing: WisentDesign.Space.x2) {
                    summaryStatus(status: .passed, count: snapshot.summary.passed)
                    summaryStatus(status: .failed, count: snapshot.summary.failed)
                    summaryStatus(status: .blocked, count: snapshot.summary.blocked)
                    summaryStatus(status: .canceled, count: snapshot.summary.canceled)
                    summaryStatus(status: .incomplete, count: snapshot.summary.incomplete)
                    Spacer(minLength: 0)
                    if snapshot.manifestsTruncated {
                        WisentBadge(
                            "Inventory limit reached",
                            symbol: "exclamationmark.triangle.fill",
                            tone: .warning
                        )
                    }
                }
            }
        }
    }

    private func summaryStatus(status: RunStatus, count: Int) -> some View {
        WisentBadge(
            "\(count) \(status.title.lowercased())",
            symbol: status.symbol,
            tone: status.wisentTone
        )
    }

    private func contractRow(_ contract: ContractItem) -> some View {
        WisentPanel {
            HStack(alignment: .top, spacing: WisentDesign.Space.x3) {
                VStack(alignment: .leading, spacing: WisentDesign.Space.x2) {
                    Text(contract.title)
                        .font(WisentTypography.bodyMedium(14))
                        .foregroundStyle(WisentDesign.ink)
                    Text(contract.detail)
                        .font(WisentTypography.body(13))
                        .foregroundStyle(WisentDesign.secondary)
                    Text(contract.relativePath)
                        .font(WisentTypography.mono(11))
                        .foregroundStyle(WisentDesign.muted)
                        .textSelection(.enabled)
                }
                Spacer(minLength: WisentDesign.Space.x3)
                VStack(alignment: .trailing, spacing: WisentDesign.Space.x2) {
                    AvailabilityBadge(
                        isAvailable: contract.isAvailable,
                        availableTitle: "Available",
                        unavailableTitle: "Unavailable"
                    )
                    if let modifiedAt = contract.modifiedAt {
                        Text(modifiedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(WisentTypography.mono(10))
                            .foregroundStyle(WisentDesign.muted)
                    }
                }
            }
        }
    }

    private func configuration(_ snapshot: ProbierzSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WisentDesign.Space.x6) {
                WisentPageHeader(
                    eyebrow: "Local inventory",
                    title: "Configuration",
                    detail: "Presence only. Values are never retained or displayed.",
                    symbol: "gearshape.2"
                )
                LazyVGrid(columns: metricColumns, spacing: WisentDesign.Space.x3) {
                    WisentMetricCard(
                        title: "Declared names",
                        value: snapshot.configurations.count.formatted(),
                        detail: "configuration keys in scope",
                        symbol: "list.bullet.rectangle",
                        tone: .brand
                    )
                    WisentMetricCard(
                        title: "Present names",
                        value: snapshot.configuredCount.formatted(),
                        detail: "values detected without reading them",
                        symbol: "checkmark.shield",
                        tone: snapshot.configuredCount == snapshot.configurations.count ? .success : .warning
                    )
                }
                WisentPanel {
                    VStack(alignment: .leading, spacing: WisentDesign.Space.x3) {
                        WisentSectionHeader("Workspace", detail: "Current metadata source")
                        Label {
                            Text(snapshot.repositoryRoot.path)
                                .font(WisentTypography.mono(11))
                                .foregroundStyle(WisentDesign.secondary)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "folder")
                                .foregroundStyle(WisentDesign.brand)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: WisentDesign.Space.x3) {
                    WisentSectionHeader(
                        "Declared configuration",
                        detail: "Only the name and presence state cross the read-only boundary.",
                        trailing: "\(model.filteredConfigurations.count) names"
                    )
                    if snapshot.configurations.isEmpty {
                        WisentEmptyState(
                            title: "No configuration names",
                            detail: "This workspace does not declare configuration metadata for Probierz.",
                            symbol: "key.slash"
                        )
                    } else if model.filteredConfigurations.isEmpty, model.hasActiveFilter {
                        EmptyFilterView(clear: model.clearFilters)
                            .frame(minHeight: 280)
                    } else {
                        WisentPanel {
                            VStack(spacing: 0) {
                                ForEach(Array(model.filteredConfigurations.enumerated()), id: \.element.id) { index, item in
                                    HStack(spacing: WisentDesign.Space.x3) {
                                        Image(systemName: "key.horizontal")
                                            .foregroundStyle(WisentDesign.brand)
                                            .frame(width: WisentDesign.Space.x5)
                                        Text(item.name)
                                            .font(WisentTypography.monoMedium(12))
                                            .foregroundStyle(WisentDesign.ink)
                                        Spacer()
                                        AvailabilityBadge(
                                            isAvailable: item.isPresent,
                                            availableTitle: "Present",
                                            unavailableTitle: "Not present"
                                        )
                                    }
                                    .padding(.vertical, WisentDesign.Space.x3)
                                    if index < model.filteredConfigurations.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
                privacyBoundary
            }
            .frame(maxWidth: WisentDesign.Layout.contentMaximumWidth, alignment: .leading)
            .padding(WisentDesign.Space.x6)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("Configuration")
    }

    private func runs(_ snapshot: ProbierzSnapshot) -> some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
            HStack(alignment: .bottom, spacing: WisentDesign.Space.x4) {
                WisentPageHeader(
                    eyebrow: "Manifest inventory",
                    title: "Run status",
                    detail: "Normalized from the read-only run-manifest metadata boundary.",
                    symbol: "checklist"
                )
                Spacer(minLength: WisentDesign.Space.x4)
                Picker("Status", selection: $model.statusFilter) {
                    Text("All statuses").tag(RunStatus?.none)
                    ForEach(RunStatus.allCases) { status in
                        Text(status.title).tag(Optional(status))
                    }
                }
                .frame(width: 190)
                .labelsHidden()
                .accessibilityLabel("Filter runs by status")
            }
            LazyVGrid(columns: metricColumns, spacing: WisentDesign.Space.x3) {
                WisentMetricCard(
                    title: "Recorded",
                    value: snapshot.summary.total.formatted(),
                    detail: "run manifests",
                    symbol: "doc.text.magnifyingglass",
                    tone: .brand
                )
                WisentMetricCard(
                    title: "Needs attention",
                    value: (snapshot.summary.failed + snapshot.summary.blocked + snapshot.summary.incomplete).formatted(),
                    detail: "failed, blocked, or incomplete",
                    symbol: "exclamationmark.triangle.fill",
                    tone: snapshot.summary.failed > 0 ? .danger : .warning
                )
            }
            if snapshot.runs.isEmpty {
                WisentEmptyState(
                    title: "No run metadata",
                    detail: "Probierz has not recorded a run manifest in this workspace.",
                    symbol: "checklist"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredRuns.isEmpty {
                EmptyFilterView(clear: model.clearFilters)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WisentPanel(padding: 0) {
                    Table(model.filteredRuns) {
                        TableColumn("Status") { run in
                            StatusBadge(status: run.status)
                        }
                        .width(min: 96, ideal: 104)
                        TableColumn("Target") { run in
                            Text(run.target)
                                .lineLimit(1)
                                .help(run.target)
                        }
                        .width(min: 104, ideal: 140)
                        TableColumn("Started") { run in
                            if let date = run.startedAt {
                                Text(date, format: .dateTime.year().month().day().hour().minute())
                            } else {
                                Text("Unavailable")
                                    .foregroundStyle(WisentDesign.muted)
                            }
                        }
                        .width(min: 126, ideal: 150)
                        TableColumn("Duration") { run in
                            Text(durationLabel(run.durationMilliseconds))
                                .monospacedDigit()
                        }
                        .width(min: 66, ideal: 82)
                        TableColumn("Artifacts") { run in
                            Text(run.artifactCount.formatted())
                                .monospacedDigit()
                        }
                        .width(min: 58, ideal: 72)
                        TableColumn("Run ID") { run in
                            Text(run.runID)
                                .font(WisentTypography.mono(11))
                                .lineLimit(1)
                                .help(run.runID)
                        }
                        .width(min: 160, ideal: 260)
                    }
                    .font(WisentTypography.body(12))
                    .accessibilityLabel("Probierz run metadata")
                }
                .clipShape(RoundedRectangle(cornerRadius: WisentDesign.Radius.large))
            }
        }
        .frame(maxWidth: WisentDesign.Layout.contentMaximumWidth, alignment: .leading)
        .padding(WisentDesign.Space.x6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Runs")
    }

    private func artifacts(_ snapshot: ProbierzSnapshot) -> some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
            WisentPageHeader(
                eyebrow: "Evidence inventory",
                title: "Artifacts",
                detail: "Type, size, integrity availability, and timestamp only. Names, paths, and contents are excluded.",
                symbol: "archivebox"
            )
            LazyVGrid(columns: metricColumns, spacing: WisentDesign.Space.x3) {
                WisentMetricCard(
                    title: "Descriptors",
                    value: snapshot.artifacts.count.formatted(),
                    detail: "artifact metadata records",
                    symbol: "archivebox",
                    tone: .brand
                )
                WisentMetricCard(
                    title: "Inventory size",
                    value: ByteCountFormatter.string(fromByteCount: snapshot.artifactBytes, countStyle: .file),
                    detail: "declared bytes",
                    symbol: "externaldrive",
                    tone: .info
                )
            }
            if snapshot.artifacts.isEmpty {
                WisentEmptyState(
                    title: "No artifact metadata",
                    detail: "No artifact descriptors are available in local run manifests.",
                    symbol: "archivebox"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredArtifacts.isEmpty {
                EmptyFilterView(clear: model.clearFilters)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WisentPanel(padding: 0) {
                    Table(model.filteredArtifacts) {
                        TableColumn("Kind") { artifact in
                            Label(artifact.kind.title, systemImage: artifact.kind.symbol)
                                .lineLimit(1)
                                .help(artifact.kind.title)
                        }
                        .width(min: 96, ideal: 120)
                        TableColumn("Format") { artifact in
                            Text(artifact.fileExtension)
                                .font(WisentTypography.mono(11))
                        }
                        .width(min: 50, ideal: 64)
                        TableColumn("Size") { artifact in
                            Text(ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file))
                                .monospacedDigit()
                        }
                        .width(min: 70, ideal: 88)
                        TableColumn("SHA-256") { artifact in
                            AvailabilityBadge(
                                isAvailable: artifact.hasSHA256,
                                availableTitle: "Recorded",
                                unavailableTitle: "Unavailable"
                            )
                        }
                        .width(min: 92, ideal: 112)
                        TableColumn("Modified") { artifact in
                            if let date = artifact.modifiedAt {
                                Text(date, format: .dateTime.year().month().day().hour().minute())
                            } else {
                                Text("Unavailable")
                                    .foregroundStyle(WisentDesign.muted)
                            }
                        }
                        .width(min: 122, ideal: 146)
                        TableColumn("Evidence") { artifact in
                            if artifact.kind == .protectedBundle, artifact.isAvailableOnDisk {
                                Button("Inspect") {
                                    model.inspectEvidenceBundle(id: artifact.id)
                                }
                                .buttonStyle(.borderless)
                                .help("Open the read-only evidence bundle inspector")
                            } else {
                                Text("—")
                                    .foregroundStyle(WisentDesign.muted)
                            }
                        }
                        .width(min: 60, ideal: 72)
                        TableColumn("Run ID") { artifact in
                            Text(artifact.runID)
                                .font(WisentTypography.mono(11))
                                .lineLimit(1)
                                .help(artifact.runID)
                        }
                        .width(min: 146, ideal: 240)
                    }
                    .font(WisentTypography.body(12))
                    .accessibilityLabel("Probierz artifact metadata")
                }
                .clipShape(RoundedRectangle(cornerRadius: WisentDesign.Radius.large))
            }
        }
        .frame(maxWidth: WisentDesign.Layout.contentMaximumWidth, alignment: .leading)
        .padding(WisentDesign.Space.x6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Artifacts")
    }

    private var privacyBoundary: some View {
        WisentPanel {
            Label {
                VStack(alignment: .leading, spacing: WisentDesign.Space.x1) {
                    Text("Read-only metadata boundary")
                        .font(WisentTypography.bodyMedium(13))
                        .foregroundStyle(WisentDesign.ink)
                    Text("Probierz Desktop reads configuration-name presence and the documented run-manifest projection. It never reads screenshots, videos, traces, logs, protected bundle contents, prompts, responses, payloads, account data, recipient data, credentials, or secret values.")
                        .font(WisentTypography.body(12))
                        .foregroundStyle(WisentDesign.secondary)
                }
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(WisentDesign.brand)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x2) {
            WisentBadge("Local inventory", symbol: "internaldrive", tone: .brand)
            Text("Metadata only")
                .font(WisentTypography.body(11))
                .foregroundStyle(WisentDesign.secondary)
            Text("No artifact contents")
                .font(WisentTypography.mono(10))
                .foregroundStyle(WisentDesign.muted)
        }
        .padding(WisentDesign.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WisentDesign.surface)
        .accessibilityElement(children: .combine)
    }

    private var loadingWorkspace: some View {
        WisentPanel {
            HStack(spacing: WisentDesign.Space.x3) {
                ProgressView()
                    .controlSize(.small)
                    .tint(WisentDesign.brand)
                VStack(alignment: .leading, spacing: WisentDesign.Space.x1) {
                    Text("Loading workspace metadata")
                        .font(WisentTypography.bodyMedium(14))
                        .foregroundStyle(WisentDesign.ink)
                    Text("Reading the documented local projection without opening artifact contents.")
                        .font(WisentTypography.body(12))
                        .foregroundStyle(WisentDesign.secondary)
                }
            }
        }
        .padding(WisentDesign.Space.x6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading Probierz workspace metadata")
    }

    private var unavailableWorkspace: some View {
        VStack(spacing: WisentDesign.Space.x4) {
            WisentEmptyState(
                title: "Probierz metadata unavailable",
                detail: "Choose the Wisent workspace containing probierz/package.json and agent/history.mjs.",
                symbol: "questionmark.folder"
            )
            Button("Choose Workspace", action: chooseWorkspace)
                .buttonStyle(WisentPrimaryButtonStyle())
        }
    }

    private func errorBanner(_ message: String) -> some View {
        WisentPanel(padding: WisentDesign.Space.x3) {
            HStack(alignment: .top, spacing: WisentDesign.Space.x3) {
                WisentBadge(
                    "Refresh failed",
                    symbol: "exclamationmark.triangle.fill",
                    tone: .danger
                )
                Text(message)
                    .font(WisentTypography.body(12))
                    .foregroundStyle(WisentDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var metricColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: WisentDesign.Space.x3),
            GridItem(.flexible(), spacing: WisentDesign.Space.x3),
        ]
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
        ZStack {
            WisentCanvasBackground()
            VStack(alignment: .leading, spacing: WisentDesign.Space.x5) {
                WisentPageHeader(
                    eyebrow: "Read-only provenance",
                    title: "Protected evidence bundle",
                    detail: "Inspect the manifest projection without opening or decrypting the bundle payload.",
                    symbol: "lock.doc"
                )
                WisentPanel {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: WisentDesign.Space.x5,
                        verticalSpacing: WisentDesign.Space.x3
                    ) {
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
                HStack(spacing: WisentDesign.Space.x2) {
                    WisentBadge(
                        artifact.hasSHA256 ? "Integrity field recorded" : "Integrity field unavailable",
                        symbol: artifact.hasSHA256 ? "checkmark.shield.fill" : "shield.slash",
                        tone: artifact.hasSHA256 ? .success : .warning
                    )
                    WisentBadge(
                        "Regular non-symlink file",
                        symbol: "doc.badge.checkmark",
                        tone: .success
                    )
                }
                Text("The run manifest references a regular, non-symlink .pev file inside its run directory. Probierz Desktop does not read or decrypt the bundle payload, and it does not expose the local path.")
                    .font(WisentTypography.body(13))
                    .foregroundStyle(WisentDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(WisentPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(WisentDesign.Space.x6)
        }
        .frame(width: ProbierzLayout.inspectorWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Protected evidence bundle inspector")
    }

    private func inspectorRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(WisentTypography.body(12))
                .foregroundStyle(WisentDesign.secondary)
            if monospaced {
                Text(value)
                    .font(WisentTypography.mono(12))
                    .foregroundStyle(WisentDesign.ink)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(WisentTypography.bodyMedium(12))
                    .foregroundStyle(WisentDesign.ink)
                    .textSelection(.enabled)
            }
        }
    }
}
