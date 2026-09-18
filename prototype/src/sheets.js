// ---------------------------------------------------------------------------
// sheets.js — the liquid-glass sheets: info, boost, search, crate, settings.
// ---------------------------------------------------------------------------

import { el, fmtCount, fmtTime, durationText, toast, log } from "./util.js";
import { state, current, applyBoost, inCrate, toggleCrate } from "./state.js";
import { PRESETS, PRESET_LABELS, BOOST_MIN_DB, BOOST_MAX_DB } from "./boost.js";
import { gateTrack } from "./lofi-filter.js";
import { thumbFor, parseTracklist, artistAt, fetchDetails, fetchTopComments } from "./youtube.js";

export const fmtDb = (db) => `${db > 0 ? "+" : ""}${Number(db).toFixed(1)}dB`;

export class Sheets {
  constructor(handlers = {}) {
    this.h = handlers;
    this.scrim = document.getElementById("scrim");
    this.byId = {
      info: document.getElementById("sheetInfo"),
      boost: document.getElementById("sheetBoost"),
      search: document.getElementById("sheetSearch"),
      crate: document.getElementById("sheetCrate"),
      settings: document.getElementById("sheetSettings"),
    };
    this.scrim.addEventListener("click", () => this.close());
    addEventListener("keydown", (e) => e.key === "Escape" && this.close());
    this.open = null;
  }

  show(name, builder) {
    const node = this.byId[name];
    if (!node) return;
    node.innerHTML = "";
    node.append(
      el("div", { class: "sheet__grab" }),
      el("div", { class: "sheet__head" }, [
        el(
          "h3",
          { class: "sheet__title" },
          name === "info"
            ? "sleeve · description + credits + comments"
            : name === "boost"
            ? "boost · −12…+12 dB"
            : name === "search"
            ? "hunt for lofi"
            : name === "crate"
            ? "my crate"
            : "source & feel"
        ),
        el("button", { class: "sheet__close", onClick: () => this.close() }, "✕"),
      ]),
      builder()
    );
    node.classList.add("glass");
    Object.values(this.byId).forEach((n) => (n.hidden = n !== node));
    this.scrim.hidden = false;
    this.open = name;
    document.querySelectorAll(".dock__item").forEach((b) => b.classList.toggle("is-on", b.dataset.tab === name));
  }

  close() {
    Object.values(this.byId).forEach((n) => (n.hidden = true));
    this.scrim.hidden = true;
    this.open = null;
    document.querySelectorAll(".dock__item").forEach((b) => b.classList.toggle("is-on", b.dataset.tab === "deck"));
  }

  /* ------------------------------------------------------------- info */
  openInfo(track = current(), tab = "desc") {
    if (!track) return toast("nothing in the deck yet");
    this.infoTrack = track;
    this.infoTab = tab;
    this.show("info", () => this.infoBody(track, tab));
  }

