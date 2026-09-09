import Foundation
import SwiftUI
import WisentDesignSystem

/// The register of attempts that did not hold.
///
/// `FailuresView` shows what a running product reported about itself. This
/// screen shows the other half: a claim somebody made that turned out to be
/// wrong, what it was worth, and whether anything ever closed it. Same anatomy
/// as the other tables — a facet rail with counts, the entries newest first,
/// and the selected entry's claim, envelope and resolution beside them.
struct RegisterView: View {
    @ObservedObject var model: ProbierzModel
    @StateObject private var store = RegisterStore()
    @State private var note = ""
    @State private var runID = ""
    @State private var recording = false
    private var root: URL? { model.snapshot?.repositoryRoot }

    var body: some View {
        WisentScreen(
            title: "Register",
            scope: model.scopeLabel,
            freshness: store.freshnessLabel,
            actions: [
                WisentAction("Record incident", symbol: "plus", kind: .primary, isEnabled: root != nil) {
                    recording = true
                },
                WisentAction(
                    "Refresh",
                    symbol: "arrow.clockwise",
                    kind: .secondary,
                    isEnabled: model.workspaceRoot != nil
                ) {
                    reload()
                }
            ],
            scrolls: false,
            constrainsWidth: false
        ) {
            HStack(spacing: 0) {
                WisentFacetRail(
                    groups: facetGroups,
                    footerTitle: "Selection",
                    footerDetail: "\(store.visible.count.formatted(.number)) of \(store.entries.count.formatted(.number)) recorded"
                )
                centre
                inspector
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { reload() }
        .onChange(of: model.workspaceRoot) { reload() }
        .onChange(of: store.stateFilter) { reload() }
        .onChange(of: store.selectedID) {
            note = ""
            runID = ""
            if let root, let id = store.selectedID {
                Task { await store.show(workspaceRoot: root, id: id) }
            }
        }
        .sheet(isPresented: $recording) {
            if let root { RecordIncidentSheet(store: store, root: root) }
        }
    }

    private func reload() {
        guard let root else { return }
        Task { await store.load(workspaceRoot: root) }
    }

    // MARK: - Facets

    private var facetGroups: [WisentFacetGroup] {
        [
            WisentFacetGroup(
                "State",
                facets: [
                    WisentFacet(
                        id: "state.all",
                        label: "Everything recorded",
                        count: store.entries.count,
                        isSelected: store.stateFilter == nil
                    ) {
                        store.stateFilter = nil
                    },
                    WisentFacet(
                        id: "state.open",
                        label: "Open",
                        count: store.openCount,
                        isSelected: store.stateFilter == "open"
                    ) {
                        store.stateFilter = "open"
                    },
                    WisentFacet(
                        id: "state.resolved",
                        label: "Resolved",
                        count: store.resolvedCount,
                        isSelected: store.stateFilter == "resolved"
                    ) {
                        store.stateFilter = "resolved"
                    },
                ]
            )
        ]
    }

    // MARK: - Centre

    @ViewBuilder
    private var centre: some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
            if model.workspaceRoot == nil {
                WisentEmptyPanel(
                    title: "No workspace selected",
                    detail: "Choose the workspace whose register you want to read.",
                    symbol: "questionmark.folder"
                )
                Spacer(minLength: 0)
            } else if let problem = store.problem, store.entries.isEmpty {
                WisentEmptyPanel(
                    title: "The register could not be read",
                    detail: problem,
                    symbol: "exclamationmark.triangle"
                )
                Spacer(minLength: 0)
            } else if store.entries.isEmpty {
                WisentEmptyPanel(
                    title: "Nothing has been recorded",
                    detail: "probierz incident record --claim <text> writes the first entry.",
                    symbol: "checkmark.shield"
                )
                Spacer(minLength: 0)
            } else if store.visible.isEmpty {
                WisentEmptyPanel(
                    title: "Nothing in this state",
                    detail: "There are \(store.entries.count.formatted(.number)) entries; this state has none.",
                    symbol: "line.3.horizontal.decrease.circle",
                    action: WisentAction("Show everything", kind: .secondary) { store.stateFilter = nil }
                )
                Spacer(minLength: 0)
            } else {
                table
            }
        }
        .padding(WisentDesign.Space.x5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var table: some View {
        WisentTableFrame {
            Table(store.visible, selection: $store.selectedID) {
                TableColumn("RECORDED") { entry in
                    Text(entry.incident.recordedAt)
                        .font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                }
                .width(min: 150, ideal: 180)
                TableColumn("STATE") { entry in
                    stateCell(entry)
                }
                .width(min: 64, ideal: 76)
                TableColumn("ACTOR") { entry in
                    Text(entry.incident.actor)
                        .font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 100)
                TableColumn("CLAIM") { entry in
                    Text(entry.incident.claim)
                        .font(WisentTypeScale.body())
                        .foregroundStyle(WisentDesign.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.incident.claim)
                }
                .width(min: 180, ideal: 260)
            }
            .tableStyle(.inset)
            .accessibilityLabel("Attempts that did not hold")
        }
    }

    @ViewBuilder
    private func stateCell(_ entry: RegisterEntry) -> some View {
        if entry.isOpen {
            Text("open")
                .font(WisentTypeScale.identifierSmall())
                .foregroundStyle(WisentDesign.warning)
        } else {
            Text("resolved")
                .font(WisentTypeScale.identifierSmall())
                .foregroundStyle(WisentDesign.secondary)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
                TextField("Maximum entries", value: $store.limit, format: .number)
                    .textFieldStyle(.roundedBorder)
                Button("Apply limit") { reload() }
                if let entry = store.selected {
                    selectedEntry(entry)
                } else {
                    Text("Select an entry to read the claim, failure, and resolution.")
                        .font(WisentTypeScale.body())
                        .foregroundStyle(WisentDesign.secondary)
                }
                if let problem = store.problem {
                    Text(problem).foregroundStyle(WisentDesign.danger).textSelection(.enabled)
                }
                if let detail = store.detail {
                    section("Full entry") {
                        Text(detail).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .padding(WisentDesign.Space.x5)
        }
        .frame(width: 340, alignment: .topLeading)
    }

    @ViewBuilder
    private func selectedEntry(_ entry: RegisterEntry) -> some View {
        section("Claim") {
            Text(entry.incident.claim)
                .font(WisentTypeScale.body())
                .foregroundStyle(WisentDesign.ink)
                .textSelection(.enabled)
        }
        section("Recorded") {
            row("id", entry.id)
            row("at", entry.incident.recordedAt)
            row("by", entry.incident.actor)
            if let run = entry.incident.runID {
                row("run", run)
            }
        }
        section("Failure") {
            row("service", entry.incident.envelope.service)
            row("failure point", entry.incident.envelope.failurePoint)
            row("error code", entry.incident.envelope.errorCode)
            Text(entry.incident.envelope.detail)
                .font(WisentTypeScale.body())
                .foregroundStyle(WisentDesign.secondary)
                .textSelection(.enabled)
        }
        if let resolution = entry.resolution {
            section("Resolved") {
                row("at", resolution.resolvedAt)
                row("by", resolution.actor)
                if let run = resolution.runID { row("run", run) }
                Text(resolution.note)
                    .font(WisentTypeScale.body())
                    .foregroundStyle(WisentDesign.ink)
                    .textSelection(.enabled)
            }
        } else {
            resolveSection(entry)
        }
        if let problem = store.problem {
            section("Refused") {
                Text(problem)
                    .font(WisentTypeScale.body())
                    .foregroundStyle(WisentDesign.danger)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func resolveSection(_ entry: RegisterEntry) -> some View {
        section("Close it") {
            TextField("What repaired it", text: $note)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("What repaired this incident")
            TextField("Verification run ID (optional)", text: $runID)
                .textFieldStyle(.roundedBorder)
            Button("Resolve") {
                resolve(entry)
            }
            .disabled(store.isWorking || note.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x2) {
            Text(title.uppercased())
                .font(WisentTypeScale.identifierSmall())
                .foregroundStyle(WisentDesign.secondary)
            content()
        }
    }

    @ViewBuilder
    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WisentDesign.Space.x2) {
            Text(key)
                .font(WisentTypeScale.identifierSmall())
                .foregroundStyle(WisentDesign.secondary)
            Text(value)
                .font(WisentTypeScale.identifierSmall())
                .foregroundStyle(WisentDesign.ink)
                .textSelection(.enabled)
        }
    }

    private func resolve(_ entry: RegisterEntry) {
        guard let root else { return }
        let submitted = note
        let verificationRun = runID
        Task {
            await store.resolve(workspaceRoot: root, id: entry.id, note: submitted, runID: verificationRun)
            if store.problem == nil {
                note = ""
            }
        }
    }
}
