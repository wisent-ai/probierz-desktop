import Foundation
import SwiftUI

/// A product that does not exist yet, and the loop that needs nobody:
/// `probierz benchmark scout` reads a Trends topic and writes an opportunity
/// brief, `adopt` has Stado create the brief's repository and preview
/// catalog record, `cycle` runs the whole loop once under the written policy,
/// and `schedule` has Stado run that cycle on a cron on one host. Each is the
/// same CLI call an operator types; its refusal is the product's own sentence.
struct BenchmarkScoutSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case scout = "Scout a topic"
        case adopt = "Adopt a brief"
        case cycle = "Run the loop once"
        case schedule = "Schedule the loop"
        var id: String { rawValue }
    }

    @ObservedObject var store: BenchmarkStore
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.scout
    @State private var topic = ""
    @State private var owner = ""
    @State private var observations = ""
    @State private var rounds = ""
    @State private var cases = ""
    @State private var brief = ""
    @State private var authorised = false
    @State private var policy = ""
    @State private var cron = ""
    @State private var host = ""
    @State private var harnessDir = ""
    @State private var secrets = ""
    @State private var settings = ""

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
            case .cycle: cycleFields
            case .schedule: scheduleFields
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
        TextField("Observations the model reads", text: $observations)
        TextField("Drafts allowed per question", text: $rounds)
        Text("Refused while Trends holds too little evidence for the topic or reads it falling. Every product, rival and gap the model names must cite an observation it was given.")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var adoptFields: some View {
        TextField("Brief file written by scout", text: $brief)
        Toggle("Create the brief's private repository and preview catalog record", isOn: $authorised)
        TextField("Cases the first suite holds", text: $cases)
        TextField("Suite drafts allowed", text: $rounds)
        Text("Stado creates the repository, its checkout and the catalog record; the catalog then names the rivals and the benchmark, and Probierz drafts the first suite.")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var cycleFields: some View {
        TextField("Policy file (empty: autonomy.yaml in the harness)", text: $policy)
        Text("Gives every catalog product a Trends topic, scouts every rising topic within the policy's weekly product limit, has the model judge and adopt briefs, runs every suite, writes the roadmap, pursues losses within the policy's budget, and turns open incidents into roadmap items. The report lands under test-results/.autonomy/.")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var scheduleFields: some View {
        TextField("Cron, five fields in UTC", text: $cron)
        TextField("Stado host", text: $host)
        TextField("Probierz harness directory on that host", text: $harnessDir)
        TextField("Secrets as NAME=ITEM#FIELD, separated by spaces", text: $secrets)
        TextField("Settings as NAME=VALUE, separated by spaces (router URL, agent id)", text: $settings)
        TextField("Policy file on that host (empty: the harness's autonomy.yaml)", text: $policy)
    }

    /// The command line this sheet runs, or `nil` while a required field is
    /// empty, a number is not one, or adoption is not authorised.
    private var arguments: [String]? {
        func positive(_ text: String) -> String? {
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
            return String(value)
        }
        switch kind {
        case .scout:
            let name = topic.trimmingCharacters(in: .whitespaces)
            let github = owner.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !github.isEmpty,
                  let read = positive(observations), let drafts = positive(rounds) else { return nil }
            return ["scout", name, "--owner", github, "--observations", read, "--rounds", drafts]
        case .adopt:
            let file = brief.trimmingCharacters(in: .whitespaces)
            guard !file.isEmpty, authorised, let suiteCases = positive(cases), let drafts = positive(rounds) else {
                return nil
            }
            return ["adopt", file, "--allow-create", "--cases", suiteCases, "--rounds", drafts]
        case .cycle:
            let file = policy.trimmingCharacters(in: .whitespaces)
            return file.isEmpty ? ["cycle"] : ["cycle", "--policy", file]
        case .schedule:
            let expression = cron.trimmingCharacters(in: .whitespaces)
            let target = host.trimmingCharacters(in: .whitespaces)
            let directory = harnessDir.trimmingCharacters(in: .whitespaces)
            guard !expression.isEmpty, !target.isEmpty, !directory.isEmpty else { return nil }
            var line = ["schedule", "--cron", expression, "--host", target, "--harness-dir", directory]
            for secret in secrets.split(separator: " ") where !secret.isEmpty {
                line += ["--secret-env", String(secret)]
            }
            for setting in settings.split(separator: " ") where !setting.isEmpty {
                line += ["--env", String(setting)]
            }
            let file = policy.trimmingCharacters(in: .whitespaces)
            if !file.isEmpty { line += ["--policy", file] }
            return line
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
