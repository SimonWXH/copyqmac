// Bundle resource validation and stale resource assertions.
// Ensures that the resources sealed in the staged app bundle are exactly the
// source resources in resources/, and that stale, untracked, or dropped
// resources cause loud build/test failures.

import Foundation

func registerBundleResourcesTests() {
    TestRunner.currentSuite = "BundleResources"

    let scriptURL = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tools/assert-bundle-resources.sh")

    func runScript(bundlePath: String, sourcePath: String) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, bundlePath, sourcePath]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", "Failed to launch process: \(error)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    struct Fixture {
        let base: URL
        let bundle: URL
        let sourceResources: URL

        var bundleResources: URL { bundle.appendingPathComponent("Contents/Resources") }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    func makeFixture() throws -> Fixture {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-resources-\(UUID().uuidString)")
        let fixture = Fixture(
            base: tempBase,
            bundle: tempBase.appendingPathComponent("Test.app"),
            sourceResources: tempBase.appendingPathComponent("resources")
        )

        try FileManager.default.createDirectory(at: fixture.bundleResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.sourceResources, withIntermediateDirectories: true)

        let iconData = "fake-icon-data".data(using: .utf8)!
        try iconData.write(to: fixture.sourceResources.appendingPathComponent("AppIcon.icns"))
        try iconData.write(to: fixture.bundleResources.appendingPathComponent("AppIcon.icns"))

        return fixture
    }

    TestRunner.add("assertion script succeeds when bundle resources match source tree") {
        do {
            let fixture = try makeFixture()
            defer { fixture.remove() }

            let result = runScript(bundlePath: fixture.bundle.path, sourcePath: fixture.sourceResources.path)

            expectEqual(result.exitCode, 0, "script should exit 0 on matching resources")
            expect(result.stdout.contains("Verified bundle resources"), "should confirm verification in stdout")
        } catch {
            TestRunner.fail("setup failed: \(error)")
        }
    }

    TestRunner.add("assertion script fails loudly naming offending file when bundle contains stale resource") {
        do {
            let fixture = try makeFixture()
            defer { fixture.remove() }

            // Plant a stale resource that does not exist in the source tree
            try "stale-icon".data(using: .utf8)!.write(to: fixture.bundleResources.appendingPathComponent("CopyEm.icns"))

            let result = runScript(bundlePath: fixture.bundle.path, sourcePath: fixture.sourceResources.path)

            expectNotEqual(result.exitCode, 0, "script must fail on untracked resource")
            expect(
                result.stderr.contains("CopyEm.icns"),
                "error message must name the offending stale file: got '\(result.stderr)'"
            )
            expect(
                result.stderr.contains("stale or untracked resource"),
                "error message must explain the stale resource: got '\(result.stderr)'"
            )
        } catch {
            TestRunner.fail("setup failed: \(error)")
        }
    }

    TestRunner.add("assertion script fails loudly naming a source resource that never reached the bundle") {
        do {
            let fixture = try makeFixture()
            defer { fixture.remove() }

            try "dropped-icon".data(using: .utf8)!.write(to: fixture.sourceResources.appendingPathComponent("CopyEm.icns"))

            let result = runScript(bundlePath: fixture.bundle.path, sourcePath: fixture.sourceResources.path)

            expectNotEqual(result.exitCode, 0, "script must fail when a source resource is not staged")
            expect(
                result.stderr.contains("CopyEm.icns"),
                "error message must name the source resource missing from the bundle: got '\(result.stderr)'"
            )
            expect(
                result.stderr.contains("missing source resource"),
                "error message must explain the missing resource: got '\(result.stderr)'"
            )
        } catch {
            TestRunner.fail("setup failed: \(error)")
        }
    }
}
