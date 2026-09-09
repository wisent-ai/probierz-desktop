import Foundation
import SwiftUI
import WisentDesignSystem

struct RegisterView: View {
    @ObservedObject var model: ProbierzModel
    @StateObject private var store = RegisterStore()
    @State private var recording = false
    private var root: URL? { model.snapshot?.repositoryRoot }

    var body: some View {
        WisentScreen(
            title: "Register", scope: model.scopeLabel, freshness: store.freshnessLabel,
            actions: [
                WisentAction("Record incident", symbol: "plus", kind: .primary, isEnabled: root != nil) {
                    recording = true
                },
                WisentAction("Refresh", symbol: "arrow.clockwise", kind: .secondary, isEnabled: root != nil) {
                    reload()
                },
            ],
            scrolls: false, constrainsWidth: false
        ) {
            HStack(spacing: 0) {
                WisentFacetRail(
                    groups: facetGroups, footerTitle: "Loaded entries",
                    footerDetail: "\(store.entries.count.formatted(.number)) recorded"
                )
                centre
                RegisterInspector(store: store, root: root)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: root) {
            store.clear()
            if let root { await store.load(workspaceRoot: root) }
        }
        .onChange(of: store.stateFilter) { reload() }
        .onChange(of: store.selectedID) {
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

    private var facetGroups: [WisentFacetGroup] {
        [WisentFacetGroup("State", facets: [
            WisentFacet(id: "state.all", label: "Everything recorded", count: store.entries.count,
                        isSelected: store.stateFilter == nil) { store.stateFilter = nil },
            WisentFacet(id: "state.open", label: "Open", count: store.openCount,
                        isSelected: store.stateFilter == "open") { store.stateFilter = "open" },
            WisentFacet(id: "state.resolved", label: "Resolved", count: store.resolvedCount,
                        isSelected: store.stateFilter == "resolved") { store.stateFilter = "resolved" },
        ])]
    }

    private var centre: some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
            if root == nil {
                WisentEmptyPanel(title: "No workspace selected",
                    detail: "Choose the workspace whose register you want to read.", symbol: "questionmark.folder")
                Spacer(minLength: 0)
            } else if let problem = store.problem, store.entries.isEmpty {
                WisentEmptyPanel(title: "The register could not be read", detail: problem, symbol: "exclamationmark.triangle")
                Spacer(minLength: 0)
            } else if store.loadedAt == nil {
                ProgressView("Reading the selected repository's register")
            } else if store.entries.isEmpty {
                WisentEmptyPanel(title: "No entries match this state",
                    detail: "Choose another state or record an incident.", symbol: "book.closed")
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
                    Text(entry.incident.recordedAt).font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(WisentDesign.secondary).lineLimit(1)
                }
                .width(min: 150, ideal: 180)
                TableColumn("STATE") { entry in
                    Text(entry.state).font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(entry.isOpen ? WisentDesign.warning : WisentDesign.secondary)
                }
                .width(min: 64, ideal: 76)
                TableColumn("ACTOR") { entry in
                    Text(entry.incident.actor).font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(WisentDesign.secondary).lineLimit(1)
                }
                .width(min: 80, ideal: 100)
                TableColumn("CLAIM") { entry in
                    Text(entry.incident.claim).font(WisentTypeScale.body())
                        .foregroundStyle(WisentDesign.ink).lineLimit(1)
                        .truncationMode(.middle).help(entry.incident.claim)
                }
                .width(min: 180, ideal: 260)
            }
            .tableStyle(.inset)
            .accessibilityLabel("Attempts that did not hold")
        }
    }
}
