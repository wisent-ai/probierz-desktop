import Foundation
import SwiftUI

/// The same owned-scope evaluator as the CLI, including its persisted failure evidence.
struct SecurityView: View {
    @ObservedObject var model: ProbierzModel
    @State private var appID = ""
    @State private var route = ""
    @State private var output = ""
    @State private var routerURL = ""
    @State private var agentID = ""
    @State private var bearer = ""
    @State private var signingSecret = ""
    @State private var running = false
    @State private var report = ""
    @State private var diagnostics = ""
    @State private var assessment: SecurityReport?
    @State private var failuresOnly = false
    @State private var deterministic = false
    @State private var progress: SecurityJournal?

    var body: some View {
        Form {
            Text("Owned-system security assessment").font(.title2)
            Text("Only the application's security declaration authorizes targets. The model orders declared GET checks and explains results; it cannot execute commands, add targets or follow redirects.")
                .foregroundStyle(.secondary)
            TextField("Registered application ID", text: $appID)
                .accessibilityIdentifier("security.app")
            Toggle("Deterministic checks only — no model calls", isOn: $deterministic)
                .accessibilityIdentifier("security.deterministic")
                .disabled(running)
            if !deterministic {
                TextField("Brama model route", text: $route)
                    .accessibilityIdentifier("security.model")
            }
            TextField("New JSON report path", text: $output)
                .accessibilityIdentifier("security.output")
            if !deterministic {
                TextField("Brama URL (empty: configured environment)", text: $routerURL)
                TextField("Agent ID (empty: configured environment)", text: $agentID)
                SecureField("Router bearer (empty: configured environment)", text: $bearer)
                SecureField("Agent signing secret (empty: configured environment)", text: $signingSecret)
            }
            Text("The declaration is the security block in apps/<application>/probierz.yaml. Its owner must match the registered owner; every resolved address must be explicitly approved. Existing reports are never overwritten.")
                .foregroundStyle(.secondary)
            Button(running ? "Assessing…" : "Assess owned system") { assess() }
                .accessibilityIdentifier("security.run")
                .disabled(running || appID.isEmpty || (!deterministic && route.isEmpty) || output.isEmpty || model.snapshot?.repositoryRoot == nil)
            Button("Open retained report…") { openReport() }.disabled(running)
            Button("Open operation journal…") { openJournal() }
                .accessibilityIdentifier("security.openJournal")
            if let progress {
                Section("Retained execution progress — not a final verdict") {
                    if progress.hasPartialRecord {
                        Text("The final record is incomplete and was not interpreted.")
                    }
                    ForEach(Array(progress.events.enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading) {
                            Text("\(event.operation): \(event.state.rawValue)")
                            if let check = event.check { Text("Check: \(check)") }
                            if let status = event.detail?.status { Text("HTTP \(status)") }
                            if let error = event.detail?.error { Text(error).foregroundStyle(.red) }
                        }
                        .textSelection(.enabled)
                    }
                }
            }
            if let assessment {
                Text(assessment.complete ? (assessment.pass ? "Declared checks passed" : "Security findings")
                    : "Assessment incomplete")
                    .font(.headline)
                    .accessibilityIdentifier("security.verdict")
                Text(assessment.mode == .deterministic ? "Deterministic checks — no model assessment"
                    : "Model-assisted assessment")
                    .accessibilityIdentifier("security.mode")
                if let failure = assessment.error {
                    Text(failure).foregroundStyle(.red).textSelection(.enabled)
                    if let operation = assessment.failedOperation {
                        Text("Failed operation: \(operation)").textSelection(.enabled)
                    }
                    if let check = assessment.failedCheck { Text("Failed check: \(check)") }
                }
                if let journal = assessment.journal {
                    Text("Operation journal: \(journal)").textSelection(.enabled)
                }
                Toggle("Show failing checks only", isOn: $failuresOnly)
                    .accessibilityIdentifier("security.failuresOnly")
                ForEach(assessment.observations.filter { !failuresOnly || !$0.pass }) { observation in
                    VStack(alignment: .leading) {
                        Text("\(observation.id): \(observation.pass ? "Passed" : "Finding")")
                            .font(.headline)
                        Text("\(observation.method) \(observation.path) — HTTP \(observation.status)")
                        if !observation.missingHeaders.isEmpty {
                            Text("Missing headers: \(observation.missingHeaders.joined(separator: ", "))")
                        }
                        ForEach(observation.failedAssertions, id: \.header) { assertion in
                            Text("\(assertion.header): \(assertion.cause)")
                        }
                        ForEach(Array(observation.failedCookies.enumerated()), id: \.offset) { _, finding in
                            Text("Cookie \(finding.cookie): \(finding.cause)")
                        }
                    }
                    .textSelection(.enabled)
                    .accessibilityIdentifier("security.check.\(observation.id)")
                }
            }
            if !diagnostics.isEmpty {
                Text(diagnostics).textSelection(.enabled)
                    .accessibilityIdentifier("security.diagnostics")
            }
            if !report.isEmpty {
                ScrollView {
                    Text(report).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("security.report")
                }
            }
        }
        .padding()
    }

