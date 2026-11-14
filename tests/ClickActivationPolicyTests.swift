// Tests for ClickActivationPolicy: immediate activation on single click,
// duplicate suppression during fast click sequences, and sequence separation.

import Foundation

func registerClickActivationPolicyTests() {
    TestRunner.currentSuite = "ClickActivationPolicy"

    TestRunner.add("one single click on a row performs exactly one activation, immediately") {
        var policy = ClickActivationPolicy(doubleClickInterval: 0.5)
        let activates = policy.shouldActivate(row: 0, clickCount: 1, at: 10.0, singleClickActivates: true)
        expectEqual(activates, true, "single click activates immediately")
        expectEqual(policy.lastActivatedRow, 0)
        expectEqual(policy.lastActivatedAt, 10.0)
        expectEqual(policy.lastActivatedClickCount, 1)
    }

    TestRunner.add("a fast double click on the same row performs exactly one activation in total") {
        var policy = ClickActivationPolicy(doubleClickInterval: 0.5)
        let firstClick = policy.shouldActivate(row: 0, clickCount: 1, at: 10.0, singleClickActivates: true)
        expectEqual(firstClick, true, "the first click activates")

        let secondClick = policy.shouldActivate(row: 0, clickCount: 2, at: 10.15, singleClickActivates: true)
        expectEqual(secondClick, false, "the second click is ignored")

        let doubleAction = policy.shouldActivate(row: 0, clickCount: 2, at: 10.15, singleClickActivates: true)
        expectEqual(doubleAction, false, "the double-click action that follows is ignored")
    }

    TestRunner.add("a single click followed by another single click more than the double-click interval later performs two activations") {
        var policy = ClickActivationPolicy(doubleClickInterval: 0.5)
        let firstClick = policy.shouldActivate(row: 0, clickCount: 1, at: 10.0, singleClickActivates: true)
        expectEqual(firstClick, true, "the first click activates")

        let secondClick = policy.shouldActivate(row: 0, clickCount: 1, at: 10.6, singleClickActivates: true)
        expectEqual(secondClick, true, "a click after the double-click interval performs a second activation")
    }

    TestRunner.add("with single click disabled, only a double click activates") {
        var policy = ClickActivationPolicy(doubleClickInterval: 0.5)
        let singleClick = policy.shouldActivate(row: 0, clickCount: 1, at: 10.0, singleClickActivates: false)
        expectEqual(singleClick, false, "single click does not activate when disabled")

        let doubleClick = policy.shouldActivate(row: 0, clickCount: 2, at: 10.15, singleClickActivates: false)
        expectEqual(doubleClick, true, "double click activates")

        let duplicateDoubleAction = policy.shouldActivate(row: 0, clickCount: 2, at: 10.15, singleClickActivates: false)
        expectEqual(duplicateDoubleAction, false, "duplicate double-click action is ignored")
    }

    TestRunner.add("clicks on different rows within the interval activate independently") {
        var policy = ClickActivationPolicy(doubleClickInterval: 0.5)
        let row0 = policy.shouldActivate(row: 0, clickCount: 1, at: 10.0, singleClickActivates: true)
        expectEqual(row0, true, "first row activates")

        let row1 = policy.shouldActivate(row: 1, clickCount: 1, at: 10.1, singleClickActivates: true)
        expectEqual(row1, true, "different row activates")
    }

    TestRunner.add("reset clears active sequence and activation history") {
        var policy = ClickActivationPolicy(doubleClickInterval: 0.5)
        _ = policy.shouldActivate(row: 0, clickCount: 1, at: 10.0, singleClickActivates: true)
        policy.reset()
        expectNil(policy.lastActivatedRow)
        expectNil(policy.lastActivatedAt)
        expectNil(policy.lastActivatedClickCount)

        let reactivated = policy.shouldActivate(row: 0, clickCount: 1, at: 10.1, singleClickActivates: true)
        expectEqual(reactivated, true, "row activates again after reset")
    }
}
