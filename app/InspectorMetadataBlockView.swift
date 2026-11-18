import AppKit
import SwiftUI

// MARK: - Inspector Metadata Block

struct InspectorMetadataBlock: View {
    let entry: ClipboardEntry?
    @ObservedObject var model: AppModel
    let language: AppLanguage

    var body: some View {
        if let entry = entry {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                let presentation = model.presentation(for: entry)
                let totalBytes = entry.flavours.reduce(0) { $0 + Int64($1.uncompressedByteCount) }
                let detailCount = metadataDetailCount(presentation: presentation, language: language)

                HStack(spacing: DesignTokens.Spacing.small) {
                    if let kind = presentation?.kind {
                        Text(Localization.contentKindLabel(kind, language: language))
                            .font(DesignTokens.Typography.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(DesignTokens.Colors.selection)
                            .padding(.horizontal, DesignTokens.Spacing.compact)
                            .padding(.vertical, DesignTokens.Spacing.xxSmall)
                            .background(
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.tag, style: .continuous)
                                    .fill(DesignTokens.Colors.selection.opacity(0.12))
                            )
                    }

                    Spacer(minLength: 0)

                    if entry.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.Colors.notice)
                    }
                }

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                    HStack(spacing: DesignTokens.Spacing.small) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(Localization.byteCount(totalBytes, language: language))
                            .font(DesignTokens.Typography.caption2)
                            .foregroundStyle(.secondary)

                        if let detailCount {
                            Text("•").foregroundStyle(.tertiary)
                            Image(systemName: detailCount.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(detailCount.label)
                                .font(DesignTokens.Typography.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let presentation {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(presentation.relativeTime)
                                .font(DesignTokens.Typography.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(DesignTokens.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadataDetailCount(
        presentation: EntryPresentation?,
        language: AppLanguage
    ) -> (icon: String, label: String)? {
        if let lineCount = presentation?.lineCount {
            return ("text.alignleft", Localization.lineCount(lineCount, language: language))
        }
        if presentation?.kind == .files, let fileCount = presentation?.fileCount, fileCount > 0 {
            return ("doc.on.doc", Localization.fileCount(fileCount, language: language))
        }
        return nil
    }
}
