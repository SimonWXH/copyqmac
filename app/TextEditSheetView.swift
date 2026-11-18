import AppKit
import SwiftUI

// MARK: - Item text editor

/// A save failure the sheet shows, kept unresolved so it follows a language
/// switch made while the sheet is open.
enum TextEditSheetError {
    case saveFailure(String)
    case richFormatUnsupported

    func message(language: AppLanguage) -> String {
        switch self {
        case .saveFailure(let message):
            return Localization.runtimeMessage(message, language: language)
        case .richFormatUnsupported:
            return Localization.string(.textEditRichFormatError, language: language)
        }
    }
}

/// Sheet for editing an entry's text or typing a new item.
///
/// A plain-text entry opens the plain editor, unchanged: saving keeps its
/// images, files, and itemsync base-name bookkeeping flavour, replaces the
/// plain-text flavours, and drops every other attachment that described the old
/// text. An HTML or RTF entry opens the styled editor instead, with the
/// toolbar's five attributes, and saves its document back in the format the
/// entry stores; a plain entry is never upgraded to a rich one. Creating a new
/// item writes the typed text as a new entry in the current tab.
struct TextEditSheet: View {
    let request: PendingTextEdit
    let language: AppLanguage
    let onSave: (TextEditSubmission) -> String?
    let onCancel: () -> Void

    @State private var text: String
    /// The editor font fixed when the sheet opens, or nil while the preference
    /// is untouched so each editor keeps the font it drew with before the
    /// setting existed.
    ///
    /// The styled editor applies its base font while it loads the item, the way
    /// CopyQ sets the editor font before loading an entry's HTML, so a settings
    /// change mid-edit applies to the next item instead of restyling text the
    /// user is editing.
    @State private var editorFont: NSFont?
    @State private var error: TextEditSheetError?
    @StateObject private var richController = RichTextEditingController()

    init(
        request: PendingTextEdit,
        language: AppLanguage,
        font: FontPreference,
        onSave: @escaping (TextEditSubmission) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.language = language
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: request.text)
        _editorFont = State(initialValue: font.chosenFont)
    }

    private var canSave: Bool {
        if request.rich != nil { return richController.hasText }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var submission: TextEditSubmission {
        if request.rich != nil { return .styled(richController.document()) }
        return .text(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            Text(request.title(language: language))
                .font(.title3.weight(.semibold))

            if let detail = request.detailText(language: language) {
                Label {
                    Text(detail)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(DesignTokens.Typography.callout)
                .foregroundStyle(.secondary)
            }

            editor

            if let error {
                Text(error.message(language: language))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Colors.destructive)
            }

            HStack(spacing: DesignTokens.Spacing.medium) {
                if !canSave {
                    Text(Localization.string(.textEditEmptyWarning, language: language))
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(Localization.string(.buttonCancel, language: language), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmTitle(language: language)) {
                    if let format = request.rich?.format,
                       !richController.isRepresentable(for: format) {
                        error = .richFormatUnsupported
                        return
                    }
                    error = onSave(submission).map { .saveFailure($0) }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
            }
        }
        .padding(DesignTokens.Spacing.xxLarge)
        .frame(minWidth: 540, minHeight: 380)
    }

    @ViewBuilder
    private var editor: some View {
        if let seed = request.rich {
            // The toolbar is part of the editor surface, so the controls and
            // the text they act on read as one panel.
            VStack(alignment: .leading, spacing: 0) {
                RichTextToolbar(controller: richController, language: language)
                Divider()
                RichTextEditor(
                    seed: seed.document,
                    format: seed.format,
                    font: editorFont,
                    controller: richController
                )
                    .frame(minHeight: 190, maxHeight: .infinity)
            }
            .padding(DesignTokens.Spacing.medium)
            .frame(minHeight: 220, maxHeight: .infinity)
            .glassSurface(cornerRadius: DesignTokens.Radius.card)
        } else {
            // The editor draws with the configured editor font (the app's body
            // font until one is chosen) and keeps its first line clear of the
            // clip; `TextEditor` clipped the tops of tall CJK glyphs there. See
            // `PlainTextEditor`.
            PlainTextEditor(text: $text, font: editorFont, focusOnAttach: true)
                .padding(DesignTokens.Spacing.medium)
                .frame(minHeight: 220, maxHeight: .infinity)
                .glassSurface(cornerRadius: DesignTokens.Radius.card)
        }
    }
}
