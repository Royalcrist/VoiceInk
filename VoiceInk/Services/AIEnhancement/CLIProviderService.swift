import Foundation

/// Backs the subscription CLI providers (Claude Code, Antigravity). These shell out to
/// locally installed CLI tools that are billed to the user's existing subscription, so no
/// API key is needed. A provider is "connected" when its binary is found on disk.
final class CLIProviderService {
    static let defaultTimeoutSeconds: Double = 90

    private let lookupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.cliprovider.lookup")
    private var cachedBinaryPaths: [String: String?] = [:]

    func binaryPath(for provider: AIProvider) -> String? {
        guard let executableName = provider.cliExecutableName else { return nil }
        return lookupQueue.sync {
            if let cached = cachedBinaryPaths[executableName] {
                return cached
            }
            let resolved = Self.findExecutable(named: executableName)
            cachedBinaryPaths[executableName] = resolved
            return resolved
        }
    }

    func isAvailable(_ provider: AIProvider) -> Bool {
        binaryPath(for: provider) != nil
    }

    func refreshDetection() {
        lookupQueue.sync {
            cachedBinaryPaths.removeAll()
        }
    }

    func enhance(provider: AIProvider, model: String?, systemPrompt: String, userPrompt: String) async throws -> String {
        guard let executableName = provider.cliExecutableName else {
            throw LocalCLIError.commandNotConfigured
        }
        guard let binaryPath = binaryPath(for: provider) else {
            throw LocalCLIError.commandNotFound(
                String(format: String(localized: "%@ was not found on this Mac. Install the '%@' command line tool to use this provider."), provider.rawValue, executableName)
            )
        }

        let commandTemplate = Self.commandTemplate(for: provider, binaryPath: binaryPath, model: model)
        let fullPrompt = LocalCLIService.makeFullPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt)
        return try await LocalCLIService.executeCommand(
            commandTemplate: commandTemplate,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            fullPrompt: fullPrompt,
            timeout: Self.defaultTimeoutSeconds
        )
    }

    static let validEffortLevels = ["low", "medium", "high", "xhigh", "max"]

    static func commandTemplate(for provider: AIProvider, binaryPath: String, model: String?) -> String {
        switch provider {
        case .claudeCode:
            // Picker entries look like "Sonnet (High)"; the CLI wants them as separate
            // --model and --effort flags.
            let parsed = claudeCodeModelAndEffort(from: model)
            var command = "\"\(binaryPath)\" -p --model \"\(parsed.model)\""
            if let effort = parsed.effort {
                command += " --effort \(effort)"
            }
            command += " \"$VOICEINK_FULL_PROMPT\""
            return command
        case .antigravity:
            // agy takes the full "Gemini 3.5 Flash (Low)" string as its --model value.
            let resolvedModel = sanitizedModelName(model) ?? provider.defaultModel
            return "\"\(binaryPath)\" -p --model \"\(resolvedModel)\" \"$VOICEINK_FULL_PROMPT\""
        default:
            return ""
        }
    }

    /// Splits a Claude Code picker entry such as "Sonnet (High)" into a CLI model alias
    /// ("sonnet") and reasoning effort ("high"). Accepts a bare legacy name ("haiku") and
    /// always returns safe, whitelisted values.
    static func claudeCodeModelAndEffort(from raw: String?) -> (model: String, effort: String?) {
        let fallbackModel = "haiku"
        let defaultEffort = "low"

        guard let raw, !raw.isEmpty else { return (fallbackModel, defaultEffort) }

        var namePart = raw
        var effortPart: String?
        if let open = raw.firstIndex(of: "("),
           let close = raw.lastIndex(of: ")"),
           open < close {
            namePart = String(raw[raw.startIndex..<open])
            effortPart = String(raw[raw.index(after: open)..<close])
        }

        let normalizedName = namePart.trimmingCharacters(in: .whitespaces).lowercased()
        let model = sanitizedModelName(normalizedName) ?? fallbackModel
        let effort = normalizedEffort(effortPart) ?? defaultEffort
        return (model, effort)
    }

    static func normalizedEffort(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return nil
        }
        return validEffortLevels.contains(raw) ? raw : nil
    }

    /// Model names are interpolated (double-quoted) into a shell command, so only pass
    /// through names built from a safe character set — no quotes, dollars, or backticks.
    static func sanitizedModelName(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ()._-")
        guard model.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return model
    }

    static func findExecutable(named name: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }

        let pathValue = ShellCommandEnvironment.preferredPATH(fallback: ProcessInfo.processInfo.environment["PATH"])
        var searchDirectories = pathValue.split(separator: ":").map(String.init)

        let home = NSHomeDirectory()
        let fallbackDirectories = [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "\(home)/.npm-global/bin",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        for directory in fallbackDirectories where !searchDirectories.contains(directory) {
            searchDirectories.append(directory)
        }

        let fileManager = FileManager.default
        for directory in searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
