import Foundation

// MARK: - Tab Context Menu

enum TabContextMenu {
    struct Titles: Equatable, Sendable {
        let rename: String
        let moveBackward: String
        let moveForward: String
        let useAsCaptureTab: String
        let compareSyncFolder: String
        let writeBackToSyncFolder: String
        let removeTab: String
    }

    static func titles(for layout: WindowLayout, language: AppLanguage) -> Titles {
        let moveBackwardKey: CatalogKey
        let moveForwardKey: CatalogKey
        switch layout {
        case .layoutB:
            moveBackwardKey = .tabContextMoveUp
            moveForwardKey = .tabContextMoveDown
        case .layoutA:
            moveBackwardKey = .tabContextMoveLeft
            moveForwardKey = .tabContextMoveRight
        }
        return Titles(
            rename: Localization.string(.settingsTabRenameButton, language: language),
            moveBackward: Localization.string(moveBackwardKey, language: language),
            moveForward: Localization.string(moveForwardKey, language: language),
            useAsCaptureTab: Localization.string(.menuTabsUseAsCaptureTab, language: language),
            compareSyncFolder: Localization.string(.tabContextCompareSyncFolder, language: language),
            writeBackToSyncFolder: Localization.string(.tabContextWriteBack, language: language),
            removeTab: Localization.string(.menuTabsRemoveTab, language: language)
        )
    }
}
