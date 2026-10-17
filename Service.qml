import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "GuardModel.js" as GuardModel

// OLED Guard.
//
// The premise: on an OLED panel, wear is luminance integrated over time, and
// the status bar is the only surface that holds still for the entire session.
// Every other pixel gets shuffled by window moves, scrolling and workspace
// switches; the bar's clock, tray icons and workspace pills do not. Left alone
// the strip simply ages faster than the panel around it.
//
// So the guard does one thing: hold a translucent veil over that strip, deepen
// it when nobody is looking, and lift it entirely when there is fullscreen
// content underneath.
Item {
    id: root

    // Injected by omarchy-shell's service loader. `shell` is the scoped plugin
    // API, not the host shell: it carries barConfig and a scalar view of the
    // bar, and serviceFor() answers for this plugin's own id only.
    property var shell: null
    property string omarchyPath: ""
    property var manifest: null

    readonly property var config: GuardModel.normalize(
        GuardModel.entryFor(shell ? shell.barConfig : null, GuardModel.PLUGIN_ID))

    // Runtime pause, driven by IPC or the bar widget. Deliberately not
    // persisted: a pause is for "not right now", not for "forever" -- forever
    // is `"enabled": false` in shell.json.
    property bool paused: false

    property bool idle: false
    property int phase: 0

    // Bumped whenever something happened that could change a per-screen
    // fullscreen verdict. Overlays reference it so their own bindings
    // re-evaluate: `lastIpcObject` is refreshed in place by an async round
    // trip, and a binding on it alone would not reliably re-run.
    property int hyprRevision: 0

    // --------------------------------------------------------------- geometry
    //
    // Taken off the live bar rather than re-derived from hyprctl: the bar host
    // already knows its own edge and thickness, and reading it here means a
    // bar that resizes or moves drags the veil along with it for free.
    readonly property var barState: shell ? shell.bar : null
    readonly property string edge: GuardModel.edgeFor(barState)
    readonly property bool barHidden: barState ? !!barState.barHidden : false

    // The bar's thickness on one screen. A notch floor can make a top bar
    // thicker on one screen than the configured size.
    function thicknessFor(screen) {
        var size = barState && screen ? barState.barSizeFor(screen.name) : 0
        return size > 0 ? size : 26
    }

    // Whether the pointer is on the bar. The service cannot see that -- the
    // scoped bar state carries no hover -- so the bar widget writes it here
    // from its own bar API. Without the widget, Reveal on hover never fires.
    //
    // The overlay sits on top of the bar with an empty input region, so
    // pointer events pass straight through and the bar still sees them.
    property bool barHovered: false

    // ------------------------------------------------------------ attenuation
    //
    // Screen-independent part only. Fullscreen is resolved per overlay, since
    // it is a per-monitor fact.
    readonly property real attenuation: GuardModel.attenuationFor({
        enabled: config.enabled,
        paused: root.paused,
        barHidden: root.barHidden,
        idle: root.idle,
        hovered: root.barHovered,
        revealOnHover: config.revealOnHover,
        hoverOpacity: config.hoverOpacity,
        baseOpacity: config.baseOpacity,
        idleOpacity: config.idleOpacity
    })

    // What the panel receives on average, once checkerboard's alpha ceiling is
    // taken into account. This is the figure that gets reported and banked.
    readonly property real deliveredAttenuation: GuardModel.effectiveAttenuation(
        root.attenuation, config.checkerboard, config.checkerContrast)

    readonly property bool active: attenuation > 0

    function statusObject() {
        return {
            enabled: config.enabled,
            paused: root.paused,
            active: root.active,
            // requested is what the config asked for; delivered is what the
            // panel gets. Equal by construction now that the checker sits on a
            // floor rather than carrying the whole attenuation itself, but both
            // are reported so a future mode that cannot hit its target has
            // somewhere honest to say so.
            attenuation: Math.round(root.deliveredAttenuation * 100) / 100,
            requestedAttenuation: Math.round(root.attenuation * 100) / 100,
            mode: config.checkerboard ? "checkerboard" : "dim",
            idle: root.idle,
            hovered: root.barHovered,
            revealOnHover: config.revealOnHover,
            fullscreen: root.fullscreen,
            edge: root.edge,
            thickness: root.barState ? root.barState.barSize : 0
        }
    }

    // ------------------------------------------------------------- fullscreen
    //
    // Only for `status` and the bar tooltip: it reports the focused screen.
    // The veil decision is made per overlay, against its own screen.
    readonly property bool fullscreen: {
        hyprRevision // re-evaluate when the workspace payload is refreshed
        try {
            var ws = Hyprland.focusedWorkspace
            var raw = ws ? ws.lastIpcObject : null
            return raw ? !!(raw.hasfullscreen || raw.hasFullscreen) : false
        } catch (e) {
            return false
        }
    }

    Connections {
        // No ignoreUnknownSignals: if a future Quickshell renames these, the
        // failure should be loud rather than silently disabling fullscreen
        // detection and leaving the veil over somebody's film.
        target: Hyprland

        function onFocusedWorkspaceChanged() {
            root.hyprRevision++
        }

        function onRawEvent(event) {
            // Cheap filter: only the events that can flip fullscreen state are
            // worth a refresh, and this fires on every Hyprland event.
            var name = ""
            try {
                name = String(event.name || "")
            } catch (e) {
                return
            }
            if (name === "fullscreen" || name === "activewindow" || name === "closewindow"
                    || name === "openwindow" || name === "workspace"
                    || name === "focusedmon" || name === "monitoradded"
                    || name === "monitorremoved") {
                Hyprland.refreshWorkspaces()
                Hyprland.refreshMonitors()
                // refreshWorkspaces is an async round trip, so bumping here
                // only covers the pre-refresh read; the settle timer below
                // catches the state the refresh actually returned.
                root.hyprRevision++
                hyprSettleTimer.restart()
            }
        }
    }

    Timer {
        id: hyprSettleTimer
        interval: 120
        repeat: false
        onTriggered: root.hyprRevision++
    }

    // ------------------------------------------------------------------- idle
    IdleMonitor {
        id: idleMonitor
        enabled: root.config.enabled && !root.paused
        timeout: root.config.idleAfterSeconds
        respectInhibitors: true
        onIsIdleChanged: root.idle = isIdle
    }

    // The monitor is torn down while paused, and it is not guaranteed to
    // report going un-idle on the way out. Without this a resume could snap
    // straight to idleOpacity until the next keypress.
    onPausedChanged: if (paused) idle = false

    // Rotating the checkerboard phase is what stops the pattern itself from
    // becoming the burn-in. Pointless in flat-dim mode, so it does not run.
    Timer {
        id: phaseTimer
        running: root.config.enabled && root.config.checkerboard
        interval: root.config.checkerPhaseMinutes * 60 * 1000
        repeat: true
        onTriggered: root.phase = (root.phase + 1) % 2
    }

    // ---------------------------------------------------------------- surface
    Variants {
        model: Quickshell.screens

        Overlay {
            edge: root.edge
            thickness: root.thicknessFor(modelData)
            attenuation: root.attenuation
            checkerboard: root.config.checkerboard
            checkerContrast: root.config.checkerContrast
            suspendOnFullscreen: root.config.suspendOnFullscreen
            hyprRevision: root.hyprRevision
            phaseX: GuardModel.phaseOffset(root.phase).x
            phaseY: GuardModel.phaseOffset(root.phase).y
            fadeMs: root.config.fadeMs
            revealMs: root.config.revealMs
            hovered: root.barHovered
            revealOnHover: root.config.revealOnHover
        }
    }

    // -------------------------------------------------------------------- IPC
    IpcHandler {
        target: "oledguard"

        function status(): string {
            return JSON.stringify(root.statusObject())
        }

        function pause(): string {
            root.paused = true
            return "paused"
        }

        function resume(): string {
            root.paused = false
            return "resumed"
        }

        function toggle(): string {
            root.paused = !root.paused
            return root.paused ? "paused" : "resumed"
        }

    }


}