  infoBody(track, tab) {
    const wrap = el("div", { class: "boost" });
    wrap.append(
      el(
        "div",
        { class: "tabs" },
        [
          ["desc", "description"],
          ["credits", "credits + tags"],
          ["comments", "top comments"],
        ].map(([k, label]) => el("button", { class: tab === k ? "is-on" : "", onClick: () => this.openInfo(track, k) }, label))
      )
    );

    wrap.append(
      el("div", { class: "block" }, [
        el("div", { class: "row" }, [
          el("img", { src: track.thumbnail, alt: "", onerror: (e) => (e.target.style.visibility = "hidden") }),
          el("div", {}, [el("div", { class: "row__t" }, track.title), el("div", { class: "row__s" }, `${track.channelName} · ${track.source}`)]),
          el(
            "button",
            {
              class: `preset ${inCrate(track.videoId) ? "is-on" : ""}`,
              onClick: (e) => {
                const added = toggleCrate(track);
                e.target.classList.toggle("is-on", added);
                e.target.textContent = added ? "♥ saved" : "♥";
                toast(added ? "saved to crate ♥" : "dropped from crate");
              },
            },
            inCrate(track.videoId) ? "♥ saved" : "♥"
          ),
        ]),
      ])
    );

    if (tab === "desc") {
      const cached = state.details[track.videoId];
      const pullBtn = el(
        "button",
        {
          class: "btn",
          onClick: async (e) => {
            e.target.disabled = true;
            e.target.textContent = "pulling…";
            const d = await this.loadDetails(track);
            if (d) {
              log(`description + tracklist pulled for ${track.videoId}`, "ok");
              this.openInfo(track, "desc");
            } else {
              e.target.disabled = false;
              e.target.textContent = "unreachable — showing the cached excerpt";
            }
          },
        },
        cached ? "re-pull from youtube" : "pull full description from youtube"
      );
      wrap.append(
        el("div", { class: "block" }, [
          el("h4", {}, `description · ${cached ? cached.origin : "seed cache"}`),
          el("p", { class: "prose prose--desc" }, cached?.description || track.description || track.descriptionExcerpt || "—"),
          pullBtn,
          el("div", { class: "row__s mono" }, `youtube id ${track.videoId} · ${durationText(track.durationSeconds)} · gate score ${track.gate?.score}`),
        ])
      );
    }

    if (tab === "credits") {
      const tracklist = tracklistOf(track);
      const now = artistAt(tracklist, state.time);
      wrap.append(
        el("div", { class: "block" }, [
          el("h4", {}, "who is playing right now"),
          tracklist.length
            ? el(
                "div",
                { class: "list" },
                tracklist.map((e) =>
                  el(
                    "div",
                    {
                      class: `credit ${now && now.startSeconds === e.startSeconds ? "is-on" : ""}`,
                      onClick: () => {
                        this.h.onSeek?.(e.startSeconds);
                        toast(`seek → ${e.artist} — ${e.title}`);
                      },
                    },
                    [
                      el("span", { class: "t" }, fmtTime(e.startSeconds)),
                      el("div", {}, [el("span", { class: "a" }, e.artist || "?"), e.feat ? el("span", { class: "s" }, ` ft. ${e.feat}`) : null]),
                      el("span", { class: "s" }, e.title || ""),
                    ]
                  )
                )
              )
            : el("div", { class: "empty" }, "this description has no timestamped tracklist"),
        ]),
        el("div", { class: "block" }, [
          el("h4", {}, "credits"),
          el("p", { class: "prose" }, linesOf(track)),
        ]),
        el("div", { class: "block" }, [
          el("h4", {}, "tags"),
          (track.tags || []).length
            ? el(
                "div",
                { class: "chiprow" },
                track.tags.map((t) => el("span", { class: "tag tag--glass" }, `#${t}`))
              )
            : el("div", { class: "empty" }, "no hashtags in the description"),
        ]),
        el("div", { class: "block" }, [
          el("h4", {}, "why this passed the lofi gate"),
          el(
            "p",
            { class: "prose" },
            `score ${track.gate?.score} ≥ ${track.gate?.threshold} · matched: ${track.gate?.hits?.join(", ") || "—"}${
              track.gate?.penalties?.length ? ` · penalised: ${track.gate.penalties.join(", ")}` : ""
            }`
          ),
        ])
      );
    }

    if (tab === "comments") {
      const cached = state.comments[track.videoId];
      const items = cached?.items?.length ? cached.items : track.comments || [];
      const box = el("div", { class: "block" }, [
        el("h4", {}, "top comments"),
        el("div", { class: "row__s mono" }, `${items.length} shown · ${cached?.origin || "seed cache"} · sorted by youtube relevance`),
      ]);
      if (!items.length) box.append(el("div", { class: "empty" }, "nothing cached yet — pull them live"));
      for (const c of items) {
        box.append(
          el("div", { class: "comment" }, [
            el("div", { class: "comment__who" }, [
              el("b", {}, c.author || "anon"),
              c.pinned ? el("span", { class: "badge-live" }, "pinned") : null,
              c.creatorReplied ? el("span", { class: "tag tag--pink" }, "artist replied") : null,
              el("span", { class: "comment__provenance", data: { p: c.provenance || "sample" } }, c.provenance === "youtube" ? "live" : "sample"),
            ]),
            el("div", { class: "comment__text" }, c.text || ""),
            el("div", { class: "comment__meta" }, [`▲ ${fmtCount(c.likes || 0)}`, c.time || ""]),
          ])
        );
      }
      const refresh = el(
        "button",
        {
          class: "btn btn--pink",
          onClick: async (e) => {
            e.target.disabled = true;
            e.target.textContent = "pulling comments…";
            const res = await fetchTopComments(track.videoId);
            if (res?.items?.length) {
              state.comments[track.videoId] = res;
              log(`${res.items.length} live top comments · ${res.origin}`, "ok");
              this.openInfo(track, "comments");
            } else {
              e.target.disabled = false;
              e.target.textContent = "instances unreachable — kept the samples";
            }
          },
        },
        "pull live top comments"
      );
      box.append(refresh);
      wrap.append(box);
    }
    return wrap;
  }

