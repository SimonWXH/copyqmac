// Catalog and localization support for English and Simplified Chinese interfaces.

import Foundation

/// Supported user interface languages.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// The display name of the language in its own script.
    public var displayName: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    /// The canonical locale for date, time, and number formatting.
    public var locale: Locale {
        switch self {
        case .english:
            return Locale(identifier: "en_US")
        case .simplifiedChinese:
            return Locale(identifier: "zh_CN")
        }
    }
}

/// Catalog keys representing every user-visible string in the localized surfaces:
/// the menu bar, the status item, the in-window status bar, the preferences
/// window, the dialogs and file panels the app presents, the notice banner's
/// controls, and the item rows' relative timestamps.
public enum CatalogKey: String, CaseIterable, Sendable {
    // Menu Bar: Top-level menus
    case menuAppTitle
    case menuFile
    case menuEdit
    case menuItem
    case menuTabs
    case menuHelp

    // Menu Bar: CopyQmac (App Menu)
    case menuAppAbout
    case menuAppPreferences
    case menuAppHide
    case menuAppHideOthers
    case menuAppShowAll
    case menuAppQuit

    // Menu Bar: File
    case menuFileNewTab
    case menuFileImportCopyQ
    case menuFileImportSyncFolders
    case menuFileReconcileSyncFolders
    case menuFileEmptySyncTrash
    case menuFileExportBackup
    case menuFileExportCurrentTab
    case menuFilePauseSync
    case menuFileResumeSync
    case menuFileHideWindow

    // Menu Bar: Edit
    case menuEditUndo
    case menuEditRedo
    case menuEditCut
    case menuEditCopy
    case menuEditPaste
    case menuEditSelectAll
    case menuEditFind

    // Menu Bar: Item
    case menuItemNewItem
    case menuItemEditItem
    case menuItemEditItemUseNote
    case menuItemEditNote
    case menuItemActivate
    case menuItemPin
    case menuItemUnpin
    case menuItemPasteAsPlainText
    case menuItemMoveUp
    case menuItemMoveDown
    case menuItemMoveToTop
    case menuItemMoveToBottom
    case menuItemMoveToTab
    case menuItemNoOtherTab
    case menuItemRemove
    case menuItemClearTab
    case menuItemRemoveInternalMarkerEntries

    // Menu Bar: Tabs
    case menuTabsNewTab
    case menuTabsRenameTab
    case menuTabsRemoveTab
    case menuTabsMoveTabLeft
    case menuTabsMoveTabRight
    case menuTabsMoveTabUp
    case menuTabsMoveTabDown
    case menuTabsUseAsCaptureTab

    // Menu Bar: Help
    case menuHelpCopyQmacHelp

    // Status Item (Menu bar right-click and tooltip)
    case statusItemTooltip
    case statusItemShowCopyQmac
    case statusItemHideCopyQmac
    case statusItemAccessibilityDescription
    /// The short menu-bar notice shown when the API-key guard dropped a capture.
    case statusItemAPIKeyNotSaved

    // Status Bar (In-window footer)
    case statusBarItemCountSingle
    case statusBarItemCountPlural
    case statusBarCaptureTab
    case statusBarTab
    case statusBarDismissTooltip
    case statusBarAccessibilityNotGranted
    case statusBarAccessibilityHelp
    case statusBarExportingBackup
    case statusBarExportingItems
    case statusBarExportingTab
    case statusBarExportingMultiTab

    // Relative Time
    case relativeTimeJustNow
    case relativeTimeSecondsAgo
    case relativeTimeMinutesAgo
    case relativeTimeHoursAgo
    case relativeTimeYesterday

    // Notice Banner controls
    case bannerOpenSystemSettings
    case bannerDismiss
    case bannerMessage

    // Settings Window: Window
    case settingsWindowTitle

    // Settings Window: Tab items
    case settingsTabHistory
    case settingsTabTabs
    case settingsTabIgnoredApps
    case settingsTabShortcut

    // Settings Window: Appearance Section
    case settingsSectionAppearance
    case settingsThemeLabel
    case settingsThemeSystem
    case settingsThemeLight
    case settingsThemeDark
    case settingsThemeDetail
    case settingsWindowLayoutLabel
    case settingsWindowLayoutTopTabs
    case settingsWindowLayoutSidebarInspector
    case settingsWindowLayoutDetail

    // Settings Window: Language Section
    case settingsSectionLanguage
    case settingsLanguageLabel
    case settingsLanguageDetail

    // Settings Window: Font Section
    case settingsSectionFonts
    case settingsItemListFontLabel
    case settingsItemListFontDetail
    case settingsEditorFontLabel
    case settingsEditorFontDetail
    case settingsFontFamilyLabel
    case settingsFontSystemOption
    case settingsFontSizeLabel

    // Settings Window: History Tab
    case settingsMaxItemsLabel
    case settingsMaxItemsDetail
    case settingsSearchAllTabsToggle
    case settingsSearchAllTabsDetail
    case settingsActivationSection
    case settingsActivationSingleClick
    case settingsActivationSingleClickDetail
    case settingsActivationPaste
    case settingsActivationPasteDetail
    case settingsActivationFocus
    case settingsActivationFocusDetail
    case settingsActivationCloseWindow
    case settingsActivationCloseWindowDetail
    case settingsActivationMoveToTop
    case settingsActivationMoveToTopDetail
    case settingsLaunchAtLoginToggle
    case settingsLaunchAtLoginEnabledDetail
    case settingsLaunchAtLoginDisabledDetail
    case settingsLaunchAtLoginApprovalDetail
    case settingsOpenLoginItemsButton
    case settingsStoredItemsLabel

    // Settings Window: Tabs Tab
    case settingsCaptureTabHeader
    case settingsCaptureTabPickerLabel
    case settingsSyncFolderBehaviorDetail
    case settingsPauseSyncToggle
    case settingsPauseSyncDetail
    case settingsTabsListHeader
    case settingsTabCaptureBadge
    case settingsTabRenameButton
    case settingsTabRemoveHelp
    case settingsTabSyncFolderLabel
    case settingsTabSyncFolderPlaceholder
    case settingsTabSyncFolderLocalDetail
    case settingsTabSyncFolderSyncingDetail
    case settingsAddTabButton
    case settingsTabReorderDetail

    // Settings Window: Ignored Apps Tab
    case settingsIgnoredAppsExplanation
    case settingsIgnoredAppsHeader
    case settingsNoAppsIgnored
    case settingsIgnoreAppToggle
    case settingsIgnoreAppHelp
    case settingsStopIgnoringAppHelp
    case settingsRemoveAppHelp
    case settingsAddAppHeader
    case settingsAddLastAppButton
    case settingsLastAppObserved
    case settingsLastAppNone
    /// The AI-service API-key guard on the ignore-rules tab.
    case settingsAPIKeyGuardToggle
    case settingsAPIKeyGuardDetail

    // Settings Window: Shortcut Tab
    case settingsPlainTextShortcutHeader
    case settingsRecordLabel
    case settingsPlainTextShortcutDetail
    case settingsSummonShortcutHeader
    case settingsPresetLabel
    case settingsPresetCustom
    case settingsShortcutRecordDetail
    case settingsRecordPrompt
    case settingsShortcutModifierProblem
    case settingsShortcutConflictProblem
    case settingsShortcutUnavailableProblem

    // Shortcut labels
    case hotKeySpace
    case hotKeyKeyPrefix

    // Rename Tab Alert
    case alertRenameTabTitle
    case alertRenameTabPlaceholder
    case alertRenameTabConfirm
    case alertRenameTabCancel
    case alertRenameTabMessage

    // Launch at login runtime messages
    case launchAtLoginProblemEnable
    case launchAtLoginProblemDisable
    case launchAtLoginUnavailablePrefix
    case launchAtLoginUnknownState
    case launchAtLoginNeedsApproval

    // Runtime Failures and Status Bar Notices
    case failureAccessibilityPermission
    case failureAccessibilityPermissionStaleGrant
    case failureFocusPreviousApp
    case failureActivatePreviousApp
    case failureActivatePreviousAppOrPaste
    case failureNoPlainTextToPaste
    case failureClipboardNoText
    case failurePastePrefix
    case failureUnsupportedEditText
    case failureEntryNoLongerExists
    case failureMultipleItemsEditText
    case failureTabNoLongerExists
    case failureDestinationTabNoLongerExists
    case failureEditingEntryRemovedByResultsSaved
    case failureEditingEntryRemovedByHistoryLimitSaved
    case failureEditingEntryRemovedByResultsDraftPrefix
    case failureEditingEntryRemovedByHistoryLimitDraftPrefix
    case failureDeleteEntriesPrefix
    case failureSyncEditPrefix
    case failureSyncWriterProtected
    case failureSyncWriterProtectedPrefix
    case failureSyncWriterTargetMissing
    case failureSyncWriterWritePrefix
    case failureSyncWriterRewritePrefix
    case failureSyncWriterTrashGroupPrefix
    case failureSyncWriteBackPrefix
    case failureSyncTrashInsideFolderPrefix
    case failureSyncTrashUnsafeRootPrefix
    case failureImportNotArchivePrefix
    case failureImportAmbiguousFolder
    case failureBackupNoTab
    case failureBackupNoTabs
    case failureBackupProtectedPathPrefix
    case failureResyncNoTab
    case failureResyncNoSyncFolder
    case failureResyncAmbiguousFolder
    case failureResyncFolderMissingPrefix
    case failureResyncFolderUnreadable
    case failureResyncFolderChanged
    case failureResyncPaused
    case failureTrimDestinationPrefix
    case failureSyncPausedMove
    case failureDestinationFolderUnavailablePrefix
    case failureLoadClipboardStorePrefix
    case failureReadHistoryPrefix
    case failureAddTabPrefix
    case failureUpdateTabPrefix
    case failureRemoveTabPrefix
    case failureReorderTabPrefix
    case failureSetDefaultTabPrefix
    case failureClearTabPrefix
    case failureSavePreferencesPrefix
    case failureUpdatePinPrefix
    case failureDeleteEntryPrefix
    case failureMoveItemToTopPrefix
    case failureReorderItemsPrefix
    case failureSaveNoteDraftPrefix
    case failureSaveItemPrefix
    case failureMoveItemsToTabPrefix
    case failureImportPrefix
    case failureBackupPrefix
    case failureSyncFolderTabNoLongerExists
    case failureSyncFolderAlreadyHasOnePrefix
    case failureSetSyncFolderPrefix
    case failureSyncFoldersImportPrefix
    case failureCompareTabSyncPrefix
    case failureResyncTabSyncPrefix
    case failureReconcileSyncFoldersPrefix
    case failureEmptySyncTrashPrefix
    case failureRemoveInternalMarkersPrefix
    case failureCheckInternalMarkersPrefix

    // File Panels
    case filePanelImportCopyQTitle
    case filePanelImportPrompt
    case filePanelChooseSyncFolderTitle
    case filePanelChoosePrompt
    case filePanelExportBackupTitle
    case filePanelExportCurrentTabTitle
    case filePanelExportPrompt
    case filePanelExportBackupMessage
    case filePanelExportCurrentTabMessage

    // Dialog buttons
    case buttonOK
    case buttonCancel
    case buttonChooseFolder
    case buttonRemove
    case buttonMove
    case buttonApply
    case buttonApplyChanges
    case buttonOpenPreferences
    case buttonLater
    case buttonReportOnly
    case buttonReconcile
    case buttonEmptyTrash

    // Destructive Confirmation Dialogs
    case dialogClearTabTitle
    case dialogClearTabInformativeSingle
    case dialogClearTabInformativePlural
    case dialogRemoveItemsTitlePlural
    case dialogRemoveItemsInformative
    case dialogMoveToTabTitle
    case dialogMovePlanNoSyncFiles
    case dialogMovePlanAction
    case dialogMovePlanJoiner
    case dialogMovePlanRewriteSingle
    case dialogMovePlanRewritePlural
    case dialogMovePlanTrashSingle
    case dialogMovePlanTrashPlural
    case dialogRemoveInternalMarkersTitle
    case dialogRemoveInternalMarkersInformative

    // Sync Folder Dialogs
    case dialogNoSyncFolderMappingTitle
    case dialogSyncFolderImportAlert
    case dialogSyncFolderImportPicker

    // Compare and Resync Dialogs
    case dialogResyncCompareTitle
    case dialogResyncPausedNote
    case dialogResyncConflictsSingle
    case dialogResyncConflictsPlural
    case dialogResyncFolderNote
    case dialogResyncApplyTitle
    case dialogResyncApplyIntro
    case dialogResyncApplyFolder
    case dialogResyncApplyFooter
    case dialogResyncReportCounts
    case dialogResyncReportUnresolvedSingle
    case dialogResyncReportUnresolvedPlural
    case dialogResyncReportUnreadableEntriesSingle
    case dialogResyncReportUnreadableEntriesPlural
    case dialogResyncReportUnreadableFilesSingle
    case dialogResyncReportUnreadableFilesPlural
    case dialogResyncReportSkippedStemsSingle
    case dialogResyncReportSkippedStemsPlural
    case dialogResyncPlanImportSingle
    case dialogResyncPlanImportPlural
    case dialogResyncPlanRemoveSingle
    case dialogResyncPlanRemovePlural
    case dialogResyncPlanUpdateSingle
    case dialogResyncPlanUpdatePlural
    case dialogResyncPlanConflictSingle
    case dialogResyncPlanConflictPlural
    case dialogResyncConflictLocallyEdited
    case dialogResyncConflictNoteOrPin
    case dialogResyncConflictMultipleGroups
    case dialogResyncConflictUnrelatedHistory

    // Reconcile Dialog
    case dialogReconcileTitle
    case dialogReconcileInSync
    case dialogReconcileIntro
    case dialogReconcileFooter
    case dialogReconcileTabLine
    case dialogReconcileReportCounts
    case dialogReconcileReportSkipped
    case dialogReconcileReportFailuresSingle
    case dialogReconcileReportFailuresPlural

    // Empty Sync Trash Dialog
    case dialogEmptyTrashTitle
    case dialogTrashEmpty
    case dialogEmptyTrashFooter
    case dialogTrashSummary

    // Shortcut and Help Dialogs
    case dialogShortcutUnavailableTitle
    case dialogShortcutUnavailableInformative
    case dialogHelpInformative
    case dialogFatalTitle

    // Main Window: Tab strip
    case tabBarNewTabHelp
    case tabChipCaptureHelp
    case tabContextMoveLeft
    case tabContextMoveRight
    case tabContextMoveUp
    case tabContextMoveDown
    case tabContextCompareSyncFolder

    // Main Window: Filter bar and empty state
    case filterItemsPlaceholder
    case filterClearHelp
    case filterAllTabsToggle
    case filterSearchAllTabsHelp
    case emptyStateNoItems
    case emptyStateNoMatches
    case emptyStateCreateItem

    // Main Window: Entry rows and their context menu
    case rowNoteBadge
    case rowPinnedHelp
    case rowDeleteHelp
    case rowNoPreview
    case rowMoreFiles
    case contextCopyToClipboard

    // Main Window: Preview and note pane
    case previewImageUnavailable
    case previewSelectPrompt
    case previewNoteLabel

    // Main Window: Layout B and Unified Toolbar
    case scopePickerLabel
    case scopeCurrentTab
    case scopeAllTabs
    case inspectorToggleHelp
    case sidebarToggleHelp

    // Main Window: Text edit sheet and styled toolbar
    case textEditTitleEdit
    case textEditTitleNew
    case textEditNewDetail
    case textEditConfirmSave
    case textEditConfirmAdd
    case textEditEmptyWarning
    case textEditRichFormatError
    case textEditPreviewFallbackHint
    case textEditFormattingFallbackHint
    case kindText
    case kindHTML
    case kindRichText
    case kindImage
    case kindFiles
    case kindOther
    case richToolbarBold
    case richToolbarItalic
    case richToolbarUnderline
    case richToolbarTextColour
    case richToolbarDefaultColour
    case richToolbarSize
    case richToolbarTextSize

    // Notices: window messages
    case noticeSavedHiddenByFilter
    case noticeImportingCopyQ
    case noticeImportingFilePrefix
    case noticeImportingConfiguredSyncFolders
    case noticeNoSyncFolderSet
    case noticeImportCompletePrefix
    case noticeSyncFolderImportedPrefix
    case noticeSyncFoldersImportedPrefix
    case noticeInternalMarkerCleanupPrefix
    case noticeBackupWrittenPrefix
    case noticeCopiedToClipboardNoTarget
    case noticeKeptLocalVersionPrefix
    case noticeKeptLocalVersionsPrefix
    case noticeRemovedEntryAfterRemoteDeletionPrefix
    case noticeRemovedEntriesAfterRemoteDeletion
    case noticeEmptiedTrashSingle
    case noticeEmptiedTrashPlural

