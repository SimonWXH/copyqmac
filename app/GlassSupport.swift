// Liquid Glass helpers.
//
// The app targets macOS 26.0, where `.glassEffect` is available.

import SwiftUI

/// Applies a Liquid Glass surface with the given corner radius.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 16
    var tint: Color?
    var interactive: Bool = false

    func body(content: Content) -> some View {
        content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
    }

    private var glass: Glass {
        var glass = tint.map { Glass.regular.tint($0) } ?? Glass.regular
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 16, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
}

/// Small icon button that uses the unified hover button style.
struct GlassActionButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.hover)
        .help(help)
    }
}
