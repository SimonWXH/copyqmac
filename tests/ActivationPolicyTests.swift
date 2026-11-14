// The activation policy follows the visible windows: regular while at least one
// of the app's own windows is on screen (so macOS draws the application menu
// bar), accessory as soon as the last one closes (so the Dock icon goes away).
//
// macOS 26 never gives an accessory app a menu bar; see
// docs/architecture.md#the-menu-bar-and-the-activation-policy for the
// measurement. The policy itself is injected, so this suite observes the
// decisions without touching the real NSApplication.

import AppKit
import Foundation

func registerActivationPolicyTests() {
    TestRunner.add("the activation policy is regular only while an app window is visible") {
        MainActor.assumeIsolated {
            var applied: [NSApplication.ActivationPolicy] = []
            let controller = ActivationPolicyController { applied.append($0) }
            let mainWindow = NSObject()
            let preferencesWindow = NSObject()

            expect(applied.isEmpty, "nothing changes before a window is shown")
            expect(!controller.hasVisibleWindows, "the app starts with no visible windows")

            controller.windowWillShow(mainWindow)
            expectEqual(applied, [.regular], "showing the first window makes the app regular")
            expect(controller.hasVisibleWindows, "the shown window counts as visible")

            controller.windowWillShow(mainWindow)
            expectEqual(applied, [.regular], "showing the same window twice does not switch again")

            controller.windowWillShow(preferencesWindow)
            expectEqual(applied, [.regular], "a second window keeps the app regular")

            controller.windowDidHide(mainWindow)
            expectEqual(applied, [.regular], "the preferences window still needs the menu bar")

            controller.windowDidHide(preferencesWindow)
            expectEqual(applied, [.regular, .accessory], "closing the last window drops the Dock icon")
            expect(!controller.hasVisibleWindows, "no window is left")

            controller.windowDidHide(preferencesWindow)
            expectEqual(applied, [.regular, .accessory], "hiding a window twice does nothing")

            controller.windowWillShow(mainWindow)
            expectEqual(
                applied,
                [.regular, .accessory, .regular],
                "summoning the window again makes the app regular again"
            )
        }
    }
}
