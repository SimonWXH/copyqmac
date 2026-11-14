// The transient banner's lifetime and the Accessibility status-bar item.
//
// The regression these tests guard: the window's banner stayed on screen until
// the user dismissed it - a move summary hung over the tab strip - and the
// missing-permission explanation only existed as that banner. The banner now
// fades out on its own, a newer message replaces it instead of stacking a
// second timer, and the status bar carries the permission item while it is
// missing, taking over once the banner fades.

import AppKit
import Foundation

/// The banner timers a test drives itself: nothing here waits on the clock.
@MainActor
private final class ManualNoticeTimers: NoticeTimerScheduling {
    private var entries: [(delay: TimeInterval, fire: @MainActor () -> Void, timer: NoticeTimer)] = []

    var scheduledCount: Int { entries.count }

    /// The delays of the timers that would still fire, oldest first.
    var liveDelays: [TimeInterval] {
        entries.filter { !$0.timer.isCancelled }.map(\.delay)
    }

    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> NoticeTimer {
        let timer = NoticeTimer()
        entries.append((delay, fire, timer))
        return timer
    }

    /// Lets every pending message timer fire, the way the run loop eventually
    /// would. A timer that fired is spent, like the real one.
    func fireAll() {
        for entry in entries where !entry.timer.isCancelled {
            entry.timer.cancel()
            entry.fire()
        }
    }
}

@MainActor
private final class NoticeFixture {
    let model: AppModel
    let timers = ManualNoticeTimers()
    /// Everything the model sent to the app log, in order.
    private let log: () -> [String]

    init(trusted: Bool) throws {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        var logged: [String] = []
        let timers = self.timers
        let model = AppModel(
            history: history,
            isAccessibilityTrusted: { trusted },
            noticeTimers: timers,
            noticeLog: { logged.append($0) }
        )
        self.log = { logged }
        self.model = model
    }

    /// The log as it stands right now.
    var logEntries: [String] { log() }
}

