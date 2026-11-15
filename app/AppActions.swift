// Menu and toolbar command target.
//
// Keeping every `@objc` action in one object means the main menu, the status
// item menu, and validation all share the same behaviour.

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
protocol WindowControllerProtocol: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
}

@MainActor
final class AppActions: NSObject, NSMenuItemValidation {
    let model: AppModel
    private weak var windowController: WindowControllerProtocol?
    private let presentPreferences: () -> Void
    var firstResponderOverride: (() -> NSResponder?)?
    var alertPresenter: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    var panelPresenter: (NSSavePanel, @escaping (URL?) -> Void) -> Void = { panel, completion in
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    init(
        model: AppModel,
        windowController: WindowControllerProtocol?,
        presentPreferences: @escaping () -> Void
    ) {
        self.model = model
        self.windowController = windowController
        self.presentPreferences = presentPreferences
    }

    // MARK: - Responder chain helper

    /// Indicates whether a text control or note editor has keyboard focus, so
    /// editing actions defer to the focused view instead of mutating entries.
    var isTextControlFocused: Bool {
        if model.isEditingNote { return true }
        let responder = firstResponderOverride?() ?? NSApplication.shared.keyWindow?.firstResponder
        guard let responder else { return false }
        return responder is NSText || responder is NSTextView
    }

    /// Dispatches editing actions to the first responder when a text control is
    /// focused, preventing item actions (such as window closing or entry deletion).
    @discardableResult
    private func deferToFirstResponder(action: Selector, fallbackActions: [Selector] = [], sender: Any?) -> Bool {
        guard isTextControlFocused else { return false }
        let target = firstResponderOverride?() ?? NSApplication.shared.keyWindow?.firstResponder
        if dispatchAction(action, to: target, sender: sender) {
            return true
        }
        for fallback in fallbackActions {
            if dispatchAction(fallback, to: target, sender: sender) {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func dispatchAction(_ action: Selector, to responder: NSResponder?, sender: Any?) -> Bool {
        var current = responder
        while let target = current {
            if target.responds(to: action) {
                _ = (target as AnyObject).perform(action, with: sender)
                return true
            }
            current = target.nextResponder
        }
        return false
    }

    // MARK: - Application

    @objc func showPreferencesAction(_ sender: Any?) { presentPreferences() }
    @objc func showMainWindow(_ sender: Any?) { windowController?.show() }
    @objc func hideWindow(_ sender: Any?) { windowController?.hide() }

    // MARK: - File

    @objc func newTab(_ sender: Any?) {
        model.addTab(named: "Tab \(model.tabs.count + 1)")
    }

    @objc func importFromCopyQ(_ sender: Any?) {
        let language = model.preferences.language
        let panel = NSOpenPanel()
        panel.title = Localization.string(.filePanelImportCopyQTitle, language: language)
        panel.prompt = Localization.string(.filePanelImportPrompt, language: language)
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        panelPresenter(panel) { [weak self] url in
            guard let url else { return }
            Task { @MainActor [weak self] in
                self?.model.importFromPath(url)
            }
        }
    }

    @objc func importConfiguredSyncFolders(_ sender: Any?) {
        model.importConfiguredSyncFolders { [weak self] report in
            guard report.mappedTabCount == 0 else { return }
            self?.presentNoMappedSyncFolders()
        }
    }

    /// Explains the empty configured-folder import and offers the folder picker.
    ///
    /// Returning silently here is the failure this replaces: a build with no
    /// tab sync folder left the user believing an import had happened.
    private func presentNoMappedSyncFolders() {
        guard let tab = model.selectedTab else { return }
        let language = model.preferences.language
        let prompt = SyncFolderImportPrompt.noMappedSyncFolder(tabName: tab.name, language: language)

        let alert = NSAlert()
        alert.messageText = Localization.string(.dialogNoSyncFolderMappingTitle, language: language)
        alert.alertStyle = .informational
        alert.informativeText = prompt.alertInformativeText
        alert.addButton(withTitle: Localization.string(.buttonChooseFolder, language: language))
        alert.addButton(withTitle: Localization.string(.buttonCancel, language: language))
        guard alertPresenter(alert) == .alertFirstButtonReturn else { return }
        presentSyncFolderImportPicker(prompt, targetTabID: tab.id)
    }

    private func presentSyncFolderImportPicker(_ prompt: SyncFolderImportPrompt, targetTabID: Int64) {
        let language = model.preferences.language
        let panel = NSOpenPanel()
        panel.title = Localization.string(.filePanelChooseSyncFolderTitle, language: language)
        panel.prompt = Localization.string(.filePanelChoosePrompt, language: language)
        panel.message = prompt.pickerMessage
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        panelPresenter(panel) { [weak self] url in
            guard let url else { return }
            Task { @MainActor [weak self] in
                self?.model.adoptPickedSyncFolder(url, intoTabID: targetTabID)
            }
        }
    }

    // MARK: - Sync reconciliation and trash

    /// Entry point for the tab strip context menu, which has no menu-item
    /// sender to carry the tab id.
    func resyncTab(id: Int64) {
        presentResync(tabID: id)
    }

    private func presentResync(tabID: Int64) {
        guard let tab = model.tab(id: tabID) else {
            model.reportFailure("That tab no longer exists.")
            return
        }
        let tabName = tab.name
        let store = model.history.store
        let language = model.preferences.language
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result {
                try CopyQSyncResync.reportAndPlan(tabID: tabID, in: store, language: language)
            }
            await MainActor.run { [weak self] in
                self?.presentResync(outcome, tabName: tabName, language: language)
            }
        }
    }

    private func presentResync(
        _ outcome: Result<(report: CopyQSyncResyncReport, plan: CopyQSyncResyncPlan?), Error>,
        tabName: String,
        language: AppLanguage
    ) {
        do {
            let assessment = try outcome.get()
            let report = assessment.report
            let plan = assessment.plan
            let pauseNote = plan == nil
                ? Localization.string(.dialogResyncPausedNote, language: language)
                : nil

            let alert = NSAlert()
            alert.messageText = Localization.format(.dialogResyncCompareTitle, language: language, tabName)
            alert.alertStyle = report.mismatches ? .warning : .informational

            var detailLines = [report.summary(language: language)]
            detailLines.append("")
            if let pauseNote {
                detailLines.append(pauseNote)
                detailLines.append("")
            } else if let plan, plan.isEmpty, !plan.conflicts.isEmpty {
                detailLines.append(
                    Localization.formatCount(
                        plan.conflicts.count,
                        .dialogResyncConflictsSingle,
                        .dialogResyncConflictsPlural,
                        language: language,
                        plan.conflicts.count,
                        plan.conflictSummary(language: language)
                    )
                )
                detailLines.append("")
            }
            detailLines.append(
                Localization.format(.dialogResyncFolderNote, language: language, report.folder)
            )
            if !report.failures.isEmpty {
                detailLines.append("")
                detailLines.append(contentsOf: report.failures.prefix(5))
            }
            alert.informativeText = detailLines.joined(separator: "\n")
            // The first button is the default, so Return reports without
            // changing anything.
            alert.addButton(withTitle: Localization.string(.buttonOK, language: language))
            let canApply = plan.map { !$0.isEmpty } ?? false
            if canApply {
                alert.addButton(withTitle: Localization.string(.buttonApplyChanges, language: language))
            }
            let response = alertPresenter(alert)
            if canApply, response == .alertSecondButtonReturn, let plan {
                presentResyncConfirmation(plan)
                return
            }
            model.notice = report.summary(language: language)
        } catch {
            model.reportFailure("Could not compare the tab with its sync folder: \(error.localizedDescription)")
        }
    }

    /// The explicit write confirmation.  It states, per category and with
    /// counts, exactly what the apply will import, remove, and update, and
    /// which conflicts it leaves untouched.  Cancel is the default button, so
    /// Return never writes.
    private func presentResyncConfirmation(_ plan: CopyQSyncResyncPlan) {
        let language = model.preferences.language
        let alert = NSAlert()
        alert.messageText = Localization.format(.dialogResyncApplyTitle, language: language, plan.tabName)
        alert.alertStyle = .warning
        let intro = Localization.string(.dialogResyncApplyIntro, language: language)
        let folder = Localization.format(.dialogResyncApplyFolder, language: language, plan.folder)
        let footer = Localization.string(.dialogResyncApplyFooter, language: language)
        alert.informativeText = [
            intro,
            "",
            plan.confirmation(language: language),
            "",
            folder,
            "",
            footer,
        ].joined(separator: "\n")
        alert.addButton(withTitle: Localization.string(.buttonCancel, language: language))
        alert.addButton(withTitle: Localization.string(.buttonApply, language: language))
        guard alertPresenter(alert) == .alertSecondButtonReturn else { return }

        do {
            let result = try model.applyResync(plan)
            windowController?.show()
            model.showNotice([result.summary(language: language)] + Array(result.failures.prefix(3)))
        } catch {
            model.reportFailure("Could not resync the tab with its sync folder: \(error.localizedDescription)")
        }
    }

    // MARK: - Write local items back to a sync folder

    /// Entry point for the tab strip context menu: writes the tab's local
    /// entries back into its sync folder after an explicit confirmation whose
    /// counts come from the plan.  The plan reads the folder and the store off
    /// the main thread, so a large folder never freezes the window.
    func writeBackTab(id: Int64) {
        guard model.tab(id: id) != nil else {
            model.reportFailure("That tab no longer exists.")
            return
        }
        let store = model.history.store
        let language = model.preferences.language
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result {
                try CopyQSyncRestore.plan(tabID: id, in: store)
            }
            await MainActor.run { [weak self] in
                self?.presentWriteBack(outcome, language: language)
            }
        }
    }

    private func presentWriteBack(
        _ outcome: Result<CopyQSyncRestorePlan, Error>,
        language: AppLanguage
    ) {
        do {
            presentWriteBackConfirmation(try outcome.get(), language: language)
        } catch {
            model.reportFailure(
                "Could not write the tab's items back to its sync folder: \(error.localizedDescription)"
            )
        }
    }

    /// The explicit write confirmation.  It states, with counts, how many
    /// entries are written, how many files are created and rewritten, and which
    /// entries are skipped with the reason for each.  Cancel is the default
    /// button, so Return never writes.
    private func presentWriteBackConfirmation(
        _ plan: CopyQSyncRestorePlan,
        language: AppLanguage
    ) {
        let alert = NSAlert()
        alert.messageText = Localization.format(
            .dialogWriteBackTitle,
            language: language,
            plan.tabName
        )
        alert.alertStyle = plan.isEmpty ? .informational : .warning

        var detailLines = [
            Localization.string(.dialogWriteBackIntro, language: language),
            "",
            plan.confirmation(language: language),
            "",
        ]
        let paused = model.preferences.syncPaused
        if paused {
            detailLines.append(Localization.string(.dialogWriteBackPausedNote, language: language))
            detailLines.append("")
        }
        detailLines.append(
            Localization.format(.dialogResyncApplyFolder, language: language, plan.folder)
        )
        detailLines.append("")
        detailLines.append(Localization.string(.dialogWriteBackFooter, language: language))
        alert.informativeText = detailLines.joined(separator: "\n")

        // The first button is the default, so Return never writes.
        alert.addButton(withTitle: Localization.string(.buttonCancel, language: language))
        let canWrite = !plan.isEmpty && !paused
        if canWrite {
            alert.addButton(withTitle: Localization.string(.buttonWriteBack, language: language))
        }
        guard canWrite, alertPresenter(alert) == .alertSecondButtonReturn else { return }

        let store = model.history.store
        let writer = model.syncWriter
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result {
                try CopyQSyncRestore.apply(plan, in: store, writer: writer)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let result):
                    self.windowController?.show()
                    self.model.showNotice(
                        [result.summary(language: language)] + Array(result.failures.prefix(3))
                    )
                case .failure(let error):
                    self.model.reportFailure(
                        "Could not write the tab's items back to its sync folder: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    @objc func reconcileSyncFolders(_ sender: Any?) {
        do {
            let report = try model.syncReconciliationReport()
            let language = model.preferences.language
            let alert = NSAlert()
            alert.messageText = Localization.string(.dialogReconcileTitle, language: language)
            alert.alertStyle = .informational

            guard report.mismatches else {
                alert.informativeText = report.failures.isEmpty && report.skippedFolders.isEmpty
                    ? Localization.string(.dialogReconcileInSync, language: language)
                    : report.summary(language: language)
                alert.addButton(withTitle: Localization.string(.buttonOK, language: language))
                _ = alertPresenter(alert)
                return
            }

            let details = report.tabs.map { tab in
                Localization.format(
                    .dialogReconcileTabLine,
                    language: language,
                    tab.tabName,
                    tab.missingEntries.count,
                    tab.groupsWithoutEntries.count
                )
            }.joined(separator: "\n")
            alert.informativeText = [
                Localization.string(.dialogReconcileIntro, language: language),
                "",
                report.summary(language: language),
                "",
                details,
                "",
                Localization.string(.dialogReconcileFooter, language: language),
            ].joined(separator: "\n")
            // The first button is the default, so Return reports without changing anything.
            alert.addButton(withTitle: Localization.string(.buttonReportOnly, language: language))
            alert.addButton(withTitle: Localization.string(.buttonReconcile, language: language))
            alert.addButton(withTitle: Localization.string(.buttonCancel, language: language))

            switch alertPresenter(alert) {
            case .alertSecondButtonReturn:
                let result = try model.reconcileSyncFolders(report)
                windowController?.show()
                model.notice = result.summary(language: language)
            case .alertFirstButtonReturn:
                model.notice = report.summary(language: language)
            default:
                break
            }
        } catch {
            model.reportFailure("Could not reconcile sync folders: \(error.localizedDescription)")
        }
    }

    @objc func emptySyncTrash(_ sender: Any?) {
        do {
            let summary = try model.syncTrashSummary()
            let language = model.preferences.language
            let alert = NSAlert()
            alert.messageText = Localization.string(.dialogEmptyTrashTitle, language: language)
            alert.alertStyle = .warning
            if summary.batchCount == 0 {
                alert.informativeText = summary.summary(language: language)
                alert.addButton(withTitle: Localization.string(.buttonOK, language: language))
                _ = alertPresenter(alert)
                return
            }
            alert.informativeText = [
                summary.summary(language: language),
                "",
                Localization.string(.dialogEmptyTrashFooter, language: language),
            ].joined(separator: "\n")
            // Cancel first so Return cannot empty the trash by accident.
            alert.addButton(withTitle: Localization.string(.buttonCancel, language: language))
            alert.addButton(withTitle: Localization.string(.buttonEmptyTrash, language: language))
            guard alertPresenter(alert) == .alertSecondButtonReturn else { return }
            let emptied = try model.emptySyncTrash()
            model.notice = emptied.batchCount == 1
                ? Localization.format(
                    .noticeEmptiedTrashSingle,
                    language: language,
                    emptied.fileCount
                )
                : Localization.format(
                    .noticeEmptiedTrashPlural,
                    language: language,
                    emptied.batchCount,
                    emptied.fileCount
                )
        } catch {
            model.reportFailure("Could not empty the sync trash: \(error.localizedDescription)")
        }
    }

    // MARK: - Backup export

    @objc func exportBackup(_ sender: Any?) {
        presentExportPanel(exportingCurrentTabOnly: false)
    }

    @objc func exportCurrentTab(_ sender: Any?) {
        presentExportPanel(exportingCurrentTabOnly: true)
    }

    /// Asks for the destination with a save panel, then hands it to the model,
    /// which writes the archive off the main thread.  The panel starts in
    /// Documents as a convenient default; any destination the user picks is
    /// accepted.
    private func presentExportPanel(exportingCurrentTabOnly: Bool) {
        guard !model.isExporting else { return }
        let tab = exportingCurrentTabOnly ? model.selectedTab : nil
        if exportingCurrentTabOnly, tab == nil { return }
        let language = model.preferences.language

        let panel = NSSavePanel()
        panel.title = Localization.string(
            exportingCurrentTabOnly ? .filePanelExportCurrentTabTitle : .filePanelExportBackupTitle,
            language: language
        )
        panel.prompt = Localization.string(.filePanelExportPrompt, language: language)
        panel.message = Localization.string(
            exportingCurrentTabOnly ? .filePanelExportCurrentTabMessage : .filePanelExportBackupMessage,
            language: language
        )
        panel.nameFieldStringValue = BackupFileName.default(for: tab)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: "cpq") {
            panel.allowedContentTypes = [type]
        }
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        panelPresenter(panel) { [weak self] url in
            guard let url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The export runs in the background; keep the window frontmost
                // so its status bar and the result banner are visible even when
                // the command came from the menu-bar item with the window hidden.
                self.windowController?.show()
                self.model.exportBackup(to: url, tabID: tab?.id)
            }
        }
    }

    @objc func toggleSyncPauseAction(_ sender: Any?) {
        model.toggleSyncPause()
    }

    // MARK: - Edit

    @objc func find(_ sender: Any?) { model.focusSearch() }

    /// Edit ▸ Select All. With a text control focused it selects that control's
    /// text; otherwise it selects every item the list is showing.
    @objc func selectAllItems(_ sender: Any?) {
        if isTextControlFocused {
            _ = deferToFirstResponder(action: #selector(NSText.selectAll(_:)), sender: sender)
            return
        }
        model.selectAllEntries()
    }

    @objc func copySelected(_ sender: Any?) {
        if isTextControlFocused {
            _ = deferToFirstResponder(action: #selector(NSText.copy(_:)), sender: sender)
            return
        }
        model.copySelected()
    }

    @objc func pasteSelected(_ sender: Any?) {
        if isTextControlFocused {
            _ = deferToFirstResponder(action: #selector(NSText.paste(_:)), sender: sender)
            return
        }
        model.pasteSelected(dismiss: { [weak self] in self?.windowController?.hide() })
    }

    /// Item ▸ Activate: the same pipeline as a double click and Return.
    @objc func activateSelected(_ sender: Any?) {
        model.activateSelected(dismiss: { [weak self] in self?.windowController?.hide() })
    }

    @objc func pasteSelectedAsPlainText(_ sender: Any?) {
        if isTextControlFocused {
            _ = deferToFirstResponder(
                action: #selector(NSTextView.pasteAsPlainText(_:)),
                fallbackActions: [#selector(NSText.paste(_:))],
                sender: sender
            )
            return
        }
        model.pasteSelectedAsPlainText(dismiss: { [weak self] in self?.windowController?.hide() })
    }

    // MARK: - Item

    @objc func newItem(_ sender: Any?) {
        windowController?.show()
        model.requestNewItem()
    }

    @objc func editItem(_ sender: Any?) {
        windowController?.show()
        model.requestEditSelectedEntry()
    }

    @objc func pinSelected(_ sender: Any?) { model.togglePinSelected() }

    // MARK: - Bulk order and tab moves

    @objc func moveSelectedUp(_ sender: Any?) { model.reorderSelected(.up) }
    @objc func moveSelectedDown(_ sender: Any?) { model.reorderSelected(.down) }
    @objc func moveSelectedToTop(_ sender: Any?) { model.reorderSelected(.top) }
    @objc func moveSelectedToBottom(_ sender: Any?) { model.reorderSelected(.bottom) }

    @objc func moveSelectedToTab(_ sender: Any?) {
        guard let tabID = (sender as? NSMenuItem).flatMap({ ($0.representedObject as? NSNumber)?.int64Value })
        else { return }
        model.moveSelection(toTabID: tabID)
    }

    @objc func editNote(_ sender: Any?) {
        guard !model.isEditingNote else { return }
        model.focusNote()
    }

    @objc func removeSelected(_ sender: Any?) {
        if isTextControlFocused {
            _ = deferToFirstResponder(
                action: #selector(NSResponder.deleteToBeginningOfLine(_:)),
                fallbackActions: [#selector(NSText.delete(_:)), #selector(NSResponder.deleteBackward(_:))],
                sender: sender
            )
            return
        }
        model.removeSelected()
    }

    @objc func clearTab(_ sender: Any?) {
        guard !model.isEditingText else { return }
        let tabID = model.selectedTabID != ClipboardTab.unsavedID ? model.selectedTabID : (try? model.history.defaultTab().id) ?? 0
        if let info = model.syncDeletionFileInfo(forTabID: tabID) {
            let language = model.preferences.language
            let alert = NSAlert()
            alert.messageText = Localization.string(.dialogClearTabTitle, language: language)
            alert.informativeText = Localization.formatCount(
                info.fileCount,
                .dialogClearTabInformativeSingle,
                .dialogClearTabInformativePlural,
                language: language,
                info.folder,
                info.fileCount
            )
            alert.alertStyle = .warning
            let clearTitle = Localization.string(.dialogClearTabTitle, language: language)
            alert.addButton(withTitle: clearTitle)
            alert.addButton(withTitle: Localization.string(.buttonCancel, language: language))
            guard alertPresenter(alert) == .alertFirstButtonReturn else { return }
        }
        model.clearSelectedTab()
    }

    @objc func removeInternalMarkerEntries(_ sender: Any?) {
        guard !model.isEditingText else { return }
        do {
            let candidateReport = try model.internalMarkerCandidateReport()
            let language = model.preferences.language

            let alert = NSAlert()
            alert.messageText = Localization.string(.dialogRemoveInternalMarkersTitle, language: language)
            alert.informativeText = Localization.format(
                .dialogRemoveInternalMarkersInformative,
                language: language,
                candidateReport.deletedCount,
                candidateReport.singleMarkerCount,
                candidateReport.otherPayloadlessCount
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: Localization.string(.buttonRemove, language: language))
            alert.addButton(withTitle: Localization.string(.buttonCancel, language: language))

            let response = alertPresenter(alert)
            guard response == .alertFirstButtonReturn else { return }

            windowController?.show()
            _ = model.removeInternalMarkerEntries()
        } catch {
            model.reportFailure("Could not check internal marker entries: \(error)")
        }
    }

    // MARK: - Tabs

    @objc func renameTab(_ sender: Any?) { model.requestRenameSelectedTab() }

    @objc func removeTab(_ sender: Any?) {
        if let tab = model.selectedTab { model.removeTab(tab) }
    }

    @objc func moveTabLeft(_ sender: Any?) {
        if let tab = model.selectedTab { model.moveTab(tab, delta: -1) }
    }

    @objc func moveTabRight(_ sender: Any?) {
        if let tab = model.selectedTab { model.moveTab(tab, delta: 1) }
    }

    @objc func setCaptureTab(_ sender: Any?) {
        if let tab = model.selectedTab { model.setCaptureTab(tab) }
    }

    // MARK: - Help

    @objc func showHelp(_ sender: Any?) {
        let language = model.preferences.language
        let alert = NSAlert()
        alert.messageText = Localization.string(.menuAppTitle, language: language)
        alert.informativeText = Localization.format(
            .dialogHelpInformative,
            language: language,
            Localization.hotKeyLabel(model.preferences.hotKeyDisplayLabel, language: language)
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: Localization.string(.buttonOK, language: language))
        _ = alertPresenter(alert)
    }

    // MARK: - Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showPreferencesAction(_:)), #selector(showMainWindow(_:)),
             #selector(hideWindow(_:)), #selector(find(_:)),
             #selector(showHelp(_:)):
            return true

        case #selector(newTab(_:)), #selector(newItem(_:)),
             #selector(importFromCopyQ(_:)), #selector(importConfiguredSyncFolders(_:)):
            return model.canCreateNewItem

        case #selector(editItem(_:)):
            let availability = model.editItemAvailability(language: model.preferences.language)
            menuItem.title = availability.title
            return availability.isEnabled

        case #selector(exportBackup(_:)):
            return !model.isExporting

        case #selector(exportCurrentTab(_:)):
            return !model.isExporting && model.selectedTab != nil

        case #selector(toggleSyncPauseAction(_:)):
            let lang = model.preferences.language
            menuItem.title = model.preferences.syncPaused
                ? Localization.string(.menuFileResumeSync, language: lang)
                : Localization.string(.menuFilePauseSync, language: lang)
            menuItem.state = model.preferences.syncPaused ? .on : .off
            return true

        case #selector(copySelected(_:)):
            if isTextControlFocused { return true }
            return model.canActOnSelectedEntry

        case #selector(selectAllItems(_:)):
            if isTextControlFocused { return true }
            return !model.entries.isEmpty

        case #selector(moveSelectedUp(_:)), #selector(moveSelectedDown(_:)),
             #selector(moveSelectedToTop(_:)), #selector(moveSelectedToBottom(_:)):
            return model.canReorderSelectedEntries

        case #selector(moveSelectedToTab(_:)):
            guard let tabID = (menuItem.representedObject as? NSNumber)?.int64Value else { return false }
            return model.canMoveSelection(toTabID: tabID)

        case #selector(pasteSelected(_:)):
            if isTextControlFocused { return true }
            return model.canActOnSelectedEntry

        case #selector(activateSelected(_:)):
            // Activating does nothing while a note is being edited, so the item
            // says so instead of closing the window under the editor.
            return !model.isEditingNote && model.canActOnSelectedEntry

        case #selector(pasteSelectedAsPlainText(_:)):
            if isTextControlFocused { return true }
            // Keep the item enabled for an entry with no text. A disabled item
            // does not consume its key equivalent; macOS then plays the system
            // beep. The action reports the same no-text reason as a notice.
            return !model.isEditingText

        case #selector(removeSelected(_:)):
            if model.isEditingNote || model.isEditingText || isTextControlFocused { return false }
            return model.canActOnSelectedEntry

        case #selector(editNote(_:)):
            if model.isEditingNote || model.isEditingText { return false }
            return model.canActOnSelectedEntry

        case #selector(pinSelected(_:)):
            let lang = model.preferences.language
            if let entry = model.selectedEntry, model.canActOnSelectedEntry {
                menuItem.title = entry.pinned
                    ? Localization.string(.menuItemUnpin, language: lang)
                    : Localization.string(.menuItemPin, language: lang)
                return true
            }
            menuItem.title = Localization.string(.menuItemPin, language: lang)
            return false

        case #selector(clearTab(_:)):
            return !model.isEditingText && !model.entries.isEmpty

        case #selector(removeInternalMarkerEntries(_:)):
            return !model.isEditingText

        case #selector(renameTab(_:)), #selector(removeTab(_:)),
             #selector(moveTabLeft(_:)), #selector(moveTabRight(_:)),
             #selector(setCaptureTab(_:)):
            guard let tab = model.selectedTab else { return false }
            if menuItem.action == #selector(renameTab(_:)) {
                return !model.isEditingText
            }
            if menuItem.action == #selector(removeTab(_:)) {
                return !model.isEditingText && model.tabs.count > 1
            }
            if menuItem.action == #selector(setCaptureTab(_:)) { return !tab.isDefault }
            return true

        default:
            return true
        }
    }
}

// MARK: - Move to Tab menu

/// The destination list changes with the tabs, so the submenu is rebuilt every
/// time it opens instead of going stale between tab edits.
extension AppActions: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier == MainMenuBuilder.moveToTabMenuIdentifier else { return }
        menu.removeAllItems()
        let destinations = model.tabs.filter { $0.id != model.selectedTabID }
        guard !destinations.isEmpty else {
            let empty = NSMenuItem(
                title: Localization.string(.menuItemNoOtherTab, language: model.preferences.language),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for tab in destinations {
            let item = NSMenuItem(
                title: tab.name,
                action: #selector(AppActions.moveSelectedToTab(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: tab.id)
            item.isEnabled = model.canMoveSelection(toTabID: tab.id)
            menu.addItem(item)
        }
    }
}

// MARK: - Save panel file names

/// The name a backup export proposes in the save panel.
///
/// Kept outside `AppActions` so the formatting can be exercised without the
/// main actor, and so repeated backups do not overwrite each other: every name
/// carries a minute-resolution stamp.
enum BackupFileName {
    static func `default`(for tab: ClipboardTab?, now: Date = Date()) -> String {
        let stamp = formatter.string(from: now)
        if let tab {
            return "\(sanitized(tab.name)) \(stamp).cpq"
        }
        return "CopyQmac Backup \(stamp).cpq"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()

    /// Tab names are free text, so path separators have to go before the name
    /// can be used for a file.
    private static func sanitized(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Tab" : cleaned
    }
}
