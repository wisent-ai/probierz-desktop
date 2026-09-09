import SwiftUI
import UniformTypeIdentifiers

struct RecordIncidentSheet: View {
    @ObservedObject var store: RegisterStore
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @State private var claim = ""
    @State private var envelope = ""
    @State private var runID = ""
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Form {
            Text("Record an incident").font(.title2)
            TextField("What was claimed", text: $claim, axis: .vertical)
            Text("Failure envelope JSON: service, failure_point, error_code and detail are required. Additional context is kept unchanged.")
            TextEditor(text: $envelope)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("Incident failure envelope JSON")
            Button("Import envelope JSON") { importing = true }
            TextField("Run ID (optional)", text: $runID)
            if let problem = importError ?? store.problem {
                Text(problem).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { dismiss() }.disabled(store.isWorking)
                Button("Record") {
                    Task {
                        await store.record(workspaceRoot: root, claim: claim, envelope: envelope, runID: runID)
                        if store.problem == nil { dismiss() }
                    }
                }
                .disabled(store.isWorking)
            }
        }
        .padding()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                envelope = try String(contentsOf: url, encoding: .utf8)
                importError = nil
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}
