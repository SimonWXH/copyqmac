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
        /// Dynamic NSColor for unified button hover feedback.
        public static let hoverNSColor = NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            if match == .darkAqua {
                return NSColor.labelColor.withAlphaComponent(0.10)
            } else {
                return NSColor.labelColor.withAlphaComponent(0.07)
            }
        }
        /// Neutral hover feedback colour (label at ~7% opacity in light mode, ~10% in dark mode).
        public static let hover = Color(nsColor: hoverNSColor)

        /// Dynamic NSColor for pressed button feedback.
        public static let hoverPressedNSColor = NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            if match == .darkAqua {
                return NSColor.labelColor.withAlphaComponent(0.16)
            } else {
                return NSColor.labelColor.withAlphaComponent(0.12)
            }
        }
        /// Pressed feedback colour (slightly darker shade of the hover colour).
        public static let hoverPressed = Color(nsColor: hoverPressedNSColor)
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

    // MARK: - Reusable Button Styles

    public enum Buttons {
        /// Unified hover button style using `DesignTokens.Radius.tag`.
        public static let hover = HoverButtonStyle()

        /// Unified hover button style with custom corner radius and optional hover binding.
        public static func hover(
            cornerRadius: CGFloat = DesignTokens.Radius.tag,
            hovering: Binding<Bool>? = nil
        ) -> HoverButtonStyle {
            HoverButtonStyle(cornerRadius: cornerRadius, hovering: hovering)
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

// MARK: - Hover Button Style

/// A button style providing neutral hover and pressed background feedback.
public struct HoverButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat
    public var hovering: Binding<Bool>?

    public init(
        cornerRadius: CGFloat = DesignTokens.Radius.tag,
        hovering: Binding<Bool>? = nil
    ) {
        self.cornerRadius = cornerRadius
        self.hovering = hovering
    }

    /// Resolves the background colour for the given hover, pressed, and enabled state.
    public static func backgroundColor(
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Color {
        guard isEnabled else { return Color.clear }
        if isPressed {
            return DesignTokens.Colors.hoverPressed
        } else if isHovering {
            return DesignTokens.Colors.hover
        } else {
            return Color.clear
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            externalHovering: hovering
        )
    }

    private struct HoverButtonBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let externalHovering: Binding<Bool>?

        @Environment(\.isEnabled) private var isEnabled
        @State private var internalHovering = false

        private var isHovering: Bool {
            externalHovering?.wrappedValue ?? internalHovering
        }

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(HoverButtonStyle.backgroundColor(
                            isHovering: isHovering,
                            isPressed: configuration.isPressed,
                            isEnabled: isEnabled
                        ))
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onHover { hovering in
                    guard isEnabled else {
                        if internalHovering { internalHovering = false }
                        if externalHovering?.wrappedValue == true { externalHovering?.wrappedValue = false }
                        return
                    }
                    internalHovering = hovering
                    externalHovering?.wrappedValue = hovering
                }
                .animation(.easeInOut(duration: 0.12), value: isHovering)
                .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    /// Unified hover button style using `DesignTokens.Radius.tag`.
    public static var hover: HoverButtonStyle {
        HoverButtonStyle()
    }

    /// Unified hover button style with custom corner radius and optional hover binding.
    public static func hover(
        cornerRadius: CGFloat = DesignTokens.Radius.tag,
        hovering: Binding<Bool>? = nil
    ) -> HoverButtonStyle {
        HoverButtonStyle(cornerRadius: cornerRadius, hovering: hovering)
    }
}
