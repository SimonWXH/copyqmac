// Capture-level privacy: app exclusions, pasteboard privacy markers, and the
// promise that a skipped capture leaves no row, no sync file, and no payload
// in any log.

import AppKit
import Foundation

@MainActor
private final class LogBox {
    var messages: [String] = []
}

@MainActor
private final class EntryBox {
    var entries: [ClipboardEntry] = []
}

@MainActor
private final class FrontmostBox {
    var application: SourceApplication?
}

/// A real watcher on a private pasteboard, backed by a real store and a real
/// sync folder, so a skip can be proven end to end without synthetic input or
/// the user's pasteboard.
@MainActor
private final class CaptureExclusionFixture {
    let store: ClipboardStore
    let history: ClipboardHistory
    let pasteboard: NSPasteboard
    let syncFolder: URL
    let logPath: String
    let writer: CopyQSyncWriter
    let watcher: ClipboardWatcher
    let logs: LogBox
    let captures: EntryBox
    let frontmost: FrontmostBox

    init(
        source: SourceApplication? = SourceApplication(bundleIdentifier: "com.apple.finder", name: "Finder"),
        ownBundleIdentifier: String? = "local.copyqmac.app"
    ) throws {
        let store = try ClipboardStore(inMemory: true)
        let history = ClipboardHistory(store: store)

        let root = try Fixtures.temporaryDirectory()
        let syncFolder = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        let logPath = root.appendingPathComponent("sync.log").path

        let writer = CopyQSyncWriter()
        writer.customLogFilePath = logPath

        let pasteboard = NSPasteboard(name: .init("copyqmac-exclusion-test-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let logs = LogBox()
        let captures = EntryBox()
        let frontmost = FrontmostBox()
        frontmost.application = source
        let watcher = ClipboardWatcher(
            history: history,
            pasteboard: pasteboard,
            frontmostApplication: { frontmost.application },
            ownBundleIdentifier: ownBundleIdentifier,
            logMessage: { logs.messages.append($0) }
        )
        watcher.noteActivation(source)
        watcher.onCapture = { entry in
            captures.entries.append(entry)
            // The app reaches write-back through this callback, so running it
            // synchronously here proves the skipped path never reaches it.
            _ = try? writer.writeEntry(entry, in: store)
        }

        self.store = store
        self.history = history
        self.pasteboard = pasteboard
        self.syncFolder = syncFolder
        self.logPath = logPath
        self.writer = writer
        self.watcher = watcher
        self.logs = logs
        self.captures = captures
        self.frontmost = frontmost
    }

    func enableSync() throws {
        var tab = try store.ensureDefaultTab()
        tab.syncFolder = syncFolder.path
        try store.updateTab(tab)

        var preferences = try store.preferences()
        preferences.syncPaused = false
        try store.setPreferences(preferences)
    }

    func setExclusions(_ rules: [CaptureExclusionRule]) throws {
        var preferences = try store.preferences()
        preferences.captureExclusions = rules
        try store.setPreferences(preferences)
    }

    func removeExclusion(bundleIdentifier: String) throws {
        var preferences = try store.preferences()
        preferences.captureExclusions.removeAll {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
        try store.setPreferences(preferences)
    }

    func copy(_ text: String, marker: String? = nil) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let marker {
            pasteboard.setData(Data("1".utf8), forType: NSPasteboard.PasteboardType(marker))
        }
    }

    func setFrontmost(_ bundleIdentifier: String, name: String? = nil) {
        frontmost.application = SourceApplication(
            bundleIdentifier: bundleIdentifier,
            name: name ?? bundleIdentifier
        )
    }

    func poll() {
        watcher.pollNow()
        drainMainQueue()
    }

    /// Runs queued main-queue work, including the activation notifications a
    /// poll waits for and the deferred capture decision.
    func drainMainQueue() {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date())
        }
    }

    func syncFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: syncFolder.path).sorted()
    }

    func syncLog() -> String {
        (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    }

    func entryCount() throws -> Int {
        try store.count()
    }
}

