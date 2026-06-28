import Foundation
import Observation

enum BrainClientError: Error, LocalizedError {
    case macOSOnlyLocalProcess
    case missingServerBinary(String)
    case processLaunchFailed(String)
    case serverDisconnected
    case malformedResponse
    case rpcError(String)
    case invalidToolArguments(String)

    var errorDescription: String? {
        switch self {
        case .macOSOnlyLocalProcess:
            "iOS cannot launch the local Zig stdio MCP server. Add a network bridge endpoint before connecting on iOS."
        case .missingServerBinary(let path):
            "MCP server binary does not exist at \(path). Run `zig build mcp` first or choose the built binary."
        case .processLaunchFailed(let message):
            "Could not launch MCP server: \(message)"
        case .serverDisconnected:
            "The MCP server disconnected before returning a response."
        case .malformedResponse:
            "The MCP server returned a malformed response."
        case .rpcError(let message):
            "MCP error: \(message)"
        case .invalidToolArguments(let message):
            "Invalid tool arguments: \(message)"
        }
    }
}

struct ToolCallRecord: Identifiable, Equatable {
    let id = UUID()
    let toolName: String
    let title: String
    let body: String
    let createdAt = Date()
}

@MainActor
@Observable
final class BrainDashboardModel {
    private static let maxRecords = 200

    var serverPath = "/Users/zelda/Documents/AffectiveCore/zig-out/bin/affective-core-mcp"
    var status = "Disconnected"
    var isConnected = false
    var query = ""
    var memoryText = ""
    var memoryTags = ""
    var reminderSchedule = "in 10 minutes"
    var reminderText = ""
    var userTextInput = ""
    var selectedTool = "user_text"
    var rawArguments = "{\"text\": \"hello\"}"
    var records: [ToolCallRecord] = []
    var recordsListGeneration = UUID()
    var lastError: String?
    var newBrainName = "Garden"
    var seedCoreValues = "Grow patient knowledge.\nStrengthen local care."
    var seedOperatingTendencies = "Ask before interrupting.\nFail plainly when uncertain."
    var seedWants = NewBrainDefaults.wants
    var seedGoals = NewBrainDefaults.goals
    var seedPrinciples = "Do not pretend a failed action worked.\nAsk before acting in shared spaces."
    var seedDraftPath: String?
    var llmQuality = "auto"
    var seedDraftPreview = ""

    @ObservationIgnored private var seedPreviewTask: Task<Void, Never>?
    @ObservationIgnored private var totalAppendedRecords = 0

    private var client: MCPClient?
    private var isConnecting = false

    static func snapshotDefaultBrain() -> BrainDashboardModel {
        let model = BrainDashboardModel()
        model.status = "Default brain"
        model.isConnected = true
        model.seedDraftPath = "/Users/zelda/Documents/AffectiveCore/data/seeds/garden.md"
        model.records = [
            .init(
                toolName: "read_models_snapshot",
                title: "Default Brain",
                body: "self_needs_and_wants:\n- seed_default_seed_core_value_1: Facilitate human contact.\n- seed_default_seed_superego_principle_1: Do not pretend a failed action worked.\n\npsyche:\n- Id, Ego, and Superego are active.\n- Superego principles are available as seeded self-model material."
            ),
            .init(
                toolName: "user_text",
                title: "User Text Outcome",
                body: ToolResultFormatting.displayBody(toolName: "user_text", rawJSON: """
                {
                  "text": "hello",
                  "spoken_text": "Hi — I'm here.",
                  "user_summary": "User greeted the brain.",
                  "brain_summary": "Responded with a short greeting.",
                  "awaiting_host_sense": false,
                  "interrupted_by": null,
                  "activity_id": "act-001",
                  "activity_kind": "converse",
                  "activity_kind_label": "Conversation",
                  "activity_state": "completed",
                  "activity_goal": "Respond to hello",
                  "activity_awaiting": null
                }
                """)
            ),
            .init(
                toolName: "seed_draft",
                title: "Seed Draft Created",
                body: "/Users/zelda/Documents/AffectiveCore/data/seeds/garden.md"
            ),
        ]
        model.seedDraftPreview = model.seedDraftMarkdown
        return model
    }

