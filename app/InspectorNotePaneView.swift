import AppKit
import SwiftUI

// MARK: - Inspector Note Pane

struct InspectorNotePane: View {
    @ObservedObject var model: AppModel
    let selectedEntry: ClipboardEntry?
    @Binding var noteFocused: Bool

    var body: some View {
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
        .padding(DesignTokens.Spacing.small)
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { selectedEntry?.note ?? "" },
            set: { model.setNoteDraft($0) }
        )
    }
}
