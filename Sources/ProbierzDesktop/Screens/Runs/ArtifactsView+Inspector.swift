import SwiftUI
import WisentDesignSystem

extension ArtifactsView {
    @ViewBuilder
    var inspector: some View {
        if let artifact = model.selectedArtifact {
            WisentInspector(
                eyebrow: artifact.kind == .protectedBundle ? "Protected bundle details" : "Artifact details",
                title: artifact.runID,
                badges: badges(for: artifact)
            ) {
                WisentField(label: "Type", value: artifact.kind.title)
                WisentField(label: "Format", value: artifact.fileExtension)
                WisentField(label: "Size", value: ProbierzFormat.bytes(artifact.bytes))
                WisentField(
                    label: "Integrity code",
                    value: ProbierzFormat.digest(artifact.sha256),
                    tone: artifact.hasSHA256 ? .neutral : .warning
                )
                if let fingerprint = artifact.keyFingerprintSHA256 {
                    WisentField(label: "Key ID", value: fingerprint)
                }
                WisentField(label: "Modified", value: ProbierzFormat.timestamp(artifact.modifiedAt))
                WisentField(label: "Source run", value: artifact.runID)
                WisentField(label: "Product", value: artifact.appID)
                WisentField(label: "Target", value: artifact.target)
                presence(for: artifact)
                if let run = model.runForSelectedArtifact {
                    WisentField(
                        label: "Run verdict",
                        value: "\(run.status.title) · \(run.evidenceLevel.title)",
                        tone: run.status.tone
                    )
                    WisentAction("Open Run", symbol: "list.bullet.rectangle", kind: .secondary) {
                        model.selectedRunID = run.id
                        model.destination = .runs
                    }
                    .asButton()
                }
            }
        } else {
            WisentInspector(eyebrow: "Artifact details", title: "No artifact selected") {
                Text("Select an artifact to see its type, format, size, integrity, and source run.")
                    .font(WisentTypeScale.body())
                    .foregroundStyle(WisentDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    func badges(for artifact: ArtifactMetadata) -> [(String, WisentTone)] {
        var badges: [(String, WisentTone)] = [(artifact.kind.title, artifact.kind == .protectedBundle ? .brand : .neutral)]
        badges.append(artifact.hasSHA256 ? ("Integrity recorded", .success) : ("No integrity code", .warning))
        return badges
    }
    @ViewBuilder
    func presence(for artifact: ArtifactMetadata) -> some View {
        if artifact.isAvailableOnDisk {
            WisentField(label: "Availability", value: "Available")
        } else if artifact.wasPlaintextRemoved {
            WisentField(
                label: "Availability",
                value: "Protected; original unavailable"
            )
        } else {
            WisentField(
                label: "Availability",
                value: "Unavailable",
                tone: .warning
            )
        }
    }
}
