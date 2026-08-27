import Foundation
import Testing
@testable import VoiceInk

struct AgentCommandConstructionTests {

    @Test func firstTurnHasNoResume() {
        let args = AgentCLIService.buildArguments(
            text: "create a file on my desktop",
            appendSystemPrompt: "be brief",
            model: "Sonnet (Medium)",
            permissionLevel: .standard,
            resumeSessionId: nil
        )
        #expect(args.first == "-p")
        #expect(args[1] == "create a file on my desktop")
        #expect(args.contains("--output-format"))
        #expect(args.contains("stream-json"))
        #expect(args.contains("--verbose"))
        #expect(!args.contains("--resume"))
        #expect(args.contains("--append-system-prompt"))
        #expect(args.contains("be brief"))
    }

    @Test func followUpTurnResumesSession() {
        let args = AgentCLIService.buildArguments(
            text: "add a fourth idea",
            appendSystemPrompt: nil,
            model: nil,
            permissionLevel: .standard,
            resumeSessionId: "abc-123"
        )
        guard let resumeIndex = args.firstIndex(of: "--resume") else {
            Issue.record("--resume missing")
            return
        }
        #expect(args[resumeIndex + 1] == "abc-123")
        #expect(!args.contains("--append-system-prompt"))
    }

    @Test func modelAndEffortAreSplit() {
        let args = AgentCLIService.buildArguments(
            text: "hi",
            appendSystemPrompt: nil,
            model: "Opus (Medium)",
            permissionLevel: .standard,
            resumeSessionId: nil
        )
        guard let modelIndex = args.firstIndex(of: "--model"),
              let effortIndex = args.firstIndex(of: "--effort") else {
            Issue.record("model/effort flags missing")
            return
        }
        #expect(args[modelIndex + 1] == "opus")
        #expect(args[effortIndex + 1] == "medium")
    }

    @Test func permissionLevelsMapToExpectedFlags() {
        #expect(AgentCLIService.PermissionLevel.safe.cliArguments.first == "--disallowedTools")
        #expect(AgentCLIService.PermissionLevel.safe.cliArguments.contains("Bash"))
        #expect(AgentCLIService.PermissionLevel.standard.cliArguments == ["--permission-mode", "acceptEdits"])
        #expect(AgentCLIService.PermissionLevel.full.cliArguments == ["--dangerously-skip-permissions"])
    }

    @Test func emptySystemPromptIsOmitted() {
        let args = AgentCLIService.buildArguments(
            text: "hi",
            appendSystemPrompt: "   ",
            model: nil,
            permissionLevel: .safe,
            resumeSessionId: nil
        )
        #expect(!args.contains("--append-system-prompt"))
    }
}

struct AgentResultParsingTests {

    @Test func successPayloadYieldsTextAndSession() throws {
        let payload = """
        {"type":"result","subtype":"success","is_error":false,"result":"Created the file.","session_id":"sess-42"}
        """
        let turn = try AgentCLIService.parseTurnResult(payload)
        #expect(turn.text == "Created the file.")
        #expect(turn.sessionId == "sess-42")
    }

    @Test func errorPayloadThrowsWithMessage() {
        let payload = """
        {"type":"result","subtype":"error_during_execution","is_error":true,"result":"Permission denied","session_id":"sess-42"}
        """
        #expect(throws: LocalCLIError.self) {
            _ = try AgentCLIService.parseTurnResult(payload)
        }
    }

    @Test func nonJSONOutputFallsBackToRawText() throws {
        let turn = try AgentCLIService.parseTurnResult("plain answer text")
        #expect(turn.text == "plain answer text")
        #expect(turn.sessionId == nil)
    }

    @Test func emptyOutputThrows() {
        #expect(throws: LocalCLIError.self) {
            _ = try AgentCLIService.parseTurnResult("   ")
        }
    }

    @Test func missingResultFieldThrows() {
        #expect(throws: LocalCLIError.self) {
            _ = try AgentCLIService.parseTurnResult("{\"type\":\"result\",\"session_id\":\"x\"}")
        }
    }
}

struct AgentStreamingTests {

    @Test func streamOutputYieldsFinalEnvelope() throws {
        let stream = """
        {"type":"system","subtype":"init","session_id":"sess-9"}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{}}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"Here is the answer.","session_id":"sess-9"}
        """
        let turn = try AgentCLIService.parseTurnResult(stream)
        #expect(turn.text == "Here is the answer.")
        #expect(turn.sessionId == "sess-9")
    }

    @Test func toolUseLinesMapToFriendlyActivityLabels() {
        func label(_ tool: String) -> String? {
            AgentCLIService.activityLabel(
                forStreamLine: "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"\(tool)\",\"input\":{}}]}}"
            )
        }
        #expect(label("WebSearch") == "Searching the web…")
        #expect(label("Bash") == "Running a command…")
        #expect(label("Edit") == "Editing files…")
        #expect(label("SomeMCPTool") == "Using SomeMCPTool…")
    }

    @Test func nonToolLinesProduceNoActivity() {
        #expect(AgentCLIService.activityLabel(forStreamLine: "{\"type\":\"system\",\"subtype\":\"init\"}") == nil)
        #expect(AgentCLIService.activityLabel(forStreamLine: "not json") == nil)
        #expect(AgentCLIService.activityLabel(
            forStreamLine: "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
        ) == nil)
    }

    @Test func streamBufferSplitsChunkedLines() {
        let buffer = AgentStreamBuffer()
        var lines = buffer.append(Data("{\"a\":1}\n{\"b\"".utf8))
        #expect(lines == ["{\"a\":1}"])
        lines = buffer.append(Data(":2}\n".utf8))
        #expect(lines == ["{\"b\":2}"])
        #expect(buffer.allText() == "{\"a\":1}\n{\"b\":2}\n")
    }
}

struct AgentModeConfigTests {

    @Test func agentFlagDefaultsFalseWhenAbsentFromStoredJSON() throws {
        let legacyJSON = """
        {"id":"6F1E9F51-0000-0000-0000-000000000001","name":"Old","icon":{"kind":"symbol","value":"mic.fill"},"triggerWords":[],"isAIEnhancementEnabled":true,"isRealtimeTranscriptionEnabled":true,"isTextFormattingEnabled":true,"useClipboardContext":false,"useSelectedTextContext":true,"useScreenCapture":false,"outputMode":"respond","autoSendKey":"none","isEnabled":true,"isDefault":false}
        """
        let config = try JSONDecoder().decode(ModeConfig.self, from: Data(legacyJSON.utf8))
        #expect(config.isAgentModeEnabled == false)
    }

    @Test func agentFlagRoundTripsThroughCodable() throws {
        var config = ModeConfig(name: "Agent test", isAIEnhancementEnabled: true)
        config.outputMode = .respond
        config.isAgentModeEnabled = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ModeConfig.self, from: data)
        #expect(decoded.isAgentModeEnabled == true)
    }

    @Test func agentStarterTemplateExists() {
        let template = StarterModeCatalog.templates.first { $0.kind == .agent }
        #expect(template != nil)
        #expect(template?.outputMode == .respond)
        #expect(template?.promptId == PromptTemplates.agentPromptId)
    }
}
