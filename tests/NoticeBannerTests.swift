// The window's banner: pointer transparency and the message it shows.
//
// The regression these tests guard: the banner was a SwiftUI overlay over the
// top of the item list, so its message rectangle swallowed clicks and double
// clicks on the rows underneath it for as long as it stayed up. The banner now
// lives in AppKit and answers `hitTest(_:)` itself, which is what these tests
// exercise: a hit anywhere on the message lands on the list, and only the
// banner's own buttons keep their own clicks.

import AppKit
import Foundation
import SwiftUI

@MainActor
private func makeBanner(
    _ content: NoticeBannerContent,
    width: CGFloat = 600,
    onAction: @escaping () -> Void = {},
    onDismiss: @escaping () -> Void = {}
) -> NoticeBannerView {
    let banner = NoticeBannerView()
    banner.configure(content, onAction: onAction, onDismiss: onDismiss)
    banner.frame = NSRect(x: 0, y: 0, width: width, height: banner.height(forWidth: width))
    banner.layout(in: width)
    return banner
}

@MainActor
private func centre(of view: NSView) -> NSPoint {
    NSPoint(x: view.frame.midX, y: view.frame.midY)
}

func registerNoticeBannerTests() {
    // MARK: - Pointer transparency

    TestRunner.add("a click on the banner message reaches the list underneath") {
        MainActor.assumeIsolated {
            let banner = makeBanner(NoticeBannerContent(text: "Moved the item to the tab."))
            let list = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            list.addSubview(banner)

            // A point inside the message, away from both buttons.
            let messagePoint = NSPoint(x: 120, y: banner.bounds.midY)
            expect(
                banner.hitTest(messagePoint) == nil,
                "the message must not claim a click that belongs to the row under it"
            )
            expect(
                list.hitTest(messagePoint) === list,
                "the click must fall through to the list, not be swallowed by the banner"
            )
        }
    }

    TestRunner.add("a click on the banner's close control is still the banner's") {
        MainActor.assumeIsolated {
            var dismissed = 0
            let banner = makeBanner(
                NoticeBannerContent(text: "Import complete: 3 entries."),
                onDismiss: { dismissed += 1 }
            )
            guard let close = banner.subviews.compactMap({ $0 as? NSButton }).first(where: { !$0.isHidden }) else {
                TestRunner.fail("the banner has no close control")
                return
            }
            expect(
                banner.hitTest(centre(of: close)) === close,
                "the close control keeps its own click"
            )
            close.performClick(nil)
            expectEqual(dismissed, 1, "the close control dismisses the banner")
        }
    }

    TestRunner.add("the permission banner's grant action keeps its own click") {
        MainActor.assumeIsolated {
            var granted = 0
            let banner = makeBanner(
                NoticeBannerContent(text: AccessibilityNoticePolicy.pasteNeedsPermission),
                onAction: { granted += 1 }
            )
            let buttons = banner.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            expectEqual(buttons.count, 2, "the permission banner offers the grant action and a close control")
            guard let action = buttons.first(where: { $0.frame.width > $0.frame.height }) else {
                TestRunner.fail("the permission banner has no grant button")
                return
            }
            expect(
                banner.hitTest(centre(of: action)) === action,
                "the grant button keeps its own click"
            )
            action.performClick(nil)
            expectEqual(granted, 1, "the grant button runs the grant flow")
        }
    }

    TestRunner.add("an informational banner offers only the close control") {
        MainActor.assumeIsolated {
            let banner = makeBanner(NoticeBannerContent(text: "Backup written: 12 entries."))
            let buttons = banner.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            expectEqual(buttons.count, 1, "only the close control is offered")
        }
    }

    TestRunner.add("the permission banner renders in the selected language") {
        MainActor.assumeIsolated {
            let english = NoticeBannerContent(text: AccessibilityNoticePolicy.pasteNeedsPermission)
            expectEqual(english.displayText, AccessibilityNoticePolicy.pasteNeedsPermission)
            expectEqual(english.actionTitle, "Open System Settings\u{2026}")

            let chinese = NoticeBannerContent(
                text: AccessibilityNoticePolicy.pasteNeedsPermission,
                language: .simplifiedChinese
            )
            expect(chinese.isPermissionNotice, "the raw notice still identifies the permission banner")
            expectEqual(
                chinese.displayText,
                Localization.string(.failureAccessibilityPermission, language: .simplifiedChinese)
            )
            expect(chinese.displayText.contains("辅助功能权限"), "the banner message is Simplified Chinese")
            expectEqual(chinese.actionTitle, "打开系统设置\u{2026}")

            let banner = makeBanner(chinese)
            expectEqual(banner.accessibilityValue() as? String, chinese.displayText)
        }
    }

    // MARK: - Placement over the list

    TestRunner.add("the list's banner takes a new message's frame and leaves the rows clickable") {
        MainActor.assumeIsolated {
            let scrollView = EntryListScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 900))
            scrollView.keepBannerOnTop()
            scrollView.layout()

            let banner = scrollView.banner
            scrollView.configureBanner(
                NoticeBannerContent(text: "Backup written: 12 entries."),
                onAction: {},
                onDismiss: {}
            )
            expect(!banner.isHidden, "the message is shown")
            expect(banner.frame.height > 0, "the message takes its height without a resize")
            expectEqual(banner.frame.minX, 12, "the banner keeps the list's side inset")
            expectEqual(banner.frame.width, 600 - 24, "the banner spans the list")
            expectEqual(
                banner.frame.minY,
                scrollView.bounds.minY + 12,
                "the banner sits at the top of the list, not over the tab strip"
            )
            let shortHeight = banner.frame.height

            scrollView.configureBanner(
                NoticeBannerContent(text: AccessibilityNoticePolicy.pasteNeedsPermission),
                onAction: {},
                onDismiss: {}
            )
            expect(
                banner.frame.height > shortHeight,
                "a longer message takes its new height without a resize"
            )
            expectEqual(
                banner.frame.minY,
                scrollView.bounds.minY + 12,
                "the taller banner stays anchored to the top of the list"
            )

            // A click on the message, and one just below it, both belong to the list.
            let onBanner = NSPoint(x: 100, y: banner.frame.maxY - banner.frame.height / 2)
            let belowBanner = NSPoint(x: 100, y: banner.frame.maxY + 20)
            for point in [onBanner, belowBanner] {
                let hit = scrollView.hitTest(point)
                expect(hit !== banner, "the banner must not take the point at \(point)")
                expectNotNil(hit, "the list still receives the point at \(point)")
            }
        }
    }

    // MARK: - Message measurement

    TestRunner.add("a long message wraps to the width it is given") {
        MainActor.assumeIsolated {
            let text = AccessibilityNoticePolicy.pasteNeedsPermission
            let wide = makeBanner(NoticeBannerContent(text: text), width: 900)
            let narrow = makeBanner(NoticeBannerContent(text: text), width: 420)
            expect(
                narrow.bounds.height > wide.bounds.height,
                "a narrower banner must be taller to fit the same message"
            )
            let singleLine = makeBanner(NoticeBannerContent(text: "Copied to the clipboard."), width: 900)
            expect(
                singleLine.bounds.height < wide.bounds.height,
                "a single-line message must not use the height of the long one"
            )
        }
    }
}