    // Notices: report summaries
    case reportClauseJoiner
    case reportSentenceSeparator
    case reportTerminator
    case importSummaryImported
    case importSummaryUpdated
    case importSummaryUpstreamSkipped
    case importSummaryDuplicateSingle
    case importSummaryDuplicatePlural
    case importSummaryInternalSingle
    case importSummaryInternalPlural
    case importSummaryFailed
    case importSummaryTabs
    case exportSummaryHead
    case exportSummaryTabsSingle
    case exportSummaryTabsPlural
    case exportSummaryItemsSingle
    case exportSummaryItemsPlural
    case exportSummaryRenamedSingle
    case exportSummaryRenamedPlural
    case exportSummaryPayloadCaveat
    case exportSummarySyncDestination
    case markerCleanupNoEntries
    case markerCleanupTabLine
    case markerCleanupTotalSingle
    case markerCleanupTotalPlural
    case relocationMovedSingle
    case relocationMovedPlural
    case relocationMovedAndSingle
    case relocationMovedAndPlural
    case relocationSyncGroupsSingle
    case relocationSyncGroupsPlural
    case relocationTrashGroupsSingle
    case relocationTrashGroupsPlural
    case reconcileResultRemovedSingle
    case reconcileResultRemovedPlural
    case reconcileResultImportedSingle
    case reconcileResultImportedPlural
    case reconcileResultFailed
    case resyncResultImportedSingle
    case resyncResultImportedPlural
    case resyncResultLinked
    case resyncResultRemoved
    case resyncResultUpdated
    case resyncResultConflictsSingle
    case resyncResultConflictsPlural
    case resyncResultSkipped
    case watcherSummaryUpdatedInPlace
    case watcherSummaryUpstreamDiscardedSingle
    case watcherSummaryUpstreamDiscardedPlural
    case watcherSummaryReassertedSingle
    case watcherSummaryReassertedPlural
    case watcherSummaryReplacedSingle
    case watcherSummaryReplacedPlural
    case watcherSummaryWrittenByUs
    case watcherSummaryInternalOnly
    case watcherSummaryIncomplete
    case watcherSummaryPendingSettlement
    case watcherSummaryRemoteDeleted
    case watcherSummaryKeptLocallyEdited
    case watcherSummaryPendingDeletionSettlement

    // Notices: resync and sync diagnostics
    case diagnosticSkippedEntryGone
    case diagnosticSkippedNoIdentity
    case diagnosticKeptReason
    case diagnosticKeptUnarchivedPayload
    case diagnosticFolderFileFailure
    case diagnosticFolderCannotResolvePath
    case diagnosticFolderPathEscapesRoot
    case diagnosticFolderCannotReadFile
    case diagnosticFolderFlavourFailure
    case deletionCouldNotMoveBeforeReconciliation
    case deletionCouldNotArchiveBeforeReconciliation
    case diagnosticCouldNotCheckLocalEdit
    case diagnosticSkippedGroupReappeared
    case diagnosticSkippedGroupBeingWritten
    case diagnosticCouldNotRemoveMissingEntries
    case diagnosticSkippedNotImportable
    case diagnosticSkippedAlreadyOwned
    case diagnosticSkippedWrittenByApp
    case diagnosticSkippedLocalEditPending
    case diagnosticSkippedFolderOlder
    case diagnosticSkippedNoContent
    case diagnosticCouldNotImportStem
    case diagnosticSkippedFolderItemGone
    case diagnosticSkippedAlreadyHasFolderContent
    case diagnosticCouldNotUpdateStem
    case diagnosticSkippedFile