    let quickTools = [
        "connect",
        "brain_mode",
        "read_models_snapshot",
        "set_runtime_option",
        "mailbox_list",
        "request_dream_time",
        "user_text",
    ]

    let allTools = [
        "connect",
        "host_attach",
        "host_capability_manifest",
        "send_experience_event",
        "user_text",
        "request_dream_time",
        "brain_mode",
        "read_models_snapshot",
        "set_runtime_option",
        "mailbox_list",
        "mailbox_mark_read",
        "capability_status",
        "export_brain",
        "import_brain",
    ]

    func connect() async {
        guard !isConnected, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        await runReportingErrors {
            let client = MCPClient(serverPath: serverPath)
            try await client.connect()
            self.client = client
            self.isConnected = true
            self.status = "Connected"
            appendRecord(.init(toolName: "initialize", title: "Connected", body: "AffectiveCore MCP server is ready."))
            try await self.callTool("connect", arguments: [:], title: "Connection")
            try await self.callTool("read_models_snapshot", arguments: [:], title: "Initial Read Models")
        }
    }

    func disconnect() async {
        await client?.disconnect()
        client = nil
        isConnected = false
        status = "Disconnected"
    }

    func refresh() async {
        await runReportingErrors {
            try await callTool("read_models_snapshot", arguments: [:], title: "Read Models")
            syncLlmQualityFromLatestSnapshot()
        }
    }

    func applyLlmQuality() async {
        await runReportingErrors {
            try await callTool(
                "set_runtime_option",
                arguments: ["llm_quality": .string(llmQuality)],
                title: "LLM Quality"
            )
        }
    }

    private func syncLlmQualityFromLatestSnapshot() {
        guard let latest = records.last(where: { $0.toolName == "read_models_snapshot" }) else { return }
        guard let data = latest.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let readModels = json["read_models"] as? [String: Any],
              let policy = readModels["llm_policy_model"] as? [String: Any],
              let quality = policy["user_quality"] as? String else { return }
        llmQuality = quality
    }

    func recallMemory() async {
        await runReportingErrors {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty else {
                throw BrainClientError.invalidToolArguments("Recall query is required.")
            }
            let tags = parsedTags()
            let suffix = tags.isEmpty ? "" : " Tags: \(tags.joined(separator: ", "))."
            let text = "Recall memories related to: \(trimmedQuery).\(suffix)"
            try await callTool("user_text", arguments: ["text": .string(text)], title: "Recall")
        }
    }

