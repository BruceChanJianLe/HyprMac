// Text fields + helper hints for the `launchApp` bundle-ID and
// `runCommand` label/command parameters.

import SwiftUI

/// Bundle-ID text field used by the keybind editor for `launchApp`.
struct BundleIDPicker: View {
    @Binding var bundleID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Bundle ID", text: $bundleID)
                .textFieldStyle(.roundedBorder)
            Text("e.g. com.apple.Terminal, com.googlecode.iterm2")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Label + command-line fields used by the keybind editor for `runCommand`.
struct CommandPicker: View {
    @Binding var label: String
    @Binding var command: String
    let validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Label (shown in Hypr+K)", text: $label)
                .textFieldStyle(.roundedBorder)
            TextField("Command", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Text("Runs the program directly, not through a shell. "
                 + "Quote arguments that contain spaces. ~ expands to your home folder.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // stay quiet until they have typed something — an empty field is
            // not yet a mistake
            if let validationMessage, !command.isEmpty {
                Text(validationMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}
