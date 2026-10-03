import SwiftUI

/// The three benchmark commands that write: `run` records a run of one suite,
/// `author-suite` drafts and declares a new suite, and `author` drafts, places,
/// declares and verifies one contender's driver. Each is the same CLI call an
/// operator types; its refusal is the product's own sentence.
struct BenchmarkActionSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case run = "Run a suite"
        case authorSuite = "Author a suite"
        case authorContender = "Author a contender"
        var id: String { rawValue }
    }

    @ObservedObject var store: BenchmarkStore
    let root: URL
    let app: String
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.run
    @State private var suite = ""
    @State private var chosen: Set<String> = []
    @State private var repetitions = ""
    @State private var newSuite = ""
    @State private var cases = ""
    @State private var contender = ""
    @State private var ours = false

    var body: some View {
        Form {
            Text("Benchmark \(app)").font(.title2)
            Picker("Command", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch kind {
            case .run: runFields
            case .authorSuite: authorSuiteFields
            case .authorContender: authorContenderFields
            }
            if let problem = store.problem {
                Text(problem).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { dismiss() }.disabled(store.isWorking)
                Button(store.isWorking ? "Running…" : "Start") { start() }
                    .disabled(store.isWorking || arguments == nil)
            }
        }
        .padding()
        .frame(minWidth: 480)
        .onAppear { suite = store.suites.first?.id ?? "" }
    }

    @ViewBuilder private var runFields: some View {
        suitePicker
        Text("Contenders (none chosen runs every declared contender)")
        ForEach(store.contenders) { declared in
            Toggle(declared.ours ? "\(declared.id) (ours)" : declared.id, isOn: Binding(
                get: { chosen.contains(declared.id) },
                set: { if $0 { chosen.insert(declared.id) } else { chosen.remove(declared.id) } }
            ))
        }
        TextField("Repetitions (empty: the suite's own)", text: $repetitions)
    }

    @ViewBuilder private var authorSuiteFields: some View {
        TextField("New suite id", text: $newSuite)
        TextField("Cases (empty: Probierz's default)", text: $cases)
        Text("Drafted from the catalog record of \(app) and its rivals through the Stado model router. An existing suite file is never overwritten.")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var authorContenderFields: some View {
        TextField("Contender id (a rival the catalog names, or ours)", text: $contender)
        Toggle("Our own contender", isOn: $ours)
        suitePicker
        Text("The driver is placed under benchmark/contenders/ or benchmark/rivals/, declared, and verified with a recorded run of that contender alone.")
            .foregroundStyle(.secondary)
    }

    private var suitePicker: some View {
        Picker("Suite", selection: $suite) {
            ForEach(store.suites) { Text($0.id).tag($0.id) }
        }
    }

    /// The command line this sheet runs, or `nil` while a required field is
    /// empty or a number is not one.
    private var arguments: [String]? {
        func count(_ text: String, _ flag: String) -> [String]?? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .some(nil) }
            guard let value = Int(trimmed), value > 0 else { return nil }
            return .some([flag, String(value)])
        }
        switch kind {
        case .run:
            guard !suite.isEmpty, let extra = count(repetitions, "--repetitions") else { return nil }
            return ["run", app, "--suite", suite]
                + chosen.sorted().flatMap { ["--contender", $0] } + (extra ?? [])
        case .authorSuite:
            let id = newSuite.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, let extra = count(cases, "--cases") else { return nil }
            return ["author-suite", app, "--suite", id] + (extra ?? [])
        case .authorContender:
            let id = contender.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !suite.isEmpty else { return nil }
            return ["author", app, "--contender", id, "--suite", suite] + (ours ? ["--ours"] : [])
        }
    }

    private func start() {
        guard let arguments else { return }
        Task {
            await store.act(root: root, app: app, title: kind.rawValue, arguments)
            if store.problem == nil { dismiss() }
        }
    }
}
