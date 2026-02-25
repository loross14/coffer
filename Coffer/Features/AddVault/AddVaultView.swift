import SwiftUI

struct AddVaultView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var folderPath = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var useTouchID = true
    @State private var autoLockMinutes = 5
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Add New Vault")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Name", text: $name)

                HStack {
                    TextField("Folder", text: $folderPath)
                        .disabled(true)
                    Button("Browse") {
                        pickFolder()
                    }
                }

                SecureField("Password", text: $password)
                SecureField("Confirm Password", text: $confirmPassword)

                if appState.isBiometricsAvailable {
                    Toggle("Enable Touch ID", isOn: $useTouchID)
                }

                Stepper("Auto-lock: \(autoLockMinutes) min", value: $autoLockMinutes, in: 0...60)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !password.isEmpty && !confirmPassword.isEmpty && password != confirmPassword {
                Text("Passwords do not match")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)

                Spacer()

                Button(isCreating ? "Creating..." : "Create Coffer") {
                    createVault()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isCreating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private var isValid: Bool {
        !name.isEmpty && !folderPath.isEmpty && !password.isEmpty && password == confirmPassword
    }

    private func createVault() {
        isCreating = true
        appState.addVault(
            name: name,
            folderPath: folderPath,
            password: password,
            useTouchID: useTouchID,
            autoLockMinutes: autoLockMinutes
        )
        if appState.errorMessage != nil {
            errorMessage = appState.errorMessage
            appState.errorMessage = nil
            isCreating = false
        } else {
            dismiss()
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Add a file or folder to the Coffer"
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
            if name.isEmpty {
                name = url.lastPathComponent
            }
        }
    }
}
