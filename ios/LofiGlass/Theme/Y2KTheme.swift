import SwiftUI

// MARK: - Y2K design language
//
// The palette is deliberately "2001 desktop": chrome gradients, hot magenta,
// cyan, a lime accent, and a deep violet void behind everything. Mirrored by
// prototype/src/styles.css so the two never drift apart.

enum Y2K {
  // MARK: Palette
  static let void = Color(red: 0.043, green: 0.027, blue: 0.125)
  static let void2 = Color(red: 0.090, green: 0.047, blue: 0.220)
  static let plum = Color(red: 0.169, green: 0.043, blue: 0.290)
  static let pink = Color(red: 1.000, green: 0.216, blue: 0.827)
  static let magenta = Color(red: 0.839, green: 0.000, blue: 0.612)
  static let cyan = Color(red: 0.275, green: 0.973, blue: 1.000)
  static let lime = Color(red: 0.718, green: 1.000, blue: 0.180)
  static let butter = Color(red: 1.000, green: 0.914, blue: 0.659)
  static let chromeHi = Color.white
  static let chromeMid = Color(red: 0.725, green: 0.769, blue: 0.961)
  static let chromeLo = Color(red: 0.290, green: 0.325, blue: 0.588)
  static let ink = Color(red: 0.918, green: 0.937, blue: 1.000)
  static let inkDim = Color(red: 0.600, green: 0.631, blue: 0.839)

  // MARK: Gradients
  static var chrome: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: .white, location: 0.00),
        .init(color: chromeMid, location: 0.38),
        .init(color: chromeLo, location: 0.52),
        .init(color: Color(red: 0.914, green: 0.949, blue: 1.0), location: 0.62),
        .init(color: chromeMid, location: 0.80),
        .init(color: Color(red: 0.435, green: 0.475, blue: 0.769), location: 1.00),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  static var voidBackdrop: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: plum, location: 0.0),
        .init(color: void2, location: 0.45),
        .init(color: void, location: 1.0),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  static var stampPink: LinearGradient {
    LinearGradient(colors: [pink, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  static var stampCyan: LinearGradient {
    LinearGradient(colors: [cyan, Color(red: 0.0, green: 0.45, blue: 0.60)], startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  static var spectrum: LinearGradient {
    LinearGradient(colors: [cyan, pink, butter], startPoint: .bottom, endPoint: .top)
  }

  // MARK: Type
  /// Chrome display face. Falls back to the system rounded face when the
  /// bundled Y2K fonts are missing (see Resources/Fonts note in README).
  static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    // `relativeTo:` is what makes the fallback behave: if Michroma is not in the
    // bundle, SwiftUI substitutes the anchored text style and Dynamic Type still
    // scales the wordmark instead of freezing it at a hard-coded point size.
    .custom("Michroma", size: size, relativeTo: .title3).weight(weight)
  }

  /// The pixel/terminal face used for numbers, tags and meters.
  static func pixel(_ size: CGFloat) -> Font {
    .custom("VT323", size: size, relativeTo: .body)
  }

  static func body(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .rounded)
  }

  // MARK: Metrics
  static let cornerXL: CGFloat = 34
  static let cornerL: CGFloat = 26
  static let cornerM: CGFloat = 18
  static let stroke: CGFloat = 1.2
}

// MARK: - Reusable type styles

extension View {
  /// Silver bevel text: the single most Y2K thing you can do to a wordmark.
  func chromeText(_ size: CGFloat = 30) -> some View {
    self
      .font(Y2K.display(size))
      .foregroundStyle(Y2K.chrome)
      .shadow(color: Y2K.pink.opacity(0.55), radius: 0, y: 1.5)
      .shadow(color: Y2K.cyan.opacity(0.45), radius: 6, y: -1)
  }

  func neon(_ color: Color = Y2K.cyan, radius: CGFloat = 9) -> some View {
    self.shadow(color: color.opacity(0.85), radius: radius)
  }
}
