// Design tokens: semantic colours, spacing scale, radius hierarchy, and typography.

import AppKit
import SwiftUI

public enum DesignTokens {
    // MARK: - Semantic Colours

    public enum Colors {
        /// Primary label / text colour.
        public static let label = Color.primary
        /// Window background surface colour.
        public static let windowBackground = Color(nsColor: .windowBackgroundColor)
        /// System accent and selection colour.
        public static let selection = Color.accentColor
        /// Destructive actions and failure text.
        public static let destructive = Color.red
        /// Attention accent for notices, pinned items, and permission reminders.
        public static let notice = Color.orange
    }

    // MARK: - Spacing Scale

    public enum Spacing {
        /// 1pt: Hairline gap between stacked labels and around badges.
        public static let hairline: CGFloat = 1
        /// 2pt: Micro spacing (sub-element offsets, badges).
        public static let xxSmall: CGFloat = 2
        /// 4pt: Extra small spacing (inner padding, compact gaps).
        public static let xSmall: CGFloat = 4
        /// 5pt: Compact inset for chips, the status bar, and the editing toolbar.
        public static let compact: CGFloat = 5
        /// 6pt: Small gap between related inline items.
        public static let small: CGFloat = 6
        /// 8pt: Standard item spacing.
        public static let medium: CGFloat = 8
        /// 10pt: Standard inset and inter-item gap.
        public static let card: CGFloat = 10
        /// 12pt: Section separation.
        public static let large: CGFloat = 12
        /// 14pt: Horizontal inset of the filter bar and the status bar.
        public static let bar: CGFloat = 14
        /// 16pt: Window edge inset.
        public static let xLarge: CGFloat = 16
        /// 20pt: Sheet padding.
        public static let xxLarge: CGFloat = 20
    }

    // MARK: - Radius Hierarchy

    public enum Radius {
        /// 12pt: Top-level surfaces (the notice banner plate).
        public static let topLevel: CGFloat = 12
        /// 10pt: Content plates (sync folder card and editor surfaces).
        public static let card: CGFloat = 10
        /// 8pt: Panels (tab chips and the note editor).
        public static let panel: CGFloat = 8
        /// 6pt: Inline image borders.
        public static let media: CGFloat = 6
        /// 5pt: Tags (thumbnails, fallback icons, toolbar buttons).
        public static let tag: CGFloat = 5
    }

    // MARK: - Typography

    public enum Typography {
        /// Section and group headings.
        public static let headline = Font.headline
        /// Secondary descriptive text.
        public static let callout = Font.callout
        /// Footnotes and secondary metadata.
        public static let caption = Font.caption
        /// The smallest metadata text.
        public static let caption2 = Font.caption2

        /// Base body font for AppKit rendering.
        public static var defaultBodyFont: NSFont {
            NSFont.preferredFont(forTextStyle: .body)
        }

        /// Resolves an item list font preference into an NSFont.
        public static func resolveItemListFont(preference: FontPreference) -> NSFont {
            let fallback = defaultBodyFont
            let size = preference.pointSize.map { CGFloat($0) } ?? fallback.pointSize
            guard let family = preference.family, !family.isEmpty else {
                return preference.pointSize == nil ? fallback : NSFont.systemFont(ofSize: size)
            }
            return NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)
        }

        /// Resolves an editor font preference into an NSFont? (nil when preference is default).
        public static func resolveEditorFont(preference: FontPreference) -> NSFont? {
            guard !preference.isDefault else { return nil }
            return resolveItemListFont(preference: preference)
        }
    }
}

// MARK: - FontPreference Extension

extension FontPreference {
    /// Resolves this preference to an NSFont for rendering, falling back to the system body font.
    public var nsFont: NSFont {
        DesignTokens.Typography.resolveItemListFont(preference: self)
    }

    /// Resolves this preference to an NSFont for surfaces with their own defaults, or nil if untouched.
    public var chosenFont: NSFont? {
        DesignTokens.Typography.resolveEditorFont(preference: self)
    }
}

// MARK: - AppTheme Extensions

extension AppTheme {
    /// The appearance name this theme forces, keeping the system's Increase Contrast variant.
    /// `.system` returns nil so the system decides both scheme and contrast.
    public func appearanceName(increaseContrast: Bool) -> NSAppearance.Name? {
        switch self {
        case .system:
            return nil
        case .light:
            return increaseContrast ? .accessibilityHighContrastAqua : .aqua
        case .dark:
            return increaseContrast ? .accessibilityHighContrastDarkAqua : .darkAqua
        }
    }
}
