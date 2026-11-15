// Tabs (F-01) and preferences (F-11) models.
//
// Both are AppKit-free so the tests can drive them directly.

import Foundation

// MARK: - Tabs

/// A user-defined clipboard page.
public struct ClipboardTab: Codable, Equatable, Identifiable, Sendable {
    /// Sentinel used before the store assigns a real row id.
    public static let unsavedID: Int64 = 0

    public var id: Int64
    public var name: String
    /// Sort order, low to high.
    public var position: Int
    /// The tab that captures made on this machine are written into.
    public var isDefault: Bool
    /// CopyQ-compatible sync folder for this tab. A tab with a folder syncs
    /// both ways: captures and edits are written into it, and items arriving
    /// in it are imported. There is no separate enable switch.
    public var syncFolder: String?

    public init(
        id: Int64 = ClipboardTab.unsavedID,
        name: String,
        position: Int = 0,
        isDefault: Bool = false,
        syncFolder: String? = nil
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.isDefault = isDefault
        self.syncFolder = syncFolder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? ClipboardTab.unsavedID
        name = try container.decode(String.self, forKey: .name)
        position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        syncFolder = try container.decodeIfPresent(String.self, forKey: .syncFolder)
    }
}

/// Carbon modifier masks, duplicated here so the core layer does not import
/// Carbon. The values are the historic Carbon constants.
public enum HotKeyModifiers {
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000
}

/// Virtual key codes used by the built-in presets (Carbon `kVK_*` values).
public enum HotKeyKey {
    public static let v: UInt32 = 0x09
    public static let c: UInt32 = 0x08
    public static let b: UInt32 = 0x0B
    public static let h: UInt32 = 0x04
    public static let space: UInt32 = 0x31
}

/// The three-way theme policy: follow system, force light, or force dark.
public enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// The window layout arrangement.
public enum WindowLayout: String, Codable, CaseIterable, Sendable {
    case layoutA = "layoutA"
    case layoutB = "layoutB"
}

/// Geometry and clamping logic for the inspector split divider in Layout B.
public enum InspectorSplitLayout {
    public static let defaultRatio: Double = 0.55
    public static let minRatio: Double = 0.20
    public static let maxRatio: Double = 0.80
    public static let minPaneHeight: CGFloat = 60

    /// Clamps a split ratio to the allowed 0.20...0.80 range.
    public static func clampRatio(_ ratio: Double) -> Double {
        min(max(ratio, minRatio), maxRatio)
    }

    /// The ratio produced by moving the pointer `pointerDelta` points (positive
    /// is downward) away from where a drag on the divider started.
    public static func ratio(
        startRatio: Double,
        pointerDelta: CGFloat,
        availableHeight: CGFloat
    ) -> Double {
        guard availableHeight > 0 else { return clampRatio(startRatio) }
        return clampRatio(startRatio + Double(pointerDelta / availableHeight))
    }

    /// Computes the preview and note pane heights given an available column height.
    /// The two heights always sum exactly to `availableHeight`.
    public static func paneHeights(availableHeight: CGFloat, ratio: Double) -> (preview: CGFloat, note: CGFloat) {
        guard availableHeight > 0 else { return (0, 0) }
        let clamped = clampRatio(ratio)
        var preview = (availableHeight * CGFloat(clamped)).rounded(.toNearestOrAwayFromZero)
        var note = availableHeight - preview

        if availableHeight >= minPaneHeight * 2 {
            if preview < minPaneHeight {
                preview = minPaneHeight
                note = availableHeight - preview
            } else if note < minPaneHeight {
                note = minPaneHeight
                preview = availableHeight - note
            }
        } else {
            let half = (availableHeight / 2).rounded(.toNearestOrAwayFromZero)
            preview = half
            note = availableHeight - preview
        }
        return (preview, note)
    }

