import SwiftUI

struct OnboardingModelScreen: View {
    let contentMaxWidth: CGFloat
    let localModel: FluidAudioModel?
    let setupKind: OnboardingTranscriptionSetupKind
    let providerOptions: [any CloudProvider]
    @Binding var selectedProviderKey: String
    let isLocalDownloaded: Bool
    let isLocalDownloading: Bool
    let localDownloadStatus: FluidAudioDownloadStatus?
    let isSetupReady: Bool
    let onSelectSetupKind: (OnboardingTranscriptionSetupKind) -> Void
    let onDownload: (FluidAudioModel) -> Void
    let onVerificationChanged: () -> Void
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScreen(
            stage: .model,
            contentMaxWidth: contentMaxWidth
        ) {
            OnboardingTranscriptionSetupCard(
                localModel: localModel,
                setupKind: setupKind,
                providerOptions: providerOptions,
                selectedProviderKey: $selectedProviderKey,
                isLocalDownloaded: isLocalDownloaded,
                isLocalDownloading: isLocalDownloading,
                localDownloadStatus: localDownloadStatus,
                onSelectSetupKind: onSelectSetupKind,
                onDownloadLocalModel: onDownload,
                onVerificationChanged: onVerificationChanged
            )
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: isSetupReady && !(setupKind == .local && isLocalDownloading),
                onLeading: onBack,
                onPrimary: onContinue
            )
        }
        .onAppear {
            startRecommendedDownloadIfNeeded()
        }
        .onChange(of: setupKind) { _, _ in
            startRecommendedDownloadIfNeeded()
        }
    }

    // Zero-manual-downloads: the recommended local model starts downloading as soon as
    // this step appears, instead of waiting for a button press.
    private func startRecommendedDownloadIfNeeded() {
        guard setupKind == .local,
              let localModel,
              !isLocalDownloaded,
              !isLocalDownloading else { return }
        onDownload(localModel)
    }
}
