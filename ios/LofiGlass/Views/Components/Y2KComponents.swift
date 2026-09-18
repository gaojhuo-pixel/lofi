import SwiftUI

// MARK: - Y2K furniture
// Starbursts, scanlines, chrome marquees, spinning CD grooves. Small, dumb
// views — all state lives in AppState / players.

/// ✦ four-point sparkle, drawn (not fonted) so it tints and glows.
struct Starburst: View {
  var size: CGFloat = 22
  var color: Color = .white
  var rotation: Double = 0

  var body: some View {
    Path { p in
      let r = size / 2
      let inner = r * 0.20
      let center = CGPoint(x: r, y: r)
      func point(_ k: Int, _ radius: CGFloat) -> CGPoint {
        let a = Double(k) * .pi / 4 + rotation * .pi / 180
        return CGPoint(x: center.x + CGFloat(cos(a)) * radius, y: center.y + CGFloat(sin(a)) * radius)
      }
      p.move(to: point(0, r))
      for k in 1..<8 { p.addLine(to: point(k, k.isMultiple(of: 2) ? r : inner)) }
      p.closeSubpath()
    }
    .fill(color)
    .frame(width: size, height: size)
  }
}

/// CRT lines + vignette. Sits above content, ignores hits.
struct ScanlineOverlay: View {
  var opacity: Double = 0.28
  var spacing: CGFloat = 3

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Path { p in
          var y: CGFloat = 0
          while y < proxy.size.height {
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: proxy.size.width, y: y))
            y += spacing
          }
        }
        .stroke(Color.white.opacity(0.06 * (opacity / 0.28)), lineWidth: 1)

        RadialGradient(
          colors: [.clear, .black.opacity(0.34 * (opacity / 0.28))],
          center: .center,
          startRadius: min(proxy.size.width, proxy.size.height) * 0.34,
          endRadius: max(proxy.size.width, proxy.size.height) * 0.80
        )
      }
    }
    .allowsHitTesting(false)
    .blendMode(.softLight)
  }
}

/// Vaporwave floor: a perspective grid that never stops moving.
struct GridHorizon: View {
  var lines: Int = 14

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
      // Reduce Motion freezes the floor but keeps the grid: the pattern is part
      // of the identity, the drift is not.
      let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
      Canvas { ctx, size in
        let horizon = size.height * 0.32
        var vertical = Path()
        for i in 0...lines {
          let x = CGFloat(i) / CGFloat(lines) * size.width
          vertical.move(to: CGPoint(x: x, y: horizon))
          vertical.addLine(to: CGPoint(x: (x - size.width / 2) * 2.6 + size.width / 2, y: size.height))
        }
        ctx.stroke(vertical, with: .color(Y2K.pink.opacity(0.22)), lineWidth: 1)

        var horizontal = Path()
        for i in 0..<lines {
          let phase = CGFloat(Double(i) / Double(lines) + t.truncatingRemainder(dividingBy: 1) * 0.11)
          let y = horizon + pow(phase, 2.1) * (size.height - horizon)
          horizontal.move(to: CGPoint(x: 0, y: y))
          horizontal.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(horizontal, with: .color(Y2K.cyan.opacity(0.16)), lineWidth: 1)
      }
    }
    .allowsHitTesting(false)
  }
}

/// One-line chrome marquee for the now-playing strip. Scrolls only when the
/// string is wider than the container, measured with a background GeometryReader.
struct ChromeMarquee: View {
  var text: String
  var font: Font = Y2K.pixel(17)
  var secondsPerLoop: Double = 16

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var contentWidth: CGFloat = 0
  @State private var offset: CGFloat = 0

  var body: some View {
    GeometryReader { proxy in
      let scrolls = contentWidth > proxy.size.width + 4
      HStack(spacing: 34) {
        Text(text).foregroundStyle(Y2K.butter)
        Text(text).foregroundStyle(Y2K.cyan.opacity(0.75))
      }
      .font(font)
      .fixedSize()
      .offset(x: offset)
      .background {
        GeometryReader { inner in
          Color.clear
            .onAppear { contentWidth = inner.size.width }
            .onChange(of: inner.size.width) { _, w in
              contentWidth = w
              restart(scrolls: w > proxy.size.width + 4, visible: proxy.size.width)
            }
        }
      }
      .onAppear { restart(scrolls: scrolls, visible: proxy.size.width) }
      .clipped()
    }
    .frame(height: 22)
    .background(Color.black.opacity(0.26))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private func restart(scrolls: Bool, visible: CGFloat) {
    guard scrolls, !reduceMotion else {
      offset = 0
      return
    }
    let total = max(contentWidth - 34, visible) + 34
    offset = 0
    withAnimation(.linear(duration: secondsPerLoop).repeatForever(autoreverses: false)) {
      offset = -total / 2 - 17
    }
  }
}

/// The little Y2K status pill: "LIVE", "MIX", "TRACK".
struct PixelBadge: View {
  var text: String
  var tint: Color = Y2K.pink
  var glyph: String? = nil

