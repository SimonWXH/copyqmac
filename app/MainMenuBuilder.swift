// Builds the application main menu: CopyQmac / File / Edit / Item / Tabs / Help.

import AppKit
import Foundation

@MainActor
enum MainMenuBuilder {
    static let moveToTabMenuIdentifier = NSUserInterfaceItemIdentifier("CopyQmacMoveToTabMenu")

    static func build(actions: AppActions, language: AppLanguage? = nil) -> NSMenu {
        let lang = language ?? actions.model.preferences.language
        let mainMenu = NSMenu()

        // Application menu
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: Localization.string(.menuAppAbout, language: lang),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: Localization.string(.menuAppPreferences, language: lang),
            action: #selector(AppActions.showPreferencesAction(_:)),
            keyEquivalent: ","
        ).target = actions
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: Localization.string(.menuAppHide, language: lang),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: Localization.string(.menuAppHideOthers, language: lang),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            withTitle: Localization.string(.menuAppShowAll, language: lang),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: Localization.string(.menuAppQuit, language: lang),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        mainMenu.addItem(submenu(appMenu, title: Localization.string(.menuAppTitle, language: lang)))

        // File
        let fileMenu = NSMenu(title: Localization.string(.menuFile, language: lang))
        fileMenu.addItem(
            withTitle: Localization.string(.menuFileNewTab, language: lang),
            action: #selector(AppActions.newTab(_:)),
            keyEquivalent: "t"
        ).target = actions
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: Localization.string(.menuFileImportCopyQ, language: lang),
            action: #selector(AppActions.importFromCopyQ(_:)),
            keyEquivalent: "i"
        ).target = actions
        fileMenu.addItem(
            withTitle: Localization.string(.menuFileImportSyncFolders, language: lang),
            action: #selector(AppActions.importConfiguredSyncFolders(_:)),
            keyEquivalent: "I"
        ).target = actions
        fileMenu.addItem(
            withTitle: Localization.string(.menuFileReconcileSyncFolders, language: lang),
            action: #selector(AppActions.reconcileSyncFolders(_:)),
            keyEquivalent: ""
        ).target = actions
        fileMenu.addItem(
            withTitle: Localization.string(.menuFileEmptySyncTrash, language: lang),
            action: #selector(AppActions.emptySyncTrash(_:)),
            keyEquivalent: ""
        ).target = actions
        fileMenu.addItem(.separator())
        let exportBackup = fileMenu.addItem(
            withTitle: Localization.string(.menuFileExportBackup, language: lang),
            action: #selector(AppActions.exportBackup(_:)),
            keyEquivalent: "E"
        )
        exportBackup.keyEquivalentModifierMask = [.command, .shift]
        exportBackup.target = actions
        fileMenu.addItem(
            withTitle: Localization.string(.menuFileExportCurrentTab, language: lang),
            action: #selector(AppActions.exportCurrentTab(_:)),
            keyEquivalent: ""
        ).target = actions
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: Localization.string(.menuFilePauseSync, language: lang),
            action: #selector(AppActions.toggleSyncPauseAction(_:)),
            keyEquivalent: ""
        ).target = actions
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: Localization.string(.menuFileHideWindow, language: lang),
            action: #selector(AppActions.hideWindow(_:)),
            keyEquivalent: "w"
        ).target = actions
        mainMenu.addItem(submenu(fileMenu, title: Localization.string(.menuFile, language: lang)))

        // Edit
        let editMenu = NSMenu(title: Localization.string(.menuEdit, language: lang))
        editMenu.addItem(
            withTitle: Localization.string(.menuEditUndo, language: lang),
            action: #selector(UndoManager.undo),
            keyEquivalent: "z"
        )
        let redoItem = NSMenuItem(
            title: Localization.string(.menuEditRedo, language: lang),
            action: #selector(UndoManager.redo),
            keyEquivalent: "Z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: Localization.string(.menuEditCut, language: lang),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: Localization.string(.menuEditCopy, language: lang),
            action: #selector(AppActions.copySelected(_:)),
            keyEquivalent: "c"
        ).target = actions
        editMenu.addItem(
            withTitle: Localization.string(.menuEditPaste, language: lang),
            action: #selector(AppActions.pasteSelected(_:)),
            keyEquivalent: "v"
        ).target = actions
        editMenu.addItem(
            withTitle: Localization.string(.menuEditSelectAll, language: lang),
            action: #selector(AppActions.selectAllItems(_:)),
            keyEquivalent: "a"
        ).target = actions
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: Localization.string(.menuEditFind, language: lang),
            action: #selector(AppActions.find(_:)),
            keyEquivalent: "f"
        ).target = actions
        mainMenu.addItem(submenu(editMenu, title: Localization.string(.menuEdit, language: lang)))

        // Item
        let itemMenu = NSMenu(title: Localization.string(.menuItem, language: lang))
        itemMenu.addItem(
            withTitle: Localization.string(.menuItemNewItem, language: lang),
            action: #selector(AppActions.newItem(_:)),
            keyEquivalent: "n"
        ).target = actions
        let editItem = itemMenu.addItem(
            withTitle: Localization.string(.menuItemEditItem, language: lang),
            action: #selector(AppActions.editItem(_:)),
            keyEquivalent: String(UnicodeScalar(NSF2FunctionKey)!)
        )
        editItem.keyEquivalentModifierMask = []
        editItem.target = actions
        itemMenu.addItem(
            withTitle: Localization.string(.menuItemEditNote, language: lang),
            action: #selector(AppActions.editNote(_:)),
            keyEquivalent: "e"
        ).target = actions
        itemMenu.addItem(.separator())
        itemMenu.addItem(
            withTitle: Localization.string(.menuItemActivate, language: lang),
            action: #selector(AppActions.activateSelected(_:)),
            keyEquivalent: ""
        ).target = actions
        itemMenu.addItem(
            withTitle: Localization.string(.menuItemPin, language: lang),
            action: #selector(AppActions.pinSelected(_:)),
            keyEquivalent: "p"
        ).target = actions
        let pastePlain = NSMenuItem(
            title: Localization.string(.menuItemPasteAsPlainText, language: lang),
            action: #selector(AppActions.pasteSelectedAsPlainText(_:)),
            keyEquivalent: "V"
        )
        pastePlain.keyEquivalentModifierMask = [.command, .shift]
        pastePlain.target = actions
        itemMenu.addItem(pastePlain)
        itemMenu.addItem(.separator())
        itemMenu.addItem(
            withTitle: Localization.string(.menuItemMoveUp, language: lang),
            action: #selector(AppActions.moveSelectedUp(_:)),
            keyEquivalent: ""
        ).target = actions
        itemMenu.addItem(
            withTitle: Localization.string(.menuItemMoveDown, language: lang),
            action: #selector(AppActions.moveSelectedDown(_:)),
            keyEquivalent: ""
        ).target = actions
        itemMenu.addItem(
            withTitle: Localization.string(.menuItemMoveToTop, language: lang),
            action: #selector(AppActions.moveSelectedToTop(_:)),
            keyEquivalent: ""
        ).target = actions
        itemMenu.addItem(
            withTitle: Localization.string(.menuItemMoveToBottom, language: lang),
            action: #selector(AppActions.moveSelectedToBottom(_:)),
            keyEquivalent: ""
        ).target = actions
        let moveToTab = NSMenuItem(
            title: Localization.string(.menuItemMoveToTab, language: lang),
            action: nil,
            keyEquivalent: ""
        )
        let moveToTabMenu = NSMenu(title: Localization.string(.menuItemMoveToTab, language: lang))
        moveToTabMenu.identifier = moveToTabMenuIdentifier
        moveToTabMenu.delegate = actions
        moveToTab.submenu = moveToTabMenu
        itemMenu.addItem(moveToTab)
        itemMenu.addItem(.separator())
        let remove = itemMenu.addItem(
            withTitle: Localization.string(.menuItemRemove, language: lang),
            action: #selector(AppActions.removeSelected(_:)),
            keyEquivalent: "\u{8}"
        )
        remove.target = actions
        itemMenu.addItem(
            withTitle: Localization.string(.menuItemClearTab, language: lang),
            action: #selector(AppActions.clearTab(_:)),
            keyEquivalent: ""
        ).target = actions
        itemMenu.addItem(
            withTitle: Localization.string(.menuItemRemoveInternalMarkerEntries, language: lang),
            action: #selector(AppActions.removeInternalMarkerEntries(_:)),
            keyEquivalent: ""
        ).target = actions
        mainMenu.addItem(submenu(itemMenu, title: Localization.string(.menuItem, language: lang)))

        // Tabs
        let tabsMenu = NSMenu(title: Localization.string(.menuTabs, language: lang))
        tabsMenu.addItem(
            withTitle: Localization.string(.menuTabsNewTab, language: lang),
            action: #selector(AppActions.newTab(_:)),
            keyEquivalent: ""
        ).target = actions
        tabsMenu.addItem(
            withTitle: Localization.string(.menuTabsRenameTab, language: lang),
            action: #selector(AppActions.renameTab(_:)),
            keyEquivalent: ""
        ).target = actions
        let removeTab = tabsMenu.addItem(
            withTitle: Localization.string(.menuTabsRemoveTab, language: lang),
            action: #selector(AppActions.removeTab(_:)),
            keyEquivalent: ""
        )
        removeTab.target = actions
        tabsMenu.addItem(.separator())
        let moveLeft = tabsMenu.addItem(
            withTitle: Localization.string(.menuTabsMoveTabLeft, language: lang),
            action: #selector(AppActions.moveTabLeft(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        moveLeft.keyEquivalentModifierMask = [.command, .option]
        moveLeft.target = actions
        let moveRight = tabsMenu.addItem(
            withTitle: Localization.string(.menuTabsMoveTabRight, language: lang),
            action: #selector(AppActions.moveTabRight(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        )
        moveRight.keyEquivalentModifierMask = [.command, .option]
        moveRight.target = actions
        tabsMenu.addItem(.separator())
        tabsMenu.addItem(
            withTitle: Localization.string(.menuTabsUseAsCaptureTab, language: lang),
            action: #selector(AppActions.setCaptureTab(_:)),
            keyEquivalent: ""
        ).target = actions
        mainMenu.addItem(submenu(tabsMenu, title: Localization.string(.menuTabs, language: lang)))

        // Help
        let helpMenu = NSMenu(title: Localization.string(.menuHelp, language: lang))
        helpMenu.addItem(
            withTitle: Localization.string(.menuHelpCopyQmacHelp, language: lang),
            action: #selector(AppActions.showHelp(_:)),
            keyEquivalent: "?"
        ).target = actions
        let helpItem = submenu(helpMenu, title: Localization.string(.menuHelp, language: lang))
        mainMenu.addItem(helpItem)
        // `NSApp` is nil until an NSApplication exists, which the app always
        // has but a headless test binary may not; `NSApplication.shared` is the
        // same instance and creates it on demand.
        NSApplication.shared.helpMenu = helpMenu

        return mainMenu
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

@MainActor
enum StatusMenuBuilder {
    static func build(
        actions: AppActions,
        language: AppLanguage? = nil
    ) -> (menu: NSMenu, showItem: NSMenuItem, pauseSyncItem: NSMenuItem) {
        let lang = language ?? actions.model.preferences.language
        let menu = NSMenu()
        let showItem = menu.addItem(
            withTitle: Localization.string(.statusItemShowCopyQmac, language: lang),
            action: #selector(AppActions.showMainWindow(_:)),
            keyEquivalent: ""
        )
        showItem.target = actions
        menu.addItem(.separator())
        let newItem = menu.addItem(
            withTitle: Localization.string(.menuItemNewItem, language: lang),
            action: #selector(AppActions.newItem(_:)),
            keyEquivalent: "n"
        )
        newItem.target = actions
        let editItem = menu.addItem(
            withTitle: Localization.string(.menuItemEditItem, language: lang),
            action: #selector(AppActions.editItem(_:)),
            keyEquivalent: String(UnicodeScalar(NSF2FunctionKey)!)
        )
        editItem.keyEquivalentModifierMask = []
        editItem.target = actions
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localization.string(.menuAppPreferences, language: lang),
            action: #selector(AppActions.showPreferencesAction(_:)),
            keyEquivalent: ""
        ).target = actions
        menu.addItem(
            withTitle: Localization.string(.menuFileImportCopyQ, language: lang),
            action: #selector(AppActions.importFromCopyQ(_:)),
            keyEquivalent: ""
        ).target = actions
        menu.addItem(
            withTitle: Localization.string(.menuFileImportSyncFolders, language: lang),
            action: #selector(AppActions.importConfiguredSyncFolders(_:)),
            keyEquivalent: ""
        ).target = actions
        menu.addItem(
            withTitle: Localization.string(.menuFileExportBackup, language: lang),
            action: #selector(AppActions.exportBackup(_:)),
            keyEquivalent: ""
        ).target = actions
        let pauseSyncItem = menu.addItem(
            withTitle: Localization.string(.menuFilePauseSync, language: lang),
            action: #selector(AppActions.toggleSyncPauseAction(_:)),
            keyEquivalent: ""
        )
        pauseSyncItem.target = actions
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localization.string(.menuAppQuit, language: lang),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return (menu, showItem, pauseSyncItem)
    }
}
