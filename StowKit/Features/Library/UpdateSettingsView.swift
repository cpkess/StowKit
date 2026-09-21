import SwiftUI

struct UpdateSettingsView: View {
    @Bindable var updater: Updater
    var body: some View {
        Section("Updates") {
            if updater.isAvailable {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyInstalls)
                    .disabled(!updater.automaticallyChecks)
                Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                Text("Updates come from StowKit’s GitHub releases, signed and notarized, and are verified before they install. Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This build of StowKit doesn’t update itself. Signed releases from GitHub do.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
