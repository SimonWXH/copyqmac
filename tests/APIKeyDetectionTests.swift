// Content-level privacy: an AI-service API key copied once is dropped before it
// reaches the history, the skip log names the rule and never the secret, and the
// interface gets one short notice.
//
// The regression these tests guard: a key pasted once was stored in plaintext in
// SQLite and written into the sync folder, where the other machine read it back.
// When a user deliberately turns the switch off, the same key is captured again.

import AppKit
import Foundation

// MARK: - Sample keys

private enum BodyAlphabet {
    static let base62 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    static let base64URL = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
}

/// A body of exactly `length` characters drawn from `alphabet`.
///
/// Every sample key in this file is built from these helpers rather than typed
/// out, so each one has the length and character set the rule under test claims
/// while staying obviously synthetic: a live credential never appears here.
private func keyBody(_ length: Int, _ alphabet: String) -> String {
    var body = ""
    var index = alphabet.startIndex
    while body.count < length {
        body.append(alphabet[index])
        index = alphabet.index(after: index)
        if index == alphabet.endIndex { index = alphabet.startIndex }
    }
    return body
}

private enum SampleKey {
    /// OpenAI project key: `sk-proj-` and a long `-`/`_` capable body.
    static let openAIProject = "sk-proj-" + keyBody(70, BodyAlphabet.base64URL)
    /// OpenAI service-account key: `sk-svcacct-` and a long `-`/`_` capable body.
    static let openAIServiceAccount = "sk-svcacct-" + keyBody(70, BodyAlphabet.base64URL)
    /// OpenAI administrator key: `sk-admin-` and a long `-`/`_` capable body.
    static let openAIAdmin = "sk-admin-" + keyBody(70, BodyAlphabet.base64URL)
    /// OpenAI legacy key: `sk-` and 48 letters and digits.
    static let openAI = "sk-" + keyBody(48, BodyAlphabet.base62)
    /// Anthropic key: `sk-ant-api03-` and a long body.
    static let anthropic = "sk-ant-api03-" + keyBody(76, BodyAlphabet.base64URL)
    /// Google API key: `AIza` and 35 characters.
    static let google = "AIza" + keyBody(35, BodyAlphabet.base64URL)
    /// OpenRouter key: `sk-or-v1-` and a long letters-and-digits body.
    static let openRouter = "sk-or-v1-" + keyBody(64, BodyAlphabet.base62)
    /// OpenRouter key with a hexadecimal body, which the same row accepts.
    static let openRouterHex = "sk-or-v1-" + keyBody(64, "0123456789abcdef")
    /// An HTTP bearer credential carrying an AI-service key.
    static let bearerWithOpenAIKey = "Bearer " + openAI
}

// MARK: - Detection table

/// One clipboard text and the rule that must claim it, or nil for ordinary text
/// that must never be blocked.
private struct DetectionCase {
    let label: String
    let text: String
    let expectedRule: String?
}

