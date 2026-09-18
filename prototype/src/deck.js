// ---------------------------------------------------------------------------
// deck.js — every song is a disc, swipe left/right to find one.
// ---------------------------------------------------------------------------

import { el, fmtCount, fmtTime, durationText, clamp } from "./util.js";
import { artistAt } from "./youtube.js";
import { state, current } from "./state.js";

const SWIPE_X = 92;
const SWIPE_V = 0.55; // px per ms
const FLIP_Y = 66;

export class Deck {
  constructor(root, handlers = {}) {
    this.root = root;
    this.stack = root.querySelector("#stack");
    this.h = handlers;
    this.nodes = [];
    this.dragging = false;
    this.install();
  }

  install() {
    // glass specular follows the pointer, per element
    addEventListener(
      "pointermove",
      (e) => {
        const g = e.target.closest?.(".glass");
        if (!g) return;
        const r = g.getBoundingClientRect();
        g.style.setProperty("--mx", `${(((e.clientX - r.left) / r.width) * 100).toFixed(1)}%`);
        g.style.setProperty("--my", `${(((e.clientY - r.top) / r.height) * 100).toFixed(1)}%`);
      },
      { passive: true }
    );
  }

  render(tracks = state.queue, index = state.idx) {
    this.stack.innerHTML = "";
    this.nodes = [];
    const [cur, next] = [tracks[index], tracks[index + 1]];
    if (cur) {
      const front = this.card(cur, "current");
      front.addEventListener("click", (e) => {
        if (!e.target.closest("[data-act]") && !this.moved) this.flip(front);
      });
      this.stack.append(front);
      this.nodes.push(front);
      this.attachDrag(front);
      this.current = front;
    } else {
      this.stack.append(el("div", { class: "empty" }, "no lofi in the deck — hit ⌕ and hunt some"));
      this.current = null;
    }
    if (next) {
      const under = this.card(next, "under");
      under.classList.add("card--under");
      this.stack.append(under);
      this.nodes.push(under);
    }
  }

  card(track, role) {
    const credit = artistAt(track.tracklist || [], state.time);
    const isLive = track.kind === "live";
    const node = el(
      "div",
      { class: `glass card card--${role}`, data: { vid: track.videoId } },
      [
        el("div", { class: "card__face card__face--front" }, [
          el("div", { class: "disc" }, [
            el("i", { class: "disc__arm" }),
            el("div", { class: "disc__label", style: `background-image:url('${track.thumbnail}')` }, [
              el("img", { src: track.thumbnail, alt: "", loading: "lazy", onerror: (e) => (e.target.style.display = "none") }),
            ]),
            el("div", { class: "disc__hole" }),
          ]),
          el("div", { class: "stamp stamp--left" }, [el("b", {}, "SKIP"), el("span", {}, "not this one")]),
          el("div", { class: "stamp stamp--right" }, [el("b", {}, "SPIN"), el("span", {}, "→ next lofi")]),
        ]),
        el("div", { class: "card__meta" }, [
          el("div", { class: "card__row" }, [
            isLive ? el("span", { class: "badge-live" }, "● live") : el("span", { class: "tag tag--pink" }, track.kind),
            el("span", { class: "mono" }, durationText(track.durationSeconds)),
            track.viewCount ? el("span", { class: "mono" }, `👁 ${fmtCount(track.viewCount)}`) : null,
            track.watching ? el("span", { class: "mono" }, track.watching) : null,
            el("span", { class: "mono", style: "margin-left:auto;opacity:.7" }, `gate ${track.gate?.score ?? "-"}`),
          ]),
          el("div", { class: "card__title" }, track.title),
          el("div", { class: "card__artist" }, credit ? `${credit.artist}${credit.title ? ` — ${credit.title}` : ""}` : track.channelName),
          el("div", { class: "card__row" }, [
            ...(track.tags || []).slice(0, 4).map((t) => el("span", { class: "tag tag--glass" }, `#${t}`)),
            el("button", { class: "mini", "data-act": "info" }, "◈ info"),
            el("button", { class: "mini", "data-act": "yt" }, "↗ youtube"),
          ]),
        ]),
        this.cardBack(track),
      ]
    );
    if (state.playing && role === "current") node.classList.add("is-playing");
    node.addEventListener("click", (e) => {
      const act = e.target.closest("[data-act]")?.dataset.act;
      if (act === "info") this.h.onInfo?.(track);
      if (act === "yt") window.open(track.watchUrl, "_blank", "noopener");
    });
    return node;
  }