    func rememberMemory() async {
        await runReportingErrors {
            guard !memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrainClientError.invalidToolArguments("Memory text is required.")
            }
            var arguments: [String: JSONValue] = [
                "source": .string("host"),
                "kind": .string("Memory.MemoryWritten"),
                "payload": .string(memoryText),
                "salience": .number(0.72),
                "confidence": .number(0.85),
                "retention": .string("durable"),
                "visibility": .string("internal"),
            ]
            let tags = parsedTags()
            if !tags.isEmpty {
                arguments["causal_parent_ids"] = .array(tags.map { .string("tag:\($0)") })
            }
            try await callTool("send_experience_event", arguments: arguments, title: "Remember")
            memoryText = ""
        }
    }

    func setReminder() async {
        await runReportingErrors {
            guard !reminderSchedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrainClientError.invalidToolArguments("Reminder schedule is required.")
            }
            guard !reminderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrainClientError.invalidToolArguments("Reminder text is required.")
            }
            let text = "Schedule a reminder \(reminderSchedule): \(reminderText)"
            try await callTool("user_text", arguments: ["text": .string(text)], title: "Set Reminder")
            reminderText = ""
        }
    }

    func sendUserText() async {
        await runReportingErrors {
            let text = userTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw BrainClientError.invalidToolArguments("User text is required.")
            }
            let dispatchId = UUID().uuidString
            try await callTool(
                "user_text",
                arguments: [
                    "text": .string(text),
                    "request_id": .string(dispatchId),
                ],
                title: "User Text"
            )
            userTextInput = ""
        }
    }

    func applyDefaultArguments(for tool: String) {
        selectedTool = tool
        rawArguments = Self.defaultArguments(for: tool)
    }

    static func defaultArguments(for tool: String) -> String {
        switch tool {
        case "user_text":
            return """
            {"text": "hello"}
            """
        case "send_experience_event":
            return """
            {"kind": "User.TextReceived", "payload": "typed text logged for experience", "retention": "episode", "visibility": "host"}
            """
        case "request_dream_time":
            return """
            {"text": "reflect on today"}
            """
        case "host_attach":
            return """
            {"host_id": "mac-studio", "platform": "macos", "app_version": "0.1.0", "permissions": ["camera", "microphone"]}
            """
        case "host_capability_manifest":
            return """
            {"host_id": "mac-studio", "capability_ids": ["camera_capture", "identity_recognition"]}
            """
        case "mailbox_mark_read":
            return """
            {"mailbox_id": "mailbox-001"}
            """
        case "capability_status":
            return """
            {"capability_id": "camera_capture", "availability": "available", "quality": 0.9}
            """
        case "set_runtime_option":
            return """
            {"llm_quality": "auto"}
            """
        case "export_brain":
            return """
            {"brain_file_path": "data/export/default.brain"}
            """
        case "import_brain":
            return """
            {"brain_file_path": "data/export/default.brain", "brain_root": "data/brains/imported", "host_id": "mac-studio"}
            """
        default:
            return "{}"
        }
    }

    func runSelectedTool() async {
        await runReportingErrors {
            let parsed = try JSONValue.objectFromString(rawArguments)
            try await callTool(selectedTool, arguments: parsed, title: selectedTool)
        }
    }

    var seedDraftMarkdown: String {
        let title = newBrainName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Brain" : newBrainName.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = [
            """
        # \(title) Seed

        ## Core Values

        \(markdownBullets(seedCoreValues))
        """,
        ]
        appendSeedSection(title: "Operating Tendencies", text: seedOperatingTendencies, to: &sections)
        appendSeedSection(title: "Wants", text: seedWants, to: &sections)
        appendSeedSection(title: "Goals", text: seedGoals, to: &sections)
        appendSeedSection(title: "Superego Principles", text: seedPrinciples, to: &sections)
        return sections.joined(separator: "\n\n")
    }

    func scheduleSeedPreviewUpdate() {
        seedPreviewTask?.cancel()
        seedPreviewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            seedDraftPreview = seedDraftMarkdown
        }
    }

    func createSeedDraft() async {
        await runReportingErrors {
            let seedName = newBrainName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seedName.isEmpty else {
                throw BrainClientError.invalidToolArguments("Brain name is required.")
            }
            guard !normalizedLines(seedCoreValues).isEmpty else {
                throw BrainClientError.invalidToolArguments("Add at least one core value.")
            }
            let root = URL(fileURLWithPath: "/Users/zelda/Documents/AffectiveCore")
            let seedsDirectory = root.appendingPathComponent("data/seeds", isDirectory: true)
            try FileManager.default.createDirectory(at: seedsDirectory, withIntermediateDirectories: true)
            let fileURL = seedsDirectory.appendingPathComponent("\(seedSlug(seedName)).md")
            try seedDraftMarkdown.write(to: fileURL, atomically: true, encoding: .utf8)
            seedDraftPath = fileURL.path
            appendRecord(.init(toolName: "seed_draft", title: "Seed Draft Created", body: fileURL.path))
            status = "Seed draft ready"
        }
    }

    private func parsedTags() -> [String] {
        memoryTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedLines(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func markdownBullets(_ text: String) -> String {
        let lines = normalizedLines(text)
        if lines.isEmpty {
            return ""
        }
        return lines.map { line in
            if line.hasPrefix("- ") {
                return line
            }
            return "- \(line)"
        }.joined(separator: "\n")
    }

    private func appendSeedSection(title: String, text: String, to sections: inout [String]) {
        let bullets = markdownBullets(text)
        guard !bullets.isEmpty else {
            return
        }
        sections.append(
            """
            ## \(title)

            \(bullets)
            """
        )
    }

    private func seedSlug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var result = ""
        var previousSeparator = false
        for scalar in text.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousSeparator = false
            } else if !previousSeparator {
                result.append("-")
                previousSeparator = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "new-brain" : trimmed
    }

    private func appendRecord(_ record: ToolCallRecord) {
        records.append(record)
        totalAppendedRecords += 1
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
        if totalAppendedRecords.isMultiple(of: Self.maxRecords) {
            recordsListGeneration = UUID()
        }
    }

    private func callTool(_ name: String, arguments: [String: JSONValue], title: String) async throws {
        guard let client else {
            throw BrainClientError.serverDisconnected
        }
        let output = try await client.callTool(name: name, arguments: arguments)
        let body = ToolResultFormatting.displayBody(toolName: name, rawJSON: output)
        appendRecord(.init(toolName: name, title: title, body: body))
    }

    private func runReportingErrors(_ operation: () async throws -> Void) async {
        do {
            lastError = nil
            try await operation()
        } catch {
            lastError = error.localizedDescription
            status = "Error"
        }
    }
}

