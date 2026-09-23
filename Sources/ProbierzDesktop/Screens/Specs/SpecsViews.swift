import SwiftUI
import WisentDesignSystem

/// The six surfaces Probierz drives, their packages, their spec inventory and
/// the coverage the workspace has recorded against each.
///
/// Two zones rather than three: six rows do not need a facet rail, and a rail
/// with six facets over six rows would be filter theatre. The baseline showed
/// six hardcoded file-presence cards on an Overview screen instead, which said
/// nothing about which surface can actually run.
struct SurfacesView: View {
    @ObservedObject var model: ProbierzModel

    var body: some View {
        WisentScreen(
            title: "Surfaces",
            scope: model.scopeLabel,
            freshness: model.freshnessLabel,
            actions: [
                WisentAction(
                    "Refresh",
                    symbol: "arrow.clockwise",
                    kind: .secondary,
                    isEnabled: model.workspaceRoot != nil,
                    isBusy: model.isRefreshing
                ) {
                    Task { await model.refresh() }
                }
            ],
            scrolls: false,
            constrainsWidth: false
        ) {
            HStack(spacing: 0) {
                centre
                inspector
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var surfaces: [SurfaceRecord] { model.snapshot?.surfaces ?? [] }

    @ViewBuilder
    private var centre: some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
            ProbierzSnapshotGate(
                model: model,
                readingLabel: "Loading surfaces",
                // Six columns and a header, like the surfaces table below.
                readingShape: .table(columns: 6)
            ) {
                let missing = surfaces.filter { !$0.isPackagePresent }
                if !missing.isEmpty {
                    WisentAlertPanel(
                        tone: .warning,
                        title: "\(missing.count.formatted(.number)) surfaces are unavailable",
                        detail: "These surfaces are unavailable: \(missing.map(\.name).joined(separator: ", ")). Their targets cannot run."
                    )
                }
                table
            }
        }
        .padding(WisentDesign.Space.x5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var table: some View {
        WisentTableFrame {
            Table(surfaces, selection: $model.selectedSurfaceID) {
                TableColumn("SURFACE") { surface in
                    Text(surface.name)
                        .font(WisentTypeScale.identifier())
                        .foregroundStyle(WisentDesign.ink)
                        .lineLimit(1)
                        .denseRow()
                }
                .width(min: 96, ideal: 112)
                TableColumn("TOOL") { surface in
                    Text(surface.tool)
                        .font(WisentTypeScale.body())
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(surface.tool)
                }
                .width(min: 120, ideal: 168)
                TableColumn("SPECS") { surface in
                    Text(surface.specPaths.count.formatted(.number))
                        .font(WisentTypeScale.identifierSmall())
                        .monospacedDigit()
                        .foregroundStyle(WisentDesign.secondary)
                }
                .width(40)
                TableColumn("RUNS") { surface in
                    Text(surface.runCount.formatted(.number))
                        .font(WisentTypeScale.identifierSmall())
                        .monospacedDigit()
                        .foregroundStyle(WisentDesign.secondary)
                }
                .width(40)
                // A pill only where the state is exceptional: a present package
                // is the norm, an absent one is the thing that stops a run.
                TableColumn("PACKAGE") { surface in
                    if surface.isPackagePresent {
                        Text("Present")
                            .font(WisentTypeScale.body())
                            .foregroundStyle(WisentDesign.secondary)
                    } else {
                        WisentStatusChip(text: "Absent", tone: .warning)
                    }
                }
                .width(min: 62, ideal: 74)
                TableColumn("LAST") { surface in
                    if let status = surface.lastStatus {
                        RunVerdictCell(status: status)
                    } else {
                        Text("No run")
                            .font(WisentTypeScale.body())
                            .foregroundStyle(WisentDesign.muted)
                    }
                }
                .width(min: 62, ideal: 76)
            }
            .tableStyle(.inset)
            .accessibilityLabel("Probierz surfaces")
            // A click in this table already means "select this surface" and a
            // drag means "extend that selection", so selectable cell text would
            // compete with both. The index opts out of the window's selection
            // rule; the inspector beside it states the same values selectably.
            .textSelection(.disabled)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let surface = surfaces.first(where: { $0.id == model.selectedSurfaceID }) {
            WisentInspector(
                eyebrow: "Surface details",
                title: surface.name,
                badges: [
                    surface.isPackagePresent
                        ? ("Package present", WisentTone.success)
                        : ("Package absent", WisentTone.warning)
                ]
            ) {
                WisentField(label: "Package", value: surface.isPackagePresent ? "Available" : "Unavailable")
                WisentField(label: "Tool", value: surface.tool)
                WisentField(label: "Script", value: surface.scriptLabel)
                WisentField(label: "Runs on", value: surface.targetsLabel)
                WisentField(
                    label: "Requirements",
                    value: "\(surface.conditionNames.count.formatted(.number))"
                )
                if !surface.observedTargets.isEmpty {
                    WisentField(
                        label: "Targets recorded here",
                        value: surface.observedTargets.joined(separator: "\n")
                    )
                }
                if let level = surface.lastEvidenceLevel {
                    WisentField(label: "Last result", value: level.title, tone: level.tone)
                }
                if surface.specPaths.isEmpty {
                    WisentField(
                        label: "Specs",
                        value: "None found",
                        tone: .warning
                    )
                } else {
                    WisentField(
                        label: "Specs",
                        value: "\(surface.specPaths.count.formatted(.number)) available"
                    )
                }
            }
        } else {
            WisentInspector(eyebrow: "Surface details", title: "No surface selected") {
                Text("Select a surface to see its tools, requirements, available specs, and latest run.")
                    .font(WisentTypeScale.body())
                    .foregroundStyle(WisentDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