    /// English translation value.
    public var english: String {
        switch self {
        // Menu Bar: Top-level menus
        case .menuAppTitle:
            return "CopyQmac"
        case .menuFile:
            return "File"
        case .menuEdit:
            return "Edit"
        case .menuItem:
            return "Item"
        case .menuTabs:
            return "Tabs"
        case .menuHelp:
            return "Help"

        // Menu Bar: CopyQmac (App Menu)
        case .menuAppAbout:
            return "About CopyQmac"
        case .menuAppPreferences:
            return "Preferences\u{2026}"
        case .menuAppHide:
            return "Hide CopyQmac"
        case .menuAppHideOthers:
            return "Hide Others"
        case .menuAppShowAll:
            return "Show All"
        case .menuAppQuit:
            return "Quit CopyQmac"

        // Menu Bar: File
        case .menuFileNewTab:
            return "New Tab"
        case .menuFileImportCopyQ:
            return "Import from CopyQ\u{2026}"
        case .menuFileImportSyncFolders:
            return "Import Configured Sync Folders"
        case .menuFileReconcileSyncFolders:
            return "Reconcile Sync Folders\u{2026}"
        case .menuFileEmptySyncTrash:
            return "Empty Sync Trash\u{2026}"
        case .menuFileExportBackup:
            return "Export Backup\u{2026}"
        case .menuFileExportCurrentTab:
            return "Export Current Tab\u{2026}"
        case .menuFilePauseSync:
            return "Pause Sync"
        case .menuFileResumeSync:
            return "Resume Sync"
        case .menuFileHideWindow:
            return "Hide Window"

        // Menu Bar: Edit
        case .menuEditUndo:
            return "Undo"
        case .menuEditRedo:
            return "Redo"
        case .menuEditCut:
            return "Cut"
        case .menuEditCopy:
            return "Copy"
        case .menuEditPaste:
            return "Paste"
        case .menuEditSelectAll:
            return "Select All"
        case .menuEditFind:
            return "Find"

        // Menu Bar: Item
        case .menuItemNewItem:
            return "New Item\u{2026}"
        case .menuItemEditItem:
            return "Edit Item\u{2026}"
        case .menuItemEditItemUseNote:
            return "Edit Item\u{2026} (Use Edit Note)"
        case .menuItemEditNote:
            return "Edit Note"
        case .menuItemActivate:
            return "Activate"
        case .menuItemPin:
            return "Pin"
        case .menuItemUnpin:
            return "Unpin"
        case .menuItemPasteAsPlainText:
            return "Paste as Plain Text"
        case .menuItemMoveUp:
            return "Move Up"
        case .menuItemMoveDown:
            return "Move Down"
        case .menuItemMoveToTop:
            return "Move to Top"
        case .menuItemMoveToBottom:
            return "Move to Bottom"
        case .menuItemMoveToTab:
            return "Move to Tab"
        case .menuItemNoOtherTab:
            return "No Other Tab"
        case .menuItemRemove:
            return "Remove"
        case .menuItemClearTab:
            return "Clear Tab\u{2026}"
        case .menuItemRemoveInternalMarkerEntries:
            return "Remove Internal-Marker Entries\u{2026}"

        // Menu Bar: Tabs
        case .menuTabsNewTab:
            return "New Tab"
        case .menuTabsRenameTab:
            return "Rename Tab\u{2026}"
        case .menuTabsRemoveTab:
            return "Remove Tab"
        case .menuTabsMoveTabLeft:
            return "Move Tab Left"
        case .menuTabsMoveTabRight:
            return "Move Tab Right"
        case .menuTabsMoveTabUp:
            return "Move Tab Up"
        case .menuTabsMoveTabDown:
            return "Move Tab Down"
        case .menuTabsUseAsCaptureTab:
            return "Use as Capture Tab"

        // Menu Bar: Help
        case .menuHelpCopyQmacHelp:
            return "CopyQmac Help"

        // Status Item
        case .statusItemTooltip:
            return "CopyQmac clipboard history (%@)"
        case .statusItemShowCopyQmac:
            return "Show CopyQmac"
        case .statusItemHideCopyQmac:
            return "Hide CopyQmac"
        case .statusItemAccessibilityDescription:
            return "Clipboard history"
        case .statusItemAPIKeyNotSaved:
            return "API key not saved"

        // Status Bar
        case .statusBarItemCountSingle:
            return "%d item"
        case .statusBarItemCountPlural:
            return "%d items"
        case .statusBarCaptureTab:
            return "capture tab: %@"
        case .statusBarTab:
            return "tab: %@"
        case .statusBarDismissTooltip:
            return "%@\nClick to dismiss."
        case .statusBarAccessibilityNotGranted:
            return "Accessibility permission not granted"
        case .statusBarAccessibilityHelp:
            return "Needed to paste automatically into the previous app. Click to open System Settings \u{25B8} Privacy & Security \u{25B8} Accessibility."
        case .statusBarExportingBackup:
            return "Exporting backup\u{2026}"
        case .statusBarExportingItems:
            return "%@ of %@ items\u{2026}"
        case .statusBarExportingTab:
            return "Exporting \u{201C}%@\u{201D}: %@"
        case .statusBarExportingMultiTab:
            return "Exporting tab %d of %d \u{201C}%@\u{201D}: %@"

        // Relative Time
        case .relativeTimeJustNow:
            return "just now"
        case .relativeTimeSecondsAgo:
            return "%d s ago"
        case .relativeTimeMinutesAgo:
            return "%d min ago"
        case .relativeTimeHoursAgo:
            return "%d h ago"
        case .relativeTimeYesterday:
            return "Yesterday"

        // Notice Banner controls
        case .bannerOpenSystemSettings:
            return "Open System Settings\u{2026}"
        case .bannerDismiss:
            return "Dismiss"
        case .bannerMessage:
            return "Message"

        // Settings Window: Window
        case .settingsWindowTitle:
            return "CopyQmac Preferences"

        // Settings Window: Tab items
        case .settingsTabHistory:
            return "History"
        case .settingsTabTabs:
            return "Tabs"
        case .settingsTabIgnoredApps:
            return "Ignored Apps"
        case .settingsTabShortcut:
            return "Shortcut"

        // Settings Window: Appearance Section
        case .settingsSectionAppearance:
            return "Appearance"
        case .settingsThemeLabel:
            return "Theme"
        case .settingsThemeSystem:
            return "System"
        case .settingsThemeLight:
            return "Light"
        case .settingsThemeDark:
            return "Dark"
        case .settingsThemeDetail:
            return "Choose whether CopyQmac follows the system appearance or stays light or dark."
        case .settingsWindowLayoutLabel:
            return "Window layout"
        case .settingsWindowLayoutTopTabs:
            return "Top tabs"
        case .settingsWindowLayoutSidebarInspector:
            return "Sidebar + inspector"
        case .settingsWindowLayoutDetail:
            return "Choose between the classic top tabs layout and the sidebar with inspector layout."

        // Settings Window: Language Section
        case .settingsSectionLanguage:
            return "Language"
        case .settingsLanguageLabel:
            return "Interface language"
        case .settingsLanguageDetail:
            return "Choose the language for menus, dialogs, the status bar, and settings."

        // Settings Window: Font Section
        case .settingsSectionFonts:
            return "Fonts"
        case .settingsItemListFontLabel:
            return "Item list"
        case .settingsItemListFontDetail:
            return "The font list rows draw in. A row whose text carries its own font keeps it, so a rich item's fonts still win. System draws the real system font."
        case .settingsEditorFontLabel:
            return "Editor"
        case .settingsEditorFontDetail:
            return "The base font new text is typed in once you choose one: the first character at the opening caret and text typed after deleting everything. Typing inside existing text keeps its font. System plus a size draws the real system font in the plain editor, but the app's default writing font in the styled editor, because a rich item cannot store the system font."
        case .settingsFontFamilyLabel:
            return "Family"
        case .settingsFontSystemOption:
            return "System"
        case .settingsFontSizeLabel:
            return "Size"

        // Settings Window: History Tab
        case .settingsMaxItemsLabel:
            return "Maximum items in each tab"
        case .settingsMaxItemsDetail:
            return "This limit applies to every tab. Pinned items are never removed."
        case .settingsSearchAllTabsToggle:
            return "Search all tabs"
        case .settingsSearchAllTabsDetail:
            return "When off, the filter only searches the tab you are viewing."
        case .settingsActivationSection:
            return "Activation"
        case .settingsActivationSingleClick:
            return "Single click activates"
        case .settingsActivationSingleClickDetail:
            return "When off, a click only selects the item; Return or a double click activates it."
        case .settingsActivationPaste:
            return "Paste into the previous app"
        case .settingsActivationPasteDetail:
            return "Activating always copies the item to the clipboard, then pastes it. Without Accessibility permission the item is only copied and a notice explains why."
        case .settingsActivationFocus:
            return "Focus the previous app"
        case .settingsActivationFocusDetail:
            return "Pasting already focuses the previous app, so this only changes anything when pasting is off."
        case .settingsActivationCloseWindow:
            return "Close the main window"
        case .settingsActivationCloseWindowDetail:
            return "The window stays open when a delivery does not arrive. Without Accessibility permission the status bar keeps the permission reminder until the grant is recognized; a failed paste or focus stays there until you dismiss it. With no target app, only the copy hint is shown."
        case .settingsActivationMoveToTop:
            return "Move the item to the top"
        case .settingsActivationMoveToTopDetail:
            return "Moves the activated item to the top of its tab."
        case .settingsLaunchAtLoginToggle:
            return "Launch CopyQmac at login"
        case .settingsLaunchAtLoginEnabledDetail:
            return "CopyQmac runs in the menu bar when you log in."
        case .settingsLaunchAtLoginDisabledDetail:
            return "CopyQmac stays closed until you open it."
        case .settingsLaunchAtLoginApprovalDetail:
            return "macOS needs your approval in System Settings \u{203A} General \u{203A} Login Items before CopyQmac can start at login."
        case .settingsOpenLoginItemsButton:
            return "Open Login Items\u{2026}"
        case .settingsStoredItemsLabel:
            return "Stored items"

        // Settings Window: Tabs Tab
        case .settingsCaptureTabHeader:
            return "Capture tab"
        case .settingsCaptureTabPickerLabel:
            return "Captures on this machine are written to:"
        case .settingsSyncFolderBehaviorDetail:
            return "A tab with a sync folder always syncs both ways: captures and edits are written into the folder, and items arriving in it are imported."
        case .settingsPauseSyncToggle:
            return "Pause sync"
        case .settingsPauseSyncDetail:
            return "Immediately stops all folder write and watch operations."
        case .settingsTabsListHeader:
            return "Tabs"
        case .settingsTabCaptureBadge:
            return "capture"
        case .settingsTabRenameButton:
            return "Rename\u{2026}"
        case .settingsTabRemoveHelp:
            return "Remove this tab and its items"
        case .settingsTabSyncFolderLabel:
            return "Sync folder"
        case .settingsTabSyncFolderPlaceholder:
            return "~/Syncthing/Config/CopyQ/<tab>"
        case .settingsTabSyncFolderLocalDetail:
            return "No sync folder: this tab stays local."
        case .settingsTabSyncFolderSyncingDetail:
            return "This tab syncs both ways with its folder. Pause sync in the section above to stop it."
        case .settingsAddTabButton:
            return "Add Tab"
        case .settingsTabReorderDetail:
            return "Reordering is available from the tab context menu in the main window."

        // Settings Window: Ignored Apps Tab
        case .settingsIgnoredAppsExplanation:
            return "Captures are skipped when an app on this list was frontmost since the last clipboard check, and when no app was observed in that window. CopyQmac itself counts as an observed app. Captures that a source app marks as private are always skipped."
        case .settingsIgnoredAppsHeader:
            return "Ignored Apps"
        case .settingsNoAppsIgnored:
            return "No apps are ignored."
        case .settingsIgnoreAppToggle:
            return "Ignore %@"
        case .settingsIgnoreAppHelp:
            return "Ignore %@"
        case .settingsStopIgnoringAppHelp:
            return "Stop ignoring %@"
        case .settingsRemoveAppHelp:
            return "Remove %@ from the list"
        case .settingsAddAppHeader:
            return "Add an App"
        case .settingsAddLastAppButton:
            return "Add Last App"
        case .settingsLastAppObserved:
            return "Last app: %@ (%@)"
        case .settingsLastAppNone:
            return "Copy something in another app, then come back to add it."
        case .settingsAPIKeyGuardToggle:
            return "Do not save AI service API keys copied on this Mac"
        case .settingsAPIKeyGuardDetail:
            return "Covers copies made here only: a key copied on this Mac is not saved, though it cannot promise that nothing ever does. Keys already in the history stay, copying and pasting still works, and items arriving through a sync folder are not filtered."

        // Settings Window: Shortcut Tab
        case .settingsPlainTextShortcutHeader:
            return "Paste as Plain Text shortcut: %@"
        case .settingsRecordLabel:
            return "Record"
        case .settingsPlainTextShortcutDetail:
            return "While the CopyQmac window is open this pastes the selected item as plain text. While CopyQmac is only in the menu bar it strips the formatting from the clipboard and pastes that text into the app in front."
        case .settingsSummonShortcutHeader:
            return "Summon shortcut: %@"
        case .settingsPresetLabel:
            return "Preset"
        case .settingsPresetCustom:
            return "Custom"
        case .settingsShortcutRecordDetail:
            return "Click a field and press the new shortcut. Each shortcut must include at least one modifier and the two must differ. If the system refuses a combination because another app already uses it, a warning appears here."
        case .settingsRecordPrompt:
            return "Press a shortcut\u{2026}"
        case .settingsShortcutModifierProblem:
            return "Choose a shortcut with at least one modifier."
        case .settingsShortcutConflictProblem:
            return "%@ conflicts with the summon shortcut. Choose a different shortcut."
        case .settingsShortcutUnavailableProblem:
            return "%@ could not be registered. Another app may already use it; choose a different shortcut."

        // Shortcut labels
        case .hotKeySpace:
            return "Space"
        case .hotKeyKeyPrefix:
            return "Key %@"

        // Rename Tab Alert
        case .alertRenameTabTitle:
            return "Rename Tab"
        case .alertRenameTabPlaceholder:
            return "Tab name"
        case .alertRenameTabConfirm:
            return "Rename"
        case .alertRenameTabCancel:
            return "Cancel"
        case .alertRenameTabMessage:
            return "Choose a name for this tab."

        // Launch at login runtime messages
        case .launchAtLoginProblemEnable:
            return "Could not enable launch at login: %@"
        case .launchAtLoginProblemDisable:
            return "Could not disable launch at login: %@"
        case .launchAtLoginUnavailablePrefix:
            return "Launch at login is unavailable: %@"
        case .launchAtLoginUnknownState:
            return "macOS reported an unknown login-item state."
        case .launchAtLoginNeedsApproval:
            return "Launch at login needs approval in System Settings \u{203A} General \u{203A} Login Items."

        // Runtime Failures and Status Bar Notices
        case .failureAccessibilityPermission:
            return "Copied to the clipboard. CopyQmac needs Accessibility permission to paste automatically. In System Settings ▸ Privacy & Security ▸ Accessibility, switch CopyQmac on. CopyQmac is signed locally, so every rebuild is a new binary: if CopyQmac is already listed there, select it, remove it with \u{2212}, then add /Applications/CopyQmac.app back with + (or use the Open System Settings\u{2026} button on this message). The entry is ready for a manual \u{2318}V."
        case .failureAccessibilityPermissionStaleGrant:
            return "Copied to the clipboard. CopyQmac needs Accessibility permission to paste automatically, but macOS still treats this build as untrusted even though System Settings may show CopyQmac switched on: that switch belongs to an older binary. In System Settings ▸ Privacy & Security ▸ Accessibility, select CopyQmac, remove it with \u{2212}, then add /Applications/CopyQmac.app back with + (or use the Open System Settings\u{2026} button on this message), then return to the app. The entry is ready for a manual \u{2318}V."
        case .failureFocusPreviousApp:
            return "Could not focus the previous app."
        case .failureActivatePreviousApp:
            return "Could not activate the previous app."
        case .failureActivatePreviousAppOrPaste:
            return "Could not activate the previous app or send the paste command."
        case .failureNoPlainTextToPaste:
            return "This entry has no text to paste as plain text."
        case .failureClipboardNoText:
            return "The clipboard has no text to paste as plain text."
        case .failurePastePrefix:
            return "Paste failed: %@"
        case .failureUnsupportedEditText:
            return "This item shows an image or files instead of text. Add a note to describe it."
        case .failureEntryNoLongerExists:
            return "The item no longer exists."
        case .failureMultipleItemsEditText:
            return "This item holds more than one item and cannot be edited as styled text."
        case .failureTabNoLongerExists:
            return "That tab no longer exists."
        case .failureDestinationTabNoLongerExists:
            return "The destination tab no longer exists."
        case .failureEditingEntryRemovedByResultsSaved:
            return "The entry being edited was removed by the current results; its note was saved."
        case .failureEditingEntryRemovedByHistoryLimitSaved:
            return "The entry being edited was removed by the history limit; its note was saved."
        case .failureEditingEntryRemovedByResultsDraftPrefix:
            return "The entry being edited was removed by the current results; its draft could not be saved and remains available for retry: %@"
        case .failureEditingEntryRemovedByHistoryLimitDraftPrefix:
            return "The entry being edited was removed by the history limit; its draft could not be saved and remains available for retry: %@"
        case .failureDeleteEntriesPrefix:
            return "Could not delete the selected entries: %@"
        case .failureSyncEditPrefix:
            return "Saved the item, but could not update its sync folder: %@"
        case .failureSyncWriterProtected:
            return "Refusing write: target directory is protected."
        case .failureSyncWriterProtectedPrefix:
            return "Refusing write: target directory is protected: %@"
        case .failureSyncWriterTargetMissing:
            return "Target directory does not exist or is not a directory."
        case .failureSyncWriterWritePrefix:
            return "Could not write the item's files: %@"
        case .failureSyncWriterRewritePrefix:
            return "Could not rewrite the item's files: %@"
        case .failureSyncWriterTrashGroupPrefix:
            return "Could not move the extra sync group to the trash: %@"
        case .failureSyncWriteBackPrefix:
            return "Write-back failed: %@"
        case .failureSyncTrashInsideFolderPrefix:
            return "Refusing to move sync files into a trash folder inside the sync folder: %@"
        case .failureSyncTrashUnsafeRootPrefix:
            return "Refusing to empty an unsafe trash directory: %@"
        case .failureImportNotArchivePrefix:
            return "Not a .cpq archive or sync directory: %@"
        case .failureImportAmbiguousFolder:
            return "Skipped %@: multiple tabs claim this sync folder: %@"
        case .failureBackupNoTab:
            return "There is no tab %@ to export"
        case .failureBackupNoTabs:
            return "There are no tabs to export"
        case .failureBackupProtectedPathPrefix:
            return "Refusing dry-run export into protected CopyQ or Syncthing directory: %@"
        case .failureResyncNoTab:
            return "The tab with id %@ no longer exists."
        case .failureResyncNoSyncFolder:
            return "The tab \u{201C}%@\u{201D} has no sync folder configured."
        case .failureResyncAmbiguousFolder:
            return "Several tabs claim the sync folder %@: %@. Fix the tab folders before comparing."
        case .failureResyncFolderMissingPrefix:
            return "The sync folder does not exist: %@"
        case .failureResyncFolderUnreadable:
            return "Could not read %@: %@"
        case .failureResyncFolderChanged:
            return "The tab's sync folder changed from %@ to %@ after the report. Compare the tab again before applying."
        case .failureResyncPaused:
            return "Sync is paused, so \u{201C}%@\u{201D} cannot be resynced. Resume sync first."
        case .failureTrimDestinationPrefix:
            return "Could not trim the destination tab: %@"
        case .failureSyncPausedMove:
            return "Sync is paused. Resume sync before moving items out of a synced tab."
        case .failureDestinationFolderUnavailablePrefix:
            return "The destination sync folder is not available: %@"
        case .failureLoadClipboardStorePrefix:
            return "Could not load the clipboard store: %@"
        case .failureReadHistoryPrefix:
            return "Could not read history: %@"
        case .failureAddTabPrefix:
            return "Could not add the tab: %@"
        case .failureUpdateTabPrefix:
            return "Could not update the tab: %@"
        case .failureRemoveTabPrefix:
            return "Could not remove the tab: %@"
        case .failureReorderTabPrefix:
            return "Could not reorder the tab: %@"
        case .failureSetDefaultTabPrefix:
            return "Could not set the default tab: %@"
        case .failureClearTabPrefix:
            return "Could not clear the tab: %@"
        case .failureSavePreferencesPrefix:
            return "Could not save preferences: %@"
        case .failureUpdatePinPrefix:
            return "Could not update the pin: %@"
        case .failureDeleteEntryPrefix:
            return "Could not delete the entry: %@"
        case .failureMoveItemToTopPrefix:
            return "Could not move the item to the top: %@"
        case .failureReorderItemsPrefix:
            return "Could not reorder the items: %@"
        case .failureSaveNoteDraftPrefix:
            return "Could not save the note; its draft remains available for retry: %@"
        case .failureSaveItemPrefix:
            return "Could not save the item: %@"
        case .failureMoveItemsToTabPrefix:
            return "Could not move the items to \u{201C}%@\u{201D}: %@"
        case .failureImportPrefix:
            return "Import failed: %@"
        case .failureBackupPrefix:
            return "Backup failed: %@"
        case .failureSyncFolderTabNoLongerExists:
            return "Could not set the sync folder: the tab it was picked for no longer exists."
        case .failureSyncFolderAlreadyHasOnePrefix:
            return "Could not set the sync folder: '%@' already has one."
        case .failureSetSyncFolderPrefix:
            return "Could not set the sync folder: %@"
        case .failureSyncFoldersImportPrefix:
            return "Sync folders import failed: %@"
        case .failureCompareTabSyncPrefix:
            return "Could not compare the tab with its sync folder: %@"
        case .failureResyncTabSyncPrefix:
            return "Could not resync the tab with its sync folder: %@"
        case .failureReconcileSyncFoldersPrefix:
            return "Could not reconcile sync folders: %@"
        case .failureEmptySyncTrashPrefix:
            return "Could not empty the sync trash: %@"
        case .failureRemoveInternalMarkersPrefix:
            return "Could not remove internal marker entries: %@"
        case .failureCheckInternalMarkersPrefix:
            return "Could not check internal marker entries: %@"

        // File Panels
        case .filePanelImportCopyQTitle:
            return "Import from CopyQ"
        case .filePanelImportPrompt:
            return "Import"
        case .filePanelChooseSyncFolderTitle:
            return "Choose Sync Folder"
        case .filePanelChoosePrompt:
            return "Choose"
        case .filePanelExportBackupTitle:
            return "Export Backup"
        case .filePanelExportCurrentTabTitle:
            return "Export Current Tab"
        case .filePanelExportPrompt:
            return "Export"
        case .filePanelExportBackupMessage:
            return "Write every tab to a CopyQ .cpq archive."
        case .filePanelExportCurrentTabMessage:
            return "Write this tab to a CopyQ .cpq archive."

        // Dialog buttons
        case .buttonOK:
            return "OK"
        case .buttonCancel:
            return "Cancel"
        case .buttonChooseFolder:
            return "Choose Folder\u{2026}"
        case .buttonRemove:
            return "Remove"
        case .buttonMove:
            return "Move"
        case .buttonApply:
            return "Apply"
        case .buttonApplyChanges:
            return "Apply Changes\u{2026}"
        case .buttonOpenPreferences:
            return "Open Preferences"
        case .buttonLater:
            return "Later"
        case .buttonReportOnly:
            return "Report Only"
        case .buttonReconcile:
            return "Reconcile"
        case .buttonEmptyTrash:
            return "Empty Trash"

        // Destructive Confirmation Dialogs
        case .dialogClearTabTitle:
            return "Clear Tab"
        case .dialogClearTabInformativeSingle:
            return "Clearing this tab will also delete its sync files in \u{201C}%@\u{201D} (%d file)."
        case .dialogClearTabInformativePlural:
            return "Clearing this tab will also delete its sync files in \u{201C}%@\u{201D} (%d files)."
        case .dialogRemoveItemsTitlePlural:
            return "Remove %d Items"
        case .dialogRemoveItemsInformative:
            return "This removes the selected items from the history. File groups owned by a tab with a sync folder are moved to the app trash first."
        case .dialogMoveToTabTitle:
            return "Move to \u{201C}%@\u{201D}"
        case .dialogMovePlanNoSyncFiles:
            return "No sync files will be moved or deleted."
        case .dialogMovePlanAction:
            return "The move will %@."
        case .dialogMovePlanJoiner:
            return " and "
        case .dialogMovePlanRewriteSingle:
            return "rewrite %d file group into the destination sync folder"
        case .dialogMovePlanRewritePlural:
            return "rewrite %d file groups into the destination sync folder"
        case .dialogMovePlanTrashSingle:
            return "move %d file group to the app trash because the destination tab does not write to a sync folder"
        case .dialogMovePlanTrashPlural:
            return "move %d file groups to the app trash because the destination tab does not write to a sync folder"
        case .dialogRemoveInternalMarkersTitle:
            return "Remove Internal-Marker Entries"
        case .dialogRemoveInternalMarkersInformative:
            return "This deletes shell entries that contain no real content. Total: %d. Single-marker shells: %d. Other payload-less entries: %d."

        // Sync Folder Dialogs
        case .dialogNoSyncFolderMappingTitle:
            return "No tab has a sync folder set"
        case .dialogSyncFolderImportAlert:
            return "Import Configured Sync Folders reads the folder each tab has set under Preferences \u{25B8} Tabs. No tab has one, so there is nothing to import. You can pick a folder now: it becomes the sync folder of \"%@\", and the items already in it are imported into that tab."
        case .dialogSyncFolderImportPicker:
            return "The chosen folder becomes the sync folder of \"%@\", and its existing items are imported into that tab."

        // Compare and Resync Dialogs
        case .dialogResyncCompareTitle:
            return "Compare \u{201C}%@\u{201D} with Sync Folder"
        case .dialogResyncPausedNote:
            return "Sync is paused, so nothing can be applied. Resume sync to resync."
        case .dialogResyncConflictsSingle:
            return "Resync will not resolve %d conflict on its own: %@."
        case .dialogResyncConflictsPlural:
            return "Resync will not resolve %d conflicts on its own: %@."
        case .dialogResyncFolderNote:
            return "Folder: %@. This report changes nothing; the second, separately confirmed Apply step is what writes."
        case .dialogResyncApplyTitle:
            return "Apply Resync to \u{201C}%@\u{201D}?"
        case .dialogResyncApplyIntro:
            return "This changes the tab's history from its sync folder. The folder itself is not rewritten:"
        case .dialogResyncApplyFolder:
            return "Folder: %@"
        case .dialogResyncApplyFooter:
            return "Removed entries are archived to the app trash and can be recovered; updates keep each entry's note and pin. Conflicts are reported, never resolved automatically."
        case .dialogResyncReportCounts:
            return "Matched by stem and content: %d. Content differences: %d. Entries with no file: %d. File stems with no entry: %d."
        case .dialogResyncReportUnresolvedSingle:
            return "%d entry has no usable folder content, including an internal-only stem, or unresolved historical identity."
        case .dialogResyncReportUnresolvedPlural:
            return "%d entries have no usable folder content, including an internal-only stem, or unresolved historical identity."
        case .dialogResyncReportUnreadableEntriesSingle:
            return "%d entry has a file that could not be decoded."
        case .dialogResyncReportUnreadableEntriesPlural:
            return "%d entries have a file that could not be decoded."
        case .dialogResyncReportUnreadableFilesSingle:
            return "%d file could not be read."
        case .dialogResyncReportUnreadableFilesPlural:
            return "%d files could not be read."
        case .dialogResyncReportSkippedStemsSingle:
            return "%d internal or empty file stem skipped."
        case .dialogResyncReportSkippedStemsPlural:
            return "%d internal or empty file stems skipped."
        case .dialogResyncPlanImportSingle:
            return "Import %d entry from file stems that have no entry."
        case .dialogResyncPlanImportPlural:
            return "Import %d entries from file stems that have no entry."
        case .dialogResyncPlanRemoveSingle:
            return "Remove %d entry whose files are gone, after archiving it to the app trash."
        case .dialogResyncPlanRemovePlural:
            return "Remove %d entries whose files are gone, after archiving each to the app trash."
        case .dialogResyncPlanUpdateSingle:
            return "Update %d entry to the folder's content, keeping the entry's note and pin."
        case .dialogResyncPlanUpdatePlural:
            return "Update %d entries to the folder's content, keeping each entry's note and pin."
        case .dialogResyncPlanConflictSingle:
            return "Leave %d conflict untouched: %@."
        case .dialogResyncPlanConflictPlural:
            return "Leave %d conflicts untouched: %@."
        case .dialogResyncConflictLocallyEdited:
            return "the entry has a local edit that has not reached the folder"
        case .dialogResyncConflictNoteOrPin:
            return "the folder item's note or pin differs from the entry's"
        case .dialogResyncConflictMultipleGroups:
            return "the entry owns several groups with different content"
        case .dialogResyncConflictUnrelatedHistory:
            return "the entry's ownership comes only from its creation time, so the file could be unrelated history"

        // Reconcile Dialog
        case .dialogReconcileTitle:
            return "Reconcile Sync Folders"
        case .dialogReconcileInSync:
            return "Everything is in sync. No missing files or orphan file groups were found."
        case .dialogReconcileIntro:
            return "This is a one-shot check; it never runs on launch."
        case .dialogReconcileFooter:
            return "Report Only leaves everything untouched. Reconcile moves missing-file entries to the app trash and imports orphan file groups."
        case .dialogReconcileTabLine:
            return "%@: entries without files: %d, file groups without entries: %d"
        case .dialogReconcileReportCounts:
            return "Entries without files: %d. File groups without entries: %d."
        case .dialogReconcileReportSkipped:
            return "Skipped ambiguous or unreadable folders: %@."
        case .dialogReconcileReportFailuresSingle:
            return "%d check failed."
        case .dialogReconcileReportFailuresPlural:
            return "%d checks failed."

        // Empty Sync Trash Dialog
        case .dialogEmptyTrashTitle:
            return "Empty Sync Trash"
        case .dialogTrashEmpty:
            return "The sync trash is empty."
        case .dialogEmptyTrashFooter:
            return "This permanently deletes the recovered files. It does not touch any sync folder."
        case .dialogTrashSummary:
            return "Trash batches: %d. Files: %d. Bytes: %lld."

        // Shortcut and Help Dialogs
        case .dialogShortcutUnavailableTitle:
            return "Global shortcut unavailable"
        case .dialogShortcutUnavailableInformative:
            return "%@ could not be registered, probably because another app already uses it. Choose a different shortcut in Preferences; you can still open the window from the menu-bar item."
        case .dialogHelpInformative:
            return "%@ shows and hides this window. Everything you copy is captured into the capture tab, and activating an item (a double click, Return, or Item \u{25B8} Activate) copies it and then does whatever History \u{25B8} Activation is set to."
        case .dialogFatalTitle:
            return "CopyQmac could not start"

        // Main Window: Tab strip
        case .tabBarNewTabHelp:
            return "New tab"
        case .tabChipCaptureHelp:
            return "Captures on this machine are written here"
        case .tabContextMoveLeft:
            return "Move Left"
        case .tabContextMoveRight:
            return "Move Right"
        case .tabContextMoveUp:
            return "Move Up"
        case .tabContextMoveDown:
            return "Move Down"
        case .tabContextCompareSyncFolder:
            return "Compare with Sync Folder\u{2026}"

        // Main Window: Filter bar and empty state
        case .filterItemsPlaceholder:
            return "Filter items"
        case .filterClearHelp:
            return "Clear filter"
        case .filterAllTabsToggle:
            return "All tabs"
        case .filterSearchAllTabsHelp:
            return "Search across every tab"
        case .emptyStateNoItems:
            return "No items in this tab yet"
        case .emptyStateNoMatches:
            return "No matching items"
        case .emptyStateCreateItem:
            return "Press \u{2318}N to create an item"

        // Main Window: Entry rows and their context menu
        case .rowNoteBadge:
            return "note"
        case .rowPinnedHelp:
            return "Pinned"
        case .rowDeleteHelp:
            return "Delete"
        case .rowNoPreview:
            return "(no preview)"
        case .rowMoreFiles:
            return "+ %d more"
        case .contextCopyToClipboard:
            return "Copy to Clipboard"

        // Main Window: Preview and note pane
        case .previewImageUnavailable:
            return "Image preview unavailable"
        case .previewSelectPrompt:
            return "Select an item to preview it"
        case .previewNoteLabel:
            return "Note"

        // Main Window: Layout B and Unified Toolbar
        case .scopePickerLabel:
            return "Search Scope"
        case .scopeCurrentTab:
            return "Current tab"
        case .scopeAllTabs:
            return "All tabs"
        case .inspectorToggleHelp:
            return "Toggle Inspector (\u{2325}\u{2318}I)"
        case .sidebarToggleHelp:
            return "Toggle Sidebar (\u{2303}\u{2318}S)"

        // Main Window: Text edit sheet and styled toolbar
        case .textEditTitleEdit:
            return "Edit Item"
        case .textEditTitleNew:
            return "New Item"
        case .textEditNewDetail:
            return "Adds a new item to the \u{201C}%@\u{201D} tab."
        case .textEditConfirmSave:
            return "Save"
        case .textEditConfirmAdd:
            return "Add"
        case .textEditEmptyWarning:
            return "Enter some text to save."
        case .textEditRichFormatError:
            return "This item contains formatting the styled editor cannot save. Undo it or remove it and try again."
        case .textEditPreviewFallbackHint:
            return "This item has no text flavour. Typing replaces its content with plain text; only image and file-URL payloads are kept."
        case .textEditFormattingFallbackHint:
            return "This item's formatting cannot be kept here. It opens as plain text, so saving will drop the formatting."
        case .kindText:
            return "text"
        case .kindHTML:
            return "HTML"
        case .kindRichText:
            return "rich text"
        case .kindImage:
            return "image"
        case .kindFiles:
            return "files"
        case .kindOther:
            return "other"
        case .richToolbarBold:
            return "Bold (\u{2318}B)"
        case .richToolbarItalic:
            return "Italic (\u{2318}I)"
        case .richToolbarUnderline:
            return "Underline (\u{2318}U)"
        case .richToolbarTextColour:
            return "Text colour"
        case .richToolbarDefaultColour:
            return "Default text colour (no colour)"
        case .richToolbarSize:
            return "Size"
        case .richToolbarTextSize:
            return "Text size"

        // Notices: window messages
        case .noticeSavedHiddenByFilter:
            return "Saved; hidden by the current filter."
        case .noticeImportingCopyQ:
            return "Importing CopyQ data\u{2026}"
        case .noticeImportingFilePrefix:
            return "Importing %@\u{2026}"
        case .noticeImportingConfiguredSyncFolders:
            return "Importing configured sync folders\u{2026}"
        case .noticeNoSyncFolderSet:
            return "No tab has a sync folder set."
        case .noticeImportCompletePrefix:
            return "Import complete: %@"
        case .noticeSyncFolderImportedPrefix:
            return "Sync folder imported: %@"
        case .noticeSyncFoldersImportedPrefix:
            return "Sync folders imported: %@"
        case .noticeInternalMarkerCleanupPrefix:
            return "Internal marker cleanup: %@"
        case .noticeBackupWrittenPrefix:
            return "Backup written: %@"
        case .noticeCopiedToClipboardNoTarget:
            return "Copied to the clipboard. Open the target app and press \u{2318}V."
        case .noticeKeptLocalVersionPrefix:
            return "Kept the local version of %@ because it is newer than the upstream edit."
        case .noticeKeptLocalVersionsPrefix:
            return "Kept the local versions of %@ because they are newer than the upstream edits."
        case .noticeRemovedEntryAfterRemoteDeletionPrefix:
            return "Removed the entry for %@ after it was deleted in the sync folder."
        case .noticeRemovedEntriesAfterRemoteDeletion:
            return "Removed %@ entries after their files were deleted in sync folders."
        case .noticeEmptiedTrashSingle:
            return "Emptied the sync trash (1 batch, %d files)."
        case .noticeEmptiedTrashPlural:
            return "Emptied the sync trash (%d batches, %d files)."

        // Notices: report summaries
        case .reportClauseJoiner:
            return ", "
        case .reportSentenceSeparator:
            return ". "
        case .reportTerminator:
            return "."
        case .importSummaryImported:
            return "%d imported"
        case .importSummaryUpdated:
            return "%d updated"
        case .importSummaryUpstreamSkipped:
            return "%d upstream-new skipped (%@)"
        case .importSummaryDuplicateSingle:
            return "%d skipped as duplicate"
        case .importSummaryDuplicatePlural:
            return "%d skipped as duplicates"
        case .importSummaryInternalSingle:
            return "%d skipped as internal bookkeeping item"
        case .importSummaryInternalPlural:
            return "%d skipped as internal bookkeeping items"
        case .importSummaryFailed:
            return "%d failed"
        case .importSummaryTabs:
            return "into [%@]"
        case .exportSummaryHead:
            return "%@, %@, %@"
        case .exportSummaryTabsSingle:
            return "%d tab"
        case .exportSummaryTabsPlural:
            return "%d tabs"
        case .exportSummaryItemsSingle:
            return "%d item"
        case .exportSummaryItemsPlural:
            return "%d items"
        case .exportSummaryRenamedSingle:
            return "%d duplicate tab name renamed"
        case .exportSummaryRenamedPlural:
            return "%d duplicate tab names renamed"
        case .exportSummaryPayloadCaveat:
            return "Captures with several pasteboard items keep only the first item's flavours; multi-file copies keep every path"
        case .exportSummarySyncDestination:
            return "The archive will sync to your other devices"
        case .markerCleanupNoEntries:
            return "No internal marker entries to delete."
        case .markerCleanupTabLine:
            return "%@: %d (%d single-marker, %d other payload-less)"
        case .markerCleanupTotalSingle:
            return "Total: %d entry deleted (%d single-marker, %d other payload-less)."
        case .markerCleanupTotalPlural:
            return "Total: %d entries deleted (%d single-marker, %d other payload-less)."
        case .relocationMovedSingle:
            return "Moved the item to the tab."
        case .relocationMovedPlural:
            return "Moved the items to the tab."
        case .relocationMovedAndSingle:
            return "Moved the item to the tab and %@."
        case .relocationMovedAndPlural:
            return "Moved the items to the tab and %@."
        case .relocationSyncGroupsSingle:
            return "moved %d sync file group"
        case .relocationSyncGroupsPlural:
            return "moved %d sync file groups"
        case .relocationTrashGroupsSingle:
            return "moved %d file group to the app trash"
        case .relocationTrashGroupsPlural:
            return "moved %d file groups to the app trash"
        case .reconcileResultRemovedSingle:
            return "%d missing-file entry moved to trash"
        case .reconcileResultRemovedPlural:
            return "%d missing-file entries moved to trash"
        case .reconcileResultImportedSingle:
            return "%d orphan file group imported"
        case .reconcileResultImportedPlural:
            return "%d orphan file groups imported"
        case .reconcileResultFailed:
            return "%d failed"
        case .resyncResultImportedSingle:
            return "Imported %d entry"
        case .resyncResultImportedPlural:
            return "Imported %d entries"
        case .resyncResultLinked:
            return "linked %d existing"
        case .resyncResultRemoved:
            return "removed %d (archived to the app trash)"
        case .resyncResultUpdated:
            return "updated %d"
        case .resyncResultConflictsSingle:
            return "left %d conflict untouched"
        case .resyncResultConflictsPlural:
            return "left %d conflicts untouched"
        case .resyncResultSkipped:
            return "%d skipped"
        case .watcherSummaryUpdatedInPlace:
            return "%d updated in place"
        case .watcherSummaryUpstreamDiscardedSingle:
            return "%d upstream edit discarded (local newer) (%@)"
        case .watcherSummaryUpstreamDiscardedPlural:
            return "%d upstream edits discarded (local newer) (%@)"
        case .watcherSummaryReassertedSingle:
            return "%d local version rewritten"
        case .watcherSummaryReassertedPlural:
            return "%d local versions rewritten"
        case .watcherSummaryReplacedSingle:
            return "%d local edit replaced by a newer upstream edit"
        case .watcherSummaryReplacedPlural:
            return "%d local edits replaced by a newer upstream edit"
        case .watcherSummaryWrittenByUs:
            return "%d skipped (written by us)"
        case .watcherSummaryInternalOnly:
            return "%d skipped (internal bookkeeping only)"
        case .watcherSummaryIncomplete:
            return "%d incomplete"
        case .watcherSummaryPendingSettlement:
            return "%d pending settlement"
        case .watcherSummaryRemoteDeleted:
            return "%d removed after upstream deletion"
        case .watcherSummaryKeptLocallyEdited:
            return "%d kept (locally edited)"
        case .watcherSummaryPendingDeletionSettlement:
            return "%d pending deletion settlement"

        // Notices: resync and sync diagnostics
        case .diagnosticSkippedEntryGone:
            return "Skipped %@: the entry no longer exists."
        case .diagnosticSkippedNoIdentity:
            return "Skipped %@: the entry has no resolved sync identity."
        case .diagnosticKeptReason:
            return "Kept %@: %@."
        case .diagnosticKeptUnarchivedPayload:
            return "its payload could not be archived to the app trash"
        case .diagnosticFolderFileFailure:
            return "%@: %@"
        case .diagnosticFolderCannotResolvePath:
            return "cannot resolve path"
        case .diagnosticFolderPathEscapesRoot:
            return "resolved path escapes sync root"
        case .diagnosticFolderCannotReadFile:
            return "cannot read file: %@"
        case .diagnosticFolderFlavourFailure:
            return "flavour %@: %@"
        case .deletionCouldNotMoveBeforeReconciliation:
            return "Could not move %@ to the trash before reconciliation: %@"
        case .deletionCouldNotArchiveBeforeReconciliation:
            return "Could not archive %@ before reconciliation: %@"
        case .diagnosticCouldNotCheckLocalEdit:
            return "Could not check %@ for a pending local edit: %@"
        case .diagnosticSkippedGroupReappeared:
            return "Skipped %@: its group reappeared in the folder."
        case .diagnosticSkippedGroupBeingWritten:
            return "Skipped %@: its group is still being written."
        case .diagnosticCouldNotRemoveMissingEntries:
            return "Could not remove the entries whose files are gone: %@"
        case .diagnosticSkippedNotImportable:
            return "Skipped %@: it is no longer importable folder content."
        case .diagnosticSkippedAlreadyOwned:
            return "Skipped %@: an entry already owns it."
        case .diagnosticSkippedWrittenByApp:
            return "Skipped %@: this app wrote it and no entry owns it."
        case .diagnosticSkippedLocalEditPending:
            return "Skipped %@: the entry has a local edit that has not reached the folder."
        case .diagnosticSkippedFolderOlder:
            return "Skipped %@: the folder's version is older than the entry's."
        case .diagnosticSkippedNoContent:
            return "Skipped %@: it carries no content."
        case .diagnosticCouldNotImportStem:
            return "Could not import %@: %@"
        case .diagnosticSkippedFolderItemGone:
            return "Skipped %@: the folder item is gone."
        case .diagnosticSkippedAlreadyHasFolderContent:
            return "Skipped %@: the entry already has the folder's content."
        case .diagnosticCouldNotUpdateStem:
            return "Could not update %@: %@"
        case .diagnosticSkippedFile:
            return "Skipped %@: %@"
        }
    }

