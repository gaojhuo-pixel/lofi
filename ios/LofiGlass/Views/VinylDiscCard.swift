import SwiftUI

// MARK: - The disc
//
// One song = one record: grooves, label = the video's own artwork, tonearm that
// drops when the deck is running. Tap flips it to the sleeve notes.

struct VinylDiscCard: View {
  let track: LofiTrack
  let credit: String
  var spinning: Bool
  var compact: Bool
  @Binding var flipped: Bool

  @EnvironmentObject private var app: AppState
  @State private var cover: UIImage?

  init(
    track: LofiTrack,
    credit: String,
    spinning: Bool,
    compact: Bool,
    flipped: Binding<Bool> = .constant(false)
  ) {
    self.track = track
    self.credit = credit
    self.spinning = spinning
    self.compact = compact
    self._flipped = flipped
  }

  var body: some View {
    ZStack {
      if flipped {
        sleeve
          .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
      } else {
        front
          .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.94).combined(with: .opacity)))
      }
    }
    .padding(compact ? 6 : 12)
    .lofiGlass(corner: Y2K.cornerXL, tint: .clear, interactive: !compact)
    .rotation3DEffect(
      .degrees(flipped ? 180 : 0),
      axis: (x: 0, y: 1, z: 0),
      anchor: .center,
      perspective: 0.4
    )
    .animation(.spring(duration: 0.55, bounce: 0.22), value: flipped)
    .task(id: track.videoId) { cover = await Self.cover(for: track.videoId) }
  }

  // MARK: Front

  private var front: some View {
    VStack(spacing: compact ? 4 : 8) {
      VinylSurface(spinning: spinning, cover: cover, period: spinPeriod)
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.top, compact ? 4 : 8)

      VStack(alignment: .leading, spacing: compact ? 2 : 5) {
        HStack(spacing: 5) {
          if track.isLive {
            PixelBadge(text: "LIVE", tint: Y2K.pink, glyph: "●")
          } else {
            PixelBadge(text: track.resolvedKind.label, tint: track.resolvedKind == .mix ? Y2K.cyan : Y2K.butter)
          }
          Text(track.durationText).font(Y2K.pixel(15)).foregroundStyle(Y2K.inkDim)
          if !track.viewText.isEmpty {
            Text(track.viewText).font(Y2K.pixel(15)).foregroundStyle(Y2K.inkDim)
          }
          Spacer(minLength: 2)
          Text("gate \(String(format: "%.1f", track.gate?.score ?? 0))")
            .font(Y2K.pixel(14))
            .foregroundStyle(Y2K.lime.opacity(0.85))
        }

        Text(track.title)
          .font(Y2K.display(compact ? 9 : 11.5))
          .foregroundStyle(.white)
          .lineLimit(compact ? 1 : 2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)

        if !compact {
          Text(credit)
            .font(Y2K.pixel(19))
            .foregroundStyle(Y2K.cyan)
            .lineLimit(1)
            .neon(Y2K.cyan, radius: 8)

          HStack(spacing: 5) {
            ForEach(track.tags.prefix(3), id: \.self) { TagPill(tag: $0) }
            Spacer(minLength: 0)
            Text("↕ sleeve")
              .font(Y2K.pixel(13))
              .foregroundStyle(Y2K.inkDim)
          }
        }
      }
      .padding(.horizontal, compact ? 8 : 10)
      .padding(.bottom, compact ? 4 : 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// A 6-hour mix should not feel like a 7-inch single. Same curve as the
  /// prototype's `--spin` (deck.js → clamp(duration / 700, 2.2, 7.5)) so both
  /// surfaces turn at the same speed for the same record.
  private var spinPeriod: Double {
    let seconds = Double(max(track.durationSeconds, 1200))
    return min(7.5, max(2.2, seconds / 700))
  }

  // MARK: Sleeve (back)

  private var sleeve: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("SLEEVE NOTES")
          .font(Y2K.pixel(15))
          .tracking(3)
          .foregroundStyle(Y2K.pink)

        Text(track.bestDescription.isEmpty ? "no description" : track.bestDescription)
          .font(Y2K.body(12))
          .foregroundStyle(Y2K.ink.opacity(0.92))
          .lineLimit(6)

        Divider().overlay(.white.opacity(0.14))

        Text("TOP COMMENTS")
          .font(Y2K.pixel(15))
          .tracking(3)
          .foregroundStyle(Y2K.pink)

        let shown = app.visibleComments(for: track).prefix(2)
        if shown.isEmpty {
          Text("comments load a beat after the disc lands")
            .font(Y2K.body(11.5))
            .foregroundStyle(Y2K.inkDim)
        }
        ForEach(Array(shown)) { comment in
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
              Text(comment.author).font(Y2K.pixel(15)).foregroundStyle(.white)
              Text(comment.isLive ? "LIVE" : "sample")
                .font(Y2K.pixel(11))
                .foregroundStyle(comment.isLive ? Y2K.lime : Y2K.inkDim)
              Spacer()
              Text(comment.likeText).font(Y2K.pixel(13)).foregroundStyle(Y2K.lime)
            }
            Text(comment.text)
              .font(Y2K.body(11.5))
              .foregroundStyle(Y2K.ink.opacity(0.9))
              .lineLimit(3)
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
        }

        Button {
          flipped = false
        } label: {
          Text("↺ back to the disc")
            .font(Y2K.pixel(16))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .lofiGlassButton()
      }
      .padding(12)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Artwork

  /// hqdefault is 480×360 and letterboxed; maxresdefault is full-frame but only
  /// exists for some uploads, so try the big one and fall back.
  static func cover(for videoId: String) async -> UIImage? {
    let candidates = [
      "https://i.ytimg.com/vi/\(videoId)/maxresdefault.jpg",
      "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
      "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg",
    ]
    for string in candidates {
      guard let url = URL(string: string) else { continue }
      if let (data, response) = try? await URLSession.shared.data(from: url),
         (response as? HTTPURLResponse)?.statusCode == 200,
         let image = UIImage(data: data),
         image.size.width > 160 {
        return image
      }
    }
    return nil
  }
}