    /// The ratio the divider is drawn at, after the minimum-height guard has
    /// moved the boundary away from the requested ratio.
    public static func displayedRatio(availableHeight: CGFloat, ratio: Double) -> Double {
        guard availableHeight > 0 else { return clampRatio(ratio) }
        let heights = paneHeights(availableHeight: availableHeight, ratio: ratio)
        return Double(heights.preview / availableHeight)
    }
}

/// Geometry and clamping logic for the sidebar column in Layout B.
public enum SidebarLayout {
    public static let defaultWidth: Double = 200
    public static let minWidth: Double = 160
    public static let maxWidth: Double = 260

    /// Clamps a sidebar width to the allowed 160...260 range.
    public static func clampWidth(_ width: Double) -> Double {
        min(max(width, minWidth), maxWidth)
    }
}

extension SidebarLayout: ColumnWidthLayout {
    /// The sidebar width does not depend on the detail container.
    public static func clampWidth(_ width: Double, containerWidth: CGFloat) -> Double {
        clampWidth(width)
    }
}

/// Geometry and clamping logic for the inspector column in Layout B.
public enum InspectorColumnLayout {
    public static let defaultWidth: Double = 280
    public static let minWidth: Double = 240
    public static let maxWidth: Double = 560
    public static let minItemListWidth: CGFloat = 320

    /// Clamps an inspector width to the allowed 240...560 range.
    public static func clampWidth(_ width: Double) -> Double {
        min(max(width, minWidth), maxWidth)
    }

    /// Clamps an inspector width within the allowed range and available
    /// container width. Whenever the container is at least 560 pt wide
    /// (minWidth + minItemListWidth), the maximum leaves the center item list
    /// at least minItemListWidth (320 pt). A narrower container cannot fit
    /// both minimums, so the inspector keeps its 240 pt minimum and the item
    /// list takes whatever remains.
    public static func clampWidth(_ width: Double, containerWidth: CGFloat) -> Double {
        guard containerWidth > 0 else { return clampWidth(width) }
        guard containerWidth >= minWidth + Double(minItemListWidth) else { return minWidth }
        let maxAllowedByContainer = Double(containerWidth) - Double(minItemListWidth)
        return min(max(width, minWidth), min(maxWidth, maxAllowedByContainer))
    }

    /// Computes the proposed inspector width given a drag translation and base width.
    /// Dragging the left handle to the left (negative translation) expands the inspector;
    /// dragging to the right (positive translation) shrinks it.
    public static func width(
        baseWidth: Double,
        translationX: CGFloat,
        containerWidth: CGFloat = 0
    ) -> Double {
        let proposed = baseWidth - Double(translationX)
        return clampWidth(proposed, containerWidth: containerWidth)
    }
}

extension InspectorColumnLayout: ColumnWidthLayout {}

/// A font the user chose for one surface: a family name and a point size.
///
/// The core layer has no AppKit, so the choice is stored as data and resolved to
/// a platform font where it is drawn. Neither field is required: an untouched
/// setting leaves the surface on the font it drew with before this preference
/// existed, so nothing changes for an install that never opens the pickers. A
/// missing size is the size that surface already uses, and no field is
/// validated: a chosen family is applied as stored, matching how CopyQ applies
/// its configured fonts.
public struct FontPreference: Codable, Equatable, Sendable {
    /// An installed font family name, or nil to keep the surface's own font.
    public var family: String?
    /// Point size, or nil for the surface's own default size.
    public var pointSize: Double?

    public static let defaultValue = FontPreference()

    public init(family: String? = nil, pointSize: Double? = nil) {
        self.family = family
        self.pointSize = pointSize
    }

    /// True while the setting is untouched, so the surface keeps the font it
    /// drew with before this preference existed.
    public var isDefault: Bool {
        family == nil && pointSize == nil
    }
}

