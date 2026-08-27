import Foundation

/// Adds the Agent starter mode to installs that completed onboarding before it existed.
/// Runs once: if the user later deletes the mode, it stays deleted.
@MainActor
enum AgentModeSeeder {
    private static let seededKey = "AgentStarterModeSeeded_v1"

    static func ensureInstalled(enhancementService: AIEnhancementService) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seededKey) else { return }

        // Fresh installs have no modes yet; onboarding will seed everything including
        // the Agent mode, so just mark done.
        let manager = ModeManager.shared
        guard !manager.configurations.isEmpty else {
            defaults.set(true, forKey: seededKey)
            return
        }

        guard let template = StarterModeCatalog.templates.first(where: { $0.kind == .agent }) else {
            return
        }

        guard !manager.configurations.contains(where: { $0.id == template.id }) else {
            defaults.set(true, forKey: seededKey)
            return
        }

        let seedResult = StarterModePromptSeeder.ensurePrompts(
            for: [.agent],
            in: enhancementService.customPrompts
        )
        if seedResult.didChange {
            enhancementService.customPrompts = seedResult.prompts
        }

        let transcriptionModelName = manager.getDefaultConfiguration()?.selectedTranscriptionModelName
            ?? StarterModeFactory.defaultTranscriptionModelName

        let agentConfig = ModeConfig(
            id: template.id,
            name: template.name,
            icon: template.icon,
            isAIEnhancementEnabled: true,
            selectedPrompt: template.promptId?.uuidString,
            selectedTranscriptionModelName: transcriptionModelName,
            useSelectedTextContext: template.useSelectedTextContext,
            useScreenCapture: template.useScreenCapture,
            isTextFormattingEnabled: true,
            selectedAIProvider: AIProvider.claudeCode.rawValue,
            selectedAIModel: AIProvider.claudeCode.defaultModel,
            outputMode: template.outputMode,
            isAgentModeEnabled: true
        )

        manager.replaceConfigurations(manager.configurations + [agentConfig])
        defaults.set(true, forKey: seededKey)
    }
}
