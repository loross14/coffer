import SwiftUI

struct PasswordEntryView: View {
    let vaultName: String
    var isLocking: Bool = false
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isLocking ? "lock.fill" : "lock.open.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(isLocking ? "Lock \(vaultName)" : "Unlock \(vaultName)")
                .font(.title3)
                .fontWeight(.semibold)

            if isLocking {
                Text("Enter your password to lock all files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isLocking ? "Lock" : "Unlock") { submit() }
                    .buttonStyle(.borderedProminent)
                    .tint(isLocking ? .orange : .blue)
                    .disabled(password.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        onSubmit(password)
    }
}
