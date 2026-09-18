import SwiftUI

// MARK: - Liquid Glass
//
// On iOS 26 we use the real thing (`glassEffect`). Below that we approximate it
// with the same ingredients Apple's material exposes: a translucent fill, a
// saturating blur, a 1pt specular edge and a pointer-driven highlight, so the
// screens still read as glass on iOS 18/19.

public enum GlassTint {
  case clear, pink, cyan, lime, chrome

  var fill: Color {
    switch self {
    case .clear: return .white.opacity(0.10)
    case .pink: return Y2K.pink.opacity(0.16)
    case .cyan: return Y2K.cyan.opacity(0.14)
    case .lime: return Y2K.lime.opacity(0.14)
    case .chrome: return Y2K.chromeMid.opacity(0.16)
    }
  }

  var interactiveMaterial: AnyShapeStyle {
    switch self {
    case .clear: return AnyShapeStyle(.regularMaterial)
    case .pink, .cyan, .lime, .chrome: return AnyShapeStyle(.thinMaterial)
    }
  }
}

struct GlassPanel: ViewModifier {
  var corner: CGFloat = Y2K.cornerL
  var tint: GlassTint = .clear
  var interactive: Bool = false
  @State private var hotspot: CGPoint? = nil

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
    content
      .background {
        ZStack {
          if #available(iOS 26.0, *) {
            // Real liquid glass. `in:` gives it the refractive rim for free.
            shape
              .fill(tint.fill)
              .glassEffect(
                interactive
                  ? .regular.interactive().tint(tintColor)
                  : .regular.tint(tintColor),
                in: shape
              )
          } else {
            shape
              .fill(tint.interactiveMaterial)
              .overlay(shape.fill(tint.fill))
              .overlay { specular }
              // Fallback specular edge: bright top-left, cool bottom-right.
              .overlay(
                shape
                  .strokeBorder(
                    LinearGradient(
                      colors: [.white.opacity(0.55), .white.opacity(0.06), Y2K.cyan.opacity(0.30)],
                      startPoint: .topLeading,
                      endPoint: .bottomTrailing
                    ),
                    lineWidth: Y2K.stroke
                  )
              )
          }
        }
      }
      .clipShape(shape)
      .shadow(color: .black.opacity(0.45), radius: 22, y: 14)
      .contentShape(shape)
      .onContinuousHover { phase in
        switch phase {
        case .active(let p): hotspot = p
        case .ended: hotspot = nil
        }
      }
  }

  @ViewBuilder private var specular: some View {
    if let hotspot {
      shapelessHighlight(at: hotspot)
    } else {
      shapelessHighlight(at: CGPoint(x: 0.5, y: 0.0))
    }
  }

  /// A soft screen-blend glow that follows the cursor (iPad trackpad / Mac
  /// Catalyst). Zero-cost on iPhone because there is no hover.
  private func shapelessHighlight(at point: CGPoint) -> some View {
    GeometryReader { proxy in
      let p = point.x <= 1 && point.y <= 1
        ? CGPoint(x: proxy.size.width * point.x, y: proxy.size.height * point.y)
        : point
      Circle()
        .fill(.white.opacity(0.18))
        .frame(width: 180, height: 180)
        .blur(style: .fine)
        .blendMode(.screen)
        .position(x: p.x, y: p.y)
    }
    .allowsHitTesting(false)
  }

  private var tintColor: Color {
    switch tint {
    case .clear: return .white.opacity(0.12)
    case .pink: return Y2K.pink.opacity(0.5)
    case .cyan: return Y2K.cyan.opacity(0.45)
    case .lime: return Y2K.lime.opacity(0.4)
    case .chrome: return Y2K.chromeMid.opacity(0.45)
    }
  }
}

extension View {
  /// The one glass modifier every surface in the app uses.
  @ViewBuilder func lofiGlass(
    corner: CGFloat = Y2K.cornerL,
    tint: GlassTint = .clear,
    interactive: Bool = false
  ) -> some View {
    if #available(iOS 26.0, *) {
      let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
      self
        .background {
          shape.fill(tint.fill).glassEffect(
            interactive ? .regular.interactive().tint(.white.opacity(0.10)) : .regular.tint(.white.opacity(0.08)),
            in: shape
          )
        }
        .clipShape(shape)
    } else {
      self.modifier(GlassPanel(corner: corner, tint: tint, interactive: interactive))
    }
  }

  /// iOS 26 glass button; older systems get a capsule material button.
  @ViewBuilder func lofiGlassButton() -> some View {
    if #available(iOS 26.0, *) {
      self.buttonStyle(.glass)
    } else {
      self.buttonStyle(.borderedProminent).tint(Y2K.pink.opacity(0.85))
    }
  }
}

// MARK: - Preset button styles

struct GlassChipButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Y2K.pixel(16))
      .foregroundStyle(Y2K.ink)
      .padding(.vertical, 7)
      .padding(.horizontal, 12)
      .lofiGlass(corner: 999, tint: .clear, interactive: true)
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .brightness(configuration.isPressed ? 0.12 : 0)
      .animation(.spring(duration: 0.25, bounce: 0.5), value: configuration.isPressed)
  }
}

struct GlassTabButtonStyle: ButtonStyle {
  var selected: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Y2K.pixel(15))
      .foregroundStyle(selected ? Y2K.cyan : Y2K.inkDim)
      .padding(.vertical, 6)
      .padding(.horizontal, 10)
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.16))
            .overlay(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.5), lineWidth: 1)
            )
            .lofiGlass(tint: .cyan, interactive: true)
        }
      }
      .scaleEffect(configuration.isPressed ? 0.93 : 1)
  }
}
