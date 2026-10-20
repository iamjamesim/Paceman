import Foundation

/// Compatibility decoder for Paceman's retired, flattened detail field. This is
/// our wire format, not a provider hook schema. Only paragraph-boundary headers
/// are recognized; prose containing a quoted header is left intact.
struct ApprovalDetailContent {
    let explanation: String
    let action: String?
    init(_ detail: String) {
        var start = detail.startIndex
        while start < detail.endIndex {
            let candidate = String(detail[start...])
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let isJSON = (trimmed.hasPrefix("{") || trimmed.hasPrefix("["))
                && trimmed.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
            if candidate.hasPrefix("Tool: ") || candidate.hasPrefix("Working directory: ")
                || candidate.hasPrefix("Command: ") || isJSON {
                explanation = String(detail[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
                action = candidate
                return
            }
            guard let paragraph = detail.range(of: "\n\n", range: start..<detail.endIndex) else { break }
            start = paragraph.upperBound
        }
        explanation = detail
        action = nil
    }
}

/// Desktop-decoded content plus its complete source JSON representation.
/// Opaque JSON stays serialized: client numeric types must not round tool input.
struct ApprovalPayload: Codable, Equatable {
    struct Action: Codable, Equatable {
        enum TerminalOperation: String { case interrupt, poll, write }
        enum Content {
            case command(String), patch(String)
            case fileWrite(path: String, text: String)
            case fileEdit(path: String, before: String, after: String, replaceAll: Bool)
            case terminalInput(sessionID: String, text: String, operation: TerminalOperation, parentCommand: String?)
            case tool
        }
        let kind: String
        var text: String? = nil
        var filePath: String? = nil
        var before: String? = nil
        var replaceAll: Bool? = nil
        var terminalSessionID: String? = nil
        var operation: String? = nil
        var parentCommand: String? = nil
        var content: Content? {
            guard (kind == "terminalInput" || (terminalSessionID == nil && operation == nil && parentCommand == nil)),
                  (kind == "fileEdit" || (before == nil && replaceAll == nil)),
                  (["fileWrite", "fileEdit"].contains(kind) || filePath == nil) else { return nil }
            switch kind {
            case "command": return text.map(Content.command)
            case "patch": return text.map(Content.patch)
            case "fileWrite":
                guard let filePath, !filePath.isEmpty, let text else { return nil }
                return .fileWrite(path: filePath, text: text)
            case "fileEdit":
                guard let filePath, !filePath.isEmpty, let before, let text else { return nil }
                return .fileEdit(path: filePath, before: before, after: text, replaceAll: replaceAll == true)
            case "terminalInput":
                guard let terminalSessionID, !terminalSessionID.isEmpty, let text,
                      let operation = operation.flatMap(TerminalOperation.init(rawValue:)) else { return nil }
                let interrupt = !text.isEmpty && text.allSatisfy { $0 == "\u{03}" }
                guard (operation == .interrupt && interrupt) || (operation == .poll && text.isEmpty)
                    || (operation == .write && !text.isEmpty && !interrupt) else { return nil }
                return .terminalInput(sessionID: terminalSessionID, text: text, operation: operation, parentCommand: parentCommand)
            case "tool": return text == nil ? .tool : nil
            default: return nil
            }
        }
    }
    let toolName: String
    var workingDirectory: String? = nil
    var reason: String? = nil
    let inputJSON: String
    let action: Action
    let hasAdditionalInput: Bool
    var valid: Bool {
        guard InteractionWire.text(toolName, limit: 256), !inputJSON.isEmpty, inputJSON.utf8.count <= 32768 else { return false }
        return action.content != nil
    }
}
struct ApprovalResponseOption: Codable, Identifiable, Equatable {
    let id: String
    let label: String
}

/// Known tool contracts get a useful presentation. Arbitrary MCP arguments are
/// never interpreted as shell input or stripped of fields that look like metadata.
struct ApprovalActionContent {
    enum Kind { case command, patch, fileWrite, fileEdit, terminalInput, tool }
    struct Section {
        let label: String
        let text: String
    }
    let body: String
    let tool: String?
    let directory: String?
    let explanation: String?
    let otherArguments: String?
    let kind: Kind
    let originalInput: String
    let targetPath: String?
    let previousBody: String?
    let replacesAll: Bool
    let terminalSessionID: String?
    let terminalOperation: ApprovalPayload.Action.TerminalOperation?
    let parentCommand: String?

    init(_ action: String) {
        var remaining = action[...]
        var parsedTool: String?
        var parsedDirectory: String?
        while !remaining.isEmpty {
            let end = remaining.firstIndex(of: "\n") ?? remaining.endIndex
            let line = remaining[..<end].trimmingCharacters(in: .newlines)
            if line.hasPrefix("Tool: "), parsedTool == nil {
                parsedTool = String(line.dropFirst(6))
            } else if line.hasPrefix("Working directory: "), parsedDirectory == nil {
                parsedDirectory = String(line.dropFirst(19))
            } else { break }
            remaining = end == remaining.endIndex ? ""[...] : remaining[remaining.index(after: end)...]
        }
        let explicitCommand = remaining.hasPrefix("Command: ")
        if explicitCommand { remaining = remaining.dropFirst(9) }
        else if remaining.hasPrefix("\n") { remaining = remaining.dropFirst() }
        tool = parsedTool
        directory = parsedDirectory
        let original = String(remaining)
        originalInput = original
        var decodedBody: String?
        var decodedReason: String?
        var decodedKind: Kind = explicitCommand ? .command : .tool
        var consumed: Set<String> = []
        var extras: String?
        if !explicitCommand, let data = original.data(using: .utf8),
           var input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // Narrow compatibility for the retired v1 wire format only.
            if ["Bash", "PowerShell", "apply_patch"].contains(parsedTool ?? ""),
               let command = input["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                decodedBody = command
                let reason = input["description"] as? String
                decodedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? reason : nil
                decodedKind = parsedTool == "apply_patch" ? .patch : .command
                consumed.insert("command")
                if input["description"] is String || input["description"] is NSNull { consumed.insert("description") }
            }
            if decodedBody != nil {
                for key in consumed { input.removeValue(forKey: key) }
                if !input.isEmpty {
                    extras = (try? JSONSerialization.data(withJSONObject: input,
                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                        .flatMap { String(data: $0, encoding: .utf8) }
                    // If an extension cannot be represented, keep the complete
                    // original rather than silently losing part of the action.
                    if extras == nil { decodedBody = nil }
                }
            }
        }
        body = decodedBody ?? original
        explanation = decodedBody != nil ? decodedReason : nil
        otherArguments = decodedBody != nil ? extras : nil
        targetPath = nil
        previousBody = nil
        replacesAll = false
        terminalSessionID = nil
        terminalOperation = nil
        parentCommand = nil
        kind = decodedBody != nil ? decodedKind : explicitCommand ? .command : .tool
    }

    init(_ payload: ApprovalPayload) {
        tool = payload.toolName
        directory = payload.workingDirectory
        explanation = payload.reason
        originalInput = payload.inputJSON
        otherArguments = payload.hasAdditionalInput ? originalInput : nil
        var path: String?, before: String?, terminal: String?, command: String?
        var replaces = false
        var operation: ApprovalPayload.Action.TerminalOperation?
        switch payload.action.content {
        case .command(let text): kind = .command; body = text
        case .patch(let text): kind = .patch; body = text
        case .fileWrite(let filePath, let text): kind = .fileWrite; body = text; path = filePath
        case .fileEdit(let filePath, let previous, let text, let all):
            kind = .fileEdit; body = text; path = filePath; before = previous; replaces = all
        case .terminalInput(let sessionID, let text, let terminalOperation, let parent):
            kind = .terminalInput; terminal = sessionID; operation = terminalOperation; command = parent
            switch terminalOperation {
            case .interrupt: body = text.count == 1 ? "Ctrl-C" : "Ctrl-C × \(text.count)"
            case .poll: body = "No characters will be sent."
            case .write: body = (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? text
            }
        default: kind = .tool; body = originalInput
        }
        targetPath = path
        previousBody = before
        replacesAll = replaces
        terminalSessionID = terminal
        self.terminalOperation = operation
        parentCommand = command
    }

    var sections: [Section] {
        if let parentCommand { return [.init(label: "Input", text: body), .init(label: "Running command", text: parentCommand)] }
        if let previousBody { return [.init(label: "Before", text: previousBody), .init(label: "After", text: body)] }
        let label: String
        switch kind {
        case .command: label = "Command"
        case .patch: label = "Changes"
        case .fileWrite: label = "File contents"
        case .fileEdit: label = "Changes"
        case .terminalInput: label = "Input"
        case .tool: label = "Tool input"
        }
        return [.init(label: label, text: body)]
    }

    func title(_ original: String) -> String {
        guard original == "Allow \(tool ?? "")?" else { return original }
        switch kind {
        case .command: return "Run this command?"
        case .patch: return "Apply these changes?"
        case .fileWrite: return "Write this file?"
        case .fileEdit: return "Edit this file?"
        case .terminalInput:
            switch terminalOperation {
            case .interrupt: return "Interrupt this terminal?"
            case .poll: return "Read terminal output?"
            default: return "Send input to this terminal?"
            }
        case .tool: return original
        }
    }
}

/// A display-only excerpt. The original text is never truncated or submitted
/// from this value. Character and line budgets keep Watch controls reachable,
/// including for one enormous line of JSON; Dynamic Type remains uncapped.
struct ApprovalTextPreview {
    enum Surface { case phone, watch }
    let fullText: String
    let excerpt: String
    let needsExpansion: Bool
    let jsonSummary: String?

    init(_ text: String, surface: Surface) {
        fullText = text
        let characterLimit = surface == .watch ? 180 : 500
        let lineLimit = surface == .watch ? 4 : 8
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let firstLines = lines.prefix(lineLimit).joined(separator: "\n")
        excerpt = String(firstLines.prefix(characterLimit))
        needsExpansion = excerpt != text
        if let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let keys = object.keys.sorted()
            let names = keys.prefix(3).map { String($0.prefix(32)) }.joined(separator: ", ")
            jsonSummary = keys.isEmpty ? "No arguments" : "\(keys.count) \(keys.count == 1 ? "field" : "fields"): \(names)\(keys.count > 3 ? ", …" : "")"
        } else { jsonSummary = nil }
    }
}

#if DEBUG
/// Synthetic payloads for reviewing large requests without invoking an agent.
enum ApprovalPreviewFixtures {
    static let pageTool = "mcp__codex_apps__chatgpt_space_edit_page"
    static var largePageEdit: String {
        detail(tool: pageTool, input: ["page_id": "page_fixture", "stream_kind": "content",
            "operations": [["op": "replace_block_markdown", "block_id": "block_fixture",
                "expected_hash": "fixture-hash", "block_units": [["kind": "markdown",
                    "markdown": String(repeating: "Proposed page content. ", count: 350),
                    "metadata": ["image": ["file_id": "fixture-image", "width": 210.5, "height": 256]]]]]]])
    }
    static var longCommand: String {
        detail(tool: "Bash", input: ["command": "python3 - <<'PY'\n" + String(repeating: "print('Verify the change')\n", count: 100) + "PY",
                                     "description": "Verify the generated output.", "timeout": 120000])
    }
    static func file(_ editing: Bool) -> ApprovalPayload {
        let path = "/Projects/Paceman/notes.md"
        let text = String(repeating: "Proposed file content.\n", count: 100)
        let before = "Previous wording."
        let input: [String: Any] = editing ? ["file_path": path, "old_string": before, "new_string": text, "replace_all": true]
            : ["file_path": path, "content": text]
        return ApprovalPayload(toolName: editing ? "Edit" : "Write", workingDirectory: "/Projects/Paceman",
            inputJSON: json(input), action: .init(kind: editing ? "fileEdit" : "fileWrite", text: text,
                filePath: path, before: editing ? before : nil, replaceAll: editing ? true : nil), hasAdditionalInput: false)
    }
    static let choices: [ApprovalResponseOption] = [
        .init(id: "once", label: "Allow once"), .init(id: "session", label: "Allow for this session"),
        .init(id: "decline", label: "Decline")]
    static func terminal(_ operation: String = "interrupt", parent: Bool = true) -> ApprovalPayload {
        let text = operation == "interrupt" ? "\u{03}\u{03}" : operation == "poll" ? "" : "echo ready\n"
        let input: [String: Any] = ["session_id": 35467, "chars": text,
            "parent_call_id": "parent_fixture", "approval_id": "approval_fixture"]
        return ApprovalPayload(toolName: "write_stdin", inputJSON: json(input),
            action: .init(kind: "terminalInput", text: text, terminalSessionID: "35467", operation: operation,
                parentCommand: parent ? "xcodebuild test-without-building -resultBundlePath /private/tmp/paceman-watch-tests.xcresult\n" + String(repeating: "  -only-testing:AgentCompanionTests/InteractionTests\n", count: 40) : nil),
            hasAdditionalInput: true)
    }
    private static func detail(tool: String, input: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        return "Tool: \(tool)\nWorking directory: /Projects/Paceman\n\n" + String(decoding: data, as: UTF8.self)
    }
    private static func json(_ input: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
#endif
