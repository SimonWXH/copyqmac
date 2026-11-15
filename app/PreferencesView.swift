// Preferences window (F-11): history, tabs, and the summon shortcut.

import AppKit
import SwiftUI

private enum PreferencesTab: Hashable {
    case history
    case tabs
    case ignoredApps
    case shortcut
}

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    let fontFamilies: FontFamilyCatalog
    @State private var renamingTab: ClipboardTab?
    @State private var renameText = ""
    @State private var selectedTab: PreferencesTab = .history

    var body: some View {
        let lang = model.preferences.language
        TabView(selection: $selectedTab) {
            HistoryPreferences(model: model, fontFamilies: fontFamilies)
                .tabItem { Label(Localization.string(.settingsTabHistory, language: lang), systemImage: "clock") }
                .tag(PreferencesTab.history)
            TabsPreferences(model: model, renamingTab: $renamingTab, renameText: $renameText)
                .tabItem { Label(Localization.string(.settingsTabTabs, language: lang), systemImage: "square.on.square") }
                .tag(PreferencesTab.tabs)
            IgnoredAppsPreferences(model: model)
                .tabItem { Label(Localization.string(.settingsTabIgnoredApps, language: lang), systemImage: "hand.raised") }
                .tag(PreferencesTab.ignoredApps)
            ShortcutPreferences(model: model)
                .tabItem { Label(Localization.string(.settingsTabShortcut, language: lang), systemImage: "keyboard") }
                .tag(PreferencesTab.shortcut)
        }
        .id(lang)
        .padding(DesignTokens.Spacing.xLarge)
        .frame(minWidth: 560, minHeight: 420)
        .alert(Localization.string(.alertRenameTabTitle, language: lang), isPresented: renameBinding) {
            TextField(Localization.string(.alertRenameTabPlaceholder, language: lang), text: $renameText)
            Button(Localization.string(.alertRenameTabConfirm, language: lang)) {
                if let tab = renamingTab { model.renameTab(tab, to: renameText) }
                renamingTab = nil
            }
            Button(Localization.string(.alertRenameTabCancel, language: lang), role: .cancel) { renamingTab = nil }
        } message: {
            Text(Localization.string(.alertRenameTabMessage, language: lang))
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingTab != nil },
            set: { if !$0 { renamingTab = nil } }
        )
    }
}

// MARK: - History

private struct HistoryPreferences: View {
    @ObservedObject var model: AppModel
    @ObservedObject var fontFamilies: FontFamilyCatalog
    @State private var maxItemsText = ""
    @FocusState private var maxItemsFocused: Bool

