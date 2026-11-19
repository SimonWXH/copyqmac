// A tiny test harness.
//
// XCTest and swift-testing both live in Xcode, which this machine does not
// have, so the tests are a plain executable with a minimal assertion layer.
// It runs anywhere a process can run: no window server, no GUI session, no
// Accessibility permission.

import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum TestRunner {
    static var currentSuite: String = ""
    private static var tests: [(name: String, suite: String, body: () throws -> Void)] = []
    private static var failures: [(test: String, message: String)] = []
    private static var currentTest = ""
    private static var assertions = 0

    static func add(_ name: String, _ body: @escaping () throws -> Void) {
        tests.append((name, currentSuite, body))
    }

    static func fail(_ message: String, file: StaticString = #file, line: UInt = #line) {
        let location = "\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line)"
        failures.append((currentTest, "\(message) [\(location)]"))
    }

    static func pass() { assertions += 1 }

    static func run() -> Never {
        let args = CommandLine.arguments.dropFirst()
        var filter: String?
        var iter = args.makeIterator()
        while let arg = iter.next() {
            if arg == "--filter" {
                filter = iter.next()
            } else if !arg.hasPrefix("-") && filter == nil {
                filter = arg
            }
        }
        let testsToRun = tests.filter { test in
            guard let filter = filter, !filter.isEmpty else { return true }
            return test.name.localizedCaseInsensitiveContains(filter) || test.suite.localizedCaseInsensitiveContains(filter)
        }
        let start = Date()
        for test in testsToRun {
            currentTest = test.name
            do {
                try test.body()
            } catch {
                fail("threw \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        print("")
        if failures.isEmpty {
            print("OK  \(testsToRun.count) tests, \(assertions) assertions in \(String(format: "%.3f", elapsed))s")
            exit(0)
        }
        print("FAILED  \(failures.count) failure(s) in \(testsToRun.count) tests")
        for failure in failures {
            print("  [\(failure.test)] \(failure.message)")
        }
        exit(1)
    }
}

// MARK: - Assertions

func expect(_ condition: Bool, _ message: String = "condition was false", file: StaticString = #file, line: UInt = #line) {
    if condition { TestRunner.pass() } else { TestRunner.fail(message, file: file, line: line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if actual == expected {
        TestRunner.pass()
    } else {
        let detail = message.isEmpty ? "" : "\(message): "
        TestRunner.fail("\(detail)expected \(expected), got \(actual)", file: file, line: line)
    }
}

func expectEqual(_ actual: Double, _ expected: Double, accuracy: Double, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if abs(actual - expected) <= accuracy {
        TestRunner.pass()
    } else {
        let detail = message.isEmpty ? "" : "\(message): "
        TestRunner.fail("\(detail)expected \(expected) +/- \(accuracy), got \(actual)", file: file, line: line)
    }
}

func expectNotEqual<T: Equatable>(_ actual: T, _ unexpected: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if actual != unexpected { TestRunner.pass() } else {
        let detail = message.isEmpty ? "" : "\(message): "
        TestRunner.fail("\(detail)expected value different from \(unexpected)", file: file, line: line)
    }
}

func expectNil<T>(_ value: T?, _ message: String = "expected nil", file: StaticString = #file, line: UInt = #line) {
    if value == nil { TestRunner.pass() } else { TestRunner.fail("\(message), got \(String(describing: value))", file: file, line: line) }
}

func expectNotNil<T>(_ value: T?, _ message: String = "expected a value", file: StaticString = #file, line: UInt = #line) {
    if value != nil { TestRunner.pass() } else { TestRunner.fail(message, file: file, line: line) }
}

func expectThrows(_ body: () throws -> Void, _ message: String = "expected an error", file: StaticString = #file, line: UInt = #line) {
    do {
        try body()
        TestRunner.fail(message, file: file, line: line)
    } catch {
        TestRunner.pass()
    }
}

/// Failure marker thrown by `unwrap`, so a test body stops at a nil value the
/// way `XCTUnwrap` does.
struct UnwrapFailure: Error {}

/// Returns `value`, recording a failure and throwing when it is nil.  The
/// XCTest-free equivalent of `XCTUnwrap`.
func unwrap<T>(_ value: T?, _ message: String = "expected a value", file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else {
        TestRunner.fail(message, file: file, line: line)
        throw UnwrapFailure()
    }
    return value
}

@MainActor
func duplicateMenuShortcuts(in menu: NSMenu) -> [String] {
    var seen: [String: String] = [:]
    var duplicates: [String] = []
    func visit(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem && !item.keyEquivalent.isEmpty {
            let mask = item.keyEquivalentModifierMask.subtracting([.shift, .function])
            let identifier = "\(item.keyEquivalent)|\(mask.rawValue)"
            if let first = seen[identifier] {
                duplicates.append("\(first) and \(item.title) share \(identifier)")
            } else {
                seen[identifier] = item.title
            }
        }
        for item in menu.items {
            if let submenu = item.submenu { visit(submenu) }
        }
    }
    visit(menu)
    return duplicates
}

/// A real `NSDraggingSession` is only created by AppKit for a live drag, which
/// a headless suite cannot start. This subclass only supplies the pasteboard
/// the shipped delegate method writes through, so the delegate call itself is
/// exercised rather than its implementation being called directly.
final class TestDraggingSession: NSDraggingSession {
    /// The base class owns drag-session resources that it only disposes when it
    /// deinitializes. The suites keep their stand-in sessions alive so teardown
    /// cannot try to dispose a session AppKit never created.
    private static var retained: [TestDraggingSession] = []

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init()
        Self.retained.append(self)
    }

    override var draggingPasteboard: NSPasteboard { pasteboard }
}

// MARK: - Fixtures

enum Fixtures {
    /// A valid 1x1 PNG.
    static let pngData = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==
        """)!

    static let gifData = Data(base64Encoded: """
        R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7
        """)!

    static func text(_ string: String, itemIndex: Int = 0) -> Flavour {
        Flavour(itemIndex: itemIndex, type: PasteboardTypes.utf8Text, data: Data(string.utf8))
    }

    static func fileURL(_ path: String, itemIndex: Int = 0) -> Flavour {
        Flavour(
            itemIndex: itemIndex,
            type: PasteboardTypes.fileURL,
            data: Data("file://\(path)".utf8)
        )
    }

    static func largeTIFF(width: Int = 800, height: Int = 800) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.tiff" as CFString, 1, nil as CFDictionary?)!
        CGImageDestinationAddImage(destination, image, nil as CFDictionary?)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func jpegWithEmbeddedThumbnail(width: Int, height: Int, thumbWidth: Int, thumbHeight: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        let fullCtx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo.rawValue)!
        fullCtx.setFillColor(red: 0.1, green: 0.4, blue: 0.7, alpha: 1.0)
        fullCtx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let fullImage = fullCtx.makeImage()!

        let thumbCtx = CGContext(data: nil, width: thumbWidth, height: thumbHeight, bitsPerComponent: 8, bytesPerRow: thumbWidth * 4, space: colorSpace, bitmapInfo: bitmapInfo.rawValue)!
        thumbCtx.setFillColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)
        thumbCtx.fill(CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
        let thumbImage = thumbCtx.makeImage()!

        let fullData = NSMutableData()
        let fullDest = CGImageDestinationCreateWithData(fullData as CFMutableData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(fullDest, fullImage, nil)
        CGImageDestinationFinalize(fullDest)

        let thumbData = NSMutableData()
        let thumbDest = CGImageDestinationCreateWithData(thumbData as CFMutableData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(thumbDest, thumbImage, nil)
        CGImageDestinationFinalize(thumbDest)

        let fullJpeg = fullData as Data
        let thumbJpeg = thumbData as Data

        var tiff = Data()
        tiff.append(contentsOf: [0x49, 0x49, 0x2A, 0x00]) // II, 42
        let ifd0Offset: UInt32 = 8
        tiff.append(contentsOf: withUnsafeBytes(of: ifd0Offset.littleEndian) { Array($0) })

        let ifd0Entries: UInt16 = 0
        tiff.append(contentsOf: withUnsafeBytes(of: ifd0Entries.littleEndian) { Array($0) })
        let ifd1Offset: UInt32 = 14
        tiff.append(contentsOf: withUnsafeBytes(of: ifd1Offset.littleEndian) { Array($0) })

        let ifd1Entries: UInt16 = 2
        tiff.append(contentsOf: withUnsafeBytes(of: ifd1Entries.littleEndian) { Array($0) })

        let thumbOffset: UInt32 = 44
        let thumbLen: UInt32 = UInt32(thumbJpeg.count)

        tiff.append(contentsOf: withUnsafeBytes(of: UInt16(0x0201).littleEndian) { Array($0) })
        tiff.append(contentsOf: withUnsafeBytes(of: UInt16(4).littleEndian) { Array($0) })
        tiff.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian) { Array($0) })
        tiff.append(contentsOf: withUnsafeBytes(of: thumbOffset.littleEndian) { Array($0) })

        tiff.append(contentsOf: withUnsafeBytes(of: UInt16(0x0202).littleEndian) { Array($0) })
        tiff.append(contentsOf: withUnsafeBytes(of: UInt16(4).littleEndian) { Array($0) })
        tiff.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian) { Array($0) })
        tiff.append(contentsOf: withUnsafeBytes(of: thumbLen.littleEndian) { Array($0) })

        let nextIFD: UInt32 = 0
        tiff.append(contentsOf: withUnsafeBytes(of: nextIFD.littleEndian) { Array($0) })
        tiff.append(thumbJpeg)

        var app1 = Data()
        app1.append(contentsOf: [0xFF, 0xE1])
        let app1Length = UInt16(2 + 6 + tiff.count)
        app1.append(contentsOf: withUnsafeBytes(of: app1Length.bigEndian) { Array($0) })
        app1.append(contentsOf: "Exif\0\0".utf8)
        app1.append(tiff)

        var combined = Data()
        combined.append(fullJpeg.prefix(2))
        combined.append(app1)
        combined.append(fullJpeg.dropFirst(2))
        return combined
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("copyqmac-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