  async loadDetails(track) {
    const d = await fetchDetails(track.videoId);
    if (!d) return null;
    const parsed = d.chapters?.length
      ? d.chapters.map((c) => ({
          startSeconds: c.startSeconds,
          artist: (c.title || "").split(/\s+[-–—]\s+/)[0] || c.title,
          title: (c.title || "").split(/\s+[-–—]\s+/)[1] || "",
        }))
      : parseTracklist(d.description || "");
    state.details[track.videoId] = d;
    Object.assign(track, {
      description: d.description || track.description,
      tags: d.tags?.length ? [...new Set([...(track.tags || []), ...d.tags])] : track.tags,
      tracklist: parsed.length ? parsed : track.tracklist,
      durationSeconds: d.durationSeconds || track.durationSeconds,
      viewCount: d.viewCount || track.viewCount,
      gate: gateTrack({ title: track.title, description: d.description, tags: d.tags, channelName: d.channelName || track.channelName, durationSeconds: track.durationSeconds }),
    });
    return d;
  }

  /* ------------------------------------------------------------ boost */
  openBoost() {
    this.show("boost", () => {
      const s = state.boost;
      const box = el("div", { class: "boost" });

      box.append(
        el("div", { class: "boost__dbs" }, [
          el("b", { id: "boostDb" }, fmtDb(s.db)),
          el("i", { id: "boostState" }, s.db > 0 ? "boost armed" : s.db < 0 ? "trimmed" : "unity"),
          el("small", {}, "digital pre-gain, post-fader — the VLC slider, but with a ceiling"),
        ])
      );

      box.append(
        el("input", {
          type: "range",
          min: BOOST_MIN_DB,
          max: BOOST_MAX_DB,
          step: "0.5",
          value: s.db,
          id: "boostSlider",
          "aria-label": "boost in decibels",
          oninput: (e) => this.setBoost({ db: parseFloat(e.target.value), preset: "" }),
        }),
        el("div", { class: "boost__ticks" }, ["−12", "−6", "0", "+6", "+12"].map((t) => el("span", {}, t)))
      );

      box.append(el("canvas", { class: "viz", id: "boostViz", width: 640, height: 150 }));

      box.append(
        el(
          "div",
          { class: "boost__grid" },
          [
            eqField("low shelf · 130hz", "low", s.low, (v) => this.setBoost({ low: v, preset: "" })),
            eqField("mid peak · 900hz", "mid", s.mid, (v) => this.setBoost({ mid: v, preset: "" })),
            eqField("high shelf · 3.6khz", "high", s.high, (v) => this.setBoost({ high: v, preset: "" })),
          ]
        )
      );

      box.append(
        el("div", { class: "block" }, [
          el("h4", {}, "presets"),
          el(
            "div",
            { class: "presetrow" },
            Object.keys(PRESETS).map((k) =>
              el(
                "button",
                {
                  class: `preset ${s.preset === k ? "is-on" : ""}`,
                  "data-preset": k,
                  onClick: (e) => {
                    this.setBoost({ ...PRESETS[k], preset: k });
                    e.currentTarget.parentElement.querySelectorAll("[data-preset]").forEach((b) => b.classList.toggle("is-on", b === e.currentTarget));
                  },
                },
                PRESET_LABELS[k] || k
              )
            )
          ),
        ]),
        el("div", { class: "switchrow" }, [
          el("label", { class: "switchrow" }, [
            el("input", { type: "checkbox", ...(s.limiter ? { checked: "" } : {}), onchange: (e) => this.setBoost({ limiter: e.target.checked }) }),
            document.createTextNode(" limiter (vlc “volume safety”)"),
          ]),
          el("label", { class: "switchrow" }, [
            el("input", { type: "checkbox", ...(s.softClip ? { checked: "" } : {}), onchange: (e) => this.setBoost({ softClip: e.target.checked }) }),
            document.createTextNode(" soft clip"),
          ]),
        ]),
        el("div", { class: "block" }, [
          el("h4", {}, "output volume"),
          el("input", {
            type: "range",
            id: "sysVol",
            min: 0,
            max: 100,
            step: 1,
            value: state.volume,
            oninput: (e) => {
              state.volume = parseInt(e.target.value, 10);
              this.h.onVolume?.(state.volume);
            },
          }),
          el("div", { class: "row__s mono" }, "0–100 = the system volume step · anything above 0 dB above is app-side gain"),
        ]),
        el(
          "p",
          { class: "fine" },
          [
            "Two sources, one slider. With ",
            el("i", {}, "player: youtube"),
            " the dB value maps onto the IFrame's 0–100 volume and the +dB half reports as armed (cross-origin iframes can't be tapped by Web Audio). With ",
            el("i", {}, "player: synth"),
            " the same value drives a real graph — shelf → peak → shelf → boost → limiter → soft clip — so you hear exactly what AVAudioEngine does on device.",
          ]
        )
      );
      return box;
    });
  }

