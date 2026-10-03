import Foundation
import SwiftUI

/// A product that does not exist yet: `probierz benchmark scout` reads a
/// Trends topic and writes an opportunity brief with the rivals and the
/// suite, and `probierz benchmark adopt` is the operator's decision on that
/// brief, which has Stado create the private repository and the preview
/// catalog record. Each is the same CLI call an operator types; its refusal
/// is the product's own sentence.
struct BenchmarkScoutSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case scout = "Scout a topic"
        case adopt = "Adopt a brief"
        var id: String { rawValue }
    }

    @ObservedObject var store: BenchmarkStore
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.scout
    @State private var topic = ""
    @State private var owner = ""
    @State private var observations = ""
    @State private var brief = ""
    @State private var authorised = false

    var body: some View {
        Form {
            Text("Scout a new product").font(.title2)
            Picker("Command", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch kind {
            case .scout: scoutFields
            case .adopt: adoptFields
            }
            if let problem = store.problem {
                Text(problem).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Close") { dismiss() }.disabled(store.isWorking)
                Button(store.isWorking ? "Running…" : "Start") { start() }
                    .disabled(store.isWorking || arguments == nil)
            }
        }
        .padding()
        .frame(minWidth: 520)
    }

    @ViewBuilder private var scoutFields: some View {
        TextField("Trends topic", text: $topic)
        TextField("GitHub owner of the new repository", text: $owner)
        TextField("Observations the model reads (empty: Probierz's default)", text: $observations)
        Text("Refused while Trends holds too little evidence for the topic or reads it falling. Every product, rival and gap the model names must cite an observation it was given.")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var adoptFields: some View {
        TextField("Brief file written by scout", text: $brief)
        Toggle("Create the brief's private repository and preview catalog record", isOn: $authorised)
        Text("Stado creates the repository, its checkout and the catalog record; the catalog then names the rivals and the benchmark, and Probierz drafts the first suite.")
            .foregroundStyle(.secondary)
    }

    /// The command line this sheet runs, or `nil` while a required field is
    /// empty, a number is not one, or adoption is not authorised.
    private var arguments: [String]? {
        switch kind {
        case .scout:
            let name = topic.trimmingCharacters(in: .whitespaces)
            let github = owner.trimmingCharacters(in: .whitespaces)
            let count = observations.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !github.isEmpty else { return nil }
            if count.isEmpty { return ["scout", name, "--owner", github] }
            guard let value = Int(count), value > 0 else { return nil }
            return ["scout", name, "--owner", github, "--observations", String(value)]
        case .adopt:
            let file = brief.trimmingCharacters(in: .whitespaces)
            guard !file.isEmpty, authorised else { return nil }
            return ["adopt", file, "--allow-create"]
        }
    }

    private func start() {
        guard let arguments else { return }
        Task {
            await store.read(root: root, title: kind.rawValue, arguments)
            guard store.problem == nil else { return }
            if kind == .scout, let written = writtenBrief() {
                brief = written
                kind = .adopt
            } else {
                dismiss()
            }
        }
    }

    /// The brief file the scout answer names, so adoption starts from it.
    private func writtenBrief() -> String? {
        guard let text = store.answer,
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return value["brief"] as? String
    }
}
