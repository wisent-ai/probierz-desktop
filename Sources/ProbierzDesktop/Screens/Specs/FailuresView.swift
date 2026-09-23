import Foundation
import SwiftUI
import WisentDesignSystem

// MARK: - Envelope model

/// What the desktop apps reported, straight from the intake's files.
///
/// RunsView answers "what did Probierz drive and how did it end"; this screen
/// answers the other failure stream — the envelopes apps posted to
/// `probierz intake` on their own failures. Same anatomy as RunsView: facets
/// with counts (service and error code, the grouping the intake index prints),
/// a dense table newest first, and the selected envelope's fields beside it.
struct FailuresView: View {
    @ObservedObject var model: ProbierzModel

    var body: some View {
        let visible = model.visibleFailures

        return WisentScreen(
            title: "Failures",
            scope: model.scopeLabel,
            freshness: model.failuresFreshnessLabel,
            actions: [
                WisentAction(
                    "Refresh",
                    symbol: "arrow.clockwise",
                    kind: .secondary,
                    isEnabled: model.workspaceRoot != nil
                ) {
                    Task { await model.refreshFailures() }
                }
            ],
            scrolls: false,
            constrainsWidth: false
        ) {
            HStack(spacing: 0) {
                WisentFacetRail(
                    groups: facetGroups,
                    footerTitle: "Selection",
                    footerDetail: "\(visible.count.formatted(.number)) of \(model.failures.count.formatted(.number)) failures"
                )
                centre(visible: visible)
                inspector
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await model.refreshFailures() }
    }

    // MARK: - Facets

    private var facetGroups: [WisentFacetGroup] {
        [
            WisentFacetGroup(
                "Service",
                facets: [
                    WisentFacet(
                        id: "service.all",
                        label: "All services",
                        count: model.failures.count,
                        isSelected: model.failureServiceFilter == nil
                    ) {
                        model.failureServiceFilter = nil
                    }
                ] + model.failureServiceCounts.map { pair in
                    WisentFacet(
                        id: "service.\(pair.service)",
                        label: pair.service,
                        count: pair.count,
                        isSelected: model.failureServiceFilter == pair.service
                    ) {
                        model.failureServiceFilter = pair.service
                    }
                }
            ),
            WisentFacetGroup(
                "Error code",
                facets: [
                    WisentFacet(
                        id: "code.all",
                        label: "All codes",
                        count: model.failures.count,
                        isSelected: model.failureCodeFilter == nil
                    ) {
                        model.failureCodeFilter = nil
                    }
                ] + model.failureCodeCounts.map { pair in
                    WisentFacet(
                        id: "code.\(pair.code)",
                        label: pair.code,
                        count: pair.count,
                        isSelected: model.failureCodeFilter == pair.code
                    ) {
                        model.failureCodeFilter = pair.code
                    }
                }
            ),
        ]
    }

    // MARK: - Centre

    @ViewBuilder
    private func centre(visible: [FailureEntry]) -> some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x4) {
            if model.workspaceRoot == nil {
                WisentEmptyPanel(
                    title: "No workspace selected",
                    detail: model.errorMessage
                        ?? "Choose the workspace you want to review.",
                    symbol: "questionmark.folder"
                )
                Spacer(minLength: 0)
            } else if model.failures.isEmpty, model.failuresLoadedAt == nil {
                // The reported failures land in the five-column table below,
                // header included, so the read is drawn as that table.
                WisentSkeletonTable(rows: 6, columns: 5, header: true, label: "Loading reported failures")
                Spacer(minLength: 0)
            } else if model.failures.isEmpty {
                WisentEmptyPanel(
                    title: "Nothing has reported",
                    detail: "No desktop app has reported a failure to Probierz yet.",
                    symbol: "checkmark.shield"
                )
                Spacer(minLength: 0)
            } else if visible.isEmpty {
                WisentEmptyPanel(
                    title: "No failure matches this selection",
                    detail: "There are \(model.failures.count.formatted(.number)) failures. Current filters exclude all of them.",
                    symbol: "line.3.horizontal.decrease.circle",
                    action: WisentAction("Clear filters", kind: .secondary) { model.clearFailureFilters() }
                )
                Spacer(minLength: 0)
            } else {
                table(visible: visible)
            }
        }
        .padding(WisentDesign.Space.x5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Five columns on the same width budget as RunsView: 556 pt in the middle
    /// zone. Impact, context and the cause chain live in the inspector, one
    /// tap away.
    private func table(visible: [FailureEntry]) -> some View {
        WisentTableFrame {
            Table(visible, selection: $model.selectedFailureID) {
                TableColumn("SERVICE") { entry in
                    Text(entry.envelope.service)
                        .font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(WisentDesign.ink)
                        .lineLimit(1)
                        .denseRow()
                }
                .width(min: 80, ideal: 100)
                TableColumn("CODE") { entry in
                    Text(entry.envelope.errorCode)
                        .font(WisentTypeScale.identifierSmall())
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                }
                .width(min: 60, ideal: 80)
                TableColumn("SEVERITY") { entry in
                    severityCell(entry.envelope)
                }
                .width(min: 56, ideal: 64)
                TableColumn("FAILURE POINT") { entry in
                    Text(entry.envelope.failurePoint)
                        .font(WisentTypeScale.body())
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.envelope.failurePoint)
                }
                .width(min: 110, ideal: 140)
                TableColumn("DETAIL") { entry in
                    Text(entry.envelope.detail ?? "—")
                        .font(WisentTypeScale.body())
                        .foregroundStyle(WisentDesign.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .width(min: 120, ideal: 170)
            }
            .tableStyle(.inset)
            .accessibilityLabel("Failures reported to Probierz")
            // A click in this table already means "select this failure" and a
            // drag means "extend that selection", so selectable cell text would
            // compete with both. The index opts out of the window's selection
            // rule; the inspector beside it states the same values selectably.
            .textSelection(.disabled)
        }
    }

    /// The minority-severity pill: a warning is the catalogue's quietest row
    /// and stays text; error and critical earn the chip.
    @ViewBuilder
    private func severityCell(_ envelope: FailureNode) -> some View {
        if envelope.severityTone == .danger {
            WisentStatusChip(text: envelope.severity, tone: .danger)
        } else {
            Text(envelope.severity)
                .font(WisentTypeScale.body())
                .foregroundStyle(envelope.severityTone == .warning ? WisentDesign.warning : WisentDesign.secondary)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let entry = model.selectedFailure {
            let envelope = entry.envelope
            WisentInspector(
                eyebrow: "Reported failure",
                title: envelope.failurePoint,
                badges: badges(for: envelope)
            ) {
                WisentAlertPanel(
                    tone: envelope.severityTone == .warning ? .warning : .danger,
                    title: envelope.failurePoint,
                    detail: envelope.detail ?? "No additional detail was recorded."
                )
                WisentField(label: "Failure point", value: envelope.failurePoint)
                WisentField(label: "Service", value: envelope.service)
                WisentField(label: "Error code", value: envelope.errorCode)
                WisentField(label: "Severity", value: envelope.severity, tone: envelope.severityTone)
                WisentField(
                    label: "Try again",
                    value: envelope.retryable ? "Yes — the same action may succeed" : "No"
                )
                WisentField(
                    label: "Service unavailable",
                    value: envelope.outage ? "Yes" : "No",
                    tone: envelope.outage ? .warning : .neutral
                )
                if let impact = envelope.impact {
                    WisentField(label: "Impact", value: impact)
                }
                if let detail = envelope.detail {
                    WisentField(label: "Detail", value: detail)
                }
                if let context = contextLines(envelope) {
                    WisentField(label: "Context", value: context)
                }
                ForEach(Array(envelope.causeChain.enumerated()), id: \.offset) { index, cause in
                    WisentField(
                        label: "Cause \(index + 1) · \(cause.service)",
                        value: "\(cause.failurePoint) [\(cause.errorCode)] \(cause.detail ?? "—")",
                        tone: cause.severityTone
                    )
                }
            }
        } else {
            WisentInspector(eyebrow: "Reported failure", title: "No failure selected") {
                Text("Select a failure to see its severity, details, and causes.")
                    .font(WisentTypeScale.body())
                    .foregroundStyle(WisentDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func badges(for envelope: FailureNode) -> [(String, WisentTone)] {
        var badges: [(String, WisentTone)] = [(envelope.severity, envelope.severityTone)]
        if envelope.retryable { badges.append(("Retryable", .info)) }
        if envelope.outage { badges.append(("Outage", .danger)) }
        return badges
    }

    private func contextLines(_ envelope: FailureNode) -> String? {
        guard let context = envelope.context, !context.isEmpty else { return nil }
        return context.keys.sorted()
            .map { "\($0): \(context[$0]?.rendered ?? "null")" }
            .joined(separator: "\n")
    }
}
