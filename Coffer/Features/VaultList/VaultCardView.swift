import SwiftUI

struct VaultCardView: View {
    @Environment(AppState.self) private var appState
    let vault: Vault

    var body: some View {
        let operation = appState.activeOperations[vault.id]
        let isOperating = operation != nil

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                        .font(.title2)
                    Text(vault.name)
                        .font(.headline)
                    Spacer()
                    Text(vault.state.rawValue.uppercased())
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(badgeBackground)
                        .foregroundStyle(iconColor)
                        .clipShape(Capsule())
                }

                Text(vault.folderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack {
                    Label("\(vault.fileCount) files", systemImage: "doc")
                    Spacer()
                    Label(ByteCountFormatter.string(fromByteCount: vault.totalSize, countStyle: .file), systemImage: "internaldrive")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let operation {
                    ProgressView(value: operation.progress)
                        .progressViewStyle(.linear)
                    Text(operation.type == .encrypting ? "Encrypting..." : "Decrypting...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if vault.state == .locked {
                        if vault.useTouchID {
                            Button("Unlock with Touch ID") {
                                Task {
                                    await appState.unlockVaultWithBiometrics(vault.id)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isOperating)
                        }

                        if vault.useTouchID {
                            Button("Use Password") {
                                appState.promptForPassword(vaultID: vault.id, mode: .unlock)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isOperating)
                        } else {
                            Button("Unlock") {
                                appState.promptForPassword(vaultID: vault.id, mode: .unlock)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isOperating)
                        }
                    } else if vault.state == .unlocked {
                        Button("Lock") {
                            appState.promptForPassword(vaultID: vault.id, mode: .lock)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(isOperating)
                    }

                    Spacer()

                    if vault.state == .unlocked {
                        Button {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: vault.folderPath)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var iconName: String {
        switch vault.state {
        case .locked: "lock.fill"
        case .unlocked: "lock.open.fill"
        case .encrypting, .decrypting: "arrow.triangle.2.circlepath"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch vault.state {
        case .locked: .red
        case .unlocked: .green
        case .encrypting, .decrypting: .blue
        case .error: .orange
        }
    }

    private var badgeBackground: Color {
        iconColor.opacity(0.15)
    }
}
