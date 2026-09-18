import SwiftUI

// MARK: - Deck
//
// Every song is a disc. Drag it sideways and the app goes and finds another
// lofi video; drag it up and it flips to the sleeve (description + comments).
// Left is rewind, right is "next", because that is what a deck of records
// implies: you put the one you just heard back on the left.

struct DeckView: View {
  @EnvironmentObject private var app: AppState
  @EnvironmentObject private var config: AppConfig
  @Binding var sheet: DeckSheet?
  @Binding var flip: Bool

  @State private var drag: CGFloat = 0
  @State private var vertical: CGFloat = 0
  private let swipeThreshold: CGFloat = 92
  private let flipThreshold: CGFloat = 64

  var body: some View {
    ZStack {
      playerLayer

      if let track = app.current {
        ZStack {
          if let upcoming = app.upcoming {
            VinylDiscCard(track: upcoming, credit: upcoming.headline(at: app.position), spinning: false, compact: true)
              .scaleEffect(0.9)
              .offset(y: 16)
              .opacity(0.55)
              .blur(radius: 1.2)
          }

          VinylDiscCard(
            track: track,
            credit: app.currentCredit?.display ?? track.channelName,
            spinning: app.isPlaying,
            compact: false,
            flipped: $flip
          )
          .offset(x: drag, y: vertical)
          .rotationEffect(.degrees(Double(drag / 16)))
          .overlay { stamps(for: track) }
          .gesture(dragGesture)
          .onTapGesture {
            withAnimation(.spring(duration: 0.45, bounce: 0.25)) { flip.toggle() }
          }
          .onLongPressGesture(minimumDuration: 0.35) {
            sheet = .info
          }
        }
        .animation(.spring(duration: 0.5, bounce: 0.22), value: track.videoId)
      } else {
        EmptyDeck(busy: app.busy)
          .contentShape(Rectangle())
          .onTapGesture { Task { await app.hunt(reason: "empty") } }
      }

      if app.busy { SeekingVeil() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Player behind the record

  @ViewBuilder private var playerLayer: some View {
    Group {
      switch config.route {
      case .embedded:
        if let track = app.current {
          EmbeddedPlayerView(
            videoId: track.videoId,
            startSeconds: 0,
            wantsPlaying: app.isPlaying,
            volumePercent: config.boost.systemVolumePercent,
            onEvent: { event in
              switch event {
              case .ready:
                app.status = "embed ready"
              case .time(let t, let d):
                app.report(time: t, duration: d)
              case .ended:
                Task { @MainActor in await app.hunt(reason: "ended") }
              case .failed(let message):
                app.status = "embed: \(message)"
              }
            }
          )
          .id(track.videoId)
          .opacity(flip ? 0.25 : 0.9)
        }
      case .boostedLocal:
        BoostedPlayerView(app: app)
          .opacity(flip ? 0.25 : 0.9)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: Y2K.cornerXL, style: .continuous))
    .allowsHitTesting(false)
    .animation(.easeOut(duration: 0.3), value: flip)
  }

  // MARK: Stamps

  @ViewBuilder private func stamps(for track: LofiTrack) -> some View {
    HStack {
      Stamp(text: "SKIP", sub: "not this one", gradient: Y2K.stampPink, tilt: -8)
        .opacity(Double(min(1, -drag / swipeThreshold)))
      Spacer()
      Stamp(text: "SPIN", sub: "→ next lofi", gradient: Y2K.stampCyan, tilt: 8)
        .opacity(Double(min(1, drag / swipeThreshold)))
    }
    .opacity(flip ? 0 : 1)
    .allowsHitTesting(false)
  }

  // MARK: Gesture

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { value in
        let dx = value.translation.width
        let dy = value.translation.height
        if abs(dx) > abs(dy) {
          drag = dx
          vertical = dy * 0.18
        } else {
          vertical = dy * 0.5
          drag = dx * 0.3
        }
      }
      .onEnded { value in
        // Read the finished translation before zeroing the state, otherwise the
        // direction is always "left".
        let dx = abs(drag) > abs(vertical) ? drag : 0
        let dy = dx == 0 ? vertical : 0
        let commit = abs(dx) > swipeThreshold
        let doFlip = abs(dy) > flipThreshold

        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
          drag = 0
          vertical = 0
        }

        if commit {
          Task { await app.swipe(dx > 0 ? 1 : -1) }
        } else if doFlip {
          withAnimation(.spring(duration: 0.5, bounce: 0.25)) { flip.toggle() }
        } else if abs(value.translation.width) < 4, abs(value.translation.height) < 4 {
          // a press, not a fling → open the sleeve
          sheet = .info
        }
      }
  }
}

// MARK: - Bits

private struct Stamp: View {
  var text: String
  var sub: String
  var gradient: LinearGradient
  var tilt: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(text).font(Y2K.pixel(21)).tracking(2.2)
      Text(sub).font(Y2K.pixel(12)).opacity(0.85)
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(gradient))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
    .rotationEffect(.degrees(tilt))
    .padding(14)
    .neon(.white, radius: 8)
  }
}

private struct SeekingVeil: View {
  @EnvironmentObject private var app: AppState
  @State private var phase: CGFloat = -0.4

  var body: some View {
    VStack(spacing: 10) {
      Text("SEEKING LOFI…")
        .font(Y2K.pixel(19))
        .tracking(3)
        .foregroundStyle(Y2K.lime)
        .neon(Y2K.lime, radius: 10)
      GeometryReader { proxy in
        Capsule()
          .fill(Y2K.cyan)
          .frame(width: proxy.size.width * 0.4, height: 6)
          .offset(x: phase * proxy.size.width)
          .onAppear {
            withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) { phase = 1.05 }
          }
      }
      .frame(height: 6)
      .background(Capsule().fill(.white.opacity(0.14)))
      Text(app.status)
        .font(Y2K.pixel(13))
        .foregroundStyle(Y2K.inkDim)
        .lineLimit(1)
    }
    .padding(18)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.ultraThinMaterial.opacity(0.7))
    .contentShape(Rectangle())
  }
}

private struct EmptyDeck: View {
  var busy: Bool

  var body: some View {
    VStack(spacing: 12) {
      Starburst(size: 44, color: Y2K.pink).neon(Y2K.pink, radius: 14)
      Text(busy ? "digging…" : "no lofi in the deck")
        .font(Y2K.display(13))
        .foregroundStyle(Y2K.chromeMid)
      Text("tap to hunt")
        .font(Y2K.pixel(15))
        .foregroundStyle(Y2K.cyan)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
