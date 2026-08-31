import SwiftUI
import WisentDesignSystem

/// The evidence inventory: what a run produced, how large it is, and whether it
/// carries a digest — never what is inside it.
///
/// Sizes come from `ByteCountFormatter`, identifiers are monospaced, and the
/// digest column carries a pill only when a digest is missing; the count of the
/// dominant healthy state lives in the facet rail instead of on 1 500 rows.
struct ArtifactsView: View {
    @ObservedObject var model: ProbierzModel
    @ObservedObject var onboarding: ProbierzOnboarding

    var body: some View {
        let visible = model.visibleArtifacts

        return WisentScreen(
            title: "Artifacts",
            scope: model.scopeLabel,
            freshness: model.freshnessLabel,
            actions: [
                WisentAction(
                    "Refresh",
                    symbol: "arrow.clockwise",
                    kind: .secondary,
                    isEnabled: !model.isRefreshing && model.workspaceRoot != nil
                ) {
                    Task { await model.refresh() }
                }
            ],
            scrolls: false,
            constrainsWidth: false
        ) {
            HStack(spacing: 0) {
                WisentFacetRail(
                    groups: facetGroups,
                    footerTitle: "Selection",
                    footerDetail: "\(visible.count.formatted(.number)) of \(model.artifacts.count.formatted(.number)) · \(ProbierzFormat.bytes(visible.reduce(0) { $0 + $1.bytes }))"
                )
                centre(visible: visible)
                inspector
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .searchable(
            text: $model.query,
            placement: .toolbar,
            prompt: "Search run id, type, format or digest"
        )
        // The first-use journey finishes when a protected bundle's real
        // provenance inspector is on screen. The inspector is a pane now rather
        // than a sheet, so selection is the moment that happens.
        .onChange(of: model.selectedArtifactID) { _, _ in
            guard let artifact = model.selectedArtifact else { return }
            Task { await onboarding.observeEvidenceBundleInspected(artifact) }
        }
        .onAppear {
            guard let artifact = model.selectedArtifact else { return }
            Task { await onboarding.observeEvidenceBundleInspected(artifact) }
        }
    }

    // MARK: - Facets

    private var facetGroups: [WisentFacetGroup] {
        let summary = model.summary
        let missingDigest = summary.missingIntegrityCount
        let unavailable = model.artifacts.lazy.filter { !$0.isAvailableOnDisk }.count
        var groups: [WisentFacetGroup] = [
            WisentFacetGroup(
                "Type",
                facets: [
                    WisentFacet(
                        id: "kind.all",
                        label: "All types",
                        count: model.artifacts.count,
                        isSelected: model.artifactKindFilter == nil
                    ) {
                        model.artifactKindFilter = nil
                    }
                ] + ArtifactKind.allCases.compactMap { kind in
                    let count = model.artifactKindCounts[kind] ?? 0
                    guard count > 0 || model.artifactKindFilter == kind else { return nil }
                    return WisentFacet(
                        id: "kind.\(kind.rawValue)",
                        label: kind.title,
                        count: count,
                        tone: kind == .protectedBundle ? .brand : .neutral,
                        isSelected: model.artifactKindFilter == kind
                    ) {
                        model.artifactKindFilter = kind
                    }
                }
            ),
            WisentFacetGroup(
                "Integrity",
                facets: [
                    WisentFacet(
                        id: "integrity.all",
                        label: "Any digest",
                        count: model.artifacts.count,
                        isSelected: model.artifactIntegrityFilter == nil
                    ) {
                        model.artifactIntegrityFilter = nil
                    },
                    WisentFacet(
                        id: "integrity.recorded",
                        label: "SHA-256 recorded",
                        count: model.artifacts.count - missingDigest,
                        isSelected: model.artifactIntegrityFilter == true
                    ) {
                        model.artifactIntegrityFilter = true
                    },
                    WisentFacet(
                        id: "integrity.missing",
                        label: "No digest",
                        count: missingDigest,
                        tone: missingDigest > 0 ? .warning : .neutral,
                        isSelected: model.artifactIntegrityFilter == false
                    ) {
                        model.artifactIntegrityFilter = false
                    },
                ]
            ),
        ]
        if unavailable > 0 || model.artifactAvailabilityFilter != nil {
            groups.append(
                WisentFacetGroup(
                    "Presence",
                    facets: [
                        WisentFacet(
                            id: "presence.all",
                            label: "Any presence",
                            count: model.artifacts.count,
                            isSelected: model.artifactAvailabilityFilter == nil
                        ) {
                            model.artifactAvailabilityFilter = nil
                        },
                        WisentFacet(
                            id: "presence.ondisk",
                            label: "On disk",
                            count: model.artifacts.count - unavailable,
                            isSelected: model.artifactAvailabilityFilter == true
                        ) {
                            model.artifactAvailabilityFilter = true
                        },
                        WisentFacet(
                            id: "presence.absent",
                            label: "Descriptor only",
                            count: unavailable,
                            isSelected: model.artifactAvailabilityFilter == false
                        ) {
                            model.artifactAvailabilityFilter = false
                        },
                    ]
                )
            )
        }
        return groups
    }

    // MARK: - Centre

    @ViewBuilder
    private func centre(visible: [ArtifactMetadata]) -> some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
            if let errorMessage = model.errorMessage, model.snapshot != nil {
                WisentErrorBanner(
                    title: "Refresh failed",
                    detail: errorMessage,
                    action: WisentAction("Retry", symbol: "arrow.clockwise", kind: .secondary) {
                        Task { await model.refresh() }
                    }
                )
            }
            ProbierzSnapshotGate(
                model: model,
                readingTitle: "Reading artifact descriptors",
                readingDetail: "Each run manifest lists the file size and SHA-256 of what it produced; this read never opens those files."
            ) {
                if model.artifacts.isEmpty {
                    WisentEmptyPanel(
                        title: "No artifact descriptor here",
                        detail: "A run manifest records its artifacts once the run finishes. No manifest in \(model.scopeLabel.lowercased()) lists one.",
                        symbol: "archivebox"
                    )
                    Spacer(minLength: 0)
                } else if visible.isEmpty {
                    WisentEmptyPanel(
                        title: "No descriptor matches this selection",
                        detail: "The scope holds \(model.artifacts.count.formatted(.number)) descriptors. The facets and search term in force exclude every one of them.",
                        symbol: "line.3.horizontal.decrease.circle",
                        action: WisentAction("Clear filters", kind: .secondary) { model.clearArtifactFilters() }
                    )
                    Spacer(minLength: 0)
                } else {
                    table(visible: visible)
                }
            }
        }
        .padding(WisentDesign.Space.x5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func table(visible: [ArtifactMetadata]) -> some View {
        WisentTableFrame {
            Table(visible, selection: $model.selectedArtifactID) {
                TableColumn("RUN ID") { artifact in
                    Text(artifact.runID)
                        .font(WisentTypeScale.identifier())
                        .foregroundStyle(WisentDesign.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(artifact.runID)
                        .denseRow()
                }
                .width(min: 140, ideal: 170)
                TableColumn("TYPE") { artifact in
                    Label(artifact.kind.title, systemImage: artifact.kind.symbol)
                        .font(WisentTypeScale.body())
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                }
                .width(min: 84, ideal: 100)
                TableColumn("FMT") { artifact in
                    Text(artifact.fileExtension)
                        .font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(WisentDesign.muted)
                        .lineLimit(1)
                }
                .width(44)
                TableColumn("SIZE") { artifact in
                    Text(ProbierzFormat.bytes(artifact.bytes))
                        .font(WisentTypeScale.identifierSmall())
                        .monospacedDigit()
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                }
                .width(min: 62, ideal: 74)
                // A pill only for the minority: a recorded digest is the healthy
                // dominant state and its count is in the rail, so only a missing
                // one is marked here.
                TableColumn("DIGEST") { artifact in
                    if artifact.hasSHA256 {
                        Text("Recorded")
                            .font(WisentTypeScale.body())
                            .foregroundStyle(WisentDesign.secondary)
                    } else {
                        WisentStatusChip(text: "No digest", tone: .warning)
                    }
                }
                .width(min: 62, ideal: 74)
            }
            .tableStyle(.inset)
            .accessibilityLabel("Probierz artifact descriptors")
            // A click in this table already means "select this artifact" and a
            // drag means "extend that selection", so selectable cell text would
            // compete with both. The index opts out of the window's selection
            // rule; the inspector beside it states the same values selectably.
            .textSelection(.disabled)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let artifact = model.selectedArtifact {
            WisentInspector(
                eyebrow: artifact.kind == .protectedBundle ? "Protected bundle provenance" : "Artifact provenance",
                title: artifact.runID,
                badges: badges(for: artifact)
            ) {
                WisentField(label: "Type", value: artifact.kind.title)
                WisentField(label: "Format", value: artifact.fileExtension)
                WisentField(label: "Size", value: ProbierzFormat.bytes(artifact.bytes))
                WisentField(
                    label: "SHA-256",
                    value: ProbierzFormat.digest(artifact.sha256),
                    tone: artifact.hasSHA256 ? .neutral : .warning
                )
                if let fingerprint = artifact.keyFingerprintSHA256 {
                    WisentField(label: "Encryption key fingerprint", value: fingerprint)
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
            WisentInspector(eyebrow: "Artifact provenance", title: "No descriptor selected") {
                Text("Select a descriptor to read its type, format, size, SHA-256 and source run. Selecting one never opens the file it describes.")
                    .font(WisentTypeScale.body())
                    .foregroundStyle(WisentDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func badges(for artifact: ArtifactMetadata) -> [(String, WisentTone)] {
        var badges: [(String, WisentTone)] = [(artifact.kind.title, artifact.kind == .protectedBundle ? .brand : .neutral)]
        badges.append(artifact.hasSHA256 ? ("Digest recorded", .success) : ("No digest", .warning))
        return badges
    }

    @ViewBuilder
    private func presence(for artifact: ArtifactMetadata) -> some View {
        if artifact.isAvailableOnDisk {
            WisentField(label: "Presence", value: "Regular non-symlink file inside the result store")
        } else if artifact.wasPlaintextRemoved {
            WisentField(
                label: "Presence",
                value: "Descriptor only — probierz protect removed the plaintext and kept this record"
            )
        } else {
            WisentField(
                label: "Presence",
                value: "Descriptor only — the manifest lists this artifact but no readable file matches it",
                tone: .warning
            )
        }
    }
}