  var body: some View {
    HStack(spacing: 4) {
      if let glyph { Text(glyph).font(Y2K.pixel(13)) }
      Text(text)
        .font(Y2K.pixel(14))
        .tracking(1.4)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(tint.gradient)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
    )
    .foregroundStyle(.black.opacity(0.85))
    .neon(tint, radius: 7)
  }
}

/// #hashtag pill — tags come from the description, never invented by us.
struct TagPill: View {
  var tag: String
  var body: some View {
    Text("#\(tag)")
      .font(Y2K.pixel(15))
      .foregroundStyle(Y2K.ink)
      .padding(.horizontal, 9)
      .padding(.vertical, 3)
      .lofiGlass(corner: 999, tint: .clear)
  }
}

/// Level meter for the boost sheet. `level` is 0…1, `reductionDb` is how hard
/// the limiter is pulling, `clipping` lights the CLIP lamp.
struct BoostMeter: View {
  var level: Double
  var reductionDb: Double
  var clipping: Bool

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.10))
        Capsule()
          .fill(Y2K.spectrum)
          .frame(width: max(2, proxy.size.width * CGFloat(min(1, max(0, level)))))
        Rectangle()
          .fill(.white.opacity(0.5))
          .frame(width: 1, height: proxy.size.height)
          .position(x: proxy.size.width * 0.66, y: proxy.size.height / 2)
        if abs(reductionDb) > 0.15 {
          Rectangle()
            .fill(Y2K.lime.opacity(0.5))
            .frame(width: max(1, proxy.size.width * min(1, abs(reductionDb) / 12)), height: 3)
            .offset(y: -proxy.size.height / 2 + 1.5)
        }
      }
      .overlay(alignment: .trailing) {
        if clipping {
          Text("CLIP")
            .font(Y2K.pixel(13))
            .foregroundStyle(Y2K.pink)
            .neon(Y2K.pink, radius: 8)
            .padding(.trailing, 4)
        }
      }
    }
    .frame(height: 12)
  }
}

/// Vinyl grooves + rainbow sheen + tonearm. Spin is derived from the clock, so
/// there is no animation state machine to get out of sync when you pause.
struct VinylSurface: View {
  var spinning: Bool
  var cover: UIImage?
  /// seconds per revolution — long mixes feel heavier, short ones skitters
  var period: Double = 4.2

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var baseAngle: Double = 0
  @State private var spinStart: Date?

  var body: some View {
    GeometryReader { proxy in
      let d = min(proxy.size.width, proxy.size.height)
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
        ZStack {
          disc(d: d)
        }
        .frame(width: d, height: d)
        .rotationEffect(.degrees(angle(at: context.date)))
      }
      .frame(width: d, height: d)
      .shadow(color: .black.opacity(0.75), radius: 26, y: 16)
      .overlay {
        tonearm(width: d)
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .onChange(of: spinning) { _, now in
      if now {
        spinStart = Date()
      } else if let start = spinStart {
        baseAngle = (baseAngle + angleSince(start)).truncatingRemainder(dividingBy: 360)
        spinStart = nil
      }
    }
  }

  private func angleSince(_ start: Date) -> Double {
    Date().timeIntervalSince(start) / period * 360
  }

  private func angle(at date: Date) -> Double {
    guard spinning, !reduceMotion, let start = spinStart else { return baseAngle }
    return baseAngle + date.timeIntervalSince(start) / period * 360
  }

  @ViewBuilder private func disc(d: CGFloat) -> some View {
    ZStack {
      Circle()
        .fill(
          RadialGradient(
            stops: [
              .init(color: Color(white: 0.14), location: 0.0),
              .init(color: Color(white: 0.05), location: 0.26),
              .init(color: Color(white: 0.10), location: 0.55),
              .init(color: Color(white: 0.03), location: 1.0),
            ],
            center: .center,
            startRadius: 0,
            endRadius: d / 2
          )
        )

      ForEach(0..<26, id: \.self) { i in
        Circle()
          .stroke(Color.white.opacity(i.isMultiple(of: 2) ? 0.045 : 0.018), lineWidth: 0.7)
          .frame(width: d * (0.34 + CGFloat(i) * 0.025), height: d * (0.34 + CGFloat(i) * 0.025))
      }

      Circle()
        .fill(
          AngularGradient(
            colors: [
              Y2K.pink.opacity(0.28), Y2K.cyan.opacity(0.24), Y2K.lime.opacity(0.20),
              Y2K.butter.opacity(0.24), Y2K.pink.opacity(0.28),
            ],
            center: .center
          )
        )
        .mask { Circle().inset(by: d * 0.05) }
        .opacity(0.5)

      if let cover {
        Image(uiImage: cover)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: d * 0.46, height: d * 0.46)
          .clipShape(Circle())
          .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1.6))
      } else {
        Circle()
          .fill(Y2K.plum)
          .frame(width: d * 0.46, height: d * 0.46)
          .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1.6))
      }

      Circle()
        .fill(.black)
        .frame(width: d * 0.055, height: d * 0.055)
        .overlay(Circle().strokeBorder(.white.opacity(0.30), lineWidth: 1))
    }
  }

  @ViewBuilder private func tonearm(width d: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 3)
      .fill(LinearGradient(colors: [.white, Y2K.chromeLo], startPoint: .leading, endPoint: .trailing))
      .frame(width: d * 0.34, height: 4)
      .rotationEffect(.degrees(spinning ? 6 : -26), anchor: .trailing)
      .offset(x: d * 0.16, y: -d * 0.30)
      .animation(.spring(duration: 0.7, bounce: 0.25), value: spinning)
  }
}
