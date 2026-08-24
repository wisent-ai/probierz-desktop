import AppKit
import SwiftUI
import WisentDesignSystem

struct ProbierzRootView: View {
    @ObservedObject var model: ProbierzModel
    @ObservedObject var onboarding: ProbierzOnboarding

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .toolbar { toolbarContent }
        }
        .frame(
            minWidth: WisentAppLayout.minimumWindowWidth,
            minHeight: WisentAppLayout.minimumWindowHeight
        )
        .tint(WisentDesign.brand)
        .task {
            await onboarding.start()
            if model.snapshot == nil, model.workspaceRoot != nil {
                await model.refresh()
            }
        }
    }

    // MARK: - Sidebar

    /// Rows are buttons, not `NavigationLink`s inside a `List`.
    ///
    /// The recorded defect in Skarbiec: clicking a `List` row did not change the
    /// destination, leaving the window navigable by keyboard only. A `Button`
    /// carries one unambiguous action.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
            Divider()
            productScope
            ScrollView {
                VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
                    ForEach(DestinationGroup.all) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title.uppercased())
                                .font(WisentTypeScale.eyebrow())
                                .tracking(0.8)
                                .foregroundStyle(WisentDesign.muted)
                                .padding(.horizontal, WisentDesign.Space.x4)
                                .padding(.bottom, WisentDesign.Space.x1)
                            ForEach(group.destinations) { destination in
                                destinationRow(destination)
                            }
                        }
                    }
                }
                .padding(.vertical, WisentDesign.Space.x4)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: WisentAppLayout.sidebarWidth, idealWidth: WisentAppLayout.sidebarWidth)
        .background(WisentDesign.canvasMuted)
        .navigationSplitViewColumnWidth(
            min: WisentAppLayout.sidebarWidth,
            ideal: WisentAppLayout.sidebarWidth
        )
    }

    private var brandHeader: some View {
        HStack(spacing: WisentDesign.Space.x3) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: WisentDesign.Space.x4, weight: .semibold))
                .foregroundStyle(WisentDesign.brandStrong)
                .frame(width: WisentDesign.Space.x10, height: WisentDesign.Space.x10)
                .background(
                    WisentDesign.brandSoft,
                    in: RoundedRectangle(cornerRadius: WisentDesign.Radius.medium)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WisentDesign.Space.x1) {
                Text("Probierz")
                    .font(WisentTypography.heading(17))
                    .foregroundStyle(WisentDesign.ink)
                Text("QUALITY EVIDENCE")
                    .font(WisentTypography.monoMedium(9))
                    .tracking(0.7)
                    .foregroundStyle(WisentDesign.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(WisentDesign.Space.x4)
    }

    /// The product in view is scope, not a destination.
    ///
    /// Probierz keys history, journeys and merge verdicts by app ID, so every
    /// screen reads this one value. As a tab it would cost a destination and
    /// still leave the operator guessing which product the numbers describe.
    private var productScope: some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x1) {
            Text("PRODUCT IN VIEW")
                .font(WisentTypography.monoSemibold(8))
                .tracking(0.6)
                .foregroundStyle(WisentDesign.muted)
            Menu {
                Button {
                    model.productScope = nil
                } label: {
                    if model.productScope == nil {
                        Label("All products", systemImage: "checkmark")
                    } else {
                        Text("All products")
                    }
                }
                if let snapshot = model.snapshot, !snapshot.productIDs.isEmpty {
                    Divider()
                    ForEach(snapshot.productIDs, id: \.self) { product in
                        Button {
                            model.productScope = product
                        } label: {
                            if model.productScope == product {
                                Label(product, systemImage: "checkmark")
                            } else {
                                Text(product)
                            }
                        }
                    }
                } else {
                    Text("No product manifest read yet")
                }
                Divider()
                Button("Choose Workspace…", action: chooseWorkspace)
            } label: {
                Text(model.scopeLabel)
                    .font(WisentTypeScale.identifierSmall())
                    .foregroundStyle(WisentDesign.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(WisentDesign.Space.x3)
        .background(WisentDesign.surface, in: RoundedRectangle(cornerRadius: WisentDesign.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: WisentDesign.Radius.medium)
                .stroke(WisentDesign.border, lineWidth: WisentDesign.hairline)
        }
        .padding(.horizontal, WisentDesign.Space.x3)
        .padding(.vertical, WisentDesign.Space.x3)
        .accessibilityIdentifier("probierz.product-scope")
    }

    private func destinationRow(_ destination: ProbierzDestination) -> some View {
        Button {
            model.destination = destination
        } label: {
            HStack(spacing: WisentDesign.Space.x3) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected(destination) ? WisentDesign.brand : WisentDesign.muted)
                    .frame(width: 16)
                Text(destination.title)
                    .font(isSelected(destination) ? WisentTypography.bodyMedium(13) : WisentTypography.body(13))
                    .foregroundStyle(isSelected(destination) ? WisentDesign.ink : WisentDesign.secondary)
                Spacer(minLength: WisentDesign.Space.x2)
                indicator(for: destination)
            }
            .padding(.horizontal, WisentDesign.Space.x3)
            .padding(.vertical, WisentDesign.Space.x2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected(destination) {
                    RoundedRectangle(cornerRadius: WisentDesign.Radius.small)
                        .fill(WisentDesign.surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: WisentDesign.Radius.small)
                                .stroke(WisentDesign.border, lineWidth: WisentDesign.hairline)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, WisentDesign.Space.x2)
        .accessibilityLabel(destination.title)
        .accessibilityIdentifier("probierz.destination.\(destination.rawValue)")
        .accessibilityAddTraits(isSelected(destination) ? [.isSelected] : [])
    }

    private func isSelected(_ destination: ProbierzDestination) -> Bool {
        model.destination == destination
    }

    /// A count only where a count changes what the operator does next.
    @ViewBuilder
    private func indicator(for destination: ProbierzDestination) -> some View {
        switch destination {
        case .runs where model.summary.status.needsAttention > 0:
            countBadge(model.summary.status.needsAttention, tone: WisentDesign.danger)
        case .verdicts where !model.blockingVerdicts.isEmpty:
            countBadge(model.blockingVerdicts.count, tone: WisentDesign.warning)
        case .preflight where blockedPreflightCount > 0:
            countBadge(blockedPreflightCount, tone: WisentDesign.warning)
        case .workspace where model.snapshot?.manifestsTruncated == true:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WisentDesign.warning)
                .accessibilityLabel("Inventory truncated")
        default:
            EmptyView()
        }
    }

    private func countBadge(_ value: Int, tone: Color) -> some View {
        Text(value.formatted(.number))
            .font(WisentTypography.monoSemibold(9))
            .foregroundStyle(tone)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tone.opacity(0.12), in: Capsule())
    }

    private var blockedPreflightCount: Int {
        model.snapshot?.preflights.filter { !$0.isReady }.count ?? 0
    }


    // MARK: - Detail

    /// The detail column is bound to the window, like every screen inside it.
    ///
    /// Measured before this: the onboarding card and the screen sat as siblings
    /// in an unbounded `VStack`, so their combined intrinsic height pushed the
    /// whole split view off the top edge — the accessibility frames put the
    /// sidebar's last row above the window origin, 442 pt out of a 860 pt
    /// window. `WisentScreen` bounds itself; a container that stacks something
    /// above it has to do the same.
    private var detail: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if let screen = onboarding.screen {
                    ProbierzOnboardingCard(
                        screen: screen,
                        isWorking: onboarding.isWorking,
                        action: performOnboardingAction
                    )
                    .padding(.horizontal, WisentDesign.Space.x5)
                    .padding(.top, WisentDesign.Space.x4)
                    .background(WisentDesign.canvas)
                    .fixedSize(horizontal: false, vertical: true)
                }
                destinationView
                    .frame(maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .clipped()
        }
        .background { WisentCanvasBackground() }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch model.destination {
        case .posture:
            PostureView(model: model, chooseWorkspace: chooseWorkspace)
        case .runs:
            RunsView(model: model)
        case .artifacts:
            ArtifactsView(model: model, onboarding: onboarding)
        case .verdicts:
            VerdictsView(model: model)
        case .surfaces:
            SurfacesView(model: model)
        case .journeys:
            JourneysView(model: model)
        case .preflight:
            PreflightView(model: model)
        case .workspace:
            WorkspaceView(model: model, chooseWorkspace: chooseWorkspace)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh Local Metadata", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing || model.workspaceRoot == nil)
            .keyboardShortcut("r", modifiers: .command)
            .help("Re-read run manifests, app manifests and spec inventory")
            .accessibilityLabel(model.isRefreshing ? "Refreshing Probierz metadata" : "Refresh Probierz metadata")
        }
    }

    // MARK: - Actions

    private func performOnboardingAction() {
        Task {
            switch await onboarding.performPrimaryAction() {
            case .showEvidenceBundles:
                model.destination = .artifacts
                model.selectFirstProtectedBundle()
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
