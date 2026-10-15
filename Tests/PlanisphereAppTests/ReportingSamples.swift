import Foundation
import PlanisphereConnection

// Same fixture as the Connection tests; test targets cannot share sources.
/// Hook commands shaped like the console's generator, carrying `key`.
enum SampleHooks {
    static func grant(key: String = "ps_test_abcDEF123-_x", workspace: String = "workspace") -> [String: Any] {
        let post = "| curl -sS -m 8 -X POST https://api.planisphere.ooo/v1/record -H \"X-Planisphere-Key: \(key)\" -H \"Content-Type: application/json\" -d @- >/dev/null 2>&1 & exit 0"
        let start = "INPUT=$(cat); mkdir -p /tmp/planisphere; printf '%s\\n' \"$INPUT\" | jq -r '.model // \"unknown\"' > \"/tmp/planisphere/model-$(printf '%s\\n' \"$INPUT\" | jq -r .session_id)\"; exit 0"
        func cmd(_ event: String) -> String { "INPUT=$(cat); jq '{pack:\"ai-provenance\",event_type:\"\(event)\",system_id:\"claude-code-primary\"}' \(post)" }
        return ["workspace_id": workspace, "system_id": "claude-code-primary", "settings_file": "~/.claude/settings.json",
                "key": ["key_id": "key-1", "label": "Planisphere on Mac · Claude Code hooks", "active": true, "created_at": "2026-10-14T20:00:00Z", "revoked_at": NSNull(), "last_used_at": NSNull()],
                "hooks": ["SessionStart": [["hooks": [["type": "command", "command": start]]]],
                          "PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": cmd("tool_used")]]]],
                          "UserPromptSubmit": [["hooks": [["type": "command", "command": cmd("prompt_submitted")]]]],
                          "Stop": [["hooks": [["type": "command", "command": cmd("agent_response")]]]]]]
    }
    static func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    static func credential(permissions: [String] = ["connection:read", "connection:revoke", "activity:record", "hooks:read", "prompts:read"]) -> ConnectionCredential {
        let json = """
        {"token":"ps_mac_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","connection":{"id":"device","label":"Planisphere on Mac","workspace":{"id":"workspace","name":"My workspace"},"email":null,"expires_at":"2026-11-10T12:00:00Z","permissions":\(try! String(data: JSONSerialization.data(withJSONObject: permissions), encoding: .utf8)!),"vault_sync_enabled":false}}
        """
        return try! JSONDecoder().decode(ConnectionCredential.self, from: Data(json.utf8))
    }
}


/// A scratch folder with no symbolic link anywhere above it (macOS's temp dir sits under /var → /private/var,
/// and URL.resolvingSymlinksInPath keeps the /var spelling).
func scratchFolder(_ name: String) -> URL {
    let temporary = FileManager.default.temporaryDirectory.path
    guard let resolved = realpath(temporary, nil) else { return URL(fileURLWithPath: temporary).appendingPathComponent(name, isDirectory: true) }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent(name, isDirectory: true)
}
