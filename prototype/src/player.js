// ---------------------------------------------------------------------------
// player.js — playback abstraction.
//
//  · "youtube" → real YouTube playback through the IFrame API (browser side).
//    This is the compliant way to hear YouTube in a web view; on iOS the app
//    uses the same approach via the inline player (see PlayerKind.embedded).
//  · "synth"   → the procedural lofi loop, which is fully routable through
//    Web Audio, so the +12 dB boost chain can be auditioned for real.
// ---------------------------------------------------------------------------

import { LofiSynth } from "./boost.js";
import { log, toast } from "./util.js";

let apiPromise = null;
function apiReady() {
  if (window.YT?.Player) return Promise.resolve(window.YT);
  if (apiPromise) return apiPromise;
  apiPromise = new Promise((resolve) => {
    const prev = window.onYouTubeIframeAPIReady;
    window.onYouTubeIframeAPIReady = () => {
      prev?.();
      resolve(window.YT);
    };
    // script tag is <async> in index.html; poll as a safety net
    const t = setInterval(() => {
      if (window.YT?.Player) {
        clearInterval(t);
        resolve(window.YT);
      }
    }, 120);
    setTimeout(() => clearInterval(t), 12000);
  });
  return apiPromise;
}

export class Player {
  constructor(handlers = {}) {
    this.h = handlers;
    this.kind = "youtube";
    this.videoId = null;
    this.yt = null;
    this.ready = false;
    this.ytReady = false;
    this.embedBlocked = false;
    this.synth = null;
    this.timer = null;
    this.paused = true;
    this.wantPlay = false;
    this.startAt = 0;
  }

  async mount(host, engine) {
    this.host = host;
    this.engine = engine;
    const YT = await apiReady();
    if (!YT?.Player) {
      this.embedBlocked = true;
      log("YouTube IFrame API never loaded — using synth source", "warn");
      this.kind = "synth";
      return;
    }
    const div = document.createElement("div");
    div.id = "yt-host";
    host.append(div);
    this.yt = new YT.Player(div, {
      width: "100%",
      height: "100%",
      playerVars: {
        controls: 0,
        disablekb: 1,
        modestbranding: 1,
        rel: 0,
        playsinline: 1,
        iv_load_policy: 3,
        fs: 0,
      },
      events: {
        onReady: () => {
          this.ytReady = true;
          log("youtube player ready", "ok");
          this.h.onReady?.();
          if (this.wantPlay) this.play();
        },
        onStateChange: (e) => {
          const S = YT.PlayerState;
          if (e.data === S.PLAYING) {
            this.paused = false;
            this.startTicking();
          } else if (e.data === S.PAUSED) {
            this.paused = true;
          } else if (e.data === S.ENDED) {
            this.paused = true;
            this.h.onEnded?.();
          }
          this.h.onState?.(e.data);
        },
        onError: (e) => {
          const code = e.data;
          log(`iframe error ${code}`, "warn");
          if (code === 101 || code === 150) {
            this.embedBlocked = true;
            toast("owner disabled playback on this video · switch to boost source");
            this.h.onBlocked?.(code);
          } else if (code === 2 || code === 5 || code === 100) {
            toast(code === 100 ? "video gone — skipping" : "player said no (embed unavailable)");
            this.h.onBlocked?.(code);
          }
        },
      },
    });
    this.startTicking();
  }

  startTicking() {
    if (this.timer) return;
    this.timer = setInterval(() => this.tick(), 220);
  }

  tick() {
    const pos = this.position();
    const dur = this.duration();
    this.h.onTime?.(pos, dur, this.level());
  }

  setKind(kind) {
    if (kind === this.kind) return;
    const wasPlaying = !this.paused;
    const pos = this.position();
    if (this.kind === "youtube" && this.yt) {
      try {
        this.yt.pauseVideo();
      } catch {}
    }
    if (this.kind === "synth" && this.synth) this.synth.stop();
    this.kind = kind;
    if (kind === "synth") this.synth = this.synth || new LofiSynth(this.engine);
    log(`source → ${kind}`);
    if (wasPlaying) this.play(pos);
    else if (pos) this.seek?.(pos);
  }

  async load(videoId, startSeconds = 0, autoplay = true) {
    this.videoId = videoId;
    this.startAt = startSeconds;
    this.wantPlay = autoplay;
    if (this.kind === "synth") {
      this.synth = this.synth || new LofiSynth(this.engine);
      this.synth.stop();
      this.synth.offset = startSeconds;
      if (autoplay) this.play();
      return;
    }
    if (!this.yt || !this.ytReady || this.embedBlocked) {
      log(`queued ${videoId} (player not ready${this.embedBlocked ? "/blocked" : ""})`);
      return;
    }
    try {
      this.yt.loadVideoById({ videoId, startSeconds });
    } catch (err) {
      log(`loadVideoById failed: ${err.message}`, "warn");
    }
  }

  play() {
    this.wantPlay = true;
    if (this.kind === "synth") {
      this.synth = this.synth || new LofiSynth(this.engine);
      this.synth.start();
      this.paused = false;
      this.startTicking();
      return;
    }
    if (this.yt?.playVideo) {
      try {
        this.yt.playVideo();
        this.paused = false;
      } catch {}
    }
  }

  pause() {
    this.wantPlay = false;
    if (this.kind === "synth") {
      this.synth?.stop();
      this.paused = true;
      return;
    }
    if (this.yt?.pauseVideo) {
      try {
        this.yt.pauseVideo();
        this.paused = true;
      } catch {}
    }
  }

  toggle() {
    this.paused ? this.play() : this.pause();
  }

  position() {
    if (this.kind === "synth") return this.synth?.position?.() || 0;
    try {
      return this.yt?.getCurrentTime?.() ?? this.startAt;
    } catch {
      return this.startAt;
    }
  }

  duration() {
    if (this.kind === "synth") return 3600; // loop has no end
    try {
      const d = this.yt?.getDuration?.() || 0;
      return d > 1 ? d : 0;
    } catch {
      return 0;
    }
  }

  seek(sec) {
    if (this.kind === "synth") {
      this.synth && (this.synth.offset = sec);
      return;
    }
    try {
      this.yt?.seekTo?.(sec, true);
    } catch {}
  }

  /** 0–100 like the native app's system volume step. */
  setVolumePct(pct) {
    this.volumePct = pct;
    if (this.kind === "synth") {
      if (this.engine?.state) this.engine.state.out = Math.max(0, Math.min(1, pct / 100));
      this.engine?.apply?.(true);
      return;
    }
    try {
      this.yt?.setVolume?.(Math.round(pct));
    } catch {}
  }

  /** RMS/peak for meters; only the routable source can report real levels. */
  level() {
    if (this.kind === "synth") return this.engine.meter();
    return null;
  }
}
