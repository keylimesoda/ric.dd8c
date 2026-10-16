// Unit tests for Model.js (pure helpers) — run with node.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

// Model.js is a plain QML-importable JS module (var/function declarations):
// evaluate it in a sandbox to get its namespace.
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8");
const ctx = vm.createContext({ Date, Number, Math, JSON, Object, String, Array });
vm.runInContext(src + "\nthis.M = {ICON, inputMode, inputLabel, inputIcon, " +
  "chipState, heroTitle, heroMeta, barLabel, fmtDb, volIcon, tooltipText, " +
  "limits, clampDb, sourceOptions, namedOptions, nameOf, licenseText, " +
  "positionText, clampTone, parseLine, fixtureSnapshot};", ctx);
const M = ctx.M;

// input mode resolution
const snap = M.fixtureSnapshot();
assert.strictEqual(M.inputMode(snap), "aes");
assert.strictEqual(M.inputLabel(snap), "AES/EBU");
const s2 = { ...snap, selectedInput: "File Player", selectedXLR: null };
assert.strictEqual(M.inputMode(s2), "File Player");
assert.strictEqual(M.inputLabel(s2), "Files");

// chip states
assert.strictEqual(M.chipState(null, false), "offline");
assert.strictEqual(M.chipState(null, true), "idle");
assert.strictEqual(M.chipState({ ...snap, sleep: true }, true), "standby");
assert.strictEqual(M.chipState({ ...snap, mute: true }, true), "muted");
assert.strictEqual(M.chipState(snap, true), "ready");

// dB formatting + clamping
assert.strictEqual(M.fmtDb(-27.5), "-27.5 dB");
assert.strictEqual(M.fmtDb(-30), "-30 dB");
assert.strictEqual(M.fmtDb(2), "+2 dB");
assert.strictEqual(M.clampDb(99, snap), 6);
assert.strictEqual(M.clampDb(-999, snap), -70);
assert.strictEqual(M.clampDb(-27.44, snap), -27.4);
// limits come from the snapshot; unknown snapshot -> documented defaults
// (deepEqual, not deepStrictEqual: vm-sandbox objects have foreign prototypes)
assert.deepEqual(M.limits(null), { min: -70, max: 6, step: 0.1 });

// tone clamp: app dropdown is -12..+6 in 0.5 steps
assert.strictEqual(M.clampTone(99), 6);
assert.strictEqual(M.clampTone(-99), -12);
assert.strictEqual(M.clampTone(1.3), 1.5);

// options builders
assert.strictEqual(M.sourceOptions().length, 5);
assert.strictEqual(M.sourceOptions()[2].label, "AES/EBU");
assert.deepEqual(M.namedOptions({ a: "Flat", b: "Night" }),
  [{ value: "a", label: "Flat" }, { value: "b", label: "Night" }]);
assert.strictEqual(M.nameOf({ a: "Flat" }, "a"), "Flat");
assert.strictEqual(M.nameOf({}, "a"), "—");

// license + position text
assert.strictEqual(M.licenseText({ audio: true, streaming: false }), "audio");
assert.strictEqual(M.licenseText({ audio: true, streaming: true, bacch: true }),
  "audio + streaming + BACCH");
assert.strictEqual(M.licenseText({}), "none");
assert.strictEqual(M.positionText({ l: "left", r: "right" }), "2 speakers");

// daemon line parsing
assert.deepStrictEqual(M.parseLine('{"a":1}'), { a: 1 });
assert.strictEqual(M.parseLine("junk"), null);
assert.strictEqual(M.parseLine("null"), null);

// fixture snapshot mirrors the real daemon contract keys
const required = ["online", "room", "version", "selectedInput", "selectedXLR",
  "inputModes", "gain", "mute", "sleep", "linearPhase", "selectedProfile",
  "lastSelectedPreset", "presets", "profiles", "tone", "licenses", "positions"];
for (const k of required) assert.ok(k in snap, "fixture missing " + k);

console.log("Model.js: all assertions passed");
