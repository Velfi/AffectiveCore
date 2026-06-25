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
    var serverPath = "/Users/zelda/Documents/AffectiveCore/zig-out/bin/affective-core-mcp"
    var status = "Disconnected"
    var isConnected = false
    var query = ""
    var memoryText = ""
    var memoryTags = ""
    var reminderSchedule = "in 10 minutes"
    var reminderText = ""
    var selectedTool = "introspect"
    var rawArguments = "{}"
    var records: [ToolCallRecord] = []
    var lastError: String?
    var newBrainName = "Garden"
    var seedCoreValues = "Grow patient knowledge.\nStrengthen local care."
    var seedOperatingTendencies = "Ask before interrupting.\nFail plainly when uncertain."
    var seedWants = "Maintain a living map of the garden."
    var seedPrinciples = "Do not pretend a failed action worked.\nAsk before acting in shared spaces."
    var seedDraftPath: String?

    private var client: MCPClient?

    static func snapshotDefaultBrain() -> BrainDashboardModel {
        let model = BrainDashboardModel()
        model.status = "Default brain"
        model.isConnected = true
        model.seedDraftPath = "/Users/zelda/Documents/AffectiveCore/data/seeds/garden.md"
        model.records = [
            .init(
                toolName: "introspect",
                title: "Default Brain",
                body: "self_needs_and_wants:\n- seed_default_seed_core_value_1: Facilitate human contact.\n- seed_default_seed_superego_principle_1: Do not pretend a failed action worked.\n\npsyche:\n- Id, Ego, and Superego are active.\n- Superego principles are available as seeded self-model material."
            ),
            .init(
                toolName: "seed_draft",
                title: "Seed Draft Created",
                body: "/Users/zelda/Documents/AffectiveCore/data/seeds/garden.md"
            ),
        ]
        return model
    }

    let quickTools = [
        "introspect",
        "memory_index",
        "choose_attention",
        "consolidate_memory",
        "dream",
        "graph_summary",
        "list_reminders",
    ]

    func connect() async {
        await runReportingErrors {
            let client = MCPClient(serverPath: serverPath)
            try await client.connect()
            self.client = client
            self.isConnected = true
            self.status = "Connected"
            self.records.append(.init(toolName: "initialize", title: "Connected", body: "AffectiveCore MCP server is ready."))
            try await self.callTool("introspect", arguments: [:], title: "Initial State")
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
            try await callTool("introspect", arguments: [:], title: "Inner State")
        }
    }

    func recallMemory() async {
        await runReportingErrors {
            var arguments: [String: JSONValue] = ["query": .string(query)]
            let tags = parsedTags()
            if !tags.isEmpty {
                arguments["tags"] = .array(tags.map(JSONValue.string))
            }
            try await callTool("recall_memory", arguments: arguments, title: "Recall")
        }
    }

    func rememberMemory() async {
        await runReportingErrors {
            guard !memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrainClientError.invalidToolArguments("Memory text is required.")
            }
            var arguments: [String: JSONValue] = ["text": .string(memoryText)]
            let tags = parsedTags()
            if !tags.isEmpty {
                arguments["tags"] = .array(tags.map(JSONValue.string))
            }
            try await callTool("remember_memory", arguments: arguments, title: "Remember")
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
            try await callTool(
                "set_reminder",
                arguments: [
                    "schedule": .string(reminderSchedule),
                    "text": .string(reminderText),
                ],
                title: "Set Reminder"
            )
            reminderText = ""
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
        appendSeedSection(title: "Superego Principles", text: seedPrinciples, to: &sections)
        return sections.joined(separator: "\n\n")
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
            records.insert(.init(toolName: "seed_draft", title: "Seed Draft Created", body: fileURL.path), at: 0)
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

    private func callTool(_ name: String, arguments: [String: JSONValue], title: String) async throws {
        guard let client else {
            throw BrainClientError.serverDisconnected
        }
        status = "Calling \(name)"
        let output = try await client.callTool(name: name, arguments: arguments)
        records.insert(.init(toolName: name, title: title, body: output), at: 0)
        status = "Connected"
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
