import SwiftUI

/// Full disclosure sheet for Mainline's anonymous telemetry.
/// Reachable from the opt-in banner and the Privacy settings pane.
struct TelemetryDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Privacy & Telemetry")
                    .font(.title2.bold())

                section(
                    title: "What we collect",
                    items: [
                        "Whether a GitHub poll succeeded, returned 304, or failed — and how long it took",
                        "Error categories — e.g. \"rate_limited\", \"server_error\" (never the raw message)",
                        "Write actions — approve, merge, request changes — action type and result only",
                        "Triage interactions — snooze, tab switches, scope changes, shortcut usage",
                        "Notification counts by event type and attention level",
                        "App launch count and session duration",
                    ]
                )

                section(
                    title: "What we never collect",
                    items: [
                        "PR titles, PR numbers, or PR descriptions",
                        "Repository names, organisation names, or branch names",
                        "Author usernames, reviewer usernames, or any GitHub login",
                        "GitHub tokens or credentials of any kind",
                        "Your IP address",
                        "Any data that could identify you or a specific PR personally",
                    ]
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("How we identify your installation")
                        .font(.headline)
                    Text("Two anonymous identifiers are included with every event:")
                        .foregroundStyle(.secondary)
                    Text("• A random ID generated when you first install Mainline. It changes if you reinstall.")
                        .foregroundStyle(.secondary)
                    Text("• A one-way hash of your Mac's hardware ID. It survives reinstalls so we can tell when the same machine is reporting — but it cannot be reversed to identify you or your machine.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Where it goes")
                        .font(.headline)
                    Text("Telemetry is sent to Dash0 — an observability platform built by the same team as Mainline. The endpoint is configurable via environment variables if you run your own OTel collector.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("How to turn it off")
                        .font(.headline)
                    Text("Open Settings → Privacy and toggle off \"Share anonymous usage data\". Takes effect immediately.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(width: 480, height: 520)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func section(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
