// Localization and translation catalog tests.

import AppKit
import Foundation

@MainActor
private final class LocalizationWindowControllerStub: NSObject, WindowControllerProtocol {
    var isVisible = false
    func show() {}
    func hide() {}
}

func registerLocalizationTests() {
    TestRunner.currentSuite = "Localization"
    TestRunner.add("every catalog key carries a non-empty English and Simplified Chinese value") {
        for key in CatalogKey.allCases {
            expect(
                !key.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "key \(key.rawValue) must have non-empty English text"
            )
            expect(
                !key.simplifiedChinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "key \(key.rawValue) must have non-empty Simplified Chinese text"
            )
        }
    }

    TestRunner.add("both languages share exactly the same key set") {
        let allKeys = Set(CatalogKey.allCases.map(\.rawValue))
        let englishKeys = Set(CatalogKey.allCases.compactMap { key -> String? in
            key.english.isEmpty ? nil : key.rawValue
        })
        let chineseKeys = Set(CatalogKey.allCases.compactMap { key -> String? in
            key.simplifiedChinese.isEmpty ? nil : key.rawValue
        })

        expectEqual(englishKeys, allKeys, "English covers every catalog key")
        expectEqual(chineseKeys, allKeys, "Simplified Chinese covers every catalog key")
        expectEqual(englishKeys, chineseKeys, "Both languages share the exact same key set")

        // Chinese translations must not be accidental copies of English except for allowed brand names
        let brandKeys: Set<CatalogKey> = [.menuAppTitle]
        for key in CatalogKey.allCases where !brandKeys.contains(key) {
            expect(
                key.simplifiedChinese != key.english,
                "key \(key.rawValue) should have a distinct Simplified Chinese translation, not raw English"
            )
        }
    }

    TestRunner.add("switching language preference changes resolved string for menu, status bar, and settings") {
        var preferences = Preferences.defaultValue
        expectEqual(preferences.language, .english)

        // 1. Representative menu title
        let menuTitleEn = Localization.string(.menuFile, language: preferences.language)
        expectEqual(menuTitleEn, "File")

        // 2. Representative status-bar string
        let statusBarEn = Localization.string(.statusBarAccessibilityNotGranted, language: preferences.language)
        expectEqual(statusBarEn, "Accessibility permission not granted")
        let itemCountEn = Localization.itemCount(2, language: preferences.language)
        expectEqual(itemCountEn, "2 items")

        // 3. Representative settings label
        let settingsLabelEn = Localization.string(.settingsStoredItemsLabel, language: preferences.language)
        expectEqual(settingsLabelEn, "Stored items")

        // Switch to Simplified Chinese
        preferences.language = .simplifiedChinese

        // 1. Representative menu title changed
        let menuTitleZh = Localization.string(.menuFile, language: preferences.language)
        expectEqual(menuTitleZh, "文件")
        expect(menuTitleEn != menuTitleZh, "menu title changes when language changes")

        // 2. Representative status-bar string changed
        let statusBarZh = Localization.string(.statusBarAccessibilityNotGranted, language: preferences.language)
        expectEqual(statusBarZh, "辅助功能权限未授予")
        expect(statusBarEn != statusBarZh, "status bar text changes when language changes")
        let itemCountZh = Localization.itemCount(2, language: preferences.language)
        expectEqual(itemCountZh, "2 个条目")

        // 3. Representative settings label changed
        let settingsLabelZh = Localization.string(.settingsStoredItemsLabel, language: preferences.language)
        expectEqual(settingsLabelZh, "已存储条目")
        expect(settingsLabelEn != settingsLabelZh, "settings label changes when language changes")
    }

    TestRunner.add("main menu builds with the selected language") {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let history: ClipboardHistory
            do {
                history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
            } catch {
                TestRunner.fail("could not open in-memory store: \(error)")
                return
            }
            let actions = AppActions(
                model: AppModel(history: history, isAccessibilityTrusted: { true }),
                windowController: LocalizationWindowControllerStub(),
                presentPreferences: {}
            )

            // Default English build
            let englishMenu = MainMenuBuilder.build(actions: actions, language: .english)
            expectEqual(
                englishMenu.items.map(\.title),
                ["CopyQmac", "File", "Edit", "Item", "Tabs", "Help"]
            )
            let englishFile = englishMenu.items.first { $0.title == "File" }?.submenu
            expect(englishFile?.items.contains { $0.title == "New Tab" } == true)
            expect(englishFile?.items.contains { $0.title == "Pause Sync" } == true)

            // Simplified Chinese build
            let chineseMenu = MainMenuBuilder.build(actions: actions, language: .simplifiedChinese)
            expectEqual(
                chineseMenu.items.map(\.title),
                ["CopyQmac", "文件", "编辑", "条目", "标签页", "帮助"]
            )
            let chineseFile = chineseMenu.items.first { $0.title == "文件" }?.submenu
            expect(chineseFile?.items.contains { $0.title == "新建标签页" } == true)
            expect(chineseFile?.items.contains { $0.title == "暂停同步" } == true)
        }
    }

    TestRunner.add("status item menu and tooltip build with the selected language") {
        try MainActor.assumeIsolated {
            let history = try ClipboardHistory(store: ClipboardStore(inMemory: true))
            let actions = AppActions(
                model: AppModel(history: history, isAccessibilityTrusted: { true }),
                windowController: LocalizationWindowControllerStub(),
                presentPreferences: {}
            )

            let (enMenu, enShow, enPause) = StatusMenuBuilder.build(actions: actions, language: .english)
            expectEqual(enShow.title, "Show CopyQmac")
            expectEqual(enPause.title, "Pause Sync")
            expect(enMenu.items.contains { $0.title == "Quit CopyQmac" })

            let (zhMenu, zhShow, zhPause) = StatusMenuBuilder.build(actions: actions, language: .simplifiedChinese)
            expectEqual(zhShow.title, "显示 CopyQmac")
            expectEqual(zhPause.title, "暂停同步")
            expect(zhMenu.items.contains { $0.title == "退出 CopyQmac" })

            let enTooltip = Localization.statusItemTooltip(hotkey: "⌥V", language: .english)
            expectEqual(enTooltip, "CopyQmac clipboard history (⌥V)")
            let zhTooltip = Localization.statusItemTooltip(hotkey: "⌥V", language: .simplifiedChinese)
            expectEqual(zhTooltip, "CopyQmac 剪贴板历史 (⌥V)")
        }
    }

    TestRunner.add("language preference round-trips and defaults to English") {
        let store = try ClipboardStore(inMemory: true)
        var preferences = try store.preferences()
        expectEqual(preferences.language, .english)

        preferences.language = .simplifiedChinese
        try store.setPreferences(preferences)

        let reloaded = try store.preferences()
        expectEqual(reloaded.language, .simplifiedChinese)
        expectEqual(reloaded, preferences)

        // Decoding older JSON without language field defaults to English
        let json = #"{"defaultMaxItems":500,"hotKeyKeyCode":9,"hotKeyModifiers":2048}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.language, .english)
    }

    TestRunner.add("an unrecognized stored language keeps every other preference") {
        let json = #"{"defaultMaxItems":500,"hotKeyKeyCode":9,"hotKeyModifiers":2048,"searchAllTabs":true,"syncPaused":true,"language":"zh_CN"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.language, .english)
        expectEqual(decoded.defaultMaxItems, 500)
        expect(decoded.searchAllTabs)
        expect(decoded.syncPaused, "a paused tab must stay paused when the language is unknown")
    }

    TestRunner.add("language displays in its own script") {
        expectEqual(AppLanguage.english.displayName, "English")
        expectEqual(AppLanguage.simplifiedChinese.displayName, "简体中文")
    }

    TestRunner.add("rename-tab alert copy is localized in English and Simplified Chinese") {
        expectEqual(Localization.string(.alertRenameTabTitle, language: .english), "Rename Tab")
        expectEqual(Localization.string(.alertRenameTabPlaceholder, language: .english), "Tab name")
        expectEqual(Localization.string(.alertRenameTabConfirm, language: .english), "Rename")
        expectEqual(Localization.string(.alertRenameTabCancel, language: .english), "Cancel")
        expectEqual(Localization.string(.alertRenameTabMessage, language: .english), "Choose a name for this tab.")

        expectEqual(Localization.string(.alertRenameTabTitle, language: .simplifiedChinese), "重命名标签页")
        expectEqual(Localization.string(.alertRenameTabPlaceholder, language: .simplifiedChinese), "标签页名称")
        expectEqual(Localization.string(.alertRenameTabConfirm, language: .simplifiedChinese), "重命名")
        expectEqual(Localization.string(.alertRenameTabCancel, language: .simplifiedChinese), "取消")
        expectEqual(Localization.string(.alertRenameTabMessage, language: .simplifiedChinese), "为该标签页选取一个名称。")
    }

    TestRunner.add("launch-at-login failure and unavailable reasons are localized") {
        let enableError = "Could not enable launch at login: Service disabled"
        let disableError = "Could not disable launch at login: Operation not permitted"
        let unknownState = "macOS reported an unknown login-item state."
        let needsApproval = "Launch at login needs approval in System Settings \u{203A} General \u{203A} Login Items."

        expectEqual(Localization.runtimeMessage(enableError, language: .english), enableError)
        expectEqual(Localization.runtimeMessage(disableError, language: .english), disableError)
        expectEqual(Localization.runtimeMessage(unknownState, language: .english), unknownState)
        expectEqual(Localization.runtimeMessage(needsApproval, language: .english), needsApproval)

        expectEqual(
            Localization.runtimeMessage(enableError, language: .simplifiedChinese),
            "无法启用登录时启动：Service disabled"
        )
        expectEqual(
            Localization.runtimeMessage(disableError, language: .simplifiedChinese),
            "无法禁用登录时启动：Operation not permitted"
        )
        expectEqual(
            Localization.runtimeMessage(unknownState, language: .simplifiedChinese),
            "macOS 报告了未知的登录项状态。"
        )
        expectEqual(
            Localization.runtimeMessage(needsApproval, language: .simplifiedChinese),
            "登录时启动需要在“系统设置 › 通用 › 登录项”中批准。"
        )
    }

    TestRunner.add("status-bar failure records are localized in English and Simplified Chinese") {
        // 1. Accessibility permission notices
        let permEn = Localization.runtimeMessage(AccessibilityNoticePolicy.pasteNeedsPermission, language: .english)
        expectEqual(permEn, AccessibilityNoticePolicy.pasteNeedsPermission)
        let permZh = Localization.runtimeMessage(AccessibilityNoticePolicy.pasteNeedsPermission, language: .simplifiedChinese)
        expect(permZh.contains("已拷贝到剪贴板。CopyQmac 需要辅助功能权限才能自动粘贴。"))
        expect(permZh != permEn)

        let staleZh = Localization.runtimeMessage(AccessibilityNoticePolicy.pasteNeedsPermissionStaleGrant, language: .simplifiedChinese)
        expect(staleZh.contains("macOS 仍将此构建视为不受信任"))

        // 2. Focus and paste errors
        let focusZh = Localization.runtimeMessage(PasteService.focusFailedMessage, language: .simplifiedChinese)
        expectEqual(focusZh, "无法聚焦上一个应用程序。")

        let noPlainZh = Localization.runtimeMessage("Paste failed: " + PasteService.noPlainTextMessage, language: .simplifiedChinese)
        expectEqual(noPlainZh, "粘贴失败：该条目没有可作为纯文本粘贴的文本。")

        // 3. Dynamic error prefixes
        let readError = "Could not read history: Permission denied"
        expectEqual(
            Localization.runtimeMessage(readError, language: .simplifiedChinese),
            "无法读取历史记录：Permission denied"
        )

        let tabError = "That tab no longer exists."
        expectEqual(
            Localization.runtimeMessage(tabError, language: .simplifiedChinese),
            "该标签页已不存在。"
        )

        // 4. Paste failures keep the reason inside the prefix in Chinese too
        expectEqual(
            Localization.runtimeMessage("Paste failed: " + PasteService.noClipboardTextMessage, language: .simplifiedChinese),
            "粘贴失败：剪贴板没有可作为纯文本粘贴的文本。"
        )
        expectEqual(
            Localization.runtimeMessage("Paste failed: Could not activate the previous app.", language: .simplifiedChinese),
            "粘贴失败：无法激活上一个应用程序。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Paste failed: Could not activate the previous app or send the paste command.",
                language: .simplifiedChinese
            ),
            "粘贴失败：无法激活上一个应用程序或发送粘贴命令。"
        )

        // 5. Other failure prefixes that reach the status bar
        expectEqual(
            Localization.runtimeMessage("Could not delete the selected entries: busy", language: .simplifiedChinese),
            "无法删除所选条目：busy"
        )
        expectEqual(
            Localization.runtimeMessage("Saved the item, but could not update its sync folder: busy", language: .simplifiedChinese),
            "已保存条目，但无法更新其同步文件夹：busy"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Saved the item, but could not update its sync folder: Could not rewrite the item's files: disk full",
                language: .simplifiedChinese
            ),
            "已保存条目，但无法更新其同步文件夹：无法重写条目的文件：disk full"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not empty the sync trash: Refusing to empty an unsafe trash directory: /tmp/trash",
                language: .simplifiedChinese
            ),
            "无法清空同步废纸篓：拒绝清空不安全的废纸篓目录：/tmp/trash"
        )
        expectEqual(
            Localization.runtimeMessage("Refusing write: target directory is protected.", language: .simplifiedChinese),
            "拒绝写入：目标目录受保护。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Refusing write: target directory is protected: /tmp/sync",
                language: .simplifiedChinese
            ),
            "拒绝写入：目标目录受保护：/tmp/sync"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Target directory does not exist or is not a directory.",
                language: .simplifiedChinese
            ),
            "目标目录不存在或不是目录。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not move the extra sync group to the trash: disk full",
                language: .simplifiedChinese
            ),
            "无法将额外的同步文件组移至废纸篓：disk full"
        )
        expectEqual(
            Localization.runtimeMessage("Write-back failed: disk full", language: .simplifiedChinese),
            "写回失败：disk full"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Import failed: Not a .cpq archive or sync directory: /tmp/x.txt",
                language: .simplifiedChinese
            ),
            "导入失败：不是 .cpq 归档或同步文件夹：/tmp/x.txt"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Import failed: Skipped /tmp/f: multiple tabs claim this sync folder: 'A' (id 1), 'B' (id 2)",
                language: .simplifiedChinese
            ),
            "导入失败：已跳过 /tmp/f：多个标签页使用同一同步文件夹：'A' (id 1), 'B' (id 2)"
        )
        expectEqual(
            Localization.runtimeMessage("Backup failed: There is no tab 5 to export", language: .simplifiedChinese),
            "备份失败：没有可导出的标签页 5"
        )
        expectEqual(
            Localization.runtimeMessage("Backup failed: There are no tabs to export", language: .simplifiedChinese),
            "备份失败：没有可导出的标签页"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Backup failed: Refusing dry-run export into protected CopyQ or Syncthing directory: /tmp/sync",
                language: .simplifiedChinese
            ),
            "备份失败：拒绝将试运行导出写入受保护的 CopyQ 或 Syncthing 目录：/tmp/sync"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not compare the tab with its sync folder: The sync folder does not exist: /tmp/gone",
                language: .simplifiedChinese
            ),
            "无法将标签页与其同步文件夹进行对比：同步文件夹不存在：/tmp/gone"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not compare the tab with its sync folder: The tab with id 3 no longer exists.",
                language: .simplifiedChinese
            ),
            "无法将标签页与其同步文件夹进行对比：ID 为 3 的标签页已不存在。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not compare the tab with its sync folder: The tab \u{201C}Work\u{201D} has no sync folder configured.",
                language: .simplifiedChinese
            ),
            "无法将标签页与其同步文件夹进行对比：标签页“Work”未配置同步文件夹。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not compare the tab with its sync folder: Several tabs claim the sync folder /tmp/x: A, B. Fix the tab folders before comparing.",
                language: .simplifiedChinese
            ),
            "无法将标签页与其同步文件夹进行对比：多个标签页使用同一同步文件夹 /tmp/x：A, B。请先修正标签页的文件夹再进行对比。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not compare the tab with its sync folder: Could not read /tmp/x: Permission denied",
                language: .simplifiedChinese
            ),
            "无法将标签页与其同步文件夹进行对比：无法读取 /tmp/x：Permission denied"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not compare the tab with its sync folder: The tab's sync folder changed from /tmp/a to /tmp/b after the report. Compare the tab again before applying.",
                language: .simplifiedChinese
            ),
            "无法将标签页与其同步文件夹进行对比：标签页的同步文件夹在报告生成后从 /tmp/a 变为了 /tmp/b。请重新对比后再应用。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not resync the tab with its sync folder: Sync is paused, so \u{201C}Work\u{201D} cannot be resynced. Resume sync first.",
                language: .simplifiedChinese
            ),
            "无法重新同步标签页与其同步文件夹：同步已暂停，因此无法重新同步“Work”。请先恢复同步。"
        )
        expectEqual(
            Localization.runtimeMessage("Could not trim the destination tab: busy", language: .simplifiedChinese),
            "无法裁剪目标标签页：busy"
        )
        expectEqual(
            Localization.runtimeMessage(
                CopyQSyncRelocationError.syncUnavailable.errorDescription ?? "",
                language: .simplifiedChinese
            ),
            "同步已暂停。请先恢复同步，再将条目移出同步标签页。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "The destination sync folder is not available: /tmp/missing",
                language: .simplifiedChinese
            ),
            "目标同步文件夹不可用：/tmp/missing"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not move the items to \u{201C}Work\u{201D}: The destination tab no longer exists.",
                language: .simplifiedChinese
            ),
            "无法将条目移动到“Work”：目标标签页已不存在。"
        )

        // 6. Note-transition notices and the non-text edit reason
        expectEqual(
            Localization.runtimeMessage(
                "The entry being edited was removed by the current results; its note was saved.",
                language: .simplifiedChinese
            ),
            "正在编辑的条目已被当前结果移除；其备注已保存。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "The entry being edited was removed by the history limit; its draft could not be saved and remains available for retry: busy",
                language: .simplifiedChinese
            ),
            "正在编辑的条目已被历史记录上限移除；其草稿无法保存，仍可重试：busy"
        )
        let editingErrors: [EntryTextEditingError] = [
            .entryNotFound,
            .unsupportedKind,
            .multipleItems,
        ]
        for error in editingErrors {
            expectEqual(
                Localization.runtimeMessage(error.message, language: .english),
                error.message,
                "\(error) message must stay unchanged in English"
            )
            expect(
                Localization.runtimeMessage(error.message, language: .simplifiedChinese) != error.message,
                "\(error) message must translate to Chinese under 简体中文"
            )
        }

        expectEqual(
            Localization.runtimeMessage(EntryTextEditingError.entryNotFound.message, language: .simplifiedChinese),
            "该条目已不存在。"
        )
        expectEqual(
            Localization.runtimeMessage(EntryTextEditingError.unsupportedKind.message, language: .simplifiedChinese),
            "该条目显示的是图片或文件而不是文本。请添加备注进行说明。"
        )
        expectEqual(
            Localization.runtimeMessage(EntryTextEditingError.multipleItems.message, language: .simplifiedChinese),
            "该条目包含多个项目，无法作为样式文本编辑。"
        )
        expectEqual(
            Localization.runtimeMessage("Could not save the item: database is locked", language: .english),
            "Could not save the item: database is locked"
        )
        expectEqual(
            Localization.runtimeMessage("Could not save the item: database is locked", language: .simplifiedChinese),
            "无法保存条目：database is locked"
        )
    }

    TestRunner.add("the status-bar failure record follows the selected language") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()

                model.reportFailure("Paste failed: " + PasteService.noClipboardTextMessage)
                expectEqual(model.failureNotice, "Paste failed: The clipboard has no text to paste as plain text.")

                model.updatePreferences { $0.language = .simplifiedChinese }
                expectEqual(model.failureNotice, "粘贴失败：剪贴板没有可作为纯文本粘贴的文本。")

                model.reportFailure([
                    "Could not save the note; its draft remains available for retry: busy",
                    "Could not read history: denied",
                ])
                expectEqual(
                    model.failureNotice,
                    "无法保存备注；草稿仍可重试：busy 无法读取历史记录：denied"
                )

                model.updatePreferences { $0.language = .english }
                expectEqual(
                    model.failureNotice,
                    "Could not save the note; its draft remains available for retry: busy Could not read history: denied"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("status item accessibility description is localized in English and Simplified Chinese") {
        expectEqual(
            Localization.string(.statusItemAccessibilityDescription, language: .english),
            "Clipboard history"
        )
        expectEqual(
            Localization.string(.statusItemAccessibilityDescription, language: .simplifiedChinese),
            "剪贴板历史"
        )
    }

    TestRunner.add("the API-key guard's switch, hint, and notice carry both languages") {
        expectEqual(
            Localization.string(.settingsAPIKeyGuardToggle, language: .english),
            "Do not save AI service API keys copied on this Mac"
        )
        expectEqual(
            Localization.string(.settingsAPIKeyGuardToggle, language: .simplifiedChinese),
            "不保存在此 Mac 上复制的 AI 服务 API 密钥"
        )
        expectEqual(
            Localization.string(.settingsAPIKeyGuardDetail, language: .english),
            "Covers copies made here only: a key copied on this Mac is not saved, though it cannot promise that nothing ever does. Keys already in the history stay, copying and pasting still works, and items arriving through a sync folder are not filtered."
        )
        expectEqual(
            Localization.string(.settingsAPIKeyGuardDetail, language: .simplifiedChinese),
            "仅适用于在此 Mac 上进行的复制：在此复制的密钥不会被保存，但无法保证绝不遗漏。历史记录中已有的密钥会保留，复制和粘贴仍然照常可用，来自同步文件夹的条目不会被过滤。"
        )
        expectEqual(
            Localization.string(.statusItemAPIKeyNotSaved, language: .english),
            "API key not saved"
        )
        expectEqual(
            Localization.string(.statusItemAPIKeyNotSaved, language: .simplifiedChinese),
            "API 密钥未保存"
        )
        // The hint is the promise the switch makes, so it has to stay honest in
        // both languages: reduce, never guarantee.
        expect(
            Localization.string(.settingsAPIKeyGuardDetail, language: .english)
                .contains("cannot promise"),
            "the English hint says what it cannot promise"
        )
        expect(
            Localization.string(.settingsAPIKeyGuardDetail, language: .simplifiedChinese)
                .contains("无法保证"),
            "the Chinese hint says what it cannot promise"
        )
        // The guard only covers copies made here; the hint must not imply that
        // items arriving through a sync folder are filtered.
        expect(
            Localization.string(.settingsAPIKeyGuardDetail, language: .english)
                .contains("sync folder are not filtered"),
            "the English hint names the inbound sync limit"
        )
        expect(
            Localization.string(.settingsAPIKeyGuardDetail, language: .simplifiedChinese)
                .contains("同步文件夹"),
            "the Chinese hint names the inbound sync limit"
        )
        expect(
            !Localization.string(.settingsAPIKeyGuardDetail, language: .english)
                .contains("other devices"),
            "the English hint no longer promises coverage of what sync delivers"
        )
        expect(
            !Localization.string(.settingsAPIKeyGuardDetail, language: .simplifiedChinese)
                .contains("其他设备"),
            "the Chinese hint no longer promises coverage of what sync delivers"
        )
    }

    TestRunner.add("shortcut labels and headers translate key names but keep modifier glyphs") {
        guard let spacePreset = HotKeyShortcut.presets.first(where: { $0.keyCode == HotKeyKey.space }) else {
            TestRunner.fail("the space preset is missing")
            return
        }
        expectEqual(Localization.hotKeyLabel(spacePreset.label, language: .english), "⌘⇧Space")
        expectEqual(Localization.hotKeyLabel(spacePreset.label, language: .simplifiedChinese), "⌘⇧空格")
        expectEqual(
            Localization.format(
                .settingsSummonShortcutHeader,
                language: .english,
                Localization.hotKeyLabel(spacePreset.label, language: .english)
            ),
            "Summon shortcut: ⌘⇧Space"
        )
        expectEqual(
            Localization.format(
                .settingsSummonShortcutHeader,
                language: .simplifiedChinese,
                Localization.hotKeyLabel(spacePreset.label, language: .simplifiedChinese)
            ),
            "呼出快捷键：⌘⇧空格"
        )
        expectEqual(Localization.hotKeyLabel("⌥Key 42", language: .simplifiedChinese), "⌥键 42")
        expectEqual(Localization.hotKeyLabel("⌥Key 42", language: .english), "⌥Key 42")
        expectEqual(Localization.hotKeyLabel("⌥V", language: .simplifiedChinese), "⌥V")
    }

    TestRunner.add("file panels open with the selected language's title and prompt") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()
                let actions = AppActions(
                    model: model,
                    windowController: LocalizationWindowControllerStub(),
                    presentPreferences: {}
                )
                var presentedPanel: NSSavePanel?
                actions.panelPresenter = { panel, _ in presentedPanel = panel }

                actions.importFromCopyQ(nil)
                expectEqual(presentedPanel?.title, "Import from CopyQ")
                expectEqual(presentedPanel?.prompt, "Import")

                model.updatePreferences { $0.language = .simplifiedChinese }
                actions.importFromCopyQ(nil)
                expectEqual(presentedPanel?.title, "从 CopyQ 导入")
                expectEqual(presentedPanel?.prompt, "导入")

                actions.exportBackup(nil)
                expectEqual(presentedPanel?.title, "导出备份")
                expectEqual(presentedPanel?.message, "将所有标签页写入 CopyQ .cpq 归档。")

                model.updatePreferences { $0.language = .english }
                actions.exportBackup(nil)
                expectEqual(presentedPanel?.title, "Export Backup")
                expectEqual(presentedPanel?.message, "Write every tab to a CopyQ .cpq archive.")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the Clear Tab confirmation renders in the selected language with its file count") {
        MainActor.assumeIsolated {
            do {
                let root = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("copyq-clear-tab-language-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let sync = root.appendingPathComponent("sync", isDirectory: true)
                let trash = root.appendingPathComponent("trash", isDirectory: true)
                try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)

                let store = try ClipboardStore(inMemory: true)
                let tab = try store.insertTab(ClipboardTab(name: "Work", syncFolder: sync.path))
                var data = CopyQDataMap()
                data.set(CopyQFormat.text, Data("kept in sync".utf8))
                data.set(CopyQFormat.html, Data("<b>kept in sync</b>".utf8))
                try CopyQSyncFolder.write(
                    CopyQSyncItem(baseName: "copyq_20261025120000901", data: data),
                    into: sync.path
                )
                _ = try CopyQSyncBridge.importSyncFolder(atPath: sync.path, intoTabID: tab.id, in: store)

                let history = ClipboardHistory(store: store)
                history.syncTrashRoot = trash
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()
                model.selectTab(tab.id)
                let actions = AppActions(
                    model: model,
                    windowController: LocalizationWindowControllerStub(),
                    presentPreferences: {}
                )
                var captured: NSAlert?
                actions.alertPresenter = { alert in
                    captured = alert
                    return .alertSecondButtonReturn
                }

                actions.clearTab(nil)
                expectEqual(captured?.messageText, "Clear Tab")
                expectEqual(captured?.buttons.map(\.title), ["Clear Tab", "Cancel"])
                expect(
                    captured?.informativeText.contains("in \u{201C}\(sync.path)\u{201D} (2 files)") == true,
                    "the English dialog names the folder and its file count: \(captured?.informativeText ?? "")"
                )

                model.updatePreferences { $0.language = .simplifiedChinese }
                actions.clearTab(nil)
                expectEqual(captured?.messageText, "清空标签页")
                expectEqual(captured?.buttons.map(\.title), ["清空标签页", "取消"])
                expect(
                    captured?.informativeText.contains("“\(sync.path)”中的同步文件（2 个文件）") == true,
                    "the Chinese dialog names the folder and its file count: \(captured?.informativeText ?? "")"
                )
                expectEqual(try store.count(tabID: tab.id), 1, "cancelling keeps the entry")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the compare dialog and its report render in the selected language") {
        MainActor.assumeIsolated {
            do {
                let root = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("copyq-compare-dialog-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let sync = root.appendingPathComponent("sync", isDirectory: true)
                let trash = root.appendingPathComponent("trash", isDirectory: true)
                try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
                var data = CopyQDataMap()
                data.set(CopyQFormat.text, Data("orphan".utf8))
                try CopyQSyncFolder.write(
                    CopyQSyncItem(baseName: "copyq_20261025120000902", data: data),
                    into: sync.path
                )

                let unreadableStem = "copyq_20261025120000903"
                var stream = QDataStreamWriter()
                stream.writeInt32(-2)
                stream.writeInt32(1)
                stream.writeQString("0text/corrupt")
                stream.writeBool(true)
                stream.writeQByteArray(Data([0x78, 0x9C, 0x00]))
                let unreadableFileName = unreadableStem + CopyQFormat.dataFileSuffix
                try stream.data.write(to: sync.appendingPathComponent(unreadableFileName))

                let store = try ClipboardStore(inMemory: true)
                let tab = try store.insertTab(ClipboardTab(name: "Work", syncFolder: sync.path))
                let history = ClipboardHistory(store: store)
                history.syncTrashRoot = trash
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.reload()
                model.selectedTabID = tab.id
                model.reload()
                model.updatePreferences { $0.language = .simplifiedChinese }
                let actions = AppActions(
                    model: model,
                    windowController: LocalizationWindowControllerStub(),
                    presentPreferences: {}
                )
                var captured: NSAlert?
                actions.alertPresenter = { alert in
                    captured = alert
                    return .alertFirstButtonReturn
                }

                actions.resyncTab(id: tab.id)
                let deadline = Date().addingTimeInterval(5)
                while captured == nil, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }

                expectEqual(captured?.messageText, "将“Work”与其同步文件夹进行对比")
                expectEqual(captured?.buttons.map(\.title), ["好", "应用更改…"])
                let informative = captured?.informativeText ?? ""
                expect(
                    informative.contains("缺少条目的文件主名：1 个"),
                    "the report counts are translated: \(informative)"
                )
                expect(
                    informative.contains("文件夹：\(sync.path)"),
                    "the folder note is translated: \(informative)"
                )
                expect(
                    informative.contains("\(unreadableFileName)：格式 text/corrupt："),
                    "the read failure keeps the file name and translates the framing: \(informative)"
                )
                expect(
                    !informative.contains("flavour"),
                    "no English read-failure framing is left: \(informative)"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the help dialog renders in the selected language with a translated shortcut label") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()
                model.updatePreferences {
                    $0.language = .simplifiedChinese
                    $0.hotKeyDisplayLabel = "⌘⇧Space"
                }
                let actions = AppActions(
                    model: model,
                    windowController: LocalizationWindowControllerStub(),
                    presentPreferences: {}
                )
                var captured: NSAlert?
                actions.alertPresenter = { alert in
                    captured = alert
                    return .alertFirstButtonReturn
                }

                actions.showHelp(nil)
                expectEqual(captured?.messageText, "CopyQmac")
                expect(
                    captured?.informativeText.contains("⌘⇧空格 显示或隐藏此窗口") == true,
                    "the help body translates the shortcut and its explanation: \(captured?.informativeText ?? "")"
                )
                expectEqual(captured?.buttons.map(\.title), ["好"], "the help dialog's button is translated")

                model.updatePreferences { $0.language = .english }
                actions.showHelp(nil)
                expect(
                    captured?.informativeText.contains("⌘⇧Space shows and hides this window") == true,
                    "the English help keeps the stored label: \(captured?.informativeText ?? "")"
                )
                expectEqual(captured?.buttons.map(\.title), ["OK"], "the English help button is unchanged")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("relative time wording follows the language setting for all intervals") {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // English
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-2), now: now, calendar: calendar, language: .english), "just now")
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-30), now: now, calendar: calendar, language: .english), "30 s ago")
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-180), now: now, calendar: calendar, language: .english), "3 min ago")
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-7200), now: now, calendar: calendar, language: .english), "2 h ago")
        let yesterday = now.addingTimeInterval(-90_000)
        expectEqual(RelativeTime.describe(yesterday, now: now, calendar: calendar, language: .english), "Yesterday")

        // Simplified Chinese
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-2), now: now, calendar: calendar, language: .simplifiedChinese), "刚刚")
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-30), now: now, calendar: calendar, language: .simplifiedChinese), "30 秒前")
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-180), now: now, calendar: calendar, language: .simplifiedChinese), "3 分钟前")
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-7200), now: now, calendar: calendar, language: .simplifiedChinese), "2 小时前")
        expectEqual(RelativeTime.describe(yesterday, now: now, calendar: calendar, language: .simplifiedChinese), "昨天")

        // Older entries fallback to localized date
        let oldSameYear = now.addingTimeInterval(-60 * 86_400)
        let enDate = RelativeTime.describe(oldSameYear, now: now, calendar: calendar, language: .english)
        let zhDate = RelativeTime.describe(oldSameYear, now: now, calendar: calendar, language: .simplifiedChinese)
        expect(!enDate.isEmpty && !zhDate.isEmpty)
        expect(enDate != zhDate, "older date is localized by language")
        expect(zhDate.contains("月") && zhDate.contains("日"), "Chinese date format contains 月 and 日: \(zhDate)")

        let oldDifferentYear = now.addingTimeInterval(-400 * 86_400)
        let zhDiffYear = RelativeTime.describe(oldDifferentYear, now: now, calendar: calendar, language: .simplifiedChinese)
        expect(zhDiffYear.contains("年") && zhDiffYear.contains("月") && zhDiffYear.contains("日"), "Chinese date with year contains 年, 月, and 日: \(zhDiffYear)")
    }

    TestRunner.add("language switch updates existing rows' relative timestamps immediately") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()

                let now = Date()
                let first = now.addingTimeInterval(-200)
                let second = now.addingTimeInterval(-1800)
                let third = now.addingTimeInterval(-3000)
                guard case .inserted(let entry1) = try history.record([Fixtures.text("first")], at: first),
                      case .inserted(let entry2) = try history.record([Fixtures.text("second")], at: second),
                      case .inserted(let entry3) = try history.record([Fixtures.text("third")], at: third)
                else {
                    TestRunner.fail("failed to record entries")
                    return
                }
                let calendar = Calendar.current
                func expected(_ date: Date, _ language: AppLanguage) -> String {
                    RelativeTime.describe(date, now: Date(), calendar: calendar, language: language)
                }
                model.reload()
                model.ensureRowContent(for: entry1.id)
                model.ensureRowContent(for: entry2.id)
                model.ensureRowContent(for: entry3.id)
                let deadline = Date().addingTimeInterval(5)
                while (model.rows.contains(where: { $0.relativeTime.isEmpty }) || model.rows.count < 3) && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }

                expectEqual(model.rows.count, 3)
                let row1En = model.rows.first(where: { $0.id == entry1.id })?.relativeTime
                let row2En = model.rows.first(where: { $0.id == entry2.id })?.relativeTime
                let row3En = model.rows.first(where: { $0.id == entry3.id })?.relativeTime
                expectEqual(row1En, expected(first, .english))
                expectEqual(row2En, expected(second, .english))
                expectEqual(row3En, expected(third, .english))

                // Switch to Simplified Chinese
                model.updatePreferences { $0.language = .simplifiedChinese }

                // Rows should update immediately without waiting for a timer tick
                let row1Zh = model.rows.first(where: { $0.id == entry1.id })?.relativeTime
                let row2Zh = model.rows.first(where: { $0.id == entry2.id })?.relativeTime
                let row3Zh = model.rows.first(where: { $0.id == entry3.id })?.relativeTime
                expectEqual(row1Zh, expected(first, .simplifiedChinese))
                expectEqual(row2Zh, expected(second, .simplifiedChinese))
                expectEqual(row3Zh, expected(third, .simplifiedChinese))

                // Switch back to English
                model.updatePreferences { $0.language = .english }
                let row1Back = model.rows.first(where: { $0.id == entry1.id })?.relativeTime
                let row2Back = model.rows.first(where: { $0.id == entry2.id })?.relativeTime
                let row3Back = model.rows.first(where: { $0.id == entry3.id })?.relativeTime
                expectEqual(row1Back, expected(first, .english))
                expectEqual(row2Back, expected(second, .english))
                expectEqual(row3Back, expected(third, .english))
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a stored Chinese preference localizes row timestamps on launch") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                var storedPreferences = Preferences.defaultValue
                storedPreferences.language = .simplifiedChinese
                try store.setPreferences(storedPreferences)

                let history = ClipboardHistory(store: store)
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()

                let createdAt = Date().addingTimeInterval(-3000)
                guard case .inserted(let entry) = try history.record([Fixtures.text("stored language")], at: createdAt) else {
                    TestRunner.fail("failed to record entry")
                    return
                }
                model.reload()
                model.ensureRowContent(for: entry.id)
                let deadline = Date().addingTimeInterval(5)
                while (model.rows.isEmpty || model.rows.contains(where: { $0.relativeTime.isEmpty })) && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }

                let row = model.rows.first(where: { $0.id == entry.id })?.relativeTime
                expectEqual(
                    row,
                    RelativeTime.describe(createdAt, now: Date(), calendar: .current, language: .simplifiedChinese)
                )
                expect(
                    row?.hasSuffix("分钟前") == true,
                    "the launched row uses the stored Chinese wording: \(row ?? "nil")"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("rows materialized after a language switch use the new language") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()

                let now = Date()
                let visibleAtSwitch = now.addingTimeInterval(-600)
                let scrolledInLater = now.addingTimeInterval(-300)
                guard case .inserted(let earlier) = try history.record([Fixtures.text("listed before the switch")], at: visibleAtSwitch),
                      case .inserted(let later) = try history.record([Fixtures.text("listed after the switch")], at: scrolledInLater)
                else {
                    TestRunner.fail("failed to record entries")
                    return
                }

                // Only the top row is materialized before the switch, like a row
                // that was on screen in an English window.
                model.reload()
                model.ensureRowContent(for: earlier.id)
                let firstDeadline = Date().addingTimeInterval(5)
                while (model.rows.first(where: { $0.id == earlier.id })?.relativeTime.isEmpty ?? true) && Date() < firstDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                expectEqual(
                    model.rows.first(where: { $0.id == earlier.id })?.relativeTime,
                    RelativeTime.describe(visibleAtSwitch, now: Date(), language: .english)
                )

                model.updatePreferences { $0.language = .simplifiedChinese }

                // Scrolling down materializes a row whose content was never built
                // before the switch; it must not come back in English.
                model.ensureRowContent(for: later.id)
                let secondDeadline = Date().addingTimeInterval(5)
                while (model.rows.first(where: { $0.id == later.id })?.relativeTime.isEmpty ?? true) && Date() < secondDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                let laterRow = model.rows.first(where: { $0.id == later.id })?.relativeTime
                expectEqual(
                    laterRow,
                    RelativeTime.describe(scrolledInLater, now: Date(), calendar: .current, language: .simplifiedChinese)
                )
                expect(
                    laterRow?.hasSuffix("分钟前") == true,
                    "a row built after the switch uses the Chinese wording: \(laterRow ?? "nil")"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the main window's own surfaces carry both languages") {
        let mainWindowKeys: [CatalogKey] = [
            .tabBarNewTabHelp, .tabChipCaptureHelp, .tabContextMoveLeft,
            .tabContextMoveRight, .tabContextMoveUp, .tabContextMoveDown,
            .tabContextCompareSyncFolder,
            .filterItemsPlaceholder, .filterClearHelp, .filterAllTabsToggle,
            .filterSearchAllTabsHelp, .emptyStateNoItems, .emptyStateNoMatches,
            .emptyStateCreateItem, .rowNoteBadge, .rowPinnedHelp, .rowDeleteHelp,
            .rowNoPreview, .rowMoreFiles, .contextCopyToClipboard,
            .previewImageUnavailable, .previewSelectPrompt, .previewNoteLabel,
            .textEditTitleEdit, .textEditTitleNew, .textEditNewDetail,
            .textEditConfirmSave, .textEditConfirmAdd, .textEditEmptyWarning,
            .textEditRichFormatError, .textEditPreviewFallbackHint,
            .textEditFormattingFallbackHint, .richToolbarBold, .richToolbarItalic,
            .richToolbarUnderline, .richToolbarTextColour,
            .richToolbarDefaultColour, .richToolbarSize, .richToolbarTextSize,
        ]

        // Every main-window key must render a distinct Simplified Chinese
        // value; the completeness check above covers every key in the catalog.
        for key in mainWindowKeys {
            expect(
                !key.simplifiedChinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "key \(key.rawValue) must have non-empty Simplified Chinese text"
            )
            expect(
                key.simplifiedChinese != key.english,
                "key \(key.rawValue) must not fall back to its English text"
            )
        }

        expectEqual(Localization.string(.filterItemsPlaceholder, language: .english), "Filter items")
        expectEqual(Localization.string(.filterItemsPlaceholder, language: .simplifiedChinese), "筛选条目")
        expectEqual(Localization.string(.filterClearHelp, language: .english), "Clear filter")
        expectEqual(Localization.string(.filterClearHelp, language: .simplifiedChinese), "清除筛选")
        expectEqual(Localization.string(.filterAllTabsToggle, language: .english), "All tabs")
        expectEqual(Localization.string(.filterAllTabsToggle, language: .simplifiedChinese), "所有标签页")
        expectEqual(Localization.string(.emptyStateNoItems, language: .english), "No items in this tab yet")
        expectEqual(Localization.string(.emptyStateNoItems, language: .simplifiedChinese), "此标签页尚无条目")
        expectEqual(Localization.string(.previewSelectPrompt, language: .english), "Select an item to preview it")
        expectEqual(Localization.string(.previewSelectPrompt, language: .simplifiedChinese), "选择条目以预览")
        expectEqual(Localization.string(.previewNoteLabel, language: .english), "Note")
        expectEqual(Localization.string(.previewNoteLabel, language: .simplifiedChinese), "备注")
        expectEqual(Localization.string(.rowNoteBadge, language: .english), "note")
        expectEqual(Localization.string(.rowNoteBadge, language: .simplifiedChinese), "备注")
        expectEqual(Localization.string(.rowPinnedHelp, language: .english), "Pinned")
        expectEqual(Localization.string(.rowPinnedHelp, language: .simplifiedChinese), "已固定")
        expectEqual(Localization.contentKindLabel(.text, language: .english), "text")
        expectEqual(Localization.contentKindLabel(.text, language: .simplifiedChinese), "文本")
        expectEqual(Localization.contentKindLabel(.html, language: .english), "HTML")
        expectEqual(Localization.contentKindLabel(.html, language: .simplifiedChinese), "网页")
        expectEqual(Localization.contentKindLabel(.rtf, language: .simplifiedChinese), "富文本")
        expectEqual(Localization.contentKindLabel(.image, language: .simplifiedChinese), "图像")
        expectEqual(Localization.contentKindLabel(.files, language: .simplifiedChinese), "文件")
        expectEqual(Localization.contentKindLabel(.other, language: .simplifiedChinese), "其他")
        expectEqual(Localization.string(.textEditEmptyWarning, language: .english), "Enter some text to save.")
        expectEqual(Localization.string(.textEditEmptyWarning, language: .simplifiedChinese), "请输入要保存的文本。")
        expectEqual(Localization.string(.buttonCancel, language: .english), "Cancel")
        expectEqual(Localization.string(.buttonCancel, language: .simplifiedChinese), "取消")
        expectEqual(Localization.string(.richToolbarTextSize, language: .english), "Text size")
        expectEqual(Localization.string(.richToolbarTextSize, language: .simplifiedChinese), "文字大小")
    }

    TestRunner.add("the text edit sheet's own text follows the selected language") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()
                model.updatePreferences { $0.language = .simplifiedChinese }

                let tabName = model.selectedTab?.name ?? ""
                model.requestNewItem()
                expectEqual(model.pendingTextEdit?.title(language: .simplifiedChinese), "新建条目")
                expectEqual(
                    model.pendingTextEdit?.detailText(language: .simplifiedChinese),
                    "将新条目添加到“\(tabName)”标签页。"
                )
                expectEqual(model.pendingTextEdit?.confirmTitle(language: .simplifiedChinese), "添加")
                model.updatePreferences { $0.language = .english }
                expectEqual(model.pendingTextEdit?.title(language: .english), "New Item")
                expectEqual(
                    model.pendingTextEdit?.detailText(language: .english),
                    "Adds a new item to the \u{201C}\(tabName)\u{201D} tab."
                )
                expectEqual(model.pendingTextEdit?.confirmTitle(language: .english), "Add")
                model.cancelTextEdit()
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the row context menu renders in the selected language") {
        MainActor.assumeIsolated {
            let row = EntryRow(
                id: 42,
                number: 1,
                kind: .text,
                primaryText: "hello",
                richText: nil,
                fileNames: [],
                fileCount: 0,
                relativeTime: "now",
                pinned: false,
                hasNote: false,
                icon: nil
            )
            let selection = SelectionState()
            let list = EntryListView(
                rows: [row],
                rowsRevision: 1,
                selection: selection,
                singleClickActivates: false,
                language: .simplifiedChinese,
                actions: .none,
                contextActions: EntryContextActions(
                    newItem: {},
                    editItem: { _ in },
                    editItemAvailability: { _ in
                        EditItemAvailability(isEnabled: true, title: "")
                    },
                    canCreateNewItem: { true },
                    removeSelection: {}
                ),
                onSelectionChange: { _ in },
                onActivate: { _ in },
                onCopy: { _ in },
                onFocusChange: { _ in },
                onRowBecameVisible: { _ in },
                banner: nil,
                onBannerAction: {},
                onBannerDismiss: {}
            )
            let coordinator = list.makeCoordinator()

            expectEqual(
                coordinator.contextMenu(for: 0)?.items.map(\.title),
                [
                    "新建条目\u{2026}",
                    "编辑条目\u{2026}",
                    "",
                    "激活",
                    "复制到剪贴板",
                    "",
                    "固定",
                    "移除",
                ],
                "the row context menu is translated"
            )

            selection.set(ids: [42], focus: 42)
            expectEqual(
                coordinator.emptyAreaContextMenu()?.items.map(\.title),
                ["新建条目\u{2026}"],
                "the empty-area menu is translated"
            )
        }
    }

    TestRunner.add("every kept-conflict reason translates inside a resync diagnostic") {
        for reason in CopyQSyncResyncConflictReason.allCases {
            let message = "Kept copyq_1: \(reason.description)."
            expectEqual(
                Localization.runtimeMessage(message, language: .simplifiedChinese),
                "保留了 copyq_1：\(reason.description(language: .simplifiedChinese))。",
                "\(reason.rawValue) must keep its stem and translate its reason"
            )
        }
    }

    TestRunner.add("a language switch repaints the rows already on screen") {
        MainActor.assumeIsolated {
            let row = EntryRow(
                id: 42,
                number: 1,
                kind: .text,
                primaryText: "hello",
                richText: nil,
                fileNames: [],
                fileCount: 0,
                relativeTime: "now",
                pinned: false,
                hasNote: true,
                icon: nil
            )
            let selection = SelectionState()
            func list(_ language: AppLanguage) -> EntryListView {
                EntryListView(
                    rows: [row],
                    rowsRevision: 1,
                    selection: selection,
                    singleClickActivates: false,
                    language: language,
                    actions: .none,
                    contextActions: .none,
                    onSelectionChange: { _ in },
                    onActivate: { _ in },
                    onCopy: { _ in },
                    onFocusChange: { _ in },
                    onRowBecameVisible: { _ in },
                    banner: nil,
                    onBannerAction: {},
                    onBannerDismiss: {}
                )
            }
            let coordinator = list(.english).makeCoordinator()
            let tableView = EntryListView.makeTableView(coordinator: coordinator)
            // Fixed row heights keep every rendering the same size, so the
            // comparison only sees what the row draws.
            tableView.usesAutomaticRowHeights = false
            tableView.rowHeight = 60
            tableView.tableColumns.first?.width = 300
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 120))
            scrollView.documentView = tableView
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            window.layoutIfNeeded()
            guard window.contentView === scrollView else {
                print("SKIP: could not create a window for the row repaint test")
                return
            }
            coordinator.attach(to: tableView)
            coordinator.applyRows()

            func settle() {
                let deadline = Date().addingTimeInterval(0.3)
                while Date() < deadline {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                scrollView.layoutSubtreeIfNeeded()
                tableView.layoutSubtreeIfNeeded()
            }
            func paintedRow() -> UInt64? {
                guard let cell = tableView.view(atColumn: 0, row: 0, makeIfNecessary: false) else {
                    return nil
                }
                let bounds = cell.bounds
                guard bounds.width > 0, bounds.height > 0,
                      let representation = cell.bitmapImageRepForCachingDisplay(in: bounds)
                else { return nil }
                cell.cacheDisplay(in: bounds, to: representation)
                guard let data = representation.bitmapData else { return nil }
                var hash: UInt64 = 1469598103934665603
                for index in 0..<(representation.bytesPerRow * representation.pixelsHigh) {
                    hash = (hash ^ UInt64(data[index])) &* 1099511628211
                }
                return hash
            }

            settle()
            guard let english = paintedRow() else {
                TestRunner.fail("the table did not draw its row")
                window.close()
                return
            }

            coordinator.parent = list(.simplifiedChinese)
            coordinator.applyRows()
            settle()
            guard let chinese = paintedRow() else {
                TestRunner.fail("the table did not draw its row")
                window.close()
                return
            }
            expect(
                chinese != english,
                "the row kept its English drawing after the language switch"
            )

            coordinator.parent = list(.english)
            coordinator.applyRows()
            settle()
            expectEqual(paintedRow(), english, "the row returns to its English drawing")
            window.close()
        }
    }

    TestRunner.add("report summaries and notice messages localize their prose and keep their data") {
        // Import report: counts, tab names, and the clause separators.
        let importReport = CopyQImportReport(
            importedCount: 2,
            updatedCount: 1,
            duplicateCount: 1,
            importedTabs: ["Work"]
        )
        expectEqual(
            importReport.summary(language: .english),
            "2 imported, 1 updated, 1 skipped as duplicate, into [Work]"
        )
        expectEqual(
            importReport.summary(language: .simplifiedChinese),
            "已导入 2 个，已更新 1 个，已跳过 1 个重复项，导入至 [Work]"
        )
        expectEqual(importReport.summary, importReport.summary(language: .english))

        // Marker cleanup: one line per tab and the total.
        let markerReport = InternalMarkerCleanupReport(tabs: [
            .init(tabID: 1, tabName: "Work", singleMarkerCount: 2, otherPayloadlessCount: 1),
        ])
        expectEqual(
            markerReport.summary(language: .english),
            "Work: 3 (2 single-marker, 1 other payload-less)\nTotal: 3 entries deleted (2 single-marker, 1 other payload-less)."
        )
        expectEqual(
            markerReport.summary(language: .simplifiedChinese),
            "Work：3 个（2 个单标记，1 个其他无内容）\n总计：已删除 3 个条目（2 个单标记，1 个其他无内容）。"
        )

        // Move report.
        var relocation = CopyQSyncRelocationReport()
        relocation.movedEntryCount = 1
        relocation.movedGroupCount = 2
        relocation.trashedGroupCount = 1
        expectEqual(
            relocation.summary(language: .english),
            "Moved the item to the tab and moved 2 sync file groups, moved 1 file group to the app trash."
        )
        expectEqual(
            relocation.summary(language: .simplifiedChinese),
            "已将条目移动到标签页，并移动了 2 个同步文件组，将 1 个文件组移至应用废纸篓。"
        )

        // Reconcile and resync results.
        let reconcile = CopyQSyncReconciliationResult(entriesRemoved: 1, groupsImported: 2)
        expectEqual(
            reconcile.summary(language: .english),
            "1 missing-file entry moved to trash, 2 orphan file groups imported."
        )
        expectEqual(
            reconcile.summary(language: .simplifiedChinese),
            "1 个缺少文件的条目已移至废纸篓，已导入 2 个孤立文件组。"
        )

        let resync = CopyQSyncResyncResult(
            entriesImported: 1,
            entriesLinked: 0,
            entriesRemoved: 2,
            entriesUpdated: 1,
            conflictsLeft: 1,
            failures: ["Skipped copyq_1: the entry no longer exists."]
        )
        expectEqual(
            resync.summary(language: .english),
            "Imported 1 entry, linked 0 existing, removed 2 (archived to the app trash), updated 1, left 1 conflict untouched, 1 skipped."
        )
        expectEqual(
            resync.summary(language: .simplifiedChinese),
            "已导入 1 个条目，关联了 0 个现有条目，移除了 2 个（已归档到应用废纸篓），更新了 1 个，保留了 1 个冲突未处理，已跳过 1 个。"
        )

        // Backup report and watcher scan report.
        let export = CopyQSyncBridge.ExportReport(
            path: "/tmp/backup.cpq",
            tabNames: ["Work"],
            itemCount: 3,
            byteCount: 1024
        )
        expect(
            export.summary(language: .english).hasPrefix("1 tab, 3 items,"),
            "the English backup summary keeps its wording: \(export.summary(language: .english))"
        )
        expect(
            export.summary(language: .simplifiedChinese).hasPrefix("1 个标签页，3 个条目，"),
            "the Chinese backup summary translates the counts: \(export.summary(language: .simplifiedChinese))"
        )
        expect(
            export.summary(language: .simplifiedChinese).contains("该归档将同步到您的其他设备") == false,
            "a local backup is not described as syncing"
        )

        let smallExport = CopyQSyncBridge.ExportReport(
            path: "/tmp/backup.cpq",
            tabNames: ["Work"],
            itemCount: 5,
            byteCount: 843
        )
        expect(
            smallExport.summary(language: .english).contains("843 bytes"),
            "the English backup summary keeps its byte unit: \(smallExport.summary(language: .english))"
        )
        let chineseSmallSummary = smallExport.summary(language: .simplifiedChinese)
        expect(
            chineseSmallSummary.contains("843\u{5B57}\u{8282}") || chineseSmallSummary.contains("843 \u{5B57}\u{8282}"),
            "the Chinese backup summary localizes the size unit: \(chineseSmallSummary)"
        )

        let renamedExport = CopyQSyncBridge.ExportReport(
            path: "/tmp/backup.cpq",
            tabNames: ["Work", "Work"],
            itemCount: 3,
            byteCount: 1024,
            renamedTabCount: 1
        )
        expect(
            renamedExport.summary(language: .english).contains(
                ", 1 duplicate tab name renamed. Captures with several pasteboard items"
            ),
            "the English backup keeps its comma before the renamed clause: \(renamedExport.summary(language: .english))"
        )
        expect(
            renamedExport.summary(language: .simplifiedChinese).contains(
                "，1 个重名标签页已重命名。包含多个剪贴板项目的捕获"
            ),
            "the Chinese backup uses its own clause and sentence separators: \(renamedExport.summary(language: .simplifiedChinese))"
        )

        let scan = CopyQWatcherScanReport(importedCount: 1, duplicateCount: 0)
        expectEqual(scan.summary(language: .english), "1 imported, 0 skipped as duplicates")
        expectEqual(scan.summary(language: .simplifiedChinese), "已导入 1 个，已跳过 0 个重复项")

        // Notice messages whose data stays verbatim.
        expectEqual(
            Localization.runtimeMessage("Saved; hidden by the current filter.", language: .simplifiedChinese),
            "已保存；被当前筛选隐藏。"
        )
        expectEqual(
            Localization.runtimeMessage("Importing CopyQ data\u{2026}", language: .simplifiedChinese),
            "正在导入 CopyQ 数据\u{2026}"
        )
        expectEqual(
            Localization.runtimeMessage("Importing /tmp/work\u{2026}", language: .simplifiedChinese),
            "正在导入 /tmp/work\u{2026}"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Copied to the clipboard. Open the target app and press \u{2318}V.",
                language: .simplifiedChinese
            ),
            "已复制到剪贴板。请打开目标应用并按 \u{2318}V。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Kept the local version of copyq_1 because it is newer than the upstream edit.",
                language: .simplifiedChinese
            ),
            "保留了 copyq_1 的本地版本，因为它比上游编辑更新。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Kept the local versions of copyq_1, copyq_2 because they are newer than the upstream edits.",
                language: .simplifiedChinese
            ),
            "保留了 copyq_1, copyq_2 的本地版本，因为它们比上游编辑更新。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Removed the entry for copyq_1 after it was deleted in the sync folder.",
                language: .simplifiedChinese
            ),
            "同步文件夹中的 copyq_1 已被删除，其对应条目也已移除。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Removed 2 entries after their files were deleted in sync folders.",
                language: .simplifiedChinese
            ),
            "已移除 2 个条目，因为它们的文件在同步文件夹中被删除。"
        )

        // Reader and resync diagnostics keep the file name and the system error.
        expectEqual(
            Localization.runtimeMessage("Could not import copyq_1: disk full", language: .simplifiedChinese),
            "无法导入 copyq_1：disk full"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not check copyq_1 for a pending local edit: Permission denied",
                language: .simplifiedChinese
            ),
            "无法检查 copyq_1 是否有待处理的本地编辑：Permission denied"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Kept copyq_1: the entry has a local edit that has not reached the folder.",
                language: .simplifiedChinese
            ),
            "保留了 copyq_1：该条目有尚未写入文件夹的本地编辑。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Kept Note: important: the entry has a local edit that has not reached the folder.",
                language: .simplifiedChinese
            ),
            "保留了 Note: important：该条目有尚未写入文件夹的本地编辑。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Kept the local version of Note: important because it is newer than the upstream edit.",
                language: .simplifiedChinese
            ),
            "保留了 Note: important 的本地版本，因为它比上游编辑更新。"
        )
        expectEqual(
            Localization.runtimeMessage("Skipped copyq_1: cannot read file", language: .simplifiedChinese),
            "已跳过 copyq_1：cannot read file"
        )

        // Emptied-trash notices.
        expectEqual(
            Localization.format(.noticeEmptiedTrashSingle, language: .english, 4),
            "Emptied the sync trash (1 batch, 4 files)."
        )
        expectEqual(
            Localization.format(.noticeEmptiedTrashSingle, language: .simplifiedChinese, 4),
            "已清空同步废纸篓（1 个批次，4 个文件）。"
        )
        expectEqual(
            Localization.format(.noticeEmptiedTrashPlural, language: .simplifiedChinese, 2, 4),
            "已清空同步废纸篓（2 个批次，4 个文件）。"
        )
    }
}