func registerCaptureExclusionTests() {
    TestRunner.currentSuite = "CaptureExclusion"

    TestRunner.add("built-in password managers are ignored before any configuration") {
        MainActor.assumeIsolated {
            do {
                let payload = "correct horse battery staple 9f3c"
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.1password.1password",
                        name: "1Password"
                    )
                )
                try fixture.enableSync()
                fixture.copy(payload)
                fixture.poll()

                expectEqual(try fixture.entryCount(), 0, "no row is created")
                expectEqual(try fixture.syncFiles(), [], "no sync file is written")
                expect(
                    fixture.logs.messages.contains { $0.contains("com.1password.1password") },
                    "the skip names the matched rule"
                )
                expect(
                    !fixture.logs.messages.contains { $0.contains(payload) },
                    "no log line contains the payload"
                )
                expect(
                    !fixture.syncLog().contains(payload),
                    "the sync log never contains the payload"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("default preferences list the well-known password managers") {
        let identifiers = Set(
            Preferences.defaultValue.captureExclusions
                .filter(\.isEnabled)
                .map(\.bundleIdentifier)
        )
        for expected in [
            "com.1password.1password",
            "com.bitwarden.desktop",
            "com.apple.keychainaccess",
            "com.apple.Passwords",
            "org.keepassxc.keepassxc",
        ] {
            expect(identifiers.contains(expected), "default list must contain \(expected)")
        }
    }

    TestRunner.add("an older preferences blob without exclusions gets the built-in list") {
        do {
            let encoded = try JSONEncoder().encode(Preferences.defaultValue)
            guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                TestRunner.fail("could not read the encoded preferences")
                return
            }
            object.removeValue(forKey: "captureExclusions")
            let legacy = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(Preferences.self, from: legacy)
            expect(
                decoded.captureExclusions.contains { $0.bundleIdentifier == "com.1password.1password" },
                "a missing key falls back to the built-in list"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a disabled built-in rule lets its app capture again") {
        MainActor.assumeIsolated {
            do {
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.bitwarden.desktop",
                        name: "Bitwarden"
                    )
                )
                try fixture.enableSync()
                var rules = CaptureExclusionCatalog.builtInRules
                guard let index = rules.firstIndex(where: { $0.bundleIdentifier == "com.bitwarden.desktop" })
                else {
                    TestRunner.fail("Bitwarden must be a built-in rule")
                    return
                }
                rules[index].isEnabled = false
                try fixture.setExclusions(rules)

                fixture.copy("not a secret any more")
                fixture.poll()

                expectEqual(try fixture.entryCount(), 1, "a disabled rule no longer skips")
                expectEqual(try fixture.syncFiles().isEmpty, false, "the capture is written back")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a custom exclusion skips, and removing it restores capture") {
        MainActor.assumeIsolated {
            do {
                let ignoredPayload = "private payload 51e9"
                let keptPayload = "public payload 72b1"
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.example.private",
                        name: "Example Private"
                    )
                )
                try fixture.enableSync()
                try fixture.setExclusions([
                    CaptureExclusionRule(
                        bundleIdentifier: "com.example.private",
                        name: "Example Private"
                    ),
                ])

                fixture.copy(ignoredPayload)
                fixture.poll()
                expectEqual(try fixture.entryCount(), 0, "the custom rule skips")
                expectEqual(try fixture.syncFiles(), [], "the skipped capture writes no file")

                try fixture.removeExclusion(bundleIdentifier: "com.example.private")
                fixture.copy(keptPayload)
                fixture.poll()

                expectEqual(try fixture.entryCount(), 1, "removing the rule restores capture")
                expectEqual(fixture.captures.entries.count, 1, "the capture callback runs")
                expectEqual(try fixture.syncFiles().isEmpty, false, "the restored capture writes a file")
                expect(
                    !fixture.logs.messages.contains { $0.contains(ignoredPayload) },
                    "no watcher log line contains the skipped payload"
                )
                expect(
                    !fixture.syncLog().contains(ignoredPayload),
                    "the sync log never contains the skipped payload"
                )
                expect(
                    fixture.syncLog().contains(keptPayload) == false,
                    "the sync log records file metadata, not payload"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a non-excluded app still captures") {
        MainActor.assumeIsolated {
            do {
                let payload = "ordinary clipboard text"
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.apple.TextEdit",
                        name: "TextEdit"
                    )
                )
                try fixture.enableSync()
                fixture.copy(payload)
                fixture.poll()

                expectEqual(try fixture.entryCount(), 1)
                expectEqual(try fixture.syncFiles().isEmpty, false)
                expectEqual(
                    FlavourDecoder.plainText(from: fixture.captures.entries.first?.flavours ?? []),
                    payload,
                    "the full content is recorded"
                )
                expectEqual(
                    fixture.watcher.lastObservedFrontmostApplication?.bundleIdentifier,
                    "com.apple.TextEdit"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a pasteboard privacy marker skips even when the app is not excluded") {
        MainActor.assumeIsolated {
            do {
                let payload = "concealed secret d1a7"
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.apple.TextEdit",
                        name: "TextEdit"
                    )
                )
                try fixture.enableSync()
                fixture.copy(payload, marker: "org.nspasteboard.ConcealedType")
                fixture.poll()

                expectEqual(try fixture.entryCount(), 0, "the marker skips the capture")
                expectEqual(try fixture.syncFiles(), [], "no file is written for a marked capture")
                expect(
                    !fixture.logs.messages.contains { $0.contains(payload) },
                    "no log line contains the payload"
                )
                expect(
                    !fixture.syncLog().contains(payload),
                    "the sync log never contains the payload"
                )
                expectEqual(
                    fixture.watcher.lastObservedFrontmostApplication?.bundleIdentifier,
                    "com.apple.TextEdit"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a copy inside a window with an excluded app is skipped") {
        MainActor.assumeIsolated {
            do {
                let payload = "secret in an excluded window 1a2b"
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.example.private",
                        name: "Example Private"
                    )
                )
                try fixture.enableSync()
                try fixture.setExclusions([
                    CaptureExclusionRule(
                        bundleIdentifier: "com.example.private",
                        name: "Example Private"
                    ),
                ])
                fixture.copy(payload)
                fixture.poll()

                expectEqual(try fixture.entryCount(), 0, "the excluded window skips")
                expectEqual(try fixture.syncFiles(), [], "no sync file is written")
                expect(
                    fixture.logs.messages.contains { $0.contains("com.example.private") },
                    "the skip names the excluded app"
                )
                expect(
                    !fixture.logs.messages.contains { $0.contains(payload) },
                    "no log line contains the payload"
                )
                expect(
                    !fixture.syncLog().contains(payload),
                    "the sync log never contains the payload"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an excluded app already in the window skips after switching away") {
        MainActor.assumeIsolated {
            do {
                let payload = "secret copied before the switch 4c81"
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.example.private",
                        name: "Example Private"
                    )
                )
                try fixture.enableSync()
                try fixture.setExclusions([
                    CaptureExclusionRule(
                        bundleIdentifier: "com.example.private",
                        name: "Example Private"
                    ),
                ])
                fixture.copy(payload)
                fixture.setFrontmost("com.apple.TextEdit", name: "TextEdit")
                fixture.poll()

                expectEqual(try fixture.entryCount(), 0, "the excluded window skips")
                expectEqual(try fixture.syncFiles(), [], "no sync file is written")
                expectEqual(
                    fixture.watcher.lastObservedFrontmostApplication?.bundleIdentifier,
                    "com.apple.TextEdit",
                    "the hint follows the live app"
                )
                expect(
                    fixture.logs.messages.contains { $0.contains("com.example.private") },
                    "the skip names the excluded app"
                )
                expect(
                    !fixture.logs.messages.contains { $0.contains(payload) },
                    "no log line contains the payload"
                )
                expect(
                    !fixture.syncLog().contains(payload),
                    "the sync log never contains the payload"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an excluded app entering the window after a copy skips") {
        MainActor.assumeIsolated {
            do {
                let payload = "secret copied before the excluded app 7d2b"
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.apple.TextEdit",
                        name: "TextEdit"
                    )
                )
                try fixture.enableSync()
                try fixture.setExclusions([
                    CaptureExclusionRule(
                        bundleIdentifier: "com.example.private",
                        name: "Example Private"
                    ),
                ])
                fixture.copy(payload)
                fixture.setFrontmost("com.example.private", name: "Example Private")
                fixture.poll()

                expectEqual(try fixture.entryCount(), 0, "the excluded window skips")
                expectEqual(try fixture.syncFiles(), [], "no sync file is written")
                expectEqual(
                    fixture.watcher.lastObservedFrontmostApplication?.bundleIdentifier,
                    "com.example.private",
                    "the hint follows the live app"
                )
                expect(
                    fixture.logs.messages.contains { $0.contains("com.example.private") },
                    "the skip names the excluded app"
                )
                expect(
                    !fixture.syncLog().contains(payload),
                    "the sync log never contains the payload"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a window of only non-excluded apps captures") {
        MainActor.assumeIsolated {
            do {
                let payload = "copied before switching to Safari 9e2f"
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.apple.TextEdit",
                        name: "TextEdit"
                    )
                )
                try fixture.enableSync()
                fixture.copy(payload)
                fixture.setFrontmost("com.apple.Safari", name: "Safari")
                fixture.poll()

                expectEqual(try fixture.entryCount(), 1, "a non-excluded window captures")
                expectEqual(
                    fixture.watcher.lastObservedFrontmostApplication?.bundleIdentifier,
                    "com.apple.Safari",
                    "the most recent app is attributed"
                )
                expectEqual(
                    FlavourDecoder.plainText(from: fixture.captures.entries.first?.flavours ?? []),
                    payload,
                    "the full content is recorded"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("CopyQmac itself frontmost still captures and keeps the Add Last App hint") {
        MainActor.assumeIsolated {
            do {
                let payload = "copied while CopyQmac was frontmost 3b7c"
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.apple.TextEdit",
                        name: "TextEdit"
                    )
                )
                try fixture.enableSync()
                fixture.setFrontmost("local.copyqmac.app", name: "CopyQmac")
                fixture.poll()
                fixture.copy(payload)
                fixture.poll()

                expectEqual(try fixture.entryCount(), 1, "our own window does not drop the clip")
                expectEqual(
                    FlavourDecoder.plainText(from: fixture.captures.entries.first?.flavours ?? []),
                    payload,
                    "the full content is recorded"
                )
                expectEqual(
                    fixture.watcher.lastObservedFrontmostApplication?.bundleIdentifier,
                    "com.apple.TextEdit",
                    "the hint keeps the last external app"
                )

                let model = AppModel(history: fixture.history)
                model.sourceApplicationProvider = { fixture.watcher.lastObservedFrontmostApplication }
                expectEqual(
                    model.observedSourceApplication?.bundleIdentifier,
                    "com.apple.TextEdit",
                    "the Add Last App hint is still available"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("content copied from elsewhere while CopyQmac is frontmost is captured") {
        MainActor.assumeIsolated {
            do {
                let payload = "helper snippet while the panel is open 4d9e"
                let fixture = try CaptureExclusionFixture(source: nil)
                try fixture.enableSync()
                fixture.setFrontmost("local.copyqmac.app", name: "CopyQmac")
                fixture.copy(payload)
                fixture.poll()

                expectEqual(try fixture.entryCount(), 1, "our own app is a known source")
                expectEqual(
                    FlavourDecoder.plainText(from: fixture.captures.entries.first?.flavours ?? []),
                    payload,
                    "the full content is recorded"
                )
                expectEqual(
                    fixture.watcher.unattributableSkipCount,
                    0,
                    "our own window is not unattributable"
                )
                expectEqual(try fixture.syncFiles().isEmpty, false, "the capture is written back")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a pending activation from an excluded app skips the capture") {
        MainActor.assumeIsolated {
            do {
                let payload = "secret with a pending activation 8f1a"
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.apple.TextEdit",
                        name: "TextEdit"
                    )
                )
                try fixture.enableSync()
                try fixture.setExclusions([
                    CaptureExclusionRule(
                        bundleIdentifier: "com.example.private",
                        name: "Example Private"
                    ),
                ])

                fixture.copy(payload)
                fixture.setFrontmost("com.apple.Safari", name: "Safari")
                // The poll is already queued when the user copies in the
                // ignored app and switches back, so the activation lands
                // after the poll block and before the deferred decision.
                DispatchQueue.main.async {
                    fixture.watcher.pollNow()
                }
                DispatchQueue.main.async {
                    fixture.watcher.noteActivation(
                        SourceApplication(
                            bundleIdentifier: "com.example.private",
                            name: "Example Private"
                        )
                    )
                }
                fixture.drainMainQueue()

                expectEqual(try fixture.entryCount(), 0, "the queued activation still skips")
                expectEqual(try fixture.syncFiles(), [], "no sync file is written")
                expectEqual(fixture.captures.entries.count, 0, "the capture callback never runs")
                expect(
                    fixture.logs.messages.contains { $0.contains("com.example.private") },
                    "the skip names the excluded app"
                )
                expect(
                    !fixture.logs.messages.contains { $0.contains(payload) },
                    "no log line contains the payload"
                )
                expect(
                    !fixture.syncLog().contains(payload),
                    "the sync log never contains the payload"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an app write before the deferred decision is not captured") {
        MainActor.assumeIsolated {
            do {
                let fixture = try CaptureExclusionFixture(
                    source: SourceApplication(
                        bundleIdentifier: "com.apple.TextEdit",
                        name: "TextEdit"
                    )
                )
                try fixture.enableSync()

                fixture.copy("user copy 2f8c")
                DispatchQueue.main.async {
                    fixture.copy("paste-back write 7e3d")
                    fixture.watcher.ignore(changeCount: fixture.pasteboard.changeCount)
                }
                fixture.poll()

                expectEqual(try fixture.entryCount(), 0, "a self-produced change is not recorded")
                expectEqual(try fixture.syncFiles(), [], "no sync file is written for our own write")
                expectEqual(fixture.captures.entries.count, 0, "the capture callback never runs")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a window with only a stale observation is unattributable") {
        let policy = CaptureExclusionPolicy(rules: [])
        let app = SourceApplication(bundleIdentifier: "com.apple.Safari", name: "Safari")
        let now = Date()

        var staleWindow = CaptureWindow()
        staleWindow.note(app, at: now.addingTimeInterval(-10))
        expect(
            policy.decide(window: staleWindow, now: now).isUnattributable,
            "a gap with no fresh observation fails safe"
        )

        var freshWindow = CaptureWindow()
        freshWindow.note(app, at: now)
        let fresh = policy.decide(window: freshWindow, now: now)
        expect(!fresh.isUnattributable, "a fresh observation is attributable")
        expectEqual(fresh.application?.bundleIdentifier, "com.apple.Safari")
    }

    TestRunner.add("an empty window skips and increments the counter") {
        MainActor.assumeIsolated {
            do {
                let payload = "secret with an empty window 6c2d"
                let fixture = try CaptureExclusionFixture(source: nil)
                try fixture.enableSync()
                fixture.copy(payload)
                fixture.poll()

                expectEqual(try fixture.entryCount(), 0, "an empty window is not captured")
                expectEqual(try fixture.syncFiles(), [], "no sync file is written")
                expectEqual(fixture.watcher.unattributableSkipCount, 1, "the skip is counted")
                expect(
                    fixture.logs.messages.contains { $0.contains("could not be determined") },
                    "the skip names the empty window"
                )
                expect(
                    !fixture.logs.messages.contains { $0.contains(payload) },
                    "no log line contains the payload"
                )
                expect(
                    !fixture.syncLog().contains(payload),
                    "the sync log never contains the payload"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("adding the observed app and removing it updates preferences") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.sourceApplicationProvider = {
                    SourceApplication(bundleIdentifier: "com.example.other", name: "Other App")
                }

                expectEqual(model.observedSourceApplication?.name, "Other App")
                expect(!model.isCaptureExcluded(bundleIdentifier: "com.example.other"))
                expect(model.addObservedAppToCaptureExclusions())
                expect(model.isCaptureExcluded(bundleIdentifier: "com.example.other"))

                guard let added = model.preferences.captureExclusions.first(where: {
                    $0.id == "com.example.other"
                }) else {
                    TestRunner.fail("the observed app was not added")
                    return
                }
                expectEqual(added.name, "Other App")

                model.setCaptureExclusionEnabled(added, false)
                expect(!model.isCaptureExcluded(bundleIdentifier: "com.example.other"))

                model.removeCaptureExclusion(added)
                expect(
                    !model.preferences.captureExclusions.contains { $0.id == "com.example.other" },
                    "the custom rule is removed"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("sanitizing exclusions trims, deduplicates, and drops empty identifiers") {
        var preferences = Preferences.defaultValue
        preferences.captureExclusions = [
            CaptureExclusionRule(bundleIdentifier: " com.example.a ", name: " A ", isEnabled: false),
            CaptureExclusionRule(bundleIdentifier: "COM.EXAMPLE.A", name: "Duplicate", isEnabled: true),
            CaptureExclusionRule(bundleIdentifier: "   ", name: "Empty"),
        ]
        let sanitized = preferences.sanitized()
        expectEqual(sanitized.captureExclusions.count, 1)
        expectEqual(sanitized.captureExclusions.first?.bundleIdentifier, "com.example.a")
        expectEqual(sanitized.captureExclusions.first?.name, "A")
        expectEqual(sanitized.captureExclusions.first?.isEnabled, false)
    }
}
