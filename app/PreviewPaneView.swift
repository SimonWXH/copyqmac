import AppKit
import SwiftUI

// MARK: - Preview pane

struct PreviewPaneView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var selection: SelectionState
    @State private var noteFocused = false

    private var selectedEntry: ClipboardEntry? {
        guard let id = selection.selectedEntryID else { return nil }
        return model.entries.first { $0.id == id }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.large) {
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

            noteEditor
                .frame(width: 240)
        }
        .padding(DesignTokens.Spacing.large)
        .frame(height: 170)
        // The note-editing session is started by the editor itself, when its text
        // view takes or loses focus, not from here: a SwiftUI state round trip is
        // slower than the first keystroke, and the model drops a draft that
        // arrives before the session exists.
        .onChange(of: model.focusNoteToken) { _, _ in noteFocused = true }
        .onChange(of: model.noteBlurToken) { _, _ in noteFocused = false }
    }

    @ViewBuilder
    private var previewContent: some View {
        let lang = model.preferences.language
        if let entry = selectedEntry {
            let presentation = model.presentation(for: entry)
            switch presentation?.kind {
            case .image:
                if let previewImage = model.selectedPreviewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.media, style: .continuous)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                } else if let thumbnail = model.thumbnail(for: entry, maxSize: 140) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.media, style: .continuous)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                } else {
                    Text(Localization.string(.previewImageUnavailable, language: lang))
                        .foregroundStyle(.secondary)
                }
            case .files:
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                        ForEach(Array((presentation?.fileURLs ?? []).enumerated()), id: \.offset) { _, url in
                            HStack(spacing: DesignTokens.Spacing.small) {
                                if let icon = model.fileIcon(forPath: url.path) {
                                    Image(nsImage: icon)
                                        .resizable().frame(width: 16, height: 16)
                                }
                                Text(url.lastPathComponent).font(DesignTokens.Typography.callout).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let richText = model.richText(for: entry) {
                            // HTML and RTF keep their fonts, headings, and
                            // colours here, the way CopyQ previews a rich item.
                            Text(richText.preview)
                                .textSelection(.enabled)
                        } else {
                            Text(presentation?.searchText ?? presentation?.primaryText ?? "")
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        } else {
            Text(Localization.string(.previewSelectPrompt, language: lang))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            Label(
                Localization.string(.previewNoteLabel, language: model.preferences.language),
                systemImage: "note.text"
            )
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            PlainTextEditor(
                text: noteBinding,
                font: PlainTextEditor.noteFont,
                isFocused: $noteFocused,
                onEditingChanged: { model.setNoteEditing($0) }
            )
                .frame(maxHeight: .infinity)
                .padding(DesignTokens.Spacing.small)
                .glassSurface(cornerRadius: DesignTokens.Radius.panel)
                .disabled(selectedEntry == nil)
        }
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { selectedEntry?.note ?? "" },
            set: { model.setNoteDraft($0) }
        )
    }
}
