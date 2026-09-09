import SwiftUI
import WisentDesignSystem

struct RegisterInspector: View {
    @ObservedObject var store: RegisterStore
    let root: URL?
    @State private var note = ""
    @State private var runID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
                TextField("Maximum entries", value: $store.limit, format: .number)
                    .textFieldStyle(.roundedBorder)
                Button("Apply limit") {
                    if let root { Task { await store.load(workspaceRoot: root) } }
                }
                if let entry = store.selected {
                    details(entry)
                } else {
                    Text("Select an entry to read the claim, failure, and resolution.")
                        .font(WisentTypeScale.body()).foregroundStyle(WisentDesign.secondary)
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
        .onChange(of: store.selectedID) { note = ""; runID = "" }
    }

    @ViewBuilder private func details(_ entry: RegisterEntry) -> some View {
        section("Claim") {
            Text(entry.incident.claim).font(WisentTypeScale.body())
                .foregroundStyle(WisentDesign.ink).textSelection(.enabled)
        }
        section("Recorded") {
            row("id", entry.id)
            row("at", entry.incident.recordedAt)
            row("by", entry.incident.actor)
            if let run = entry.incident.runID { row("run", run) }
        }
        section("Failure") {
            row("service", entry.incident.envelope.service)
            row("failure point", entry.incident.envelope.failurePoint)
            row("error code", entry.incident.envelope.errorCode)
            Text(entry.incident.envelope.detail).font(WisentTypeScale.body())
                .foregroundStyle(WisentDesign.secondary).textSelection(.enabled)
        }
        if let resolution = entry.resolution {
            section("Resolved") {
                row("at", resolution.resolvedAt)
                row("by", resolution.actor)
                if let run = resolution.runID { row("run", run) }
                Text(resolution.note).font(WisentTypeScale.body())
                    .foregroundStyle(WisentDesign.ink).textSelection(.enabled)
            }
        } else {
            section("Close it") {
                TextField("What repaired it", text: $note).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("What repaired this incident")
                TextField("Verification run ID (optional)", text: $runID).textFieldStyle(.roundedBorder)
                Button("Resolve") {
                    guard let root else { return }
                    let submitted = note
                    let verificationRun = runID
                    Task {
                        await store.resolve(workspaceRoot: root, id: entry.id, note: submitted, runID: verificationRun)
                        if store.problem == nil { note = "" }
                    }
                }
                .disabled(store.isWorking || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x2) {
            Text(title.uppercased()).font(WisentTypeScale.identifierSmall()).foregroundStyle(WisentDesign.secondary)
            content()
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WisentDesign.Space.x2) {
            Text(key).font(WisentTypeScale.identifierSmall()).foregroundStyle(WisentDesign.secondary)
            Text(value).font(WisentTypeScale.identifierSmall()).foregroundStyle(WisentDesign.ink).textSelection(.enabled)
        }
    }
}
