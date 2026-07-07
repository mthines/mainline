import SwiftUI

/// A dismissable banner encouraging users to opt in to anonymous telemetry.
/// Shown at the top of the Privacy settings pane until the user either opts in
/// or dismisses it. Uses a consent version so the banner can be re-surfaced by
/// bumping `MainlineSettings.currentTelemetryConsentVersion`.
struct TelemetryOptInBanner: View {
    @ObservedObject private var settings: MainlineSettings = .shared
    @State private var showingTelemetryDetails: Bool = false

    /// Whether the banner should be visible.
    var isVisible: Bool {
        !settings.telemetryEnabled && !settings.telemetryBannerDismissed
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis.ascending")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Help shape Mainline")
                        .font(.subheadline.weight(.medium))
                    Text("Anonymous usage data — poll results, error types, feature usage. No PR titles, repo names, or tokens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Learn more") {
                        showingTelemetryDetails = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                Spacer()

                Button("Enable") {
                    settings.telemetryEnabled = true
                    settings.telemetryBannerDismissedVersion = MainlineSettings.currentTelemetryConsentVersion
                    // configure() is called from telemetryEnabled.didSet
                    TelemetryService.shared.recordAppLaunch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Not now") {
                    settings.telemetryBannerDismissedVersion = MainlineSettings.currentTelemetryConsentVersion
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.blue.opacity(0.2), lineWidth: 0.5)
                    )
            )
            .sheet(isPresented: $showingTelemetryDetails) {
                TelemetryDetailsSheet()
            }
        }
    }
}