actor MCPClient {
    private let serverPath: String
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var nextId = 1

    init(serverPath: String) {
        self.serverPath = serverPath
    }

    func connect() async throws {
        #if os(macOS)
        guard FileManager.default.fileExists(atPath: serverPath) else {
            throw BrainClientError.missingServerBinary(serverPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.currentDirectoryURL = URL(fileURLWithPath: "/Users/zelda/Documents/AffectiveCore")

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw BrainClientError.processLaunchFailed(error.localizedDescription)
        }

        self.process = process
        self.input = stdinPipe.fileHandleForWriting
        self.output = stdoutPipe.fileHandleForReading

        _ = try await request(method: "initialize", params: nil)
        #else
        throw BrainClientError.macOSOnlyLocalProcess
        #endif
    }

    func disconnect() {
        input?.closeFile()
        output?.closeFile()
        process?.terminate()
        input = nil
        output = nil
        process = nil
    }

    func callTool(name: String, arguments: [String: JSONValue]) async throws -> String {
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ])
        let response = try await request(method: "tools/call", params: params)
        if let error = response["error"]?.objectValue,
           let message = error["message"]?.stringValue {
            throw BrainClientError.rpcError(message)
        }
        guard let content = response["result"]?.objectValue?["content"]?.arrayValue,
              let first = content.first?.objectValue,
              let text = first["text"]?.stringValue else {
            throw BrainClientError.malformedResponse
        }
        return text
    }

    private func request(method: String, params: JSONValue?) async throws -> [String: JSONValue] {
        guard let input, let output else {
            throw BrainClientError.serverDisconnected
        }

        let id = nextId
        nextId += 1
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params {
            object["params"] = params
        }
        let body = try JSONValue.object(object).encodedData()
        let header = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        input.write(header + body)
        return try readResponse(from: output)
    }

    private func readResponse(from output: FileHandle) throws -> [String: JSONValue] {
        var header = Data()
        let headerTerminator = Data("\r\n\r\n".utf8)
        while !data(header, hasSuffix: headerTerminator) {
            let byte = output.readData(ofLength: 1)
            if byte.isEmpty {
                throw BrainClientError.serverDisconnected
            }
            header.append(byte)
        }
        guard let headerText = String(data: header, encoding: .utf8) else {
            throw BrainClientError.malformedResponse
        }
        let lengthLine = headerText
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
        guard let lengthLine,
              let length = Int(lengthLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) else {
            throw BrainClientError.malformedResponse
        }
        let body = output.readData(ofLength: length)
        guard body.count == length else {
            throw BrainClientError.serverDisconnected
        }
        return try JSONValue.decodedObject(from: body)
    }

    private func data(_ data: Data, hasSuffix suffix: Data) -> Bool {
        data.count >= suffix.count && data.suffix(suffix.count).elementsEqual(suffix)
    }
}