    var body: some View {
        let lang = model.preferences.language
        Form {
            Section(Localization.string(.settingsSectionAppearance, language: lang)) {
                Picker(
                    Localization.string(.settingsThemeLabel, language: lang),
                    selection: themeBinding
                ) {
                    Text(Localization.string(.settingsThemeSystem, language: lang)).tag(AppTheme.system)
                    Text(Localization.string(.settingsThemeLight, language: lang)).tag(AppTheme.light)
                    Text(Localization.string(.settingsThemeDark, language: lang)).tag(AppTheme.dark)
                }
                .pickerStyle(.segmented)
                Text(Localization.string(.settingsThemeDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)

                Picker(
                    Localization.string(.settingsWindowLayoutLabel, language: lang),
                    selection: windowLayoutBinding
                ) {
                    Text(Localization.string(.settingsWindowLayoutTopTabs, language: lang)).tag(WindowLayout.layoutA)
                    Text(Localization.string(.settingsWindowLayoutSidebarInspector, language: lang)).tag(WindowLayout.layoutB)
                }
                .pickerStyle(.segmented)
                Text(Localization.string(.settingsWindowLayoutDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }

            Section(Localization.string(.settingsSectionLanguage, language: lang)) {
                Picker(
                    Localization.string(.settingsLanguageLabel, language: lang),
                    selection: languageBinding
                ) {
                    Text(AppLanguage.english.displayName).tag(AppLanguage.english)
                    Text(AppLanguage.simplifiedChinese.displayName).tag(AppLanguage.simplifiedChinese)
                }
                .pickerStyle(.segmented)
                Text(Localization.string(.settingsLanguageDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }

            Section(Localization.string(.settingsSectionFonts, language: lang)) {
                FontPreferenceRow(
                    label: Localization.string(.settingsItemListFontLabel, language: lang),
                    detail: Localization.string(.settingsItemListFontDetail, language: lang),
                    language: lang,
                    families: fontFamilies.itemList,
                    preference: Binding(
                        get: { model.preferences.itemListFont },
                        set: { value in model.updatePreferences { $0.itemListFont = value } }
                    )
                )
                FontPreferenceRow(
                    label: Localization.string(.settingsEditorFontLabel, language: lang),
                    detail: Localization.string(.settingsEditorFontDetail, language: lang),
                    language: lang,
                    families: fontFamilies.editor,
                    preference: Binding(
                        get: { model.preferences.editorFont },
                        set: { value in model.updatePreferences { $0.editorFont = value } }
                    )
                )
            }

            Section {
                HStack {
                    Stepper(
                        value: maxItemsBinding,
                        in: 1...100_000,
                        step: 50
                    ) {
                        Text(Localization.string(.settingsMaxItemsLabel, language: lang))
                    }
                    TextField("", text: $maxItemsText)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .focused($maxItemsFocused)
                        .onSubmit { commitMaxItems(); maxItemsFocused = false }
                }
                Text(Localization.string(.settingsMaxItemsDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    Localization.string(.settingsSearchAllTabsToggle, language: lang),
                    isOn: Binding(
                        get: { model.preferences.searchAllTabs },
                        set: { model.setSearchAllTabs($0) }
                    )
                )
                Text(Localization.string(.settingsSearchAllTabsDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }

            Section(Localization.string(.settingsActivationSection, language: lang)) {
                Toggle(
                    Localization.string(.settingsActivationSingleClick, language: lang),
                    isOn: activationBinding(\.singleClickActivates)
                )
                Text(Localization.string(.settingsActivationSingleClickDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    Localization.string(.settingsActivationPaste, language: lang),
                    isOn: activationBinding(\.paste)
                )
                Text(Localization.string(.settingsActivationPasteDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    Localization.string(.settingsActivationFocus, language: lang),
                    isOn: activationBinding(\.focusPreviousApp)
                )
                Text(Localization.string(.settingsActivationFocusDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    Localization.string(.settingsActivationCloseWindow, language: lang),
                    isOn: activationBinding(\.closeWindow)
                )
                Text(Localization.string(.settingsActivationCloseWindowDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    Localization.string(.settingsActivationMoveToTop, language: lang),
                    isOn: activationBinding(\.moveToTop)
                )
                Text(Localization.string(.settingsActivationMoveToTopDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    Localization.string(.settingsLaunchAtLoginToggle, language: lang),
                    isOn: launchAtLoginBinding
                )
                .disabled(model.launchAtLogin.isUnavailable)
                Text(launchAtLoginDetail)
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
                if let problem = model.launchAtLoginProblem {
                    Text(Localization.runtimeMessage(problem, language: lang))
                        .font(DesignTokens.Typography.callout)
                        .foregroundStyle(DesignTokens.Colors.destructive)
                }
                if model.launchAtLogin == .requiresApproval {
                    Button(Localization.string(.settingsOpenLoginItemsButton, language: lang)) {
                        model.openLoginItemsSettings()
                    }
                }
            }

            Section {
                HStack {
                    Text(Localization.string(.settingsStoredItemsLabel, language: lang))
                    Spacer()
                    Text("\(model.totalEntryCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            syncMaxItemsText()
            // The user may have changed Login Items in System Settings since
            // the app last looked, so the toggle always starts from the truth.
            model.refreshLaunchAtLoginState()
        }
        .onChange(of: model.preferences.defaultMaxItems) { _, _ in
            if !maxItemsFocused { syncMaxItemsText() }
        }
        .onChange(of: maxItemsFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused { commitMaxItems() }
        }
        .onDisappear(perform: commitMaxItems)
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { model.preferences.theme },
            set: { value in model.updatePreferences { $0.theme = value } }
        )
    }

    private var windowLayoutBinding: Binding<WindowLayout> {
        Binding(
            get: { model.preferences.windowLayout },
            set: { value in model.updatePreferences { $0.windowLayout = value } }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.preferences.language },
            set: { value in model.updatePreferences { $0.language = value } }
        )
    }

    private var maxItemsBinding: Binding<Int> {
        Binding(
            get: { model.preferences.defaultMaxItems },
            set: { value in model.updatePreferences { $0.defaultMaxItems = value } }
        )
    }

    /// One History ▸ Activation switch. The whole group is stored together, so
    /// a change rewrites one preferences blob.
    private func activationBinding(
        _ keyPath: WritableKeyPath<ActivationOptions, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.preferences.activation[keyPath: keyPath] },
            set: { value in model.setActivation { $0[keyPath: keyPath] = value } }
        )
    }

    /// The toggle mirrors the real registration state, never a stored flag.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin.isEnabled },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private var launchAtLoginDetail: String {
        let lang = model.preferences.language
        switch model.launchAtLogin {
        case .enabled:
            return Localization.string(.settingsLaunchAtLoginEnabledDetail, language: lang)
        case .disabled:
            return Localization.string(.settingsLaunchAtLoginDisabledDetail, language: lang)
        case .requiresApproval:
            return Localization.string(.settingsLaunchAtLoginApprovalDetail, language: lang)
        case .unavailable(let reason):
            return Localization.runtimeMessage(reason, language: lang)
        }
    }

    private func syncMaxItemsText() {
        maxItemsText = String(model.preferences.defaultMaxItems)
    }

    private func commitMaxItems() {
        guard let value = Int(maxItemsText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            syncMaxItemsText()
            return
        }
        guard value != model.preferences.defaultMaxItems else { return }
        model.updatePreferences { $0.defaultMaxItems = value }
        syncMaxItemsText()
    }
}

// MARK: - Fonts

/// The installed font families the font pickers offer.
///
/// Reading and filtering the installed families costs more than a settings
/// layout pass, so the preferences window loads this when it is shown instead of
/// on every body evaluation: a font installed while the app runs appears the
/// next time Preferences opens.
@MainActor
final class FontFamilyCatalog: ObservableObject {
    /// Every installed family, which the item list may use: its font never
    /// reaches a payload.
    @Published private(set) var itemList: [String] = []
    /// The installed families whose default face both rich-text writers record
    /// unchanged.
    ///
    /// An editor font is written into the item's own document, so a family or
    /// face the writer would rename would refuse every save of an item the
    /// editor opened.
    @Published private(set) var editor: [String] = []

    func load() {
        let installed = NSFontManager.shared.availableFontFamilies.sorted()
        itemList = installed
        editor = installed.filter { family in
            guard let font = NSFont(
                name: family,
                size: CGFloat(StyledTextDocument.defaultPointSize)
            ) else { return false }
            return RichTextEditing.isRepresentable(font: font, format: .html)
                && RichTextEditing.isRepresentable(font: font, format: .rtf)
        }
    }
}

/// One font setting: the family picker and the point size.
///
/// `families` is what the picker offers besides the system entry, and the
/// stored family stays in the list even when it is no longer offered, so it
/// still shows as the selected value instead of silently reading as "System".
///
/// Not private so the tests can host the real row and drive its picker and
/// stepper, the way `TabSettingsRow` is hosted for its field.
struct FontPreferenceRow: View {
    let label: String
    let detail: String
    let language: AppLanguage
    /// The families this surface may draw with.
    let families: [String]
    @Binding var preference: FontPreference

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(spacing: DesignTokens.Spacing.large) {
                Text(label)
                Spacer(minLength: DesignTokens.Spacing.large)
                Picker(
                    Localization.string(.settingsFontFamilyLabel, language: language),
                    selection: familyBinding
                ) {
                    Text(Localization.string(.settingsFontSystemOption, language: language))
                        .tag(String?.none)
                    ForEach(familyChoices, id: \.self) { family in
                        Text(family).tag(String?.some(family))
                    }
                }
                .labelsHidden()
                .frame(width: 200)

                HStack(spacing: DesignTokens.Spacing.medium) {
                    Text("\(Int(preference.nsFont.pointSize.rounded())) pt")
                        .monospacedDigit()
                    Stepper(
                        Localization.string(.settingsFontSizeLabel, language: language),
                        value: sizeBinding,
                        in: 6...200,
                        step: 1
                    )
                    .labelsHidden()
                    .help(Localization.string(.settingsFontSizeLabel, language: language))
                }
                .frame(width: 78, alignment: .trailing)
            }
            Text(detail)
                .font(DesignTokens.Typography.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var familyChoices: [String] {
        var choices = families
        if let family = preference.family,
           !family.isEmpty,
           !choices.contains(family) {
            choices.insert(family, at: 0)
        }
        return choices
    }

    private var familyBinding: Binding<String?> {
        Binding(
            get: { preference.family },
            set: { family in
                var updated = preference
                updated.family = family
                // Plain "System" also drops a chosen size, so it means exactly
                // what it says: the font the surface drew with before this
                // setting existed.
                if family == nil { updated.pointSize = nil }
                preference = updated
            }
        )
    }

    private var sizeBinding: Binding<Int> {
        Binding(
            get: { Int(preference.nsFont.pointSize.rounded()) },
            set: { value in
                var updated = preference
                updated.pointSize = Double(value)
                preference = updated
            }
        )
    }
}

// MARK: - Ignored apps

private struct IgnoredAppsPreferences: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let lang = model.preferences.language
        Form {
            Section {
                Text(Localization.string(.settingsIgnoredAppsExplanation, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    Localization.string(.settingsAPIKeyGuardToggle, language: lang),
                    isOn: Binding(
                        get: { model.preferences.apiKeyGuardEnabled },
                        set: { model.setAPIKeyGuardEnabled($0) }
                    )
                )
                Text(Localization.string(.settingsAPIKeyGuardDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }

            Section(Localization.string(.settingsIgnoredAppsHeader, language: lang)) {
                if model.preferences.captureExclusions.isEmpty {
                    Text(Localization.string(.settingsNoAppsIgnored, language: lang))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.preferences.captureExclusions) { rule in
                    HStack(spacing: DesignTokens.Spacing.card) {
                        Toggle(
                            Localization.format(.settingsIgnoreAppToggle, language: lang, rule.name),
                            isOn: Binding(
                                get: { rule.isEnabled },
                                set: { model.setCaptureExclusionEnabled(rule, $0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(
                            rule.isEnabled
                                ? Localization.format(.settingsStopIgnoringAppHelp, language: lang, rule.name)
                                : Localization.format(.settingsIgnoreAppHelp, language: lang, rule.name)
                        )

                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxSmall) {
                            Text(rule.name)
                            Text(rule.bundleIdentifier)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            model.removeCaptureExclusion(rule)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.hover)
                        .help(Localization.format(.settingsRemoveAppHelp, language: lang, rule.name))
                    }
                }
            }

            Section {
                HStack {
                    Button {
                        model.addObservedAppToCaptureExclusions()
                    } label: {
                        Label(
                            Localization.string(.settingsAddLastAppButton, language: lang),
                            systemImage: "plus"
                        )
                    }
                    .disabled(addLastAppDisabled)
                    Spacer()
                }

                if let app = model.observedSourceApplication {
                    Text(
                        Localization.format(
                            .settingsLastAppObserved,
                            language: lang,
                            app.name,
                            app.bundleIdentifier
                        )
                    )
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                } else {
                    Text(Localization.string(.settingsLastAppNone, language: lang))
                        .font(DesignTokens.Typography.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(Localization.string(.settingsAddAppHeader, language: lang))
            }
        }
        .formStyle(.grouped)
    }

    private var addLastAppDisabled: Bool {
        guard let app = model.observedSourceApplication else { return true }
        return model.preferences.captureExclusions.contains {
            $0.id == app.bundleIdentifier.lowercased()
        }
    }
}

// MARK: - Tabs

private struct TabsPreferences: View {
    @ObservedObject var model: AppModel
    @Binding var renamingTab: ClipboardTab?
    @Binding var renameText: String

    var body: some View {
        let lang = model.preferences.language
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            Text(Localization.string(.settingsCaptureTabHeader, language: lang))
                .font(DesignTokens.Typography.headline)
            Picker(
                Localization.string(.settingsCaptureTabPickerLabel, language: lang),
                selection: captureTabBinding
            ) {
                ForEach(model.tabs) { tab in
                    Text(tab.name).tag(tab.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Divider()

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text(Localization.string(.settingsSyncFolderBehaviorDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    Localization.string(.settingsPauseSyncToggle, language: lang),
                    isOn: Binding(
                        get: { model.preferences.syncPaused },
                        set: { model.setSyncPaused($0) }
                    )
                )
                Text(Localization.string(.settingsPauseSyncDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(Localization.string(.settingsTabsListHeader, language: lang))
                .font(DesignTokens.Typography.headline)

            ScrollView {
                VStack(spacing: DesignTokens.Spacing.medium) {
                    ForEach(model.tabs) { tab in
                        TabSettingsRow(
                            model: model,
                            tab: tab,
                            onRename: {
                                renameText = tab.name
                                renamingTab = tab
                            }
                        )
                    }
                }
            }

            HStack {
                Button {
                    model.addTab(named: "Tab \(model.tabs.count + 1)")
                } label: {
                    Label(Localization.string(.settingsAddTabButton, language: lang), systemImage: "plus")
                }
                Spacer()
                Text(Localization.string(.settingsTabReorderDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var captureTabBinding: Binding<Int64> {
        Binding(
            get: { model.captureTab?.id ?? model.tabs.first?.id ?? 0 },
            set: { id in
                if let tab = model.tabs.first(where: { $0.id == id }) {
                    model.setCaptureTab(tab)
                }
            }
        )
    }
}

// Not private so the tests can host the real row and drive its text field;
// the debounced commit is only proven by exercising this view.
struct TabSettingsRow: View {
    /// How long the field waits after the last keystroke before committing, so
    /// a pasted path is stored without the user leaving the field or pressing
    /// Return, while typing does not write the store on every character.
    private static let commitDelay = Duration.milliseconds(400)

    @ObservedObject var model: AppModel
    let tab: ClipboardTab
    let onRename: () -> Void

    @State private var syncFolder: String = ""
    @State private var syncFolderDraft = SyncFolderDraft()
    @State private var pendingSyncFolderCommit: Task<Void, Never>?
    @FocusState private var syncFolderFocused: Bool

    var body: some View {
        let lang = model.preferences.language
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack {
                Text(tab.name).fontWeight(.medium)
                if tab.isDefault {
                    Text(Localization.string(.settingsTabCaptureBadge, language: lang))
                        .font(DesignTokens.Typography.caption2)
                        .padding(.horizontal, DesignTokens.Spacing.small)
                        .padding(.vertical, DesignTokens.Spacing.hairline)
                        .background(Capsule().fill(.tint.opacity(0.2)))
                }
                Spacer()
                Button(Localization.string(.settingsTabRenameButton, language: lang), action: onRename)
                    .buttonStyle(.hover)
                Button {
                    model.removeTab(tab)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.hover)
                .disabled(model.tabs.count <= 1)
                .help(Localization.string(.settingsTabRemoveHelp, language: lang))
            }

            HStack(spacing: DesignTokens.Spacing.medium) {
                Text(Localization.string(.settingsTabSyncFolderLabel, language: lang))
                    .foregroundStyle(.secondary)
                TextField(
                    Localization.string(.settingsTabSyncFolderPlaceholder, language: lang),
                    text: $syncFolder
                )
                .textFieldStyle(.roundedBorder)
                .focused($syncFolderFocused)
                // Return commits and drops focus; the change itself also
                // commits after the debounce below.
                .onSubmit { syncFolderFocused = false; commitPendingSyncFolder() }
            }

            Text(
                (tab.syncFolder ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Localization.string(.settingsTabSyncFolderLocalDetail, language: lang)
                    : Localization.string(.settingsTabSyncFolderSyncingDetail, language: lang)
            )
            .font(DesignTokens.Typography.callout)
            .foregroundStyle(.secondary)
        }
        .padding(DesignTokens.Spacing.card)
        .glassSurface(cornerRadius: DesignTokens.Radius.card)
        .onAppear(perform: syncFromTab)
        .onChange(of: syncFolder) { _, _ in scheduleSyncFolderCommit() }
        .onChange(of: tab) { _, _ in
            // The pending text belongs to the tab it was typed for, so it is
            // committed before the field shows the new tab's folder instead
            // of being silently dropped.
            commitPendingSyncFolder()
            syncFromTab()
        }
        .onChange(of: syncFolderFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                commitPendingSyncFolder()
                syncFromTab()
            }
        }
        .onDisappear(perform: commitPendingSyncFolder)
    }

    private func syncFromTab() {
        syncFolder = SyncFolderDraft.fieldText(
            storedFolder: tab.syncFolder,
            typed: syncFolder,
            isFocused: syncFolderFocused,
            hasPendingCommit: syncFolderDraft.hasPendingCommit
        )
    }

    /// Arms the debounce after a change, replacing any earlier pending commit
    /// so the last typed value wins. A change that needs no write (the trimmed
    /// text already matches the tab's folder) leaves nothing pending.
    private func scheduleSyncFolderCommit() {
        pendingSyncFolderCommit?.cancel()
        pendingSyncFolderCommit = nil

        guard syncFolderDraft.record(
            tabID: tab.id,
            storedFolder: tab.syncFolder,
            text: syncFolder
        ) else { return }

        pendingSyncFolderCommit = Task { @MainActor in
            try? await Task.sleep(for: Self.commitDelay)
            guard !Task.isCancelled else { return }
            commitPendingSyncFolder()
        }
    }

    /// Commits the pending draft, if any, to the tab it was typed for.
    private func commitPendingSyncFolder() {
        pendingSyncFolderCommit?.cancel()
        pendingSyncFolderCommit = nil

        guard let commit = syncFolderDraft.takeCommit() else { return }
        guard var updated = model.tab(id: commit.tabID) else { return }
        updated.syncFolder = commit.folder
        model.updateTab(updated)
    }
}

// MARK: - Shortcut

private struct ShortcutPreferences: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let lang = model.preferences.language
        Form {
            Section {
                Text(
                    Localization.format(
                        .settingsPlainTextShortcutHeader,
                        language: lang,
                        Localization.hotKeyLabel(
                            model.preferences.plainTextHotKeyDisplayLabel,
                            language: lang
                        )
                    )
                )
                .font(DesignTokens.Typography.headline)
                HStack {
                    Text(Localization.string(.settingsRecordLabel, language: lang))
                    HotKeyRecorderView(
                        shortcut: HotKeyShortcut.plainText(from: model.preferences),
                        language: lang,
                        onChange: applyPlainText
                    )
                    .frame(width: 200, height: 26)
                }
                Text(Localization.string(.settingsPlainTextShortcutDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
                if let problem = model.plainTextHotKeyProblem {
                    Text(problem.message(language: lang))
                        .font(DesignTokens.Typography.callout)
                        .foregroundStyle(DesignTokens.Colors.destructive)
                }
            }

            Section {
                Text(
                    Localization.format(
                        .settingsSummonShortcutHeader,
                        language: lang,
                        Localization.hotKeyLabel(
                            model.preferences.hotKeyDisplayLabel,
                            language: lang
                        )
                    )
                )
                .font(DesignTokens.Typography.headline)
                Picker(
                    Localization.string(.settingsPresetLabel, language: lang),
                    selection: presetBinding
                ) {
                    ForEach(HotKeyShortcut.presets, id: \.label) { preset in
                        Text(Localization.hotKeyLabel(preset.label, language: lang)).tag(preset.label)
                    }
                    Text(Localization.string(.settingsPresetCustom, language: lang)).tag("custom")
                }
            }

            Section {
                HStack {
                    Text(Localization.string(.settingsRecordLabel, language: lang))
                    HotKeyRecorderView(
                        shortcut: HotKeyShortcut(preferences: model.preferences),
                        language: lang,
                        onChange: apply
                    )
                    .frame(width: 200, height: 26)
                }
                Text(Localization.string(.settingsShortcutRecordDetail, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: {
                let current = HotKeyShortcut(preferences: model.preferences)
                return HotKeyShortcut.presets.first { $0.keyCode == current.keyCode && $0.modifiers == current.modifiers }?.label
                    ?? "custom"
            },
            set: { label in
                guard let preset = HotKeyShortcut.presets.first(where: { $0.label == label }) else { return }
                apply(preset)
            }
        )
    }

    private func apply(_ shortcut: HotKeyShortcut) {
        model.updatePreferences { shortcut.apply(to: &$0) }
    }

    private func applyPlainText(_ shortcut: HotKeyShortcut) {
        model.updatePreferences { shortcut.applyPlainText(to: &$0) }
    }
}
