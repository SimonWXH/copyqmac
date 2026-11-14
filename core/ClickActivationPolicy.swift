// Policy governing row activation from mouse clicks in the item list.
//
// When single-click activation is enabled, clicking a row activates it
// immediately. A rapid double click on the same row suppresses the second
// click and the trailing double-click event so the row is only activated once
// per sequence.

import Foundation

public struct ClickActivationPolicy: Equatable, Sendable {
    public var doubleClickInterval: TimeInterval
    public private(set) var lastActivatedRow: Int?
    public private(set) var lastActivatedAt: TimeInterval?
    public private(set) var lastActivatedClickCount: Int?

    private var lastClickRow: Int?
    private var lastClickAt: TimeInterval?
    private var sequenceActivated = false

    public init(doubleClickInterval: TimeInterval = 0.5) {
        self.doubleClickInterval = doubleClickInterval
    }

    public mutating func reset() {
        lastActivatedRow = nil
        lastActivatedAt = nil
        lastActivatedClickCount = nil
        lastClickRow = nil
        lastClickAt = nil
        sequenceActivated = false
    }

    public mutating func shouldActivate(
        row: Int,
        clickCount: Int,
        at timestamp: TimeInterval,
        singleClickActivates: Bool
    ) -> Bool {
        guard row >= 0 else { return false }

        let isSameSequence = (lastClickRow == row) && (lastClickAt.map { abs(timestamp - $0) <= doubleClickInterval } ?? false)
        lastClickRow = row
        lastClickAt = timestamp

        if isSameSequence {
            if sequenceActivated {
                return false
            }
            if clickCount >= 2 {
                sequenceActivated = true
                lastActivatedRow = row
                lastActivatedAt = timestamp
                lastActivatedClickCount = clickCount
                return true
            }
            return false
        }

        sequenceActivated = false
        let activates = (clickCount >= 2) || (clickCount == 1 && singleClickActivates)
        if activates {
            sequenceActivated = true
            lastActivatedRow = row
            lastActivatedAt = timestamp
            lastActivatedClickCount = clickCount
            return true
        }
        return false
    }
}
