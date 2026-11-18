import AppKit
import SwiftUI

// MARK: - Styled editing toolbar

/// Bold, italic, underline, colour, and size: the five attributes the item
/// editor stores, and nothing else.
///
/// The buttons reflect the attributes at the selection, so a mixed document
/// shows what the next action applies to. Bold, italic, and underline answer to
/// the standard shortcuts, which the text view itself handles
/// (`StyledTextView.formatCommand`).
struct RichTextToolbar: View {
    @ObservedObject var controller: RichTextEditingController
    let language: AppLanguage

    private static let sizes: [Double] = [
        9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64,
    ]

    private var availableSizes: [Double] {
        let current = controller.pointSize
        guard !Self.sizes.contains(current) else { return Self.sizes }
        return (Self.sizes + [current]).sorted()
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
            styleButton(
                "bold",
                help: Localization.string(.richToolbarBold, language: language),
                isOn: controller.isBold
            ) { controller.toggle(.bold) }
            styleButton(
                "italic",
                help: Localization.string(.richToolbarItalic, language: language),
                isOn: controller.isItalic
            ) { controller.toggle(.italic) }
            styleButton(
                "underline",
                help: Localization.string(.richToolbarUnderline, language: language),
                isOn: controller.isUnderline
            ) { controller.toggle(.underline) }

            Divider().frame(height: 16).padding(.horizontal, DesignTokens.Spacing.xSmall)

            ColorPicker(
                Localization.string(.richToolbarTextColour, language: language),
                selection: Binding(
                    get: { Color(nsColor: controller.color) },
                    set: { controller.apply(color: NSColor($0)) }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 38)
            .help(Localization.string(.richToolbarTextColour, language: language))

            Button {
                controller.applyDefaultColor()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.hover)
            .tint(.primary)
            .help(Localization.string(.richToolbarDefaultColour, language: language))

            Divider().frame(height: 16).padding(.horizontal, DesignTokens.Spacing.xSmall)

            Picker(
                Localization.string(.richToolbarSize, language: language),
                selection: Binding(
                    get: { controller.pointSize },
                    set: { controller.apply(pointSize: $0) }
                )
            ) {
                ForEach(availableSizes, id: \.self) { size in
                    Text(Self.sizeLabel(size)).tag(size)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 84)
            .help(Localization.string(.richToolbarTextSize, language: language))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.xSmall)
        .padding(.vertical, DesignTokens.Spacing.compact)
    }

    private func styleButton(
        _ systemImage: String,
        help: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.tag, style: .continuous)
                        .fill(isOn ? DesignTokens.Colors.selection.opacity(0.16) : Color.clear)
                )
        }
        .buttonStyle(.hover)
        // A tint keeps the glyph legible on the glass surface; a foreground
        // style lets SwiftUI draw a vibrant image that disappears there.
        .tint(isOn ? DesignTokens.Colors.selection : DesignTokens.Colors.label)
        .help(help)
    }

    private static func sizeLabel(_ size: Double) -> String {
        size == size.rounded()
            ? "\(Int(size)) pt"
            : "\(size.formatted(.number.precision(.fractionLength(1)))) pt"
    }
}
