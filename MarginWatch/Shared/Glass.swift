import SwiftUI

// Liquid Glass styling shared by the watch and iPhone apps. On iOS 26 / watchOS 26
// and later these use the system glass material; on earlier systems (and with
// SDKs that predate it, such as CI's Xcode) they fall back to a translucent material.

extension View {
    /// A glass surface in a continuous rounded rectangle, optionally tinted.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 18, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26.0, watchOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint?.opacity(0.22)).interactive(interactive), in: shape)
        } else {
            self.background((tint ?? .white).opacity(0.10), in: shape).background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background((tint ?? .white).opacity(0.10), in: shape).background(.ultraThinMaterial, in: shape)
        #endif
    }

    /// A glass capsule, for banners and chips.
    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, watchOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint?.opacity(0.25)), in: Capsule())
        } else {
            self.background((tint ?? .white).opacity(0.12), in: Capsule()).background(.ultraThinMaterial, in: Capsule())
        }
        #else
        self.background((tint ?? .white).opacity(0.12), in: Capsule()).background(.ultraThinMaterial, in: Capsule())
        #endif
    }

    /// Glass button style; `prominent` for the primary action on a screen.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, watchOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }
}

/// Groups glass shapes so nearby ones blend and morph together (GlassEffectContainer on iOS / watchOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, watchOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// A soft, slowly tinted backdrop so glass has colour to refract. `tint` follows today's recovery band.
struct MarginBackdrop: View {
    var tint: Color

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.45), Color.indigo.opacity(0.25), Color.black.opacity(0.0)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [tint.opacity(0.35), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}
