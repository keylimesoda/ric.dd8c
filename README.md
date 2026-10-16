# Dutch & Dutch 8C

[![Built for Omarchy: Plugin](https://raw.githubusercontent.com/tcballard/omarchy-badges/75975e5b5bf75e7ede3764bcd2950046f7abfe2c/badges/v1/omarchy-plugin.svg)](https://github.com/tcballard/omarchy-badges)

Control your Dutch & Dutch 8c/6c room from the Omarchy bar: gain, mute,
standby, input select, presets, RoomMatching profiles, tone controls,
front LED, and live device status. No cloud, no vendor app — the bundled
CLI speaks the speakers' local mesh API directly.

Kinds: bar-widget

## GitHub topics

Pair this badge with `omarchy`, `omarchy-plugin`, and `dutch-and-dutch` in
your GitHub repository's About topics.

## Bar chip

- **Click** — open/close the control panel
- **Middle-click** — mute toggle
- **Scroll** — gain ±`volStepDb` (default 1 dB)
- The Dutch & Dutch monogram (from the vendor's favicon, trademark D&D) plus
  the current gain; dim = offline, faint = standby.

## Panel (keyboard-first)

- `Tab` / `j` `k` — sections · `h` `l` — adjust within section
- `Enter` — activate focused control · `Space` — mute
- `m` mute · `s` standby · `f` front LED · `i` cycle input · `1`–`5` pick
  input · `+`/`-` volume · `r` refresh

Sections: Volume (slider spans the room's advertised limits), Standby /
Front LED, Input (Analog hi/lo, AES/EBU, AES Streamer, File Player),
Presets, Profiles (RoomMatching), Tone (sub/bass/treble, −12…+6 dB),
Device (master, firmware, phase/night mode, input level, licenses).

## Summon without the bar

```
omarchy-shell shell toggle ric.dd8c   # bind to a key if you like
```

IPC for scripts:

```
quickshell ipc -t ric.dd8c volSet -22
quickshell ipc -t ric.dd8c mute on
quickshell ipc -t ric.dd8c input aes
```

## CLI (same engine the widget uses)

```
bin/dd8c discover                 # find speakers via mDNS
bin/dd8c status                   # full room snapshot (JSON)
bin/dd8c vol -27                  # absolute dB (clamped to device limits)
bin/dd8c mute on|off
bin/dd8c sleep on|off
bin/dd8c input aes|analogHighGain|analogLowGain|AES\ Streamer|File\ Player
bin/dd8c preset Flat
bin/dd8c profile "REW Auto"
bin/dd8c tone --bass 2 --treble -1
```

## Settings (shell.json layout entry)

| key | default | meaning |
|---|---|---|
| `masterIp` | `192.168.183.48` | master speaker; `""` = mDNS discovery |
| `volStepDb` | `1` | scroll/arrow gain step |
| `barText` | `true` | show gain readout |
| `fixture` | `false` | demo data, no device |

## Safety

The daemon never sends firmware install/reset verbs and clamps gain to
the limits the room document advertises. It only writes endpoints that
the vendor's own web app uses for these controls.

## Requirements

- Omarchy 4 with Quattro shell-plugin support.
- Python 3 (stdlib only; no pip dependencies).
- Speakers on the same LAN, reachable at `ws://<master>:8768`.

## Installation

```bash
omarchy plugin add "$(pwd)" --enable
```

## Tests

```
./tests/run
```

Runs manifest validation, the daemon end-to-end against a fixture
WebSocket server (no speakers needed), and Model.js unit tests.
