"""The companion window's page: one self-contained HTML document (no CDN, no files).

It lives in a .py module on purpose: the 4.x self-updater copies only top-level .py
files, so the window arrives with any update, and PyInstaller bundles it with no
extra data files. `render_page` adds the per-response CSP nonce and the Orbit mark.

Design: true black (#000), surfaces one lightness step up (#111), white type, colour
only on data and status, Orbit Blue (#0A84FF) for the live marks and the satellite,
the one primary action as an inverted white pill. Segoe UI Variable, sizes 12/14/18/24
and 40 for the pairing code. Motion is feedback only and stops under reduced motion.
"""
from orbit_logo import logo_svg

PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Orbit</title>
<link rel="icon" href="data:image/svg+xml,{{FAVICON}}">
<style nonce="{{NONCE}}">
:root {
  color-scheme: dark;
  --ground: #000; --surface: #111; --nested: #1b1b1b; --raised: #2a2a2a;
  --rule: #1f1f1f; --control: #3d3d3d; --control-hover: #5a5a5a;
  --text: #fff; --muted: #b4b4b4; --faint: #949494;
  --accent: #0a84ff;
  --positive: #3fc07a; --positive-bg: #14261a;
  --negative: #ef6b82; --negative-bg: #2c1a20;
  --warning: #f2b33d; --warning-bg: #2b2310;
  --radius: 16px; --radius-nested: 10px;
  --column: 1120px; --gutter: 32px;
  --font: "Segoe UI Variable Text", "Segoe UI Variable", "Segoe UI", system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif;
  --display: "Segoe UI Variable Display", "Segoe UI Variable", "Segoe UI", system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif;
  --mono: "Cascadia Mono", "Cascadia Code", Consolas, ui-monospace, Menlo, monospace;
  --ease: cubic-bezier(.2, .8, .2, 1);
}
* { box-sizing: border-box; }
html { background: var(--ground); }
body { margin: 0; min-height: 100vh; background: var(--ground); color: var(--text); font: 400 14px/20px var(--font);
  -webkit-font-smoothing: antialiased; font-variant-numeric: tabular-nums; }