private let detectionCases: [DetectionCase] = [
    // A key alone on the clipboard.
    DetectionCase(label: "openai", text: SampleKey.openAI, expectedRule: "openai"),
    DetectionCase(
        label: "anthropic",
        text: SampleKey.anthropic,
        expectedRule: "anthropic"
    ),
    DetectionCase(label: "google", text: SampleKey.google, expectedRule: "google"),
    DetectionCase(
        label: "openrouter",
        text: SampleKey.openRouter,
        expectedRule: "openrouter"
    ),
    DetectionCase(
        label: "openai-project in an env line",
        text: "OPENAI_API_KEY=" + SampleKey.openAIProject,
        expectedRule: "openai-project"
    ),
    DetectionCase(
        label: "openai service-account in an env line",
        text: "OPENAI_API_KEY=" + SampleKey.openAIServiceAccount,
        expectedRule: "openai-service-account"
    ),
    DetectionCase(
        label: "openai admin key",
        text: SampleKey.openAIAdmin,
        expectedRule: "openai-admin"
    ),
    DetectionCase(
        label: "anthropic in a quoted shell command",
        text: "export ANTHROPIC_API_KEY=\"" + SampleKey.anthropic + "\"",
        expectedRule: "anthropic"
    ),
    DetectionCase(
        label: "bearer header carrying an AI-service key",
        text: "Authorization: " + SampleKey.bearerWithOpenAIKey,
        expectedRule: "openai"
    ),
    DetectionCase(
        label: "an AI-service key is still found without a bearer scheme",
        text: "Authorization: " + SampleKey.openAIProject,
        expectedRule: "openai-project"
    ),
    DetectionCase(
        label: "env block",
        text: """
            # local settings
            OPENAI_API_KEY=\(SampleKey.openAIProject)
            OPENAI_ORG=acme
            """,
        expectedRule: "openai-project"
    ),
    // A bearer token for another service, or one carrying no AI-service shape,
    // is not this guard's business.
    DetectionCase(
        label: "github bearer token",
        text: "Authorization: Bearer ghp_" + keyBody(36, BodyAlphabet.base62),
        expectedRule: nil
    ),
    DetectionCase(
        label: "jwt bearer token",
        text: "Authorization: Bearer "
            + keyBody(20, BodyAlphabet.base62) + "." + keyBody(24, BodyAlphabet.base64URL)
            + "." + keyBody(20, BodyAlphabet.base64URL),
        expectedRule: nil
    ),
    // Ordinary text that merely contains a key opening.
    DetectionCase(
        label: "prose with sk-",
        text: "Please review the sk-learn tutorial before Monday's planning meeting.",
        expectedRule: nil
    ),
    // A short identifier with the same opening.
    DetectionCase(
        label: "short id",
        text: "Ticket sk-4821 is closed and linked from the release notes.",
        expectedRule: nil
    ),
    // A line that only names the scheme.
    DetectionCase(
        label: "bare Bearer word",
        text: "Use the Authorization header with the Bearer scheme.",
        expectedRule: nil
    ),
    // A bearer token far too short to be a credential.
    DetectionCase(
        label: "short bearer token",
        text: "Authorization: Bearer abc123",
        expectedRule: nil
    ),
    // A prefix with no usable body.
    DetectionCase(
        label: "prefix only",
        text: "The variable starts with sk-ant- and continues in the vault.",
        expectedRule: nil
    ),
    DetectionCase(
        label: "AIza prefix only",
        text: "Google keys start with AIza in older projects.",
        expectedRule: nil
    ),
    // A key-shaped run that continues a longer word is not a key.
    DetectionCase(
        label: "inside a word",
        text: "x" + "sk-" + keyBody(48, BodyAlphabet.base62) + " is a made-up identifier.",
        expectedRule: nil
    ),
    // Ordinary prose about keys.
    DetectionCase(
        label: "prose about keys",
        text: "Rotate the API key every 90 days and keep it in the password manager.",
        expectedRule: nil
    ),
    DetectionCase(label: "empty clipboard text", text: "", expectedRule: nil),
]

// MARK: - Watcher fixture

@MainActor
private final class GuardLogBox {
    var messages: [String] = []
}

@MainActor
private final class GuardNoticeBox {
    var count = 0
}

/// A real watcher on a private pasteboard, backed by a real store and a real
/// sync folder, so a blocked capture can be proven end to end.
@MainActor
private final class APIKeyGuardFixture {
    let store: ClipboardStore
    let history: ClipboardHistory
    let pasteboard: NSPasteboard
    let syncFolder: URL
    let writer: CopyQSyncWriter
    let watcher: ClipboardWatcher
    let logs: GuardLogBox
    let notices: GuardNoticeBox
    let frontmost = SourceApplication(bundleIdentifier: "com.apple.finder", name: "Finder")

