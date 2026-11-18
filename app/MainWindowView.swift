// The main CopyQmac window. Layout A is the classic arrangement: a tab strip,
// a filter field, the numbered item list, a preview pane with the note editor,
// and a status bar. Layout B moves the tab list into a sidebar, the filter into
// a unified toolbar, and the preview and note into a trailing inspector.
// `Preferences.windowLayout` chooses between them.
//
// The window is the primary surface (the menu-bar item only shows and hides
// it). Styling follows macOS 26: system font, Liquid Glass surfaces, and the
// native blue selection highlight in the list.

import AppKit
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool
    @State private var renameText = ""

    var body: some View {
        let lang = model.preferences.language
        Group {
            switch model.preferences.windowLayout {
            case .layoutA:
                LayoutAView(
                    model: model,
                    searchFocused: $searchFocused,
                    onDismiss: onDismiss
                )
            case .layoutB:
                LayoutBView(
                    model: model,
                    searchFocused: $searchFocused,
                    onDismiss: onDismiss
                )
            }
        }
        .background(WindowBackground())
        // The smallest size the layout can take. The window uses it as its
        // minimum size, so it cannot be dragged into a shape the list, the
        // preview pane, and the note editor do not fit in.
        .frame(minWidth: 640, minHeight: 460)
        .onAppear {
            model.applyRichTextAppearance(RichTextAppearance(colorScheme: colorScheme))
        }
        .onChange(of: colorScheme) { _, scheme in
            model.applyRichTextAppearance(RichTextAppearance(colorScheme: scheme))
        }
        .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
        .onChange(of: searchFocused) { _, focused in model.setFilterFocused(focused) }
        .onChange(of: model.preferences.windowLayout) { _, _ in model.setSidebarFocused(false) }
        .onChange(of: model.pendingRenameTabID) { _, newValue in
            guard let newValue,
                  let tab = model.tabs.first(where: { $0.id == newValue }) else { return }
            renameText = tab.name
        }
        .alert(Localization.string(.alertRenameTabTitle, language: lang), isPresented: renameBinding) {
            TextField(Localization.string(.alertRenameTabPlaceholder, language: lang), text: $renameText)
            Button(Localization.string(.alertRenameTabConfirm, language: lang)) {
                if let id = model.pendingRenameTabID,
                   let tab = model.tabs.first(where: { $0.id == id }) {
                    model.renameTab(tab, to: renameText)
                }
                model.pendingRenameTabID = nil
            }
            Button(Localization.string(.alertRenameTabCancel, language: lang), role: .cancel) { model.pendingRenameTabID = nil }
        } message: {
            Text(Localization.string(.alertRenameTabMessage, language: lang))
        }
        .sheet(item: $model.pendingTextEdit) { request in
            TextEditSheet(
                request: request,
                language: model.preferences.language,
                font: model.preferences.editorFont,
                onSave: { submission in model.commitTextEdit(submission) },
                onCancel: { model.cancelTextEdit() }
            )
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { model.pendingRenameTabID != nil },
            set: { if !$0 { model.pendingRenameTabID = nil } }
        )
    }
}

// MARK: - Window background

/// The body of the window.
///
/// It is opaque on purpose: the list, the preview pane, and the status bar
/// must not show the desktop wallpaper through them. The glass surfaces are
/// accents inside the window (the tab chips, the notice, the note editor),
/// not the window itself.
private struct WindowBackground: View {
    var body: some View {
        DesignTokens.Colors.windowBackground
    }
}
