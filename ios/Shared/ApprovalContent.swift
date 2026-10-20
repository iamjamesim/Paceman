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

/// Paceman content v2: provider decoding has already happened on the desktop.
/// JSON remains structured end to end, including unrecognized tool arguments.
indirect enum ApprovalJSON: Codable, Equatable {
    case object([String: ApprovalJSON]), array([ApprovalJSON]), string(String), number(Decimal), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Decimal.self) { self = .number(v) }
        else if let v = try? value.decode([String: ApprovalJSON].self) { self = .object(v) }
        else { self = .array(try value.decode([ApprovalJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    var formatted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
struct ApprovalPayload: Codable, Equatable {
    struct Action: Codable, Equatable {
        let kind: String
        var text: String? = nil
        var filePath: String? = nil
        var before: String? = nil
        var replaceAll: Bool? = nil
    }
    let toolName: String
    var workingDirectory: String? = nil
    var reason: String? = nil
    let input: ApprovalJSON
    let action: Action
    let hasAdditionalInput: Bool
    var valid: Bool {
        guard !toolName.isEmpty, toolName.count <= 256 else { return false }
        switch action.kind {
        case "command", "patch": return action.text != nil
        case "fileWrite": return action.text != nil && action.filePath?.isEmpty == false
        case "fileEdit": return action.text != nil && action.before != nil && action.filePath?.isEmpty == false
        case "tool": return true
        default: return false
        }
    }
}
struct ApprovalResponseOption: Codable, Identifiable, Equatable {
    let id: String
    let label: String
}

/// Known tool contracts get a useful presentation. Arbitrary MCP arguments are
/// never interpreted as shell input or stripped of fields that look like metadata.
struct ApprovalActionContent {
    enum Kind { case command, patch, fileWrite, fileEdit, tool }
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
        kind = decodedBody != nil ? decodedKind : explicitCommand ? .command : .tool
    }

    init(_ payload: ApprovalPayload) {
        tool = payload.toolName
        directory = payload.workingDirectory
        explanation = payload.reason
        originalInput = payload.input.formatted
        otherArguments = payload.hasAdditionalInput ? originalInput : nil
        body = payload.action.text ?? originalInput
        targetPath = payload.action.filePath
        previousBody = payload.action.before
        replacesAll = payload.action.replaceAll == true
        switch payload.action.kind {
        case "command": kind = .command
        case "patch": kind = .patch
        case "fileWrite": kind = .fileWrite
        case "fileEdit": kind = .fileEdit
        default: kind = .tool
        }
    }

    var sections: [Section] {
        if let previousBody { return [.init(label: "Before", text: previousBody), .init(label: "After", text: body)] }
        let label: String
        switch kind {
        case .command: label = "Command"
        case .patch: label = "Changes"
        case .fileWrite: label = "File contents"
        case .fileEdit: label = "Changes"
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
        let input: ApprovalJSON = editing ? .object(["file_path": .string(path), "old_string": .string(before),
            "new_string": .string(text), "replace_all": .bool(true)])
            : .object(["file_path": .string(path), "content": .string(text)])
        return ApprovalPayload(toolName: editing ? "Edit" : "Write", workingDirectory: "/Projects/Paceman",
            input: input, action: .init(kind: editing ? "fileEdit" : "fileWrite", text: text,
                filePath: path, before: editing ? before : nil, replaceAll: editing), hasAdditionalInput: false)
    }
    static let choices: [ApprovalResponseOption] = [
        .init(id: "once", label: "Allow once"), .init(id: "session", label: "Allow for this session"),
        .init(id: "decline", label: "Decline")]
    private static func detail(tool: String, input: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        return "Tool: \(tool)\nWorking directory: /Projects/Paceman\n\n" + String(decoding: data, as: UTF8.self)
    }
}
#endif
