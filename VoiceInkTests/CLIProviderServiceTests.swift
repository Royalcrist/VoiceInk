import Foundation
import Testing
@testable import VoiceInk

struct CLIProviderMetadataTests {

    @Test func subscriptionCLIProvidersRequireNoAPIKey() {
        #expect(AIProvider.claudeCode.requiresAPIKey == false)
        #expect(AIProvider.antigravity.requiresAPIKey == false)
    }

    @Test func subscriptionCLIProvidersSupportEnhancement() {
        #expect(AIProvider.claudeCode.supportsEnhancement)
        #expect(AIProvider.antigravity.supportsEnhancement)
    }

    @Test func subscriptionCLIFlagOnlyCoversCLIProviders() {
        #expect(AIProvider.claudeCode.isSubscriptionCLIProvider)
        #expect(AIProvider.antigravity.isSubscriptionCLIProvider)
        #expect(!AIProvider.localCLI.isSubscriptionCLIProvider)
        #expect(!AIProvider.ollama.isSubscriptionCLIProvider)
        #expect(!AIProvider.anthropic.isSubscriptionCLIProvider)
    }

    @Test func cliExecutableNames() {
        #expect(AIProvider.claudeCode.cliExecutableName == "claude")
        #expect(AIProvider.antigravity.cliExecutableName == "agy")
        #expect(AIProvider.openAI.cliExecutableName == nil)
    }

    @Test func claudeCodeModelCatalog() {
        #expect(AIProvider.claudeCode.defaultModel == "haiku")
        #expect(AIProvider.claudeCode.availableModels.contains("haiku"))
    }

    @Test func antigravityModelCatalog() {
        #expect(AIProvider.antigravity.defaultModel == "Gemini 3.5 Flash (Low)")
        #expect(AIProvider.antigravity.availableModels.contains("Gemini 3.1 Pro (High)"))
        // Every catalog entry must survive sanitization or it could never be used.
        for model in AIProvider.antigravity.availableModels {
            #expect(CLIProviderService.sanitizedModelName(model) == model)
        }
    }
}

struct CLIProviderCommandTests {

    @Test func claudeCodeCommandUsesSelectedModel() {
        let command = CLIProviderService.commandTemplate(
            for: .claudeCode,
            binaryPath: "/usr/local/bin/claude",
            model: "sonnet"
        )
        #expect(command == "\"/usr/local/bin/claude\" -p --model \"sonnet\" \"$VOICEINK_FULL_PROMPT\"")
    }

    @Test func claudeCodeCommandFallsBackToHaiku() {
        let command = CLIProviderService.commandTemplate(
            for: .claudeCode,
            binaryPath: "/usr/local/bin/claude",
            model: nil
        )
        #expect(command.contains("--model \"haiku\""))
    }

    @Test func antigravityCommandUsesSelectedModel() {
        let command = CLIProviderService.commandTemplate(
            for: .antigravity,
            binaryPath: "/Users/me/.local/bin/agy",
            model: "Gemini 3.1 Pro (High)"
        )
        #expect(command == "\"/Users/me/.local/bin/agy\" -p --model \"Gemini 3.1 Pro (High)\" \"$VOICEINK_FULL_PROMPT\"")
    }

    @Test func antigravityCommandFallsBackToFastFlash() {
        let command = CLIProviderService.commandTemplate(
            for: .antigravity,
            binaryPath: "/Users/me/.local/bin/agy",
            model: nil
        )
        #expect(command.contains("--model \"Gemini 3.5 Flash (Low)\""))
    }

    @Test func unsafeModelNamesAreRejected() {
        #expect(CLIProviderService.sanitizedModelName("haiku") == "haiku")
        #expect(CLIProviderService.sanitizedModelName("claude-haiku-4-5") == "claude-haiku-4-5")
        #expect(CLIProviderService.sanitizedModelName("Gemini 3.5 Flash (Low)") == "Gemini 3.5 Flash (Low)")
        #expect(CLIProviderService.sanitizedModelName(nil) == nil)
        #expect(CLIProviderService.sanitizedModelName("") == nil)
        #expect(CLIProviderService.sanitizedModelName("haiku; rm -rf ~") == nil)
        #expect(CLIProviderService.sanitizedModelName("$(whoami)") == nil)
        #expect(CLIProviderService.sanitizedModelName("model\"; say pwned; \"") == nil)
        #expect(CLIProviderService.sanitizedModelName("model`id`") == nil)
    }

    @Test func unsafeModelFallsBackToDefaultInCommand() {
        let command = CLIProviderService.commandTemplate(
            for: .claudeCode,
            binaryPath: "/usr/local/bin/claude",
            model: "haiku\" && say pwned && \""
        )
        #expect(command.contains("--model \"haiku\""))
        #expect(!command.contains("pwned"))
    }
}

struct CLIProviderDetectionTests {

    @Test func rejectsNamesWithPathSeparators() {
        #expect(CLIProviderService.findExecutable(named: "../bin/zsh") == nil)
        #expect(CLIProviderService.findExecutable(named: "") == nil)
    }

    @Test func findsStandardSystemExecutable() {
        // zsh ships with every macOS install and /bin is always on the login-shell PATH.
        #expect(CLIProviderService.findExecutable(named: "zsh") != nil)
    }

    @Test func missingBinaryReturnsNil() {
        #expect(CLIProviderService.findExecutable(named: "voiceink-test-nonexistent-binary-xyz") == nil)
    }
}

struct CLIProviderExecutionTests {

    @Test func executeReturnsTrimmedStdout() async throws {
        let output = try await LocalCLIService.executeCommand(
            commandTemplate: "printf '%s' \"$VOICEINK_USER_PROMPT\"",
            systemPrompt: "system",
            userPrompt: "hello world",
            fullPrompt: "full",
            timeout: 10
        )
        #expect(output == "hello world")
    }

    @Test func nonZeroExitThrows() async {
        await #expect(throws: LocalCLIError.self) {
            try await LocalCLIService.executeCommand(
                commandTemplate: "exit 3",
                systemPrompt: "",
                userPrompt: "",
                fullPrompt: "",
                timeout: 10
            )
        }
    }

    @Test func missingCommandThrows() async {
        await #expect(throws: LocalCLIError.self) {
            try await LocalCLIService.executeCommand(
                commandTemplate: "voiceink-test-nonexistent-binary-xyz",
                systemPrompt: "",
                userPrompt: "",
                fullPrompt: "",
                timeout: 10
            )
        }
    }

    @Test func emptyOutputThrows() async {
        await #expect(throws: LocalCLIError.self) {
            try await LocalCLIService.executeCommand(
                commandTemplate: "true",
                systemPrompt: "",
                userPrompt: "",
                fullPrompt: "",
                timeout: 10
            )
        }
    }

    @Test func timeoutThrows() async {
        await #expect(throws: LocalCLIError.self) {
            try await LocalCLIService.executeCommand(
                commandTemplate: "sleep 30",
                systemPrompt: "",
                userPrompt: "",
                fullPrompt: "",
                timeout: 1
            )
        }
    }

    @Test func enhanceWithUndetectedProviderThrowsCommandNotFound() async {
        let service = CLIProviderService()
        // .openAI has no cliExecutableName, so enhance must throw immediately.
        await #expect(throws: LocalCLIError.self) {
            _ = try await service.enhance(provider: .openAI, model: nil, systemPrompt: "s", userPrompt: "u")
        }
    }
}