  /** Patch boost state; state.js emits "boost" and main re-routes. No re-render. */
  setBoost(patch) {
    applyBoost(patch);
  }

  /* ----------------------------------------------------------- search */
  openSearch(prefill = "") {
    this.show("search", () => {
      const box = el("div", { class: "boost" });
      const MOODS = ["study", "sleep", "rain", "cafe", "night-drive", "jazzy", "sad", "anime", "morning", "code"];
      const input = el("input", { type: "search", placeholder: "lofi rain · kudasai · night drive · 3am jazzhop", value: prefill, onkeydown: (e) => e.key === "Enter" && run() });
      const btn = el("button", { class: "btn btn--pink", onClick: () => run() }, "hunt");
      const run = async () => {
        btn.disabled = true;
        btn.textContent = "hunting…";
        try {
          await this.h.onHunt?.(input.value.trim(), state.mood);
        } finally {
          btn.disabled = false;
          btn.textContent = "hunt";
        }
      };
      box.append(
        el("div", { class: "searchbox" }, [input, btn]),
        el(
          "div",
          { class: "chiprow" },
          MOODS.map((m) =>
            el("button", {
              class: `moodchip ${state.mood === m ? "is-on" : ""}`,
              onClick: (e) => {
                state.mood = state.mood === m ? "" : m;
                e.currentTarget.parentElement.querySelectorAll(".moodchip").forEach((b) => b.classList.toggle("is-on", b.textContent === state.mood));
                run();
              },
            }, m)
          )
        ),
        el("div", { class: "row__s mono" }, "the gate drops anything that doesn't smell like lofi (score ≥ 4) — try “deep house” and watch it refuse"),
        el("div", { class: "list", id: "searchResults" }, [el("div", { class: "empty" }, "press hunt")])
      );
      return box;
    });
  }

  renderSearchResults(res) {
    const host = document.getElementById("searchResults");
    if (!host || !res) return;
    host.innerHTML = "";
    host.append(el("div", { class: "row__s mono" }, `${res.accepted.length} accepted · ${res.rejected.length} rejected · ${res.origin}`));
    for (const t of res.accepted.slice(0, 14)) {
      host.append(
        el("button", { class: "row", onClick: () => this.h.onPick?.(t) }, [
          el("img", { src: thumbFor(t.videoId, "mq"), alt: "", loading: "lazy" }),
          el("div", {}, [
            el("div", { class: "row__t" }, t.title),
            el("div", { class: "row__s" }, `${t.channelName} · ${(t.tags || []).slice(0, 3).map((x) => "#" + x).join(" ")}`),
          ]),
          el("div", { class: "row__r" }, durationText(t.durationSeconds)),
        ])
      );
    }
    const rejected = (res.rejected || []).concat(state.rejectedPool || []);
    if (rejected.length) {
      host.append(
        el("div", { class: "block" }, [
          el("h4", {}, "thrown out by the gate"),
          el(
            "div",
            { class: "list" },
            rejected.slice(0, 6).map((t) =>
              el("div", { class: "row" }, [
                el("img", { src: t.thumbnail || thumbFor(t.videoId, "mq"), alt: "" }),
                el("div", {}, [el("div", { class: "row__t" }, t.title), el("div", { class: "row__s" }, `score ${t.gate?.score} · ${t.rejectReason || t.gate?.penalties?.join(", ") || "no lofi signal"}`)]),
                el("div", { class: "row__r" }, "✕"),
              ])
            )
          ),
        ])
      );
    }
  }

  /* ------------------------------------------------------------ crate */
  openCrate() {
    this.show("crate", () => {
      const box = el("div", { class: "boost" });
      if (!state.crate.length) {
        box.append(el("div", { class: "empty" }, "crate empty — hit ♥ on a disc to keep it"));
        return box;
      }
      box.append(
        el(
          "div",
          { class: "list" },
          state.crate.map((t) =>
            el("div", { class: "row", onClick: () => this.h.onPick?.(t) }, [
              el("img", { src: t.thumbnail, alt: "" }),
              el("div", {}, [el("div", { class: "row__t" }, t.title), el("div", { class: "row__s" }, `${t.channelName} · ${t.mood}`)]),
              el(
                "button",
                {
                  class: "preset is-on",
                  onClick: (e) => {
                    e.stopPropagation();
                    toggleCrate(t);
                    this.openCrate();
                  },
                },
                "♥"
              ),
            ])
          )
        ),
        el("div", { class: "row__s mono" }, `${state.crate.length} discs · localStorage here, SwiftData on iOS`)
      );
      return box;
    });
  }

