// SPDX-License-Identifier: MIT

import XCTest
@testable import Scribe

final class SummarizationBackendTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SummarizationBackend.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SummarizationBackend.defaultsKey)
        super.tearDown()
    }

    func testDefaultBackendIsAppleFoundationModels() {
        XCTAssertEqual(SummarizationBackend.configured, .appleFoundationModels)
        XCTAssertEqual(SummarizationBackend.default, .appleFoundationModels)
    }

    func testFlagRoundTripsThroughUserDefaults() {
        SummarizationBackend.store(.mlxQwen)
        XCTAssertEqual(SummarizationBackend.configured, .mlxQwen)
        SummarizationBackend.store(.appleFoundationModels)
        XCTAssertEqual(SummarizationBackend.configured, .appleFoundationModels)
    }

    func testMLXFlagSelectsMLXClient() {
        let client = SummarizerClientFactory.makeClient(backend: .mlxQwen)
        XCTAssertTrue(client is MLXLLMClient)
    }

    func testAppleBackendFallsBackToMLXWhenUnavailable() {
        // When Apple Intelligence isn't available on the test host, the factory
        // must still return a usable client rather than nil/crash.
        let client = SummarizerClientFactory.makeClient(backend: .appleFoundationModels)
        if SummarizerClientFactory.appleFoundationModelsAvailable {
            XCTAssertFalse(client is MLXLLMClient) // got the Apple client
        } else {
            XCTAssertTrue(client is MLXLLMClient) // fell back
        }
    }
}