    init() throws {
        let store = try ClipboardStore(inMemory: true)
        let history = ClipboardHistory(store: store)

        let root = try Fixtures.temporaryDirectory()
        let syncFolder = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        let logPath = root.appendingPathComponent("sync.log").path

        let writer = CopyQSyncWriter()
        writer.customLogFilePath = logPath

        var tab = try store.ensureDefaultTab()
        tab.syncFolder = syncFolder.path
        try store.updateTab(tab)

        let pasteboard = NSPasteboard(name: .init("copyqmac-api-key-test-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let logs = GuardLogBox()
        let notices = GuardNoticeBox()
        let source = SourceApplication(bundleIdentifier: "com.apple.finder", name: "Finder")
        let watcher = ClipboardWatcher(
            history: history,
            pasteboard: pasteboard,
            frontmostApplication: { source },
            ownBundleIdentifier: "local.copyqmac.app",
            logMessage: { logs.messages.append($0) }
        )
        watcher.noteActivation(source)
        watcher.onCapture = { entry in
            // The app reaches write-back through this callback, so running it
            // synchronously proves a blocked capture never gets there.
            _ = try? writer.writeEntry(entry, in: store)
        }
        watcher.onAPIKeyCaptureBlocked = { notices.count += 1 }

        self.store = store
        self.history = history
        self.pasteboard = pasteboard
        self.syncFolder = syncFolder
        self.writer = writer
        self.watcher = watcher
        self.logs = logs
        self.notices = notices
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func setAPIKeyGuard(_ enabled: Bool) throws {
        var preferences = try store.preferences()
        preferences.apiKeyGuardEnabled = enabled
        try store.setPreferences(preferences)
    }

    func poll() {
        watcher.pollNow()
        for _ in 0..<4 { RunLoop.main.run(until: Date()) }
    }

    func syncFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: syncFolder.path).sorted()
    }

    var allLogs: String { logs.messages.joined(separator: "\n") }
}

// MARK: - Tests

func registerAPIKeyDetectionTests() {
    TestRunner.currentSuite = "APIKeyDetection"

    TestRunner.add("each AI-service key shape is detected and named by its rule") {
        for testCase in detectionCases where testCase.expectedRule != nil {
            expectEqual(
                APIKeyDetection.match(in: testCase.text)?.label,
                testCase.expectedRule,
                "\(testCase.label) must be blocked and named"
            )
            expect(
                APIKeyDetection.match(in: [Fixtures.text(testCase.text)]) != nil,
                "\(testCase.label) must block a capture"
            )
        }
    }

    TestRunner.add("ordinary text that merely resembles a key is never blocked") {
        for testCase in detectionCases where testCase.expectedRule == nil {
            expectEqual(
                APIKeyDetection.match(in: testCase.text),
                nil,
                "\(testCase.label) must not be blocked"
            )
            expect(
                APIKeyDetection.match(in: [Fixtures.text(testCase.text)]) == nil,
                "\(testCase.label) must not block a capture"
            )
        }
    }

    TestRunner.add("the specificity of a prefix decides which rule is named") {
        // Every specific opening shares the generic `sk-` opening, so the
        // longer prefix has to win or the skip log would name the wrong shape.
        expectEqual(APIKeyDetection.match(in: SampleKey.openAIProject)?.label, "openai-project")
        expectEqual(
            APIKeyDetection.match(in: SampleKey.openAIServiceAccount)?.label,
            "openai-service-account"
        )
        expectEqual(APIKeyDetection.match(in: SampleKey.openAIAdmin)?.label, "openai-admin")
        expectEqual(APIKeyDetection.match(in: SampleKey.openRouter)?.label, "openrouter")
        expectEqual(APIKeyDetection.match(in: SampleKey.openRouterHex)?.label, "openrouter")
        expectEqual(APIKeyDetection.match(in: SampleKey.anthropic)?.label, "anthropic")
        expectEqual(APIKeyDetection.match(in: SampleKey.openAI)?.label, "openai")
    }

    TestRunner.add("detection reads the plain-text flavours and ignores the rest") {
        // UTF-16 is one of the plain-text flavours a real pasteboard carries.
        let utf16 = Flavour(
            itemIndex: 0,
            type: PasteboardTypes.utf16Text,
            data: SampleKey.openAIProject.data(using: .utf16) ?? Data()
        )
        expectEqual(APIKeyDetection.match(in: [utf16])?.label, "openai-project")

        // A key-shaped byte run in a non-text flavour (an image) is not claimed
        // by this guard: that is the honest limit the settings hint names.
        let png = Flavour(
            itemIndex: 0,
            type: PasteboardTypes.png,
            data: Data(SampleKey.openAIProject.utf8)
        )
        expectEqual(APIKeyDetection.match(in: [png]), nil)
        expectEqual(
            APIKeyDetection.match(in: [Fixtures.text("ordinary words"), png]),
            nil,
            "an ordinary text flavour next to a non-text flavour stays unblocked"
        )
    }

    TestRunner.add("the guard is on by default and a preferences blob without it decodes to on") {
        expectEqual(Preferences.defaultValue.apiKeyGuardEnabled, true)

        let legacy = Data(#"{"defaultMaxItems": 25, "searchAllTabs": true}"#.utf8)
        guard let decoded = try? JSONDecoder().decode(Preferences.self, from: legacy) else {
            TestRunner.fail("a legacy preferences blob must still decode")
            return
        }
        expectEqual(decoded.apiKeyGuardEnabled, true, "a blob without the switch defaults to on")
        expectEqual(decoded.defaultMaxItems, 25, "the rest of the blob is untouched")

        var stored = Preferences.defaultValue
        stored.apiKeyGuardEnabled = false
        guard let roundTrip = try? JSONDecoder().decode(
            Preferences.self,
            from: JSONEncoder().encode(stored)
        ) else {
            TestRunner.fail("preferences must round-trip")
            return
        }
        expectEqual(roundTrip.apiKeyGuardEnabled, false, "an off switch stays off")
    }

    TestRunner.add("a copied key is skipped before SQLite and the sync folder") {
        MainActor.assumeIsolated {
            do {
                let fixture = try APIKeyGuardFixture()
                fixture.copy(SampleKey.anthropic)
                fixture.poll()

                expectEqual(try fixture.store.count(), 0, "no history row is written")
                expectEqual(try fixture.syncFiles(), [], "no sync file is written")
                expect(
                    fixture.allLogs.contains("skipped clipboard capture: an AI service API key (anthropic)"),
                    "the skip log names the rule: \(fixture.allLogs)"
                )
                expect(
                    !fixture.allLogs.contains("sk-ant-"),
                    "the skip log never carries the matched secret: \(fixture.allLogs)"
                )
                expectEqual(fixture.notices.count, 1, "the interface is told once")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("with the switch off the same key is captured and written back") {
        MainActor.assumeIsolated {
            do {
                let fixture = try APIKeyGuardFixture()
                try fixture.setAPIKeyGuard(false)

                fixture.copy(SampleKey.openAIProject)
                fixture.poll()

                expectEqual(try fixture.store.count(), 1, "the capture is stored")
                expectEqual(fixture.notices.count, 0, "nothing is announced")
                expectEqual(try fixture.syncFiles().isEmpty, false, "the capture reaches the sync folder")
                expect(
                    !fixture.allLogs.contains("AI service API key"),
                    "no skip is logged: \(fixture.allLogs)"
                )

                // Turning the switch back on protects the next capture without a
                // restart, because the watcher reads the stored preferences.
                try fixture.setAPIKeyGuard(true)
                fixture.copy(SampleKey.anthropic)
                fixture.poll()
                expectEqual(try fixture.store.count(), 1, "the blocked capture adds no row")
                expectEqual(fixture.notices.count, 1, "the blocked capture is announced")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an ordinary capture is untouched by the guard") {
        MainActor.assumeIsolated {
            do {
                let fixture = try APIKeyGuardFixture()
                fixture.copy("Groceries: milk, bread, and the sk-learn notebook")
                fixture.poll()

                expectEqual(try fixture.store.count(), 1, "the ordinary capture is stored")
                expectEqual(fixture.notices.count, 0, "nothing is announced")
                expect(
                    !fixture.allLogs.contains("API service key") && !fixture.allLogs.contains("API key"),
                    "no skip is logged: \(fixture.allLogs)"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
