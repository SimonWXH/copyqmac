// SPDX-License-Identifier: GPL-3.0-or-later
//
// System zlib bridge.
//
// CopyQ stores some clipboard flavours zlib compressed when the flavour was
// captured compressed or persisted above item_data_threshold. The framing is
// Qt's `qCompress`/`qUncompress`: a big-endian *uncompressed* size followed
// by a raw zlib stream. macOS ships zlib, so the module links it with `-lz`
// instead of pulling in a third party dependency.

import Foundation

public enum QtCompressionError: Error, Equatable, CustomStringConvertible {
    case corrupt(String)
    case outOfRange(String)

    public var description: String {
        switch self {
        case .corrupt(let msg): return msg
        case .outOfRange(let msg): return msg
        }
    }
}

private typealias ZAlloc = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32) -> UnsafeMutableRawPointer?
private typealias ZFree = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

private struct ZStream {
    var nextIn: UnsafeMutablePointer<UInt8>?
    var availIn: UInt32 = 0
    var totalIn: UInt = 0
    var nextOut: UnsafeMutablePointer<UInt8>?
    var availOut: UInt32 = 0
    var totalOut: UInt = 0
    var message: UnsafeMutablePointer<CChar>?
    var state: UnsafeMutableRawPointer?
    var allocate: ZAlloc?
    var release: ZFree?
    var opaque: UnsafeMutableRawPointer?
    var dataType: Int32 = 0
    var adler: UInt = 0
    var reserved: UInt = 0

    init() {
        nextIn = nil
        nextOut = nil
        message = nil
        state = nil
        allocate = nil
        release = nil
        opaque = nil
    }
}

@_silgen_name("zlibVersion")
private func zlib_version() -> UnsafePointer<CChar>

@_silgen_name("inflateInit_")
private func zlib_inflateInit(
    _ stream: UnsafeMutablePointer<ZStream>?,
    _ version: UnsafePointer<CChar>?,
    _ streamSize: Int32
) -> Int32

@_silgen_name("inflate")
private func zlib_inflate(_ stream: UnsafeMutablePointer<ZStream>?, _ flush: Int32) -> Int32

@_silgen_name("inflateEnd")
private func zlib_inflateEnd(_ stream: UnsafeMutablePointer<ZStream>?) -> Int32

@_silgen_name("compress2")
private func zlib_compress2(
    _ dest: UnsafeMutablePointer<UInt8>?,
    _ destLen: UnsafeMutablePointer<UInt>?,
    _ source: UnsafePointer<UInt8>?,
    _ sourceLen: UInt,
    _ level: Int32
) -> Int32

private let zlibOK: Int32 = 0
private let zlibStreamEnd: Int32 = 1
private let zlibBufferError: Int32 = -5

/// zlib in the framing Qt's `qCompress` / `qUncompress` use.
public enum QtCompression {
    /// Default upper bound for a decompressed clipboard flavour.
    public static let defaultMaximumUncompressedSize = 256 * 1024 * 1024

    /// Decodes a `qCompress` payload without allocating from its untrusted
    /// declared size. Callers may explicitly raise the output limit.
    public static func decompress(
        _ data: Data,
        maximumSize: Int = defaultMaximumUncompressedSize
    ) throws -> Data {
        var output = Data()
        _ = try inflate(data, maximumSize: maximumSize) { bytes in
            output.append(contentsOf: bytes)
        }
        return output
    }

    /// Validates a `qCompress` payload without allocating uncompressed buffers.
    public static func isValid(
        _ data: Data,
        maximumSize: Int = defaultMaximumUncompressedSize
    ) -> Bool {
        do {
            _ = try inflate(data, maximumSize: maximumSize) { _ in }
            return true
        } catch {
            return false
        }
    }

