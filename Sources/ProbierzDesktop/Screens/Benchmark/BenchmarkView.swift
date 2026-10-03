import Foundation
import SwiftUI
import WisentDesignSystem

/// Our product against its rivals on the same versioned cases: the suites and
/// contenders the manifest declares, every recorded run with ours beside the
/// best rival, and the `probierz benchmark` commands that read and act on them.
struct BenchmarkView: View {
    @ObservedObject var model: ProbierzModel
    @StateObject private var store = BenchmarkStore()
    @State private var acting = false
    private var root: URL? { model.snapshot?.repositoryRoot }
    private var app: String? { model.productScope }

    var body: some View {
        WisentScreen(
            title: "Benchmark", scope: model.scopeLabel, freshness: store.freshnessLabel,
            actions: [
                WisentAction("Run or author", symbol: "play", kind: .primary,
                             isEnabled: root != nil && app != nil && !store.isWorking) {
                    acting = true
                },
                WisentAction("Rivals", symbol: "person.2", kind: .secondary,
                             isEnabled: root != nil && app != nil && !store.isWorking) {
                    if let root, let app { Task { await store.rivals(root: root, app: app) } }
                },
                WisentAction("Refresh", symbol: "arrow.clockwise", kind: .secondary,
                             isEnabled: root != nil && app != nil) {
                    reload()
                },
            ],
            scrolls: false, constrainsWidth: false
        ) {
            HStack(spacing: 0) {
                WisentFacetRail(
                    groups: facetGroups, footerTitle: "Recorded runs",
                    footerDetail: "\(store.runs.count.formatted(.number)) for this product"
                )
                centre
                BenchmarkInspector(store: store, root: root, app: app)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: "\(root?.path ?? "")|\(app ?? "")") {
            store.clear()
            if let root, let app { await store.load(root: root, app: app) }
        }
        .sheet(isPresented: $acting) {
            if let root, let app { BenchmarkActionSheet(store: store, root: root, app: app) }
        }
    }

    private func reload() {
        guard let root, let app else { return }
        Task { await store.load(root: root, app: app) }
    }

    /// The benchmark is one product's: the rail picks the product every
    /// screen is scoped to.
    private var facetGroups: [WisentFacetGroup] {
        let products = model.snapshot?.productIDs ?? []
        return [WisentFacetGroup("Product", facets: products.map { product in
            WisentFacet(id: "product.\(product)", label: product, count: nil,
                        isSelected: app == product) { model.productScope = product }
        })]
    }

    private var centre: some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
            if root == nil {
                WisentEmptyPanel(title: "No workspace selected",
                    detail: "Choose the workspace whose benchmarks you want to read.", symbol: "questionmark.folder")
                Spacer(minLength: 0)
            } else if app == nil {
                WisentEmptyPanel(title: "Choose a product",
                    detail: "A benchmark measures one product against its rivals. Pick it on the left.", symbol: "person.2")
                Spacer(minLength: 0)
            } else if let problem = store.problem, store.loadedAt == nil {
                WisentEmptyPanel(title: "The benchmark could not be read", detail: problem, symbol: "exclamationmark.triangle")
                Spacer(minLength: 0)
            } else if store.loadedAt == nil {
                ProgressView("Reading the product's suites, contenders and runs")
            } else {
                declared
                runsTable
            }
        }
        .padding(WisentDesign.Space.x5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var declared: some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x2) {
            Text("SUITES").font(WisentTypeScale.identifierSmall()).foregroundStyle(WisentDesign.secondary)
            ForEach(store.suites) { suite in
                Text(suite.refused.map { "\(suite.id): \($0)" }
                     ?? "\(suite.id) \(suite.version ?? "") — \(suite.cases ?? 0) cases")
                    .font(WisentTypeScale.body())
                    .foregroundStyle(suite.refused == nil ? WisentDesign.ink : WisentDesign.danger)
                    .textSelection(.enabled)
            }
            Text("CONTENDERS").font(WisentTypeScale.identifierSmall()).foregroundStyle(WisentDesign.secondary)
            Text(store.contenders.map { $0.ours ? "\($0.id) (ours)" : $0.id }.joined(separator: ", "))
                .font(WisentTypeScale.body()).foregroundStyle(WisentDesign.ink)
        }
    }

    private var runsTable: some View {
        WisentTableFrame {
            Table(store.runs, selection: $store.selectedRunID) {
                TableColumn("STARTED") { run in
                    Text(run.startedAt).font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(WisentDesign.secondary).lineLimit(1)
                }
                .width(min: 150, ideal: 180)
                TableColumn("SUITE") { run in
                    Text("\(run.suite.id) \(run.suite.version)").font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(WisentDesign.ink).lineLimit(1)
                }
                .width(min: 110, ideal: 140)
                TableColumn("OURS") { run in
                    Text(percent(run.oursPassRate)).font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(WisentDesign.ink)
                }
                .width(min: 60, ideal: 70)
                TableColumn("BEST RIVAL") { run in
                    Text(run.bestRival.map { "\($0.id) \(percent($0.passRate))" } ?? "none ran")
                        .font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(isBehind(run) ? WisentDesign.warning : WisentDesign.secondary)
                }
                .width(min: 120, ideal: 160)
            }
            .tableStyle(.inset)
            .accessibilityLabel("Recorded benchmark runs")
        }
    }

    private func isBehind(_ run: BenchmarkRun) -> Bool {
        guard let ours = run.oursPassRate, let rival = run.bestRival else { return false }
        return rival.passRate > ours
    }

    private func percent(_ rate: Double?) -> String {
        rate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "did not run"
    }
}
