import AppKit
import SwiftUI

// MARK: - Status bar

struct StatusBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let lang = model.preferences.language
        HStack(spacing: DesignTokens.Spacing.large) {
            Text(Localization.itemCount(model.entries.count, language: lang))
            if let tab = model.selectedTab {
                Text(Localization.tabInfo(name: tab.name, isDefault: tab.isDefault, language: lang))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let exportStatus = model.exportStatus {
                Text(exportStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(exportStatus)
            }
            // The record of the last failure. The banner explains it for a few
            // seconds; this stays until the user has read it and clicks it away,
            // so an error is never lost just because nobody was looking.
            if model.showsFailureStatusItem, let failure = model.failureNotice {
                Button {
                    model.dismissFailureNotice()
                } label: {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, DesignTokens.Spacing.xSmall)
                        .padding(.vertical, DesignTokens.Spacing.xxSmall)
                }
                .buttonStyle(.hover)
                .foregroundStyle(DesignTokens.Colors.destructive)
                .help(Localization.format(.statusBarDismissTooltip, language: lang, failure))
            }
            // The persistent surface for a missing Accessibility permission.
            // It stays quiet while the permission banner is on screen - the
            // banner already explains the same thing - and takes over once the
            // banner fades. A granted app shows no accessibility text here.
            if model.showsAccessibilityStatusItem {
                Button {
                    model.grantAccessibility()
                } label: {
                    Label(
                        Localization.string(.statusBarAccessibilityNotGranted, language: lang),
                        systemImage: "lock.shield"
                    )
                    .lineLimit(1)
                    .padding(.horizontal, DesignTokens.Spacing.xSmall)
                    .padding(.vertical, DesignTokens.Spacing.xxSmall)
                }
                .buttonStyle(.hover)
                .foregroundStyle(DesignTokens.Colors.notice)
                .help(Localization.string(.statusBarAccessibilityHelp, language: lang))
            }
            Text(Localization.hotKeyLabel(model.preferences.hotKeyDisplayLabel, language: lang))
                .foregroundStyle(.secondary)
        }
        .font(DesignTokens.Typography.caption)
        .padding(.horizontal, DesignTokens.Spacing.bar)
        .padding(.vertical, DesignTokens.Spacing.compact)
    }
}
