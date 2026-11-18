import AppKit
import SwiftUI

// MARK: - Sidebar

struct SidebarTabView: View {
    @ObservedObject var model: AppModel
    @FocusState private var listFocused: Bool

    var body: some View {
        let lang = model.preferences.language
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.selectedTabID },
                set: {
                    if let id = $0 {
                        model.selectTab(id)
                        model.setSidebarFocused(true)
                    }
                }
            )) {
                ForEach(model.tabs) { tab in
                    SidebarTabRow(model: model, tab: tab)
                        .tag(tab.id)
                }
                .onMove { indices, destination in
                    reorderTabs(from: indices, to: destination)
                }
            }
            .listStyle(.sidebar)
            .focused($listFocused)
            .onChange(of: listFocused) { _, focused in
                model.setSidebarFocused(focused)
            }

            Divider().opacity(0.35)

            HStack {
                Button {
                    model.addTab(named: "Tab \(model.tabs.count + 1)")
                } label: {
                    Label(
                        Localization.string(.menuTabsNewTab, language: lang),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.hover)
                .font(DesignTokens.Typography.caption)
                .help(Localization.string(.tabBarNewTabHelp, language: lang))

                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.medium)
            .padding(.vertical, DesignTokens.Spacing.small)
        }
    }

    private func reorderTabs(from source: IndexSet, to destination: Int) {
        for index in source {
            let delta = destination > index ? destination - index - 1 : destination - index
            guard delta != 0 else { continue }
            let step = delta > 0 ? 1 : -1
            let tab = model.tabs[index]
            for _ in 0..<abs(delta) {
                model.moveTab(tab, delta: step)
            }
        }
    }
}
