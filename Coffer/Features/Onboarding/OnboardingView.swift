import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 30) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Welcome to Coffer")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Lock folders with Touch ID and a password.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)

            // Features
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    icon: "faceid",
                    title: "Touch ID Protection",
                    description: "Unlock your folders with a fingerprint."
                )

                FeatureRow(
                    icon: "key.fill",
                    title: "Password Backup",
                    description: "Always have password access as a fallback."
                )

                FeatureRow(
                    icon: "lock.fill",
                    title: "Offline Security",
                    description: "All encryption happens locally on your device."
                )
            }
            .padding(.horizontal, 30)

            Spacer()

            // Get Started
            Button(action: { appState.completeOnboarding() }) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .frame(width: 500, height: 600)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
