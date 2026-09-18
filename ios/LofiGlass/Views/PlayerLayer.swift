import SwiftUI
import WebKit

// MARK: - Playback routes
//
// Two of them, because the tradeoff is real and the user should own it:
//
//  · .embedded — YouTube's own inline player in a WKWebView. This is the route
//    that stays inside what YouTube offers apps: artwork, title, description,
//    comments, playback. It also means AVAudioEngine can't get between the
//    decoder and the speakers, so "boost" maps onto the player's own volume.
//  · .boostedLocal — audio decoded by AudioBoostEngine from a file your own
//    resolver returned. Here the −12…+12 dB chain is literally in the signal
//    path, which is the whole point of the feature.
//
// AppState swaps between them; both report time/duration the same way.

struct EmbeddedPlayerView: UIViewRepresentable {
  var videoId: String
  var startSeconds: Int
  var wantsPlaying: Bool
  var volumePercent: Int
  var onEvent: (PlayerEvent) -> Void

  enum PlayerEvent {
    case ready
    case time(TimeInterval, TimeInterval)
    case ended
    case failed(String)
  }

  func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    let controller = WKUserContentController()
    controller.add(context.coordinator, name: "lofi")
    config.userContentController = controller
    // Inline playback with the ringer switch muted, no PiPCheating.
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []

    let web = WKWebView(frame: .zero, configuration: config)
    web.isOpaque = false
    web.backgroundColor = .clear
    web.scrollView.isScrollEnabled = false
    web.uiDelegate = context.coordinator
    web.navigationDelegate = context.coordinator
    context.coordinator.web = web
    web.loadHTMLString(Self.html, baseURL: nil)
    return web
  }

  func updateUIView(_ web: WKWebView, context: Context) {
    context.coordinator.onEvent = onEvent
    guard context.coordinator.isReady else { return }
    if context.coordinator.loadedId != videoId {
      context.coordinator.loadedId = videoId
      web.evaluateJavaScript("window.lgLoad('\(videoId)', \(startSeconds));", completionHandler: nil)
    }
    web.evaluateJavaScript("window.lgSetPlaying(\(wantsPlaying ? "true" : "false"));", completionHandler: nil)
    web.evaluateJavaScript("window.lgVolume(\(volumePercent));", completionHandler: nil)
  }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    var onEvent: (PlayerEvent) -> Void
    weak var web: WKWebView?
    var isReady = false
    var loadedId: String?

    init(onEvent: @escaping (PlayerEvent) -> Void) {
      self.onEvent = onEvent
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard let body = message.body as? [String: Any], let name = body["e"] as? String else { return }
      switch name {
      case "ready":
        isReady = true
        onEvent(.ready)
      case "time":
        let pos = (body["t"] as? Double) ?? 0
        let dur = (body["d"] as? Double) ?? 0
        onEvent(.time(pos, dur))
      case "ended":
        onEvent(.ended)
      case "error":
        onEvent(.failed(body["m"] as? String ?? "embed error"))
      default:
        break
      }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      onEvent(.failed(error.localizedDescription))
    }
  }

  /// Minimal player harness. `origin` is left unset on purpose: with a nil base
  /// URL the page is `about:blank`, and YouTube's API accepts that for playback.
  static let html = """
  <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
  <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{position:absolute;inset:-2% -6%;width:112%;height:104%}
  video{object-fit:cover}</style></head><body>
  <div id="p"></div>
  <script src="https://www.youtube.com/iframe_api"></script>
  <script>
  var player=null, timer=null, wantPlay=false, pending=null;
  function post(o){ try{ window.webkit.messageHandlers.lofi.postMessage(o); }catch(e){} }
  function tick(){ if(!player||!player.getCurrentTime) return;
    post({e:'time', t:player.getCurrentTime(), d:player.getDuration()||0}); }
  function startTimer(){ if(timer) clearInterval(timer); timer=setInterval(tick,250); tick(); }
  window.onYouTubeIframeAPIReady=function(){
    player=new YT.Player('p',{videoId:(pending&&pending.id)||undefined,
      playerVars:{controls:0,disablekb:1,modestbranding:1,rel:0,playsinline:1,iv_load_policy:3,fs:0,start:pending?pending.s:0},
      events:{
        onReady:function(){ startTimer(); post({e:'ready'}); if(pending&&pending.id){player.loadVideoById({videoId:pending.id,startSeconds:pending.s||0});} if(wantPlay){player.unMute();player.playVideo();} },
        onStateChange:function(ev){
          var S=YT.PlayerState;
          if(ev.data===S.ENDED){ post({e:'ended'}); }
          if(ev.data===S.PLAYING||ev.data===S.PAUSED){ tick(); }
        },
        onError:function(ev){ post({e:'error', m:'yt error '+ev.data}); }
      }});
  };
  window.lgLoad=function(id,sec){ pending={id:id,s:sec||0};
    if(player&&player.loadVideoById){ player.loadVideoById({videoId:id,startSeconds:sec||0}); if(wantPlay) player.playVideo(); } };
  window.lgSetPlaying=function(on){ wantPlay=!!on; if(!player) return;
    if(on){ player.unMute(); player.playVideo(); } else { player.pauseVideo(); } };
  window.lgVolume=function(pct){ if(player&&player.setVolume) try{ player.setVolume(Math.max(0,Math.min(100,pct))); }catch(e){} };
  </script></body></html>
  """
}

// MARK: - Boosted local player

struct BoostedPlayerView: View {
  @ObservedObject var app: AppState

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { _ in
      Canvas { ctx, size in
        // Spectrum-ish bar field driven by the engine's metering, so the "TV
        // behind the record" still does something while the deck spins.
        let bars = 40
        let level = app.meter.peakDb
        let norm = max(0, min(1, (level + 48) / 48))
        for i in 0..<bars {
          let phase = 0.35 + 0.65 * abs(sin(Double(i) * 0.55 + app.position * 1.7))
          let h = size.height * CGFloat(norm * phase * (1 - Double(i) / Double(bars * 2)))
          let rect = CGRect(x: CGFloat(i) / CGFloat(bars) * size.width, y: size.height - h, width: size.width / CGFloat(bars) - 1.5, height: h)
          ctx.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Y2K.cyan.opacity(0.55), Y2K.pink.opacity(0.45)]),
            startPoint: CGPoint(x: 0, y: size.height),
            endPoint: CGPoint(x: 0, y: 0)
          ))
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: Y2K.cornerL, style: .continuous))
    .overlay(alignment: .bottomLeading) {
      Text(app.routeLabel)
        .font(Y2K.pixel(13))
        .foregroundStyle(Y2K.lime)
        .padding(6)
    }
  }
}
