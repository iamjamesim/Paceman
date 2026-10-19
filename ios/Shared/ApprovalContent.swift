import Foundation

/// Separate known approval metadata from introductory prose without parsing,
/// reordering, or dropping any of the proposed tool input. Unknown formats stay prose.
struct ApprovalDetailContent {
    let explanation: String
    let action: String?
    init(_ detail: String) {
        if let boundary = detail.range(of: #"(?m)^(?:Tool: |Working directory: |Command: |\{)"#,
                                       options: .regularExpression) {
            explanation = String(detail[..<boundary.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            action = String(detail[boundary.lowerBound...])
        } else {
            explanation = detail
            action = nil
        }
    }
}
/// Present the documented shell hook input without guessing the meaning of
/// arbitrary tool fields. Unknown or malformed input stays verbatim.
struct ApprovalActionContent {
    enum Kind { case command, patch, tool }
    let body: String
    let tool: String?
    let directory: String?
    let explanation: String?
    let otherArguments: String?
    let kind: Kind
    init(_ action: String) {
        var remaining = action[...]
        var parsedTool: String?
        var parsedDirectory: String?
        while !remaining.isEmpty {
            let end = remaining.firstIndex(of: "\n") ?? remaining.endIndex
            let line = remaining[..<end]
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
        // Codex normalizes shell_command/exec_command to Bash command/description.
        // A field called description on an MCP tool may be content to write.
        let knownKind: Kind? = ["Bash", "PowerShell"].contains(parsedTool ?? "") ? .command
            : parsedTool == "apply_patch" ? .patch : nil
        if !explicitCommand, let knownKind,
           let data = original.data(using: .utf8),
           var input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let command = input["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input.removeValue(forKey: "command")
            let description = input["description"] as? String
            if description != nil || input["description"] is NSNull { input.removeValue(forKey: "description") }
            // Preserve every other argument, including unfamiliar fields and
            // non-string descriptions. If re-encoding fails, keep the full input.
            let extras = input.isEmpty ? nil : try? JSONSerialization.data(
                withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if input.isEmpty || extras != nil {
                body = command
                explanation = description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? description : nil
                otherArguments = extras.flatMap { String(data: $0, encoding: .utf8) }
                kind = knownKind
                return
            }
        }
        body = original
        explanation = nil
        otherArguments = nil
        kind = explicitCommand ? .command : .tool
    }

    func title(_ original: String) -> String {
        guard original == "Allow \(tool ?? "")?" else { return original }
        switch kind {
        case .command: return "Run this command?"
        case .patch: return "Apply these changes?"
        case .tool: return original
        }
    }
}
