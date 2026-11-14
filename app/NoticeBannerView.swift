// The window's transient message, built in AppKit so its pointer behaviour is
// real rather than a SwiftUI hit-testing side effect:
// `NoticeBannerView.hitTest(_:)` returns nothing for the whole plate and only
// the banner's own buttons for their own rects, so a click on the message
// reaches the list row underneath instead of being swallowed by a banner that
// is only on screen for a few seconds.
//
// SwiftUI still draws the plate, because the app's Liquid Glass surface is a
// SwiftUI view modifier; the wrapping height for a given width comes from the
// hosting controller's proposal-based sizing, so the plate is laid out by the
// same rules the rest of the window uses.

import AppKit
import SwiftUI

/// One banner message, as the views need it.
struct NoticeBannerContent: Equatable {
    /// The clauses the model recorded, so each is translated on its own
    /// instead of the joined record being looked up as one string.
    let parts: [String]
    let language: AppLanguage
    /// Whether this is the Accessibility notice, which offers the grant flow as
    /// well as the close control.
    let isPermissionNotice: Bool

    var displayText: String {
        Localization.runtimeMessage(parts, language: language)
    }

    var actionTitle: String? {
        isPermissionNotice ? Localization.string(.bannerOpenSystemSettings, language: language) : nil
    }

    init(parts: [String], language: AppLanguage = .english) {
        self.parts = parts
        self.language = language
        self.isPermissionNotice = AccessibilityNoticePolicy.isPermissionNotice(parts.first)
    }

    /// A notice that is a single message.
    init(text: String, language: AppLanguage = .english) {
        self.init(parts: [text], language: language)
    }
}

// MARK: - Plate

/// The banner's plate: icon, message, glass.
///
/// It is drawn only; `NoticeBannerView` owns every pointer decision, so the
/// plate must never take input of its own.
private struct NoticePlate: View {
    let message: String
    /// Trailing room reserved for the banner's buttons, so the wrapped message
    /// never runs underneath them.
    let controlInset: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.medium) {
            Image(systemName: "lock.shield").foregroundStyle(DesignTokens.Colors.notice)
            Text(message)
                .font(DesignTokens.Typography.callout)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.card)
        .padding(.trailing, controlInset)
        .glassSurface(cornerRadius: DesignTokens.Radius.topLevel, tint: DesignTokens.Colors.notice)
    }
}

// MARK: - Banner view

/// The banner the main window shows over the top of the item list.
///
/// The view is transparent to the pointer except for its buttons. That is the
/// one property the whole design rests on, so it lives in AppKit where it can
/// be checked directly with `hitTest(_:)` instead of being a SwiftUI modifier
/// whose effect no test can observe.
@MainActor
final class NoticeBannerView: NSView {
    /// The plate for the message currently shown. It is replaced with the
    /// message, so measuring it for a width and drawing it always describe the
    /// same text.
    private var plate: NSHostingController<NoticePlate>?
    private let actionButton = NSButton()
    private let closeButton = NSButton()
    private var content: NoticeBannerContent?

    /// Layout constants, matching the plate's own padding.
    private static let padding: CGFloat = DesignTokens.Spacing.card
    private static let controlHeight: CGFloat = 18
    private static let controlSpacing: CGFloat = DesignTokens.Spacing.medium

    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// The banner draws from the top down, like the list it covers.
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Dismiss"
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Dismiss"
        closeButton.target = self
        closeButton.action = #selector(dismissPressed)
        closeButton.setAccessibilityLabel("Dismiss")
        addSubview(closeButton)

        actionButton.isBordered = false
        actionButton.bezelStyle = .inline
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        addSubview(actionButton)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Message")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The banner's own buttons: the only rects `hitTest(_:)` claims, so every
    /// other click goes through to the list underneath.
    private var controls: [NSView] { [actionButton, closeButton] }