    @MainActor private func assess() {
        guard let root = model.snapshot?.repositoryRoot else {
            diagnostics = "Choose a Probierz workspace before assessing a system."
            return
        }
        var arguments = ["evaluate", "security", "--app", appID, "--out", output]
        if deterministic {
            arguments.append("--deterministic")
        } else {
            arguments += ["--model", route]
            if !routerURL.isEmpty { arguments += ["--router-url", routerURL] }
            if !agentID.isEmpty { arguments += ["--agent-id", agentID] }
        }
        var input: Data?
        if !deterministic && (!bearer.isEmpty || !signingSecret.isEmpty) {
            guard !bearer.isEmpty, !signingSecret.isEmpty,
                !bearer.contains("\n"), !signingSecret.contains("\n") else {
                diagnostics = "Supply both bearer and signing secret as single lines, or leave both empty for the configured environment."
                return
            }
            arguments.append("--router-token-stdin")
            input = Data("\(bearer)\n\(signingSecret)\n".utf8)
        }
        running = true
        report = ""
        assessment = nil
        progress = nil
        diagnostics = deterministic ? "Waiting for the declared owned-target checks."
            : "Waiting for the owned-target checks and Brama's assessment."
        Task {
            defer { running = false; bearer = ""; signingSecret = "" }
            do {
                let result = try await ProbierzCLI.run(repositoryRoot: root, arguments: arguments, input: input)
                progress = nil
                report = String(decoding: result.stdout, as: UTF8.self)
                diagnostics = "CLI exit status: \(result.status)\n\(String(decoding: result.stderr, as: UTF8.self))"
                if !result.stdout.isEmpty {
                    do {
                        assessment = try SecurityReport.decode(result.stdout)
                    } catch {
                        diagnostics += "\nReport interpretation failed: \(error.localizedDescription)"
                    }
                }
            } catch {
                diagnostics = error.localizedDescription
            }
        }
    }

    @MainActor private func openJournal() {
        let panel = NSOpenPanel()
        panel.title = "Read a retained security operation journal"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            progress = try SecurityJournal.decode(Data(contentsOf: url))
            assessment = nil
            report = ""
            diagnostics = "Retained operation journal: \(url.path). Progress is not a final assessment."
        } catch {
            progress = nil
            diagnostics = "Could not read \(url.path): \(error.localizedDescription)"
        }
    }

    @MainActor private func openReport() {
        let panel = NSOpenPanel()
        panel.title = "Read a retained security assessment"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        progress = nil
        do {
            let data = try Data(contentsOf: url)
            let decoded = try SecurityReport.decode(data)
            let value = try JSONSerialization.jsonObject(with: data)
            report = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
            assessment = decoded
            diagnostics = "Retained report: \(url.path)"
        } catch {
            report = ""
            assessment = nil
            diagnostics = "Could not read \(url.path): \(error.localizedDescription)"
        }
    }
}