  cardBack(track) {
    const comments = (state.comments[track.videoId]?.items || track.comments || []).slice(0, 2);
    return el("div", { class: "card__face card__face--back" }, [
      el("div", { class: "back" }, [
        el("h4", {}, "sleeve notes"),
        el("p", { class: "prose" }, (track.description || track.descriptionExcerpt || "no description").slice(0, 320)),
        el("h4", {}, "top comments"),
        ...comments.map((c) =>
          el("div", { class: "comment" }, [
            el("div", { class: "comment__who" }, [el("b", {}, c.author || "anon")]),
            el("div", { class: "comment__text" }, String(c.text || "").slice(0, 180)),
          ])
        ),
        comments.length ? null : el("div", { class: "empty" }, "comments load when you open ◈ info"),
      ]),
    ]);
  }

  flip(node) {
    node.classList.toggle("is-flipped");
    this.h.onFlip?.(node.classList.contains("is-flipped"));
  }

  attachDrag(node) {
    let x0 = 0,
      y0 = 0,
      t0 = 0,
      dx = 0,
      dy = 0;
    this.moved = false;

    const stamp = (side, v) => {
      const s = node.querySelector(`.stamp--${side}`);
      if (s) s.style.opacity = v;
    };

    node.addEventListener("pointerdown", (e) => {
      if (e.target.closest("[data-act]")) return;
      if (node.classList.contains("is-flipped")) return;
      this.dragging = true;
      this.moved = false;
      x0 = e.clientX;
      y0 = e.clientY;
      t0 = performance.now();
      dx = dy = 0;
      node.setPointerCapture(e.pointerId);
      this.root.classList.add("is-dragging");
    });

    node.addEventListener("pointermove", (e) => {
      if (!this.dragging) return;
      dx = e.clientX - x0;
      dy = e.clientY - y0;
      if (Math.abs(dx) > 6 || Math.abs(dy) > 6) this.moved = true;
      const rot = clamp(dx / 16, -22, 22);
      if (Math.abs(dy) > Math.abs(dx)) {
        node.style.transform = `translate3d(${dx * 0.3}px, ${dy * 0.5}px, 0) rotate(${rot * 0.25}deg) scale(${1 - Math.min(0.08, Math.abs(dy) / 1400)})`;
        stamp("left", clamp(Math.abs(dy) / FLIP_Y, 0, 1) * 0.9);
        node.dataset.pull = dy > 0 ? "down" : "up";
      } else {
        node.style.transform = `translate3d(${dx}px, ${dy * 0.18}px, 0) rotate(${rot}deg)`;
        stamp("right", clamp(dx / SWIPE_X, 0, 1));
        stamp("left", clamp(-dx / SWIPE_X, 0, 1));
      }
    });

    const end = (e) => {
      if (!this.dragging) return;
      this.dragging = false;
      this.root.classList.remove("is-dragging");
      const dt = Math.max(1, performance.now() - t0);
      const v = Math.abs(dx) / dt;
      const horizontal = Math.abs(dx) > Math.abs(dy);

      node.style.transition = "transform .42s cubic-bezier(.2,.9,.2,1)";
      if (horizontal && (Math.abs(dx) > SWIPE_X || v > SWIPE_V)) {
        const dir = dx > 0 ? 1 : -1;
        node.classList.add("card--flying");
        node.style.transform = `translate3d(${dir * (innerWidth || 640)}px, ${dy}px, 0) rotate(${dir * 34}deg)`;
        this.h.onSwipe?.(dir, node.__track);
      } else if (!horizontal && Math.abs(dy) > FLIP_Y) {
        node.style.transform = "";
        this.flip(node);
      } else {
        node.style.transform = "";
      }
      stamp("left", 0);
      stamp("right", 0);
      setTimeout(() => (node.style.transition = ""), 460);
    };

    node.addEventListener("pointerup", end);
    node.addEventListener("pointercancel", end);
  }

  /** Deal animation when a new disc arrives. */
  pulse() {
    const top = this.stack.firstElementChild;
    if (!top) return;
    top.classList.add("card--dealing");
    setTimeout(() => top.classList.remove("card--dealing"), 520);
  }

  setPlaying(on) {
    state.playing = !!on;
    const top = this.stack.firstElementChild;
    if (!top) return;
    top.classList.toggle("is-playing", !!on);
    const disc = top.querySelector(".disc");
    const cur = current();
    if (disc && cur) {
      // one revolution per "side" — feels right at ~1.9s and slows for long mixes
      const period = clamp((cur.durationSeconds || 1200) / 700, 2.2, 7.5);
      disc.style.setProperty("--spin", `${on ? period : 99999}s`);
    }
  }

  updateCredit() {
    const track = current();
    const top = this.stack.firstElementChild;
    if (!track || !top) return;
    const credit = artistAt(track.tracklist || [], state.time);
    const node = top.querySelector(".card__artist");
    if (!node) return;
    const text = credit ? `${credit.artist}${credit.title ? ` — ${credit.title}` : ""}` : track.channelName;
    if (node.textContent !== text) node.textContent = text;
  }
}

export function timeLabel(s, d) {
  if (!d) return fmtTime(s);
  return `${fmtTime(s)}/${fmtTime(d)}`;
}
