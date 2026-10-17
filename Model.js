// ric.dd8c — pure display/state helpers for the Dutch & Dutch 8C bar widget.
//
// All functions are pure: they take the parsed daemon snapshot JSON (or
// primitives) and return display strings/glyphs/options, so they can be
// unit-tested outside Qt (tests/test_model.js with node).

// Nerd Font glyphs (same set verified for JetBrainsMono Nerd Font).
var ICON = {
  speaker: "\u{F04C3}",   // 󰓃
  volumeHigh: "\u{F057E}",// 󰕾
  volumeLow: "\u{F057F}", // 󰕿
  volumeMute: "\u{F075F}",// 󰝟
  sleep: "\u{F04AA}",     // 󰒪
  power: "\u{F0425}",     // 󰐥
  sliders: "\u{F0497}",   // 󰒗
  refresh: "\u{F0453}",   // 󰑓
  wifi: "\u{F05A9}",      // 󰖩
  moon: "\u{F0C5C}",      // 󰌾 nightmode
  wave: "\u{F0470}",      // 󰑰 linear phase-ish
  aes: "\u{F0CE6}",       // 󰳦 digital input
  analog: "\u{F04CC}",    // 󰓌 analog input
  file: "\u{F02B7}",      // 󰊓 file player
  link: "\u{F0C3F}",      // 󰃿 AES streamer
  lock: "\u{F0237}",      // 󰌵
  chevronRight: "\u{F0142}"
}

// input mode -> label + icon (matches room-doc inputModes / selectedInput)
var INPUT_INFO = {
  analogHighGain: { label: "Analog hi", icon: ICON.analog },
  analogLowGain: { label: "Analog lo", icon: ICON.analog },
  aes: { label: "AES/EBU", icon: ICON.aes },
  "AES Streamer": { label: "AES Stream", icon: ICON.link },
  "File Player": { label: "Files", icon: ICON.file }
}

var SOURCE_ORDER = ["analogHighGain", "analogLowGain", "aes",
                    "AES Streamer", "File Player"]

function inputMode(snap) {
  if (!snap) return ""
  if (snap.selectedInput === "XLR") return snap.selectedXLR || ""
  return snap.selectedInput || ""
}

function inputLabel(snap) {
  var m = inputMode(snap)
  return (INPUT_INFO[m] || {}).label || m || "—"
}

function inputIcon(snap) {
  var m = inputMode(snap)
  return (INPUT_INFO[m] || {}).icon || ICON.speaker
}

// chip state: offline | standby | muted | ready
function chipState(snap, daemonReady) {
  if (!snap || !snap.online) return daemonReady ? "idle" : "offline"
  if (snap.sleep) return "standby"
  if (snap.mute) return "muted"
  return "ready"
}

function heroTitle(snap) {
  if (!snap || !snap.online) return "Dutch & Dutch 8C"
  return snap.room || "8C"
}

function heroMeta(snap) {
  if (!snap || !snap.online) return "offline"
  var bits = ["fw " + (snap.version || "?"), inputLabel(snap)]
  var g = snap.gain ? snap.gain.global : null
  if (g !== null) bits.push(fmtDb(g))
  if (snap.streamService) bits.push(snap.streamService)
  return bits.join("  ·  ")
}

function barLabel(snap) {
  if (!snap || !snap.online) return ""
  if (snap.sleep) return "standby"
  var g = snap.gain ? snap.gain.global : null
  if (g === null) return ""
  return fmtDb(g)
}

function fmtDb(v) {
  v = Number(v)
  if (isNaN(v)) return "—"
  var r = Math.round(v * 10) / 10
  return (r > 0 ? "+" : "") + (Number.isInteger(r) ? r.toFixed(0) : r.toFixed(1)) + " dB"
}

function volIcon(snap) {
  if (!snap || snap.mute) return ICON.volumeMute
  var g = snap.gain ? Number(snap.gain.global) : -20
  return g > -30 ? ICON.volumeHigh : ICON.volumeLow
}

function tooltipText(snap) {
  if (!snap || !snap.online) return "8C: offline"
  var bits = [snap.room || "8C", inputLabel(snap), fmtDb(snap.gain.global)]
  if (snap.mute) bits.push("muted")
  if (snap.sleep) bits.push("standby")
  return bits.join(" · ")
}

// Gain limits from the room doc; fall back to documented defaults.
function limits(snap) {
  var l = (snap && snap.gain && snap.gain.limits) || {}
  return {
    min: l.min !== undefined ? Number(l.min) : -70,
    max: l.max !== undefined ? Number(l.max) : 6,
    step: l.step !== undefined ? Number(l.step) : 0.1
  }
}

function clampDb(v, snap) {
  var l = limits(snap)
  v = Number(v)
  if (isNaN(v)) v = l.min
  return Math.max(l.min, Math.min(l.max, Math.round(v * 10) / 10))
}

// ButtonGroup options for the 5 input modes
function sourceOptions() {
  return SOURCE_ORDER.map(function (m) {
    return { value: m, label: INPUT_INFO[m].label }
  })
}

// ButtonGroup options from {id: name} maps
function namedOptions(map) {
  var opts = []
  for (var id in (map || {})) opts.push({ value: id, label: map[id] })
  return opts
}

function nameOf(map, id) {
  return (map && map[id]) || "—"
}

function licenseText(lic) {
  if (!lic) return "—"
  var parts = []
  if (lic.audio) parts.push("audio")
  if (lic.streaming) parts.push("streaming")
  if (lic.bacch) parts.push("BACCH")
  if (lic.dev) parts.push("dev")
  return parts.length ? parts.join(" + ") : "none"
}

function positionText(positions) {
  var n = Object.keys(positions || {}).length
  return n ? n + (n === 1 ? " speaker" : " speakers") : "—"
}

// Tone sliders: app dropdown is QS(-12, 6, 0.5)
function clampTone(v) {
  v = Number(v)
  if (isNaN(v)) v = 0
  return Math.max(-12, Math.min(6, Math.round(v * 2) / 2))
}

// Parse one daemon stdout line; returns null on junk.
function parseLine(text) {
  try {
    var obj = JSON.parse(String(text))
    return obj && typeof obj === "object" ? obj : null
  } catch (e) {
    return null
  }
}

// ---------------------------------------------------------------------------
// Fixture snapshot: mirrors the real daemon contract exactly (the real
// daemon's --fixture mode is the data source; this mirrors it for QML-side
// fixture mode and unit tests).
// ---------------------------------------------------------------------------

function fixtureSnapshot() {
  return {
    online: true,
    ts: new Date().toISOString(),
    masterIp: "192.168.1.50",
    room: "Living Room Zone (fixture)",
    roomId: "fixture-room",
    version: "2.6.43",
    selectedInput: "XLR",
    selectedXLR: "aes",
    inputModes: SOURCE_ORDER.slice(),
    inputLevel: -42.5,
    gain: { global: -27.5, activeCorrection: -10,
            limits: { min: -70, max: 6, step: 0.1 } },
    mute: false,
    sleep: false,
    nightmode: false,
    frontled: true,
    linearPhase: true,
    selectedProfile: "default",
    lastSelectedPreset: "p-flat",
    presets: { "p-flat": "Flat", "p-night": "Night", "p-warm": "Warm" },
    profiles: { "default": "Default", "p-rew": "REW Auto" },
    tone: { sub: 0, bass: 0, treble: 0 },
    licenses: { audio: true, streaming: false, bacch: false },
    streaming: false,
    streamService: null,
    streamDisplay: null,
    positions: { "pos-l": "left", "pos-r": "right" }
  }
}