button, input, textarea { font: inherit; color: inherit; }
a { color: inherit; }
:focus-visible { outline: 2px solid #fff; outline-offset: 2px; border-radius: 6px; }
.visually-hidden { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }

/* Shell: a 48px bar on the ground over one centred column. */
.bar { position: sticky; top: 0; z-index: 20; background: var(--ground); border-bottom: 1px solid transparent; transition: border-color .2s; }
.bar.scrolled { border-bottom-color: var(--rule); }
.bar-inner, main { max-width: var(--column); margin: 0 auto; padding-left: var(--gutter); padding-right: var(--gutter); }
.bar-inner { height: 48px; display: flex; align-items: center; gap: 36px; }
.brand { display: flex; align-items: center; gap: 10px; text-decoration: none; font: 600 15px/20px var(--display); flex: none; }
.brand svg { width: 22px; height: 22px; display: block; }
.nav { display: flex; gap: 26px; }
.nav a { color: var(--muted); text-decoration: none; font-weight: 600; line-height: 48px; transition: color .15s; }
.nav a:hover, .nav a[aria-current="page"] { color: var(--text); }
.scope { margin-left: auto; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.button.menu-button { display: none; margin-left: auto; }
.sheet { position: fixed; inset: 48px 0 0; background: var(--ground); z-index: 30; padding: 8px 20px; display: none; }
.sheet.open { display: block; }
.sheet a { display: block; padding: 14px 0; font: 600 18px/24px var(--display); text-decoration: none; color: var(--muted); border-bottom: 1px solid var(--rule); }
.sheet a[aria-current="page"] { color: var(--text); }

main { padding-top: 32px; padding-bottom: 96px; }

/* Title row */
.title-row { display: flex; align-items: flex-start; justify-content: space-between; gap: 24px; }
h1 { margin: 0; font: 600 24px/32px var(--display); letter-spacing: -.01em; }
.lede { margin: 6px 0 0; color: var(--muted); display: flex; flex-wrap: wrap; align-items: center; column-gap: 10px; row-gap: 4px; }
.lede strong { color: var(--text); font-weight: 600; }
.lede .line { flex-basis: 100%; }
.actions { display: flex; flex-wrap: wrap; gap: 10px; flex: none; }

/* Sections stacked about 48px apart, an 18/500 title on the left and a quiet action on the right. */
.section { margin-top: 44px; }
.section-head { display: flex; align-items: baseline; gap: 12px; margin-bottom: 14px; }
.section-head h2 { margin: 0; font: 500 18px/24px var(--display); }
.section-head .meta { color: var(--faint); display: inline-flex; align-items: center; gap: 8px; }
.section-head .end { margin-left: auto; display: flex; gap: 16px; align-items: baseline; }
.card { background: var(--surface); border-radius: var(--radius); padding: 8px 24px; }
.card.padded { padding: 24px; }

/* Controls */
.button { height: 36px; padding: 0 18px; border-radius: 999px; border: 1px solid var(--control); background: transparent; cursor: pointer;
  display: inline-flex; align-items: center; justify-content: center; gap: 8px; font-weight: 600; white-space: nowrap;
  transition: transform .1s var(--ease), border-color .15s, background-color .15s, color .15s; }
.button:hover { border-color: var(--control-hover); }
.button:active { transform: scale(.97); }
.button.primary { background: #fff; color: #000; border-color: #fff; }
.button.primary:hover { background: #e8e8e8; border-color: #e8e8e8; }
.button.danger { color: var(--negative); border-color: #4a2a31; }
.button:disabled { cursor: default; color: var(--faint); border-color: var(--rule); background: transparent; transform: none; }
.link { border: 0; background: none; padding: 0; cursor: pointer; color: var(--muted); font-weight: 600; text-decoration: none; transition: color .15s; }
.link:hover { color: var(--text); }
.link.danger { color: var(--negative); }

/* Status */
.dot { width: 8px; height: 8px; border-radius: 50%; background: var(--faint); display: inline-block; flex: none; }
.dot.ok { background: var(--positive); } .dot.problem { background: var(--negative); }
.dot.warning { background: var(--warning); } .dot.live { background: var(--accent); }
.pill { display: inline-flex; align-items: center; height: 22px; padding: 0 9px; border-radius: 999px; background: var(--nested);
  color: var(--muted); font: 500 12px/22px var(--font); white-space: nowrap; flex: none; }
.pill.ok { background: var(--positive-bg); color: var(--positive); }
.pill.problem { background: var(--negative-bg); color: var(--negative); }
.pill.warning { background: var(--warning-bg); color: var(--warning); }
.live-text { color: var(--text); display: inline-flex; align-items: center; gap: 8px; }

/* The connection path: four stations a device's request passes, left to right. */
.path { list-style: none; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(4, 1fr); background: var(--surface);
  border-radius: var(--radius); overflow: hidden; }
.path li { padding: 0 24px 22px; position: relative; min-width: 0; }
.path li + li { border-left: 1px solid var(--rule); }
.path .leg { height: 3px; margin: 0 -24px 18px; background: var(--raised); }
.path .ok .leg { background: var(--positive); } .path .problem .leg { background: var(--negative); }
.path .warning .leg { background: var(--warning); } .path .live .leg { background: var(--accent); }
.station { color: var(--faint); font-size: 12px; line-height: 16px; }
.station-state { margin-top: 6px; font: 500 16px/22px var(--font); }
.station-detail { margin-top: 4px; color: var(--muted); overflow-wrap: break-word; }
.verdict { margin-top: 16px; display: flex; gap: 16px; align-items: center; justify-content: space-between; }
.verdict p { margin: 0; color: var(--muted); max-width: 640px; }

/* The pairing code: the biggest thing on screen while a device waits for it. */
.pairing { display: grid; grid-template-columns: 1fr auto; gap: 8px 32px; align-items: center; background: var(--surface);
  border-radius: var(--radius); padding: 24px; margin-top: 28px; }
.pairing h2 { margin: 0; font: 500 18px/24px var(--display); }
.pairing p { margin: 6px 0 0; color: var(--muted); }
.code { font: 600 40px/48px var(--display); letter-spacing: .06em; grid-row: span 2; }
.countdown { display: flex; align-items: center; gap: 12px; color: var(--faint); }
.track { width: 220px; height: 4px; border-radius: 4px; background: var(--raised); overflow: hidden; }
.track .fill { height: 100%; background: var(--accent); transform-origin: left center; transition: transform 1s linear; }

/* KPI strip: one container split by 1px dividers. */
.strip { display: grid; grid-template-columns: repeat(3, 1fr); background: var(--surface); border-radius: var(--radius); }
.strip > div { padding: 18px 24px 20px; min-width: 0; }
.strip > div + div { border-left: 1px solid var(--rule); }
.kpi-label { color: var(--muted); font-weight: 500; }
.kpi-value { margin-top: 4px; font: 400 24px/32px var(--display); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.kpi-value small { font: 400 14px/20px var(--font); color: var(--faint); margin-left: 4px; }
.kpi-value.none { color: var(--faint); font-size: 14px; line-height: 32px; }

/* Rows */
table { width: 100%; border-collapse: collapse; }
th { text-align: left; color: var(--faint); font: 400 12px/16px var(--font); padding: 14px 12px 10px; white-space: nowrap; }
td { padding: 14px 12px; border-top: 1px solid var(--rule); vertical-align: middle; }
tr > :first-child { padding-left: 0; } tr > :last-child { padding-right: 0; text-align: right; }
tbody tr:first-child td { border-top: 0; }
.name { font-weight: 600; } .sub { color: var(--faint); font-size: 12px; line-height: 16px; margin-top: 2px; }
.muted { color: var(--muted); } .faint { color: var(--faint); } .nowrap { white-space: nowrap; }
.mono { font-family: var(--mono); font-size: 13px; }
.row-actions { display: inline-flex; gap: 18px; white-space: nowrap; }
.feed { list-style: none; margin: 0; padding: 0; }
.feed li { display: grid; grid-template-columns: 1fr auto; gap: 16px; padding: 13px 0; border-top: 1px solid var(--rule); }
.feed li:first-child { border-top: 0; }
.feed .when { color: var(--faint); white-space: nowrap; text-align: right; }

/* Editing a device in place */
.editor td { padding: 4px 0 22px; border-top: 0; text-align: left; }
.editor-body { background: var(--nested); border-radius: var(--radius-nested); padding: 20px; display: grid; grid-template-columns: 260px 1fr; gap: 24px; }
.scopes { display: grid; gap: 2px; }
.scope-row { display: flex; gap: 14px; align-items: center; padding: 8px 0; }
.scope-row .text { flex: 1; }
.editor-actions { grid-column: 1 / -1; display: flex; gap: 10px; align-items: center; }
.editor-actions .end { margin-left: auto; }

/* Switches: green when on, never the accent. */
.switch { width: 36px; height: 20px; border-radius: 999px; border: 0; background: #3a3a3a; position: relative; cursor: pointer; flex: none; padding: 0;
  transition: background-color .18s var(--ease); }
.switch::after { content: ""; position: absolute; top: 3px; left: 3px; width: 14px; height: 14px; border-radius: 50%; background: #fff;
  transition: transform .2s var(--ease); }
.switch[aria-checked="true"] { background: var(--positive); }
.switch[aria-checked="true"]::after { transform: translateX(16px); }
.switch:disabled { opacity: .5; cursor: default; }
.switch:active::after { width: 17px; }

/* Settings: a label column beside a panel. */
.settings-section { display: grid; grid-template-columns: 300px 1fr; gap: 40px; padding: 32px 0; border-top: 1px solid var(--rule); }
.settings-section:first-of-type { border-top: 0; padding-top: 28px; }
.settings-label h2 { margin: 0; font: 500 16px/22px var(--display); display: flex; gap: 10px; align-items: center; }
.settings-label p { margin: 6px 0 0; color: var(--muted); }
.saved { color: var(--positive); font: 500 12px/16px var(--font); opacity: 0; transition: opacity .2s; }
.saved.show { opacity: 1; }
.panel { background: var(--surface); border-radius: var(--radius); padding: 4px 20px; }
.switch-row { display: flex; align-items: center; gap: 16px; padding: 15px 0; }
.switch-row + .switch-row, .field + .field { border-top: 1px solid var(--rule); }
.switch-row .text { flex: 1; min-width: 0; } .switch-row .title { font-weight: 500; } .switch-row .desc { color: var(--muted); margin-top: 2px; }
.field { padding: 16px 0; display: grid; gap: 8px; align-content: start; }
.editor-body .field { padding: 0; }
.field label { font-weight: 500; }
.input { width: 100%; height: 36px; border-radius: var(--radius-nested); border: 1px solid #333; background: #0a0a0a; padding: 0 12px; }
textarea.input { height: auto; min-height: 76px; padding: 8px 12px; resize: vertical; line-height: 20px; }
.input:focus { outline: 2px solid #fff; outline-offset: 1px; }
.input:disabled { color: var(--faint); }
.hint { color: var(--faint); font-size: 12px; line-height: 16px; }
.error-text { color: var(--negative); font-size: 12px; line-height: 16px; }
.toast { margin-top: 20px; background: #1f1f1f; border-radius: 8px; padding: 12px 14px; max-width: 300px; }
.toast-head { display: flex; align-items: center; gap: 8px; color: var(--faint); font-size: 12px; line-height: 16px; }
.toast-head svg { width: 14px; height: 14px; }
.toast-title { margin-top: 8px; font-weight: 600; }
.toast-body { margin-top: 2px; color: var(--muted); }
.update-line { display: flex; align-items: center; gap: 16px; padding: 16px 0; }
.update-line .text { flex: 1; }

/* Key-value well */
.kv { display: grid; grid-template-columns: 220px 1fr; }
.kv dt, .kv dd { margin: 0; padding: 12px 0; border-top: 1px solid var(--rule); }
.kv dt { color: var(--muted); } .kv dd { overflow-wrap: anywhere; }
.kv dt:first-of-type, .kv dt:first-of-type + dd { border-top: 0; }

/* Tabs */
.tabs { display: flex; gap: 24px; border-bottom: 1px solid var(--rule); margin-top: 24px; overflow-x: auto; scrollbar-width: none; }
.tabs button { border: 0; background: none; padding: 0 0 12px; cursor: pointer; color: var(--muted); font-weight: 600; white-space: nowrap;
  border-bottom: 2px solid transparent; margin-bottom: -1px; transition: color .15s, border-color .15s; }
.tabs button:hover { color: var(--text); }
.tabs button[aria-selected="true"] { color: var(--text); border-bottom-color: #fff; }

/* States */
.empty { border: 1px dashed #333; border-radius: 8px; padding: 12px 16px; color: var(--muted); margin: 14px 0; }
.problem-line { display: flex; gap: 10px; align-items: center; padding: 16px 0; color: var(--muted); }
.skeleton { display: inline-block; height: 14px; width: 120px; border-radius: 4px; background: var(--nested); vertical-align: middle; }
.skeleton.big { height: 22px; width: 160px; }
.more { margin-top: 16px; display: flex; justify-content: center; }
.notice { margin-top: 16px; color: var(--muted); }

dialog { border: 0; border-radius: var(--radius); background: #1a1a1a; color: var(--text); padding: 24px; width: min(460px, calc(100vw - 32px));
  box-shadow: 0 24px 64px rgba(0, 0, 0, .55); }
dialog::backdrop { background: rgba(0, 0, 0, .6); }
dialog h2 { margin: 0; font: 600 18px/24px var(--display); }
dialog p { margin: 10px 0 0; color: var(--muted); }
dialog .token { margin-top: 16px; background: #0a0a0a; border-radius: var(--radius-nested); padding: 12px 14px; font-family: var(--mono);
  font-size: 13px; line-height: 20px; overflow-wrap: anywhere; user-select: all; }
dialog .dialog-actions { margin-top: 22px; display: flex; justify-content: flex-end; gap: 10px; }

.signed-out { max-width: 520px; padding-top: 18vh; }
.signed-out p { color: var(--muted); }

@media (max-width: 860px) {
  .path { grid-template-columns: repeat(2, 1fr); }
  .path li:nth-child(3) { border-left: 0; }
  .path li:nth-child(n + 3) { border-top: 1px solid var(--rule); }
  .strip { grid-template-columns: 1fr; }
  .strip > div + div { border-left: 0; border-top: 1px solid var(--rule); }
  .settings-section { grid-template-columns: 1fr; gap: 16px; }
  .editor-body { grid-template-columns: 1fr; }
  .kv { grid-template-columns: 1fr; } .kv dd { border-top: 0; padding-top: 0; } .kv dt { padding-bottom: 4px; }
}
@media (max-width: 720px) {
  :root { --gutter: 16px; }
  .nav, .scope { display: none; }
  .button.menu-button { display: inline-flex; }
  .title-row { flex-direction: column; }
  .pairing { grid-template-columns: 1fr; }
  .code { grid-row: auto; }
  .track { width: 100%; max-width: 260px; }
  .verdict { flex-direction: column; align-items: stretch; }
  .verdict .actions { flex: 1 1 auto; }
  table.rows thead { display: none; }
  table.rows tr { display: grid; grid-template-columns: 1fr auto; column-gap: 12px; border-top: 1px solid var(--rule); padding: 12px 0; }
  table.rows td { border: 0; padding: 0; text-align: left; }
  table.rows td.secondary { grid-column: 1 / -1; color: var(--faint); font-size: 13px; }
  table.rows td:last-child { grid-column: 2; grid-row: 1; text-align: right; }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { transition-duration: 0s !important; }
}
</style>
</head>
<body>
<header class="bar" id="bar">
  <div class="bar-inner">
    <a class="brand" href="#/overview" aria-label="Orbit, overview">{{LOGO}}<span>Orbit</span></a>
    <nav class="nav" aria-label="Orbit" id="nav">
      <a href="#/overview" data-view="overview">Overview</a>
      <a href="#/devices" data-view="devices">Devices</a>
      <a href="#/activity" data-view="activity">Activity</a>
      <a href="#/settings" data-view="settings">Settings</a>
      <a href="#/diagnostics" data-view="diagnostics">Diagnostics</a>
    </nav>
    <span class="scope" id="scope"></span>
    <button class="button menu-button" id="menu-button" aria-expanded="false" aria-controls="sheet">Menu</button>
  </div>
</header>
<nav class="sheet" id="sheet" aria-label="Orbit">
  <a href="#/overview" data-view="overview">Overview</a>
  <a href="#/devices" data-view="devices">Devices</a>
  <a href="#/activity" data-view="activity">Activity</a>
  <a href="#/settings" data-view="settings">Settings</a>
  <a href="#/diagnostics" data-view="diagnostics">Diagnostics</a>
</nav>
<main id="main"><div class="view" id="view"></div></main>
<dialog id="dialog" aria-labelledby="dialog-title"></dialog>
<script nonce="{{NONCE}}">
"use strict";
const SIGNED_IN = {{SIGNED_IN}};
const LOGO = `{{LOGO_SMALL}}`;
const view = document.getElementById("view");
const dialog = document.getElementById("dialog");
let timers = [];
let currentView = "";
const SCOPE_NAMES = {read: "Read", control: "Control", input: "Input", files: "Files", admin: "Admin"};
const SCOPE_HELP = {
  read: "Status, hardware, history, games and power settings",
  control: "Power, volume, apps, games and Sunshine",
  input: "Mouse, keyboard, clipboard and the screen preview",
  files: "Browse, download and upload files",
  admin: "Devices, settings, updates and the Sunshine login",
};
const PLATFORM_NAMES = {iOS: "iPhone", iPadOS: "iPad", macOS: "Mac", tvOS: "Apple TV", watchOS: "Apple Watch"};

const escape = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]));
const raw = (text) => ({__raw: text});
function h(strings, ...values) {
  let out = strings[0];
  values.forEach((value, index) => {
    if (Array.isArray(value)) value = raw(value.map((item) => (item && item.__raw !== undefined ? item.__raw : escape(item))).join(""));
    out += (value && value.__raw !== undefined ? value.__raw : escape(value)) + strings[index + 1];
  });
  return raw(out);
}
const render = (node, markup) => { node.innerHTML = markup.__raw; };

async function api(path, options = {}) {
  const headers = {"X-Orbit-Window": "1"};
  if (options.body !== undefined) headers["Content-Type"] = "application/json";
  const response = await fetch(path, {method: options.method || "GET", headers, credentials: "same-origin",
    body: options.body === undefined ? undefined : JSON.stringify(options.body)});
  if (response.status === 401) { expired(); throw new Error("expired"); }
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.detail || `Orbit answered ${response.status}.`);
  return body;
}

// MARK: time and words
const clock = new Intl.DateTimeFormat("en-GB", {hour: "2-digit", minute: "2-digit"});
const day = new Intl.DateTimeFormat("en-GB", {day: "numeric", month: "short"});
function parse(iso) { const value = iso ? new Date(iso) : null; return value && !isNaN(value) ? value : null; }
function online(device) { const seen = parse(device.lastSeenAt); return Boolean(seen && Date.now() - seen.getTime() < 90000); }
function when(iso) {
  const date = parse(iso);
  if (!date) return "Never";
  const seconds = (Date.now() - date.getTime()) / 1000;
  if (seconds < 60) return "Just now";
  if (seconds < 3600) return `${Math.max(1, Math.round(seconds / 60))} min ago`;
  const today = new Date(); const yesterday = new Date(Date.now() - 86400000);
  if (date.toDateString() === today.toDateString()) return `Today ${clock.format(date)}`;
  if (date.toDateString() === yesterday.toDateString()) return `Yesterday ${clock.format(date)}`;
  return `${day.format(date)} ${clock.format(date)}`;
}
function access(scopes) {
  if (!scopes || !scopes.length) return "No access";
  if (scopes.length === 5) return "Full access";
  return scopes.map((scope) => SCOPE_NAMES[scope] || scope).join(" · ");
}
function deviceKind(device) {
  const kind = PLATFORM_NAMES[device.platform] || device.platform || "";
  return [device.model && device.model !== kind ? device.model : kind, device.legacy ? "Paired before 5.0" : ""].filter(Boolean).join(" · ") || "Device";
}
function seen(device) {
  return online(device) ? h`<span class="live-text"><span class="dot live"></span>Connected now</span>` : h`${when(device.lastSeenAt)}`;
}
function duration(seconds) {
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return [String(minutes), "min"];
  const hours = Math.floor(minutes / 60); const rest = minutes % 60;
  return rest ? [`${hours} h ${rest}`, "min"] : [String(hours), "h"];
}
const ACTION_WORDS = {shutdown: "Shut down", restart: "Restart", sleep: "Sleep", hibernate: "Hibernate", signout: "Sign out", displayOff: "Display off"};

// MARK: shell
function setCurrent(name) {
  document.querySelectorAll("[data-view]").forEach((link) => link.toggleAttribute("aria-current", link.dataset.view === name));
  document.querySelectorAll("[data-view][aria-current]").forEach((link) => link.setAttribute("aria-current", "page"));
}
function stopTimers() { timers.forEach((timer) => clearInterval(timer)); timers = []; }
function every(ms, task) { timers.push(setInterval(() => { if (document.visibilityState === "visible") task(); }, ms)); }
function expired() {
  stopTimers();
  document.getElementById("nav").hidden = true;
  render(view, h`<section class="signed-out"><h1>This window has expired</h1>
    <p>Open Orbit again from its icon in the Windows tray, at the bottom right of the screen.</p></section>`);
}
function failure(node, message, retry) {
  render(node, h`<div class="problem-line"><span class="dot problem"></span><span>${message}</span>${retry ? h`<button class="link" data-retry>Retry</button>` : ""}</div>`);
  const button = node.querySelector("[data-retry]");
  if (button && retry) button.addEventListener("click", retry);
}
function flashSaved(id) {
  const stamp = document.getElementById(id);
  if (!stamp) return;
  stamp.classList.add("show");
  setTimeout(() => stamp.classList.remove("show"), 1800);
}
window.addEventListener("scroll", () => document.getElementById("bar").classList.toggle("scrolled", window.scrollY > 4), {passive: true});
document.getElementById("menu-button").addEventListener("click", (event) => {
  const sheet = document.getElementById("sheet");
  const open = !sheet.classList.contains("open");
  sheet.classList.toggle("open", open);
  event.currentTarget.setAttribute("aria-expanded", String(open));
});
document.getElementById("sheet").addEventListener("click", (event) => {
  if (event.target.closest("a")) { document.getElementById("sheet").classList.remove("open"); document.getElementById("menu-button").setAttribute("aria-expanded", "false"); }
});

function ask({title, body, confirm, danger, cancel = "Cancel"}) {
  render(dialog, h`<h2 id="dialog-title">${title}</h2><p>${body}</p>
    <div class="dialog-actions"><button class="button" value="cancel">${cancel}</button>
    ${confirm ? h`<button class="button ${danger ? "danger" : "primary"}" value="confirm">${confirm}</button>` : ""}</div>`);
  return new Promise((resolve) => {
    dialog.querySelectorAll("button").forEach((button) => button.addEventListener("click", () => { dialog.close(button.value); }));
    dialog.addEventListener("close", () => resolve(dialog.returnValue === "confirm"), {once: true});
    dialog.showModal();
  });
}

// MARK: the connection path
function stations(report, overview) {
  if (!report) {
    return h`${[0, 1, 2, 3].map(() => h`<li><div class="leg"></div><div class="station"><span class="skeleton"></span></div>
      <div class="station-state"><span class="skeleton big"></span></div></li>`)}`;
  }
  const network = report.network;
  const firewall = report.firewall || {};
  const missing = (firewall.rules || []).filter((rule) => rule.required && !rule.working).length;
  const devices = overview ? overview.counts : null;
  const list = [
    {label: "This network", state: network ? network.state : "unknown",
     title: network ? (network.category === "DomainAuthenticated" ? "Work network" : `${network.category} network`) : "Unknown",
     detail: network ? `${network.name} · ${network.interface}` : (report.reason || "Windows did not report a network")},
    {label: "Windows Firewall", state: report.available ? firewall.state : "unknown",
     title: !report.available ? "Unknown" : (missing ? (missing === 2 ? "Rules missing" : "A rule is missing") : "Orbit allowed"),
     detail: !report.available ? "Could not be checked" : (missing ? "TCP 8766 and UDP 5353 for the local network" : "TCP 8766 and UDP 5353, local network only")},
    {label: "Orbit on this PC", state: report.companion.state === "ok" ? "ok" : "problem",
     title: report.companion.state === "ok" ? "Listening" : "Not listening", detail: report.companion.detail},
    {label: "Your devices", state: devices && devices.online ? "live" : "unknown",
     title: devices ? (devices.online ? `${devices.online} connected now` : "None connected now") : "—",
     detail: devices ? `${devices.devices} paired` : ""},
  ];
  return h`${list.map((item) => h`<li class="${item.state}"><div class="leg"></div><div class="station">${item.label}</div>
    <div class="station-state">${item.title}</div><div class="station-detail">${item.detail}</div></li>`)}`;
}
function fixButtons(report) {
  return h`${(report && report.fixes || []).map((fix, index) => h`<button class="button ${index === 0 ? "primary" : ""}" data-fix="${fix.kind}"
    data-index="${fix.interfaceIndex || ""}">${fix.label}</button>`)}`;
}
function bindFixes(node, reload) {
  node.querySelectorAll("[data-fix]").forEach((button) => button.addEventListener("click", async () => {
    const kind = button.dataset.fix;
    const ok = await ask({title: kind === "firewall" ? "Add Orbit's firewall rules?" : "Make this network Private?",
      body: kind === "firewall"
        ? "Windows will ask for permission. Orbit adds three inbound rules for your local network only: TCP 8766, UDP 5353 and TCP 8765."
        : "Windows will ask for permission. Only do this on your home network: Private lets devices on it find this PC.",
      confirm: "Continue"});
    if (!ok) return;
    button.disabled = true;
    try {
      await api("/local/api/diagnostics/fix", {method: "POST", body: {kind, interfaceIndex: button.dataset.index ? Number(button.dataset.index) : null}});
      button.textContent = "Waiting for Windows…";
      let tries = 0;
      const check = setInterval(async () => {
        tries += 1;
        try { await reload(true); } catch (error) { /* shown by reload */ }
        if (tries >= 4) clearInterval(check);
      }, 3500);
      timers.push(check);
    } catch (error) {
      button.disabled = false;
      await ask({title: "Windows did not make the change", body: error.message, cancel: "Close"});
    }
  }));
}

// MARK: overview
async function showOverview() {
  pairingCode = null;
  render(view, h`<div class="title-row"><div><h1 id="pc-name"><span class="skeleton big"></span></h1>
      <p class="lede" id="verdict-line"><span class="skeleton"></span></p></div>
      <div class="actions"><button class="button primary" id="add-device">Add a device</button></div></div>
    <div id="pairing"></div>
    <section class="section"><div class="section-head"><h2>Connection</h2><span class="meta" id="checked"></span>
      <span class="end"><a class="link" href="#/diagnostics">Diagnostics</a></span></div>
      <ol class="path" id="path">${stations(null)}</ol><div class="verdict" id="verdict"></div></section>
    <section class="section"><div class="section-head"><h2>This PC</h2></div><div class="strip" id="strip"></div></section>
    <section class="section"><div class="section-head"><h2>Devices</h2>
      <span class="end"><a class="link" href="#/devices">View all</a></span></div><div class="card" id="devices"></div></section>
    <section class="section"><div class="section-head"><h2>Recent activity</h2>
      <span class="end"><a class="link" href="#/activity">View all</a></span></div><div class="card" id="activity"></div></section>`);
  document.getElementById("add-device").addEventListener("click", addDevice);
  let overview = null;
  let report = null;
  const drawPath = () => {
    render(document.getElementById("path"), stations(report, overview));
    const verdict = document.getElementById("verdict");
    if (report) {
      const tone = report.verdict.state;
      render(document.getElementById("checked"), h`Checked ${clock.format(parse(report.checkedAt) || new Date())}`);
      const fixing = Boolean(report.fixes && report.fixes.length);
      render(verdict, fixing ? h`<p>${report.verdict.detail}</p><div class="actions">${fixButtons(report)}</div>` : h``);
      document.getElementById("add-device").classList.toggle("primary", !fixing);
      bindFixes(verdict, loadReport);
      render(document.getElementById("verdict-line"), h`<span class="dot ${tone === "ok" ? "ok" : tone === "unknown" ? "" : tone}"></span>
        <strong>${report.verdict.title}</strong>${overview ? h`<span>${overview.pc.address || "No network address"} · HTTPS ${overview.pc.securePort}</span>` : ""}`);
    }
  };
  const loadReport = async (force) => {
    try { report = await api(`/local/api/diagnostics${force ? "?force=1" : ""}`); }
    catch (error) { report = {available: false, reason: error.message, companion: {state: "ok", detail: ""}, firewall: {}, fixes: [],
      verdict: {state: "unknown", title: "The network could not be checked", detail: error.message}}; }
    drawPath();
  };
  const load = async () => {
    try { overview = await api("/local/api/overview"); }
    catch (error) { if (error.message !== "expired") failure(document.getElementById("devices"), error.message, load); return; }
    if (currentView !== "overview") return;
    document.getElementById("scope").textContent = overview.pc.name;
    render(document.getElementById("pc-name"), h`${overview.pc.name}`);
    drawPairing(overview.pairing);
    drawStrip(overview);
    drawDeviceRows(document.getElementById("devices"), overview.devices.slice(0, 4), false);
    drawFeed(document.getElementById("activity"), overview.activity.slice(0, 5));
    drawPath();
  };
  await load();
  loadReport(false);
  every(4000, load);
  every(60000, () => loadReport(false));
}
let pairingTimer = null;
let pairingCode = null;
function drawPairing(pairing) {
  const node = document.getElementById("pairing");
  if (pairing && pairing.code === pairingCode && node.firstChild) return;
  clearInterval(pairingTimer);
  pairingCode = pairing ? pairing.code : null;
  if (!pairing) { render(node, h``); return; }
  const deadline = Date.now() + pairing.expiresIn * 1000;
  const spaced = `${pairing.code.slice(0, 3)} ${pairing.code.slice(3)}`;
  render(node, h`<section class="pairing" aria-live="polite"><div><h2>${pairing.kind === "device" ? "A device" : `Your ${pairing.kind}`} wants to pair</h2>
    <p>Type this code in Orbit on the ${pairing.kind === "device" ? "device" : pairing.kind}. It works once. If you did not ask for it, ignore it.</p></div>
    <div class="code" aria-label="Pairing code ${pairing.code.split("").join(" ")}">${spaced}</div>
    <div class="countdown"><div class="track"><div class="fill" id="pairing-fill"></div></div><span id="pairing-left"></span></div></section>`);
  const tick = () => {
    const left = Math.max(0, Math.round((deadline - Date.now()) / 1000));
    document.getElementById("pairing-left").textContent = left ? `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")} left` : "Expired";
    document.getElementById("pairing-fill").style.transform = `scaleX(${left / 120})`;
    if (!left) clearInterval(pairingTimer);
  };
  tick();
  pairingTimer = setInterval(tick, 1000);
  timers.push(pairingTimer);
}
function drawStrip(overview) {
  const timer = overview.power && overview.power.timer;
  const awake = overview.power && overview.power.keepAwake;
  let power = h`<div class="kpi-value none">No timer</div>`;
  if (timer && timer.remainingSeconds != null) {
    const [value, unit] = duration(timer.remainingSeconds);
    power = h`<div class="kpi-value">${value}<small>${unit}</small></div>`;
  } else if (timer) {
    power = h`<div class="kpi-value">Game exit</div>`;
  } else if (awake) {
    power = h`<div class="kpi-value">Awake</div>`;
  }
  const powerLabel = timer ? `${ACTION_WORDS[timer.action] || timer.action} timer` : (awake ? "Kept awake" : "Power");
  render(document.getElementById("strip"), h`
    <div><div class="kpi-label">Actions today</div><div class="kpi-value">${overview.counts.actionsToday}</div></div>
    <div><div class="kpi-label">Game</div>${overview.game ? h`<div class="kpi-value">${overview.game}</div>` : h`<div class="kpi-value none">None running</div>`}</div>
    <div><div class="kpi-label">${powerLabel}</div>${power}</div>`);
}
function drawDeviceRows(node, devices, full) {
  if (!devices.length) {
    render(node, h`<div class="empty">No device is paired yet. In Orbit on your iPhone, iPad, Mac or Apple TV, choose Find my PC.</div>`);
    return;
  }
  render(node, h`<table class="rows"><thead><tr><th>Device</th><th>Access</th><th>Last seen</th>${full ? h`<th>Address</th><th><span class="visually-hidden">Actions</span></th>` : h`<th>Address</th>`}</tr></thead>
    <tbody>${devices.map((device) => h`<tr data-id="${device.id}"><td><div class="name">${device.name}</div><div class="sub">${deviceKind(device)}</div></td>
      <td class="secondary">${access(device.scopes)}</td><td class="nowrap">${seen(device)}</td>
      <td class="secondary faint nowrap">${device.lastAddress || "—"}</td>
      ${full ? h`<td><span class="row-actions"><button class="link" data-edit="${device.id}">Edit</button>
        <button class="link" data-remove="${device.id}">Remove</button></span></td>` : ""}</tr>`)}</tbody></table>`);
}
function drawFeed(node, entries) {
  if (!entries.length) {
    render(node, h`<div class="empty">Nothing yet. When a device locks the PC, sends a file or changes a setting, it shows here.</div>`);
    return;
  }
  render(node, h`<ul class="feed">${entries.map((entry) => h`<li><div><div>${entry.summary}</div>
    <div class="sub">${entry.deviceName || "This PC"}${entry.result !== "ok" ? ` · ${entry.result === "denied" ? "Not allowed" : "Failed"}` : ""}</div></div>
    <div class="when">${when(entry.at)}</div></li>`)}</ul>`);
}

// MARK: devices
async function addDevice() {
  const ok = await ask({title: "Add a device",
    body: "On the iPhone, iPad, Mac or Apple TV, open Orbit and choose Find my PC. The code to type appears in a Windows dialog and here. For a device that cannot find this PC, create a manual token instead.",
    confirm: "Create a manual token", cancel: "Done"});
  if (!ok) return;
  try {
    const result = await api("/local/api/devices/manual", {method: "POST", body: {}});
    render(dialog, h`<h2 id="dialog-title">Manual token</h2>
      <p>${result.copied ? "Copied. Windows keeps it out of clipboard history, and Orbit clears it in a minute." : "Select it to copy."}
      Paste it in Orbit under Add manually, with this PC's address. It is shown once.</p>
      <div class="token">${result.token}</div><div class="dialog-actions"><button class="button primary" value="close">Done</button></div>`);
    dialog.querySelector("button").addEventListener("click", () => dialog.close());
    dialog.showModal();
    if (currentView === "devices") showDevices();
  } catch (error) {
    if (error.message !== "expired") ask({title: "No token was created", body: error.message, cancel: "Close"});
  }
}
async function showDevices() {
  render(view, h`<div class="title-row"><div><h1>Devices</h1><p class="lede" id="devices-lede"><span class="skeleton"></span></p></div>
    <div class="actions"><button class="button primary" id="add-device">Add a device</button></div></div>
    <section class="section" id="device-list"><span class="skeleton"></span></section>`);
  document.getElementById("add-device").addEventListener("click", addDevice);
  let data;
  try { data = await api("/local/api/devices"); }
  catch (error) { if (error.message !== "expired") failure(document.getElementById("device-list"), `Couldn't load the devices. ${error.message}`, showDevices); return; }
  const count = data.devices.length;
  const connected = data.devices.filter(online).length;
  render(document.getElementById("devices-lede"), h`<span>${count} paired · ${connected} connected now</span>
    <span class="line">Each device has its own token, so removing one never affects the others.</span>`);
  const node = document.getElementById("device-list");
  drawDeviceRows(node, data.devices, true);
  node.querySelectorAll("[data-edit]").forEach((button) => button.addEventListener("click", () => openEditor(data, button.dataset.edit)));
  node.querySelectorAll("[data-remove]").forEach((button) => button.addEventListener("click", () => removeDevice(data, button.dataset.remove)));
}
function openEditor(data, id) {
  const device = data.devices.find((item) => item.id === id);
  document.querySelectorAll("tr.editor").forEach((row) => row.remove());
  const row = document.querySelector(`tr[data-id="${CSS.escape(id)}"]`);
  const editor = document.createElement("tr");
  editor.className = "editor";
  render(editor, h`<td colspan="5"><form class="editor-body" id="editor">
    <div class="field"><label for="device-name">Name</label><input class="input" id="device-name" maxlength="60" value="${device.name}">
      <span class="hint">${deviceKind(device)} · paired ${when(device.createdAt)}</span></div>
    <div class="scopes" role="group" aria-label="What ${device.name} may do">${Object.keys(SCOPE_NAMES).map((scope) => h`<div class="scope-row">
      <div class="text"><div class="title">${SCOPE_NAMES[scope]}</div><div class="sub">${SCOPE_HELP[scope]}</div></div>
      <button type="button" class="switch" role="switch" aria-checked="${device.scopes.includes(scope)}" data-scope="${scope}" aria-label="${SCOPE_NAMES[scope]}"></button></div>`)}</div>
    <div class="editor-actions"><button class="button primary" type="submit">Save</button><button class="button" type="button" data-cancel>Cancel</button>
      <span class="error-text" id="editor-error"></span></div></form></td>`);
  row.after(editor);
  editor.querySelectorAll(".switch").forEach((toggle) => toggle.addEventListener("click", () =>
    toggle.setAttribute("aria-checked", String(toggle.getAttribute("aria-checked") !== "true"))));
  editor.querySelector("[data-cancel]").addEventListener("click", () => editor.remove());
  editor.querySelector("form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const scopes = [...editor.querySelectorAll(".switch")].filter((toggle) => toggle.getAttribute("aria-checked") === "true").map((toggle) => toggle.dataset.scope);
    try {
      await api(`/local/api/devices/${encodeURIComponent(id)}`, {method: "PATCH", body: {name: document.getElementById("device-name").value.trim(), scopes}});
      showDevices();
    } catch (error) { document.getElementById("editor-error").textContent = error.message; }
  });
  document.getElementById("device-name").focus();
}
async function removeDevice(data, id) {
  const device = data.devices.find((item) => item.id === id);
  const ok = await ask({title: `Remove ${device.name}?`, danger: true, confirm: "Remove",
    body: device.legacy
      ? "Every app paired before Orbit 5.0 uses this shared token. They stop working until you pair them again with a code."
      : `${device.name} can no longer reach this PC. To use it again, pair it with a new code.`});
  if (!ok) return;
  try { await api(`/local/api/devices/${encodeURIComponent(id)}`, {method: "DELETE"}); showDevices(); }
  catch (error) { if (error.message !== "expired") ask({title: "It was not removed", body: error.message, cancel: "Close"}); }
}

// MARK: activity
const TABS = [["", "All"], ["power", "Power"], ["files", "Files"], ["devices", "Devices"], ["screen", "Screen"], ["input", "Input"],
  ["audio", "Audio"], ["apps", "Apps"], ["settings", "Settings"]];
async function showActivity(category = "") {
  render(view, h`<div class="title-row"><div><h1>Activity</h1><p class="lede">What paired devices did on this PC, newest first. Kept for 90 days.</p></div></div>
    <div class="tabs" role="tablist" aria-label="Kind of activity">${TABS.map(([key, label]) => h`<button role="tab" aria-selected="${key === category}" data-category="${key}">${label}</button>`)}</div>
    <div id="activity-list"><span class="skeleton"></span></div><div class="more" id="more"></div>`);
  view.querySelectorAll("[data-category]").forEach((tab) => tab.addEventListener("click", () => showActivity(tab.dataset.category)));
  const rows = [];
  const node = document.getElementById("activity-list");
  const page = async (before) => {
    let data;
    try { data = await api(`/local/api/activity?limit=50${before ? `&before=${before}` : ""}${category ? `&category=${category}` : ""}`); }
    catch (error) { if (error.message !== "expired") failure(node, `Couldn't load the activity. ${error.message}`, () => showActivity(category)); return; }
    rows.push(...data.entries);
    if (!rows.length) {
      render(node, h`<div class="empty">${category ? "Nothing of this kind yet." : "Nothing yet. When a device locks the PC, sends a file or changes a setting, it shows here."}</div>`);
    } else {
      render(node, h`<table class="rows"><thead><tr><th>What happened</th><th>Device</th><th>When</th><th>Result</th></tr></thead><tbody>
        ${rows.map((entry) => h`<tr><td>${entry.summary}</td><td class="secondary nowrap muted">${entry.deviceName || "This PC"}</td>
          <td class="secondary nowrap muted">${when(entry.at)}</td><td>${entry.result === "ok" ? "" :
          h`<span class="pill ${entry.result === "denied" ? "warning" : "problem"}">${entry.result === "denied" ? "Not allowed" : "Failed"}</span>`}</td></tr>`)}</tbody></table>`);
    }
    const more = document.getElementById("more");
    render(more, data.nextBefore ? h`<button class="button" id="load-more">Show older</button>` : h``);
    if (data.nextBefore) document.getElementById("load-more").addEventListener("click", () => page(data.nextBefore));
  };
  await page(null);
}

// MARK: settings
const NOTIFICATIONS = [
  ["newDevice", "A new device pairs", "iPhone can now use this PC. If this was not you, remove it in Orbit.", "Orbit · New device"],
  ["power", "Power actions and timers", "The PC will go to sleep in 1 minute (requested from iPhone). Cancel it in Orbit.", "Orbit · Power"],
  ["files", "Files sent or downloaded", "iPhone: Uploaded IMG_4021.HEIC (3.1 MB) to Downloads", "Orbit · Files"],
  ["screenView", "Someone views the screen", "iPhone is viewing your screen.", "Orbit · Screen"],
  ["inputSession", "Someone takes the mouse and keyboard", "iPhone is controlling the mouse and keyboard.", "Orbit · Remote input"],
  ["quietWhileGaming", "Quiet while a game runs", "Files, screen and input stay silent during a game. New devices and power actions still show."],
];
async function showSettings() {
  render(view, h`<div class="title-row"><div><h1>Settings</h1><p class="lede">Every change is saved as you make it.</p></div></div>
    <div id="settings"><span class="skeleton"></span></div>`);
  let data;
  try { data = await api("/local/api/settings"); }
  catch (error) { if (error.message !== "expired") failure(document.getElementById("settings"), `Couldn't load the settings. ${error.message}`, showSettings); return; }
  drawSettings(data);
}
function drawSettings(data) {
  const node = document.getElementById("settings");
  const first = NOTIFICATIONS.find(([key]) => key !== "quietWhileGaming" && data.notifications[key]);
  const managed = new Set(data.monitoring.managedByEnvironment || []);
  const field = (key, label, hint, value, area) => h`<div class="field"><label for="m-${key}">${label}</label>
    ${area ? h`<textarea class="input" id="m-${key}" data-monitor="${key}" ${managed.has(key) ? "disabled" : ""}>${value}</textarea>`
           : h`<input class="input" id="m-${key}" data-monitor="${key}" value="${value}" ${managed.has(key) ? "disabled" : ""}>`}
    <span class="hint">${managed.has(key) ? "Set by a Windows environment variable; change it there." : hint}</span></div>`;
  render(node, h`
    <section class="settings-section"><div class="settings-label"><h2>Starting Orbit <span class="saved" id="saved-start">Saved</span></h2>
      <p>Orbit runs in the tray. Started before sign-in, your devices can reach the PC right after it turns on.</p></div>
      <div class="panel">
        <div class="switch-row"><div class="text"><div class="title">Start with Windows</div><div class="desc">When you sign in to Windows.</div></div>
          <button class="switch" role="switch" id="run-at-startup" aria-checked="${data.runAtStartup}" aria-label="Start with Windows"></button></div>
        <div class="switch-row"><div class="text"><div class="title">Start before anyone signs in</div>
          <div class="desc">${data.bootTaskAvailable ? "Windows asks for permission to change this." : "Available in the Windows app only."}</div></div>
          <button class="switch" role="switch" id="boot-task" aria-checked="${data.startBeforeSignIn}" aria-label="Start before anyone signs in" ${data.bootTaskAvailable ? "" : "disabled"}></button></div>
      </div></section>
    <section class="settings-section"><div class="settings-label"><h2>Notifications <span class="saved" id="saved-notifications">Saved</span></h2>
      <p>Shown on this PC when your devices act on it. Orbit records everything in Activity either way.</p>
      ${first ? h`<div class="toast" aria-hidden="true"><div class="toast-head">${raw(LOGO)}Orbit PC Companion · now</div>
        <div class="toast-title">${first[3]}</div><div class="toast-body">${first[2]}</div></div>` : ""}</div>
      <div class="panel">${NOTIFICATIONS.map(([key, title, example]) => h`<div class="switch-row"><div class="text"><div class="title">${title}</div>
        ${key === "quietWhileGaming" ? h`<div class="desc">${example}</div>` : ""}</div>
        <button class="switch" role="switch" data-notification="${key}" aria-checked="${data.notifications[key]}" aria-label="${title}"></button></div>`)}</div></section>
    <section class="settings-section"><div class="settings-label"><h2>Monitoring <span class="saved" id="saved-monitoring">Saved</span></h2>
      <p>Where Orbit finds games, frame rates and sensors. Leave a field empty for the automatic choice.</p></div>
      <div class="panel">
        ${field("gameProcesses", "Extra games", "One executable per line, such as eldenring.exe. Steam, Epic and GOG games are found by themselves.", (data.monitoring.gameProcesses || []).join("\n"), true)}
        ${field("networkInterface", "Network adapter for traffic", "The name Windows shows, such as Ethernet.", data.monitoring.networkInterface || "")}
        ${field("presentMonCSV", "PresentMon capture", "Full path of the CSV PresentMon writes, such as C:\\Orbit\\presentmon.csv.", data.monitoring.presentMonCSV || "")}
        ${field("libreHardwareMonitorURL", "LibreHardwareMonitor", "Its local web server, such as http://127.0.0.1:8085/data.json.", data.monitoring.libreHardwareMonitorURL || "")}
        <div class="error-text" id="monitoring-error"></div>
      </div></section>
    <section class="settings-section"><div class="settings-label"><h2>Updates <span class="saved" id="saved-updates">Saved</span></h2>
      <p>Orbit PC Companion ${data.updates.version}. Updates come from Orbit's public GitHub repository.</p></div>
      <div class="panel">
        <div class="switch-row"><div class="text"><div class="title">Check once a day</div><div class="desc">Shows a notification when a new version is out. Nothing installs by itself.</div></div>
          <button class="switch" role="switch" id="check-updates" aria-checked="${data.updates.checkAutomatically}" aria-label="Check once a day"></button></div>
        <div class="update-line" id="update-line"><div class="text muted">${data.updates.frozen ? "This standalone app updates by downloading the new OrbitCompanion.exe." : "Check now to see if a newer version is available."}</div>
          <button class="button" id="check-now">Check now</button></div>
      </div></section>`);
  const patch = async (body, stamp) => {
    try { await api("/local/api/settings", {method: "PATCH", body}); flashSaved(stamp); return true; }
    catch (error) { if (error.message !== "expired") ask({title: "Not saved", body: error.message, cancel: "Close"}); return false; }
  };
  const toggle = (button, change) => button.addEventListener("click", async () => {
    const next = button.getAttribute("aria-checked") !== "true";
    button.setAttribute("aria-checked", String(next));
    if (!(await change(next))) button.setAttribute("aria-checked", String(!next));
  });
  toggle(document.getElementById("run-at-startup"), (value) => patch({runAtStartup: value}, "saved-start"));
  toggle(document.getElementById("check-updates"), (value) => patch({updates: {checkAutomatically: value}}, "saved-updates"));
  toggle(document.getElementById("boot-task"), async (value) => {
    try { await api("/local/api/settings/boot-task", {method: "POST", body: {enabled: value}}); flashSaved("saved-start"); return true; }
    catch (error) { if (error.message !== "expired") ask({title: "Windows did not change it", body: error.message, cancel: "Close"}); return false; }
  });
  node.querySelectorAll("[data-notification]").forEach((button) => toggle(button, (value) => patch({notifications: {[button.dataset.notification]: value}}, "saved-notifications")));
  node.querySelectorAll("[data-monitor]").forEach((input) => input.addEventListener("change", async () => {
    const key = input.dataset.monitor;
    const value = key === "gameProcesses" ? input.value.split(/\n|;/).map((item) => item.trim()).filter(Boolean) : input.value.trim();
    try { await api("/local/api/settings", {method: "PATCH", body: {monitoring: {[key]: value}}}); document.getElementById("monitoring-error").textContent = ""; flashSaved("saved-monitoring"); }
    catch (error) { document.getElementById("monitoring-error").textContent = error.message; }
  }));
  document.getElementById("check-now").addEventListener("click", () => checkForUpdates(data));
}
async function checkForUpdates(data) {
  const line = document.getElementById("update-line");
  render(line, h`<div class="text muted">Checking GitHub…</div><button class="button" disabled>Check now</button>`);
  let result;
  try { result = await api("/local/api/updates/check", {method: "POST", body: {}}); }
  catch (error) {
    if (error.message === "expired") return;
    render(line, h`<div class="text"><span class="error-text">${error.message}</span></div><button class="button" id="check-now">Try again</button>`);
    document.getElementById("check-now").addEventListener("click", () => checkForUpdates(data));
    return;
  }
  if (!result.updateAvailable) {
    render(line, h`<div class="text muted">${result.currentVersion} is the latest version.</div><button class="button" id="check-now">Check now</button>`);
    document.getElementById("check-now").addEventListener("click", () => checkForUpdates(data));
    return;
  }
  render(line, h`<div class="text"><div class="title">Orbit PC Companion ${result.latestVersion} is available</div>
    <div class="desc">${data.updates.frozen ? "Download the new OrbitCompanion.exe from the release page." : "Orbit keeps your devices, settings and history."}</div></div>
    ${data.updates.frozen ? h`<a class="button" href="${result.releaseUrl}" target="_blank" rel="noopener">Release page</a>` : h`<button class="button primary" id="install">Install</button>`}`);
  const install = document.getElementById("install");
  if (install) install.addEventListener("click", async () => {
    install.disabled = true; install.textContent = "Installing…";
    try {
      const done = await api("/local/api/updates/install", {method: "POST", body: {}});
      render(line, h`<div class="text"><div class="title">Installed ${done.latestVersion}</div><div class="desc">${done.dependencies === "failed" ? "Run install_orbit.bat once to finish the new dependencies. " : ""}Restart Orbit to use it.</div></div>
        <button class="button primary" id="restart">Restart Orbit</button>`);
      document.getElementById("restart").addEventListener("click", async () => {
        try { await api("/local/api/restart", {method: "POST", body: {}}); } catch (error) { /* the window closes with Orbit */ }
        render(view, h`<section class="signed-out"><h1>Orbit is restarting</h1><p>Open it again from the tray icon in a few seconds.</p></section>`);
      });
    } catch (error) {
      install.disabled = false; install.textContent = "Install";
      ask({title: "The update was not installed", body: error.message, cancel: "Close"});
    }
  });
}

// MARK: diagnostics
async function showDiagnostics() {
  render(view, h`<div class="title-row"><div><h1>Diagnostics</h1><p class="lede" id="diag-lede"><span class="skeleton"></span></p></div>
    <div class="actions"><button class="button" id="check-again">Check again</button></div></div>
    <section class="section"><div class="section-head"><h2>Connection</h2><span class="meta" id="checked"></span></div>
      <ol class="path" id="path">${stations(null)}</ol><div class="verdict" id="verdict"></div></section>
    <div id="diag-details"></div>`);
  let overview = null;
  try { overview = await api("/local/api/overview"); } catch (error) { /* the path still works without device counts */ }
  const load = async (force) => {
    let report;
    try { report = await api(`/local/api/diagnostics${force ? "?force=1" : ""}`); }
    catch (error) { if (error.message !== "expired") failure(document.getElementById("diag-details"), `Couldn't check this PC. ${error.message}`, () => load(true)); return; }
    if (currentView !== "diagnostics") return;
    const tone = report.verdict.state;
    render(document.getElementById("diag-lede"), h`<span class="dot ${tone === "ok" ? "ok" : tone === "unknown" ? "" : tone}"></span><strong>${report.verdict.title}</strong>`);
    render(document.getElementById("checked"), h`Checked ${clock.format(parse(report.checkedAt) || new Date())}`);
    render(document.getElementById("path"), stations(report, overview));
    const verdict = document.getElementById("verdict");
    render(verdict, h`<p>${report.verdict.detail}</p><div class="actions">${fixButtons(report)}</div>`);
    bindFixes(verdict, load);
    const rules = (report.firewall && report.firewall.rules) || [];
    const sunshine = report.sunshine;
    render(document.getElementById("diag-details"), h`
      <section class="section"><div class="section-head"><h2>Networks</h2><span class="meta">Windows lets devices find this PC only on Private networks</span></div>
        <div class="card">${report.profiles && report.profiles.length ? h`<table class="rows"><thead><tr><th>Network</th><th>Adapter</th><th>Type</th></tr></thead><tbody>
          ${report.profiles.map((profile) => { const used = report.network && report.network.interfaceIndex === profile.interfaceIndex;
            return h`<tr><td><div class="name">${profile.name}</div>${used ? h`<div class="sub">Orbit listens here</div>` : ""}</td>
            <td class="secondary muted">${profile.interface}</td>
            <td><span class="pill ${used ? (profile.category === "Public" ? "warning" : "ok") : ""}">${profile.category === "DomainAuthenticated" ? "Work" : profile.category}</span></td></tr>`; })}
          </tbody></table>` : h`<div class="empty">${report.reason || "Windows reported no network."}</div>`}</div></section>
      <section class="section"><div class="section-head"><h2>Windows Firewall</h2><span class="meta">Inbound, your local network only</span></div>
        <div class="card"><table class="rows"><thead><tr><th>Rule</th><th>Port</th><th>State</th></tr></thead><tbody>
          ${rules.map((rule) => h`<tr><td><div class="name">${rule.purpose}</div>${rule.required ? "" : h`<div class="sub">Optional</div>`}</td>
            <td class="secondary muted nowrap">${rule.protocol} ${rule.port}</td>
            <td>${rule.working ? h`<span class="pill ok">Allowed · ${rule.profiles.join(", ")}</span>` : h`<span class="pill ${rule.required ? "problem" : ""}">${rule.present ? "Turned off" : "Missing"}</span>`}</td></tr>`)}
          </tbody></table>${rules.length ? "" : h`<div class="empty">${report.reason || "The firewall could not be read."}</div>`}</div></section>
      <section class="section"><div class="section-head"><h2>Orbit</h2></div><div class="card"><dl class="kv">
        <dt>Address</dt><dd>${report.companion.address || "—"}</dd>
        <dt>Encrypted connection</dt><dd>HTTPS ${report.companion.securePort}</dd>
        ${overview ? h`<dt>Version</dt><dd>${overview.pc.version}</dd><dt>Certificate SHA-256</dt><dd class="mono">${overview.pc.fingerprint || "—"}</dd>` : ""}
      </dl></div></section>
      <section class="section"><div class="section-head"><h2>Sunshine</h2><span class="meta">Game streaming</span></div><div class="card">
        ${sunshine ? h`<dl class="kv"><dt>Installed</dt><dd>${sunshine.installed ? "Yes" : "No"}</dd>
          <dt>Running</dt><dd>${sunshine.running ? h`<span class="live-text"><span class="dot ok"></span>Running</span>` : "Not running"}</dd>
          <dt>Ports</dt><dd>HTTPS ${sunshine.httpsPort} · Web UI ${sunshine.webUIPort}</dd>
          <dt>Pairing PIN</dt><dd>${sunshine.canSubmitPin ? "Orbit types it for you (login saved)" : "Typed by hand in Sunshine's web UI"}</dd></dl>`
          : h`<div class="empty">Sunshine's status is not available.</div>`}</div></section>`);
  };
  document.getElementById("check-again").addEventListener("click", () => load(true));
  await load(false);
}

// MARK: router
const VIEWS = {overview: showOverview, devices: showDevices, activity: () => showActivity(""), settings: showSettings, diagnostics: showDiagnostics};
const TITLES = {overview: "Orbit", devices: "Devices · Orbit", activity: "Activity · Orbit", settings: "Settings · Orbit", diagnostics: "Diagnostics · Orbit"};
function route() {
  const name = (location.hash.replace(/^#\/?/, "") || "overview").split(/[/?]/)[0];
  const next = VIEWS[name] ? name : "overview";
  stopTimers();
  currentView = next;
  setCurrent(next);
  document.title = TITLES[next];
  window.scrollTo(0, 0);
  const pending = VIEWS[next]();
  // A short cross-fade into the new view; time-based, so it also completes in a background window.
  if (!matchMedia("(prefers-reduced-motion: reduce)").matches && view.animate) {
    view.animate([{opacity: 0}, {opacity: 1}], {duration: 160, easing: "cubic-bezier(.2, .8, .2, 1)"});
  }
  pending.catch((error) => { if (error.message !== "expired") failure(view, error.message, route); });
}
if (SIGNED_IN) {
  window.addEventListener("hashchange", route);
  route();
  api("/local/api/overview").then((data) => { document.getElementById("scope").textContent = data.pc.name; }).catch(() => {});
} else {
  expired();
  render(view, h`<section class="signed-out"><h1>Open Orbit from the tray</h1>
    <p>For your privacy this window opens only from Orbit's icon in the Windows tray, at the bottom right of the screen. Click the icon to open it.</p></section>`);
}
</script>
</body>
</html>
"""


def render_page(nonce, signed_in=True):
    from urllib.parse import quote
    return (PAGE.replace("{{NONCE}}", nonce)
            .replace("{{SIGNED_IN}}", "true" if signed_in else "false")
            .replace("{{LOGO}}", logo_svg(title="Orbit"))
            .replace("{{LOGO_SMALL}}", logo_svg(title=""))
            .replace("{{FAVICON}}", quote(logo_svg(title="Orbit"))))
