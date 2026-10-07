import SwiftUI
import WisentDesignSystem

/// The selected run's reads and the roadmap write, and the answer of the
/// last command exactly as `probierz benchmark` printed it.
struct BenchmarkInspector: View {
    @ObservedObject var store: BenchmarkStore
    let root: URL?
    let app: String?
    @State private var baselineID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
                if let run = store.runs.first(where: { $0.id == store.selectedRunID }) {
                    selected(run)
                } else {
                    Text(
                        "Select a run to read it, its suite's standing, or compare it with an earlier run."
                    )
                    .font(WisentTypeScale.body()).foregroundStyle(WisentDesign.secondary)
                }
                if let problem = store.problem {
                    Text(problem).foregroundStyle(WisentDesign.danger).textSelection(.enabled)
                }
                if let answer = store.answer {
                    section(store.answerTitle ?? "Answer") {
                        Text(answer).font(.system(.body, design: .monospaced)).textSelection(
                            .enabled)
                    }
                }
            }
            .padding(WisentDesign.Space.x5)
        }
        .frame(width: 360, alignment: .topLeading)
        .onChange(of: store.selectedRunID) { baselineID = nil }
    }

    @ViewBuilder private func selected(_ run: BenchmarkRun) -> some View {
        section("Run") {
            row("id", run.id)
            row("suite", "\(run.suite.id) \(run.suite.version)")
            row("started", run.startedAt)
            row("ours", run.ours)
        }
        section("Read") {
            Button("Show every sample") {
                perform("Run \(run.id)", ["show", run.id])
            }
            Button("Standing of \(run.suite.id)") {
                perform("Standing of \(run.suite.id)", ["standing", "--suite", run.suite.id])
            }
            let earlier = store.runs.filter { $0.suite.id == run.suite.id && $0.id != run.id }
            if !earlier.isEmpty {
                Picker("Compare with", selection: $baselineID) {
                    Text("Choose a run").tag(String?.none)
                    ForEach(earlier) { other in Text(other.startedAt).tag(Optional(other.id)) }
                }
                Button("Compare") {
                    guard let baseline = baselineID else { return }
                    perform(
                        "\(baseline) → \(run.id)",
                        ["compare", "--baseline", baseline, "--candidate", run.id])
                }
                .disabled(baselineID == nil)
            }
        }
        section("Roadmap") {
            Text(
                "Writes one catalog roadmap item per case the newest run of \(run.suite.id) lost, and withdraws the items of cases ours now wins."
            )
            .font(WisentTypeScale.body()).foregroundStyle(WisentDesign.secondary)
            Button("Write roadmap from \(run.suite.id)") {
                guard let root, let app else { return }
                Task {
                    await store.act(
                        root: root, app: app, title: "Roadmap of \(app)",
                        ["roadmap", app, "--suite", run.suite.id])
                }
            }
        }
        .disabled(store.isWorking)
    }

    /// `show`, `standing` and `compare` take the product before their own
    /// arguments, as the CLI does.
    private func perform(_ title: String, _ arguments: [String]) {
        guard let root, let app, let verb = arguments.first else { return }
        Task { await store.read(root: root, title: title, [verb, app] + arguments.dropFirst()) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x2) {
            Text(title.uppercased()).font(WisentTypeScale.identifierSmall()).foregroundStyle(
                WisentDesign.secondary)
            content()
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WisentDesign.Space.x2) {
            Text(key).font(WisentTypeScale.identifierSmall()).foregroundStyle(
                WisentDesign.secondary)
            Text(value).font(WisentTypeScale.identifierSmall()).foregroundStyle(WisentDesign.ink)
                .textSelection(.enabled)
        }
    }
}
