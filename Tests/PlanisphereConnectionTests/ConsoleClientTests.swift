import Foundation
import XCTest
@testable import PlanisphereConnection

final class ConsoleClientTests: XCTestCase {
    func testPKCEKnownVector() throws {
        let attempt = ConnectionAttempt(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "test")
        XCTAssertEqual(attempt.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let random = try ConnectionAttempt()
        XCTAssertEqual(random.verifier.count, 43)
        XCTAssertEqual(random.state.count, 43)
        XCTAssertNotEqual(random.verifier, random.state)
    }

    func testCallbackBoundToAttemptAndFixedDestination() throws {
        let attempt = ConnectionAttempt(verifier: "v", state: "s")
        let code = String(repeating: "a", count: 43)
        let good = "ooo.planisphere.mac:/console-connected?code=\(code)&state=s"
        XCTAssertEqual(try attempt.code(from: URL(string: good)!), code)
        for value in [good + "&state=s", good + "&code=\(code)", good + "#other", good + "&error=no",
                      good.replacingOccurrences(of: "state=s", with: "state=other"),
                      good.replacingOccurrences(of: ":/", with: "://evil/"),
                      good.replacingOccurrences(of: "ooo.planisphere.mac:", with: "https:")] {
            XCTAssertThrowsError(try attempt.code(from: URL(string: value)!))
        }
    }

    func testBeginCannotRedirectBrowserOffOrigin() async throws {
        let client = ConsoleClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.planisphere.ooo/mac/connections/begin")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (Data(#"{"authorization_path":"https://evil.invalid"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await client.begin(ConnectionAttempt()); XCTFail("Accepted an external URL") }
        catch { XCTAssertEqual(error as? ConnectionError, .invalidResponse) }
    }

    func testRedirectAndExpiredCredentialFailClosed() async throws {
        for status in [302, 401] {
            let client = ConsoleClient { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Location": "https://evil.invalid"])!)
            }
            do { _ = try await client.status("secret"); XCTFail("Accepted failed status") }
            catch { XCTAssertEqual(error as? ConnectionError, status == 401 ? .signInAgain : .invalidResponse) }
        }
    }

    func testFailedDisconnectDoesNotClaimSuccess() async throws {
        let client = ConsoleClient { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
            return (Data(#"{"disconnected":false}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { try await client.disconnect("device-token"); XCTFail("Claimed disconnect") }
        catch { XCTAssertEqual(error as? ConnectionError, .invalidResponse) }
    }
}
