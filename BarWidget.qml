import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// ric.dd8c — Dutch & Dutch 8C control in the Omarchy bar.
//
// Bar chip: Dutch & Dutch monogram + gain readout. Click opens the control
// panel; middle-click toggles mute; scrolling over the chip nudges volume.
//
// Panel: keyboard-first (hjkl + Tab sections, direct keys), built on the
// house Panel/KeyboardPanel/PanelKeyCatcher pattern (see ric.wiim/ric.daikin).
// State streams from `bin/dd8c daemon` (subscribe + stdin commands);
// `fixture: true` renders the whole surface from fake data.
//
// Safety: the bundled CLI never sends firmware install/reset verbs and
// clamps gain to the limits advertised by the room document.
Panel {
  id: root
  moduleName: "ric.dd8c"
  ipcTarget: "ric.dd8c"
  manageIpc: false // own IpcHandler: expose control actions to the shell

  // ---- settings -----------------------------------------------------------
  readonly property string pluginDir: {
    if (manifest && manifest.__sourceDir) return String(manifest.__sourceDir)
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    return url.replace(/\/+$/, "")
  }
  readonly property string bin: pluginDir + "/bin/dd8c"
  readonly property string masterIp: String(setting("masterIp", ""))
  property real dragVol: 0
  // Local input authority: while the user drags the volume slider, device
  // state echoes must not overwrite the knob/readout (standard media-slider
  // pattern: local control wins until release, then remote state reconciles).
  property bool dragActive: false
  // Command authority for stepped volume (keys/wheel/IPC): the last value we
  // commanded wins over device echoes until the burst window closes.
  property real cmdVol: 0
  property bool cmdActive: false
  property int cmdBurst: 0
  readonly property real volStepDb: Math.max(0.1, Math.min(5, (Number(setting("volStepTenths", 1)) || 1) / 10))
  readonly property bool barText: setting("barText", true) !== false
  readonly property bool fixtureMode: setting("fixture", false) === true

  // ---- theme ---------------------------------------------------------------
  property var shell: null
  property var manifest: null
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string ff: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property bool vertical: root.bar ? root.bar.vertical : false
  readonly property real controlH: Style.spacing.controlHeight
  readonly property int barH: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal

  // ---- live state ----------------------------------------------------------
  property var snap: null
  property bool daemonReady: false
  property string lastError: ""
  property int cmdSeq: 0
  property int backoffMs: 1000

  // ---- cursor model ---------------------------------------------------------
  readonly property var sectionOrder: ["volume", "toggles", "source",
    "presets", "profiles", "tone", "device"]
  property string focusSection: "volume"
  property var secIdx: ({})
  property bool cursorActive: false
  property bool viaEnter: false

  function idx(sec) { return secIdx[sec] !== undefined ? secIdx[sec] : 0 }
  function setIdx(sec, v) { var m = {}; for (var k in secIdx) m[k] = secIdx[k];
    m[sec] = v; secIdx = m }

  function groupCount(sec) {
    if (!snap) return 0
    if (sec === "source") return Model.sourceOptions().length
    if (sec === "presets") return Object.keys(snap.presets || {}).length
    if (sec === "profiles") return Object.keys(snap.profiles || {}).length
    if (sec === "toggles") return 2
    return 0
  }

  function moveSection(dy) {
    var order = sectionOrder
    var i = order.indexOf(focusSection)
    var next = order[Math.max(0, Math.min(order.length - 1, i + dy))]
    if (next === focusSection) return
    focusSection = next
    if (idx(next) >= groupCount(next)) setIdx(next, 0)
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy !== 0) { moveSection(dy); return }
    switch (focusSection) {
      case "volume":
        if (idx("volume") === 0) setIdx("volume", 1)
        else volStepBy(dx * root.volStepDb)
        break
      case "toggles":
        setIdx("toggles", Math.max(0, Math.min(1, idx("toggles") + dx)))
        break
      case "source": case "presets": case "profiles": {
        var n = groupCount(focusSection)
        if (n) setIdx(focusSection, (idx(focusSection) + dx + n) % n)
        break
      }
      case "tone": {
        var f = ["sub", "bass", "treble"][Math.min(2, idx("tone"))]
        var cur = (snap && snap.tone) ? Number(snap.tone[f]) || 0 : 0
        toneSet(f, cur + dx * 0.5)
        break
      }
    }
  }

  function activateSection() {
    cursorActive = true
    switch (focusSection) {
      case "volume": muteToggle(); break
      case "toggles": {
        var i = idx("toggles")
        if (i === 0) sleepToggle(); else frontToggle()
        break
      }
      case "source": {
        var opts = Model.sourceOptions()
        if (opts.length) inputSet(opts[idx("source")].value)
        break
      }
      case "presets": {
        var po = Model.namedOptions(snap ? snap.presets : {})
        if (po.length) presetSet(po[idx("presets")].value)
        break
      }
      case "profiles": {
        var fo = Model.namedOptions(snap ? snap.profiles : {})
        if (fo.length) profileSet(fo[idx("profiles")].value)
        break
      }
      case "device": refresh(); break
    }
  }

  // ---- derived state --------------------------------------------------------
  readonly property bool online: snap !== null && snap.online === true
  readonly property real vol: online ? Number(snap.gain.global) : 0
  readonly property bool muted: online && snap.mute === true
  readonly property bool asleep: online && snap.sleep === true
  readonly property bool night: online && snap.nightmode === true
  readonly property bool linPhase: online && snap.linearPhase === true
  readonly property string inputMode: online ? Model.inputMode(snap) : ""
  readonly property var lim: Model.limits(snap)
  readonly property string chipState: Model.chipState(snap, daemonReady || fixtureMode)

  // ---- actions --------------------------------------------------------------
  function sendCmd(cmd, args) {
    if (fixtureMode) { fixtureApply(cmd, args || {}); return }
    if (!daemonProc.running) { lastError = "dd8c daemon not running"; return }
    cmdSeq += 1
    var req = { id: cmdSeq, cmd: cmd }
    if (args) req.args = args
    daemonProc.write(JSON.stringify(req) + "\n")
  }

  function patchSnap(part) {
    if (!snap) return
    var copy = JSON.parse(JSON.stringify(snap))
    for (var k in part) {
      if (typeof part[k] === "object" && part[k] !== null) {
        for (var j in part[k]) copy[k][j] = part[k][j]
      } else copy[k] = part[k]
    }
    snap = copy
  }

  function refresh() { sendCmd("status", {}) }

  function volSetTo(v) {
    v = Model.clampDb(v, snap)
    cmdVol = v
    patchSnap({ gain: { global: v }, mute: false })
    sendCmd("vol", { db: v })
  }
  // Stepped volume (keys, wheel, IPC). Two protections:
  //  * Command authority: consecutive steps chain from the last commanded
  //    value (cmdVol), not from lagging device echoes, so rapid stepping
  //    cannot bounce between stale snapshots. Writes are trailing-throttled
  //    (120 ms) so a burst coalesces; the final value always lands.
  //  * Acceleration: steps within a 400 ms burst escalate the multiplier
  //    (1x for the first 3, 2x up to 8, 5x beyond) so holding a key starts
  //    fine and speeds up, like a good audio client.
  function volStepBy(d) {
    cmdActive = true
    cmdBurst++
    volCmdIdleTimer.restart()
    var mult = cmdBurst <= 3 ? 1 : (cmdBurst <= 7 ? 2 : (cmdBurst <= 11 ? 5 : 2))
    var base = cmdActive ? cmdVol : vol
    var target = Model.clampDb(base + d * mult, snap)
    cmdVol = target
    patchSnap({ gain: { global: target }, mute: false })
    volCmdWriteTimer.restart()
  }
  Timer {
    id: volCmdWriteTimer
    interval: 120
    onTriggered: {
      root.patchSnap({ mute: false })
      root.sendCmd("vol", { db: root.cmdVol })
    }
  }
  Timer {
    id: volCmdIdleTimer
    interval: 400
    onTriggered: {
      root.cmdActive = false
      root.cmdBurst = 0
    }
  }
  function muteToggle() {
    var on = !muted
    patchSnap({ mute: on })
    sendCmd("mute", { on: on })
  }
  function sleepToggle() {
    var on = !asleep
    patchSnap({ sleep: on })
    sendCmd("sleep", { on: on })
  }
  function frontToggle() {
    var on = !(online && snap.frontled === true)
    patchSnap({ frontled: on })
    sendCmd("frontled", { on: on })
  }
  function inputSet(mode) {
    sendCmd("input", { mode: mode })
  }
  function inputCycle() {
    var opts = Model.sourceOptions()
    var i = 0
    for (var k = 0; k < opts.length; k++) if (opts[k].value === inputMode) i = k
    inputSet(opts[(i + 1) % opts.length].value)
  }
  function presetSet(id) {
    patchSnap({ lastSelectedPreset: id })
    sendCmd("preset", { name: id })
  }
  function profileSet(id) {
    patchSnap({ selectedProfile: id })
    sendCmd("profile", { name: id })
  }
  function toneSet(field, v) {
    v = Model.clampTone(v)
    var part = { tone: {} }
    part.tone[field] = v
    patchSnap(part)
    var args = {}
    args[field] = v
    sendCmd("tone", args)
  }

  // ---- daemon -----------------------------------------------------------------
  function handleLine(text) {
    var obj = Model.parseLine(text)
    if (!obj) return
    if (obj.event === "hello") {
      daemonReady = true
      backoffMs = 1000
      lastError = ""
    } else if (obj.event === "state") {
      if (obj.snapshot) {
        // Suppress gain echoes while dragging or mid step-burst; local
        // commands own the value until the interaction settles.
        if (obj.snapshot.gain) {
          if (root.dragActive) obj.snapshot.gain.global = root.dragVol
          else if (root.cmdActive) obj.snapshot.gain.global = root.cmdVol
        }
        snap = obj.snapshot; lastError = ""
      }
    } else if (obj.event === "offline") {
      lastError = obj.error || "offline"
      root.dragActive = false
    } else if (obj.ok === false && obj.error) {
      lastError = String(obj.error)
      refresh() // optimistic patch was wrong; resync
    }
  }

  Process {
    id: daemonProc
    command: root.masterIp
      ? [root.bin, "--ip", root.masterIp, "daemon"]
      : [root.bin, "daemon"]
    running: !root.fixtureMode
    stdinEnabled: true

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (data) { root.handleLine(data) }
    }
    stderr: StdioCollector { waitForEnd: true }

    onExited: {
      if (root.fixtureMode) return
      root.daemonReady = false
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: root.backoffMs
    onTriggered: {
      root.backoffMs = Math.min(30000, root.backoffMs * 2)
      if (!root.fixtureMode) daemonProc.running = true
    }
  }

  onMasterIpChanged: restartDaemon()
  function restartDaemon() {
    if (root.fixtureMode) return
    daemonProc.running = false
    Qt.callLater(function () { daemonProc.running = true })
  }

  // ---- fixture mode ---------------------------------------------------------
  function initFixture() {
    daemonReady = true
    snap = Model.fixtureSnapshot()
  }
  function fixtureApply(cmd, a) {
    if (!snap) initFixture()
    switch (cmd) {
      case "vol": patchSnap({ gain: { global: Model.clampDb(a.db, snap) }, mute: false }); break
      case "mute": patchSnap({ mute: a.on }); break
      case "sleep": patchSnap({ sleep: a.on }); break
      case "frontled": patchSnap({ frontled: a.on }); break
      case "input":
        if (a.mode === "analogHighGain" || a.mode === "analogLowGain" || a.mode === "aes")
          patchSnap({ selectedInput: "XLR", selectedXLR: a.mode })
        else patchSnap({ selectedInput: a.mode })
        break
      case "preset": patchSnap({ lastSelectedPreset: a.name }); break
      case "profile": patchSnap({ selectedProfile: a.name }); break
      case "tone": {
        var part = { tone: {} }
        for (var f in a) part.tone[f] = Model.clampTone(a[f])
        patchSnap(part)
        break
      }
    }
  }
  Component.onCompleted: if (fixtureMode) initFixture()

  // ---- IPC --------------------------------------------------------------------
  IpcHandler {
    target: "ric.dd8c"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function volSet(v: real): string { root.volSetTo(v); return "ok" }
    function volStep(d: real): string { root.volStepBy(d); return "ok" }
    function mute(state: string): string {
      var on = state === "on" || (state === "" && !root.muted)
      root.patchSnap({ mute: on }); root.sendCmd("mute", { on: on }); return "ok"
    }
    function sleep(state: string): string {
      var on = state === "on" || (state === "" && !root.asleep)
      root.patchSnap({ sleep: on }); root.sendCmd("sleep", { on: on }); return "ok"
    }
    function input(mode: string): string { root.inputSet(mode); return "ok" }
    function preset(name: string): string { root.presetSet(name); return "ok" }
    function profile(name: string): string { root.profileSet(name); return "ok" }
    function refresh(): string { root.refresh(); return "ok" }

    function dumpState(): string {
      return JSON.stringify({
        online: root.online, chipState: root.chipState,
        daemonRunning: daemonProc.running, daemonReady: root.daemonReady,
        lastError: root.lastError, fixtureMode: root.fixtureMode,
        settings: root.settings, focusSection: root.focusSection
      })
    }
  }

  // ---- bar chip ----------------------------------------------------------------
  implicitWidth: chip.implicitWidth
  implicitHeight: chip.implicitHeight

  Item {
    id: chip
    implicitWidth: barTextRow.implicitWidth + Style.space(17)
    implicitHeight: root.barH

    Row {
      id: barTextRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      DdMark {
        id: mark
        anchors.verticalCenter: parent.verticalCenter
        size: Math.max(20, root.barH - 8)
        ink: root.chipInk
      }

      Item {
        // Constant-width slot (widest possible readout) so the chip never
        // re-centres while the volume slider is dragged.
        width: gainProbe.implicitWidth
        implicitWidth: width
        height: gainLabel.implicitHeight
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: gainLabel
          anchors.fill: parent
          visible: root.barText && !root.vertical && root.online
          textFormat: Text.PlainText
          text: Model.barLabel(root.snap)
          color: root.chipInk
          font.family: root.ff
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignRight
          verticalAlignment: Text.AlignVCenter
        }
      }
    }

    Text {
      id: gainProbe
      visible: false
      textFormat: Text.PlainText
      text: "-88.8 dB"
      font.family: root.ff
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function (mouse) {
        if (mouse.button === Qt.MiddleButton) root.muteToggle()
        else root.toggle()
      }
      onWheel: function (wheel) {
        root.volStepBy(wheel.angleDelta.y > 0 ? root.volStepDb : -root.volStepDb)
      }
      onEntered: if (root.bar) root.bar.showTooltip(chip, Model.tooltipText(root.snap))
      onExited: if (root.bar) root.bar.hideTooltip(chip)
    }
  }

  readonly property color chipInk:
    root.chipState === "offline" ? Qt.alpha(root.fg, 0.35)
    : root.chipState === "standby" ? Qt.alpha(root.fg, 0.45)
    : root.chipState === "muted" ? Qt.alpha(root.fg, 0.60)
    : root.chipState === "idle" ? Qt.alpha(root.fg, 0.70)
    : root.fg

  // ---- panel ---------------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: chip
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function (dx, dy) { root.moveCursor(dx, dy) }
      onReturnRequested: root.viaEnter = true
      onActivateRequested: {
        if (root.viaEnter) { root.viaEnter = false; root.activateSection() }
        else root.muteToggle()
      }
      onCloseRequested: root.close()
      onTabRequested: function (direction) {
        if (Math.abs(direction) === 1) {
          cursorActive = true
          moveSection(direction)
        }
      }
      onTextKey: function (t) {
        if (t === "+" || t === "=") root.volStepBy(root.volStepDb)
        else if (t === "-" || t === "_") root.volStepBy(-root.volStepDb)
        else if (t === "m") root.muteToggle()
        else if (t === "s") root.sleepToggle()
        else if (t === "f") root.frontToggle()
        else if (t === "i") root.inputCycle()
        else if (t === "r") root.refresh()
        else if (t >= "1" && t <= "5") {
          var opts = Model.sourceOptions()
          root.inputSet(opts[Number(t) - 1].value)
        }
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        anchors.bottomMargin: Style.space(42) // keep content clear of the footer
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height
          ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(13)

          // ---------- Hero: room · fw · input · gain ----------
          PanelHero {
            iconComponent: inputTile
            title: Model.heroTitle(root.snap)
            meta: Model.heroMeta(root.snap)
            detail: root.asleep ? "STANDBY" : (root.muted ? "MUTED" : "")
            foreground: root.fg
            fontFamily: root.ff
          }

          // ---------- Volume ----------
          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              id: muteBtn
              width: root.controlH + Style.space(10)
              height: root.controlH
              iconText: Model.volIcon(root.snap)
              bordered: true
              selected: root.muted
              foreground: root.fg
              fontFamily: root.ff
              hasCursor: root.cursorActive && root.focusSection === "volume" && root.idx("volume") === 0
              onClicked: root.muteToggle()
              onHovered: function (h) { if (h) root.setCursor("volume", 0) }
            }

            Rectangle {
              id: volFrame
              // volSlot has a constant width (widest readout), so the track
              // never resizes while the number changes length mid-drag.
              width: Math.max(40, parent.width - muteBtn.width - volSlot.width
                              - parent.spacing * 2)
              height: root.controlH
              color: "transparent"
              border.width: root.cursorActive && root.focusSection === "volume"
                && root.idx("volume") === 1 ? 1 : 0
              border.color: Qt.alpha(root.fg, 0.75)

              PanelSlider {
                id: volSlider
                anchors.fill: parent
                bar: root.bar
                minimum: root.lim.min
                maximum: root.lim.max
                step: root.volStepDb
                value: root.vol
                enabled: root.online
                // Live while dragging: the UI is driven purely by the drag
                // (device echoes suppressed until release), and a throttled
                // write reaches the device every 120 ms; release commits
                // immediately and the device echo then reconciles.
                onMoved: function (v) {
                  var val = Model.clampDb(v, root.snap)
                  root.dragActive = true
                  root.dragVol = val
                  root.patchSnap({ gain: { global: val } })
                  volDragTimer.restart()
                }
                onReleased: function (v) {
                  root.dragActive = false
                  volDragTimer.stop()
                  root.volSetTo(v)
                }
              }
              Timer {
                id: volDragTimer
                interval: 120
                onTriggered: {
                  root.patchSnap({ mute: false })
                  root.sendCmd("vol", { db: root.dragVol })
                }
              }
            }

            Item {
              id: volSlot
              width: volProbe.implicitWidth
              height: volReadout.implicitHeight
              anchors.verticalCenter: parent.verticalCenter

              Text {
                id: volReadout
                anchors.fill: parent
                textFormat: Text.PlainText
                text: root.online ? Model.fmtDb(root.vol) : "—"
                color: root.fg
                opacity: root.muted ? 0.45 : 1.0
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
              }
            }

            Text {
              id: volProbe
              visible: false
              textFormat: Text.PlainText
              text: "-88.8 dB"
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---------- Toggles: standby / front LED ----------
          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              width: (parent.width - parent.spacing) / 2
              height: root.controlH
              iconText: Model.ICON.sleep
              text: "Standby"
              bordered: true
              selected: root.asleep
              foreground: root.fg
              fontFamily: root.ff
              hasCursor: root.cursorActive && root.focusSection === "toggles" && root.idx("toggles") === 0
              onClicked: root.sleepToggle()
              onHovered: function (h) { if (h) root.setCursor("toggles", 0) }
            }
            Button {
              width: (parent.width - parent.spacing) / 2
              height: root.controlH
              iconText: Model.ICON.power
              text: "Front LED"
              bordered: true
              selected: root.online && root.snap.frontled === true
              foreground: root.fg
              fontFamily: root.ff
              hasCursor: root.cursorActive && root.focusSection === "toggles" && root.idx("toggles") === 1
              onClicked: root.frontToggle()
              onHovered: function (h) { if (h) root.setCursor("toggles", 1) }
            }
          }

          // ---------- Source ----------
          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "INPUT"
              foreground: root.fg
              fontFamily: root.ff
            }

            ButtonGroup {
              width: parent.width
              options: Model.sourceOptions()
              value: root.inputMode
              foreground: root.fg
              fontFamily: root.ff
              cursorIndex: root.cursorActive && root.focusSection === "source"
                ? root.idx("source") : -1
              onChanged: function (v) { root.inputSet(v) }
              onHovered: function (i, h) { if (h) root.setCursor("source", i) }
            }
          }

          // ---------- Presets ----------
          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "PRESETS"
              foreground: root.fg
              fontFamily: root.ff
            }

            ButtonGroup {
              width: parent.width
              options: Model.namedOptions(root.snap ? root.snap.presets : {})
              value: root.online ? root.snap.lastSelectedPreset : ""
              foreground: root.fg
              fontFamily: root.ff
              cursorIndex: root.cursorActive && root.focusSection === "presets"
                ? root.idx("presets") : -1
              onChanged: function (v) { root.presetSet(v) }
              onHovered: function (i, h) { if (h) root.setCursor("presets", i) }
            }
          }

          // ---------- Profiles (RoomMatching) ----------
          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "PROFILES"
              foreground: root.fg
              fontFamily: root.ff
            }

            ButtonGroup {
              width: parent.width
              options: Model.namedOptions(root.snap ? root.snap.profiles : {})
              value: root.online ? root.snap.selectedProfile : ""
              foreground: root.fg
              fontFamily: root.ff
              cursorIndex: root.cursorActive && root.focusSection === "profiles"
                ? root.idx("profiles") : -1
              onChanged: function (v) { root.profileSet(v) }
              onHovered: function (i, h) { if (h) root.setCursor("profiles", i) }
            }
          }

          // ---------- Tone ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "TONE"
              foreground: root.fg
              fontFamily: root.ff
            }

            Repeater {
              model: [
                { field: "sub", label: "Sub" },
                { field: "bass", label: "Bass" },
                { field: "treble", label: "Treble" }
              ]
              delegate: Row {
                required property var modelData
                required property int index
                width: panelColumn.width
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(52)
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.fg
                  opacity: 0.7
                  font.family: root.ff
                  font.pixelSize: Style.font.bodySmall
                }

                Rectangle {
                  width: Math.max(40, parent.width - Style.space(52)
                                  - Style.space(56) - parent.spacing * 2)
                  height: root.controlH
                  color: "transparent"
                  border.width: root.cursorActive && root.focusSection === "tone"
                    && root.idx("tone") === index ? 1 : 0
                  border.color: Qt.alpha(root.fg, 0.75)

                  PanelSlider {
                    anchors.fill: parent
                    bar: root.bar
                    minimum: -12
                    maximum: 6
                    step: 0.5
                    value: root.online && root.snap.tone
                      ? Number(root.snap.tone[modelData.field]) || 0 : 0
                    enabled: root.online
                    onReleased: function (v) { root.toneSet(modelData.field, v) }
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(56)
                  textFormat: Text.PlainText
                  text: root.online && root.snap.tone
                    ? Model.fmtDb(root.snap.tone[modelData.field]) : "—"
                  color: root.fg
                  opacity: 0.8
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignRight
                }
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---------- Device ----------
          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "DEVICE"
              foreground: root.fg
              fontFamily: root.ff
            }

            InfoPair { label: "Master"; value: root.online ? String(root.snap.masterIp) : "—" }
            InfoPair { label: "Firmware"; value: root.online ? String(root.snap.version) : "—" }
            InfoPair {
              label: "Phase mode"
              value: root.online ? (root.linPhase ? "Linear" : "Low latency") : "—"
            }
            InfoPair {
              label: "Night mode"
              value: root.online ? (root.night ? "On" : "Off") : "—"
            }
            InfoPair {
              label: "Input level"
              value: root.online && root.snap.inputLevel !== undefined
                ? Number(root.snap.inputLevel).toFixed(1) + " dB" : "—"
            }
            InfoPair {
              label: "Licenses"
              value: root.online ? Model.licenseText(root.snap.licenses) : "—"
            }
            InfoPair {
              label: "Speakers"
              value: root.online ? Model.positionText(root.snap.positions) : "—"
            }
          }

          // ---------- Error / hint line ----------
          Text {
            visible: root.lastError !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.lastError
            color: root.fg
            opacity: 0.65
            font.family: root.ff
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }

    // footer: key hints + section indicator
    Column {
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(10)
      spacing: Style.space(4)
      visible: root.opened

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "m mute · s standby · f led · i input · 1-5 input · +/- vol · r refresh"
        color: root.fg
        opacity: 0.45
        font.family: root.ff
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }

      Row {
        spacing: Style.space(6)
        Repeater {
          model: root.sectionOrder
          delegate: Rectangle {
            required property int index
            required property var modelData
            width: Style.space(6)
            height: Style.space(6)
            radius: width / 2
            color: root.focusSection === modelData && root.cursorActive
              ? root.fg : Qt.alpha(root.fg, 0.25)
          }
        }
      }
    }
  }

  // Dutch & Dutch monogram — from the vendor's favicon.svg (trademark Dutch
  // & Dutch; used here to label the user's own room). QtSvg's basic renderer
  // mangles the evenodd counters, so we ship pre-rasterized 128px PNGs in
  // light/dark variants and pick by ink luminance.
  component DdMark: Item {
    id: ddMark
    property color ink: root.fg
    property real size: Style.bar.iconCanvas
    width: size
    height: size
    implicitWidth: size
    implicitHeight: size
    Image {
      anchors.fill: parent
      fillMode: Image.PreserveAspectFit
      smooth: true
      source: (ddMark.ink.r * 0.299 + ddMark.ink.g * 0.587
               + ddMark.ink.b * 0.114) > 0.5
        ? "assets/dd-mark-light.png" : "assets/dd-mark-dark.png"
    }
  }

  // Panel hero tile: the D&D monogram (the active input is spelled out in
  // the hero meta line, so the tile carries the brand instead of a glyph).
  // Declared as a Component value (house pattern, cf. ric.wiim artTile):
  // inline `component X:` types cannot be assigned to Component properties.
  Component {
    id: inputTile
    Rectangle {
      width: Style.space(44)
      height: Style.space(44)
      color: Qt.alpha(root.fg, 0.08)
      DdMark {
        anchors.centerIn: parent
        size: Style.space(30)
        ink: root.chipInk
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: label
      color: root.fg
      opacity: 0.6
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }
    Item {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, parent.width - parent.children[0].implicitWidth
              - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: value
      color: root.fg
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