enum ToolResultFormatting {
    static func displayBody(toolName: String, rawJSON: String) -> String {
        if toolName == "user_text" {
            return formatUserTextOutcome(rawJSON)
        }
        return rawJSON
    }

    static func formatUserTextOutcome(_ rawJSON: String) -> String {
        guard let data = rawJSON.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return rawJSON
        }

        let outcome = extractOutcome(from: root)
        var lines: [String] = ["user_text outcome"]
        appendField("dispatch_id", from: outcome, to: &lines)
        appendField("text", from: outcome, to: &lines)
        appendField("spoken_text", from: outcome, to: &lines)
        appendField("user_summary", from: outcome, to: &lines)
        appendField("brain_summary", from: outcome, to: &lines)
        appendField("awaiting_host_sense", from: outcome, to: &lines)
        appendField("interrupted_by", from: outcome, to: &lines)
        appendField("activity_id", from: outcome, to: &lines)
        appendField("activity_kind", from: outcome, to: &lines)
        appendField("activity_kind_label", from: outcome, to: &lines)
        appendField("activity_state", from: outcome, to: &lines)
        appendField("activity_goal", from: outcome, to: &lines)
        appendField("activity_awaiting", from: outcome, to: &lines)

        lines.append("")
        lines.append("embedded envelope (host dispatch):")
        lines.append("{")
        lines.append("  \"kind\": \"user_text\",")
        lines.append("  \"outcome\": { ...fields above... }")
        lines.append("}")
        lines.append("")
        lines.append("raw json:")
        lines.append(prettyJSON(rawJSON) ?? rawJSON)
        return lines.joined(separator: "\n")
    }

    private static func extractOutcome(from root: JSONValue) -> [String: JSONValue] {
        if let envelope = root.objectValue,
           let value = envelope["value"]?.objectValue,
           let outcome = value["outcome"]?.objectValue {
            return outcome
        }
        if let envelope = root.objectValue,
           let outcome = envelope["outcome"]?.objectValue {
            return outcome
        }
        return root.objectValue ?? [:]
    }

    private static func appendField(_ key: String, from outcome: [String: JSONValue], to lines: inout [String]) {
        guard let value = outcome[key] else { return }
        lines.append("\(key): \(renderValue(value))")
    }

    private static func renderValue(_ value: JSONValue) -> String {
        switch value {
        case .null:
            "null"
        case .bool(let flag):
            flag ? "true" : "false"
        case .number(let number):
            number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(number)) : String(number)
        case .string(let text):
            text.isEmpty ? "(empty)" : text
        case .array(let items):
            "[\(items.count) items]"
        case .object(let object):
            "{\(object.count) keys}"
        }
    }

    private static func prettyJSON(_ rawJSON: String) -> String? {
        guard let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        return text
    }
}

enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decodedObject(from data: Data) throws -> [String: JSONValue] {
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw BrainClientError.malformedResponse
        }
        return object
    }

    static func objectFromString(_ text: String) throws -> [String: JSONValue] {
        let data = Data(text.utf8)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw BrainClientError.invalidToolArguments("Raw arguments must be a JSON object.")
        }
        return object
    }
}
