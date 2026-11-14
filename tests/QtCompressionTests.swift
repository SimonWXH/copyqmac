// Compression: the load-time validator and the read-time decoder share one
// framing and inflate policy, so they must agree on every payload.

import Foundation

func registerQtCompressionTests() {
    TestRunner.add("isValid and decompress agree on valid and corrupted payloads") {
        func expectAgreement(
            _ data: Data,
            _ label: String,
            maximumSize: Int = QtCompression.defaultMaximumUncompressedSize
        ) -> Data? {
            let decoded = try? QtCompression.decompress(data, maximumSize: maximumSize)
            expectEqual(
                QtCompression.isValid(data, maximumSize: maximumSize),
                decoded != nil,
                "validity must match decompression for \(label)"
            )
            return decoded
        }

        let payload = Data("copyqmac compression equivalence".utf8)
        guard let valid = QtCompression.compress(payload) else {
            TestRunner.fail("could not compress the fixture payload")
            return
        }
        expectEqual(expectAgreement(valid, "a valid stream"), payload, "a valid stream decodes")

        guard let empty = QtCompression.compress(Data()) else {
            TestRunner.fail("could not compress an empty payload")
            return
        }
        expectEqual(expectAgreement(empty, "an empty stream"), Data(), "an empty stream decodes")

        var truncated = valid
        truncated.removeLast()
        expectEqual(expectAgreement(truncated, "a truncated stream"), nil, "a truncated stream is rejected")

        var trailing = valid
        trailing.append(contentsOf: [0x00, 0x01])
        expectEqual(expectAgreement(trailing, "a stream with trailing bytes"), nil, "trailing bytes are rejected")

        var oversizedDeclared = valid
        oversizedDeclared[0] = 0xFF
        oversizedDeclared[1] = 0xFF
        oversizedDeclared[2] = 0xFF
        oversizedDeclared[3] = 0xFF
        expectEqual(
            expectAgreement(oversizedDeclared, "a stream with an oversized declared size"),
            nil,
            "an oversized declared size is rejected"
        )

        expectEqual(
            expectAgreement(valid, "a stream above the caller's cap", maximumSize: 8),
            nil,
            "a stream above the caller's cap is rejected"
        )

        expectEqual(expectAgreement(Data(), "an empty buffer"), nil, "an empty buffer is rejected")
        expectEqual(
            expectAgreement(Data([0x00, 0x00, 0x00, 0x00]), "a zero-length payload"),
            Data(),
            "a zero-length payload decodes to empty data"
        )
        expectEqual(
            expectAgreement(Data([0x00, 0x00, 0x00, 0x01, 0x01]), "a short payload"),
            nil,
            "a short payload is rejected"
        )
        expectEqual(
            expectAgreement(Data([0x00, 0x00, 0x00, 0x00, 0x01]), "a zero-length payload with extra bytes"),
            nil,
            "extra bytes after a zero-length payload are rejected"
        )

        var corrupt = valid
        corrupt[corrupt.count / 2] ^= 0xFF
        expectEqual(expectAgreement(corrupt, "a corrupted zlib stream"), nil, "a corrupted stream is rejected")
    }
}
