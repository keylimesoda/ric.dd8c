# ric.dd8c — design record

Omarchy-native Dutch & Dutch 8c/6c controller: a Quattro bar-widget plugin
with a keyboard-driven control panel, backed by a stdlib-only Python
CLI/daemon speaking the reverse-engineered local "Ascend" mesh API.

## Decisions (settled with the user, 2026-10-16)

- Target: user's 8c pair "Play Room" (master 192.168.183.48 pinned as
  default; `masterIp: ""` enables mDNS discovery of `_x-clerk._tcp`).
- House pattern: follows `ric.wiim` / `ric.daikin` exactly — `bar-widget`
  kind, `Panel`-derived `BarWidget.qml`, bundled `bin/` CLI, `Model.js`
  pure helpers, fixture mode, tests.
- **Safety contract (user requirement: "don't break my speakers"):**
  the CLI never sends firmware verbs (`install rms-releases`,
  `rms-factory-reset`, `setup-complete`, profile/preset delete). Gain
  writes are clamped to the room document's advertised limits. Only
  endpoints verified against the live device or the official web-app
  bundle are exposed.
- No license bypass: streaming sources (Roon/Spotify) are gated by the
  vendor cloud license; the widget controls only what the unlicensed
  firmware already allows (gain, mute, standby, inputs, presets,
  profiles, tone, front LED).

## Prior art (surveyed)

- No existing Omarchy/Quickshell plugin for D&D speakers (marketplace +
  public search, 2026-10-16). Closest: `joseluis.media` (MPRIS), built-in
  audio panel (PipeWire) — neither speaks the Ascend mesh.
- `dannyfiresnake/dutchdutch-ascend` (Rust) and `trevorwarwick/dutchdutch`
  (HA integration): protocol prior art; this plugin's protocol layer was
  derived independently by live RE (see ~/Work/dd8c-re/FINDINGS.md).
- `ric.wiim`: the structural template (daemon stdio contract, cursor
  model, fixture mode, test layout).

## Surface & kinds

- Plugin id `ric.dd8c`, kinds: `bar-widget` (single entry point
  `BarWidget.qml` deriving from `qs.Ui.Panel`).
- Bar widget is persistent → state + daemon live in the widget instance;
  `IpcHandler` target `ric.dd8c` works while the popout is closed.
  Single monitor, single room: no separate `service` kind (house style).

## State ownership

- Widget instance owns: live snapshot, daemon process, cursor/open state.
- `bin/dd8c daemon` owns: WS connection to the master, `subscribe network`
  push handling (debounced re-read), command execution, master election,
  mDNS discovery.
- Durable config: widget settings in `shell.json` layout entry
  (`masterIp`, `volStepDb`, `barText`, `fixture`).

## External surface (named explicitly)

- `bin/dd8c` — Python 3 stdlib only (no pip deps). Outbound:
  - mDNS query to 224.0.0.251:5353 (PTR `_x-clerk._tcp.local`).
  - `ws://<master>:8768` JSON-RPC (LAN, no auth by vendor design, no
    credentials involved).
- No cloud contact. No firmware endpoints.

## IPC contract (target `ric.dd8c`)

open/close/show/hide/toggle, volSet(v)/volStep(d), mute(on|off|"toggle"),
sleep(same), input(mode), preset(name|id), profile(name|id), refresh,
dumpState.

## Failure states

offline (no master / WS down → chip dim, daemon backoff 1→30 s),
error (command rejected by device → error line + auto-resync),
fixture (synthetic state). Room-read "Network is not locked" resolves on
retry via the daemon reconnect loop.

## Verification

- `tests/run`: manifest validator + `omarchy plugin validate` +
  `tests/test_cli.py` (daemon end-to-end against `fixture_ws_server.py`,
  which also asserts firmware verbs are refused) + `tests/test_model.js`.
- Live: widget enabled in the user's bar against the real room; gain
  round-trip verified; state restored after every probe.

## Deferred

- Media-key routing (no licensed transport source to route yet).
- File Player library browsing (needs on-device file probing).
- Multi-room / 6c switcher; second-monitor service extraction.
- paramEQ / RoomMatching editing (write schemas exist but are riskier).