/// The user's global setup.
public struct Preferences: Codable, Equatable, Sendable {
    /// Key code and Carbon modifier mask for the global summon hotkey.
    /// Default is Option-V, matching a typical existing CopyQ setup.
    public var hotKeyKeyCode: UInt32
    public var hotKeyModifiers: UInt32
    /// Human-readable rendering of the hotkey, captured when it was chosen.
    /// Storing it avoids having to map every virtual key code back to a label.
    public var hotKeyDisplayLabel: String
    /// Key code, Carbon modifier mask, and label for the global Paste as Plain
    /// Text shortcut. Defaults to ⇧⌘V, the same keystroke as the menu item.
    public var plainTextHotKeyKeyCode: UInt32
    public var plainTextHotKeyModifiers: UInt32
    public var plainTextHotKeyDisplayLabel: String
    /// Default cap on stored entries.
    public var defaultMaxItems: Int
    /// When true, the search field looks across every tab, not just the current one.
    public var searchAllTabs: Bool
    /// Global pause toggle that stops all sync-folder reading and writing
    /// immediately. It is the only off switch; a tab with a sync folder is
    /// otherwise always bidirectional.
    public var syncPaused: Bool
    /// What activating an item does: single-click activation, and the paste,
    /// focus, close, and move-to-top steps that follow it.
    public var activation: ActivationOptions
    /// Apps whose clipboard content is never captured. Defaults to the built-in
    /// password-manager list; an empty list means nothing is excluded by app.
    public var captureExclusions: [CaptureExclusionRule]
    /// When true, a capture whose plain text carries an AI-service API key is
    /// skipped before anything is stored, so a key copied here reaches neither
    /// the database nor a sync folder; an item arriving through a sync folder is
    /// not filtered. On by default; an entry already in the history stays.
    public var apiKeyGuardEnabled: Bool
    /// User interface language. Defaults to English.
    public var language: AppLanguage
    /// Theme policy: system (follow OS), light, or dark. Defaults to system.
    public var theme: AppTheme
    /// Font the item list rows draw in. While untouched the list draws the
    /// system font at the size it already used.
    public var itemListFont: FontPreference
    /// Font the item editor draws in, for both the styled and the plain editor.
    /// While untouched each editor keeps the font it drew with before this
    /// preference existed: the styled editor's own base font and the plain
    /// editor's system body font. The styled editor draws a system face as the
    /// default writing family at the chosen size, because its text has to stay
    /// writable into the payload.
    public var editorFont: FontPreference
    /// Window layout arrangement. Defaults to Layout B (sidebar + inspector).
    public var windowLayout: WindowLayout
    /// The old `windowLayout` field, carried through unchanged so a rewritten
    /// blob neither loses nor rewrites it. It never describes a choice.
    private var legacyWindowLayout: String?
    /// Ratio of the inspector height allocated to the preview pane (0.20...0.80). Defaults to 0.55.
    public var inspectorSplitRatio: Double
    /// Width of the sidebar column in Layout B (160...260 pt). Defaults to 200.
    public var sidebarWidth: Double
    /// Width of the inspector column in Layout B (240...560 pt). Defaults to 280.
    public var inspectorColumnWidth: Double

    private enum CodingKeys: String, CodingKey {
        case hotKeyKeyCode
        case hotKeyModifiers
        case hotKeyDisplayLabel
        case plainTextHotKeyKeyCode
        case plainTextHotKeyModifiers
        case plainTextHotKeyDisplayLabel
        case defaultMaxItems
        case searchAllTabs
        case syncPaused
        case activation
        case captureExclusions
        case apiKeyGuardEnabled
        case language
        case theme
        case itemListFont
        case editorFont
        case windowLayout = "windowLayoutChoice"
        case inspectorSplitRatio
        case sidebarWidth
        case inspectorColumnWidth
        case legacyWindowLayout = "windowLayout"
    }

    public static let defaultMaxItems = 1_000