// MARK: - Now playing glass

struct NowPlayingBar: View {
  @EnvironmentObject private var app: AppState
  @EnvironmentObject private var config: AppConfig
  @Binding var sheet: DeckSheet?

  var body: some View {
    VStack(spacing: 7) {
      ChromeMarquee(text: marquee)
        .padding(.horizontal, 4)

      HStack(spacing: 8) {
        Button { Task { await app.swipe(-1) } } label: { Image(systemName: "backward.end.fill").font(.system(size: 13)) }
          .buttonStyle(.borderless)
          .frame(width: 34, height: 34)
          .background(Circle().fill(.white.opacity(0.10)))

        Button { app.toggle() } label: {
          Image(systemName: app.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 50, height: 50)
            .background(Circle().fill(Y2K.stampPink))
            .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
            .neon(Y2K.pink, radius: 12)
        }
        .buttonStyle(.borderless)

        Button { Task { await app.swipe(1) } } label: { Image(systemName: "forward.end.fill").font(.system(size: 13)) }
          .buttonStyle(.borderless)
          .frame(width: 34, height: 34)
          .background(Circle().fill(.white.opacity(0.10)))

        VStack(spacing: 3) {
          GeometryReader { proxy in
            ZStack(alignment: .leading) {
              Capsule().fill(.white.opacity(0.16))
              Capsule()
                .fill(Y2K.spectrum)
                .frame(width: max(3, proxy.size.width * CGFloat(app.progress)))
            }
          }
          .frame(height: 7)
          HStack {
            Text(timeText).font(Y2K.pixel(13)).foregroundStyle(Y2K.inkDim)
            Spacer()
            if let next = app.nextCredit {
              Text("next · \(next.artist) \(next.timecode)").font(Y2K.pixel(12)).foregroundStyle(Y2K.butter.opacity(0.85)).lineLimit(1)
            }
          }
        }
      }

      HStack(spacing: 7) {
        Button { sheet = .info } label: { Label("desc · credits · comments", systemImage: "doc.text").font(Y2K.pixel(15)) }
          .buttonStyle(GlassChipButtonStyle())
        Button { sheet = .boost } label: {
          HStack(spacing: 4) {
            Text("boost").font(Y2K.pixel(15))
            Text(String(format: "%+.1f", config.boost.db)).font(Y2K.pixel(16)).foregroundStyle(Y2K.lime)
          }
        }
        .buttonStyle(GlassChipButtonStyle())
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .foregroundStyle(Y2K.ink)
    .lofiGlass(corner: Y2K.cornerM, tint: .clear)
  }

  private var marquee: String {
    let track = app.current
    let credit = app.currentCredit
    if let track {
      let who = credit.map { "\($0.artist)\($0.title.isEmpty ? "" : " — \($0.title)")" } ?? track.channelName
      return "◉ \(who) · \(track.channelName)\(track.license.map { " · \($0)" } ?? "")"
    }
    return "◉ standby · swipe a disc"
  }

  private var timeText: String {
    func fmt(_ t: TimeInterval) -> String {
      let s = Int(t)
      return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    guard app.duration > 1 else { return fmt(app.position) }
    return "\(fmt(app.position)) / \(fmt(app.duration))"
  }
}