    /// Shows `content`, or hides the banner when it is nil.
    ///
    /// The callbacks are replaced on every update because they capture the
    /// model that asked for them.
    func configure(
        _ content: NoticeBannerContent?,
        onAction: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onAction = onAction
        self.onDismiss = onDismiss
        guard let content else {
            self.content = nil
            isHidden = true
            return
        }
        if self.content != content {
            self.content = content
            let dismissTitle = Localization.string(.bannerDismiss, language: content.language)
            closeButton.toolTip = dismissTitle
            closeButton.setAccessibilityLabel(dismissTitle)
            closeButton.image?.accessibilityDescription = dismissTitle
            setAccessibilityLabel(Localization.string(.bannerMessage, language: content.language))
            configureActionButton(title: content.actionTitle)
            installPlate(for: content)
            setAccessibilityValue(content.displayText)
        }
        isHidden = false
        needsLayout = true
    }

    private var controlInset: CGFloat {
        var inset = Self.padding + Self.controlHeight + Self.padding
        if content?.actionTitle != nil {
            inset += actionButton.fittingSize.width + Self.controlSpacing
        }
        return inset
    }

    private func configureActionButton(title: String?) {
        guard let title else {
            actionButton.isHidden = true
            actionButton.title = ""
            return
        }
        actionButton.isHidden = false
        actionButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.preferredFont(forTextStyle: .callout),
                .foregroundColor: NSColor.controlAccentColor,
            ]
        )
        actionButton.sizeToFit()
    }

    /// Puts a freshly measured plate behind the buttons for `content`.
    private func installPlate(for content: NoticeBannerContent) {
        plate?.view.removeFromSuperview()
        let controller = NSHostingController(
            rootView: NoticePlate(message: content.displayText, controlInset: controlInset)
        )
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.autoresizingMask = []
        addSubview(controller.view, positioned: .below, relativeTo: closeButton)
        plate = controller
    }

    /// How tall the banner is when it is laid out `width` points wide.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        guard let plate else { return 0 }
        let proposal = NSSize(width: width, height: .greatestFiniteMagnitude)
        return ceil(plate.sizeThatFits(in: proposal).height)
    }

    /// Lays the plate and the buttons out inside `width` points.
    func layout(in width: CGFloat) {
        guard !isHidden, width > 0, let plate else { return }
        let height = height(forWidth: width)
        plate.view.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let top = Self.padding
        let closeX = width - Self.padding - Self.controlHeight
        closeButton.frame = NSRect(
            x: closeX,
            y: top,
            width: Self.controlHeight,
            height: Self.controlHeight
        )
        if actionButton.isHidden {
            actionButton.frame = .zero
        } else {
            let size = actionButton.fittingSize
            actionButton.frame = NSRect(
                x: closeX - Self.controlSpacing - size.width,
                y: top + (Self.controlHeight - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    override func layout() {
        super.layout()
        layout(in: bounds.width)
    }

    /// The banner is click-through: everything it draws except its own buttons
    /// belongs to whatever is underneath. `hitTest(_:)` therefore never asks the
    /// plate for a target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        for control in controls where !control.isHidden && control.frame.contains(local) {
            return control
        }
        return nil
    }

    @objc private func dismissPressed() {
        onDismiss?()
    }

    @objc private func actionPressed() {
        onAction?()
    }
}

// MARK: - SwiftUI host

/// Hosts the AppKit banner in a SwiftUI layout, for the places that are not the
/// item list itself (the empty list has no scroll view to overlay).
struct NoticeBannerHost: NSViewRepresentable {
    let content: NoticeBannerContent?
    let onAction: () -> Void
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> NoticeBannerView {
        let view = NoticeBannerView()
        view.configure(content, onAction: onAction, onDismiss: onDismiss)
        return view
    }

    func updateNSView(_ view: NoticeBannerView, context: Context) {
        view.configure(content, onAction: onAction, onDismiss: onDismiss)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NoticeBannerView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}
