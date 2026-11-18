import AppKit
import SwiftUI

// MARK: - Filter bar

struct FilterBarView: View {
    @ObservedObject var model: AppModel
    @FocusState.Binding var searchFocused: Bool

    var body: some View {
        let lang = model.preferences.language
        HStack(spacing: DesignTokens.Spacing.medium) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                Localization.string(.filterItemsPlaceholder, language: lang),
                text: $model.searchText
            )
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.hover)
                .help(Localization.string(.filterClearHelp, language: lang))
            }
            Spacer(minLength: DesignTokens.Spacing.medium)
            Toggle(Localization.string(.filterAllTabsToggle, language: lang), isOn: Binding(
                get: { model.preferences.searchAllTabs },
                set: { model.setSearchAllTabs($0) }
            ))
            .toggleStyle(.checkbox)
            .help(Localization.string(.filterSearchAllTabsHelp, language: lang))
        }
        .padding(.horizontal, DesignTokens.Spacing.bar)
        .padding(.vertical, DesignTokens.Spacing.small)
    }
}