  /* --------------------------------------------------------- settings */
  openSettings() {
    this.show("settings", () => {
      const box = el("div", { class: "boost" });
      const srcBtn = (label, v) =>
        el("button", {
          class: `moodchip ${state.source === v ? "is-on" : ""}`,
          onClick: (e) => {
            state.source = v;
            e.currentTarget.parentElement.querySelectorAll(".moodchip").forEach((b) => b.classList.toggle("is-on", b === e.currentTarget));
            document.getElementById("srcDot")?.setAttribute("data-src", v);
            document.getElementById("selSource").value = v;
            document.getElementById("selSource").dispatchEvent(new Event("change"));
          },
        }, label);

      box.append(
        el("div", { class: "block" }, [
          el("h4", {}, "metadata source"),
          el("div", { class: "chiprow" }, [srcBtn("offline seed", "seed"), srcBtn("piped / invidious (live)", "piped")]),
          el(
            "p",
            { class: "fine" },
            "Live mode pulls real descriptions, hashtags, chapters and top comments from public Piped/Invidious JSON endpoints, from this browser. Anything unreachable falls back to the seed corpus — real YouTube metadata captured on 2026-09-18."
          ),
        ]),
        el("div", { class: "block" }, [
          el("h4", {}, "feel"),
          el("div", { class: "switchrow" }, [
            el("label", { class: "switchrow" }, [
              el("input", {
                type: "checkbox",
                ...(document.body.dataset.refract !== "off" ? { checked: "" } : {}),
                onchange: (e) => {
                  document.body.dataset.refract = e.target.checked ? "on" : "off";
                  state.refract = e.target.checked;
                },
              }),
              document.createTextNode(" glass refraction (feDisplacementMap)"),
            ]),
            el("label", { class: "switchrow" }, [
              el("input", {
                type: "checkbox",
                ...(document.body.dataset.crt !== "off" ? { checked: "" } : {}),
                onchange: (e) => {
                  document.body.dataset.crt = e.target.checked ? "on" : "off";
                  state.crt = e.target.checked;
                },
              }),
              document.createTextNode(" CRT scanlines"),
            ]),
          ]),
        ]),
        el("div", { class: "block" }, [
          el("h4", {}, "on device"),
          el(
            "p",
            { class: "prose" },
            [
              "ios/LofiGlass mirrors this screen 1:1:",
              "  · DeckView + VinylDiscCard — swipe ← / →",
              "  · TrackInfoSheet — description, parsed tracklist credits, tags, top comments",
              "  · AudioBoostEngine — AVAudioEngine: lowShelf/peak/highShelf → booster → DynamicsCompressor limiter → soft clip",
              "  · LofiFilter — same weights, same threshold",
              "",
              "YouTube playback on iOS goes through the official inline player (no DSP tap-in) or your own resolver behind a token — see docs/DATA-SOURCES.md",
            ].join("\n")
          ),
        ])
      );
      return box;
    });
  }
}

function eqField(label, key, value, onChange) {
  const out = el("span", { class: "mono" }, fmtDb(value));
  return el("div", { class: "field" }, [
    el("span", {}, label),
    out,
    el("input", {
      type: "range",
      min: -6,
      max: 6,
      step: 0.5,
      value: value,
      oninput: (e) => {
        const v = parseFloat(e.target.value);
        out.textContent = fmtDb(v);
        onChange(v);
      },
    }),
  ]);
}

function tracklistOf(track) {
  if (track.tracklist?.length) return track.tracklist;
  const parsed = parseTracklist(track.description || track.descriptionExcerpt || "");
  track.tracklist = parsed;
  return parsed;
}

function linesOf(track) {
  return [
    `channel · ${track.channelName}${track.channelHandle ? ` (${track.channelHandle})` : ""}`,
    track.channelId ? `channel id · ${track.channelId}` : "",
    track.creditOverride ? `track credit · ${track.creditOverride}` : "",
    `license · ${track.license || "not stated in the description — re-credit the uploader wherever this goes"}`,
    `published · ${track.publishedLabel || "n/a"}${track.viewCount ? ` · ${fmtCount(track.viewCount)} views` : ""}${track.watching ? ` · ${track.watching}` : ""}`,
    `source · ${track.watchUrl || "https://youtu.be/" + track.videoId}`,
  ]
    .filter(Boolean)
    .join("\n");
}
