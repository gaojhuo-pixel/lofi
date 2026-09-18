import SwiftUI

// MARK: - Track info sheet
//
// The three things the request asked for that most lofi apps skip: the video's
// own description, the artist credits parsed out of it, and the top comments.

enum InfoTab: String, CaseIterable, Identifiable {
  case desc = "DESCRIPTION"
  case credits = "CREDITS + TAGS"
  case comments = "TOP COMMENTS"
  var id: String { rawValue }
}

struct TrackInfoSheet: View {
  @EnvironmentObject private var app: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var tab: InfoTab = .desc

  var body: some View {
    ZStack {
      Y2K.voidBackdrop.ignoresSafeArea()
      VStack(spacing: 10) {
        HStack {
          Text("sleeve")
            .font(Y2K.display(12))
            .foregroundStyle(Y2K.chrome)
          Spacer()
          Button { dismiss() } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.7))
          }
          .buttonStyle(.borderless)
        }
        .padding(.top, 6)

        Picker("", selection: $tab) {
          ForEach(InfoTab.allCases) { Text($0.rawValue).font(Y2K.pixel(13)).tag($0) }
        }
        .pickerStyle(.segmented)
        .colorMultiply(Y2K.chromeMid)

        if let track = app.current {
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              header(track)
              switch tab {
              case .desc: descriptionBlock(track)
              case .credits: creditsBlock(track)
              case .comments: commentsBlock(track)
              }
            }
            .padding(.bottom, 20)
          }
        } else {
          Text("no disc loaded")
            .font(Y2K.pixel(16))
            .foregroundStyle(Y2K.inkDim)
            .frame(maxWidth: .infinity, minHeight: 200)
        }
      }
      .padding(.horizontal, 14)
    }
  }

  // MARK: Header

  private func header(_ track: LofiTrack) -> some View {
    HStack(alignment: .top, spacing: 10) {
      AsyncImage(url: track.thumbnailURL) { image in
        image.resizable().aspectRatio(contentMode: .fill)
      } placeholder: {
        Rectangle().fill(.white.opacity(0.08))
      }
      .frame(width: 74, height: 54)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        Text(track.title).font(Y2K.body(13, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
        Text("\(track.channelName) · \(track.source.label)")
          .font(Y2K.pixel(14))
          .foregroundStyle(Y2K.cyan)
      }
      Spacer()
      Button {
        let added = app.toggleCrate(track)
        app.status = added ? "saved ♥" : "dropped"
      } label: {
        Image(systemName: app.isInCrate(track) ? "suit.heart.fill" : "suit.heart")
          .font(.system(size: 17))
          .foregroundStyle(app.isInCrate(track) ? Y2K.pink : .white.opacity(0.6))
      }
      .buttonStyle(.borderless)
    }
    .padding(10)
    .lofiGlass(corner: Y2K.cornerM, tint: .clear)
  }

  // MARK: Description

  private func descriptionBlock(_ track: LofiTrack) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("description · \(track.source.label)")
      Text(track.bestDescription.isEmpty ? "—" : track.bestDescription)
        .font(Y2K.body(12.5))
        .foregroundStyle(Y2K.ink.opacity(0.92))
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lofiGlass(corner: Y2K.cornerM, tint: .clear)

      if app.loadingDetails.contains(track.videoId) {
        ProgressView().tint(Y2K.cyan)
      } else if configUsesLiveSource {
        Button {
          Task { await app.enrich(track) }
        } label: {
          Text("re-pull description + tracklist").font(Y2K.pixel(15)).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .lofiGlassButton()
      }

      if !configUsesLiveSource {
        NoteRow(text: "seed mode shows the cached excerpt · switch source in Settings for the full text")
      }

      NoteRow(text: "youtube id \(track.videoId) · \(track.durationText) · gate \(String(format: "%.2f", track.gate?.score ?? 0))")

      if let url = track.watchURL {
        Link(destination: url) {
          HStack(spacing: 6) {
            Image(systemName: "play.rectangle.on.rectangle")
            Text("open on youtube")
          }
          .font(Y2K.pixel(15))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
        }
        .lofiGlassButton()
      }
    }
  }

  private var configUsesLiveSource: Bool { app.config.source != .seed }

  // MARK: Credits

  private func creditsBlock(_ track: LofiTrack) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("who is playing")
      let list = track.tracklist ?? []
      if list.isEmpty {
        NoteRow(text: "this description has no timestamped tracklist — the channel gets the credit instead")
      } else {
        ForEach(list) { entry in
          let now = list.credit(at: app.position)?.id == entry.id
          Button {
            app.jump(to: entry)
          } label: {
            HStack(spacing: 8) {
              Text(entry.timecode)
                .font(Y2K.pixel(15))
                .foregroundStyle(now ? Y2K.butter : Y2K.inkDim)
                .frame(width: 46, alignment: .leading)
              VStack(alignment: .leading, spacing: 1) {
                Text(entry.artist).font(Y2K.body(12.5, weight: .semibold)).foregroundStyle(.white)
                if let feat = entry.feat, !feat.isEmpty {
                  Text("ft. \(feat)").font(Y2K.pixel(13)).foregroundStyle(Y2K.inkDim)
                }
              }
              Spacer()
              Text(entry.title).font(Y2K.body(11)).foregroundStyle(Y2K.inkDim).lineLimit(1)
              if now { Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(Y2K.lime) }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
              if now {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .fill(LinearGradient(colors: [Y2K.pink.opacity(0.25), Y2K.cyan.opacity(0.14)], startPoint: .leading, endPoint: .trailing))
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          .buttonStyle(.borderless)
        }
      }

      SectionHeader("credit")
      VStack(alignment: .leading, spacing: 3) {
        CreditLine(label: "channel", value: "\(track.channelName)\(track.channelHandle.map { " (\($0))" } ?? "")")
        if let channelId = track.channelId { CreditLine(label: "channel id", value: channelId) }
        if let override = track.creditOverride { CreditLine(label: "track", value: override) }
        CreditLine(label: "license", value: track.license ?? "not stated — re-credit the uploader wherever this goes")
        if let published = track.publishedLabel { CreditLine(label: "published", value: published) }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .lofiGlass(corner: Y2K.cornerM, tint: .clear)

      if !track.tags.isEmpty {
        SectionHeader("tags")
        FlowLayout(spacing: 6) {
          ForEach(track.tags, id: \.self) { TagPill(tag: $0) }
        }
      }

      if let gate = track.gate {
        SectionHeader("why this is in your deck")
        NoteRow(text: gate.explain)
      }
    }
  }

  // MARK: Comments

  private func commentsBlock(_ track: LofiTrack) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SectionHeader("top comments")
        Spacer()
        Text(app.provenanceLabel(for: track)).font(Y2K.pixel(12)).foregroundStyle(Y2K.inkDim)
        if app.loadingComments.contains(track.videoId) {
          ProgressView().controlSize(.mini).tint(Y2K.cyan)
        } else {
          Button {
            Task { await app.loadComments(track, force: true) }
          } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 12))
          }
          .buttonStyle(.borderless)
        }
      }

      let items = app.visibleComments(for: track)
      if items.isEmpty {
        NoteRow(text: "no comments yet — pull them with ↻ (needs a reachable source)")
      }
      ForEach(items) { comment in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(comment.author).font(Y2K.pixel(15)).foregroundStyle(.white)
            if comment.pinned == true { PixelBadge(text: "PINNED", tint: Y2K.butter) }
            if comment.creatorReplied == true { PixelBadge(text: "ARTIST REPLIED", tint: Y2K.lime) }
            Spacer()
            Text(comment.isLive ? "live" : "sample")
              .font(Y2K.pixel(12))
              .padding(.horizontal, 5)
              .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.22), lineWidth: 0.8))
              .foregroundStyle(comment.isLive ? Y2K.lime : Y2K.inkDim)
          }
          Text(comment.text)
            .font(Y2K.body(12))
            .foregroundStyle(Y2K.ink.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            Text(comment.likeText).font(Y2K.pixel(14)).foregroundStyle(Y2K.lime)
            if let time = comment.time { Text(time).font(Y2K.pixel(12)).foregroundStyle(Y2K.inkDim) }
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lofiGlass(corner: Y2K.cornerM, tint: .clear)
      }
    }
  }
}

// MARK: - Shared bits

struct SectionHeader: View {
  var text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(Y2K.pixel(15))
      .tracking(2.6)
      .foregroundStyle(Y2K.pink)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct NoteRow: View {
  var text: String
  var body: some View {
    Text(text)
      .font(Y2K.pixel(13))
      .foregroundStyle(Y2K.inkDim)
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.25)))
  }
}

struct CreditLine: View {
  var label: String
  var value: String
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label).font(Y2K.pixel(13)).foregroundStyle(Y2K.inkDim).frame(width: 74, alignment: .leading)
      Text(value).font(Y2K.body(12)).foregroundStyle(Y2K.ink).textSelection(.enabled)
      Spacer(minLength: 0)
    }
  }
}

/// Wrapping row for tags, without pulling in a layout library.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x + size.width > maxWidth, x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x + size.width > bounds.maxX, x > bounds.minX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
