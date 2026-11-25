import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import QtQuick.Window

import Muse.Ui
import Muse.UiComponents as MU
import MuseScore 3.0
import FileIO 3.0

MuseScore {
    id: root

    title: "Plugin Creator"
    description: "Live QML editor with syntax-aware code editing, find & replace, external file tracking, runner, detachable floating preview window, multi-breakpoint step-in/over/out debugger/REPL with local scope inspection, console, and Gemini AI assistant for MuseScore 4 plugins."
    version: "1.14.2"
    pluginType: "dialog"
    thumbnailName: "thumbnail.png"
    requiresScore: false

    implicitWidth: 1100
    implicitHeight: 700
    width: Window.width > 0 ? Window.width : implicitWidth
    height: Window.height > 0 ? Window.height : implicitHeight

    // Persistent settings
    property string lastFilePath: ""
    property string geminiApiKey: ""
    property string geminiModel: "gemini-4-hydrogen"
    property bool trackExternalChanges: false

    // Working state
    property bool isClosing: false
    property var activeInstance: null
    property var activeMachine: null
    property var machineStack: []
    property bool isStepping: false
    property string stepMode: "none"         // "none" | "over" | "into" | "out" | "continue"
    property int stepTargetDepth: -1
    property bool popOutPreview: false
    property bool floatingWindowOpened: false
    property var floatingWindow: null
    property var breakpointLines: []         // Array of 1-based line numbers
    property var breakpointRects: []         // Array of { line: int, rect: rect }
    property int debugActiveLine: -1         // 1-based line number currently paused on (-1 = none)
    property rect debugActiveRect: Qt.rect(0, 0, 0, 0)
    property var braceMatchRects: []         // Array of { rect: rect, matched: bool }
    property string highlightedHtml: ""
    property real highlightOverlayY: 0
    property var highlightedLineCache: []
    property int lastKnownLineCount: 0
    property string currentFilePath: ""
    property var pendingSave: null
    property bool isDirty: false
    property string cleanTextSnapshot: ""
    property string lastKnownDiskModTime: ""
    property bool externalChangePending: false
    property string pendingDiscardAction: ""   // "close" | "open" | "new"
    property bool showFindBar: false
    property int currentMatchStart: -1
    property int currentMatchEnd: -1
    property bool showAiBar: false
    property bool aiBusy: false
    property string aiTmpOut: ""
    property string aiTmpReq: ""
    property string aiTmpErr: ""
    property string aiTmpSh: ""
    property string lastErrorText: ""
    property int aiRetryCount: 0
    property string aiActiveModel: ""
    property var aiChatHistory: []           // Array of { role: "user"|"model", parts: [{ text: "..." }] }
    property string pendingAiPrompt: ""
    property bool didInitialWindowPlacement: false

    // Crash-Recovery Backup State
    property string recoveredBackupCode: ""
    property string recoveredBackupTargetPath: ""

    // Side-Park State
    property bool isParkedSide: false
    property point savedWindowPos: Qt.point(100, 100)
    readonly property bool pluginWindowActive: !!root.Window.window && root.Window.window.active

    // REPL History & Busy State
    property var replHistory: []
    property int replHistoryIdx: -1
    property bool replBusy: false
    property string pendingReplExpr: ""

    readonly property string defaultDemoCode:
        'import QtQuick\nimport MuseScore 3.0\n\nMuseScore {\n    id: testPlugin\n    property int stepCounter: 0\n\n    // Tip: Click line numbers in the gutter to toggle multiple breakpoints!\n    // Use F10 (Step Over), F11 (Step Into), and Shift+F11 (Step Out).\n    onRun: {\n        console.log("Starting multi-breakpoint demo...")\n        if (!curScore) {\n            console.warn("No score is currently open.")\n            return\n        }\n        runHelper(2)\n        console.log("Back in onRun after helper!")\n    }\n\n    function runHelper(limit) {\n        for (var i = 1; i <= limit; i++) {\n            stepCounter = i\n            console.log("Helper iteration:", i)\n        }\n    }\n}'

    // Only intercept shortcuts when Plugin Creator's own window is active
    Keys.onShortcutOverride: function(e) {
        if (!root.pluginWindowActive) return
        if (e.key === Qt.Key_Escape) {
            e.accepted = true
        } else if ((e.modifiers & Qt.ControlModifier) && (e.modifiers & Qt.ShiftModifier) && e.key === Qt.Key_W) {
            e.accepted = true
        } else if ((e.modifiers & Qt.ControlModifier) && (e.key === Qt.Key_F || e.key === Qt.Key_H || e.key === Qt.Key_O)) {
            e.accepted = true
        } else if (e.key === Qt.Key_F3 || e.key === Qt.Key_F9) {
            e.accepted = true
        } else if (root.isStepping && (e.key === Qt.Key_F10 || e.key === Qt.Key_F11)) {
            e.accepted = true
        }
    }

    Keys.onPressed: function(e) {
        if (!root.pluginWindowActive) return
        if ((e.modifiers & Qt.ControlModifier) && (e.modifiers & Qt.ShiftModifier) && e.key === Qt.Key_W) {
            root.requestClose()
            e.accepted = true
        } else if (e.key === Qt.Key_Escape) {
            if (unsavedOverlay.visible) {
                root.pendingDiscardAction = ""
                unsavedOverlay.visible = false
                editor.forceActiveFocus()
            } else if (root.showFindBar) {
                root.showFindBar = false
                editor.forceActiveFocus()
            }
            e.accepted = true
        } else if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_O) {
            root.openPluginFile()
            e.accepted = true
        } else if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_F) {
            root.toggleFind(true, false)
            e.accepted = true
        } else if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_H) {
            root.toggleFind(true, true)
            e.accepted = true
        } else if (e.key === Qt.Key_F3) {
            root.findNext(e.modifiers & Qt.ShiftModifier)
            e.accepted = true
        } else if (e.key === Qt.Key_F9) {
            root.toggleBreakpointAtCursor()
            e.accepted = true
        } else if (root.isStepping && e.key === Qt.Key_F10) {
            root.stepOver()
            e.accepted = true
        } else if (root.isStepping && e.key === Qt.Key_F11) {
            if (e.modifiers & Qt.ShiftModifier) {
                root.stepOut()
            } else {
                root.stepInto()
            }
            e.accepted = true
        }
    }

    // Compact, modern flat toolbar button component with hover tooltip
    component ToolBtn: Rectangle {
        id: btn
        property string text: ""
        property string tip: ""
        property bool accent: false
        property bool activeToggle: false
        property bool enabled: true
        signal clicked()

        implicitWidth: btnLabel.implicitWidth + 14
        implicitHeight: 24
        radius: 4
        opacity: enabled ? 1.0 : 0.42
        color: {
            if (!enabled) return accent ? ui.theme.accentColor : ui.theme.buttonColor
            if (activeToggle) return "#b83232"
            if (btnMouse.pressed) return accent ? Qt.darker(ui.theme.accentColor, 1.2) : Qt.darker(ui.theme.buttonColor, 1.15)
            if (btnMouse.containsMouse) return accent ? Qt.lighter(ui.theme.accentColor, 1.1) : Qt.lighter(ui.theme.buttonColor, 1.12)
            return accent ? ui.theme.accentColor : ui.theme.buttonColor
        }
        border.color: (accent || activeToggle) ? "transparent" : ui.theme.strokeColor
        border.width: (accent || activeToggle) ? 0 : 1

        Text {
            id: btnLabel
            anchors.centerIn: parent
            text: btn.text
            font.family: ui.theme.bodyFont.family
            font.pixelSize: 11
            font.weight: (btn.accent || btn.activeToggle) ? 600 : 400
            color: (btn.accent || btn.activeToggle) ? "#ffffff" : ui.theme.fontPrimaryColor
        }

        QQC.ToolTip {
            id: btnTip
            visible: !root.isClosing && btn.tip.length > 0 && btnMouse.containsMouse && !btnMouse.pressed
            delay: 350
            text: btn.tip
        }

        MouseArea {
            id: btnMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: btn.enabled
            cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onPressed: btnTip.hide()
            onClicked: btn.clicked()
        }
    }

    // Intercept window titlebar X button when buffer has unsaved changes
    Connections {
        target: root.Window.window
        enabled: !root.isClosing && !!root.Window.window
        function onClosing(close) {
            if (!root || root.isClosing || !root.Window.window) return
            if (root.isDirty) {
                close.accepted = false
                if (root.isParkedSide) {
                    root.toggleParkWindow()
                }
                root.pendingDiscardAction = "close"
                unsavedOverlay.visible = true
            } else {
                root.isClosing = true
                root.clearBackupTempFile()
                root.stopCode(true)
            }
        }
    }

    Settings {
        category: "PluginCreator"
        property alias lastFilePath: root.lastFilePath
        property alias geminiApiKey: root.geminiApiKey
        property alias geminiModel: root.geminiModel
        property alias trackExternalChanges: root.trackExternalChanges
    }

    FileIO { id: fio }
    FileIO { id: readerFio }
    FileIO { id: watchFio }

    QProcess {
        id: copyProc
        onFinished: root.finishExternalSave(true)
        onErrorOccurred: root.finishExternalSave(false)
    }

    QProcess {
        id: aiProc
        onFinished: root.finishGeminiRequest(true)
        onErrorOccurred: root.finishGeminiRequest(false)
    }

    Timer {
        id: aiTimeoutTimer
        interval: 80000
        repeat: false
        onTriggered: {
            if (root.aiBusy) {
                root.aiBusy = false
                root.logMessage("ERR", "Gemini request timed out after 80 seconds.", "#f48771")
            }
        }
    }

    // Poll currentFilePath for external edits (e.g., from VS Code or gedit)
    Timer {
        id: externalFileWatchTimer
        interval: 1200
        repeat: true
        running: !root.isClosing && root.trackExternalChanges && root.currentFilePath !== ""
                 && !root.pendingSave && !openDialog.visible && !saveDialog.visible
                 && !unsavedOverlay.visible && !recoveryOverlay.visible
        onTriggered: root.checkExternalFileChange()
    }

    // Debounced full syntax-highlighting refresh for multi-line edits on large files
    Timer {
        id: highlightTimer
        interval: 60
        repeat: false
        onTriggered: {
            if (!root.isClosing) {
                root.refreshSyntaxHighlight()
            }
        }
    }

    // Debounced autosave timer for manual edits (1.5s after typing stops)
    Timer {
        id: autosaveTimer
        interval: 1500
        repeat: false
        onTriggered: {
            if (!root.isClosing && root.isDirty && !recoveryOverlay.visible) {
                root.writeBackupTempFile()
            }
        }
    }

    // Yields one UI paint frame so "[REPL] > expr" and "Evaluating..." render immediately
    Timer {
        id: replEvalTimer
        interval: 15
        repeat: false
        onTriggered: root.executePendingRepl()
    }

    // Yields one UI paint frame so button tooltips dismiss and console flushes before execution
    Timer {
        id: runDelayTimer
        interval: 15
        repeat: false
        onTriggered: root.executeRunCode()
    }

    // Smooth horizontal slide animation for parking/restoring the window
    NumberAnimation {
        id: parkAnim
        target: root.Window.window
        property: "x"
        duration: 420
        easing.type: Easing.OutCubic
        onFinished: {
            if (!root.isClosing && !root.isParkedSide && root.Window.window) {
                root.Window.window.raise()
                root.Window.window.requestActivate()
                editor.forceActiveFocus()
            }
        }
    }

    // ------------------------------------------------------------------
    //  Crash-Recovery Backup Helpers (.tmp in OS tempPath)
    // ------------------------------------------------------------------

    function getBackupTempPath() {
        return fio.tempPath().replace(/\\/g, "/") + "/plugin_creator_autosave.qml.tmp"
    }

    function getBackupMetaPath() {
        return fio.tempPath().replace(/\\/g, "/") + "/plugin_creator_autosave.meta.tmp"
    }

    function writeBackupTempFile() {
        var tmpPath = getBackupTempPath()
        var metaPath = getBackupMetaPath()
        fio.source = tmpPath
        var ok = fio.write(editor.text)
        if (ok) {
            fio.source = metaPath
            fio.write(currentFilePath || "")
        }
        return ok
    }

    function clearBackupTempFile() {
        autosaveTimer.stop()
        var tmpPath = getBackupTempPath()
        var metaPath = getBackupMetaPath()
        fio.source = tmpPath
        if (fio.exists()) {
            fio.remove()
        }
        fio.source = metaPath
        if (fio.exists()) {
            fio.remove()
        }
    }

    function checkAndPromptCrashRecovery() {
        var tmpPath = getBackupTempPath()
        var savedCode = readTextFile(tmpPath)
        if (!savedCode || savedCode.trim() === "") {
            clearBackupTempFile()
            return
        }

        var metaPath = getBackupMetaPath()
        var targetPath = (readTextFile(metaPath) || "").trim()
        var normalizedSaved = normalizeLoadedText(savedCode)

        if (normalizedSaved === editor.text) {
            clearBackupTempFile()
            return
        }

        recoveredBackupCode = normalizedSaved
        recoveredBackupTargetPath = targetPath
        recoveryOverlay.visible = true
    }

    function acceptCrashRecovery() {
        recoveryOverlay.visible = false
        var codeToRestore = recoveredBackupCode
        var pathToRestore = recoveredBackupTargetPath
        recoveredBackupCode = ""
        recoveredBackupTargetPath = ""

        if (pathToRestore !== "") {
            currentFilePath = pathToRestore
            lastFilePath = pathToRestore
            var diskContent = readTextFile(pathToRestore)
            cleanTextSnapshot = (diskContent !== null) ? normalizeLoadedText(diskContent) : ""
            syncDiskModTime(pathToRestore)
        } else {
            currentFilePath = ""
            cleanTextSnapshot = normalizeLoadedText(defaultDemoCode)
            lastKnownDiskModTime = ""
        }

        externalChangePending = false
        editor.text = codeToRestore
        resetEditorView()
        isDirty = (editor.text !== cleanTextSnapshot)
        writeBackupTempFile()
        editor.forceActiveFocus()
        logMessage("INFO", "Restored unsaved backup from previous session"
            + (currentFilePath ? (" (" + currentFilePath + ")") : "") + ".", "#4ec9b0")
    }

    function discardCrashRecovery() {
        recoveryOverlay.visible = false
        recoveredBackupCode = ""
        recoveredBackupTargetPath = ""
        clearBackupTempFile()
        editor.forceActiveFocus()
        logMessage("INFO", "Discarded previous session backup.", "#b5cea8")
    }

    function getAvailableScreenWidth() {
        var w = root.Window.window
        if (w && w.screen) {
            if (w.screen.desktopAvailableWidth > 0) return w.screen.desktopAvailableWidth
            if (w.screen.width > 0) return w.screen.width
        }
        if (root.Screen.desktopAvailableWidth > 0) return root.Screen.desktopAvailableWidth
        if (root.Screen.width > 0) return root.Screen.width
        if (Qt.application.screens && Qt.application.screens.length > 0) {
            var primary = Qt.application.screens[0]
            if (primary.desktopAvailableWidth > 0) return primary.desktopAvailableWidth
            if (primary.width > 0) return primary.width
        }
        return 1280
    }

    function getAvailableScreenHeight() {
        var w = root.Window.window
        if (w && w.screen) {
            if (w.screen.desktopAvailableHeight > 0) return w.screen.desktopAvailableHeight
            if (w.screen.height > 0) return w.screen.height
        }
        if (root.Screen.desktopAvailableHeight > 0) return root.Screen.desktopAvailableHeight
        if (root.Screen.height > 0) return root.Screen.height
        if (Qt.application.screens && Qt.application.screens.length > 0) {
            var primary = Qt.application.screens[0]
            if (primary.desktopAvailableHeight > 0) return primary.desktopAvailableHeight
            if (primary.height > 0) return primary.height
        }
        return 800
    }

    function ensureFloatingWindow() {
        if (floatingWindow) return floatingWindow
        var titleStr = (root.currentFilePath ? root.currentFilePath.split("/").pop() : "Plugin Preview") + " - Live Preview"
        var qmlStr =
            'import QtQuick\nimport QtQuick.Window\n' +
            'Window {\n' +
            '    id: fw\n' +
            '    title: ' + JSON.stringify(titleStr) + '\n' +
            '    color: ui.theme.backgroundPrimaryColor\n' +
            '    minimumWidth: 320\n' +
            '    minimumHeight: 240\n' +
            '    property alias hostItem: host\n' +
            '    onClosing: function(close) {\n' +
            '        close.accepted = true\n' +
            '        if (!root.isClosing && root.activeInstance) root.stopCode(false)\n' +
            '    }\n' +
            '    Item { id: host; anchors.fill: parent; focus: true }\n' +
            '}\n'
        floatingWindow = Qt.createQmlObject(qmlStr, root, "file:///floating_preview.qml")
        floatingWindowOpened = true
        return floatingWindow
    }

    function sizeAndShowFloatingWindow(obj) {
        var fw = ensureFloatingWindow()
        var desiredW = 800
        var desiredH = 600

        if (obj) {
            if (obj.implicitWidth && obj.implicitWidth > 0) desiredW = obj.implicitWidth
            else if (obj.width && obj.width > 0) desiredW = obj.width

            if (obj.implicitHeight && obj.implicitHeight > 0) desiredH = obj.implicitHeight
            else if (obj.height && obj.height > 0) desiredH = obj.height
        }

        var availW = getAvailableScreenWidth()
        var availH = getAvailableScreenHeight()

        fw.width = Math.max(360, Math.min(desiredW, availW - 60))
        fw.height = Math.max(260, Math.min(desiredH, availH - 80))
        fw.x = Math.max(24, Math.floor((availW - fw.width) / 2) + 30)
        fw.y = Math.max(32, Math.floor((availH - fw.height) / 2))
        fw.visible = true
        fw.raise()
    }

    function togglePopOutPreview() {
        popOutPreview = !popOutPreview
        if (popOutPreview) {
            var fw = ensureFloatingWindow()
            if (activeInstance) {
                activeInstance.parent = fw.hostItem
                sizeAndShowFloatingWindow(activeInstance)
            } else {
                sizeAndShowFloatingWindow(null)
            }
            logMessage("INFO", "Preview popped out to floating window.", "#b5cea8")
        } else {
            var hadInstance = !!activeInstance
            if (activeInstance) {
                activeInstance.parent = sandboxHost
                activeInstance.x = 0
                activeInstance.y = 0
                activeInstance.visible = true
                activeInstance.update()
            }
            if (floatingWindow) {
                var fwToClose = floatingWindow
                floatingWindow = null
                floatingWindowOpened = false
                fwToClose.visible = false
                fwToClose.destroy()
            }
            editor.forceActiveFocus()
            if (hadInstance) {
                logMessage("INFO", "Preview docked back into main window.", "#b5cea8")
            } else {
                logMessage("INFO", "Dock mode restored (click Run to launch plugin in docked preview).", "#b5cea8")
            }
        }
    }

    function makeResizable() {
        if (root.isClosing) return
        var w = root.Window.window
        if (!w) return
        w.minimumWidth = 680
        w.minimumHeight = 480
        w.maximumWidth = 16777215
        w.maximumHeight = 16777215

        if (!didInitialWindowPlacement) {
            var availW = getAvailableScreenWidth()
            var availH = getAvailableScreenHeight()
            var targetW = Math.min(w.width > 0 ? w.width : implicitWidth, availW - 48)
            var targetH = Math.min(w.height > 0 ? w.height : implicitHeight, availH - 64)
            if (targetW > 0) w.width = targetW
            if (targetH > 0) w.height = targetH
            w.x = Math.max(16, Math.floor((availW - targetW) / 2))
            w.y = Math.max(24, Math.floor((availH - targetH) / 2))
            if (w.width > 0 && w.height > 0) {
                didInitialWindowPlacement = true
            }
        }
    }

    function toggleParkWindow() {
        var w = root.Window.window
        if (!w) return

        var availW = getAvailableScreenWidth()
        var peekWidth = mainCol.anchors.margins + parkBtn.width + 6

        parkAnim.stop()
        if (!isParkedSide) {
            if (w.x < availW - 200) {
                savedWindowPos = Qt.point(w.x, w.y)
            } else if (savedWindowPos.x >= availW - 200) {
                savedWindowPos = Qt.point(Math.max(16, Math.floor((availW - w.width) / 2)), Math.max(24, w.y))
            }
            isParkedSide = true
            parkAnim.from = w.x
            parkAnim.to = availW - peekWidth
            parkAnim.start()
        } else {
            isParkedSide = false
            var restoreX = (savedWindowPos.x < availW - 200)
                           ? savedWindowPos.x
                           : Math.max(16, Math.floor((availW - w.width) / 2))
            w.y = savedWindowPos.y
            parkAnim.from = w.x
            parkAnim.to = restoreX
            parkAnim.start()
        }
    }

    Timer {
        id: resizeTimer
        interval: 120
        repeat: true
        property int count: 0
        onTriggered: {
            if (root.isClosing) {
                stop()
                return
            }
            root.makeResizable()
            if (count < 3 && !recoveryOverlay.visible && !root.isParkedSide) {
                editor.forceActiveFocus()
            }
            if (++count >= 10) stop()
        }
    }

    onRun: {
        resizeTimer.start()
        var loadedSaved = false
        if (lastFilePath !== "") {
            var restoredContent = readTextFile(lastFilePath)
            if (restoredContent !== null) {
                currentFilePath = normalizeLocalPath(lastFilePath)
                setEditorTextClean(restoredContent)
                syncDiskModTime(currentFilePath)
                logMessage("INFO", "Restored last session file: " + currentFilePath, "#b5cea8")
                loadedSaved = true
            }
        }
        if (!loadedSaved) {
            setEditorTextClean(defaultDemoCode)
            lastKnownDiskModTime = ""
        }
        editor.forceActiveFocus()
        checkAndPromptCrashRecovery()
    }

    Component.onDestruction: {
        root.isClosing = true
        parkAnim.stop()
        resizeTimer.stop()
        externalFileWatchTimer.stop()
        highlightTimer.stop()
        autosaveTimer.stop()
        aiTimeoutTimer.stop()
        replEvalTimer.stop()
        runDelayTimer.stop()
    }

    QtObject {
        id: sandboxConsole
        function log() {
            var msg = Array.prototype.slice.call(arguments).join(" ")
            root.logMessage("LOG", msg, "#9cdcfe")
            console.log(msg)
        }
        function warn() {
            var msg = Array.prototype.slice.call(arguments).join(" ")
            root.logMessage("WARN", msg, "#dcdcaa")
            console.warn(msg)
        }
        function error() {
            var msg = Array.prototype.slice.call(arguments).join(" ")
            root.lastErrorText = msg
            root.logMessage("ERR", msg, "#f48771")
            console.error(msg)
        }
        function runMachine(machine, label) {
            root.beginMachine(machine, label)
        }
    }

    function sandboxQuit() {
        logMessage("INFO", "Plugin called quit() - tearing down preview instance.", "#b5cea8")
        stopCode(true)
    }

    // ------------------------------------------------------------------
    //  External File Tracking (e.g. VS Code / gedit Live Sync)
    // ------------------------------------------------------------------

    function normalizeLoadedText(raw) {
        return String(raw || "").replace(/\r\n/g, "\n").replace(/\n+$/, "")
    }

    function syncDiskModTime(path) {
        var cleanPath = normalizeLocalPath(path)
        if (!cleanPath) {
            lastKnownDiskModTime = ""
            return
        }
        watchFio.source = cleanPath
        lastKnownDiskModTime = watchFio.exists() ? String(watchFio.modifiedTime()) : ""
    }

    function reloadFromDiskPreservingScroll(newContent, announce) {
        var normalized = normalizeLoadedText(newContent)
        var vbar = editorScroll.QQC.ScrollBar.vertical
        var hbar = editorScroll.QQC.ScrollBar.horizontal
        var savedVPos = vbar ? vbar.position : 0
        var savedHPos = hbar ? hbar.position : 0
        var savedCur = editor.cursorPosition

        clearDebugState()
        cleanTextSnapshot = normalized
        editor.text = normalized
        isDirty = false
        externalChangePending = false
        clearBackupTempFile()
        refreshSyntaxHighlight()

        editor.cursorPosition = Math.max(0, Math.min(savedCur, editor.text.length))
        updateLineVisuals()
        Qt.callLater(function() {
            if (root.isClosing) return
            if (vbar) vbar.position = savedVPos
            if (hbar) hbar.position = savedHPos
            updateVisibleHighlightSlice()
            updateLineVisuals()
        })

        if (announce) {
            logMessage("INFO", "Reloaded external changes from " + currentFilePath.split("/").pop() + ".", "#4ec9b0")
        }
    }

    function checkExternalFileChange() {
        if (!trackExternalChanges || !currentFilePath) return
        watchFio.source = currentFilePath
        if (!watchFio.exists()) return

        var modTime = String(watchFio.modifiedTime())
        if (lastKnownDiskModTime !== "" && modTime === lastKnownDiskModTime) return

        var rawDiskContent = watchFio.read()
        lastKnownDiskModTime = modTime
        if (rawDiskContent === null) return

        var diskContent = normalizeLoadedText(rawDiskContent)
        if (diskContent === cleanTextSnapshot) return

        if (!isDirty) {
            reloadFromDiskPreservingScroll(diskContent, true)
        } else if (!externalChangePending) {
            externalChangePending = true
            logMessage("WARN", "External modification detected in " + currentFilePath.split("/").pop()
                + " (buffer has unsaved edits — click 'Reload External' in toolbar to replace).", "#dcdcaa")
        }
    }

    function applyPendingExternalReload() {
        if (!currentFilePath) return
        var diskContent = readTextFile(currentFilePath)
        syncDiskModTime(currentFilePath)
        if (diskContent !== null) {
            reloadFromDiskPreservingScroll(diskContent, true)
        } else {
            externalChangePending = false
            logMessage("ERR", "Could not read external file: " + currentFilePath, "#f48771")
        }
    }

    // ------------------------------------------------------------------
    //  QML / JavaScript Syntax Highlighter (Virtualized Viewport Overlay)
    // ------------------------------------------------------------------

    readonly property var syntaxKeywords: ({
        "import": true, "as": true, "property": true, "readonly": true,
        "default": true, "signal": true, "enum": true, "component": true,
        "required": true, "pragma": true, "function": true, "var": true,
        "let": true, "const": true, "if": true, "else": true, "for": true,
        "while": true, "do": true, "switch": true, "case": true, "break": true,
        "continue": true, "return": true, "try": true, "catch": true,
        "finally": true, "throw": true, "new": true, "delete": true,
        "typeof": true, "instanceof": true, "in": true, "of": true,
        "void": true, "this": true, "super": true, "true": true,
        "false": true, "null": true, "undefined": true, "NaN": true,
        "Infinity": true, "int": true, "real": true, "double": true,
        "bool": true, "string": true, "url": true, "color": true,
        "font": true, "list": true, "point": true, "size": true,
        "rect": true, "vector2d": true, "vector3d": true, "variant": true
    })

    readonly property var syntaxBuiltins: ({
        "curScore": true, "cmd": true, "newScore": true, "readScore": true,
        "writeScore": true, "closeScore": true, "console": true, "Math": true,
        "JSON": true, "Date": true, "Array": true, "Object": true,
        "String": true, "Number": true, "Boolean": true, "RegExp": true,
        "Error": true, "Promise": true, "qsTr": true, "qsTranslate": true
    })

    function highlightQmlJs(src) {
        if (!src || src.length === 0) return ""
        var out = []
        var i = 0
        var n = src.length
        var kw = syntaxKeywords
        var bi = syntaxBuiltins

        function esc(s) {
            return s.replace(/&/g, "&amp;")
                    .replace(/</g, "&lt;")
                    .replace(/>/g, "&gt;")
                    .replace(/ /g, "&nbsp;")
        }

        function span(colorHex, rawText) {
            return '<span style="color:' + colorHex + ';">' + esc(rawText) + '</span>'
        }

        while (i < n) {
            var ch = src[i]
            var nextCh = (i + 1 < n) ? src[i + 1] : ""

            if (ch === "\n") {
                out.push("<br/>")
                i++
                continue
            }

            if (ch === "/" && nextCh === "/") {
                var endLine = src.indexOf("\n", i)
                if (endLine === -1) endLine = n
                out.push(span("#008000", src.substring(i, endLine)))
                i = endLine
                continue
            }

            if (ch === "/" && nextCh === "*") {
                var endBlock = src.indexOf("*/", i + 2)
                endBlock = (endBlock === -1) ? n : (endBlock + 2)
                var commentLines = src.substring(i, endBlock).split("\n")
                for (var cl = 0; cl < commentLines.length; ++cl) {
                    if (cl > 0) out.push("<br/>")
                    if (commentLines[cl].length > 0) {
                        out.push(span("#008000", commentLines[cl]))
                    }
                }
                i = endBlock
                continue
            }

            if (ch === '"' || ch === "'") {
                var quote = ch
                var j = i + 1
                while (j < n && src[j] !== "\n") {
                    if (src[j] === "\\") {
                        j += 2
                        continue
                    }
                    if (src[j] === quote) {
                        j++
                        break
                    }
                    j++
                }
                out.push(span("#a31515", src.substring(i, j)))
                i = j
                continue
            }

            if (/[0-9]/.test(ch) && (i === 0 || !/[A-Za-z0-9_$]/.test(src[i - 1]))) {
                var numEnd = i
                if (ch === "0" && (nextCh === "x" || nextCh === "X")) {
                    numEnd += 2
                    while (numEnd < n && /[0-9A-Fa-f]/.test(src[numEnd])) numEnd++
                } else {
                    while (numEnd < n && /[0-9.]/.test(src[numEnd])) numEnd++
                }
                out.push(span("#098658", src.substring(i, numEnd)))
                i = numEnd
                continue
            }

            if (/[A-Za-z_$]/.test(ch)) {
                var idEnd = i + 1
                while (idEnd < n && /[A-Za-z0-9_$]/.test(src[idEnd])) idEnd++
                var word = src.substring(i, idEnd)
                var prevChar = i > 0 ? src[i - 1] : ""

                var look = idEnd
                while (look < n && (src[look] === " " || src[look] === "\t")) look++
                var followedByColon = (look < n && src[look] === ":")

                if (prevChar !== "." && kw[word]) {
                    out.push(span("#0000ff", word))
                } else if (/^on[A-Z]/.test(word) && followedByColon) {
                    out.push(span("#af00db", word))
                } else if (/^[A-Z]/.test(word)) {
                    out.push(span("#267f99", word))
                } else if (prevChar !== "." && bi[word]) {
                    out.push(span("#795e26", word))
                } else if (followedByColon && prevChar !== ".") {
                    out.push(span("#001080", word))
                } else {
                    out.push(esc(word))
                }
                i = idEnd
                continue
            }

            var runEnd = i + 1
            while (runEnd < n) {
                var rc = src[runEnd]
                if (rc === "\n" || rc === "/" || rc === '"' || rc === "'" || /[A-Za-z0-9_$]/.test(rc)) break
                runEnd++
            }
            out.push(esc(src.substring(i, runEnd)))
            i = runEnd
        }

        return '<span style="color:#111111;">' + out.join("") + '</span>'
    }

    function updateVisibleHighlightSlice() {
        var cache = highlightedLineCache
        if (!cache || cache.length === 0) {
            highlightOverlayY = 0
            highlightedHtml = ""
            return
        }

        var vbar = editorScroll.QQC.ScrollBar.vertical
        var totalH = editor.implicitHeight
        var viewH = editorScroll.availableHeight
        var lineH = (editor.lineCount > 0 && totalH > editor.topPadding + editor.bottomPadding)
            ? ((totalH - editor.topPadding - editor.bottomPadding) / editor.lineCount)
            : 16

        var viewTop = (vbar && totalH > viewH) ? (vbar.position * totalH) : 0
        var firstVis = Math.max(0, Math.floor((viewTop - editor.topPadding) / lineH) - 10)
        var visCount = Math.ceil((viewH > 0 ? viewH : 600) / lineH) + 22
        var lastVis = Math.min(cache.length - 1, firstVis + visCount)

        highlightOverlayY = firstVis * lineH
        highlightedHtml = cache.slice(firstVis, lastVis + 1).join("<br/>")
    }

    function refreshSyntaxHighlight() {
        highlightTimer.stop()
        var lines = editor.text.split("\n")
        var cache = new Array(lines.length)
        for (var i = 0; i < lines.length; ++i) {
            cache[i] = highlightQmlJs(lines[i])
        }
        highlightedLineCache = cache
        lastKnownLineCount = lines.length
        updateVisibleHighlightSlice()
    }

    function updateHighlightIncremental() {
        var t = editor.text
        var lines = t.split("\n")
        if (lines.length !== highlightedLineCache.length || t.indexOf("/*") !== -1) {
            if (lines.length <= 400) {
                refreshSyntaxHighlight()
            } else {
                var curIdx = lineNumberAtOffset(t, editor.cursorPosition) - 1
                if (curIdx >= 0 && curIdx < lines.length && curIdx < highlightedLineCache.length) {
                    highlightedLineCache[curIdx] = highlightQmlJs(lines[curIdx])
                    updateVisibleHighlightSlice()
                }
                highlightTimer.restart()
            }
            return
        }

        // Single-line edit: re-tokenize ONLY the edited line and render only visible slice
        var lineIdx = lineNumberAtOffset(t, editor.cursorPosition) - 1
        if (lineIdx >= 0 && lineIdx < lines.length) {
            highlightedLineCache[lineIdx] = highlightQmlJs(lines[lineIdx])
            updateVisibleHighlightSlice()
        }
    }

    // ------------------------------------------------------------------
    //  Editor Ergonomics: Atomic Single-Undo Edits, Indent, Pairs, Comments
    // ------------------------------------------------------------------

    function atomicReplaceSpan(spanStart, spanEnd, replacement) {
        if (spanStart === spanEnd && replacement.length === 0) return

        // Save user's current clipboard via hidden atomicHelper
        atomicHelper.text = ""
        atomicHelper.selectAll()
        atomicHelper.paste()
        var savedClip = atomicHelper.text

        // Replace [spanStart, spanEnd] in a single QTextCursor undo transaction
        atomicHelper.text = replacement
        atomicHelper.selectAll()
        atomicHelper.copy()

        editor.select(spanStart, spanEnd)
        editor.paste()

        // Restore user's previous clipboard
        atomicHelper.text = savedClip
        atomicHelper.selectAll()
        atomicHelper.copy()
        atomicHelper.text = ""
    }

    function replaceEditorRange(startPos, endPos, replacement, newCursorStart, newCursorEnd) {
        atomicReplaceSpan(startPos, endPos, replacement)
        if (newCursorEnd !== undefined && newCursorEnd !== newCursorStart) {
            editor.select(newCursorStart, newCursorEnd)
        } else {
            editor.cursorPosition = newCursorStart
        }
    }

    function applyBatchEdits(edits) {
        if (!edits || edits.length === 0) return

        var sorted = edits.slice().sort(function(a, b) {
            var posA = (a.type === "insert") ? a.pos : a.start
            var posB = (b.type === "insert") ? b.pos : b.start
            return posA - posB
        })

        var first = sorted[0]
        var spanStart = (first.type === "insert") ? first.pos : first.start
        var lastEd = sorted[sorted.length - 1]
        var spanEnd = (lastEd.type === "insert") ? lastEd.pos : lastEd.end

        var t = editor.text
        var parts = []
        var cursor = spanStart

        for (var i = 0; i < sorted.length; ++i) {
            var ed = sorted[i]
            if (ed.type === "replace") {
                if (ed.start > cursor) parts.push(t.substring(cursor, ed.start))
                if (ed.text && ed.text.length > 0) parts.push(ed.text)
                cursor = ed.end
            } else if (ed.type === "remove") {
                if (ed.start > cursor) parts.push(t.substring(cursor, ed.start))
                cursor = ed.end
            } else {
                if (ed.pos > cursor) parts.push(t.substring(cursor, ed.pos))
                parts.push(ed.text)
                cursor = ed.pos
            }
        }
        if (spanEnd > cursor) parts.push(t.substring(cursor, spanEnd))

        atomicReplaceSpan(spanStart, spanEnd, parts.join(""))
    }

    function handleEditorEnter() {
        var t = editor.text
        var selStart = editor.selectionStart
        var selEnd = editor.selectionEnd
        var lineStart = t.lastIndexOf("\n", selStart - 1) + 1
        var lineEnd = t.indexOf("\n", selEnd)
        if (lineEnd === -1) lineEnd = t.length

        var beforeCursorOnLine = t.substring(lineStart, selStart)
        var fullLine = t.substring(lineStart, lineEnd)
        var indentMatch = beforeCursorOnLine.match(/^([ \t]*)/)
        var baseIndent = indentMatch ? indentMatch[1] : ""

        if (selStart === selEnd && /^[ \t]+$/.test(fullLine)) {
            var insertClean = "\n" + baseIndent
            var targetCleanPos = lineStart + insertClean.length
            replaceEditorRange(lineStart, lineEnd, insertClean, targetCleanPos, targetCleanPos)
            return
        }

        var trimmedBefore = beforeCursorOnLine.replace(/\/\/[^\n]*$/, "").trim()
        var lastCh = trimmedBefore.length > 0 ? trimmedBefore[trimmedBefore.length - 1] : ""
        var nextCh = selEnd < t.length ? t[selEnd] : ""

        if (lastCh === "{" && nextCh === "}") {
            var innerIndent = baseIndent + "    "
            var insertBlock = "\n" + innerIndent + "\n" + baseIndent
            var targetPos = selStart + 1 + innerIndent.length
            replaceEditorRange(selStart, selEnd, insertBlock, targetPos, targetPos)
            return
        }

        var extraIndent = (lastCh === "{" || lastCh === "[" || lastCh === "(") ? "    " : ""
        var insertStr = "\n" + baseIndent + extraIndent
        var nextPos = selStart + insertStr.length
        replaceEditorRange(selStart, selEnd, insertStr, nextPos, nextPos)
    }

    function handleEditorTab(outdent) {
        var t = editor.text
        var selStart = editor.selectionStart
        var selEnd = editor.selectionEnd

        if (!outdent && selStart === selEnd) {
            editor.insert(selStart, "    ")
            editor.cursorPosition = selStart + 4
            return
        }

        var blockStart = t.lastIndexOf("\n", selStart - 1) + 1
        var effectiveEnd = (selEnd > selStart && t[selEnd - 1] === "\n") ? (selEnd - 1) : selEnd
        var blockEnd = t.indexOf("\n", effectiveEnd)
        if (blockEnd === -1) blockEnd = t.length

        var lines = t.substring(blockStart, blockEnd).split("\n")
        var edits = []
        var lineOffset = blockStart
        var deltaFirst = 0
        var deltaTotal = 0

        for (var i = 0; i < lines.length; ++i) {
            var lineStr = lines[i]
            if (!outdent) {
                edits.push({ type: "insert", pos: lineOffset, text: "    " })
                if (i === 0) deltaFirst = 4
                deltaTotal += 4
            } else {
                var removed = 0
                if (lineStr.indexOf("    ") === 0) {
                    removed = 4
                } else if (lineStr[0] === "\t") {
                    removed = 1
                } else {
                    var leadSpaces = lineStr.match(/^( {1,3})/)
                    if (leadSpaces) removed = leadSpaces[1].length
                }
                if (removed > 0) {
                    edits.push({ type: "remove", start: lineOffset, end: lineOffset + removed })
                }
                if (i === 0) deltaFirst = -removed
                deltaTotal -= removed
            }
            lineOffset += lineStr.length + 1
        }

        applyBatchEdits(edits)

        if (selStart === selEnd) {
            editor.cursorPosition = Math.max(blockStart, selStart + deltaFirst)
        } else {
            var newSelStart = Math.max(blockStart, selStart + deltaFirst)
            var newSelEnd = Math.max(newSelStart, selEnd + deltaTotal)
            editor.select(newSelStart, newSelEnd)
        }
    }

    function handleElectricCloseBrace() {
        var t = editor.text
        var selStart = editor.selectionStart
        var selEnd = editor.selectionEnd
        var lineStart = t.lastIndexOf("\n", selStart - 1) + 1
        var beforeOnLine = t.substring(lineStart, selStart)

        if (/^[ \t]+$/.test(beforeOnLine)) {
            var outdented = beforeOnLine.indexOf("    ") === 0
                ? beforeOnLine.substring(4)
                : (beforeOnLine[0] === "\t" ? beforeOnLine.substring(1) : beforeOnLine.replace(/^ {1,3}/, ""))
            var newPos = lineStart + outdented.length + 1
            replaceEditorRange(lineStart, selEnd, outdented + "}", newPos, newPos)
            return true
        }
        return false
    }

    function handleAutoPair(openCh, closeCh) {
        var t = editor.text
        var selStart = editor.selectionStart
        var selEnd = editor.selectionEnd

        if (selStart !== selEnd) {
            var selected = t.substring(selStart, selEnd)
            replaceEditorRange(selStart, selEnd, openCh + selected + closeCh, selStart + 1, selEnd + 1)
            return true
        }

        if (openCh === closeCh && selStart < t.length && t[selStart] === closeCh) {
            editor.cursorPosition = selStart + 1
            return true
        }

        var nextCh = selStart < t.length ? t[selStart] : ""
        if (nextCh === "" || /[\s)\]\};,:]/.test(nextCh)) {
            if (openCh === closeCh && selStart > 0 && /[A-Za-z0-9_$\"'`]/.test(t[selStart - 1])) {
                return false
            }
            replaceEditorRange(selStart, selEnd, openCh + closeCh, selStart + 1, selStart + 1)
            return true
        }
        return false
    }

    function handleOvertypeClose(closeCh) {
        var t = editor.text
        var selStart = editor.selectionStart
        if (selStart === editor.selectionEnd && selStart < t.length && t[selStart] === closeCh) {
            editor.cursorPosition = selStart + 1
            return true
        }
        return false
    }

    function handleSmartBackspace() {
        var t = editor.text
        var selStart = editor.selectionStart
        if (selStart !== editor.selectionEnd || selStart <= 0 || selStart >= t.length) return false
        var prev = t[selStart - 1]
        var next = t[selStart]
        if ((prev === "(" && next === ")") ||
            (prev === "[" && next === "]") ||
            (prev === "{" && next === "}") ||
            (prev === '"' && next === '"') ||
            (prev === "'" && next === "'")) {
            editor.remove(selStart - 1, selStart + 1)
            editor.cursorPosition = selStart - 1
            return true
        }
        return false
    }

    function toggleLineComment() {
        var t = editor.text
        var selStart = editor.selectionStart
        var selEnd = editor.selectionEnd
        var blockStart = t.lastIndexOf("\n", selStart - 1) + 1
        var effectiveEnd = (selEnd > selStart && t[selEnd - 1] === "\n") ? (selEnd - 1) : selEnd
        var blockEnd = t.indexOf("\n", effectiveEnd)
        if (blockEnd === -1) blockEnd = t.length

        var lines = t.substring(blockStart, blockEnd).split("\n")
        var allCommented = true
        var minIndent = 9999

        for (var i = 0; i < lines.length; ++i) {
            if (lines[i].trim() === "") continue
            if (!/^[ \t]*\/\//.test(lines[i])) {
                allCommented = false
            }
            var m = lines[i].match(/^([ \t]*)/)
            if (m && m[1].length < minIndent) minIndent = m[1].length
        }
        if (minIndent === 9999) minIndent = 0

        var edits = []
        var lineOffset = blockStart
        var deltaFirst = 0
        var deltaTotal = 0

        for (var j = 0; j < lines.length; ++j) {
            var lineStr = lines[j]
            if (lineStr.trim() !== "") {
                if (allCommented) {
                    var matchUncomment = lineStr.match(/^([ \t]*)(\/\/ ?)/)
                    if (matchUncomment) {
                        var remStart = lineOffset + matchUncomment[1].length
                        var remLen = matchUncomment[2].length
                        edits.push({ type: "remove", start: remStart, end: remStart + remLen })
                        if (j === 0) deltaFirst = -remLen
                        deltaTotal -= remLen
                    }
                } else {
                    var insPos = lineOffset + minIndent
                    edits.push({ type: "insert", pos: insPos, text: "// " })
                    if (j === 0) deltaFirst = 3
                    deltaTotal += 3
                }
            }
            lineOffset += lineStr.length + 1
        }

        applyBatchEdits(edits)

        if (selStart === selEnd) {
            editor.cursorPosition = Math.max(blockStart, selStart + deltaFirst)
        } else {
            var s1 = Math.max(blockStart, selStart + deltaFirst)
            var s2 = Math.max(s1, selEnd + deltaTotal)
            editor.select(s1, s2)
        }
    }

    function findMatchingDelimBackward(src, closeIdx, openCh, closeCh) {
        var depth = 1
        var i = closeIdx - 1
        while (i >= 0 && depth > 0) {
            var ch = src[i]
            var lineStart = src.lastIndexOf("\n", i) + 1
            var prefixOnLine = src.substring(lineStart, i + 1)
            var slashIdx = prefixOnLine.indexOf("//")
            if (slashIdx !== -1 && (lineStart + slashIdx) < i) {
                i = lineStart + slashIdx - 1
                continue
            }
            if (ch === closeCh) depth++
            else if (ch === openCh) depth--
            i--
        }
        return (depth === 0) ? (i + 1) : -1
    }

    function updateBraceMatches() {
        var t = editor.text
        var pos = editor.cursorPosition
        if (!t || pos < 0 || pos > t.length || editor.selectionStart !== editor.selectionEnd) {
            braceMatchRects = []
            return
        }

        var openDelims = "{(["
        var closeDelims = "})]"
        var targetIdx = -1
        var ch = ""

        if (pos > 0 && (openDelims.indexOf(t[pos - 1]) !== -1 || closeDelims.indexOf(t[pos - 1]) !== -1)) {
            targetIdx = pos - 1
            ch = t[targetIdx]
        } else if (pos < t.length && (openDelims.indexOf(t[pos]) !== -1 || closeDelims.indexOf(t[pos]) !== -1)) {
            targetIdx = pos
            ch = t[targetIdx]
        }

        if (targetIdx === -1) {
            braceMatchRects = []
            return
        }

        var partnerIdx = -1
        var openPos = openDelims.indexOf(ch)
        if (openPos !== -1) {
            partnerIdx = findMatchingDelim(t, targetIdx, ch, closeDelims[openPos])
        } else {
            var closePos = closeDelims.indexOf(ch)
            partnerIdx = findMatchingDelimBackward(t, targetIdx, openDelims[closePos], ch)
        }

        var r1 = editor.positionToRectangle(targetIdx)
        var r2 = editor.positionToRectangle(targetIdx + 1)
        var w1 = Math.max(7, r2.x > r1.x ? (r2.x - r1.x) : 8)
        var rect1 = Qt.rect(r1.x, r1.y, w1, r1.height)

        if (partnerIdx !== -1) {
            var p1 = editor.positionToRectangle(partnerIdx)
            var p2 = editor.positionToRectangle(partnerIdx + 1)
            var pw = Math.max(7, p2.x > p1.x ? (p2.x - p1.x) : 8)
            var rect2 = Qt.rect(p1.x, p1.y, pw, p1.height)
            braceMatchRects = [
                { rect: rect1, matched: true },
                { rect: rect2, matched: true }
            ]
        } else {
            braceMatchRects = [
                { rect: rect1, matched: false }
            ]
        }
    }

    // ------------------------------------------------------------------
    //  Multi-Breakpoint & Line Geometry Helpers
    // ------------------------------------------------------------------

    function hasBreakpoint(line) {
        return breakpointLines.indexOf(line) !== -1
    }

    function charOffsetForLine(text, lineNum) {
        if (lineNum <= 1) return 0
        var line = 1
        for (var i = 0; i < text.length; ++i) {
            if (text[i] === "\n") {
                line++
                if (line === lineNum) return i + 1
            }
        }
        return text.length
    }

    function lineNumberAtOffset(text, offset) {
        var line = 1
        var limit = Math.min(offset, text.length)
        for (var i = 0; i < limit; ++i) {
            if (text[i] === "\n") line++
        }
        return line
    }

    function updateLineVisuals() {
        var rects = []
        var maxLines = editor.lineCount
        for (var i = 0; i < breakpointLines.length; ++i) {
            var ln = breakpointLines[i]
            if (ln > 0 && ln <= maxLines) {
                var off = charOffsetForLine(editor.text, ln)
                var r = editor.positionToRectangle(off)
                if (r.height > 0) {
                    rects.push({ line: ln, rect: r })
                }
            }
        }
        breakpointRects = rects

        if (debugActiveLine > 0 && debugActiveLine <= maxLines) {
            var actOff = charOffsetForLine(editor.text, debugActiveLine)
            debugActiveRect = editor.positionToRectangle(actOff)
        } else {
            debugActiveRect = Qt.rect(0, 0, 0, 0)
        }

        updateBraceMatches()
    }

    function toggleBreakpointAtCursor() {
        var line = lineNumberAtOffset(editor.text, editor.cursorPosition)
        toggleBreakpointLine(line)
    }

    function toggleBreakpointLine(line) {
        if (line < 1 || line > editor.lineCount) return
        var next = breakpointLines.slice()
        var idx = next.indexOf(line)
        if (idx !== -1) {
            next.splice(idx, 1)
            breakpointLines = next
            logMessage("INFO", "Breakpoint removed (line " + line + ").", "#b5cea8")
        } else {
            next.push(line)
            next.sort(function(a, b) { return a - b })
            breakpointLines = next
            logMessage("INFO", "Breakpoint added at line " + line + " (" + breakpointLines.length + " active).", "#f48771")
        }
        updateLineVisuals()
    }

    function clearAllBreakpoints() {
        breakpointLines = []
        updateLineVisuals()
        logMessage("INFO", "Cleared all breakpoints.", "#b5cea8")
    }

    function clearDebugState() {
        activeMachine = null
        machineStack = []
        isStepping = false
        stepMode = "none"
        stepTargetDepth = -1
        debugActiveLine = -1
        updateLineVisuals()
    }

    function stopCode(silent) {
        var wasStepping = root.isStepping
        clearDebugState()
        if (!root.isClosing && floatingWindowOpened && floatingWindow && floatingWindow.visible) {
            floatingWindow.visible = false
        }
        if (activeInstance) {
            var inst = activeInstance
            activeInstance = null
            inst.visible = false
            inst.enabled = false
            inst.parent = null
            inst.destroy()
            if (!root.isClosing) {
                gc()
            }
            if (!silent) {
                logMessage("WARN", "Execution interrupted - child plugin instance destroyed."
                    + (wasStepping ? " (If curScore.startCmd() was open, run curScore.endCmd() in REPL.)" : ""), "#dcdcaa")
            }
        }
    }

    // ------------------------------------------------------------------
    //  File Operations & Unsaved-Changes Protection
    // ------------------------------------------------------------------

    function normalizeLocalPath(p) {
        var clean = String(p || "").replace(/\\/g, "/")
        if (clean.indexOf("file:///") === 0) {
            clean = clean.substring(7)
            if (/^\/[A-Za-z]:\//.test(clean)) clean = clean.substring(1)
        }
        return clean
    }

    function readTextFile(path) {
        var cleanPath = normalizeLocalPath(path)
        if (!cleanPath) return null
        readerFio.source = cleanPath
        return readerFio.exists() ? readerFio.read() : null
    }

    function resetEditorView() {
        editor.cursorPosition = 0
        var flick = editorScroll.contentItem
        if (flick) {
            flick.contentX = 0
            flick.contentY = 0
        }
        if (editorScroll.QQC.ScrollBar.vertical) {
            editorScroll.QQC.ScrollBar.vertical.position = 0
        }
        if (editorScroll.QQC.ScrollBar.horizontal) {
            editorScroll.QQC.ScrollBar.horizontal.position = 0
        }
        refreshSyntaxHighlight()
        updateLineVisuals()
        Qt.callLater(function() {
            if (root.isClosing) return
            if (editor.contentWidth <= 0 && editor.text.length > 0) {
                editor.wrapMode = TextEdit.Wrap
                editor.wrapMode = TextEdit.NoWrap
            }
            editor.cursorPosition = 0
            if (editorScroll.contentItem) {
                editorScroll.contentItem.contentX = 0
                editorScroll.contentItem.contentY = 0
            }
            if (editorScroll.QQC.ScrollBar.vertical) {
                editorScroll.QQC.ScrollBar.vertical.position = 0
            }
            if (editorScroll.QQC.ScrollBar.horizontal) {
                editorScroll.QQC.ScrollBar.horizontal.position = 0
            }
            updateVisibleHighlightSlice()
            updateLineVisuals()
            editor.update()
        })
    }

    function setEditorTextClean(newText) {
        var normalized = normalizeLoadedText(newText)
        cleanTextSnapshot = normalized
        editor.text = normalized
        isDirty = false
        externalChangePending = false
        autosaveTimer.stop()
        resetEditorView()
    }

    function cleanQuit() {
        root.isClosing = true
        clearBackupTempFile()
        stopCode(true)
        root.quit()
    }

    function performAfterSaveAction() {
        var act = pendingDiscardAction
        pendingDiscardAction = ""
        if (act === "close") {
            cleanQuit()
        } else if (act === "new") {
            doNewBuffer()
        } else if (act === "open") {
            doOpenPluginFile()
        }
    }

    function requestClose() {
        if (isDirty) {
            if (isParkedSide) {
                toggleParkWindow()
            }
            pendingDiscardAction = "close"
            unsavedOverlay.visible = true
        } else {
            cleanQuit()
        }
    }

    function executePendingDiscard() {
        var act = pendingDiscardAction
        pendingDiscardAction = ""
        unsavedOverlay.visible = false
        isDirty = false
        externalChangePending = false
        clearBackupTempFile()
        if (act === "close") {
            cleanQuit()
        } else if (act === "new") {
            doNewBuffer()
        } else if (act === "open") {
            doOpenPluginFile()
        }
    }

    FileDialog {
        id: openDialog
        title: "Open QML Plugin"
        type: FileDialog.Open
        onAccepted: {
            var p = root.normalizeLocalPath(filePath)
            var content = root.readTextFile(p)
            if (content !== null) {
                root.currentFilePath = p
                root.lastFilePath = p
                root.breakpointLines = []
                root.clearDebugState()
                root.resetAiChat(true)
                root.clearBackupTempFile()
                root.setEditorTextClean(content)
                root.syncDiskModTime(p)
                editor.forceActiveFocus()
                logMessage("INFO", "Loaded: " + p + " (" + content.length + " chars)", "#b5cea8")
            } else {
                logMessage("ERR", "Could not read file: " + p, "#f48771")
            }
        }
    }

    FileDialog {
        id: saveDialog
        title: "Save QML Plugin"
        type: FileDialog.Save
        onAccepted: {
            var p = root.normalizeLocalPath(filePath)
            if (!p.toLowerCase().endsWith(".qml")) {
                p += ".qml"
            }
            root.currentFilePath = p
            root.lastFilePath = p
            saveCurrentFile()
        }
        onRejected: {
            root.pendingDiscardAction = ""
        }
    }

    function doNewBuffer() {
        stopCode(true)
        breakpointLines = []
        updateLineVisuals()
        resetAiChat(true)
        clearBackupTempFile()
        currentFilePath = ""
        lastFilePath = ""
        lastKnownDiskModTime = ""
        externalChangePending = false
        setEditorTextClean(defaultDemoCode)
        editor.forceActiveFocus()
        logMessage("INFO", "Started new buffer.", "#b5cea8")
    }

    function newBuffer() {
        if (isDirty) {
            pendingDiscardAction = "new"
            unsavedOverlay.visible = true
            return
        }
        doNewBuffer()
    }

    function doOpenPluginFile() {
        var startDir = currentFilePath ? currentFilePath.substring(0, currentFilePath.lastIndexOf("/"))
                                       : fio.homePath().replace(/\\/g, "/") + "/Documents/MuseScore4/Plugins"
        openDialog.folder = startDir
        openDialog.open()
    }

    function openPluginFile() {
        if (isDirty) {
            pendingDiscardAction = "open"
            unsavedOverlay.visible = true
            return
        }
        doOpenPluginFile()
    }

    function saveCurrentFile() {
        var vbar = editorScroll.QQC.ScrollBar.vertical
        var hbar = editorScroll.QQC.ScrollBar.horizontal
        var savedVPos = vbar ? vbar.position : 0
        var savedHPos = hbar ? hbar.position : 0
        var savedCur = editor.cursorPosition

        // Strip trailing whitespace across the buffer without shifting viewport scroll
        var t = editor.text
        var matches = []
        var re = /[ \t]+(?=\r?\n|$)/g
        var m
        while ((m = re.exec(t)) !== null) {
            matches.push({ start: m.index, end: m.index + m[0].length })
        }

        if (matches.length > 0) {
            var newCur = savedCur
            var edits = []
            for (var i = 0; i < matches.length; ++i) {
                var span = matches[i]
                edits.push({ type: "remove", start: span.start, end: span.end })
                if (newCur > span.start) {
                    newCur -= Math.min(span.end - span.start, newCur - span.start)
                }
            }
            applyBatchEdits(edits)
            editor.cursorPosition = Math.max(0, Math.min(newCur, editor.text.length))
            Qt.callLater(function() {
                if (root.isClosing) return
                if (vbar) vbar.position = savedVPos
                if (hbar) hbar.position = savedHPos
            })
        }

        if (!currentFilePath) {
            saveDialog.folder = fio.homePath().replace(/\\/g, "/") + "/Documents/MuseScore4/Plugins/new_plugin.qml"
            saveDialog.open()
            return
        }

        lastFilePath = currentFilePath
        var diskOut = editor.text.endsWith("\n") ? editor.text : (editor.text + "\n")

        fio.source = currentFilePath
        if (fio.write(diskOut)) {
            cleanTextSnapshot = editor.text
            isDirty = false
            externalChangePending = false
            syncDiskModTime(currentFilePath)
            clearBackupTempFile()
            logMessage("INFO", "Saved: " + currentFilePath, "#b5cea8")
            performAfterSaveAction()
            return
        }

        var tmpDir = fio.tempPath().replace(/\\/g, "/")
        var tmpPath = tmpDir + "/plugin_creator_save_" + Date.now() + ".qml"
        fio.source = tmpPath
        if (!fio.write(diskOut)) {
            pendingDiscardAction = ""
            logMessage("ERR", "Failed to write temporary save file: " + tmpPath, "#f48771")
            return
        }

        pendingSave = { tmp: tmpPath, dst: currentFilePath }

        if (Qt.platform.os === "windows") {
            var psCmd = "Copy-Item -LiteralPath '" + tmpPath.replace(/\//g, "\\").replace(/'/g, "''")
                      + "' -Destination '" + currentFilePath.replace(/\//g, "\\").replace(/'/g, "''") + "' -Force"
            copyProc.startWithArgs("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", psCmd])
        } else {
            copyProc.startWithArgs("/bin/cp", ["-f", tmpPath, currentFilePath])
        }
    }

    function finishExternalSave(ok) {
        if (!pendingSave) return
        var job = pendingSave
        pendingSave = null

        fio.source = job.tmp
        if (fio.exists()) fio.remove()

        fio.source = job.dst
        if (ok && fio.exists()) {
            cleanTextSnapshot = editor.text
            isDirty = false
            externalChangePending = false
            syncDiskModTime(job.dst)
            clearBackupTempFile()
            logMessage("INFO", "Saved: " + job.dst, "#b5cea8")
            performAfterSaveAction()
        } else {
            pendingDiscardAction = ""
            logMessage("ERR", "Failed to save to: " + job.dst, "#f48771")
        }
    }

    // ------------------------------------------------------------------
    //  Find & Replace, Go-to-Definition & Viewport Scrolling
    // ------------------------------------------------------------------

    function toggleFind(openOnly, focusReplace) {
        showFindBar = openOnly ? true : !showFindBar
        if (showFindBar) {
            if (editor.selectedText.length > 0 && editor.selectedText.indexOf("\n") === -1) {
                findInput.text = editor.selectedText
            }
            if (focusReplace) {
                replaceInput.forceActiveFocus()
                replaceInput.selectAll()
            } else {
                findInput.forceActiveFocus()
                findInput.selectAll()
            }
        } else {
            editor.forceActiveFocus()
        }
    }

    function findNext(backwards, keepBarFocus) {
        var query = findInput.text
        if (!query) return false

        var text = editor.text
        var hay = matchCaseBox.checked ? text : text.toLowerCase()
        var needle = matchCaseBox.checked ? query : query.toLowerCase()
        var idx = -1

        if (!backwards) {
            var startPos = Math.max(editor.selectionEnd, editor.cursorPosition, currentMatchEnd)
            idx = hay.indexOf(needle, startPos)
            if (idx === -1 && startPos > 0) {
                idx = hay.indexOf(needle, 0)
            }
        } else {
            var anchor = currentMatchStart >= 0 ? currentMatchStart : Math.min(editor.selectionStart, editor.cursorPosition)
            var searchEnd = anchor - 1
            if (searchEnd >= 0) {
                idx = hay.lastIndexOf(needle, searchEnd)
            }
            if (idx === -1) {
                idx = hay.lastIndexOf(needle)
            }
        }

        if (idx !== -1) {
            currentMatchStart = idx
            currentMatchEnd = idx + query.length
            if (!keepBarFocus) {
                editor.forceActiveFocus()
            }
            editor.select(idx, idx + query.length)
            scrollEditorToRect(editor.positionToRectangle(idx))
            return true
        } else {
            currentMatchStart = -1
            currentMatchEnd = -1
            logMessage("INFO", "Find: '" + query + "' not found.", "#dcdcaa")
            return false
        }
    }

    function replaceCurrentOrNext() {
        if (editor.readOnly) return
        var query = findInput.text
        if (!query) return

        var mStart = currentMatchStart
        var mEnd = currentMatchEnd
        if (mStart < 0 || mEnd <= mStart || mEnd > editor.text.length) {
            mStart = editor.selectionStart
            mEnd = editor.selectionEnd
        }

        var slice = (mEnd > mStart && mEnd <= editor.text.length) ? editor.text.substring(mStart, mEnd) : ""
        var matchesCurrent = matchCaseBox.checked
            ? (slice === query)
            : (slice.toLowerCase() === query.toLowerCase())

        if (matchesCurrent) {
            var rep = replaceInput.text
            replaceEditorRange(mStart, mEnd, rep, mStart + rep.length, mStart + rep.length)
            currentMatchStart = -1
            currentMatchEnd = -1
            findNext(false, true)
        } else {
            findNext(false, true)
        }
    }

    function replaceAllMatches() {
        if (editor.readOnly) return
        var query = findInput.text
        if (!query) return

        var t = editor.text
        var hay = matchCaseBox.checked ? t : t.toLowerCase()
        var needle = matchCaseBox.checked ? query : query.toLowerCase()
        var rep = replaceInput.text

        var positions = []
        var idx = hay.indexOf(needle, 0)
        while (idx !== -1) {
            positions.push(idx)
            idx = hay.indexOf(needle, idx + needle.length)
        }

        if (positions.length === 0) {
            logMessage("INFO", "Replace All: '" + query + "' not found.", "#dcdcaa")
            return
        }

        var vbar = editorScroll.QQC.ScrollBar.vertical
        var hbar = editorScroll.QQC.ScrollBar.horizontal
        var savedVPos = vbar ? vbar.position : 0
        var savedHPos = hbar ? hbar.position : 0
        var savedCur = editor.cursorPosition
        var delta = rep.length - query.length
        var newCur = savedCur

        var edits = []
        for (var i = 0; i < positions.length; ++i) {
            var p = positions[i]
            edits.push({ type: "replace", start: p, end: p + query.length, text: rep })
            if (newCur > p) {
                newCur += delta
            }
        }
        applyBatchEdits(edits)

        editor.cursorPosition = Math.max(0, Math.min(newCur, editor.text.length))
        Qt.callLater(function() {
            if (root.isClosing) return
            if (vbar) vbar.position = savedVPos
            if (hbar) hbar.position = savedHPos
            updateVisibleHighlightSlice()
        })

        logMessage("INFO", "Replaced " + positions.length + " occurrence" + (positions.length === 1 ? "" : "s") + ".", "#b5cea8")
    }

    function scrollEditorToRect(r) {
        if (r.height <= 0) return
        var vbar = editorScroll.QQC.ScrollBar.vertical
        if (vbar && editorScroll.availableHeight > 0 && editor.implicitHeight > 0) {
            var targetY = Math.max(0, r.y - editorScroll.availableHeight * 0.35)
            var maxVPos = Math.max(0, 1.0 - vbar.size)
            vbar.position = Math.min(maxVPos, targetY / editor.implicitHeight)
        }
        var hbar = editorScroll.QQC.ScrollBar.horizontal
        var codeViewW = editorScroll.availableWidth - gutter.width
        var totalRowW = editorRow.width
        if (hbar && codeViewW > 0 && totalRowW > editorScroll.availableWidth) {
            var targetX = Math.max(0, r.x - codeViewW * 0.25)
            var maxHPos = Math.max(0, 1.0 - hbar.size)
            hbar.position = Math.min(maxHPos, targetX / totalRowW)
        }
    }

    function ensureCursorVisibleInViewport() {
        var r = editor.cursorRectangle
        if (r.height <= 0) return

        var vbar = editorScroll.QQC.ScrollBar.vertical
        if (vbar && editor.implicitHeight > editorScroll.availableHeight && editorScroll.availableHeight > 0) {
            var viewTop = vbar.position * editor.implicitHeight
            var viewBottom = viewTop + editorScroll.availableHeight
            var curTop = r.y
            var curBottom = curTop + r.height
            var maxVPos = Math.max(0, 1.0 - vbar.size)

            if (curTop < viewTop) {
                vbar.position = Math.min(maxVPos, Math.max(0, curTop / editor.implicitHeight))
            } else if (curBottom > viewBottom) {
                var targetTop = curBottom - editorScroll.availableHeight
                vbar.position = Math.min(maxVPos, Math.max(0, targetTop / editor.implicitHeight))
            }
        }

        var hbar = editorScroll.QQC.ScrollBar.horizontal
        var codeViewW = editorScroll.availableWidth - gutter.width
        var totalRowW = editorRow.width
        if (hbar && totalRowW > editorScroll.availableWidth && codeViewW > 0) {
            var viewLeft = hbar.position * totalRowW
            var viewRight = viewLeft + codeViewW
            var margin = 24
            var maxHPos = Math.max(0, 1.0 - hbar.size)

            if (r.x < viewLeft + margin) {
                var newLeft = Math.max(0, r.x - margin)
                hbar.position = Math.min(maxHPos, newLeft / totalRowW)
            } else if (r.x + r.width + margin > viewRight) {
                var newLeft2 = Math.max(0, (r.x + r.width + margin) - codeViewW)
                hbar.position = Math.min(maxHPos, newLeft2 / totalRowW)
            }
        }
    }

    function jumpToFunctionDefinition(symbolName) {
        var name = (symbolName || "").trim()
        if (!name || !/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name)) return false

        var selStart = editor.selectionStart
        var beforeSel = editor.text.substring(Math.max(0, selStart - 20), selStart)
        if (/\bfunction\s+$/.test(beforeSel)) return false

        var escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
        var defRegex = new RegExp("\\bfunction\\s+" + escaped + "\\s*\\(")
        var match = defRegex.exec(editor.text)

        if (match) {
            var nameIdx = match.index + match[0].indexOf(name)
            editor.forceActiveFocus()
            editor.select(nameIdx, nameIdx + name.length)
            scrollEditorToRect(editor.positionToRectangle(nameIdx))
            var lineNum = lineNumberAtOffset(editor.text, nameIdx)
            logMessage("INFO", "Jumped to function " + name + "() at line " + lineNum + ".", "#b5cea8")
            return true
        }
        return false
    }

    // ------------------------------------------------------------------
    //  Gemini "Vibe Coding" Integration (Multi-Turn History + Backup)
    // ------------------------------------------------------------------

    function codeFence() {
        return String.fromCharCode(96, 96, 96)
    }

    function resetAiChat(silent) {
        aiChatHistory = []
        pendingAiPrompt = ""
        if (!silent) {
            logMessage("INFO", "Gemini conversation history cleared.", "#c586c0")
        }
    }

    function sendToGemini(overrideModel) {
        if (aiBusy) return
        if (!geminiApiKey || geminiApiKey.trim() === "") {
            logMessage("WARN", "Please enter your Gemini API key in the AI bar first.", "#dcdcaa")
            apiKeyField.forceActiveFocus()
            return
        }
        var prompt = aiPromptField.text.trim()
        if (!prompt) return

        if (isDirty) {
            writeBackupTempFile()
        }

        if (!overrideModel) {
            aiRetryCount = 0
            aiActiveModel = geminiModel.trim() || "gemini-4-hydrogen"
            pendingAiPrompt = prompt
            logMessage("PROMPT", "> " + prompt, "#9cdcfe")
        } else {
            aiActiveModel = overrideModel
        }

        aiBusy = true
        aiTimeoutTimer.restart()
        logMessage("INFO", "Sending to Gemini (" + aiActiveModel + ")...", "#c586c0")

        var sysInstruction =
            "You are an expert MuseScore 4.7 QML plugin developer. " +
            "The user is editing a QML plugin inside a live sandbox. " +
            "Important MuseScore 4 API notes: Use 'import QtQuick', 'import MuseScore 3.0', 'import FileIO 3.0', 'import Muse.Ui', 'import Muse.UiComponents as MU'. " +
            "Do not use QtQuick.Dialogs or Qt.labs.platform. FileDialog comes from MuseScore 3.0 and has no nameFilters property.\n"

        if (explainCheckBox.checked) {
            sysInstruction +=
                "Format your response using these exact XML tags:\n" +
                "<explanation>\nConcise 2-4 sentence explanation of what you changed.\n</explanation>\n" +
                "<code>\nComplete, valid, runnable QML file code here (no markdown backticks).\n</code>"
        } else {
            sysInstruction +=
                "Format your response using only this exact XML tag (no explanations, no markdown backticks):\n" +
                "<code>\nComplete, valid, runnable QML file code here.\n</code>"
        }

        var userContent = "User Request:\n" + prompt + "\n\n"
        if (lastErrorText !== "") {
            userContent += "Last Runtime/Syntax Error:\n" + lastErrorText + "\n\n"
        }
        userContent += "Current QML Code:\n" + editor.text

        var genConfig = { temperature: 0.2 }
        if (aiActiveModel.indexOf("flash-lite") === -1) {
            genConfig.thinkingConfig = { thinkingLevel: "LOW" }
        }

        var trimmedHistory = aiChatHistory.slice(-10)
        var fullContents = trimmedHistory.concat([
            { role: "user", parts: [{ text: userContent }] }
        ])

        var payloadObj = {
            system_instruction: { parts: [{ text: sysInstruction }] },
            contents: fullContents,
            generationConfig: genConfig
        }

        var tmpDir = fio.tempPath().replace(/\\/g, "/")
        var ts = Date.now()
        aiTmpReq = tmpDir + "/gemini_req_" + ts + ".json"
        aiTmpOut = tmpDir + "/gemini_res_" + ts + ".json"
        aiTmpErr = tmpDir + "/gemini_err_" + ts + ".txt"
        aiTmpSh  = tmpDir + "/gemini_call_" + ts + ".sh"

        fio.source = aiTmpReq
        fio.write(JSON.stringify(payloadObj))

        var url = "https://generativelanguage.googleapis.com/v1beta/models/" + aiActiveModel + ":generateContent?key=" + geminiApiKey.trim()

        if (Qt.platform.os === "windows") {
            var psCmd = "Invoke-RestMethod -TimeoutSec 75 -Uri '" + url + "' -Method Post -ContentType 'application/json' -InFile '"
                      + aiTmpReq.replace(/\//g, "\\") + "' | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 '"
                      + aiTmpOut.replace(/\//g, "\\") + "'"
            aiProc.startWithArgs("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", psCmd])
        } else {
            var shLines = [
                "#!/bin/sh",
                "unset LD_LIBRARY_PATH LD_PRELOAD",
                "curl -s -S --max-time 75 -X POST \"" + url + "\" -H \"Content-Type: application/json\" -d \"@" + aiTmpReq + "\" -o \"" + aiTmpOut + "\" 2>\"" + aiTmpErr + "\""
            ].join("\n")
            fio.source = aiTmpSh
            fio.write(shLines)
            aiProc.startWithArgs("/bin/sh", [aiTmpSh])
        }
    }

    function finishGeminiRequest(ok) {
        aiTimeoutTimer.stop()
        aiBusy = false

        var rawResp = ""
        var errOut = ""

        fio.source = aiTmpOut
        if (fio.exists()) {
            rawResp = fio.read()
            fio.remove()
        }
        fio.source = aiTmpErr
        if (fio.exists()) {
            errOut = fio.read().trim()
            fio.remove()
        }
        fio.source = aiTmpReq
        if (fio.exists()) {
            fio.remove()
        }
        fio.source = aiTmpSh
        if (fio.exists()) {
            fio.remove()
        }

        if (!ok || !rawResp) {
            if (aiRetryCount < 1 && aiActiveModel !== "gemini-3.5-flash-lite") {
                aiRetryCount++
                logMessage("WARN", aiActiveModel + " timed out or failed" + (errOut ? " (" + errOut + ")" : "") + ". Retrying with gemini-3.5-flash-lite...", "#dcdcaa")
                sendToGemini("gemini-3.5-flash-lite")
                return
            }
            logMessage("ERR", "Gemini request failed" + (errOut ? ": " + errOut : " (empty response from curl)."), "#f48771")
            return
        }

        try {
            var parsed = JSON.parse(rawResp)
            if (parsed.error) {
                if ((parsed.error.code === 503 || parsed.error.code === 429) && aiRetryCount < 1 && aiActiveModel !== "gemini-3.5-flash-lite") {
                    aiRetryCount++
                    logMessage("WARN", aiActiveModel + " unavailable (" + parsed.error.code + "). Retrying with gemini-3.5-flash-lite...", "#dcdcaa")
                    sendToGemini("gemini-3.5-flash-lite")
                    return
                }
                logMessage("ERR", "Gemini API Error (" + parsed.error.code + "): " + parsed.error.message, "#f48771")
                return
            }

            var replyText = parsed.candidates[0].content.parts[0].text
            var explanation = ""
            var extractedCode = ""

            var expMatch = replyText.match(/<explanation>([\s\S]*?)<\/explanation>/i)
            if (expMatch) {
                explanation = expMatch[1].trim()
            }

            var codeMatch = replyText.match(/<code>([\s\S]*?)<\/code>/i)
            if (codeMatch) {
                extractedCode = codeMatch[1].trim()
            } else {
                var fence = codeFence()
                var firstFence = replyText.indexOf(fence)
                if (firstFence !== -1) {
                    if (!explanation) {
                        explanation = replyText.substring(0, firstFence).trim()
                    }
                    var codeStart = replyText.indexOf("\n", firstFence)
                    var secondFence = replyText.indexOf(fence, codeStart + 1)
                    if (codeStart !== -1 && secondFence !== -1) {
                        extractedCode = replyText.substring(codeStart + 1, secondFence).trim()
                    } else if (codeStart !== -1) {
                        extractedCode = replyText.substring(codeStart + 1).trim()
                    }
                } else {
                    var importIdx = replyText.search(/^\s*import\s+/m)
                    if (importIdx !== -1) {
                        if (!explanation && importIdx > 0) {
                            explanation = replyText.substring(0, importIdx).trim()
                        }
                        extractedCode = replyText.substring(importIdx).trim()
                    }
                }
            }

            var fenceStr = codeFence()
            if (extractedCode.indexOf(fenceStr) === 0) {
                extractedCode = extractedCode.replace(/^```[a-zA-Z]*\s*\n?/, "").replace(/\n?```\s*$/, "").trim()
            }

            if (explanation.length > 0) {
                logMessage("GEMINI", explanation, "#c586c0")
            }

            if (extractedCode.indexOf("import ") !== -1 && extractedCode.indexOf("{") !== -1) {
                if (pendingAiPrompt !== "") {
                    var modelSummary = explanation.length > 0
                        ? explanation
                        : "Updated the QML plugin code as requested."
                    var nextHist = aiChatHistory.slice()
                    nextHist.push({ role: "user", parts: [{ text: pendingAiPrompt }] })
                    nextHist.push({ role: "model", parts: [{ text: modelSummary }] })
                    aiChatHistory = nextHist
                    pendingAiPrompt = ""
                }

                aiPromptField.text = ""
                aiPromptField.forceActiveFocus()
                clearDebugState()
                editor.text = normalizeLoadedText(extractedCode)
                resetEditorView()
                lastErrorText = ""

                autosaveTimer.stop()
                writeBackupTempFile()

                logMessage("INFO", "Editor updated by " + aiActiveModel + " (backup saved). Press Ctrl+R to run.", "#b5cea8")
            } else {
                logMessage("WARN", "Gemini replied without a recognizable QML file; editor was not overwritten:\n" + replyText, "#dcdcaa")
            }
        } catch (e) {
            logMessage("ERR", "Failed to parse Gemini response: " + e.toString(), "#f48771")
        }
    }

    // ------------------------------------------------------------------
    //  Runner, Call-Stack PC State-Machine Stepper (Over / Into / Out)
    // ------------------------------------------------------------------

    function escapeHtml(str) {
        return String(str)
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
    }

    function formatValue(val) {
        if (val === undefined) return "undefined"
        if (val === null) return "null"
        if (typeof val === "object") {
            try {
                return JSON.stringify(val)
            } catch (e) {
                return String(val)
            }
        }
        return String(val)
    }

    function logMessage(level, msg, colorHex) {
        var timestamp = new Date().toLocaleTimeString(Qt.locale(), "hh:mm:ss")
        var color = colorHex || "#d4d4d4"
        var line = '<span style="color:#808080;">[' + timestamp + ']</span> '
                 + '<span style="color:' + color + '; font-weight:bold;">[' + level + ']</span> '
                 + '<span style="color:' + color + ';">' + escapeHtml(msg) + '</span><br/>'
        consoleLog.append(line)
        consoleFlick.contentY = Math.max(0, consoleFlick.contentHeight - consoleFlick.height)
    }

    function copyConsoleToClipboard() {
        if (consoleLog.selectionStart === consoleLog.selectionEnd) {
            consoleLog.selectAll()
            consoleLog.copy()
            consoleLog.deselect()
        } else {
            consoleLog.copy()
        }
        logMessage("INFO", "Console text copied to clipboard.", "#b5cea8")
    }

    function pauseAtCurrentMachine(reason) {
        if (!activeMachine || activeMachine.pc < 0) return
        isStepping = true
        stepMode = "none"
        debugActiveLine = activeMachine.lines[activeMachine.pc] || -1
        updateLineVisuals()
        scrollEditorToRect(debugActiveRect)
        logMessage("STEP", reason + " line " + debugActiveLine + " (" + activeMachine.label + ")  [F10=Over, F11=Into, Shift+F11=Out]", "#4ec9b0")
    }

    function advancePastHelperStates() {
        var guard = 0
        while (activeMachine && activeMachine.pc >= 0 && (activeMachine.lines[activeMachine.pc] || -1) === -1 && guard < 1000) {
            activeMachine.step()
            guard++
        }
    }

    function beginMachine(machine, label) {
        if (!machine) return
        machine.label = label || "handler"

        if (activeMachine && activeMachine !== machine && activeMachine.pc >= 0) {
            machineStack.push(activeMachine)
        }
        activeMachine = machine

        if (stepMode === "into") {
            try {
                advancePastHelperStates()
            } catch (err0) {
                clearDebugState()
                lastErrorText = err0.toString()
                logMessage("ERR", "Runtime error entering " + machine.label + ": " + lastErrorText, "#f48771")
                return
            }
            if (activeMachine && activeMachine.pc >= 0) {
                pauseAtCurrentMachine("Stepped into")
                return
            }
        }

        var guard = 0
        while (machine.pc >= 0 && !root.isStepping && guard < 100000) {
            var curLine = machine.lines[machine.pc] || -1
            if (hasBreakpoint(curLine)) {
                pauseAtCurrentMachine("Paused at breakpoint")
                return
            }
            try {
                machine.step()
            } catch (err) {
                clearDebugState()
                lastErrorText = err.toString()
                logMessage("ERR", "Runtime error before breakpoint (line " + curLine + "): " + lastErrorText, "#f48771")
                return
            }
            guard++
        }

        if (guard >= 100000) {
            clearDebugState()
            logMessage("WARN", "Execution halted after 100,000 steps (possible infinite loop).", "#dcdcaa")
            return
        }

        if (root.isStepping) {
            return
        }

        if (machineStack.length > 0) {
            activeMachine = machineStack.pop()
        } else {
            clearDebugState()
        }
    }

    function runUntilStopCondition(mode, targetDepth) {
        if (!activeMachine) return
        var firstStep = true
        isStepping = false
        stepMode = mode
        stepTargetDepth = targetDepth

        var guard = 0
        while (activeMachine && guard < 100000) {
            if (activeMachine.pc < 0) {
                var finishedRetVal = activeMachine.retVal
                if (machineStack.length > 0) {
                    activeMachine = machineStack.pop()
                    if (activeMachine.applyRetVal) {
                        activeMachine.applyRetVal(finishedRetVal)
                        activeMachine.applyRetVal = null
                    }
                    firstStep = false
                    continue
                } else {
                    break
                }
            }

            var curDepth = machineStack.length
            var curLine = activeMachine.lines[activeMachine.pc] || -1

            if (!firstStep && hasBreakpoint(curLine)) {
                pauseAtCurrentMachine("Paused at breakpoint")
                return
            }

            if (!firstStep && curLine !== -1) {
                if (mode === "into") {
                    pauseAtCurrentMachine("Line")
                    return
                }
                if (mode === "over" && curDepth <= targetDepth) {
                    pauseAtCurrentMachine(curDepth < targetDepth ? "Returned to" : "Line")
                    return
                }
                if (mode === "out" && curDepth < targetDepth) {
                    pauseAtCurrentMachine("Stepped out to")
                    return
                }
            }

            firstStep = false

            try {
                activeMachine.step()
            } catch (err) {
                clearDebugState()
                lastErrorText = err.toString()
                logMessage("ERR", "Runtime error at line " + curLine + ": " + lastErrorText, "#f48771")
                return
            }

            if (root.isStepping) {
                return
            }
            guard++
        }

        if (guard >= 100000) {
            clearDebugState()
            logMessage("WARN", "Execution halted after 100,000 steps (possible infinite loop).", "#dcdcaa")
            return
        }

        var finishedLabel = activeMachine ? activeMachine.label : "handler"
        clearDebugState()
        logMessage("STEP", "Completed " + finishedLabel + ".", "#b5cea8")
    }

    function stepOver() {
        runUntilStopCondition("over", machineStack.length)
    }

    function stepInto() {
        runUntilStopCondition("into", machineStack.length)
    }

    function stepOut() {
        runUntilStopCondition("out", machineStack.length)
    }

    function continueGenerator() {
        runUntilStopCondition("continue", -1)
    }

    function findMatchingDelim(src, openIdx, openCh, closeCh) {
        var depth = 1
        var i = openIdx + 1
        var inStr = ""
        var inLineComment = false
        var inBlockComment = false

        while (i < src.length && depth > 0) {
            var ch = src[i]
            var nextCh = (i + 1 < src.length) ? src[i + 1] : ""

            if (inLineComment) {
                if (ch === "\n") inLineComment = false
            } else if (inBlockComment) {
                if (ch === "*" && nextCh === "/") {
                    inBlockComment = false
                    i++
                }
            } else if (inStr !== "") {
                if (ch === "\\") {
                    i++
                } else if (ch === inStr) {
                    inStr = ""
                }
            } else {
                if (ch === "/" && nextCh === "/") {
                    inLineComment = true
                    i++
                } else if (ch === "/" && nextCh === "*") {
                    inBlockComment = true
                    i++
                } else if (ch === '"' || ch === "'") {
                    inStr = ch
                } else if (ch === openCh) {
                    depth++
                } else if (ch === closeCh) {
                    depth--
                }
            }
            i++
        }
        return (depth === 0) ? (i - 1) : -1
    }

    function findMatchingBrace(src, openBraceIdx) {
        return findMatchingDelim(src, openBraceIdx, "{", "}")
    }

    function parseBlockToNodes(blockSrc, baseLine) {
        var nodes = []
        var i = 0
        var n = blockSrc.length

        function skipWsAndComments(pos) {
            while (pos < n) {
                var c = blockSrc[pos]
                var nc = (pos + 1 < n) ? blockSrc[pos + 1] : ""
                if (/\s/.test(c)) {
                    pos++
                } else if (c === "/" && nc === "/") {
                    pos += 2
                    while (pos < n && blockSrc[pos] !== "\n") pos++
                } else if (c === "/" && nc === "*") {
                    pos += 2
                    while (pos + 1 < n && !(blockSrc[pos] === "*" && blockSrc[pos + 1] === "/")) pos++
                    pos += 2
                } else {
                    break
                }
            }
            return pos
        }

        function parseIfAt(pos) {
            var ifLine = baseLine + lineNumberAtOffset(blockSrc, pos) - 1
            var restIf = blockSrc.substring(pos)
            var ifM = restIf.match(/^if\s*\(/)
            if (!ifM) return null
            var openP = pos + ifM[0].length - 1
            var closeP = findMatchingDelim(blockSrc, openP, "(", ")")
            if (closeP === -1) return null
            var condStr = blockSrc.substring(openP + 1, closeP)
            var thenRes = readBracedOrSingle(closeP + 1)
            var nextP = skipWsAndComments(thenRes.nextPos)
            var elseNodes = []
            if (blockSrc.substring(nextP).match(/^else\b/)) {
                nextP = skipWsAndComments(nextP + 4)
                if (blockSrc.substring(nextP).match(/^if\s*\(/)) {
                    var nestedIf = parseIfAt(nextP)
                    if (nestedIf) {
                        elseNodes = [nestedIf.node]
                        nextP = nestedIf.nextPos
                    }
                } else {
                    var elseRes = readBracedOrSingle(nextP)
                    elseNodes = elseRes.nodes
                    nextP = elseRes.nextPos
                }
            }
            return {
                node: { type: "if", cond: condStr, line: ifLine, thenNodes: thenRes.nodes, elseNodes: elseNodes },
                nextPos: nextP
            }
        }

        function readBracedOrSingle(pos) {
            pos = skipWsAndComments(pos)
            var subBaseLine = baseLine + lineNumberAtOffset(blockSrc, pos) - 1
            if (pos < n && blockSrc[pos] === "{") {
                var endB = findMatchingDelim(blockSrc, pos, "{", "}")
                if (endB !== -1) {
                    var inner = blockSrc.substring(pos + 1, endB)
                    var innerBase = baseLine + lineNumberAtOffset(blockSrc, pos + 1) - 1
                    return { nodes: parseBlockToNodes(inner, innerBase), nextPos: endB + 1 }
                }
            }
            var sEnd = pos
            var d = 0
            var str = ""
            while (sEnd < n) {
                var ch = blockSrc[sEnd]
                if (str !== "") {
                    if (ch === "\\") sEnd++
                    else if (ch === str) str = ""
                } else if (ch === '"' || ch === "'") {
                    str = ch
                } else if (ch === "(" || ch === "[" || ch === "{") {
                    d++
                } else if (ch === ")" || ch === "]" || ch === "}") {
                    d--
                } else if (d === 0 && (ch === ";" || ch === "\n")) {
                    sEnd++
                    break
                }
                sEnd++
            }
            var singleCode = blockSrc.substring(pos, sEnd)
            return {
                nodes: singleCode.trim().length > 0 ? [{ type: "stmt", code: singleCode, line: subBaseLine }] : [],
                nextPos: sEnd
            }
        }

        while (i < n) {
            i = skipWsAndComments(i)
            if (i >= n) break

            var curLine = baseLine + lineNumberAtOffset(blockSrc, i) - 1
            var rest = blockSrc.substring(i)

            var fnM = rest.match(/^function\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(([^)]*)\)\s*\{/)
            if (fnM) {
                var fOpenB = i + fnM[0].length - 1
                var fCloseB = findMatchingDelim(blockSrc, fOpenB, "{", "}")
                if (fCloseB !== -1) {
                    var fullFnSrc = blockSrc.substring(i, fCloseB + 1)
                    var subMachine = compileBlockToMachineCode(blockSrc, i, fOpenB, fCloseB, false, fnM[1], fnM[2], baseLine - 1)
                    nodes.push({
                        type: "funcDecl",
                        code: subMachine || fullFnSrc,
                        line: curLine
                    })
                    i = fCloseB + 1
                    continue
                }
            }

            if (rest.match(/^if\s*\(/)) {
                var parsedIf = parseIfAt(i)
                if (parsedIf) {
                    nodes.push(parsedIf.node)
                    i = parsedIf.nextPos
                    continue
                }
            }

            var whileM = rest.match(/^while\s*\(/)
            if (whileM) {
                var wOpenP = i + whileM[0].length - 1
                var wCloseP = findMatchingDelim(blockSrc, wOpenP, "(", ")")
                if (wCloseP !== -1) {
                    var wCond = blockSrc.substring(wOpenP + 1, wCloseP)
                    var bodyRes = readBracedOrSingle(wCloseP + 1)
                    i = bodyRes.nextPos
                    nodes.push({ type: "while", cond: wCond, line: curLine, bodyNodes: bodyRes.nodes })
                    continue
                }
            }

            var forM = rest.match(/^for\s*\(/)
            if (forM) {
                var fOpenP = i + forM[0].length - 1
                var fCloseP = findMatchingDelim(blockSrc, fOpenP, "(", ")")
                if (fCloseP !== -1) {
                    var header = blockSrc.substring(fOpenP + 1, fCloseP)
                    var parts = header.split(";")
                    if (parts.length === 3) {
                        var fBody = readBracedOrSingle(fCloseP + 1)
                        i = fBody.nextPos
                        nodes.push({
                            type: "for",
                            init: parts[0].trim(),
                            cond: parts[1].trim() || "true",
                            update: parts[2].trim(),
                            line: curLine,
                            bodyNodes: fBody.nodes
                        })
                        continue
                    }
                    var inOfM = header.match(/^\s*(?:var|let|const)?\s*([A-Za-z_$][A-Za-z0-9_$]*)\s+(in|of)\s+([\s\S]+)$/)
                    if (inOfM) {
                        var iterVar = inOfM[1]
                        var iterKind = inOfM[2]
                        var iterExpr = inOfM[3].trim()
                        var fBody2 = readBracedOrSingle(fCloseP + 1)
                        i = fBody2.nextPos
                        var tmpList = "__list_" + curLine + "_" + i
                        var tmpIdx = "__idx_" + curLine + "_" + i
                        var initStr = (iterKind === "in")
                            ? ("var " + tmpList + " = Object.keys(" + iterExpr + "); var " + tmpIdx + " = 0")
                            : ("var " + tmpList + " = Array.from(" + iterExpr + "); var " + tmpIdx + " = 0")
                        var assignStmt = {
                            type: "stmt",
                            code: "var " + iterVar + " = " + tmpList + "[" + tmpIdx + "];",
                            line: curLine
                        }
                        nodes.push({
                            type: "for",
                            init: initStr,
                            cond: tmpIdx + " < " + tmpList + ".length",
                            update: tmpIdx + "++",
                            line: curLine,
                            bodyNodes: [assignStmt].concat(fBody2.nodes)
                        })
                        continue
                    }
                }
            }

            var startStmt = i
            var depth = 0
            var inStr = ""
            var inLC = false
            var inBC = false
            while (i < n) {
                var ch = blockSrc[i]
                var nc = (i + 1 < n) ? blockSrc[i + 1] : ""
                if (inLC) {
                    if (ch === "\n") {
                        inLC = false
                        if (depth === 0) {
                            var soFarLc = blockSrc.substring(startStmt, i).replace(/\/\/[^\n]*/g, "").trim()
                            var afterLc = skipWsAndComments(i + 1)
                            var nextChLc = afterLc < n ? blockSrc[afterLc] : ""
                            var nextTwoLc = afterLc + 1 < n ? blockSrc.substring(afterLc, afterLc + 2) : ""
                            var endsOpLc = /[?:+\-*/%&|=.,]$/.test(soFarLc)
                            var startsOpLc = (nextChLc === "?" || nextChLc === ":" || nextChLc === "." ||
                                              nextTwoLc === "&&" || nextTwoLc === "||")
                            if (!endsOpLc && !startsOpLc) {
                                i++
                                break
                            }
                        }
                    }
                } else if (inBC) {
                    if (ch === "*" && nc === "/") { inBC = false; i++ }
                } else if (inStr !== "") {
                    if (ch === "\\") i++
                    else if (ch === inStr) inStr = ""
                } else {
                    if (ch === "/" && nc === "/") { inLC = true; i++ }
                    else if (ch === "/" && nc === "*") { inBC = true; i++ }
                    else if (ch === '"' || ch === "'") inStr = ch
                    else if (ch === "{" || ch === "(" || ch === "[") depth++
                    else if (ch === "}" || ch === ")" || ch === "]") depth--
                    else if (depth === 0 && ch === ";") {
                        i++
                        break
                    } else if (depth === 0 && ch === "\n") {
                        var soFar = blockSrc.substring(startStmt, i).replace(/\/\/[^\n]*/g, "").trim()
                        var afterNl = skipWsAndComments(i + 1)
                        var nextChAfterNl = afterNl < n ? blockSrc[afterNl] : ""
                        var nextTwoAfterNl = afterNl + 1 < n ? blockSrc.substring(afterNl, afterNl + 2) : ""
                        var endsWithOp = /[?:+\-*/%&|=.,]$/.test(soFar)
                        var startsWithOp = (nextChAfterNl === "?" || nextChAfterNl === ":" || nextChAfterNl === "." ||
                                            nextTwoAfterNl === "&&" || nextTwoAfterNl === "||")
                        if (!endsWithOp && !startsWithOp) {
                            i++
                            break
                        }
                    }
                }
                i++
            }
            var stmtCode = blockSrc.substring(startStmt, i)
            var cleanCheck = stmtCode.replace(/\/\/[^\n]*/g, "").replace(/\/\*[\s\S]*?\*\//g, "").trim()
            if (cleanCheck.length > 0) {
                nodes.push({ type: "stmt", code: stmtCode, line: curLine })
            }
        }
        return nodes
    }

    function compileBlockToMachineCode(src, matchIndex, openBraceIdx, closeBraceIdx, isSignal, targetName, fnParams, lineOffset) {
        var extraOffset = lineOffset || 0
        var body = src.substring(openBraceIdx + 1, closeBraceIdx)
        var bodyBaseLine = extraOffset + lineNumberAtOffset(src, openBraceIdx + 1)
        var astNodes = parseBlockToNodes(body, bodyBaseLine)
        if (astNodes.length === 0) return null

        var nestedFuncs = []
        var execNodes = []
        for (var nIdx = 0; nIdx < astNodes.length; ++nIdx) {
            if (astNodes[nIdx].type === "funcDecl") {
                nestedFuncs.push(astNodes[nIdx].code)
            } else {
                execNodes.push(astNodes[nIdx])
            }
        }

        var sharedVars = {}
        function hoistVars(code) {
            return code.replace(/\b(?:var|let|const)\s+([A-Za-z_$][A-Za-z0-9_$]*)/g, function(_, vName) {
                sharedVars[vName] = true
                return vName
            })
        }

        var states = []
        function allocState(lineNum) {
            var id = states.length
            states.push({ id: id, line: lineNum, code: "" })
            return id
        }

        function compileList(nodeList, exitPc, breakPc, continuePc) {
            if (!nodeList || nodeList.length === 0) return exitPc
            var nextEntry = exitPc
            for (var idx = nodeList.length - 1; idx >= 0; --idx) {
                nextEntry = compileNode(nodeList[idx], nextEntry, breakPc, continuePc)
            }
            return nextEntry
        }

        function compileNode(node, nextPc, breakPc, continuePc) {
            if (node.type === "stmt") {
                var stId = allocState(node.line)
                var c = hoistVars(node.code).trim()
                if (/^return\b/.test(c)) {
                    var retExpr = c.replace(/^return\b/, "").replace(/;$/, "").trim()
                    states[stId].code = (retExpr ? ("this.retVal = (" + retExpr + "); ") : "") + "this.pc = -1; return;"
                } else if (/^break\s*;?$/.test(c) && breakPc !== undefined && breakPc !== -1) {
                    states[stId].code = "this.pc = " + breakPc + ";"
                } else if (/^continue\s*;?$/.test(c) && continuePc !== undefined && continuePc !== -1) {
                    states[stId].code = "this.pc = " + continuePc + ";"
                } else {
                    if (!c.endsWith(";")) c += ";"
                    var assignMatch = c.match(/^([A-Za-z_$][A-Za-z0-9_$.]*)\s*=\s*([A-Za-z_$][A-Za-z0-9_$.]*\s*\([\s\S]*\))\s*;$/)
                    if (assignMatch) {
                        var lhs = assignMatch[1]
                        states[stId].code = "this.pc = " + nextPc + "; "
                            + "this.applyRetVal = function(v) { " + lhs + " = v; }; "
                            + c + " if (!root.isStepping) this.applyRetVal = null;"
                    } else {
                        states[stId].code = "this.pc = " + nextPc + "; " + c
                    }
                }
                return stId
            }

            if (node.type === "if") {
                var branchId = allocState(node.line)
                var thenPc = compileList(node.thenNodes, nextPc, breakPc, continuePc)
                var elsePc = (node.elseNodes && node.elseNodes.length > 0)
                           ? compileList(node.elseNodes, nextPc, breakPc, continuePc)
                           : nextPc
                states[branchId].code = "this.pc = (" + node.cond + ") ? " + thenPc + " : " + elsePc + ";"
                return branchId
            }

            if (node.type === "while") {
                var condId = allocState(node.line)
                var bodyPc = compileList(node.bodyNodes, condId, nextPc, condId)
                states[condId].code = "this.pc = (" + node.cond + ") ? " + bodyPc + " : " + nextPc + ";"
                return condId
            }

            if (node.type === "for") {
                var initId = node.init ? allocState(node.line) : -1
                var fCondId = allocState(node.line)
                var updId = node.update ? allocState(node.line) : fCondId
                var fBodyPc = compileList(node.bodyNodes, updId, nextPc, updId)

                if (node.update) {
                    var uCode = hoistVars(node.update)
                    if (!uCode.endsWith(";")) uCode += ";"
                    states[updId].code = uCode + " this.pc = " + fCondId + ";"
                }
                states[fCondId].code = "this.pc = (" + node.cond + ") ? " + fBodyPc + " : " + nextPc + ";"
                if (initId !== -1) {
                    var iCode = hoistVars(node.init)
                    if (!iCode.endsWith(";")) iCode += ";"
                    states[initId].code = iCode + " this.pc = " + fCondId + ";"
                    return initId
                }
                return fCondId
            }

            return nextPc
        }

        var entryPc = compileList(execNodes, -1, -1, -1)

        var lineMapPairs = []
        var caseClauses = []
        for (var s = 0; s < states.length; ++s) {
            lineMapPairs.push(states[s].id + ": " + states[s].line)
            caseClauses.push("case " + states[s].id + ": " + states[s].code + " break;")
        }

        var varHeader = Object.keys(sharedVars).length > 0
            ? ("var " + Object.keys(sharedVars).join(", ") + "; ")
            : ""

        var fnHeader = nestedFuncs.length > 0
            ? (nestedFuncs.join(" ") + " ")
            : ""

        var origNewlines = (src.substring(matchIndex, closeBraceIdx + 1).match(/\n/g) || []).length
        var generatedNewlines = (fnHeader.match(/\n/g) || []).length
        var padCount = Math.max(0, origNewlines - generatedNewlines)
        var padNewlines = ""
        for (var nl = 0; nl < padCount; ++nl) padNewlines += "\n"

        var paramNames = fnParams
            ? fnParams.split(",").map(function(p) { return p.trim().split("=")[0].trim() }).filter(function(p) { return p.length > 0 })
            : []
        var allLocalsMap = {}
        for (var pIdx = 0; pIdx < paramNames.length; ++pIdx) allLocalsMap[paramNames[pIdx]] = true
        var hoistedKeys = Object.keys(sharedVars)
        for (var hIdx = 0; hIdx < hoistedKeys.length; ++hIdx) allLocalsMap[hoistedKeys[hIdx]] = true
        var localNamesJson = JSON.stringify(Object.keys(allLocalsMap))

        var headerPrefix = isSignal
            ? (targetName + ": { ")
            : ("function " + targetName + "(" + fnParams + ") { ")

        var returnSuffix = isSignal ? "" : " return __m.retVal;"

        return headerPrefix + varHeader + fnHeader
            + "var __m = { pc: " + entryPc + ", retVal: undefined, applyRetVal: null"
            + ", localNames: " + localNamesJson
            + ", evalLocal: function(__expr) { try { return eval(\"(\" + __expr + \")\"); } catch (e) { if (e instanceof SyntaxError) return eval(__expr); throw e; } }"
            + ", lines: { " + lineMapPairs.join(", ") + " }"
            + ", step: function() { switch (this.pc) { " + caseClauses.join(" ") + " default: this.pc = -1; } }"
            + " }; sandboxConsole.runMachine(__m, \"" + targetName + "\");" + returnSuffix + padNewlines + "}"
    }

    function instrumentBreakpointHandlers(src, bpLines) {
        if (!bpLines || bpLines.length === 0) return src

        var pattern = /\b(?:(on[A-Z][A-Za-z0-9_]*)\s*:\s*\{|function\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(([^)]*)\)\s*\{)/g
        var match
        var out = ""
        var lastIdx = 0

        while ((match = pattern.exec(src)) !== null) {
            var isSignal = !!match[1]
            var targetName = isSignal ? match[1] : match[2]
            var fnParams = isSignal ? "" : match[3]
            var openBraceIdx = pattern.lastIndex - 1
            var closeBraceIdx = findMatchingBrace(src, openBraceIdx)
            if (closeBraceIdx === -1) break

            var replacement = compileBlockToMachineCode(src, match.index, openBraceIdx, closeBraceIdx, isSignal, targetName, fnParams, 0)
            if (replacement) {
                out += src.substring(lastIdx, match.index) + replacement
                lastIdx = closeBraceIdx + 1
            }
            pattern.lastIndex = closeBraceIdx + 1
        }

        out += src.substring(lastIdx)
        return out
    }

    function runCode() {
        stopCode(true)
        lastErrorText = ""
        logMessage("INFO", "Compiling and running" + (popOutPreview ? " in floating window..." : "..."), "#b5cea8")
        runDelayTimer.restart()
    }

    function executeRunCode() {
        var instrumentedCode = instrumentBreakpointHandlers(editor.text, breakpointLines)
            .replace(/\bconsole\.(log|warn|error)\s*\(/g, "sandboxConsole.$1(")
            .replace(/\b(?:root\.)?quit\s*\(\s*\)/g, "root.sandboxQuit()")

        try {
            var baseUrl = currentFilePath ? ("file:///" + currentFilePath.replace(/^\//, "")) : "file:///sandbox.qml"
            var targetParent = popOutPreview ? ensureFloatingWindow().hostItem : sandboxHost

            var obj = Qt.createQmlObject(instrumentedCode, targetParent, baseUrl)
            activeInstance = obj

            if (obj && obj.Keys) {
                obj.Keys.shortcutOverride.connect(function(e) {
                    if (e.key === Qt.Key_Escape) e.accepted = true
                })
                obj.Keys.pressed.connect(function(e) {
                    if (e.key === Qt.Key_Escape) e.accepted = true
                })
            }

            if (popOutPreview) {
                sizeAndShowFloatingWindow(obj)
            } else if ((obj.implicitWidth && obj.implicitWidth > 540) || (obj.implicitHeight && obj.implicitHeight > 440)) {
                logMessage("INFO", "Plugin UI is " + (obj.implicitWidth || obj.width) + "x" + (obj.implicitHeight || obj.height)
                    + " - click 'Float' in toolbar for full-window view.", "#9cdcfe")
            }

            if (typeof obj.onRun === "function") {
                obj.onRun()
            } else if (typeof obj.run === "function") {
                obj.run()
            }
        } catch (err) {
            if (err.qmlErrors) {
                var errs = []
                for (var i = 0; i < err.qmlErrors.length; ++i) {
                    var e = err.qmlErrors[i]
                    var msg = "Line " + e.lineNumber + ":" + e.columnNumber + " - " + e.message
                    errs.push(msg)
                    logMessage("SYNTAX", msg, "#f48771")
                }
                lastErrorText = errs.join("\n")
            } else {
                lastErrorText = err.toString()
                logMessage("ERR", lastErrorText, "#f48771")
            }
        }
    }

    function evalInPluginContext(expr) {
        if (replBusy) return
        var trimmed = expr.trim()
        if (trimmed === "") return

        if (replHistory.length === 0 || replHistory[replHistory.length - 1] !== trimmed) {
            replHistory.push(trimmed)
        }
        replHistoryIdx = replHistory.length

        replInput.text = ""
        pendingReplExpr = trimmed
        replBusy = true
        logMessage("REPL", "> " + trimmed, "#dcdcaa")
        replEvalTimer.restart()
    }

    function executePendingRepl() {
        var trimmed = pendingReplExpr
        pendingReplExpr = ""
        if (trimmed === "") {
            replBusy = false
            return
        }

        try {
            var result
            if (isStepping && activeMachine && activeMachine.evalLocal) {
                try {
                    result = activeMachine.evalLocal(trimmed)
                } catch (localErr) {
                    if (activeInstance && localErr instanceof ReferenceError) {
                        var names = activeMachine.localNames || []
                        var vals = names.map(function(n) { return activeMachine.evalLocal(n) })
                        var args = ["target"].concat(names)
                        try {
                            var hybridExpr = new Function(args.join(", "), "with (target) { return (" + trimmed + "); }")
                            result = hybridExpr.apply(null, [activeInstance].concat(vals))
                        } catch (syntaxErr) {
                            var hybridStmt = new Function(args.join(", "), "with (target) { " + trimmed + " }")
                            result = hybridStmt.apply(null, [activeInstance].concat(vals))
                        }
                    } else {
                        throw localErr
                    }
                }
            } else if (activeInstance) {
                try {
                    var exprFn = new Function("target", "with (target) { return (" + trimmed + "); }")
                    result = exprFn(activeInstance)
                } catch (syntaxErr) {
                    var stmtFn = new Function("target", "with (target) { " + trimmed + " }")
                    result = stmtFn(activeInstance)
                }
            } else {
                result = eval(trimmed)
            }
            logMessage("RES", formatValue(result), "#4ec9b0")
        } catch (err) {
            logMessage("ERR", err.toString(), "#f48771")
        } finally {
            replBusy = false
            replInput.forceActiveFocus()
        }
    }

    Rectangle {
        anchors.fill: parent
        color: ui.theme.backgroundPrimaryColor
    }

    ColumnLayout {
        id: mainCol
        anchors.fill: parent
        anchors.margins: 10
        spacing: 6
        focus: true

        // Tier 1 Top Toolbar: Side-Park + File Actions + External Tracking + Gemini Toggle
        RowLayout {
            Layout.fillWidth: true
            Layout.maximumWidth: mainCol.width
            spacing: 5

            ToolBtn {
                id: parkBtn
                text: root.isParkedSide ? "|←" : "→|"
                tip: root.isParkedSide ? "Slide Plugin Creator back into view" : "Slide window to right edge to inspect score"
                accent: root.isParkedSide
                onClicked: root.toggleParkWindow()
            }
            ToolBtn {
                text: "New"
                tip: "Start a new plugin buffer"
                onClicked: root.newBuffer()
            }
            ToolBtn {
                text: "Open..."
                tip: "Open an existing QML plugin (Ctrl+O)"
                onClicked: root.openPluginFile()
            }
            ToolBtn {
                text: "Save"
                tip: "Save current plugin (Ctrl+S)"
                onClicked: root.saveCurrentFile()
            }
            ToolBtn {
                text: "Find / Replace"
                tip: "Find & Replace text in editor (Ctrl+F / Ctrl+H)"
                onClicked: root.toggleFind(false, false)
            }

            MU.CheckBox {
                id: trackExternalBox
                text: "Track external"
                checked: root.trackExternalChanges
                onClicked: {
                    root.trackExternalChanges = !root.trackExternalChanges
                    if (root.trackExternalChanges && root.currentFilePath) {
                        root.checkExternalFileChange()
                    }
                }
            }

            Item { Layout.fillWidth: true }

            ToolBtn {
                visible: root.externalChangePending
                text: "↻ Reload External"
                tip: "File changed on disk — click to replace your unsaved edits with the external version"
                activeToggle: true
                onClicked: root.applyPendingExternalReload()
            }

            MU.StyledTextLabel {
                text: (root.currentFilePath ? root.currentFilePath.split("/").pop() : "Unsaved Buffer")
                      + (root.isDirty ? " ●" : "")
                font.pixelSize: 11
                font.bold: root.isDirty
                opacity: root.isDirty ? 1.0 : 0.75
            }

            ToolBtn {
                text: root.showAiBar ? "Hide Gemini" : "Ask Gemini"
                tip: "Toggle Gemini AI assistant bar"
                onClicked: root.showAiBar = !root.showAiBar
            }
        }

        // Collapsible Gemini AI Bar (Strictly Bounded to Window Width)
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredWidth: 0
            Layout.maximumWidth: mainCol.width
            implicitHeight: 122
            visible: root.showAiBar
            color: ui.theme.backgroundSecondaryColor
            border.color: ui.theme.accentColor
            border.width: 1
            radius: 4
            clip: true

            Item {
                id: aiTopRow
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 7
                height: 74

                MU.StyledTextLabel {
                    id: promptLabel
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.topMargin: 4
                    text: "Gemini Prompt:"
                }

                Column {
                    id: aiBtnCol
                    anchors.top: parent.top
                    anchors.right: parent.right
                    width: 145
                    spacing: 5

                    ToolBtn {
                        width: parent.width
                        text: root.aiBusy ? "Thinking..." : "Send (Enter)"
                        accent: true
                        enabled: !root.aiBusy
                        onClicked: root.sendToGemini()
                    }

                    MU.CheckBox {
                        id: explainCheckBox
                        width: parent.width
                        text: "Explain changes"
                        checked: true
                        onClicked: checked = !checked
                    }
                }

                Rectangle {
                    id: promptBox
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.left: promptLabel.right
                    anchors.right: aiBtnCol.left
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    color: ui.theme.textFieldColor
                    border.color: aiPromptField.activeFocus ? ui.theme.accentColor : ui.theme.strokeColor
                    border.width: 1
                    radius: 3
                    clip: true

                    Flickable {
                        id: aiPromptFlick
                        anchors.fill: parent
                        anchors.margins: 5
                        contentWidth: width
                        contentHeight: aiPromptField.implicitHeight
                        clip: true

                        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

                        TextEdit {
                            id: aiPromptField
                            width: aiPromptFlick.width
                            enabled: !root.aiBusy
                            opacity: root.aiBusy ? 0.55 : 1.0
                            color: ui.theme.fontPrimaryColor
                            font: ui.theme.bodyFont
                            selectByMouse: true
                            wrapMode: TextEdit.Wrap

                            Text {
                                anchors.fill: parent
                                text: "Describe what you want to add or fix (Enter to send, Shift+Enter for newline)..."
                                color: ui.theme.fontPrimaryColor
                                font: ui.theme.bodyFont
                                opacity: 0.45
                                visible: !aiPromptField.text && !aiPromptField.activeFocus
                            }

                            Keys.onShortcutOverride: function(e) {
                                if (((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) ||
                                    ((e.modifiers & Qt.ControlModifier) &&
                                     (e.key === Qt.Key_C || e.key === Qt.Key_V ||
                                      e.key === Qt.Key_X || e.key === Qt.Key_A))) {
                                    e.accepted = true
                                }
                            }
                            Keys.onPressed: function(e) {
                                if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                                    root.sendToGemini()
                                    e.accepted = true
                                }
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        onPressed: function(mouse) {
                            aiPromptField.forceActiveFocus()
                            mouse.accepted = false
                        }
                    }

                    Rectangle {
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 5
                        visible: root.aiBusy
                        implicitWidth: thinkingLbl.implicitWidth + 12
                        implicitHeight: thinkingLbl.implicitHeight + 4
                        radius: 3
                        color: ui.theme.accentColor

                        Text {
                            id: thinkingLbl
                            anchors.centerIn: parent
                            text: "Thinking (" + (root.aiActiveModel || "Gemini") + ")..."
                            font.family: ui.theme.bodyFont.family
                            font.pixelSize: 11
                            font.bold: true
                            color: "#ffffff"
                        }
                    }
                }
            }

            RowLayout {
                anchors.top: aiTopRow.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 7
                anchors.topMargin: 5
                spacing: 8

                MU.StyledTextLabel { text: "API Key:" }
                QQC.TextField {
                    id: apiKeyField
                    Layout.preferredWidth: 220
                    height: 24
                    echoMode: TextInput.Password
                    placeholderText: "AIzaSy..."
                    text: root.geminiApiKey
                    onTextEdited: root.geminiApiKey = text
                    color: ui.theme.fontPrimaryColor
                    font: ui.theme.bodyFont
                    selectByMouse: true
                    background: Rectangle {
                        color: ui.theme.textFieldColor
                        border.color: ui.theme.strokeColor
                        border.width: 1
                        radius: 3
                    }
                }
                MU.StyledTextLabel { text: "Model:" }
                QQC.TextField {
                    Layout.preferredWidth: 165
                    height: 24
                    text: root.geminiModel
                    onTextEdited: root.geminiModel = text
                    color: ui.theme.fontPrimaryColor
                    font: ui.theme.bodyFont
                    selectByMouse: true
                    background: Rectangle {
                        color: ui.theme.textFieldColor
                        border.color: ui.theme.strokeColor
                        border.width: 1
                        radius: 3
                    }
                }
                ToolBtn {
                    text: root.aiChatHistory.length > 0
                          ? ("Reset Chat (" + Math.floor(root.aiChatHistory.length / 2) + ")")
                          : "Reset Chat"
                    tip: "Clear Gemini multi-turn conversation history"
                    enabled: root.aiChatHistory.length > 0 && !root.aiBusy
                    onClicked: root.resetAiChat(false)
                }
                MU.StyledTextLabel {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 0
                    elide: Text.ElideRight
                    text: "Remembers recent turns + auto-saves backup."
                    opacity: 0.65
                }
            }
        }

        // Collapsible Find & Replace Bar
        Rectangle {
            Layout.fillWidth: true
            Layout.maximumWidth: mainCol.width
            implicitHeight: 64
            visible: root.showFindBar
            color: ui.theme.backgroundSecondaryColor
            border.color: ui.theme.strokeColor
            border.width: 1
            radius: 4

            ColumnLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                anchors.topMargin: 5
                anchors.bottomMargin: 5
                spacing: 4

                // Row 1: Find
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    MU.StyledTextLabel {
                        text: "Find:"
                        Layout.preferredWidth: 52
                    }
                    QQC.TextField {
                        id: findInput
                        Layout.preferredWidth: 230
                        height: 24
                        color: ui.theme.fontPrimaryColor
                        font: ui.theme.bodyFont
                        selectByMouse: true
                        background: Rectangle {
                            color: ui.theme.textFieldColor
                            border.color: findInput.activeFocus ? ui.theme.accentColor : ui.theme.strokeColor
                            border.width: 1
                            radius: 3
                        }
                        Keys.onShortcutOverride: function(e) {
                            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Escape || e.key === Qt.Key_Tab) e.accepted = true
                        }
                        Keys.onPressed: function(e) {
                            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                root.findNext(e.modifiers & Qt.ShiftModifier, true)
                                e.accepted = true
                            } else if (e.key === Qt.Key_Tab) {
                                replaceInput.forceActiveFocus()
                                replaceInput.selectAll()
                                e.accepted = true
                            } else if (e.key === Qt.Key_Escape) {
                                root.showFindBar = false
                                editor.forceActiveFocus()
                                e.accepted = true
                            }
                        }
                    }
                    ToolBtn {
                        text: "Next"
                        tip: "Find next match (Enter / F3)"
                        onClicked: root.findNext(false, true)
                    }
                    ToolBtn {
                        text: "Prev"
                        tip: "Find previous match (Shift+Enter / Shift+F3)"
                        onClicked: root.findNext(true, true)
                    }
                    MU.CheckBox {
                        id: matchCaseBox
                        text: "Match case"
                        checked: false
                        onClicked: checked = !checked
                    }
                    Item { Layout.fillWidth: true }
                    ToolBtn {
                        text: "✕"
                        tip: "Close find & replace bar (Esc)"
                        implicitWidth: 24
                        onClicked: {
                            root.showFindBar = false
                            editor.forceActiveFocus()
                        }
                    }
                }

                // Row 2: Replace
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    MU.StyledTextLabel {
                        text: "Replace:"
                        Layout.preferredWidth: 52
                    }
                    QQC.TextField {
                        id: replaceInput
                        Layout.preferredWidth: 230
                        height: 24
                        color: ui.theme.fontPrimaryColor
                        font: ui.theme.bodyFont
                        selectByMouse: true
                        background: Rectangle {
                            color: ui.theme.textFieldColor
                            border.color: replaceInput.activeFocus ? ui.theme.accentColor : ui.theme.strokeColor
                            border.width: 1
                            radius: 3
                        }
                        Keys.onShortcutOverride: function(e) {
                            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Escape || e.key === Qt.Key_Tab) e.accepted = true
                        }
                        Keys.onPressed: function(e) {
                            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                root.replaceCurrentOrNext()
                                e.accepted = true
                            } else if (e.key === Qt.Key_Tab) {
                                findInput.forceActiveFocus()
                                findInput.selectAll()
                                e.accepted = true
                            } else if (e.key === Qt.Key_Escape) {
                                root.showFindBar = false
                                editor.forceActiveFocus()
                                e.accepted = true
                            }
                        }
                    }
                    ToolBtn {
                        text: "Replace"
                        tip: "Replace current selection (or find next match)"
                        enabled: !root.isParkedSide
                        onClicked: root.replaceCurrentOrNext()
                    }
                    ToolBtn {
                        text: "Replace All"
                        tip: "Replace all matches in buffer (single Ctrl+Z undo)"
                        enabled: !root.isParkedSide
                        onClicked: root.replaceAllMatches()
                    }
                    Item { Layout.fillWidth: true }
                }
            }
        }

        // Resizable Horizontal Split: Editor (Left) | Execution & Output (Right)
        QQC.SplitView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.maximumWidth: mainCol.width
            orientation: Qt.Horizontal

            handle: Rectangle {
                implicitWidth: 6
                color: QQC.SplitHandle.pressed ? ui.theme.accentColor
                     : QQC.SplitHandle.hovered ? ui.theme.strokeColor
                     : "transparent"
                Rectangle {
                    anchors.centerIn: parent
                    width: 2
                    height: 36
                    radius: 1
                    color: ui.theme.strokeColor
                }
            }

            // Left Pane: Light-Theme Code Editor with Virtualized Syntax Highlighting & Breakpoint Gutter
            Rectangle {
                QQC.SplitView.fillWidth: true
                QQC.SplitView.minimumWidth: 260
                color: "#f2f2f2"
                border.color: "#b0b0b0"
                border.width: 1

                QQC.ScrollView {
                    id: editorScroll
                    anchors.fill: parent
                    anchors.margins: 2
                    clip: true

                    Connections {
                        target: editorScroll.contentItem
                        function onContentYChanged() {
                            root.updateVisibleHighlightSlice()
                        }
                    }

                    Row {
                        id: editorRow
                        width: Math.max(editorScroll.availableWidth, gutter.width + Math.max(200, editor.contentWidth + 32))
                        height: Math.max(editorScroll.availableHeight, Math.max(200, editor.contentHeight + 24))

                        // Line Number Gutter (Click any line number to toggle breakpoint)
                        Rectangle {
                            id: gutter
                            width: 48
                            height: parent.height
                            color: "#e4e4e4"

                            Rectangle {
                                anchors.right: parent.right
                                width: 1
                                height: parent.height
                                color: "#cccccc"
                            }

                            // Red Breakpoint Badges in Gutter
                            Repeater {
                                model: root.breakpointRects
                                Rectangle {
                                    x: 3
                                    y: modelData.rect.y
                                    width: gutter.width - 7
                                    height: modelData.rect.height
                                    radius: 3
                                    color: "#c93b3b"
                                }
                            }

                            // Amber Current-Execution Overlay in Gutter
                            Rectangle {
                                visible: root.debugActiveLine > 0 && root.debugActiveRect.height > 0
                                x: 3
                                y: root.debugActiveRect.y
                                width: parent.width - 7
                                height: root.debugActiveRect.height
                                radius: 3
                                color: "#f6c343"
                                opacity: 0.9
                            }

                            Text {
                                width: parent.width - 8
                                y: editor.topPadding
                                horizontalAlignment: Text.AlignRight
                                font: editor.font
                                color: "#666666"
                                text: {
                                    var count = Math.max(1, editor.lineCount)
                                    var lines = []
                                    for (var i = 1; i <= count; ++i) {
                                        lines.push(i)
                                    }
                                    return lines.join("\n")
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: function(mouse) {
                                    var pos = editor.positionAt(1, mouse.y)
                                    var clickedLine = root.lineNumberAtOffset(editor.text, pos)
                                    root.toggleBreakpointLine(clickedLine)
                                }
                            }
                        }

                        // Code Editor with Exact Character-Geometry Highlights & Virtualized Syntax Overlay
                        Item {
                            id: editorContainer
                            width: Math.max(editorScroll.availableWidth - gutter.width, Math.max(200, editor.contentWidth + 32))
                            height: parent.height

                            // Subtle Current-Line Highlight
                            Rectangle {
                                visible: editor.activeFocus && !root.isParkedSide
                                         && editor.cursorRectangle.height > 0 && root.debugActiveLine <= 0
                                x: 0
                                y: editor.cursorRectangle.y
                                width: parent.width
                                height: editor.cursorRectangle.height
                                color: "#e8eef5"
                            }

                            // Subtle Red Tints for All Breakpoint Lines
                            Repeater {
                                model: root.breakpointRects
                                Rectangle {
                                    visible: modelData.line !== root.debugActiveLine
                                    x: 0
                                    y: modelData.rect.y
                                    width: parent.width
                                    height: modelData.rect.height
                                    color: "#fde2e2"
                                }
                            }

                            // Bright Amber Highlight for Active Paused Line
                            Rectangle {
                                visible: root.debugActiveLine > 0 && root.debugActiveRect.height > 0
                                x: 0
                                y: root.debugActiveRect.y
                                width: parent.width
                                height: root.debugActiveRect.height
                                color: "#fff3b0"
                                border.color: "#e6c200"
                                border.width: 1
                            }

                            // Live Matching / Unmatched Bracket Highlights
                            Repeater {
                                model: root.braceMatchRects
                                Rectangle {
                                    x: modelData.rect.x
                                    y: modelData.rect.y
                                    width: modelData.rect.width
                                    height: modelData.rect.height
                                    radius: 2
                                    color: modelData.matched ? "#bfe8e2" : "#f8c7c7"
                                    border.color: modelData.matched ? "#389c8e" : "#d9534f"
                                    border.width: 1
                                }
                            }

                            // Virtualized Viewport-Only RichText Syntax Overlay
                            Text {
                                id: highlightOverlay
                                x: 0
                                y: root.highlightOverlayY
                                width: parent.width
                                topPadding: editor.topPadding
                                bottomPadding: editor.bottomPadding
                                leftPadding: editor.leftPadding
                                rightPadding: editor.rightPadding
                                font: editor.font
                                textFormat: Text.RichText
                                wrapMode: Text.NoWrap
                                opacity: root.isParkedSide ? 0.65 : 1.0
                                text: root.highlightedHtml
                            }

                            // Hidden helper for atomic single-undo selection replacement
                            TextEdit {
                                id: atomicHelper
                                visible: false
                            }

                            QQC.TextArea {
                                id: editor
                                anchors.fill: parent
                                readOnly: root.isParkedSide
                                font.family: "monospace"
                                font.pixelSize: 13
                                color: "transparent"
                                selectionColor: "#6699ccff"
                                selectedTextColor: "#000000"
                                selectByMouse: true
                                wrapMode: TextEdit.NoWrap
                                topPadding: 8
                                bottomPadding: 8
                                leftPadding: 8
                                rightPadding: 16

                                onImplicitHeightChanged: {
                                    root.updateVisibleHighlightSlice()
                                    root.updateLineVisuals()
                                }
                                onSelectionStartChanged: root.updateBraceMatches()
                                onSelectionEndChanged: root.updateBraceMatches()
                                onCursorRectangleChanged: {
                                    root.updateBraceMatches()
                                    root.ensureCursorVisibleInViewport()
                                }
                                onTextChanged: {
                                    var lineCountChanged = (editor.lineCount !== root.lastKnownLineCount)
                                    root.updateHighlightIncremental()
                                    root.currentMatchStart = -1
                                    root.currentMatchEnd = -1
                                    if (lineCountChanged) {
                                        root.updateLineVisuals()
                                    } else {
                                        root.updateBraceMatches()
                                    }
                                    root.isDirty = (editor.text !== root.cleanTextSnapshot)
                                    if (root.isDirty && !recoveryOverlay.visible) {
                                        autosaveTimer.restart()
                                    }
                                }

                                background: Rectangle {
                                    color: "transparent"
                                }

                                // Passive double-tap observer for Go-to-Definition on function calls
                                TapHandler {
                                    acceptedButtons: Qt.LeftButton
                                    onDoubleTapped: function(eventPoint, button) {
                                        var pos = editor.positionAt(eventPoint.position.x, eventPoint.position.y)
                                        var t = editor.text
                                        var start = pos
                                        var end = pos
                                        while (start > 0 && /[A-Za-z0-9_$]/.test(t[start - 1])) start--
                                        while (end < t.length && /[A-Za-z0-9_$]/.test(t[end])) end++
                                        var word = t.substring(start, end)
                                        if (word.length > 0 && /^\s*\(/.test(t.substring(end))) {
                                            root.jumpToFunctionDefinition(word)
                                        }
                                    }
                                }

                                Keys.onShortcutOverride: function(event) {
                                    if (!root.pluginWindowActive) return
                                    if (event.key === Qt.Key_Escape ||
                                        event.key === Qt.Key_Tab ||
                                        event.key === Qt.Key_Backtab) {
                                        event.accepted = true
                                    } else if ((event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier) && event.key === Qt.Key_W) {
                                        event.accepted = true
                                    } else if ((event.modifiers & Qt.ControlModifier) &&
                                        (event.key === Qt.Key_R || event.key === Qt.Key_S ||
                                         event.key === Qt.Key_O || event.key === Qt.Key_F ||
                                         event.key === Qt.Key_H || event.key === Qt.Key_Slash ||
                                         event.key === Qt.Key_C || event.key === Qt.Key_V ||
                                         event.key === Qt.Key_X || event.key === Qt.Key_A ||
                                         event.key === Qt.Key_Home || event.key === Qt.Key_End)) {
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_F3 || event.key === Qt.Key_F9 ||
                                               (root.isStepping && (event.key === Qt.Key_F10 || event.key === Qt.Key_F11))) {
                                        event.accepted = true
                                    }
                                }

                                Keys.onPressed: function(event) {
                                    if (!root.pluginWindowActive) return
                                    if ((event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier) && event.key === Qt.Key_W) {
                                        root.requestClose()
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Escape) {
                                        if (root.showFindBar) {
                                            root.showFindBar = false
                                        }
                                        event.accepted = true
                                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_R) {
                                        root.runCode()
                                        event.accepted = true
                                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) {
                                        root.saveCurrentFile()
                                        event.accepted = true
                                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_O) {
                                        root.openPluginFile()
                                        event.accepted = true
                                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_F) {
                                        root.toggleFind(true, false)
                                        event.accepted = true
                                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_H) {
                                        root.toggleFind(true, true)
                                        event.accepted = true
                                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Slash) {
                                        if (!editor.readOnly) root.toggleLineComment()
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Tab) {
                                        if (!editor.readOnly) root.handleEditorTab(event.modifiers & Qt.ShiftModifier)
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Backtab) {
                                        if (!editor.readOnly) root.handleEditorTab(true)
                                        event.accepted = true
                                    } else if (!editor.readOnly && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                               && !(event.modifiers & Qt.ControlModifier)) {
                                        root.handleEditorEnter()
                                        event.accepted = true
                                    } else if (!editor.readOnly && event.key === Qt.Key_Backspace && event.modifiers === Qt.NoModifier) {
                                        if (root.handleSmartBackspace()) {
                                            event.accepted = true
                                        }
                                    } else if (!editor.readOnly && event.text && event.text.length === 1
                                               && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
                                        var ch = event.text
                                        if (ch === "}") {
                                            if (root.handleOvertypeClose("}") || root.handleElectricCloseBrace()) {
                                                event.accepted = true
                                            }
                                        } else if (ch === ")" || ch === "]") {
                                            if (root.handleOvertypeClose(ch)) {
                                                event.accepted = true
                                            }
                                        } else if (ch === "{") {
                                            if (root.handleAutoPair("{", "}")) event.accepted = true
                                        } else if (ch === "(") {
                                            if (root.handleAutoPair("(", ")")) event.accepted = true
                                        } else if (ch === "[") {
                                            if (root.handleAutoPair("[", "]")) event.accepted = true
                                        } else if (ch === '"') {
                                            if (root.handleAutoPair('"', '"')) event.accepted = true
                                        } else if (ch === "'") {
                                            if (root.handleAutoPair("'", "'")) event.accepted = true
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Right Pane: Compact Run/Debug Icon Header + Vertical Split (Preview + Console & REPL)
            ColumnLayout {
                QQC.SplitView.preferredWidth: 460
                QQC.SplitView.minimumWidth: 280
                spacing: 5

                // Tier 2 Right-Pane Toolbar: Compact Icon + Label Controls with Tooltips
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    ToolBtn {
                        text: "▶ Run"
                        tip: "Compile and run plugin (Ctrl+R)"
                        accent: true
                        onClicked: root.runCode()
                    }
                    ToolBtn {
                        text: root.breakpointLines.length > 0 ? ("● " + root.breakpointLines.length) : "● BP"
                        tip: "Toggle breakpoint on current cursor line (F9) — or click any line number in gutter"
                        activeToggle: root.breakpointLines.length > 0
                        onClicked: root.toggleBreakpointAtCursor()
                    }
                    ToolBtn {
                        text: "✕"
                        tip: "Clear all breakpoints"
                        enabled: root.breakpointLines.length > 0
                        onClicked: root.clearAllBreakpoints()
                    }
                    ToolBtn {
                        text: "↷ Over"
                        tip: "Step Over — advance to next line in current function (F10)"
                        enabled: root.isStepping
                        onClicked: root.stepOver()
                    }
                    ToolBtn {
                        text: "↓ Into"
                        tip: "Step Into — enter called helper function (F11)"
                        enabled: root.isStepping
                        onClicked: root.stepInto()
                    }
                    ToolBtn {
                        text: "↑ Out"
                        tip: "Step Out — finish current function and pause in caller (Shift+F11)"
                        enabled: root.isStepping && root.machineStack.length > 0
                        onClicked: root.stepOut()
                    }
                    ToolBtn {
                        text: "▶▶"
                        tip: "Continue execution until next breakpoint or completion"
                        enabled: root.isStepping
                        onClicked: root.continueGenerator()
                    }
                    ToolBtn {
                        text: "■"
                        tip: "Stop running plugin instance"
                        enabled: !!root.activeInstance
                        onClicked: root.stopCode(false)
                    }

                    Item { Layout.fillWidth: true }

                    ToolBtn {
                        text: root.popOutPreview ? "↙ Dock" : "↗ Float"
                        tip: root.popOutPreview ? "Dock preview back into main window" : "Pop out preview into a floating window"
                        activeToggle: root.popOutPreview
                        onClicked: root.togglePopOutPreview()
                    }
                }

                QQC.SplitView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    orientation: Qt.Vertical

                    handle: Rectangle {
                        implicitHeight: 6
                        color: QQC.SplitHandle.pressed ? ui.theme.accentColor
                             : QQC.SplitHandle.hovered ? ui.theme.strokeColor
                             : "transparent"
                        Rectangle {
                            anchors.centerIn: parent
                            width: 36
                            height: 2
                            radius: 1
                            color: ui.theme.strokeColor
                        }
                    }

                    // Top Right: Live UI Preview Box
                    FocusScope {
                        id: sandboxHost
                        QQC.SplitView.fillHeight: true
                        QQC.SplitView.minimumHeight: 120
                        clip: true

                        Rectangle {
                            anchors.fill: parent
                            color: ui.theme.backgroundSecondaryColor
                            border.color: ui.theme.strokeColor
                            border.width: 1
                        }

                        Keys.onShortcutOverride: function(e) {
                            if (root.pluginWindowActive && e.key === Qt.Key_Escape) e.accepted = true
                        }
                        Keys.onPressed: function(e) {
                            if (root.pluginWindowActive && e.key === Qt.Key_Escape) e.accepted = true
                        }

                        MU.StyledTextLabel {
                            anchors.centerIn: parent
                            visible: !root.activeInstance || root.popOutPreview
                            text: root.popOutPreview ? "Preview popped out to floating window" : "Visual UI Preview Area"
                            opacity: 0.5
                        }
                    }

                    // Bottom Right: Dark Console Output + Header + Live REPL Evaluator Bar
                    Rectangle {
                        QQC.SplitView.preferredHeight: 260
                        QQC.SplitView.minimumHeight: 130
                        color: "#141414"
                        border.color: "#454545"
                        border.width: 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 4

                            // Compact Dark Console Header Bar (Copy Log & Clear)
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 5

                                Text {
                                    text: "CONSOLE"
                                    font.family: "monospace"
                                    font.pixelSize: 11
                                    font.bold: true
                                    color: "#808080"
                                }

                                Item { Layout.fillWidth: true }

                                Rectangle {
                                    implicitWidth: copyLbl.implicitWidth + 12
                                    implicitHeight: 20
                                    radius: 3
                                    color: copyMouse.containsMouse ? "#333333" : "#242424"
                                    border.color: "#444444"
                                    border.width: 1
                                    Text {
                                        id: copyLbl
                                        anchors.centerIn: parent
                                        text: "Copy Log"
                                        font.family: ui.theme.bodyFont.family
                                        font.pixelSize: 11
                                        color: "#cccccc"
                                    }
                                    MouseArea {
                                        id: copyMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.copyConsoleToClipboard()
                                    }
                                }

                                Rectangle {
                                    implicitWidth: clearLbl.implicitWidth + 12
                                    implicitHeight: 20
                                    radius: 3
                                    color: clearMouse.containsMouse ? "#333333" : "#242424"
                                    border.color: "#444444"
                                    border.width: 1
                                    Text {
                                        id: clearLbl
                                        anchors.centerIn: parent
                                        text: "Clear"
                                        font.family: ui.theme.bodyFont.family
                                        font.pixelSize: 11
                                        color: "#cccccc"
                                    }
                                    MouseArea {
                                        id: clearMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: consoleLog.text = ""
                                    }
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: "#2d2d2d"
                            }

                            Flickable {
                                id: consoleFlick
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                contentWidth: width
                                contentHeight: consoleLog.implicitHeight
                                clip: true

                                QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

                                TextEdit {
                                    id: consoleLog
                                    width: consoleFlick.width
                                    readOnly: true
                                    selectByMouse: true
                                    textFormat: TextEdit.RichText
                                    font.family: "monospace"
                                    font.pixelSize: 12
                                    color: "#d4d4d4"
                                    selectionColor: "#264f78"
                                    selectedTextColor: "#ffffff"
                                    wrapMode: TextEdit.Wrap

                                    Keys.onShortcutOverride: function(event) {
                                        if ((event.modifiers & Qt.ControlModifier) &&
                                            (event.key === Qt.Key_C || event.key === Qt.Key_A)) {
                                            event.accepted = true
                                        }
                                    }
                                    Keys.onPressed: function(event) {
                                        if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_C) {
                                            consoleLog.copy()
                                            event.accepted = true
                                        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_A) {
                                            consoleLog.selectAll()
                                            event.accepted = true
                                        }
                                    }
                                }
                            }

                            // Subtle divider above REPL
                            Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: "#2d2d2d"
                            }

                            // Live REPL Evaluator Bar
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Text {
                                    text: root.replBusy ? "eval..." : (root.activeInstance ? "plugin>" : "global>")
                                    font.family: "monospace"
                                    font.pixelSize: 12
                                    font.bold: true
                                    color: root.replBusy ? "#dcdcaa" : (root.activeInstance ? "#4ec9b0" : "#808080")
                                }

                                QQC.TextField {
                                    id: replInput
                                    Layout.fillWidth: true
                                    height: 24
                                    enabled: !root.replBusy
                                    placeholderText: root.replBusy ? "Evaluating..." : "Evaluate JS expression in context (Up/Down for history)..."
                                    font.family: "monospace"
                                    font.pixelSize: 12
                                    color: "#ffffff"
                                    selectionColor: "#264f78"
                                    selectedTextColor: "#ffffff"
                                    selectByMouse: true
                                    background: Rectangle {
                                        color: "#1e1e1e"
                                        border.color: replInput.activeFocus ? "#4ec9b0" : "#333333"
                                        border.width: 1
                                        radius: 2
                                    }

                                    Keys.onShortcutOverride: function(e) {
                                        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter ||
                                            e.key === Qt.Key_Up || e.key === Qt.Key_Down ||
                                            ((e.modifiers & Qt.ControlModifier) &&
                                             (e.key === Qt.Key_C || e.key === Qt.Key_V ||
                                              e.key === Qt.Key_X || e.key === Qt.Key_A))) {
                                            e.accepted = true
                                        }
                                    }

                                    Keys.onPressed: function(e) {
                                        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                            root.evalInPluginContext(replInput.text)
                                            e.accepted = true
                                        } else if (e.key === Qt.Key_Up) {
                                            if (root.replHistory.length > 0) {
                                                root.replHistoryIdx = Math.max(0, root.replHistoryIdx - 1)
                                                replInput.text = root.replHistory[root.replHistoryIdx]
                                                replInput.cursorPosition = replInput.text.length
                                            }
                                            e.accepted = true
                                        } else if (e.key === Qt.Key_Down) {
                                            if (root.replHistory.length > 0) {
                                                root.replHistoryIdx = Math.min(root.replHistory.length, root.replHistoryIdx + 1)
                                                replInput.text = root.replHistoryIdx < root.replHistory.length
                                                               ? root.replHistory[root.replHistoryIdx] : ""
                                                replInput.cursorPosition = replInput.text.length
                                            }
                                            e.accepted = true
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Full-window click-to-unpark shield when parked: absorbs the entire click on release
    // and calls toggleParkWindow() to slide back and unlock the editor.
    MouseArea {
        anchors.fill: parent
        visible: root.isParkedSide
        z: 90
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) {
            mouse.accepted = true
            root.toggleParkWindow()
        }
    }

    // Unsaved Changes Confirmation Dialog Overlay
    Rectangle {
        id: unsavedOverlay
        anchors.fill: parent
        visible: false
        color: "#88000000"
        z: 100

        MouseArea {
            anchors.fill: parent
            onClicked: {} // Block clicks to underlying editor
        }

        Rectangle {
            anchors.centerIn: parent
            width: 390
            height: 150
            radius: 6
            color: ui.theme.backgroundSecondaryColor
            border.color: ui.theme.accentColor
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 10

                MU.StyledTextLabel {
                    text: "Unsaved Changes"
                    font.pixelSize: 14
                    font.bold: true
                }

                MU.StyledTextLabel {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "You have unsaved edits in "
                          + (root.currentFilePath ? root.currentFilePath.split("/").pop() : "this buffer")
                          + ". Do you want to save before continuing?"
                }

                Item { Layout.fillHeight: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Item { Layout.fillWidth: true }

                    ToolBtn {
                        text: "Cancel"
                        onClicked: {
                            root.pendingDiscardAction = ""
                            unsavedOverlay.visible = false
                            editor.forceActiveFocus()
                        }
                    }

                    ToolBtn {
                        text: "Discard"
                        onClicked: root.executePendingDiscard()
                    }

                    ToolBtn {
                        text: "Save"
                        accent: true
                        onClicked: {
                            unsavedOverlay.visible = false
                            root.saveCurrentFile()
                        }
                    }
                }
            }
        }
    }

    // Crash-Recovery Backup Prompt Overlay
    Rectangle {
        id: recoveryOverlay
        anchors.fill: parent
        visible: false
        color: "#88000000"
        z: 110

        MouseArea {
            anchors.fill: parent
            onClicked: {} // Block clicks to underlying editor
        }

        Rectangle {
            anchors.centerIn: parent
            width: 430
            height: 165
            radius: 6
            color: ui.theme.backgroundSecondaryColor
            border.color: ui.theme.accentColor
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 10

                MU.StyledTextLabel {
                    text: "Recover Unsaved Session?"
                    font.pixelSize: 14
                    font.bold: true
                }

                MU.StyledTextLabel {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "A backup copy from an interrupted session was found"
                          + (root.recoveredBackupTargetPath
                             ? (" for " + root.recoveredBackupTargetPath.split("/").pop())
                             : "")
                          + ". Would you like to restore it?"
                }

                Item { Layout.fillHeight: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Item { Layout.fillWidth: true }

                    ToolBtn {
                        text: "Discard Backup"
                        onClicked: root.discardCrashRecovery()
                    }

                    ToolBtn {
                        text: "Restore Backup"
                        accent: true
                        onClicked: root.acceptCrashRecovery()
                    }
                }
            }
        }
    }
}
