import SwiftUI

// MARK: - DeveloperSettingsView

/// Settings → Developer: every registered feature flag with the variant it currently
/// resolves to and why, plus a per-flag override picker and "Reset All Overrides".
///
/// Shown only in DEBUG builds or to an owner login (`FeatureFlagAccess.developerPaneVisible`),
/// which is how code ships to production dark and is seen by its owner first. Overrides
/// live in `MainlineSettings.featureFlagOverrides` and win over any experiment split.
struct DeveloperSettingsView: View {
    @ObservedObject var settings: MainlineSettings

    private let client = FeatureFlagClient.shared

    /// Picker tag meaning "no override — resolve from the registry".
    private static let noOverride = ""

    private func overrideBinding(for def: FlagDefinition) -> Binding<String> {
        Binding(
            get: { settings.featureFlagOverrides[def.key] ?? Self.noOverride },
            set: { newValue in
                var next = settings.featureFlagOverrides
                if newValue == Self.noOverride {
                    next.removeValue(forKey: def.key)
                } else {
                    next[def.key] = newValue
                }
                settings.featureFlagOverrides = next
            }
        )
    }

    private func summary(for def: FlagDefinition) -> String {
        let resolution = client.resolveWithoutRecording(def.key)
        let variant = resolution.variant ?? "none"
        return "Resolves to \"\(variant)\" (\(resolution.reason.rawValue))"
    }

    @ViewBuilder
    private func flagRow(_ def: FlagDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(def.key).font(.body.monospaced())
                Spacer()
                Picker("Override", selection: overrideBinding(for: def)) {
                    Text("Default (registry)").tag(Self.noOverride)
                    ForEach(def.orderedVariantKeys, id: \.self) { variant in
                        Text(variant).tag(variant)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            Text(def.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary(for: def))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    var body: some View {
        Section("Feature Flags") {
            Text("Override a flag on this Mac only. An override beats any experiment split and the registry default; it never changes what other users see.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if client.definitions.isEmpty {
                Text("No flags are registered yet. Add one to FeatureFlagRegistry.flags.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(client.definitions, id: \.key) { def in
                    flagRow(def)
                }
            }

            HStack {
                Spacer()
                Button("Reset All Overrides") {
                    settings.featureFlagOverrides = [:]
                }
                .disabled(settings.featureFlagOverrides.isEmpty)
            }
        }
    }
}