    /// Simplified Chinese (简体中文) translation value.
    public var simplifiedChinese: String {
        switch self {
        // Menu Bar: Top-level menus
        case .menuAppTitle:
            return "CopyQmac"
        case .menuFile:
            return "文件"
        case .menuEdit:
            return "编辑"
        case .menuItem:
            return "条目"
        case .menuTabs:
            return "标签页"
        case .menuHelp:
            return "帮助"

        // Menu Bar: CopyQmac (App Menu)
        case .menuAppAbout:
            return "关于 CopyQmac"
        case .menuAppPreferences:
            return "偏好设置\u{2026}"
        case .menuAppHide:
            return "隐藏 CopyQmac"
        case .menuAppHideOthers:
            return "隐藏其他"
        case .menuAppShowAll:
            return "显示全部"
        case .menuAppQuit:
            return "退出 CopyQmac"

        // Menu Bar: File
        case .menuFileNewTab:
            return "新建标签页"
        case .menuFileImportCopyQ:
            return "从 CopyQ 导入\u{2026}"
        case .menuFileImportSyncFolders:
            return "导入已配置的同步文件夹"
        case .menuFileReconcileSyncFolders:
            return "核对同步文件夹\u{2026}"
        case .menuFileEmptySyncTrash:
            return "清空同步废纸篓\u{2026}"
        case .menuFileExportBackup:
            return "导出备份\u{2026}"
        case .menuFileExportCurrentTab:
            return "导出当前标签页\u{2026}"
        case .menuFilePauseSync:
            return "暂停同步"
        case .menuFileResumeSync:
            return "恢复同步"
        case .menuFileHideWindow:
            return "隐藏窗口"

        // Menu Bar: Edit
        case .menuEditUndo:
            return "撤销"
        case .menuEditRedo:
            return "重做"
        case .menuEditCut:
            return "剪切"
        case .menuEditCopy:
            return "复制"
        case .menuEditPaste:
            return "粘贴"
        case .menuEditSelectAll:
            return "全选"
        case .menuEditFind:
            return "查找"

        // Menu Bar: Item
        case .menuItemNewItem:
            return "新建条目\u{2026}"
        case .menuItemEditItem:
            return "编辑条目\u{2026}"
        case .menuItemEditItemUseNote:
            return "编辑条目\u{2026}（使用编辑备注）"
        case .menuItemEditNote:
            return "编辑备注"
        case .menuItemActivate:
            return "激活"
        case .menuItemPin:
            return "固定"
        case .menuItemUnpin:
            return "取消固定"
        case .menuItemPasteAsPlainText:
            return "粘贴为纯文本"
        case .menuItemMoveUp:
            return "上移"
        case .menuItemMoveDown:
            return "下移"
        case .menuItemMoveToTop:
            return "移至顶部"
        case .menuItemMoveToBottom:
            return "移至底部"
        case .menuItemMoveToTab:
            return "移动到标签页"
        case .menuItemNoOtherTab:
            return "无其他标签页"
        case .menuItemRemove:
            return "移除"
        case .menuItemClearTab:
            return "清空标签页\u{2026}"
        case .menuItemRemoveInternalMarkerEntries:
            return "移除内部标记条目\u{2026}"

        // Menu Bar: Tabs
        case .menuTabsNewTab:
            return "新建标签页"
        case .menuTabsRenameTab:
            return "重命名标签页\u{2026}"
        case .menuTabsRemoveTab:
            return "移除标签页"
        case .menuTabsMoveTabLeft:
            return "向左移动标签页"
        case .menuTabsMoveTabRight:
            return "向右移动标签页"
        case .menuTabsMoveTabUp:
            return "上移标签页"
        case .menuTabsMoveTabDown:
            return "下移标签页"
        case .menuTabsUseAsCaptureTab:
            return "用作捕获标签页"

        // Menu Bar: Help
        case .menuHelpCopyQmacHelp:
            return "CopyQmac 帮助"

        // Status Item
        case .statusItemTooltip:
            return "CopyQmac 剪贴板历史 (%@)"
        case .statusItemShowCopyQmac:
            return "显示 CopyQmac"
        case .statusItemHideCopyQmac:
            return "隐藏 CopyQmac"
        case .statusItemAccessibilityDescription:
            return "剪贴板历史"
        case .statusItemAPIKeyNotSaved:
            return "API 密钥未保存"

        // Status Bar
        case .statusBarItemCountSingle:
            return "%d 个条目"
        case .statusBarItemCountPlural:
            return "%d 个条目"
        case .statusBarCaptureTab:
            return "捕获标签页: %@"
        case .statusBarTab:
            return "标签页: %@"
        case .statusBarDismissTooltip:
            return "%@\n点击关闭。"
        case .statusBarAccessibilityNotGranted:
            return "辅助功能权限未授予"
        case .statusBarAccessibilityHelp:
            return "自动粘贴到上一个应用程序时需要此权限。点击打开“系统设置 \u{25B8} 隐私与安全性 \u{25B8} 辅助功能”。"
        case .statusBarExportingBackup:
            return "正在导出备份\u{2026}"
        case .statusBarExportingItems:
            return "%@ / %@ 个条目\u{2026}"
        case .statusBarExportingTab:
            return "正在导出“%@”：%@"
        case .statusBarExportingMultiTab:
            return "正在导出标签页 %d/%d “%@”：%@"

        // Relative Time
        case .relativeTimeJustNow:
            return "刚刚"
        case .relativeTimeSecondsAgo:
            return "%d 秒前"
        case .relativeTimeMinutesAgo:
            return "%d 分钟前"
        case .relativeTimeHoursAgo:
            return "%d 小时前"
        case .relativeTimeYesterday:
            return "昨天"

        // Notice Banner controls
        case .bannerOpenSystemSettings:
            return "打开系统设置\u{2026}"
        case .bannerDismiss:
            return "关闭"
        case .bannerMessage:
            return "消息"

        // Settings Window: Window
        case .settingsWindowTitle:
            return "CopyQmac 偏好设置"

        // Settings Window: Tab items
        case .settingsTabHistory:
            return "历史记录"
        case .settingsTabTabs:
            return "标签页"
        case .settingsTabIgnoredApps:
            return "已忽略的应用"
        case .settingsTabShortcut:
            return "快捷键"

        // Settings Window: Appearance Section
        case .settingsSectionAppearance:
            return "外观"
        case .settingsThemeLabel:
            return "主题"
        case .settingsThemeSystem:
            return "跟随系统"
        case .settingsThemeLight:
            return "浅色"
        case .settingsThemeDark:
            return "深色"
        case .settingsThemeDetail:
            return "选择 CopyQmac 跟随系统外观，或固定为浅色或深色外观。"
        case .settingsWindowLayoutLabel:
            return "窗口布局"
        case .settingsWindowLayoutTopTabs:
            return "顶部标签页"
        case .settingsWindowLayoutSidebarInspector:
            return "侧边栏与检查器"
        case .settingsWindowLayoutDetail:
            return "选择经典的顶部标签页布局，或带有检查器的侧边栏布局。"

        // Settings Window: Language Section
        case .settingsSectionLanguage:
            return "语言"
        case .settingsLanguageLabel:
            return "界面语言"
        case .settingsLanguageDetail:
            return "选择菜单、对话框、状态栏和设置的语言。"

        // Settings Window: Font Section
        case .settingsSectionFonts:
            return "字体"
        case .settingsItemListFontLabel:
            return "条目列表"
        case .settingsItemListFontDetail:
            return "历史记录列表绘制条目所用的字体。条目文本自带字体时仍使用自带字体，富文本条目的字体不会被覆盖。选择“系统”时使用系统字体。"
        case .settingsEditorFontLabel:
            return "编辑器"
        case .settingsEditorFontDetail:
            return "选择字体后，新输入的文本使用该基础字体：起始位置的首个字符以及清空内容后输入的文本。在已有文本中继续输入时沿用该文本的字体。“系统”加字号时，纯文本编辑器使用真实系统字体，富文本编辑器则使用应用默认的书写字体，因为富文本条目无法保存系统字体。"
        case .settingsFontFamilyLabel:
            return "字体家族"
        case .settingsFontSystemOption:
            return "系统"
        case .settingsFontSizeLabel:
            return "字号"

        // Settings Window: History Tab
        case .settingsMaxItemsLabel:
            return "每个标签页的最大条目数"
        case .settingsMaxItemsDetail:
            return "此限制适用于每个标签页。已固定的条目绝不会被移除。"
        case .settingsSearchAllTabsToggle:
            return "搜索所有标签页"
        case .settingsSearchAllTabsDetail:
            return "关闭时，筛选仅搜索当前正在查看的标签页。"
        case .settingsActivationSection:
            return "激活"
        case .settingsActivationSingleClick:
            return "单击即可激活"
        case .settingsActivationSingleClickDetail:
            return "关闭时，单击仅选中条目；按 Return 键或双击可激活条目。"
        case .settingsActivationPaste:
            return "粘贴到上一个应用程序"
        case .settingsActivationPasteDetail:
            return "激活始终将条目复制到剪贴板，然后进行粘贴。若未授予辅助功能权限，则仅复制条目并显示提示说明原因。"
        case .settingsActivationFocus:
            return "聚焦上一个应用程序"
        case .settingsActivationFocusDetail:
            return "粘贴操作已会自动聚焦上一个应用程序，因此仅在关闭粘贴时此项生效。"
        case .settingsActivationCloseWindow:
            return "关闭主窗口"
        case .settingsActivationCloseWindowDetail:
            return "当未完成传递时窗口保持打开。若未授予辅助功能权限，状态栏将一直保留权限提醒直至获得授权；粘贴或聚焦失败的提示将一直保留直到您手动关闭。若没有目标应用程序，则仅显示复制提示。"
        case .settingsActivationMoveToTop:
            return "将条目移至顶部"
        case .settingsActivationMoveToTopDetail:
            return "将已激活的条目移动到其标签页的顶部。"
        case .settingsLaunchAtLoginToggle:
            return "登录时启动 CopyQmac"
        case .settingsLaunchAtLoginEnabledDetail:
            return "登录时 CopyQmac 会在菜单栏中运行。"
        case .settingsLaunchAtLoginDisabledDetail:
            return "CopyQmac 保持关闭状态，直到您手动打开。"
        case .settingsLaunchAtLoginApprovalDetail:
            return "macOS 需要您在“系统设置 \u{203A} 通用 \u{203A} 登录项”中批准后，CopyQmac 才能在登录时启动。"
        case .settingsOpenLoginItemsButton:
            return "打开登录项\u{2026}"
        case .settingsStoredItemsLabel:
            return "已存储条目"

        // Settings Window: Tabs Tab
        case .settingsCaptureTabHeader:
            return "捕获标签页"
        case .settingsCaptureTabPickerLabel:
            return "此设备上的捕获内容写入至："
        case .settingsSyncFolderBehaviorDetail:
            return "包含同步文件夹的标签页始终双向同步：捕获和编辑内容将写入文件夹，传入其中的条目也会被导入。"
        case .settingsPauseSyncToggle:
            return "暂停同步"
        case .settingsPauseSyncDetail:
            return "立即停止所有文件夹写入和监控操作。"
        case .settingsTabsListHeader:
            return "标签页"
        case .settingsTabCaptureBadge:
            return "捕获"
        case .settingsTabRenameButton:
            return "重命名\u{2026}"
        case .settingsTabRemoveHelp:
            return "移除此标签页及其条目"
        case .settingsTabSyncFolderLabel:
            return "同步文件夹"
        case .settingsTabSyncFolderPlaceholder:
            return "~/Syncthing/Config/CopyQ/<标签页>"
        case .settingsTabSyncFolderLocalDetail:
            return "无同步文件夹：此标签页保留在本地。"
        case .settingsTabSyncFolderSyncingDetail:
            return "此标签页与其文件夹双向同步。在上方区域中暂停同步可停止同步。"
        case .settingsAddTabButton:
            return "添加标签页"
        case .settingsTabReorderDetail:
            return "可通过主窗口中的标签页上下文菜单调整顺序。"

        // Settings Window: Ignored Apps Tab
        case .settingsIgnoredAppsExplanation:
            return "如果自上次剪贴板检查以来此列表中的应用程序处于最前端，或者在时间窗口内未观察到任何应用程序，则会跳过捕获。CopyQmac 本身算作已观察到的应用程序。源应用程序标记为专用的捕获内容始终会被跳过。"
        case .settingsIgnoredAppsHeader:
            return "已忽略的应用"
        case .settingsNoAppsIgnored:
            return "未忽略任何应用程序。"
        case .settingsIgnoreAppToggle:
            return "忽略 %@"
        case .settingsIgnoreAppHelp:
            return "忽略 %@"
        case .settingsStopIgnoringAppHelp:
            return "停止忽略 %@"
        case .settingsRemoveAppHelp:
            return "从列表中移除 %@"
        case .settingsAddAppHeader:
            return "添加应用"
        case .settingsAddLastAppButton:
            return "添加上一个应用"
        case .settingsLastAppObserved:
            return "上一个应用：%@ (%@)"
        case .settingsLastAppNone:
            return "在其他应用程序中复制内容，然后返回此处进行添加。"
        case .settingsAPIKeyGuardToggle:
            return "不保存在此 Mac 上复制的 AI 服务 API 密钥"
        case .settingsAPIKeyGuardDetail:
            return "仅适用于在此 Mac 上进行的复制：在此复制的密钥不会被保存，但无法保证绝不遗漏。历史记录中已有的密钥会保留，复制和粘贴仍然照常可用，来自同步文件夹的条目不会被过滤。"

        // Settings Window: Shortcut Tab
        case .settingsPlainTextShortcutHeader:
            return "粘贴为纯文本快捷键：%@"
        case .settingsRecordLabel:
            return "录制"
        case .settingsPlainTextShortcutDetail:
            return "当 CopyQmac 窗口打开时，此快捷键将所选条目作为纯文本粘贴。当 CopyQmac 仅在菜单栏中时，它会去除剪贴板中的格式并将该文本粘贴到最前面的应用程序中。"
        case .settingsSummonShortcutHeader:
            return "呼出快捷键：%@"
        case .settingsPresetLabel:
            return "预设"
        case .settingsPresetCustom:
            return "自定义"
        case .settingsShortcutRecordDetail:
            return "点击输入框并按下新的快捷键。每个快捷键必须包含至少一个修饰键且两者不能相同。如果系统因其他应用程序已占用该组合而拒绝，此处将显示警告。"
        case .settingsRecordPrompt:
            return "按下快捷键\u{2026}"
        case .settingsShortcutModifierProblem:
            return "请选择至少包含一个修饰键的快捷键。"
        case .settingsShortcutConflictProblem:
            return "%@ 与呼出快捷键冲突。请选择其他快捷键。"
        case .settingsShortcutUnavailableProblem:
            return "%@ 无法注册。可能已有其他应用程序使用该快捷键；请选择其他快捷键。"

        // Shortcut labels
        case .hotKeySpace:
            return "空格"
        case .hotKeyKeyPrefix:
            return "键 %@"

        // Rename Tab Alert
        case .alertRenameTabTitle:
            return "重命名标签页"
        case .alertRenameTabPlaceholder:
            return "标签页名称"
        case .alertRenameTabConfirm:
            return "重命名"
        case .alertRenameTabCancel:
            return "取消"
        case .alertRenameTabMessage:
            return "为该标签页选取一个名称。"

        // Launch at login runtime messages
        case .launchAtLoginProblemEnable:
            return "无法启用登录时启动：%@"
        case .launchAtLoginProblemDisable:
            return "无法禁用登录时启动：%@"
        case .launchAtLoginUnavailablePrefix:
            return "登录时启动不可用：%@"
        case .launchAtLoginUnknownState:
            return "macOS 报告了未知的登录项状态。"
        case .launchAtLoginNeedsApproval:
            return "登录时启动需要在“系统设置 › 通用 › 登录项”中批准。"

        // Runtime Failures and Status Bar Notices
        case .failureAccessibilityPermission:
            return "已拷贝到剪贴板。CopyQmac 需要辅助功能权限才能自动粘贴。请在“系统设置 ▸ 隐私与安全性 ▸ 辅助功能”中开启 CopyQmac。CopyQmac 为本地签名，每次重新构建都是新的二进制文件：如果其中已列出 CopyQmac，请选中它，点击 \u{2212} 移除，然后点击 + 重新添加 /Applications/CopyQmac.app（或使用此消息上的“打开系统设置…”按钮）。该条目已就绪，可手动使用 \u{2318}V 粘贴。"
        case .failureAccessibilityPermissionStaleGrant:
            return "已拷贝到剪贴板。CopyQmac 需要辅助功能权限才能自动粘贴，但 macOS 仍将此构建视为不受信任，即使系统设置中可能显示 CopyQmac 已开启：该开关属于旧的二进制文件。请在“系统设置 ▸ 隐私与安全性 ▸ 辅助功能”中选中 CopyQmac，点击 \u{2212} 移除，然后点击 + 重新添加 /Applications/CopyQmac.app（或使用此消息上的“打开系统设置…”按钮），然后返回应用。该条目已就绪，可手动使用 \u{2318}V 粘贴。"
        case .failureFocusPreviousApp:
            return "无法聚焦上一个应用程序。"
        case .failureActivatePreviousApp:
            return "无法激活上一个应用程序。"
        case .failureActivatePreviousAppOrPaste:
            return "无法激活上一个应用程序或发送粘贴命令。"
        case .failureNoPlainTextToPaste:
            return "该条目没有可作为纯文本粘贴的文本。"
        case .failureClipboardNoText:
            return "剪贴板没有可作为纯文本粘贴的文本。"
        case .failurePastePrefix:
            return "粘贴失败：%@"
        case .failureUnsupportedEditText:
            return "该条目显示的是图片或文件而不是文本。请添加备注进行说明。"
        case .failureEntryNoLongerExists:
            return "该条目已不存在。"
        case .failureMultipleItemsEditText:
            return "该条目包含多个项目，无法作为样式文本编辑。"
        case .failureTabNoLongerExists:
            return "该标签页已不存在。"
        case .failureDestinationTabNoLongerExists:
            return "目标标签页已不存在。"
        case .failureEditingEntryRemovedByResultsSaved:
            return "正在编辑的条目已被当前结果移除；其备注已保存。"
        case .failureEditingEntryRemovedByHistoryLimitSaved:
            return "正在编辑的条目已被历史记录上限移除；其备注已保存。"
        case .failureEditingEntryRemovedByResultsDraftPrefix:
            return "正在编辑的条目已被当前结果移除；其草稿无法保存，仍可重试：%@"
        case .failureEditingEntryRemovedByHistoryLimitDraftPrefix:
            return "正在编辑的条目已被历史记录上限移除；其草稿无法保存，仍可重试：%@"
        case .failureDeleteEntriesPrefix:
            return "无法删除所选条目：%@"
        case .failureSyncEditPrefix:
            return "已保存条目，但无法更新其同步文件夹：%@"
        case .failureSyncWriterProtected:
            return "拒绝写入：目标目录受保护。"
        case .failureSyncWriterProtectedPrefix:
            return "拒绝写入：目标目录受保护：%@"
        case .failureSyncWriterTargetMissing:
            return "目标目录不存在或不是目录。"
        case .failureSyncWriterWritePrefix:
            return "无法写入条目的文件：%@"
        case .failureSyncWriterRewritePrefix:
            return "无法重写条目的文件：%@"
        case .failureSyncWriterTrashGroupPrefix:
            return "无法将额外的同步文件组移至废纸篓：%@"
        case .failureSyncWriteBackPrefix:
            return "写回失败：%@"
        case .failureSyncTrashInsideFolderPrefix:
            return "拒绝将同步文件移入同步文件夹内的废纸篓：%@"
        case .failureSyncTrashUnsafeRootPrefix:
            return "拒绝清空不安全的废纸篓目录：%@"
        case .failureImportNotArchivePrefix:
            return "不是 .cpq 归档或同步文件夹：%@"
        case .failureImportAmbiguousFolder:
            return "已跳过 %@：多个标签页使用同一同步文件夹：%@"
        case .failureBackupNoTab:
            return "没有可导出的标签页 %@"
        case .failureBackupNoTabs:
            return "没有可导出的标签页"
        case .failureBackupProtectedPathPrefix:
            return "拒绝将试运行导出写入受保护的 CopyQ 或 Syncthing 目录：%@"
        case .failureResyncNoTab:
            return "ID 为 %@ 的标签页已不存在。"
        case .failureResyncNoSyncFolder:
            return "标签页“%@”未配置同步文件夹。"
        case .failureResyncAmbiguousFolder:
            return "多个标签页使用同一同步文件夹 %@：%@。请先修正标签页的文件夹再进行对比。"
        case .failureResyncFolderMissingPrefix:
            return "同步文件夹不存在：%@"
        case .failureResyncFolderUnreadable:
            return "无法读取 %@：%@"
        case .failureResyncFolderChanged:
            return "标签页的同步文件夹在报告生成后从 %@ 变为了 %@。请重新对比后再应用。"
        case .failureResyncPaused:
            return "同步已暂停，因此无法重新同步“%@”。请先恢复同步。"
        case .failureTrimDestinationPrefix:
            return "无法裁剪目标标签页：%@"
        case .failureSyncPausedMove:
            return "同步已暂停。请先恢复同步，再将条目移出同步标签页。"
        case .failureDestinationFolderUnavailablePrefix:
            return "目标同步文件夹不可用：%@"
        case .failureLoadClipboardStorePrefix:
            return "无法加载剪贴板存储：%@"
        case .failureReadHistoryPrefix:
            return "无法读取历史记录：%@"
        case .failureAddTabPrefix:
            return "无法添加标签页：%@"
        case .failureUpdateTabPrefix:
            return "无法更新标签页：%@"
        case .failureRemoveTabPrefix:
            return "无法移除标签页：%@"
        case .failureReorderTabPrefix:
            return "无法重排标签页：%@"
        case .failureSetDefaultTabPrefix:
            return "无法设置默认标签页：%@"
        case .failureClearTabPrefix:
            return "无法清空标签页：%@"
        case .failureSavePreferencesPrefix:
            return "无法保存偏好设置：%@"
        case .failureUpdatePinPrefix:
            return "无法更新固定状态：%@"
        case .failureDeleteEntryPrefix:
            return "无法删除条目：%@"
        case .failureMoveItemToTopPrefix:
            return "无法将条目置顶：%@"
        case .failureReorderItemsPrefix:
            return "无法重排条目：%@"
        case .failureSaveNoteDraftPrefix:
            return "无法保存备注；草稿仍可重试：%@"
        case .failureSaveItemPrefix:
            return "无法保存条目：%@"
        case .failureMoveItemsToTabPrefix:
            return "无法将条目移动到“%@”：%@"
        case .failureImportPrefix:
            return "导入失败：%@"
        case .failureBackupPrefix:
            return "备份失败：%@"
        case .failureSyncFolderTabNoLongerExists:
            return "无法设置同步文件夹：所选标签页已不存在。"
        case .failureSyncFolderAlreadyHasOnePrefix:
            return "无法设置同步文件夹：“%@”已拥有同步文件夹。"
        case .failureSetSyncFolderPrefix:
            return "无法设置同步文件夹：%@"
        case .failureSyncFoldersImportPrefix:
            return "同步文件夹导入失败：%@"
        case .failureCompareTabSyncPrefix:
            return "无法将标签页与其同步文件夹进行对比：%@"
        case .failureResyncTabSyncPrefix:
            return "无法重新同步标签页与其同步文件夹：%@"
        case .failureReconcileSyncFoldersPrefix:
            return "无法协调同步文件夹：%@"
        case .failureEmptySyncTrashPrefix:
            return "无法清空同步废纸篓：%@"
        case .failureRemoveInternalMarkersPrefix:
            return "无法移除内部标记条目：%@"
        case .failureCheckInternalMarkersPrefix:
            return "无法检查内部标记条目：%@"

        // File Panels
        case .filePanelImportCopyQTitle:
            return "从 CopyQ 导入"
        case .filePanelImportPrompt:
            return "导入"
        case .filePanelChooseSyncFolderTitle:
            return "选择同步文件夹"
        case .filePanelChoosePrompt:
            return "选择"
        case .filePanelExportBackupTitle:
            return "导出备份"
        case .filePanelExportCurrentTabTitle:
            return "导出当前标签页"
        case .filePanelExportPrompt:
            return "导出"
        case .filePanelExportBackupMessage:
            return "将所有标签页写入 CopyQ .cpq 归档。"
        case .filePanelExportCurrentTabMessage:
            return "将此标签页写入 CopyQ .cpq 归档。"

        // Dialog buttons
        case .buttonOK:
            return "好"
        case .buttonCancel:
            return "取消"
        case .buttonChooseFolder:
            return "选择文件夹\u{2026}"
        case .buttonRemove:
            return "移除"
        case .buttonMove:
            return "移动"
        case .buttonApply:
            return "应用"
        case .buttonApplyChanges:
            return "应用更改\u{2026}"
        case .buttonOpenPreferences:
            return "打开偏好设置"
        case .buttonLater:
            return "稍后"
        case .buttonReportOnly:
            return "仅报告"
        case .buttonReconcile:
            return "核对"
        case .buttonEmptyTrash:
            return "清空废纸篓"

        // Destructive Confirmation Dialogs
        case .dialogClearTabTitle:
            return "清空标签页"
        case .dialogClearTabInformativeSingle:
            return "清空此标签页还会删除其在“%@”中的同步文件（%d 个文件）。"
        case .dialogClearTabInformativePlural:
            return "清空此标签页还会删除其在“%@”中的同步文件（%d 个文件）。"
        case .dialogRemoveItemsTitlePlural:
            return "移除 %d 个条目"
        case .dialogRemoveItemsInformative:
            return "这将从历史记录中移除所选条目。由包含同步文件夹的标签页拥有的文件组会先移至应用废纸篓。"
        case .dialogMoveToTabTitle:
            return "移动到“%@”"
        case .dialogMovePlanNoSyncFiles:
            return "不会移动或删除任何同步文件。"
        case .dialogMovePlanAction:
            return "此次移动会%@。"
        case .dialogMovePlanJoiner:
            return "，并"
        case .dialogMovePlanRewriteSingle:
            return "将 %d 个文件组重写入目标同步文件夹"
        case .dialogMovePlanRewritePlural:
            return "将 %d 个文件组重写入目标同步文件夹"
        case .dialogMovePlanTrashSingle:
            return "将 %d 个文件组移至应用废纸篓（目标标签页不写入同步文件夹）"
        case .dialogMovePlanTrashPlural:
            return "将 %d 个文件组移至应用废纸篓（目标标签页不写入同步文件夹）"
        case .dialogRemoveInternalMarkersTitle:
            return "移除内部标记条目"
        case .dialogRemoveInternalMarkersInformative:
            return "这将删除不含真实内容的空壳条目。总计：%d 个。单标记空壳：%d 个。其他无内容条目：%d 个。"

        // Sync Folder Dialogs
        case .dialogNoSyncFolderMappingTitle:
            return "没有任何标签页设置了同步文件夹"
        case .dialogSyncFolderImportAlert:
            return "“导入已配置的同步文件夹”会读取每个标签页在“偏好设置 \u{25B8} 标签页”中设置的文件夹。没有标签页设置过，因此没有可导入的内容。您现在可以选择一个文件夹：它将成为“%@”的同步文件夹，其中已有的条目会导入该标签页。"
        case .dialogSyncFolderImportPicker:
            return "所选文件夹将成为“%@”的同步文件夹，其中已有的条目会导入该标签页。"

        // Compare and Resync Dialogs
        case .dialogResyncCompareTitle:
            return "将“%@”与其同步文件夹进行对比"
        case .dialogResyncPausedNote:
            return "同步已暂停，因此无法应用任何内容。请恢复同步后再重新同步。"
        case .dialogResyncConflictsSingle:
            return "重新同步无法自行解决 %d 个冲突：%@。"
        case .dialogResyncConflictsPlural:
            return "重新同步无法自行解决 %d 个冲突：%@。"
        case .dialogResyncFolderNote:
            return "文件夹：%@。此报告不会更改任何内容；只有另行确认的“应用”步骤才会写入。"
        case .dialogResyncApplyTitle:
            return "对“%@”应用重新同步？"
        case .dialogResyncApplyIntro:
            return "这会根据同步文件夹更改标签页的历史记录。文件夹本身不会被重写："
        case .dialogResyncApplyFolder:
            return "文件夹：%@"
        case .dialogResyncApplyFooter:
            return "移除的条目会归档到应用废纸篓并可以恢复；更新会保留每个条目的备注和固定状态。冲突只会被报告，绝不会自动解决。"
        case .dialogResyncReportCounts:
            return "按文件主名与内容匹配：%d 个。内容不同：%d 个。缺少文件的条目：%d 个。缺少条目的文件主名：%d 个。"
        case .dialogResyncReportUnresolvedSingle:
            return "%d 个条目没有可用的文件夹内容（包括仅含内部信息的主名），或无法解析历史身份。"
        case .dialogResyncReportUnresolvedPlural:
            return "%d 个条目没有可用的文件夹内容（包括仅含内部信息的主名），或无法解析历史身份。"
        case .dialogResyncReportUnreadableEntriesSingle:
            return "%d 个条目的文件无法解码。"
        case .dialogResyncReportUnreadableEntriesPlural:
            return "%d 个条目的文件无法解码。"
        case .dialogResyncReportUnreadableFilesSingle:
            return "%d 个文件无法读取。"
        case .dialogResyncReportUnreadableFilesPlural:
            return "%d 个文件无法读取。"
        case .dialogResyncReportSkippedStemsSingle:
            return "已跳过 %d 个内部或空文件主名。"
        case .dialogResyncReportSkippedStemsPlural:
            return "已跳过 %d 个内部或空文件主名。"
        case .dialogResyncPlanImportSingle:
            return "将导入 %d 个条目（来自缺少条目的文件主名）。"
        case .dialogResyncPlanImportPlural:
            return "将导入 %d 个条目（来自缺少条目的文件主名）。"
        case .dialogResyncPlanRemoveSingle:
            return "将移除 %d 个文件已丢失的条目（先归档到应用废纸篓）。"
        case .dialogResyncPlanRemovePlural:
            return "将移除 %d 个文件已丢失的条目（先归档到应用废纸篓）。"
        case .dialogResyncPlanUpdateSingle:
            return "将 %d 个条目更新为文件夹的内容，保留条目的备注和固定状态。"
        case .dialogResyncPlanUpdatePlural:
            return "将 %d 个条目更新为文件夹的内容，保留条目的备注和固定状态。"
        case .dialogResyncPlanConflictSingle:
            return "保留 %d 个冲突不做处理：%@。"
        case .dialogResyncPlanConflictPlural:
            return "保留 %d 个冲突不做处理：%@。"
        case .dialogResyncConflictLocallyEdited:
            return "该条目有尚未写入文件夹的本地编辑"
        case .dialogResyncConflictNoteOrPin:
            return "文件夹条目的备注或固定状态与条目不同"
        case .dialogResyncConflictMultipleGroups:
            return "该条目拥有多个内容不同的文件组"
        case .dialogResyncConflictUnrelatedHistory:
            return "该条目的归属仅来自其创建时间，因此该文件可能是无关的历史记录"

        // Reconcile Dialog
        case .dialogReconcileTitle:
            return "核对同步文件夹"
        case .dialogReconcileInSync:
            return "一切均已同步。未发现缺失文件或孤立文件组。"
        case .dialogReconcileIntro:
            return "这是一次性检查，绝不会在启动时运行。"
        case .dialogReconcileFooter:
            return "“仅报告”不会更改任何内容。“核对”会将缺少文件的条目移至应用废纸篓，并导入孤立的文件组。"
        case .dialogReconcileTabLine:
            return "%@：缺少文件的条目：%d 个，缺少条目的文件组：%d 个"
        case .dialogReconcileReportCounts:
            return "缺少文件的条目：%d 个。缺少条目的文件组：%d 个。"
        case .dialogReconcileReportSkipped:
            return "已跳过有歧义或无法读取的文件夹：%@。"
        case .dialogReconcileReportFailuresSingle:
            return "%d 项检查失败。"
        case .dialogReconcileReportFailuresPlural:
            return "%d 项检查失败。"

        // Empty Sync Trash Dialog
        case .dialogEmptyTrashTitle:
            return "清空同步废纸篓"
        case .dialogTrashEmpty:
            return "同步废纸篓为空。"
        case .dialogEmptyTrashFooter:
            return "这将永久删除已恢复的文件，不会影响任何同步文件夹。"
        case .dialogTrashSummary:
            return "废纸篓批次：%d 个。文件：%d 个。字节：%lld。"

        // Shortcut and Help Dialogs
        case .dialogShortcutUnavailableTitle:
            return "全局快捷键不可用"
        case .dialogShortcutUnavailableInformative:
            return "%@ 无法注册，可能是因为其他应用已在使用它。请在偏好设置中选择其他快捷键；您仍可通过菜单栏项目打开窗口。"
        case .dialogHelpInformative:
            return "%@ 显示或隐藏此窗口。您复制的所有内容都会捕获到捕获标签页；激活条目（双击、按 Return，或选择“条目 \u{25B8} 激活”）会复制该条目，然后执行“历史记录 \u{25B8} 激活”中设置的操作。"
        case .dialogFatalTitle:
            return "CopyQmac 无法启动"

        // Main Window: Tab strip
        case .tabBarNewTabHelp:
            return "新建标签页"
        case .tabChipCaptureHelp:
            return "此设备上的捕获内容写入此处"
        case .tabContextMoveLeft:
            return "向左移动"
        case .tabContextMoveRight:
            return "向右移动"
        case .tabContextMoveUp:
            return "上移"
        case .tabContextMoveDown:
            return "下移"
        case .tabContextCompareSyncFolder:
            return "与同步文件夹对比\u{2026}"

        // Main Window: Filter bar and empty state
        case .filterItemsPlaceholder:
            return "筛选条目"
        case .filterClearHelp:
            return "清除筛选"
        case .filterAllTabsToggle:
            return "所有标签页"
        case .filterSearchAllTabsHelp:
            return "在所有标签页中搜索"
        case .emptyStateNoItems:
            return "此标签页尚无条目"
        case .emptyStateNoMatches:
            return "无匹配条目"
        case .emptyStateCreateItem:
            return "按 \u{2318}N 创建条目"

        // Main Window: Entry rows and their context menu
        case .rowNoteBadge:
            return "备注"
        case .rowPinnedHelp:
            return "已固定"
        case .rowDeleteHelp:
            return "删除"
        case .rowNoPreview:
            return "（无预览）"
        case .rowMoreFiles:
            return "另 %d 个"
        case .contextCopyToClipboard:
            return "复制到剪贴板"

        // Main Window: Preview and note pane
        case .previewImageUnavailable:
            return "图像预览不可用"
        case .previewSelectPrompt:
            return "选择条目以预览"
        case .previewNoteLabel:
            return "备注"

        // Main Window: Layout B and Unified Toolbar
        case .scopePickerLabel:
            return "搜索范围"
        case .scopeCurrentTab:
            return "当前标签页"
        case .scopeAllTabs:
            return "所有标签页"
        case .inspectorToggleHelp:
            return "切换检查器 (\u{2325}\u{2318}I)"
        case .sidebarToggleHelp:
            return "切换侧边栏 (\u{2303}\u{2318}S)"

        // Main Window: Text edit sheet and styled toolbar
        case .textEditTitleEdit:
            return "编辑条目"
        case .textEditTitleNew:
            return "新建条目"
        case .textEditNewDetail:
            return "将新条目添加到“%@”标签页。"
        case .textEditConfirmSave:
            return "保存"
        case .textEditConfirmAdd:
            return "添加"
        case .textEditEmptyWarning:
            return "请输入要保存的文本。"
        case .textEditRichFormatError:
            return "该条目包含样式编辑器无法保存的格式。请撤销该操作，或移除条目后重试。"
        case .textEditPreviewFallbackHint:
            return "该条目没有文本格式。输入内容会用纯文本替换其内容；仅保留图像和文件 URL 负载。"
        case .textEditFormattingFallbackHint:
            return "该条目的格式无法在此保留。它将以纯文本打开，因此保存会丢弃格式。"
        case .kindText:
            return "文本"
        case .kindHTML:
            return "网页"
        case .kindRichText:
            return "富文本"
        case .kindImage:
            return "图像"
        case .kindFiles:
            return "文件"
        case .kindOther:
            return "其他"
        case .richToolbarBold:
            return "粗体（\u{2318}B）"
        case .richToolbarItalic:
            return "斜体（\u{2318}I）"
        case .richToolbarUnderline:
            return "下划线（\u{2318}U）"
        case .richToolbarTextColour:
            return "文字颜色"
        case .richToolbarDefaultColour:
            return "默认文字颜色（无颜色）"
        case .richToolbarSize:
            return "大小"
        case .richToolbarTextSize:
            return "文字大小"

        // Notices: window messages
        case .noticeSavedHiddenByFilter:
            return "已保存；被当前筛选隐藏。"
        case .noticeImportingCopyQ:
            return "正在导入 CopyQ 数据\u{2026}"
        case .noticeImportingFilePrefix:
            return "正在导入 %@\u{2026}"
        case .noticeImportingConfiguredSyncFolders:
            return "正在导入已配置的同步文件夹\u{2026}"
        case .noticeNoSyncFolderSet:
            return "没有标签页设置同步文件夹。"
        case .noticeImportCompletePrefix:
            return "导入完成：%@"
        case .noticeSyncFolderImportedPrefix:
            return "同步文件夹已导入：%@"
        case .noticeSyncFoldersImportedPrefix:
            return "同步文件夹已导入：%@"
        case .noticeInternalMarkerCleanupPrefix:
            return "内部标记清理：%@"
        case .noticeBackupWrittenPrefix:
            return "备份已写入：%@"
        case .noticeCopiedToClipboardNoTarget:
            return "已复制到剪贴板。请打开目标应用并按 \u{2318}V。"
        case .noticeKeptLocalVersionPrefix:
            return "保留了 %@ 的本地版本，因为它比上游编辑更新。"
        case .noticeKeptLocalVersionsPrefix:
            return "保留了 %@ 的本地版本，因为它们比上游编辑更新。"
        case .noticeRemovedEntryAfterRemoteDeletionPrefix:
            return "同步文件夹中的 %@ 已被删除，其对应条目也已移除。"
        case .noticeRemovedEntriesAfterRemoteDeletion:
            return "已移除 %@ 个条目，因为它们的文件在同步文件夹中被删除。"
        case .noticeEmptiedTrashSingle:
            return "已清空同步废纸篓（1 个批次，%d 个文件）。"
        case .noticeEmptiedTrashPlural:
            return "已清空同步废纸篓（%d 个批次，%d 个文件）。"

        // Notices: report summaries
        case .reportClauseJoiner:
            return "，"
        case .reportSentenceSeparator:
            return "。"
        case .reportTerminator:
            return "。"
        case .importSummaryImported:
            return "已导入 %d 个"
        case .importSummaryUpdated:
            return "已更新 %d 个"
        case .importSummaryUpstreamSkipped:
            return "已跳过 %d 个上游新内容（%@）"
        case .importSummaryDuplicateSingle:
            return "已跳过 %d 个重复项"
        case .importSummaryDuplicatePlural:
            return "已跳过 %d 个重复项"
        case .importSummaryInternalSingle:
            return "已跳过 %d 个内部记账条目"
        case .importSummaryInternalPlural:
            return "已跳过 %d 个内部记账条目"
        case .importSummaryFailed:
            return "%d 个失败"
        case .importSummaryTabs:
            return "导入至 [%@]"
        case .exportSummaryHead:
            return "%@，%@，%@"
        case .exportSummaryTabsSingle:
            return "%d 个标签页"
        case .exportSummaryTabsPlural:
            return "%d 个标签页"
        case .exportSummaryItemsSingle:
            return "%d 个条目"
        case .exportSummaryItemsPlural:
            return "%d 个条目"
        case .exportSummaryRenamedSingle:
            return "%d 个重名标签页已重命名"
        case .exportSummaryRenamedPlural:
            return "%d 个重名标签页已重命名"
        case .exportSummaryPayloadCaveat:
            return "包含多个剪贴板项目的捕获仅保留第一个项目的格式；多文件复制会保留每个路径"
        case .exportSummarySyncDestination:
            return "该归档将同步到您的其他设备"
        case .markerCleanupNoEntries:
            return "没有可删除的内部标记条目。"
        case .markerCleanupTabLine:
            return "%@：%d 个（%d 个单标记，%d 个其他无内容）"
        case .markerCleanupTotalSingle:
            return "总计：已删除 %d 个条目（%d 个单标记，%d 个其他无内容）。"
        case .markerCleanupTotalPlural:
            return "总计：已删除 %d 个条目（%d 个单标记，%d 个其他无内容）。"
        case .relocationMovedSingle:
            return "已将条目移动到标签页。"
        case .relocationMovedPlural:
            return "已将条目移动到标签页。"
        case .relocationMovedAndSingle:
            return "已将条目移动到标签页，并%@。"
        case .relocationMovedAndPlural:
            return "已将条目移动到标签页，并%@。"
        case .relocationSyncGroupsSingle:
            return "移动了 %d 个同步文件组"
        case .relocationSyncGroupsPlural:
            return "移动了 %d 个同步文件组"
        case .relocationTrashGroupsSingle:
            return "将 %d 个文件组移至应用废纸篓"
        case .relocationTrashGroupsPlural:
            return "将 %d 个文件组移至应用废纸篓"
        case .reconcileResultRemovedSingle:
            return "%d 个缺少文件的条目已移至废纸篓"
        case .reconcileResultRemovedPlural:
            return "%d 个缺少文件的条目已移至废纸篓"
        case .reconcileResultImportedSingle:
            return "已导入 %d 个孤立文件组"
        case .reconcileResultImportedPlural:
            return "已导入 %d 个孤立文件组"
        case .reconcileResultFailed:
            return "%d 个失败"
        case .resyncResultImportedSingle:
            return "已导入 %d 个条目"
        case .resyncResultImportedPlural:
            return "已导入 %d 个条目"
        case .resyncResultLinked:
            return "关联了 %d 个现有条目"
        case .resyncResultRemoved:
            return "移除了 %d 个（已归档到应用废纸篓）"
        case .resyncResultUpdated:
            return "更新了 %d 个"
        case .resyncResultConflictsSingle:
            return "保留了 %d 个冲突未处理"
        case .resyncResultConflictsPlural:
            return "保留了 %d 个冲突未处理"
        case .resyncResultSkipped:
            return "已跳过 %d 个"
        case .watcherSummaryUpdatedInPlace:
            return "原地更新了 %d 个"
        case .watcherSummaryUpstreamDiscardedSingle:
            return "丢弃了 %d 个上游编辑（本地更新）（%@）"
        case .watcherSummaryUpstreamDiscardedPlural:
            return "丢弃了 %d 个上游编辑（本地更新）（%@）"
        case .watcherSummaryReassertedSingle:
            return "重写了 %d 个本地版本"
        case .watcherSummaryReassertedPlural:
            return "重写了 %d 个本地版本"
        case .watcherSummaryReplacedSingle:
            return "%d 个本地编辑已被更新的上游编辑替换"
        case .watcherSummaryReplacedPlural:
            return "%d 个本地编辑已被更新的上游编辑替换"
        case .watcherSummaryWrittenByUs:
            return "已跳过 %d 个（由本应用写入）"
        case .watcherSummaryInternalOnly:
            return "已跳过 %d 个（仅内部记账）"
        case .watcherSummaryIncomplete:
            return "%d 个不完整"
        case .watcherSummaryPendingSettlement:
            return "%d 个待定"
        case .watcherSummaryRemoteDeleted:
            return "%d 个在上游删除后已移除"
        case .watcherSummaryKeptLocallyEdited:
            return "%d 个已保留（本地已编辑）"
        case .watcherSummaryPendingDeletionSettlement:
            return "%d 个待定删除"

        // Notices: resync and sync diagnostics
        case .diagnosticSkippedEntryGone:
            return "已跳过 %@：该条目已不存在。"
        case .diagnosticSkippedNoIdentity:
            return "已跳过 %@：该条目没有可解析的同步标识。"
        case .diagnosticKeptReason:
            return "保留了 %@：%@。"
        case .diagnosticKeptUnarchivedPayload:
            return "其内容无法归档到应用废纸篓"
        case .diagnosticFolderFileFailure:
            return "%@：%@"
        case .diagnosticFolderCannotResolvePath:
            return "无法解析路径"
        case .diagnosticFolderPathEscapesRoot:
            return "解析后的路径超出同步文件夹范围"
        case .diagnosticFolderCannotReadFile:
            return "无法读取文件：%@"
        case .diagnosticFolderFlavourFailure:
            return "格式 %@：%@"
        case .deletionCouldNotMoveBeforeReconciliation:
            return "无法在重新协调前将 %@ 移到废纸篓：%@"
        case .deletionCouldNotArchiveBeforeReconciliation:
            return "无法在重新协调前归档 %@：%@"
        case .diagnosticCouldNotCheckLocalEdit:
            return "无法检查 %@ 是否有待处理的本地编辑：%@"
        case .diagnosticSkippedGroupReappeared:
            return "已跳过 %@：其文件组重新出现在文件夹中。"
        case .diagnosticSkippedGroupBeingWritten:
            return "已跳过 %@：其文件组仍在写入。"
        case .diagnosticCouldNotRemoveMissingEntries:
            return "无法移除文件已丢失的条目：%@"
        case .diagnosticSkippedNotImportable:
            return "已跳过 %@：它已不再是可导入的文件夹内容。"
        case .diagnosticSkippedAlreadyOwned:
            return "已跳过 %@：已有条目拥有它。"
        case .diagnosticSkippedWrittenByApp:
            return "已跳过 %@：它由本应用写入且没有条目拥有它。"
        case .diagnosticSkippedLocalEditPending:
            return "已跳过 %@：该条目有尚未写入文件夹的本地编辑。"
        case .diagnosticSkippedFolderOlder:
            return "已跳过 %@：文件夹中的版本比条目的旧。"
        case .diagnosticSkippedNoContent:
            return "已跳过 %@：它不包含内容。"
        case .diagnosticCouldNotImportStem:
            return "无法导入 %@：%@"
        case .diagnosticSkippedFolderItemGone:
            return "已跳过 %@：文件夹中的项目已不存在。"
        case .diagnosticSkippedAlreadyHasFolderContent:
            return "已跳过 %@：该条目已包含文件夹中的内容。"
        case .diagnosticCouldNotUpdateStem:
            return "无法更新 %@：%@"
        case .diagnosticSkippedFile:
            return "已跳过 %@：%@"
        }
    }

