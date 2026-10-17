import Foundation
import XCTest
@testable import PlanisphereConnection

final class WorkspaceClientTests: XCTestCase {
    func credential(_ workspace: String = "a", permissions: [String] = ["prompts:read", "hooks:read"]) throws -> ConnectionCredential {
        let object: [String: Any] = ["token": "ps_mac_" + String(repeating: "a", count: 43), "connection": ["id": "device", "label": "Mac", "workspace": ["id": workspace, "name": workspace], "expires_at": "2026-11-01T00:00:00Z", "permissions": permissions, "vault_sync_enabled": false]]
        return try JSONDecoder().decode(ConnectionCredential.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testMissingScopeNeverSendsCredential() async throws {
        let client = WorkspaceClient { _ in XCTFail("Must not send without consent"); throw URLError(.badURL) }
        do { _ = try await client.prompts(credential(permissions: []), filter: PromptFilter()); XCTFail() }
        catch { XCTAssertEqual(error as? WorkspaceError, .permissionRequired) }
    }
    func testWorkspaceMismatchAndRedirectAreRejected() async throws {
        for redirect in [false, true] {
            let client = WorkspaceClient { request in
                let url = redirect ? URL(string: "https://other.invalid/mac/workspace/prompts")! : request.url!
                return (Data(#"{"workspace_id":"b","prompts":[],"next_cursor":null,"coverage":"reported"}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await client.prompts(credential(), filter: PromptFilter()); XCTFail() }
            catch { XCTAssertEqual(error as? WorkspaceError, .invalidResponse) }
        }
    }
    func testFiltersAreEncodedAndPrivateTransportHasNoCookieOrKeyFallback() async throws {
        let client = WorkspaceClient { request in
            XCTAssertEqual(request.url!.host, "api.planisphere.ooo")
            XCTAssertEqual(request.url!.path, "/mac/workspace/prompts")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Planisphere-Key"))
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "q" }?.value, "a&workspace=b")
            XCTAssertEqual(items.first { $0.name == "before" }?.value, "cursor")
            return (Data(#"{"workspace_id":"a","prompts":[],"next_cursor":null,"coverage":"reported"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var filter = PromptFilter(); filter.query = "a&workspace=b"
        _ = try await client.prompts(credential(), filter: filter, before: "cursor")
    }
    func testRevokedAndOfflineAreDifferentFromEmptyHistory() async throws {
        for (status, expected) in [(401, WorkspaceError.signInAgain), (403, .permissionRequired), (503, .unavailable)] {
            let client = WorkspaceClient { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
            do { _ = try await client.hooks(credential()); XCTFail() }
            catch { XCTAssertEqual(error as? WorkspaceError, expected) }
        }
    }

    // Fixture serialized by the API Prompt model and present(include_calls: true).
    func testPopulatedAPIPromptDecodesUsageAndCalls() async throws {
        let data = Data(#"{"workspace_id":"a","prompt":{"session_id":"session","prompt_id":"p1","agent_system":"codex","system_id":"codex-local","revision":1,"status":"completed","started_at":"2026-10-10T10:00:00Z","ended_at":"2026-10-10T10:01:00Z","coverage":{"status":"observed","limitations":[]},"exchange":null,"task_information":null,"receipt_action_key":null,"receipt_payload_hash":null,"receipt_id":null,"parent_agent_system":null,"parent_session_id":null,"parent_prompt_id":null,"parent_link_source":null,"usage_id":"usage_83b1a436903ad461f115e8023984ca90a56347e8","summary":{"observations":1,"metrics":{"input_tokens":{"observed":100,"estimated":null,"missing_observations":0,"complete":true},"output_tokens":{"observed":25,"estimated":null,"missing_observations":0,"complete":true},"cache_read_input_tokens":{"observed":40,"estimated":null,"missing_observations":0,"complete":true},"cache_write_input_tokens":{"observed":10,"estimated":null,"missing_observations":0,"complete":true},"reasoning_output_tokens":{"observed":5,"estimated":null,"missing_observations":0,"complete":true},"total_tokens":{"observed":125,"estimated":null,"missing_observations":0,"complete":true},"normalized_input_tokens":{"observed":100,"estimated":null,"missing_observations":0,"complete":true},"normalized_output_tokens":{"observed":25,"estimated":null,"missing_observations":0,"complete":true},"normalized_total_tokens":{"observed":125,"estimated":null,"missing_observations":0,"complete":true}},"exchange":{"prompts":1,"metrics":{"prompt_bytes":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"response_bytes":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"prompt_messages":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"response_messages":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"prompt_storage_bits":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"response_storage_bits":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"exchange_bytes":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"storage_bits":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false}},"expansion_ratio":null,"groups":[{"system_id":"codex-local","agent_system":"codex","prompts":1,"metrics":{"prompt_bytes":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"response_bytes":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"prompt_messages":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"response_messages":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"prompt_storage_bits":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"response_storage_bits":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"exchange_bytes":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false},"storage_bits":{"observed":null,"missing_prompts":1,"partial_prompts":0,"complete":false}}}],"scope":"reported_visible_text_only","limits":"UTF-8 text sizes exclude unreported context, protocol framing, tools and attachments. Storage bits are eight times bytes, not semantic information. Task information is not summed across prompts."},"groups":[{"system_id":"codex-local","agent_system":"codex","provider":"openai","model":"fixture-model","observations":1,"metrics":{"input_tokens":{"observed":100,"estimated":null,"missing_observations":0,"complete":true},"output_tokens":{"observed":25,"estimated":null,"missing_observations":0,"complete":true},"cache_read_input_tokens":{"observed":40,"estimated":null,"missing_observations":0,"complete":true},"cache_write_input_tokens":{"observed":10,"estimated":null,"missing_observations":0,"complete":true},"reasoning_output_tokens":{"observed":5,"estimated":null,"missing_observations":0,"complete":true},"total_tokens":{"observed":125,"estimated":null,"missing_observations":0,"complete":true},"normalized_input_tokens":{"observed":100,"estimated":null,"missing_observations":0,"complete":true},"normalized_output_tokens":{"observed":25,"estimated":null,"missing_observations":0,"complete":true},"normalized_total_tokens":{"observed":125,"estimated":null,"missing_observations":0,"complete":true}}}],"coverage":{"mode":"reported_observations_only","percent":null,"untracked_observations":null},"evidence_basis":"authenticated_connector_report","limits":"Usage covers reported observations only; untracked usage is unknown. Cache and reasoning may overlap input/output. Provider totals and normalized totals are separate. This is connector-reported telemetry, not billing or measured human effort."},"exchange_accounting":{"prompt_storage_bits":null,"response_storage_bits":null,"exchange_bytes":null,"storage_bits":null,"expansion_ratio":null,"coverage":{"status":"missing","limitations":["No exchange measurement was reported."]}},"information_accounting":{"entropy_change_bits":null,"task_bits_per_byte":null,"status":"unavailable","reason":"not_estimated","basis_current":false,"evidence_basis":"declared_model_and_reported_correctness"},"calls":[{"source_id":"c1","provider":"openai","model":"fixture-model","input_tokens":100,"output_tokens":25,"cache_read_input_tokens":40,"cache_write_input_tokens":10,"reasoning_output_tokens":5,"total_tokens":125,"measurement":"observed","input_semantics":"includes_cache","reasoning_semantics":"included_in_output","source":{"format":"synthetic-usage-v1","adapter_version":"1","app_version":null,"fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","basis":"explicit synthetic response counters"},"status":"completed","started_at":null,"normalized":{"input_tokens":100,"output_tokens":25,"cache_read_input_tokens":40,"cache_write_input_tokens":10,"reasoning_output_tokens":5,"total_tokens":125,"normalized_input_tokens":100,"normalized_output_tokens":25,"normalized_total_tokens":125}}]}}"#.utf8)
        let client = WorkspaceClient { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let prompt = try await client.detail("usage_83b1a436903ad461f115e8023984ca90a56347e8", credential: credential())
        XCTAssertEqual(prompt.prompt_id, "p1")
        XCTAssertEqual(prompt.summary.metrics["input_tokens"]?.observed, 100)
        XCTAssertEqual(prompt.summary.metrics["output_tokens"]?.observed, 25)
        XCTAssertEqual(prompt.calls?.first?.model, "fixture-model")
        XCTAssertEqual(prompt.calls?.first?.measurement, "observed")
        XCTAssertEqual(prompt.coverage.status, "observed")
    }
}
