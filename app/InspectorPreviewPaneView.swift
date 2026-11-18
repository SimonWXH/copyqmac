import AppKit
import SwiftUI

// MARK: - Inspector Preview Pane

struct InspectorPreviewPane: View {
    @ObservedObject var model: AppModel
    let selectedEntry: ClipboardEntry?

    var body: some View {
        let lang = model.preferences.language
        VStack(alignment: .leading, spacing: 0) {
            if let entry = selectedEntry {
                let presentation = model.presentation(for: entry)
                switch presentation?.kind {
                case .image:
                    if let previewImage = model.selectedPreviewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.media, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                    } else if let thumbnail = model.thumbnail(for: entry, maxSize: 240) {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.media, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                    } else {
                        Text(Localization.string(.previewImageUnavailable, language: lang))
                            .font(DesignTokens.Typography.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                                    Text(url.lastPathComponent)
                                        .font(DesignTokens.Typography.callout)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(DesignTokens.Spacing.small)
                    }
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if let richText = model.richText(for: entry) {
                                Text(richText.preview)
                                    .font(DesignTokens.Typography.callout)
                                    .textSelection(.enabled)
                            } else {
                                Text(presentation?.searchText ?? presentation?.primaryText ?? "")
                                    .font(DesignTokens.Typography.callout)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(DesignTokens.Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else {
                Text(Localization.string(.previewSelectPrompt, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}