    /// Resolves the string value for the given language.
    public func string(for language: AppLanguage) -> String {
        switch language {
        case .english:
            return english
        case .simplifiedChinese:
            return simplifiedChinese
        }
    }
}

/// Central localization resolver.
public enum Localization {
    /// Returns the localized string for a catalog key in the requested language.
    public static func string(_ key: CatalogKey, language: AppLanguage) -> String {
        key.string(for: language)
    }

    /// Returns a formatted string for a catalog key with positional format specifiers.
    public static func format(_ key: CatalogKey, language: AppLanguage, _ args: CVarArg...) -> String {
        format(key, language: language, arguments: args)
    }

    /// Returns a count-bearing sentence, choosing the singular catalog entry when the count is one.
    public static func formatCount(
        _ count: Int,
        _ singular: CatalogKey,
        _ plural: CatalogKey,
        language: AppLanguage,
        _ args: CVarArg...
    ) -> String {
        format(count == 1 ? singular : plural, language: language, arguments: args)
    }

    private static func format(_ key: CatalogKey, language: AppLanguage, arguments: [CVarArg]) -> String {
        let template = key.string(for: language)
        let locale = language.locale
        return String(format: template, locale: locale, arguments: arguments)
    }

    /// Formats a byte count with the interface language's units, for example
    /// "843 bytes" or "843字节".
    public static func byteCount(_ byteCount: Int64, language: AppLanguage) -> String {
        ByteCountFormatStyle(style: .file).locale(language.locale).format(byteCount)
    }