func registerTransientNoticeTests() {
    // MARK: - Status-bar visibility

    TestRunner.add("the status-bar item is shown only while the permission is missing") {
        expectEqual(AccessibilityNoticePolicy.showsStatusItem(trusted: false, permissionBannerVisible: false), true)
        expectEqual(AccessibilityNoticePolicy.showsStatusItem(trusted: false, permissionBannerVisible: true), false)
        expectEqual(AccessibilityNoticePolicy.showsStatusItem(trusted: true, permissionBannerVisible: false), false)
        expectEqual(AccessibilityNoticePolicy.showsStatusItem(trusted: true, permissionBannerVisible: true), false)
    }

    TestRunner.add("a granted app shows no Accessibility text in the status bar") {
        MainActor.assumeIsolated {
            do {
                let fixture = try NoticeFixture(trusted: true)
                expectEqual(fixture.model.showsAccessibilityStatusItem, false)
                fixture.model.notice = AccessibilityNoticePolicy.pasteNeedsPermission
                expectEqual(
                    fixture.model.showsAccessibilityStatusItem,
                    false,
                    "a granted app must not show the Accessibility item, even beside a stale banner"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the permission banner hands over to the status-bar item once it fades") {
        MainActor.assumeIsolated {
            do {
                let fixture = try NoticeFixture(trusted: false)
                fixture.model.notice = AccessibilityNoticePolicy.pasteNeedsPermission
                expectEqual(
                    fixture.model.showsAccessibilityStatusItem,
                    false,
                    "the banner already explains the missing permission"
                )
                fixture.timers.fireAll()
                expectNil(fixture.model.notice, "the banner fades on its own")
                expectEqual(
                    fixture.model.showsAccessibilityStatusItem,
                    true,
                    "the status bar takes over after the banner fades"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an unrelated banner does not hide the status-bar item") {
        MainActor.assumeIsolated {
            do {
                let fixture = try NoticeFixture(trusted: false)
                fixture.model.notice = "Moved the item to the tab and moved 1 sync file group."
                expectEqual(
                    fixture.model.showsAccessibilityStatusItem,
                    true,
                    "only the permission banner duplicates the status-bar item"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - Failure notices

    TestRunner.add("a failure notice leaves a status-bar record and reaches the app log") {
        MainActor.assumeIsolated {
            do {
                let fixture = try NoticeFixture(trusted: true)
                fixture.model.reportFailure("Backup failed: disk is full")
                expectEqual(fixture.model.notice, "Backup failed: disk is full")
                expectEqual(fixture.model.failureNotice, "Backup failed: disk is full")
                expectEqual(fixture.logEntries, ["Backup failed: disk is full"])
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a failure record outlives the banner that announced it") {
        MainActor.assumeIsolated {
            do {
                let fixture = try NoticeFixture(trusted: true)
                fixture.model.reportFailure("Could not delete the entry: busy")
                expectEqual(
                    fixture.model.showsFailureStatusItem,
                    false,
                    "the banner already explains this failure"
                )
                fixture.timers.fireAll()
                expectNil(fixture.model.notice, "the banner faded")
                expectEqual(fixture.model.failureNotice, "Could not delete the entry: busy")
                expectEqual(
                    fixture.model.showsFailureStatusItem,
                    true,
                    "the record takes over once the banner is gone"
                )
                fixture.model.dismissFailureNotice()
                expectEqual(fixture.model.showsFailureStatusItem, false, "clicking the record clears it")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an informational notice leaves no status-bar record and no log entry") {
        MainActor.assumeIsolated {
            do {
                let fixture = try NoticeFixture(trusted: true)
                fixture.model.notice = "Backup written: 12 entries."
                expectNil(fixture.model.failureNotice, "a success is not a failure record")
                expectEqual(fixture.logEntries, [], "a success is not logged as a failure")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the status-bar record is hidden while its own banner is on screen") {
        MainActor.assumeIsolated {
            do {
                let fixture = try NoticeFixture(trusted: true)
                fixture.model.reportFailure("Could not delete the entry: busy")
                expectEqual(
                    fixture.model.showsFailureStatusItem,
                    false,
                    "the banner already explains this failure"
                )
                fixture.model.notice = "Backup written: 12 entries."
                expectEqual(
                    fixture.model.showsFailureStatusItem,
                    true,
                    "once another message replaced the banner the record takes over"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the failure record's visibility follows the banner that duplicates it") {
        expectEqual(NoticeStatusPolicy.showsFailureItem(failure: nil, banner: nil), false)
        expectEqual(NoticeStatusPolicy.showsFailureItem(failure: "x", banner: "x"), false)
        expectEqual(NoticeStatusPolicy.showsFailureItem(failure: "x", banner: "y"), true)
        expectEqual(NoticeStatusPolicy.showsFailureItem(failure: "x", banner: nil), true)
    }

    TestRunner.add("move, import, and sync write failures keep a record and reach the app log") {
        MainActor.assumeIsolated {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-notice-failures-\(UUID().uuidString)")
            let sourceFolder = root.appendingPathComponent("source")
            let blockedFolder = root.appendingPathComponent("missing")
            let writableFolder = root.appendingPathComponent("destination")
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: writableFolder.path
                )
                try? FileManager.default.removeItem(at: root)
            }
            do {
                try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: writableFolder, withIntermediateDirectories: true)

                let store = try ClipboardStore(inMemory: true)
                var preferences = try store.preferences()
                preferences.syncPaused = false
                try store.setPreferences(preferences)

                let sourceTab = try store.insertTab(ClipboardTab(
                    name: "Source",
                    syncFolder: sourceFolder.path
                ))
                let blockedTab = try store.insertTab(ClipboardTab(
                    name: "Blocked",
                    syncFolder: blockedFolder.path
                ))
                let writableTab = try store.insertTab(ClipboardTab(
                    name: "Destination",
                    syncFolder: writableFolder.path
                ))

                let stem = "copyq_20261025220000123"
                try Data("moved".utf8).write(to: sourceFolder.appendingPathComponent("\(stem).txt"))
                let entry = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 1_000),
                    tabID: sourceTab.id,
                    flavours: [
                        Fixtures.text("moved"),
                        Flavour(
                            itemIndex: 0,
                            type: Fingerprint.syncBaseNameFlavour,
                            data: Data(stem.utf8)
                        ),
                    ]
                ))

                var logged: [String] = []
                let timers = ManualNoticeTimers()
                let history = ClipboardHistory(store: store)
                history.syncTrashRoot = root.appendingPathComponent("trash")
                let model = AppModel(
                    history: history,
                    isAccessibilityTrusted: { true },
                    noticeTimers: timers,
                    noticeLog: { logged.append($0) }
                )
                model.reload()
                model.selectTab(sourceTab.id)
                model.select(entry.id)

                model.moveSelection(toTabID: blockedTab.id)
                let blocked = model.failureNotice ?? ""
                expect(
                    blocked.contains("destination sync folder is not available"),
                    "the blocked move leaves a failure record"
                )
                expectEqual(logged.last, blocked, "the blocked move reaches the app log")
                timers.fireAll()
                expectNil(model.notice, "the blocked move's banner faded")
                expectEqual(model.showsFailureStatusItem, true, "the blocked move stays in the status bar")

                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o500],
                    ofItemAtPath: writableFolder.path
                )
                model.moveSelection(toTabID: writableTab.id)
                let writeFailure = model.failureNotice ?? ""
                expect(
                    writeFailure.hasPrefix("Could not move the items to"),
                    "the failed sync write leaves a failure record"
                )
                expectEqual(logged.last, writeFailure, "the failed sync write reaches the app log")
                timers.fireAll()
                expectNil(model.notice, "the failed sync write's banner faded")
                expectEqual(model.showsFailureStatusItem, true, "the failed sync write stays in the status bar")
                expectEqual(
                    try store.entry(id: entry.id)?.tabID,
                    sourceTab.id,
                    "a failed write leaves the row in its source tab"
                )

                model.importFromPath(root.appendingPathComponent("missing.cpq"))
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline,
                      model.failureNotice?.hasPrefix("Import failed:") != true
                {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                let importFailure = model.failureNotice ?? ""
                expect(
                    importFailure.hasPrefix("Import failed:"),
                    "the import failure leaves a failure record"
                )
                expectEqual(logged.last, importFailure, "the import failure reaches the app log")
                timers.fireAll()
                expectNil(model.notice, "the import failure's banner faded")
                expectEqual(model.showsFailureStatusItem, true, "the import failure stays in the status bar")

                model.updatePreferences { $0.language = .simplifiedChinese }
                let textFile = root.appendingPathComponent("ordinary.txt")
                try Data("not a sync item".utf8).write(to: textFile)
                model.importFromPath(textFile)
                let chineseDeadline = Date().addingTimeInterval(2)
                while Date() < chineseDeadline,
                      model.failureNotice?.contains("ordinary.txt") != true
                {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                let chineseImportFailure = model.failureNotice ?? ""
                expect(
                    chineseImportFailure.contains("不是 .cpq 归档或同步文件夹："),
                    "the typed import reason is translated: \(chineseImportFailure)"
                )
                expect(
                    chineseImportFailure.contains("ordinary.txt"),
                    "the translated reason keeps the chosen path: \(chineseImportFailure)"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a move whose trim fails records the summary and the failure together") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                var preferences = try store.preferences()
                preferences.defaultMaxItems = 1
                try store.setPreferences(preferences)

                let sourceTab = try store.insertTab(ClipboardTab(name: "Source"))
                let destinationTab = try store.insertTab(ClipboardTab(name: "Destination"))
                _ = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 100),
                    tabID: destinationTab.id,
                    flavours: [Fixtures.text("older one")]
                ))
                _ = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 101),
                    tabID: destinationTab.id,
                    flavours: [Fixtures.text("older two")]
                ))
                let moved = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 200),
                    tabID: sourceTab.id,
                    flavours: [Fixtures.text("moved")]
                ))

                var logged: [String] = []
                let history = ClipboardHistory(store: store)
                history.store.onEntriesWillBeDeleted = { _, _ in
                    throw CocoaError(.fileWriteUnknown)
                }
                let model = AppModel(
                    history: history,
                    isAccessibilityTrusted: { true },
                    noticeTimers: ManualNoticeTimers(),
                    noticeLog: { logged.append($0) }
                )
                model.bootstrap()
                model.selectTab(sourceTab.id)
                model.select(moved.id)
                model.moveSelection(toTabID: destinationTab.id)

                let record = model.failureNotice ?? ""
                expect(
                    record.contains("Moved the item to the tab"),
                    "the record still says what moved: \(record)"
                )
                expect(
                    record.contains("Could not trim the destination tab"),
                    "the record carries the trim failure: \(record)"
                )
                expectEqual(logged.last, record, "the combined record reaches the app log")
                expectEqual(model.notice, record, "the banner carries the combined record")
                expectEqual(
                    NoticeBannerContent(parts: model.noticeParts, language: .english).displayText,
                    record,
                    "the English banner renders the same clauses as the status bar"
                )

                history.store.onEntriesWillBeDeleted = nil
                model.updatePreferences { $0.language = .simplifiedChinese }
                let chineseRecord = model.failureNotice ?? ""
                expect(
                    chineseRecord.contains("无法裁剪目标标签页"),
                    "the status bar translates the trim clause: \(chineseRecord)"
                )
                expectEqual(
                    NoticeBannerContent(parts: model.noticeParts, language: .simplifiedChinese).displayText,
                    chineseRecord,
                    "the banner translates the same clauses as the status bar"
                )
                expectEqual(
                    try store.entry(id: moved.id)?.tabID,
                    destinationTab.id,
                    "the row moved even though the trim failed"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a note-draft save failure keeps the transition message in the record and log") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                var logged: [String] = []
                let timers = ManualNoticeTimers()
                let model = AppModel(
                    history: history,
                    isAccessibilityTrusted: { true },
                    noticeTimers: timers,
                    noticeLog: { logged.append($0) }
                )
                model.bootstrap()

                guard case .inserted(let entry) = try history.record(
                    [Fixtures.text("draft me")],
                    at: Date(timeIntervalSince1970: 1_000)
                ) else {
                    TestRunner.fail("the draft fixture was not inserted")
                    return
                }
                model.reload()
                model.select(entry.id)
                model.setNoteEditing(true)
                model.setNoteDraft("unsaved")

                try history.delete(entry.id)
                model.endNoteEditing()

                let message = model.failureNotice ?? ""
                expect(
                    message.contains("draft could not be saved"),
                    "the transition failure reaches the status-bar record"
                )
                expectEqual(logged.last, message, "the transition failure reaches the app log")
                timers.fireAll()
                expectNil(model.notice, "the transition banner fades")
                expectEqual(
                    model.showsFailureStatusItem,
                    true,
                    "the transition failure stays in the status bar"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a deferred note save failure replaces the claim that the note was saved") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                var logged: [String] = []
                let timers = ManualNoticeTimers()
                let model = AppModel(
                    history: history,
                    isAccessibilityTrusted: { true },
                    noticeTimers: timers,
                    noticeLog: { logged.append($0) }
                )
                model.bootstrap()

                guard case .inserted(let entry) = try history.record(
                    [Fixtures.text("preserved draft")],
                    at: Date(timeIntervalSince1970: 1_000)
                ) else {
                    TestRunner.fail("the draft fixture was not inserted")
                    return
                }
                model.reload()
                model.select(entry.id)
                model.setNoteEditing(true)
                model.setNoteDraft("unsaved")

                try history.delete(entry.id)
                model.reload()

                let message = model.failureNotice ?? ""
                expect(
                    message.contains("draft remains available for retry"),
                    "the deferred save failure reaches the status-bar record"
                )
                expect(
                    !message.contains("its note was saved"),
                    "the failure must not claim the note was saved"
                )
                expectEqual(
                    model.notice,
                    message,
                    "the banner repeats the failure instead of the false success"
                )
                expectEqual(logged.last, message, "the deferred save failure reaches the app log")
                timers.fireAll()
                expectNil(model.notice, "the failure banner fades")
                expectEqual(
                    model.showsFailureStatusItem,
                    true,
                    "the deferred save failure stays in the status bar"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - Banner timer

    TestRunner.add("a banner fades out on its own after its lifetime") {
        MainActor.assumeIsolated {
            do {
                let fixture = try NoticeFixture(trusted: true)
                fixture.model.notice = "Moved the item to the tab and moved 1 sync file group."
                expectEqual(fixture.timers.liveDelays, [NoticeTimer.standardDuration])
                fixture.timers.fireAll()
                expectNil(fixture.model.notice, "the banner must retire itself")
                expectEqual(fixture.timers.liveDelays, [], "nothing is left pending")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a new message replaces the pending timer instead of stacking") {
        MainActor.assumeIsolated {
            do {
                let fixture = try NoticeFixture(trusted: true)
                fixture.model.notice = "Import complete: 1 entry."
                fixture.model.notice = "Sync folders imported: 2 entries."
                expectEqual(
                    fixture.timers.liveDelays,
                    [NoticeTimer.standardDuration],
                    "only the newest message may have a pending dismissal"
                )
                expectEqual(fixture.timers.scheduledCount, 2, "the replacement was scheduled")
                fixture.timers.fireAll()
                expectNil(fixture.model.notice, "the replacement's own timer retires it")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("showing the same message again restarts its timer") {
        MainActor.assumeIsolated {
            do {
                let fixture = try NoticeFixture(trusted: true)
                fixture.model.notice = "Could not focus the previous app."
                fixture.model.notice = "Could not focus the previous app."
                expectEqual(
                    fixture.timers.liveDelays,
                    [NoticeTimer.standardDuration],
                    "the repeated message owns a fresh timer"
                )
                expectEqual(fixture.timers.scheduledCount, 2, "the timer was restarted, not skipped")
                expectEqual(fixture.model.notice, "Could not focus the previous app.")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the close control dismisses the banner and its timer immediately") {
        MainActor.assumeIsolated {
            do {
                let fixture = try NoticeFixture(trusted: true)
                fixture.model.notice = "Could not save the note."
                fixture.model.dismissNotice()
                expectNil(fixture.model.notice, "the close control retires the banner at once")
                expectEqual(fixture.timers.liveDelays, [], "no dismissal is left pending")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
