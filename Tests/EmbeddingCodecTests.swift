// SPDX-License-Identifier: MIT

import XCTest
@testable import Scribe

final class EmbeddingCodecTests: XCTestCase {
    func testRoundTrip() {
        let vector: [Float] = [0.125, -2.5, 3.25, 0, 1e-6, -1e6]
        XCTAssertEqual(EmbeddingCodec.decode(EmbeddingCodec.encode(vector)), vector)
    }

    func testEmptyDataDecodesToEmptyVector() {
        XCTAssertEqual(EmbeddingCodec.decode(Data()), [])
    }

    func testDecodeToleratesMisalignedBytes() {
        // A blob sliced at an odd offset must still decode (the decoder copies
        // instead of rebinding memory, so alignment can't crash it).
        let vector: [Float] = [1, 2, 3]
        var padded = Data([0x00])
        padded.append(EmbeddingCodec.encode(vector))
        let slice = padded.subdata(in: 1..<padded.count)
        XCTAssertEqual(EmbeddingCodec.decode(slice), vector)
    }

    func testTrailingPartialFloatIsIgnored() {
        var data = EmbeddingCodec.encode([1, 2])
        data.append(contentsOf: [0xAB, 0xCD])
        XCTAssertEqual(EmbeddingCodec.decode(data), [1, 2])
    }
}