    /// Formats a line count with the interface language's units, for example
    /// "1 line" or "12 lines" ("1 行" or "12 行").
    public static func lineCount(_ count: Int, language: AppLanguage) -> String {
        switch language {
        case .english:
            return count == 1 ? "1 line" : "\(count) lines"
        case .simplifiedChinese:
            return "\(count) 行"
        }
    }

    /// Formats a file count with the interface language's units, for example
    /// "1 file" or "3 files" ("1 个文件" or "3 个文件").
    public static func fileCount(_ count: Int, language: AppLanguage) -> String {
        switch language {
        case .english:
            return count == 1 ? "1 file" : "\(count) files"
        case .simplifiedChinese:
            return "\(count) 个文件"
        }
    }

    /// Formatted status item tooltip: "CopyQmac clipboard history (⌥V)"
    public static func statusItemTooltip(hotkey: String, language: AppLanguage) -> String {
        format(.statusItemTooltip, language: language, hotkey)
    }

    /// Formatted status-bar item count: "1 item" / "5 items" / "5 个条目"
    public static func itemCount(_ count: Int, language: AppLanguage) -> String {
        switch language {
        case .english:
            let key: CatalogKey = count == 1 ? .statusBarItemCountSingle : .statusBarItemCountPlural
            return format(key, language: language, count)
        case .simplifiedChinese:
            return format(.statusBarItemCountSingle, language: language, count)
        }
    }