    public static let defaultValue = Preferences(
        hotKeyKeyCode: HotKeyKey.v,
        hotKeyModifiers: HotKeyModifiers.option,
        hotKeyDisplayLabel: "\u{2325}V",
        plainTextHotKeyKeyCode: HotKeyKey.v,
        plainTextHotKeyModifiers: HotKeyModifiers.command | HotKeyModifiers.shift,
        plainTextHotKeyDisplayLabel: "\u{21E7}\u{2318}V",
        defaultMaxItems: defaultMaxItems,
        searchAllTabs: false,
        syncPaused: false,
        activation: .defaultValue,
        captureExclusions: CaptureExclusionCatalog.builtInRules,
        apiKeyGuardEnabled: true,
        language: .english,
        theme: .system,
        itemListFont: .defaultValue,
        editorFont: .defaultValue,
        windowLayout: .layoutB,
        inspectorSplitRatio: InspectorSplitLayout.defaultRatio,
        sidebarWidth: SidebarLayout.defaultWidth,
        inspectorColumnWidth: InspectorColumnLayout.defaultWidth
    )

    public init(
        hotKeyKeyCode: UInt32,
        hotKeyModifiers: UInt32,
        hotKeyDisplayLabel: String,
        plainTextHotKeyKeyCode: UInt32 = HotKeyKey.v,
        plainTextHotKeyModifiers: UInt32 = HotKeyModifiers.command | HotKeyModifiers.shift,
        plainTextHotKeyDisplayLabel: String = "\u{21E7}\u{2318}V",
        defaultMaxItems: Int,
        searchAllTabs: Bool,
        syncPaused: Bool = false,
        activation: ActivationOptions = .defaultValue,
        captureExclusions: [CaptureExclusionRule] = CaptureExclusionCatalog.builtInRules,
        apiKeyGuardEnabled: Bool = true,
        language: AppLanguage = .english,
        theme: AppTheme = .system,
        itemListFont: FontPreference = .defaultValue,
        editorFont: FontPreference = .defaultValue,
        windowLayout: WindowLayout = .layoutB,
        inspectorSplitRatio: Double = InspectorSplitLayout.defaultRatio,
        sidebarWidth: Double = SidebarLayout.defaultWidth,
        inspectorColumnWidth: Double = InspectorColumnLayout.defaultWidth
    ) {
        self.hotKeyKeyCode = hotKeyKeyCode
        self.hotKeyModifiers = hotKeyModifiers
        self.hotKeyDisplayLabel = hotKeyDisplayLabel
        self.plainTextHotKeyKeyCode = plainTextHotKeyKeyCode
        self.plainTextHotKeyModifiers = plainTextHotKeyModifiers
        self.plainTextHotKeyDisplayLabel = plainTextHotKeyDisplayLabel
        self.defaultMaxItems = defaultMaxItems
        self.searchAllTabs = searchAllTabs
        self.syncPaused = syncPaused
        self.activation = activation
        self.captureExclusions = captureExclusions
        self.apiKeyGuardEnabled = apiKeyGuardEnabled
        self.language = language
        self.theme = theme
        self.itemListFont = itemListFont
        self.editorFont = editorFont
        self.windowLayout = windowLayout
        self.inspectorSplitRatio = InspectorSplitLayout.clampRatio(inspectorSplitRatio)
        self.sidebarWidth = SidebarLayout.clampWidth(sidebarWidth)
        self.inspectorColumnWidth = InspectorColumnLayout.clampWidth(inspectorColumnWidth)
    }

