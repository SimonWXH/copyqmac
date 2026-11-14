// Tab context menu titles for sidebar and tab-strip layouts across languages.

import Foundation

func registerTabContextMenuTests() {
    TestRunner.currentSuite = "TabContextMenu"

    TestRunner.add("sidebar layout context menu uses Move Up and Move Down in English") {
        let titles = TabContextMenu.titles(for: .sidebar, language: .english)
        expectEqual(titles.moveBackward, "Move Up", "move upward in sidebar")
        expectEqual(titles.moveForward, "Move Down", "move downward in sidebar")
    }

    TestRunner.add("sidebar layout context menu uses 上移 and 下移 in Simplified Chinese") {
        let titles = TabContextMenu.titles(for: .sidebar, language: .simplifiedChinese)
        expectEqual(titles.moveBackward, "上移", "move upward in sidebar (zh)")
        expectEqual(titles.moveForward, "下移", "move downward in sidebar (zh)")
    }

    TestRunner.add("tab strip layout context menu uses Move Left and Move Right in English") {
        let titles = TabContextMenu.titles(for: .tabStrip, language: .english)
        expectEqual(titles.moveBackward, "Move Left", "move left in tab strip")
        expectEqual(titles.moveForward, "Move Right", "move right in tab strip")
    }

    TestRunner.add("tab strip layout context menu uses 向左移动 and 向右移动 in Simplified Chinese") {
        let titles = TabContextMenu.titles(for: .tabStrip, language: .simplifiedChinese)
        expectEqual(titles.moveBackward, "向左移动", "move left in tab strip (zh)")
        expectEqual(titles.moveForward, "向右移动", "move right in tab strip (zh)")
    }

    TestRunner.add("shared context menu items match across layouts") {
        for lang in [AppLanguage.english, AppLanguage.simplifiedChinese] {
            let sidebar = TabContextMenu.titles(for: .sidebar, language: lang)
            let tabStrip = TabContextMenu.titles(for: .tabStrip, language: lang)
            expectEqual(sidebar.rename, tabStrip.rename)
            expectEqual(sidebar.useAsCaptureTab, tabStrip.useAsCaptureTab)
            expectEqual(sidebar.compareSyncFolder, tabStrip.compareSyncFolder)
            expectEqual(sidebar.removeTab, tabStrip.removeTab)
        }
    }
}