    /// The badge that names an entry's content kind in the item row.
    public static func contentKindLabel(_ kind: ClipboardContentKind, language: AppLanguage) -> String {
        let key: CatalogKey
        switch kind {
        case .text: key = .kindText
        case .html: key = .kindHTML
        case .rtf: key = .kindRichText
        case .image: key = .kindImage
        case .files: key = .kindFiles
        case .other: key = .kindOther
        }
        return string(key, language: language)
    }

    /// One sync folder file that could not be read, with its name kept verbatim.
    public static func folderFailure(
        _ failure: CopyQSyncFolder.Failure,
        language: AppLanguage
    ) -> String {
        format(
            .diagnosticFolderFileFailure,
            language: language,
            failure.fileName,
            folderFailureReason(failure.reason, language: language)
        )
    }

    /// Why one sync folder file could not be read, with any system error kept
    /// verbatim.
    public static func folderFailureReason(
        _ reason: CopyQSyncFolder.Failure.Reason,
        language: AppLanguage
    ) -> String {
        switch reason {
        case .cannotResolvePath:
            return string(.diagnosticFolderCannotResolvePath, language: language)
        case .pathEscapesSyncRoot:
            return string(.diagnosticFolderPathEscapesRoot, language: language)
        case .cannotReadFile(let detail):
            return format(.diagnosticFolderCannotReadFile, language: language, detail)
        case .flavour(let fileFormat, let detail):
            return format(.diagnosticFolderFlavourFailure, language: language, fileFormat, detail)
        case .systemError(let detail):
            return detail
        }
    }

