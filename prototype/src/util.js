// Small DOM/util helpers shared by every module.

export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

export function el(tag, props = {}, kids = []) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "class") n.className = v;
    else if (k === "html") n.innerHTML = v;
    else if (k.startsWith("on")) n.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === "data") Object.entries(v).forEach(([dk, dv]) => (n.dataset[dk] = dv));
    else if (v !== null && v !== undefined) n.setAttribute(k, v);
  }
  for (const kid of [].concat(kids)) {
    if (kid == null) continue;
    n.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return n;
}

export const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

export const dbToLinear = (db) => Math.pow(10, db / 20);

export function fmtTime(s) {
  if (!Number.isFinite(s) || s < 0) return "0:00";
  s = Math.floor(s);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
}

export function fmtCount(n) {
  if (!Number.isFinite(n) || n <= 0) return "";
  const units = [["B", 1e9], ["M", 1e6], ["K", 1e3]];
  for (const [u, v] of units) if (n >= v) return `${(n / v).toFixed(n / v >= 10 ? 0 : 1)}${u}`;
  return String(n);
}

export function durationText(seconds) {
  if (!seconds || seconds <= 0) return "LIVE";
  return fmtTime(seconds);
}

export const shuffle = (arr) => {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
};

export const uid = () => Math.random().toString(36).slice(2, 9);

/* --------------------------------------------------------------- logger */
let logEl = null;
export function setLogTarget(node) {
  logEl = node;
}
export function log(msg, kind = "") {
  const line = el("div", {}, [kind === "warn" ? el("em", {}, "⚠ " + msg) : kind === "ok" ? el("b", {}, "✓ " + msg) : document.createTextNode("· " + msg)]);
  if (!logEl) return;
  logEl.append(line);
  logEl.scrollTop = logEl.scrollHeight;
  while (logEl.children.length > 140) logEl.firstChild.remove();
  console.debug("[lofi.glass]", msg);
}

let toastTimer = null;
export function toast(text, ms = 2600) {
  const node = $("#toast");
  if (!node) return;
  node.textContent = text;
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (node.hidden = true), ms);
}

export function flash() {
  const f = $("#flash");
  if (!f) return;
  f.classList.remove("is-on");
  void f.offsetWidth;
  f.classList.add("is-on");
}

/* Y2K cursor sparkles */
export function sparkles(enabled = true) {
  if (!enabled) return;
  let last = 0;
  addEventListener("pointermove", (e) => {
    const now = performance.now();
    if (now - last < 60) return;
    last = now;
    if (e.target.closest?.(".phone")) return;
    const s = el("div", { class: "spark" }, "✦");
    s.style.left = e.clientX + "px";
    s.style.top = e.clientY + "px";
    s.style.setProperty("--dx", (Math.random() * 40 - 20).toFixed(0) + "px");
    s.style.setProperty("--dy", (Math.random() * -34 - 8).toFixed(0) + "px");
    document.body.append(s);
    setTimeout(() => s.remove(), 720);
  });
}