    /// Shared `qCompress` framing and inflate state machine.
    ///
    /// `sink` receives the produced bytes in order; `decompress` appends them
    /// while `isValid` discards them, so both enforce exactly the same validity
    /// rules and neither allocates from the untrusted declared size.
    private static func inflate(
        _ data: Data,
        maximumSize: Int,
        sink: (UnsafeBufferPointer<UInt8>) -> Void
    ) throws -> Int {
        guard maximumSize >= 0 else {
            throw QtCompressionError.outOfRange("negative decompression limit")
        }
        let bytes = [UInt8](data)
        if bytes.count <= 4 {
            if bytes.count == 4, bytes.allSatisfy({ $0 == 0 }) { return 0 }
            throw QtCompressionError.corrupt("invalid qCompress payload")
        }

        let expected = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        guard UInt64(expected) <= UInt64(maximumSize) else {
            throw QtCompressionError.corrupt(
                "flavour too large: declared \(expected) bytes exceeds maximum \(maximumSize)"
            )
        }
        let source = Array(bytes[4...])
        guard source.count >= 8, source.count <= Int(UInt32.max) else {
            throw QtCompressionError.corrupt("invalid qCompress input length \(source.count)")
        }

        var stream = ZStream()
        let initStatus = zlib_inflateInit(
            &stream,
            zlib_version(),
            Int32(MemoryLayout<ZStream>.size)
        )
        guard initStatus == zlibOK else {
            throw QtCompressionError.corrupt("could not initialize zlib decompressor")
        }
        defer { _ = zlib_inflateEnd(&stream) }

        let declaredSize = Int(expected)
        var totalProduced = 0
        let inflateStatus: Int32 = source.withUnsafeBufferPointer { sourceBuffer in
            stream.nextIn = UnsafeMutablePointer(mutating: sourceBuffer.baseAddress!)
            stream.availIn = UInt32(sourceBuffer.count)

            while true {
                let remaining = maximumSize - totalProduced
                let chunkSize = remaining >= 64 * 1024 ? 64 * 1024 : remaining + 1
                var chunk = [UInt8](repeating: 0, count: max(1, chunkSize))
                let status = chunk.withUnsafeMutableBufferPointer { outputBuffer -> Int32 in
                    stream.nextOut = outputBuffer.baseAddress
                    stream.availOut = UInt32(outputBuffer.count)
                    return zlib_inflate(&stream, 0)
                }
                let produced = chunk.count - Int(stream.availOut)
                if totalProduced + produced > maximumSize {
                    return -100
                }
                if totalProduced + produced > declaredSize {
                    return -101
                }
                totalProduced += produced
                if produced > 0 {
                    chunk.withUnsafeBufferPointer { buffer in
                        sink(UnsafeBufferPointer(start: buffer.baseAddress, count: produced))
                    }
                }

                if status == zlibStreamEnd { return status }
                if status != zlibOK && status != zlibBufferError { return status }
                if produced == 0 && stream.availIn == 0 { return -102 }
            }
        }

        if inflateStatus == -100 {
            throw QtCompressionError.corrupt(
                "flavour too large: decompressed output exceeds maximum \(maximumSize)"
            )
        }
        if inflateStatus == -101 {
            throw QtCompressionError.corrupt(
                "qCompress output exceeds its declared size of \(expected) bytes"
            )
        }
        guard inflateStatus == zlibStreamEnd else {
            throw QtCompressionError.corrupt("invalid or truncated qCompress zlib stream")
        }
        guard stream.availIn == 0 else {
            throw QtCompressionError.corrupt("qCompress input contains trailing bytes")
        }
        guard totalProduced == declaredSize else {
            throw QtCompressionError.corrupt(
                "qCompress declared \(expected) bytes but produced \(totalProduced)"
            )
        }
        return totalProduced
    }

    /// Encodes `data` in `qCompress` framing.
    public static func compress(_ data: Data, level: Int32 = -1) -> Data? {
        let source = [UInt8](data)
        if source.isEmpty {
            return Data([0, 0, 0, 0])
        }
        guard source.count <= Int(UInt32.max) else { return nil }

        var capacity = UInt(source.count) + UInt(source.count / 100) + 13
        while true {
            var output = [UInt8](repeating: 0, count: Int(capacity) + 4)
            var outputLength = UInt(capacity)
            let status = output.withUnsafeMutableBufferPointer { out -> Int32 in
                source.withUnsafeBufferPointer { src -> Int32 in
                    zlib_compress2(
                        out.baseAddress?.advanced(by: 4),
                        &outputLength,
                        src.baseAddress,
                        UInt(src.count),
                        level
                    )
                }
            }

            if status == zlibOK {
                let size = UInt32(source.count)
                output[0] = UInt8((size >> 24) & 0xFF)
                output[1] = UInt8((size >> 16) & 0xFF)
                output[2] = UInt8((size >> 8) & 0xFF)
                output[3] = UInt8(size & 0xFF)
                return Data(output.prefix(Int(outputLength) + 4))
            }
            if status == zlibBufferError {
                capacity *= 2
                continue
            }
            return nil
        }
    }

    /// Encodes `data` in `qCompress` framing for compressed-input tests.
    public static func compressForTesting(_ data: Data, level: Int32 = -1) -> Data? {
        compress(data, level: level)
    }
}