    /// Joins report clauses with the language's own list separator.
    public static func joinedSummaryClauses(_ clauses: [String], language: AppLanguage) -> String {
        clauses.joined(separator: string(.reportClauseJoiner, language: language))
    }

    /// Joins report clauses into one sentence with the language's terminator.
    public static func joinedSummarySentence(_ clauses: [String], language: AppLanguage) -> String {
        joinedSummaryClauses(clauses, language: language) + string(.reportTerminator, language: language)
    }

    /// Formatted status-bar tab name label.
    public static func tabInfo(name: String, isDefault: Bool, language: AppLanguage) -> String {
        let key: CatalogKey = isDefault ? .statusBarCaptureTab : .statusBarTab
        return format(key, language: language, name)
    }

    /// Renders a stored shortcut label in the target language: modifier glyphs and
    /// typed characters are kept, the spoken key names are translated.
    public static func hotKeyLabel(_ label: String, language: AppLanguage) -> String {
        var rendered = label.replacingOccurrences(
            of: CatalogKey.hotKeySpace.english,
            with: CatalogKey.hotKeySpace.string(for: language)
        )
        let englishKeyPrefix = format(.hotKeyKeyPrefix, language: .english, "")
        if let range = rendered.range(of: englishKeyPrefix) {
            let number = rendered[range.upperBound...]
            if !number.isEmpty, number.allSatisfy(\.isNumber) {
                rendered.replaceSubrange(range, with: format(.hotKeyKeyPrefix, language: language, ""))
            }
        }
        return rendered
    }

    /// Translates runtime-produced messages (such as errors, failure records, or launch-at-login reasons)
    /// into the target language using catalog keys.
    public static func runtimeMessage(_ message: String, language: AppLanguage) -> String {
        guard language == .simplifiedChinese else { return message }

        let exactMap: [String: CatalogKey] = [
            CatalogKey.failureAccessibilityPermission.english: .failureAccessibilityPermission,
            CatalogKey.failureAccessibilityPermissionStaleGrant.english: .failureAccessibilityPermissionStaleGrant,
            CatalogKey.failureFocusPreviousApp.english: .failureFocusPreviousApp,
            CatalogKey.failureActivatePreviousApp.english: .failureActivatePreviousApp,
            CatalogKey.failureActivatePreviousAppOrPaste.english: .failureActivatePreviousAppOrPaste,
            CatalogKey.failureNoPlainTextToPaste.english: .failureNoPlainTextToPaste,
            CatalogKey.failureClipboardNoText.english: .failureClipboardNoText,
            CatalogKey.failureUnsupportedEditText.english: .failureUnsupportedEditText,
            CatalogKey.failureEntryNoLongerExists.english: .failureEntryNoLongerExists,
            CatalogKey.failureMultipleItemsEditText.english: .failureMultipleItemsEditText,
            CatalogKey.failureTabNoLongerExists.english: .failureTabNoLongerExists,
            CatalogKey.failureDestinationTabNoLongerExists.english: .failureDestinationTabNoLongerExists,
            CatalogKey.failureEditingEntryRemovedByResultsSaved.english: .failureEditingEntryRemovedByResultsSaved,
            CatalogKey.failureEditingEntryRemovedByHistoryLimitSaved.english: .failureEditingEntryRemovedByHistoryLimitSaved,
            CatalogKey.failureSyncPausedMove.english: .failureSyncPausedMove,
            CatalogKey.failureSyncWriterProtected.english: .failureSyncWriterProtected,
            CatalogKey.failureSyncWriterTargetMissing.english: .failureSyncWriterTargetMissing,
            CatalogKey.failureSyncFolderTabNoLongerExists.english: .failureSyncFolderTabNoLongerExists,
            CatalogKey.failureBackupNoTabs.english: .failureBackupNoTabs,
            CatalogKey.launchAtLoginUnknownState.english: .launchAtLoginUnknownState,
            CatalogKey.launchAtLoginNeedsApproval.english: .launchAtLoginNeedsApproval,
            CatalogKey.noticeSavedHiddenByFilter.english: .noticeSavedHiddenByFilter,
            CatalogKey.noticeImportingCopyQ.english: .noticeImportingCopyQ,
            CatalogKey.noticeImportingConfiguredSyncFolders.english: .noticeImportingConfiguredSyncFolders,
            CatalogKey.noticeNoSyncFolderSet.english: .noticeNoSyncFolderSet,
            CatalogKey.noticeCopiedToClipboardNoTarget.english: .noticeCopiedToClipboardNoTarget,
            CatalogKey.dialogResyncConflictLocallyEdited.english: .dialogResyncConflictLocallyEdited,
            CatalogKey.dialogResyncConflictNoteOrPin.english: .dialogResyncConflictNoteOrPin,
            CatalogKey.dialogResyncConflictMultipleGroups.english: .dialogResyncConflictMultipleGroups,
            CatalogKey.dialogResyncConflictUnrelatedHistory.english: .dialogResyncConflictUnrelatedHistory,
            CatalogKey.diagnosticKeptUnarchivedPayload.english: .diagnosticKeptUnarchivedPayload,
        ]
        if let key = exactMap[message] {
            return key.simplifiedChinese
        }

        // Common prefix matches
        let prefixMap: [(prefix: String, key: CatalogKey)] = [
            ("Could not enable launch at login: ", .launchAtLoginProblemEnable),
            ("Could not disable launch at login: ", .launchAtLoginProblemDisable),
            ("Launch at login is unavailable: ", .launchAtLoginUnavailablePrefix),
            ("Could not load the clipboard store: ", .failureLoadClipboardStorePrefix),
            ("Could not read history: ", .failureReadHistoryPrefix),
            ("Could not add the tab: ", .failureAddTabPrefix),
            ("Could not update the tab: ", .failureUpdateTabPrefix),
            ("Could not remove the tab: ", .failureRemoveTabPrefix),
            ("Could not reorder the tab: ", .failureReorderTabPrefix),
            ("Could not set the default tab: ", .failureSetDefaultTabPrefix),
            ("Could not clear the tab: ", .failureClearTabPrefix),
            ("Could not save preferences: ", .failureSavePreferencesPrefix),
            ("Could not update the pin: ", .failureUpdatePinPrefix),
            ("Could not delete the entry: ", .failureDeleteEntryPrefix),
            ("Could not delete the selected entries: ", .failureDeleteEntriesPrefix),
            ("Could not move the item to the top: ", .failureMoveItemToTopPrefix),
            ("Could not reorder the items: ", .failureReorderItemsPrefix),
            ("Could not save the note; its draft remains available for retry: ", .failureSaveNoteDraftPrefix),
            ("Could not save the item: ", .failureSaveItemPrefix),
            ("Saved the item, but could not update its sync folder: ", .failureSyncEditPrefix),
            ("Refusing write: target directory is protected: ", .failureSyncWriterProtectedPrefix),
            ("Could not write the item's files: ", .failureSyncWriterWritePrefix),
            ("Could not rewrite the item's files: ", .failureSyncWriterRewritePrefix),
            ("Could not move the extra sync group to the trash: ", .failureSyncWriterTrashGroupPrefix),
            ("Write-back failed: ", .failureSyncWriteBackPrefix),
            ("Refusing to move sync files into a trash folder inside the sync folder: ", .failureSyncTrashInsideFolderPrefix),
            ("Refusing to empty an unsafe trash directory: ", .failureSyncTrashUnsafeRootPrefix),
            ("Not a .cpq archive or sync directory: ", .failureImportNotArchivePrefix),
            ("Refusing dry-run export into protected CopyQ or Syncthing directory: ", .failureBackupProtectedPathPrefix),
            ("The sync folder does not exist: ", .failureResyncFolderMissingPrefix),
            ("Could not trim the destination tab: ", .failureTrimDestinationPrefix),
            ("The destination sync folder is not available: ", .failureDestinationFolderUnavailablePrefix),
            ("The entry being edited was removed by the current results; its draft could not be saved and remains available for retry: ", .failureEditingEntryRemovedByResultsDraftPrefix),
            ("The entry being edited was removed by the history limit; its draft could not be saved and remains available for retry: ", .failureEditingEntryRemovedByHistoryLimitDraftPrefix),
            ("Import failed: ", .failureImportPrefix),
            ("Backup failed: ", .failureBackupPrefix),
            ("Sync folders import failed: ", .failureSyncFoldersImportPrefix),
            ("Could not remove internal marker entries: ", .failureRemoveInternalMarkersPrefix),
            ("Could not check internal marker entries: ", .failureCheckInternalMarkersPrefix),
            ("Could not compare the tab with its sync folder: ", .failureCompareTabSyncPrefix),
            ("Could not resync the tab with its sync folder: ", .failureResyncTabSyncPrefix),
            ("Could not reconcile sync folders: ", .failureReconcileSyncFoldersPrefix),
            ("Could not empty the sync trash: ", .failureEmptySyncTrashPrefix),
            ("Paste failed: ", .failurePastePrefix),
        ]

        for (prefix, key) in prefixMap {
            if message.hasPrefix(prefix) {
                let rest = String(message.dropFirst(prefix.count))
                let translatedRest = runtimeMessage(rest, language: language)
                return format(key, language: language, translatedRest)
            }
        }

        if message.hasPrefix("Could not set the sync folder: ") {
            let rest = String(message.dropFirst("Could not set the sync folder: ".count))
            if rest.hasPrefix("'") && rest.hasSuffix("' already has one.") {
                let tabName = String(rest.dropFirst().dropLast("' already has one.".count))
                return format(.failureSyncFolderAlreadyHasOnePrefix, language: language, tabName)
            } else {
                return format(.failureSetSyncFolderPrefix, language: language, rest)
            }
        }

        if message.hasPrefix("Kept ") {
            let rest = String(message.dropFirst("Kept ".count))
            for reason in keptDiagnosticReasons {
                let suffix = ": \(reason)."
                guard rest.hasSuffix(suffix) else { continue }
                return format(
                    .diagnosticKeptReason,
                    language: language,
                    String(rest.dropLast(suffix.count)),
                    runtimeMessage(reason, language: language)
                )
            }
        }

        if message.hasPrefix("Could not move the items to \u{201C}") {
            let rest = String(message.dropFirst("Could not move the items to \u{201C}".count))
            if let closingIdx = rest.range(of: "\u{201D}: ") {
                let tabName = String(rest[..<closingIdx.lowerBound])
                let errorDesc = String(rest[closingIdx.upperBound...])
                return format(
                    .failureMoveItemsToTabPrefix,
                    language: language,
                    tabName,
                    runtimeMessage(errorDesc, language: language)
                )
            }
        }

        for (pattern, key) in reasonPatterns {
            if let values = pattern.values(in: message) {
                return format(key, language: language, arguments: values)
            }
        }

        return message
    }

    /// A producer message whose values must stay verbatim while the text around
    /// them is translated.
    private struct ReasonPattern {
        let literals: [String]

        func values(in message: String) -> [String]? {
            guard literals.count >= 2,
                  let first = literals.first,
                  let last = literals.last,
                  message.hasPrefix(first),
                  message.hasSuffix(last)
            else { return nil }
            var rest = message.dropFirst(first.count)
            if !last.isEmpty { rest = rest.dropLast(last.count) }
            var values: [String] = []
            for literal in literals.dropFirst().dropLast() {
                guard let range = rest.range(of: literal) else { return nil }
                values.append(String(rest[..<range.lowerBound]))
                rest = rest[range.upperBound...]
            }
            values.append(String(rest))
            return values
        }
    }

    private static let keptDiagnosticReasons: [String] = {
        var reasons = CopyQSyncResyncConflictReason.allCases.map(\.description)
        reasons.append(CatalogKey.diagnosticKeptUnarchivedPayload.english)
        return reasons
    }()

    private static let reasonPatterns: [(pattern: ReasonPattern, key: CatalogKey)] = [
        (ReasonPattern(literals: ["Skipped ", ": multiple tabs claim this sync folder: ", ""]), .failureImportAmbiguousFolder),
        (ReasonPattern(literals: ["There is no tab ", " to export"]), .failureBackupNoTab),
        (ReasonPattern(literals: ["The tab with id ", " no longer exists."]), .failureResyncNoTab),
        (ReasonPattern(literals: ["The tab \u{201C}", "\u{201D} has no sync folder configured."]), .failureResyncNoSyncFolder),
        (ReasonPattern(literals: ["Several tabs claim the sync folder ", ": ", ". Fix the tab folders before comparing."]), .failureResyncAmbiguousFolder),
        (ReasonPattern(literals: ["Could not read ", ": ", ""]), .failureResyncFolderUnreadable),
        (ReasonPattern(literals: ["The tab's sync folder changed from ", " to ", " after the report. Compare the tab again before applying."]), .failureResyncFolderChanged),
        (ReasonPattern(literals: ["Sync is paused, so \u{201C}", "\u{201D} cannot be resynced. Resume sync first."]), .failureResyncPaused),
        (ReasonPattern(literals: ["Kept the local version of ", " because it is newer than the upstream edit."]), .noticeKeptLocalVersionPrefix),
        (ReasonPattern(literals: ["Kept the local versions of ", " because they are newer than the upstream edits."]), .noticeKeptLocalVersionsPrefix),
        (ReasonPattern(literals: ["Removed the entry for ", " after it was deleted in the sync folder."]), .noticeRemovedEntryAfterRemoteDeletionPrefix),
        (ReasonPattern(literals: ["Removed ", " entries after their files were deleted in sync folders."]), .noticeRemovedEntriesAfterRemoteDeletion),
        (ReasonPattern(literals: ["Importing ", "\u{2026}"]), .noticeImportingFilePrefix),
        (ReasonPattern(literals: ["Skipped ", ": the entry no longer exists."]), .diagnosticSkippedEntryGone),
        (ReasonPattern(literals: ["Skipped ", ": the entry has no resolved sync identity."]), .diagnosticSkippedNoIdentity),
        (ReasonPattern(literals: ["Could not check ", " for a pending local edit: ", ""]), .diagnosticCouldNotCheckLocalEdit),
        (ReasonPattern(literals: ["Skipped ", ": its group reappeared in the folder."]), .diagnosticSkippedGroupReappeared),
        (ReasonPattern(literals: ["Skipped ", ": its group is still being written."]), .diagnosticSkippedGroupBeingWritten),
        (ReasonPattern(literals: ["Could not remove the entries whose files are gone: ", ""]), .diagnosticCouldNotRemoveMissingEntries),
        (ReasonPattern(literals: ["Skipped ", ": it is no longer importable folder content."]), .diagnosticSkippedNotImportable),
        (ReasonPattern(literals: ["Skipped ", ": an entry already owns it."]), .diagnosticSkippedAlreadyOwned),
        (ReasonPattern(literals: ["Skipped ", ": this app wrote it and no entry owns it."]), .diagnosticSkippedWrittenByApp),
        (ReasonPattern(literals: ["Skipped ", ": the entry has a local edit that has not reached the folder."]), .diagnosticSkippedLocalEditPending),
        (ReasonPattern(literals: ["Skipped ", ": the folder's version is older than the entry's."]), .diagnosticSkippedFolderOlder),
        (ReasonPattern(literals: ["Skipped ", ": it carries no content."]), .diagnosticSkippedNoContent),
        (ReasonPattern(literals: ["Could not import ", ": ", ""]), .diagnosticCouldNotImportStem),
        (ReasonPattern(literals: ["Skipped ", ": the folder item is gone."]), .diagnosticSkippedFolderItemGone),
        (ReasonPattern(literals: ["Skipped ", ": the entry already has the folder's content."]), .diagnosticSkippedAlreadyHasFolderContent),
        (ReasonPattern(literals: ["Could not update ", ": ", ""]), .diagnosticCouldNotUpdateStem),
        (ReasonPattern(literals: ["Skipped ", ": ", ""]), .diagnosticSkippedFile),
    ]

    /// Translates each clause of a composed runtime message and joins them the way the
    /// producer joined them.
    public static func runtimeMessage(_ messages: [String], language: AppLanguage) -> String {
        messages.map { runtimeMessage($0, language: language) }.joined(separator: " ")
    }
}
