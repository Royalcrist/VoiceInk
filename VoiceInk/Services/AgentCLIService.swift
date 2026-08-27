import Foundation

/// Runs voice-agent turns through the official Claude Code CLI with true session
/// continuity: the first turn creates a CLI session (`--output-format json` returns a
/// `session_id`), follow-ups resume it with `--resume`, so the agent keeps context
/// across dictations without replaying transcripts. Unlike the enhancement path, the
/// agent is ALLOWED to act: permission level controls how far (read-only research,
/// file edits, or everything including commands and AppleScript).
@MainActor
final class AgentCLIService: ObservableObject {
    static let shared = AgentCLIService()

    enum PermissionLevel: String, CaseIterable, Identifiable {
        case safe
        case standard
        case full

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .safe: return String(localized: "Safe (research only)")
            case .standard: return String(localized: "Standard (can edit files)")
            case .full: return String(localized: "Full (commands & apps — use with care)")
            }
        }

        var cliArguments: [String] {
            switch self {
            case .safe:
                return ["--disallowedTools", "Write", "Edit", "NotebookEdit", "Bash"]
            case .standard:
                return ["--permission-mode", "acceptEdits"]
            case .full:
                return ["--dangerously-skip-permissions"]
            }
        }
    }

    static let permissionLevelKey = "AgentPermissionLevel"
    static let defaultTimeoutSeconds: Double = 300

    @Published var permissionLevel: PermissionLevel {
        didSet {
            UserDefaults.standard.set(permissionLevel.rawValue, forKey: Self.permissionLevelKey)
        }
    }

    @Published private(set) var currentSessionId: String?
    @Published private(set) var isRunning = false
    // One-line live status shown in the assistant panel while a turn runs
    // ("Searching the web…", "Editing files…"), derived from stream-json tool events.
    @Published private(set) var currentActivity: String?

    private var currentProcess: Process?

    private init() {
        let storedLevel = UserDefaults.standard.string(forKey: Self.permissionLevelKey) ?? ""
        permissionLevel = PermissionLevel(rawValue: storedLevel) ?? .standard
    }

    var hasActiveConversation: Bool {
        currentSessionId != nil
    }

    func startNewConversation() {
        currentSessionId = nil
    }

    func cancelCurrentTurn() {
        currentProcess?.terminate()
    }

    /// Sends one agent turn. Resumes the current conversation when one exists;
    /// otherwise starts a new session and remembers its id.
    func sendMessage(
        _ text: String,
        appendSystemPrompt: String?,
        model: String?
    ) async throws -> String {
        guard let binaryPath = CLIProviderService.findExecutable(named: "claude") else {
            throw LocalCLIError.commandNotFound(
                String(localized: "Claude Code was not found on this Mac. Install the 'claude' command line tool to use the agent.")
            )
        }

        let arguments = Self.buildArguments(
            text: text,
            appendSystemPrompt: appendSystemPrompt,
            model: model,
            permissionLevel: permissionLevel,
            resumeSessionId: currentSessionId
        )

        isRunning = true
        currentActivity = nil
        defer {
            isRunning = false
            currentActivity = nil
            currentProcess = nil
        }

        let output = try await runProcess(
            binaryPath: binaryPath,
            arguments: arguments,
            timeout: Self.defaultTimeoutSeconds
        )

        let turn = try Self.parseTurnResult(output)
        currentSessionId = turn.sessionId
        return turn.text
    }

    // MARK: - Live activity

    /// Maps a stream-json line to a user-facing activity label; nil for non-tool events.
    nonisolated static func activityLabel(forStreamLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return nil
        }

        for block in content where block["type"] as? String == "tool_use" {
            guard let toolName = block["name"] as? String else { continue }
            switch toolName {
            case "WebSearch":
                return String(localized: "Searching the web…")
            case "WebFetch":
                return String(localized: "Reading a web page…")
            case "Read", "Glob", "Grep":
                return String(localized: "Looking through files…")
            case "Write", "Edit", "NotebookEdit":
                return String(localized: "Editing files…")
            case "Bash":
                return String(localized: "Running a command…")
            case "TodoWrite", "Task":
                return String(localized: "Working on it…")
            default:
                return String(format: String(localized: "Using %@…"), toolName)
            }
        }
        return nil
    }

    // MARK: - Command construction

    nonisolated static func buildArguments(
        text: String,
        appendSystemPrompt: String?,
        model: String?,
        permissionLevel: PermissionLevel,
        resumeSessionId: String?
    ) -> [String] {
        // stream-json (with --verbose, which -p requires for intermediate events) lets
        // us surface live tool activity; the final envelope matches the json format.
        var arguments = ["-p", text, "--output-format", "stream-json", "--verbose"]

        let parsed = CLIProviderService.claudeCodeModelAndEffort(from: model)
        arguments += ["--model", parsed.model]
        if let effort = parsed.effort {
            arguments += ["--effort", effort]
        }

        if let appendSystemPrompt, !appendSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--append-system-prompt", appendSystemPrompt]
        }

        arguments += permissionLevel.cliArguments

        if let resumeSessionId, !resumeSessionId.isEmpty {
            arguments += ["--resume", resumeSessionId]
        }

        return arguments
    }

    // MARK: - Result parsing

    struct TurnResult: Equatable {
        let text: String
        let sessionId: String?
    }

    nonisolated static func parseTurnResult(_ output: String) throws -> TurnResult {
        // stream-json emits one JSON object per line; the final line is the result
        // envelope (same shape as --output-format json). Scan from the end.
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "result" else {
                continue
            }
            return try parseResultEnvelope(object)
        }

        // Not the expected envelope; a single JSON object or raw text may still be usable.
        if let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return try parseResultEnvelope(object)
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalCLIError.emptyOutput }
        return TurnResult(text: trimmed, sessionId: nil)
    }

    private nonisolated static func parseResultEnvelope(_ object: [String: Any]) throws -> TurnResult {
        let sessionId = object["session_id"] as? String

        if let isError = object["is_error"] as? Bool, isError {
            let message = (object["result"] as? String) ?? String(localized: "The agent reported an error.")
            throw LocalCLIError.nonZeroExit(status: 1, stderr: message)
        }

        guard let result = object["result"] as? String, !result.isEmpty else {
            throw LocalCLIError.emptyOutput
        }

        return TurnResult(text: result.trimmingCharacters(in: .whitespacesAndNewlines), sessionId: sessionId)
    }

    // MARK: - Process execution

    private func runProcess(
        binaryPath: String,
        arguments: [String],
        timeout: Double
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = ShellCommandEnvironment.commandEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        currentProcess = process

        // Incrementally read stdout so tool-use events update the live activity label
        // while the turn is still running.
        let streamBuffer = AgentStreamBuffer()
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let completedLines = streamBuffer.append(data)
            guard let self else { return }
            for line in completedLines {
                if let label = Self.activityLabel(forStreamLine: line) {
                    Task { @MainActor in
                        self.currentActivity = label
                    }
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: LocalCLIError.executionFailed(error.localizedDescription))
                    return
                }

                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in
                    semaphore.signal()
                }

                let waitResult = semaphore.wait(timeout: .now() + timeout)
                if waitResult == .timedOut {
                    if process.isRunning {
                        process.terminate()
                        _ = semaphore.wait(timeout: .now() + 2)
                    }
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: LocalCLIError.timeout(seconds: timeout))
                    return
                }

                // Drain whatever the readability handler has not consumed yet.
                let remainder = outputPipe.fileHandleForReading.readDataToEndOfFile()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                _ = streamBuffer.append(remainder)

                let stdout = streamBuffer.allText().trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // SIGTERM from the Stop button surfaces as a non-zero exit; report it
                // as a cancellation-style error rather than a scary failure.
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: LocalCLIError.executionFailed(String(localized: "The agent turn was stopped.")))
                    return
                }

                if process.terminationStatus != 0 && stdout.isEmpty {
                    continuation.resume(throwing: LocalCLIError.nonZeroExit(status: Int(process.terminationStatus), stderr: stderr))
                    return
                }

                guard !stdout.isEmpty else {
                    continuation.resume(throwing: LocalCLIError.emptyOutput)
                    return
                }

                continuation.resume(returning: stdout)
            }
        }
    }
}

/// Thread-safe accumulator that splits an incremental byte stream into complete lines
/// while retaining everything for final parsing.
final class AgentStreamBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var allData = Data()
    private var pendingLine = Data()

    /// Appends a chunk and returns any newline-terminated lines it completed.
    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        allData.append(data)
        pendingLine.append(data)

        var lines: [String] = []
        while let newlineIndex = pendingLine.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pendingLine[pendingLine.startIndex..<newlineIndex]
            if let line = String(data: lineData, encoding: .utf8),
               !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(line)
            }
            pendingLine = Data(pendingLine[pendingLine.index(after: newlineIndex)...])
        }
        return lines
    }

    func allText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: allData, encoding: .utf8) ?? ""
    }
}
