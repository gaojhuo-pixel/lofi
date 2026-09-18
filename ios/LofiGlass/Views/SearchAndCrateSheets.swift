import SwiftUI

// MARK: - Hunt
//
// Search is deliberately narrow: every query gets "lofi" appended, results go
// through the gate, and whatever the gate drops stays on screen so you can see
// what it decided and why.

struct SearchSheet: View {
  @EnvironmentObject private var app: AppState
  @EnvironmentObject private var config: AppConfig
  @Environment(\.dismiss) private var dismiss

  @State private var query = ""
  @State private var mood: String?
  @State private var results = LofiSearchResults.empty
  @State private var running = false

  private let moods = ["study", "sleep", "rain", "cafe", "night-drive", "jazzy", "sad", "anime", "morning", "code"]

  var body: some View {
    ZStack {
      Y2K.voidBackdrop.ignoresSafeArea()
      VStack(spacing: 10) {
        HStack(spacing: 8) {
          HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Y2K.cyan)
            TextField("lofi rain · kudasai · night drive", text: $query)
              .font(Y2K.body(13))
              .foregroundStyle(.white)
              .tint(Y2K.pink)
              .onSubmit { run() }
            if !query.isEmpty {
              Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)) }
                .buttonStyle(.borderless)
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 9)
          .lofiGlass(corner: 14, tint: .clear)

          Button { run() } label: {
            Text(running ? "…" : "hunt").font(Y2K.pixel(16)).padding(.horizontal, 8).padding(.vertical, 9)
          }
          .lofiGlassButton()
        }
        .padding(.top, 8)

        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
              ForEach(moods, id: \.self) { m in
                Button {
                  mood = mood == m ? nil : m
                  run()
                } label: {
                  Text(m).font(Y2K.pixel(14)).padding(.horizontal, 4)
                }
                .buttonStyle(GlassChipButtonStyle())
                .overlay(alignment: .topTrailing) {
                  if mood == m { Circle().fill(Y2K.lime).frame(width: 5, height: 5).offset(x: 2, y: -2) }
                }
              }
            }

            if config.source == .seed {
              NoteRow(text: "seed corpus · \(app.config.source.label) — it searches the \(SeedProvider.shared.tracks.count) discs on disk, then the gate. pick piped or the data api in Settings for the whole site")
            }

            HStack {
              SectionHeader("\(results.accepted.count) accepted")
              Spacer()
              Text(results.origin).font(Y2K.pixel(12)).foregroundStyle(Y2K.inkDim)
              SectionHeader("\(results.rejected.count) rejected")
            }

            ForEach(results.accepted) { track in
              TrackRow(track: track) {
                app.status = "queued from search"
                Task {
                  await app.playFromCrate(track)
                  dismiss()
                }
              }
            }

            if !results.rejected.isEmpty {
              SectionHeader("thrown out by the gate")
              ForEach(results.rejected.prefix(6)) { track in
                TrackRow(track: track, dimmed: true) {}
              }
            }
          }
          .padding(.bottom, 22)
        }
      }
      .padding(.horizontal, 14)
    }
  }

  private func run() {
    running = true
    Task {
      results = await app.runSearch(query: query, mood: mood)
      running = false
    }
  }
}

// MARK: - Crate

struct CrateSheet: View {
  @EnvironmentObject private var app: AppState
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      Y2K.voidBackdrop.ignoresSafeArea()
      VStack(spacing: 10) {
        HStack {
          Text("my crate · \(app.crate.count)").font(Y2K.display(12)).foregroundStyle(Y2K.chrome)
          Spacer()
          if !app.crate.isEmpty {
            Button { app.config.resetCrate(); app.crate = [] } label: {
              Text("empty").font(Y2K.pixel(14))
            }
            .lofiGlassButton()
          }
          Button { dismiss() } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.7))
          }
          .buttonStyle(.borderless)
        }
        .padding(.top, 8)

        if app.crate.isEmpty {
          ContentUnavailableCompat(
            title: "crate empty",
            message: "♥ on a disc keeps it here. the crate is one JSON file in Application Support — swap it for SwiftData when you want artwork + notes."
          )
        } else {
          ScrollView {
            VStack(spacing: 8) {
              ForEach(app.crate) { track in
                TrackRow(track: track) {
                  Task {
                    await app.playFromCrate(track)
                    dismiss()
                  }
                }
              }
            }
            .padding(.bottom, 20)
          }
        }
      }
      .padding(.horizontal, 14)
    }
  }
}

// MARK: - Row

struct TrackRow: View {
  var track: LofiTrack
  var dimmed: Bool = false
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 9) {
        AsyncImage(url: track.thumbnailURL) { image in
          image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
          Rectangle().fill(.white.opacity(0.08))
        }
        .frame(width: 56, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

        VStack(alignment: .leading, spacing: 2) {
          Text(track.title).font(Y2K.body(12, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
          HStack(spacing: 5) {
            Text(track.channelName).font(Y2K.pixel(13)).foregroundStyle(dimmed ? Y2K.inkDim : Y2K.cyan).lineLimit(1)
            Text("·").foregroundStyle(Y2K.inkDim)
            Text(track.durationText).font(Y2K.pixel(13)).foregroundStyle(Y2K.inkDim)
          }
        }
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 3) {
          Text(String(format: "%.1f", track.gate?.score ?? 0))
            .font(Y2K.pixel(15))
            .foregroundStyle(dimmed ? Y2K.pink : Y2K.lime)
          if dimmed {
            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Y2K.pink.opacity(0.8))
          } else {
            Image(systemName: "arrow.right.circle").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
          }
        }
      }
      .padding(8)
      .opacity(dimmed ? 0.6 : 1)
      .lofiGlass(corner: Y2K.cornerM, tint: dimmed ? .clear : .chrome)
    }
    .buttonStyle(.borderless)
  }
}

/// ContentUnavailableView is iOS 17+; the app targets 18, but keeping a local
/// copy means these files still compile if you drop the deployment target.
struct ContentUnavailableCompat: View {
  var title: String
  var message: String

  var body: some View {
    VStack(spacing: 8) {
      Text(title).font(Y2K.display(13)).foregroundStyle(Y2K.chromeMid)
      Text(message)
        .font(Y2K.body(11.5))
        .foregroundStyle(Y2K.inkDim)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 300)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
