import AppKit
import SwiftUI

// MARK: - Layout A (Classic)

struct LayoutAView: View {
    @ObservedObject var model: AppModel
    @FocusState.Binding var searchFocused: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(model: model)
            Divider().opacity(0.35)
            FilterBarView(model: model, searchFocused: $searchFocused)
            Divider().opacity(0.35)
            ItemListView(model: model, onDismiss: onDismiss)
            Divider().opacity(0.35)
            PreviewPaneView(model: model, selection: model.selection)
            Divider().opacity(0.35)
            StatusBarView(model: model)
        }
    }
}