    /// Tolerant decoding: unknown or missing fields fall back to defaults so a
    /// preferences blob written by a newer build never bricks an older one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Preferences.defaultValue
        hotKeyKeyCode = try container.decodeIfPresent(UInt32.self, forKey: .hotKeyKeyCode) ?? fallback.hotKeyKeyCode
        hotKeyModifiers = try container.decodeIfPresent(UInt32.self, forKey: .hotKeyModifiers) ?? fallback.hotKeyModifiers
        hotKeyDisplayLabel = try container.decodeIfPresent(String.self, forKey: .hotKeyDisplayLabel) ?? fallback.hotKeyDisplayLabel
        plainTextHotKeyKeyCode = try container.decodeIfPresent(UInt32.self, forKey: .plainTextHotKeyKeyCode)
            ?? fallback.plainTextHotKeyKeyCode
        plainTextHotKeyModifiers = try container.decodeIfPresent(UInt32.self, forKey: .plainTextHotKeyModifiers)
            ?? fallback.plainTextHotKeyModifiers
        plainTextHotKeyDisplayLabel = try container.decodeIfPresent(String.self, forKey: .plainTextHotKeyDisplayLabel)
            ?? fallback.plainTextHotKeyDisplayLabel
        defaultMaxItems = try container.decodeIfPresent(Int.self, forKey: .defaultMaxItems) ?? fallback.defaultMaxItems
        searchAllTabs = try container.decodeIfPresent(Bool.self, forKey: .searchAllTabs) ?? fallback.searchAllTabs
        syncPaused = try container.decodeIfPresent(Bool.self, forKey: .syncPaused) ?? fallback.syncPaused
        activation = try container.decodeIfPresent(ActivationOptions.self, forKey: .activation)
            ?? fallback.activation
        captureExclusions = try container.decodeIfPresent([CaptureExclusionRule].self, forKey: .captureExclusions)
            ?? fallback.captureExclusions
        // A blob written before this switch existed decodes to the protective
        // default, so an upgraded install is guarded without the user opting in.
        apiKeyGuardEnabled = try container.decodeIfPresent(Bool.self, forKey: .apiKeyGuardEnabled)
            ?? fallback.apiKeyGuardEnabled
        language = (try? container.decode(String.self, forKey: .language))
            .flatMap(AppLanguage.init(rawValue:)) ?? fallback.language
        theme = (try? container.decode(String.self, forKey: .theme))
            .flatMap(AppTheme.init(rawValue:)) ?? fallback.theme
        itemListFont = (try? container.decode(FontPreference.self, forKey: .itemListFont))
            ?? fallback.itemListFont
        editorFont = (try? container.decode(FontPreference.self, forKey: .editorFont))
            ?? fallback.editorFont
        windowLayout = (try? container.decode(String.self, forKey: .windowLayout))
            .flatMap(WindowLayout.init(rawValue:)) ?? fallback.windowLayout
        legacyWindowLayout = try? container.decode(String.self, forKey: .legacyWindowLayout)
        inspectorSplitRatio = InspectorSplitLayout.clampRatio(
            (try? container.decode(Double.self, forKey: .inspectorSplitRatio))
                ?? fallback.inspectorSplitRatio
        )
        sidebarWidth = SidebarLayout.clampWidth(
            (try? container.decode(Double.self, forKey: .sidebarWidth))
                ?? fallback.sidebarWidth
        )
        inspectorColumnWidth = InspectorColumnLayout.clampWidth(
            (try? container.decode(Double.self, forKey: .inspectorColumnWidth))
                ?? fallback.inspectorColumnWidth
        )
    }

    /// Clamps values that would make the app unusable.
    public func sanitized() -> Preferences {
        var copy = self
        copy.defaultMaxItems = min(max(defaultMaxItems, 1), 100_000)
        copy.captureExclusions = Preferences.normalizedCaptureExclusions(captureExclusions)
        copy.inspectorSplitRatio = InspectorSplitLayout.clampRatio(copy.inspectorSplitRatio)
        copy.sidebarWidth = SidebarLayout.clampWidth(copy.sidebarWidth)
        copy.inspectorColumnWidth = InspectorColumnLayout.clampWidth(copy.inspectorColumnWidth)
        return copy
    }

    /// Trims each rule, drops empty identifiers, and keeps the first rule for a
    /// bundle identifier so matching cannot depend on list order.
    private static func normalizedCaptureExclusions(
        _ rules: [CaptureExclusionRule]
    ) -> [CaptureExclusionRule] {
        var seen: Set<String> = []
        var normalized: [CaptureExclusionRule] = []
        for rule in rules {
            guard let rule = rule.normalized() else { continue }
            let key = rule.bundleIdentifier.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            normalized.append(rule)
        }
        return normalized
    }
}
