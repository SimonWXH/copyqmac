import AppKit
import SwiftUI

// MARK: - Tab bar

struct TabBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let lang = model.preferences.language
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.small) {
                ForEach(model.tabs) { tab in
                    TabChip(model: model, tab: tab)
                }
                Button {
                    model.addTab(named: "Tab \(model.tabs.count + 1)")
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.hover)
                .help(Localization.string(.tabBarNewTabHelp, language: lang))
                .padding(.leading, DesignTokens.Spacing.xxSmall)
            }
            .padding(.horizontal, DesignTokens.Spacing.large)
            .padding(.vertical, DesignTokens.Spacing.medium)
        }
    }
}
