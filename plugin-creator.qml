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
    description: "Live QML editor, runner, detachable floating preview window, multi-breakpoint step-in/over/out debugger/REPL with local scope inspection, console, and Gemini AI assistant for MuseScore 4 plugins."
    version: "1.9.6"
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

    // Working state
    property var activeInstance: null
    property var activeMachine: null
    property var machineStack: []
    property bool isStepping: false
    property string stepMode: "none"         // "none" | "over" | "into" | "out" | "continue"
    property int stepTargetDepth: -1
    property bool popOutPreview: false
    property var breakpointLines: []         // Array of 1-based line numbers
    property var breakpointRects: []         // Array of { line: int, rect: rect }
    property int debugActiveLine: -1         // 1-based line number currently paused on (-1 = none)
    property rect debugActiveRect: Qt.rect(0, 0, 0, 0)
    property string currentFilePath: ""
    property var pendingSave: null
    property bool isDirty: false
    property string cleanTextSnapshot: ""
    property string pendingDiscardAction: ""   // "close" | "open" | "new"
    property bool showFindBar: false
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

    // Side-Park State
    property bool isParkedSide: false
    property point savedWindowPos: Qt.point(100, 100)

    // REPL History & Busy State
    property var replHistory: []
    property int replHistoryIdx: -1
    property bool replBusy: false
    property string pendingReplExpr: ""

    readonly property string defaultDemoCode:
        'import QtQuick\nimport MuseScore 3.0\n\nMuseScore {\n    id: testPlugin\n    property int stepCounter: 0\n\n    // Tip: Click line numbers in the gutter to toggle multiple breakpoints!\n    // Use F10 (Step Over), F11 (Step Into), and Shift+F11 (Step Out).\n    onRun: {\n        console.log("Starting multi-breakpoint demo...")\n        if (!curScore) {\n            console.warn("No score is currently open.")\n            return\n        }\n        runHelper(2)\n        console.log("Back in onRun after helper!")\n    }\n\n    function runHelper(limit) {\n        for (var i = 1; i <= limit; i++) {\n            stepCounter = i\n            console.log("Helper iteration:", i)\n        }\n    }\n}\n'

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
            visible: btn.tip.length > 0 && btnMouse.containsMouse && !btnMouse.pressed
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
        enabled: !!root.Window.window
        function onClosing(close) {
            if (!root || !root.Window.window) return
            if (root.isDirty) {
                close.accepted = false
                if (root.isParkedSide) {
                    root.toggleParkWindow()
                }
                root.pendingDiscardAction = "close"
                unsavedOverlay.visible = true
            }
        }
    }

    // Floating Preview Window for full-sized plugin UIs
    Window {
        id: floatingWindow
        title: (root.currentFilePath ? root.currentFilePath.split("/").pop() : "Plugin Preview") + " - Live Preview"
        visible: false
        color: ui.theme.backgroundSecondaryColor
        minimumWidth: 320
        minimumHeight: 240

        onClosing: function(close) {
            close.accepted = true
            if (root.activeInstance) {
                root.stopCode(false)
            }
        }

        Item {
            id: floatingHost
            anchors.fill: parent
            focus: true

            Keys.onShortcutOverride: function(e) {
                if (root.isStepping && (e.key === Qt.Key_F10 || e.key === Qt.Key_F11)) {
                    e.accepted = true
                }
            }

            Keys.onPressed: function(e) {
                if (root.isStepping && e.key === Qt.Key_F10) {
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
        }
    }

    Settings {
        category: "PluginCreator"
        property alias lastFilePath: root.lastFilePath
        property alias geminiApiKey: root.geminiApiKey
        property alias geminiModel: root.geminiModel
    }

    FileIO { id: fio }

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
        duration: 500
        easing.type: Easing.OutCubic
        onFinished: {
            if (!root.isParkedSide && root.Window.window) {
                root.Window.window.raise()
                root.Window.window.requestActivate()
                editor.forceActiveFocus()
            }
        }
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

    function sizeAndShowFloatingWindow(obj) {
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

        floatingWindow.width = Math.max(360, Math.min(desiredW, availW - 60))
        floatingWindow.height = Math.max(260, Math.min(desiredH, availH - 80))
        floatingWindow.x = Math.max(24, Math.floor((availW - floatingWindow.width) / 2) + 30)
        floatingWindow.y = Math.max(32, Math.floor((availH - floatingWindow.height) / 2))
        floatingWindow.visible = true
        floatingWindow.raise()
    }

    function togglePopOutPreview() {
        popOutPreview = !popOutPreview
        if (popOutPreview) {
            if (activeInstance) {
                activeInstance.parent = floatingHost
                sizeAndShowFloatingWindow(activeInstance)
            } else {
                sizeAndShowFloatingWindow(null)
            }
            logMessage("INFO", "Preview popped out to floating window.", "#b5cea8")
        } else {
            if (activeInstance) {
                activeInstance.parent = sandboxHost
            }
            floatingWindow.visible = false
            editor.forceActiveFocus()
            logMessage("INFO", "Preview docked back into main window.", "#b5cea8")
        }
    }

    function makeResizable() {
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
            savedWindowPos = Qt.point(w.x, w.y)
            isParkedSide = true
            parkAnim.from = w.x
            parkAnim.to = availW - peekWidth
            parkAnim.start()
        } else {
            isParkedSide = false
            w.y = savedWindowPos.y
            parkAnim.from = w.x
            parkAnim.to = savedWindowPos.x
            parkAnim.start()
        }
    }

    Timer {
        id: resizeTimer
        interval: 120
        repeat: true
        property int count: 0
        onTriggered: {
            root.makeResizable()
            if (count < 3) {
                editor.forceActiveFocus()
            }
            if (++count >= 10) stop()
        }
    }

    onRun: {
        resizeTimer.start()
        if (lastFilePath !== "") {
            fio.source = lastFilePath
            if (fio.exists()) {
                currentFilePath = lastFilePath
                setEditorTextClean(fio.read())
                editor.forceActiveFocus()
                logMessage("INFO", "Restored last session file: " + lastFilePath, "#b5cea8")
                return
            }
        }
        setEditorTextClean(defaultDemoCode)
        editor.forceActiveFocus()
    }

    Component.onDestruction: {
        parkAnim.stop()
        resizeTimer.stop()
        aiTimeoutTimer.stop()
        replEvalTimer.stop()
        runDelayTimer.stop()
        if (aiProc && aiProc.state !== 0) {
            aiProc.kill()
        }
        if (copyProc && copyProc.state !== 0) {
            copyProc.kill()
        }
        stopCode(true)
        if (floatingWindow) {
            floatingWindow.close()
        }
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
        if (floatingWindow.visible) {
            floatingWindow.visible = false
        }
        if (activeInstance) {
            activeInstance.destroy()
            activeInstance = null
            if (!silent) {
                logMessage("WARN", "Execution interrupted - child plugin instance destroyed."
                    + (wasStepping ? " (If curScore.startCmd() was open, run curScore.endCmd() in REPL.)" : ""), "#dcdcaa")
            }
        }
    }

    // ------------------------------------------------------------------
    //  File Operations & Unsaved-Changes Protection
    // ------------------------------------------------------------------

    function setEditorTextClean(newText) {
        cleanTextSnapshot = newText
        editor.text = newText
        isDirty = false
    }

    function performAfterSaveAction() {
        var act = pendingDiscardAction
        pendingDiscardAction = ""
        if (act === "close") {
            root.quit()
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
            root.quit()
        }
    }

    function executePendingDiscard() {
        var act = pendingDiscardAction
        pendingDiscardAction = ""
        unsavedOverlay.visible = false
        isDirty = false
        if (act === "close") {
            root.quit()
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
            var p = filePath.replace(/\\/g, "/")
            fio.source = p
            if (fio.exists()) {
                root.currentFilePath = p
                root.lastFilePath = p
                root.breakpointLines = []
                root.clearDebugState()
                root.resetAiChat(true)
                root.setEditorTextClean(fio.read())
                editor.forceActiveFocus()
                logMessage("INFO", "Loaded: " + p, "#b5cea8")
            }
        }
    }

    FileDialog {
        id: saveDialog
        title: "Save QML Plugin"
        type: FileDialog.Save
        onAccepted: {
            var p = filePath.replace(/\\/g, "/")
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
        currentFilePath = ""
        lastFilePath = ""
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
        if (!currentFilePath) {
            saveDialog.folder = fio.homePath().replace(/\\/g, "/") + "/Documents/MuseScore4/Plugins/new_plugin.qml"
            saveDialog.open()
            return
        }

        lastFilePath = currentFilePath

        fio.source = currentFilePath
        if (fio.write(editor.text)) {
            cleanTextSnapshot = editor.text
            isDirty = false
            logMessage("INFO", "Saved: " + currentFilePath, "#b5cea8")
            performAfterSaveAction()
            return
        }

        var tmpDir = fio.tempPath().replace(/\\/g, "/")
        var tmpPath = tmpDir + "/plugin_creator_save_" + Date.now() + ".qml"
        fio.source = tmpPath
        if (!fio.write(editor.text)) {
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
            logMessage("INFO", "Saved: " + job.dst, "#b5cea8")
            performAfterSaveAction()
        } else {
            pendingDiscardAction = ""
            logMessage("ERR", "Failed to save to: " + job.dst, "#f48771")
        }
    }

    // ------------------------------------------------------------------
    //  Find Facility & Scrolling
    // ------------------------------------------------------------------

    function toggleFind(openOnly) {
        showFindBar = openOnly ? true : !showFindBar
        if (showFindBar) {
            if (editor.selectedText.length > 0 && editor.selectedText.indexOf("\n") === -1) {
                findInput.text = editor.selectedText
            }
            findInput.forceActiveFocus()
            findInput.selectAll()
        } else {
            editor.forceActiveFocus()
        }
    }

    function findNext(backwards) {
        var query = findInput.text
        if (!query) return

        var text = editor.text
        var hay = matchCaseBox.checked ? text : text.toLowerCase()
        var needle = matchCaseBox.checked ? query : query.toLowerCase()
        var idx = -1

        if (!backwards) {
            var startPos = Math.max(editor.selectionEnd, editor.cursorPosition)
            idx = hay.indexOf(needle, startPos)
            if (idx === -1 && startPos > 0) {
                idx = hay.indexOf(needle, 0)
            }
        } else {
            var searchEnd = Math.min(editor.selectionStart, editor.cursorPosition) - 1
            if (searchEnd >= 0) {
                idx = hay.lastIndexOf(needle, searchEnd)
            }
            if (idx === -1) {
                idx = hay.lastIndexOf(needle)
            }
        }

        if (idx !== -1) {
            editor.forceActiveFocus()
            editor.select(idx, idx + query.length)
            scrollEditorToRect(editor.positionToRectangle(idx))
        } else {
            logMessage("INFO", "Find: '" + query + "' not found.", "#dcdcaa")
        }
    }

    function scrollEditorToRect(r) {
        if (r.height <= 0 || !editorScroll.QQC.ScrollBar.vertical) return
        var targetY = Math.max(0, r.y - editorScroll.availableHeight * 0.35)
        var maxPos = Math.max(0, 1.0 - editorScroll.QQC.ScrollBar.vertical.size)
        var ratio = editor.implicitHeight > 0 ? Math.min(maxPos, targetY / editor.implicitHeight) : 0
        editorScroll.QQC.ScrollBar.vertical.position = ratio
    }

    // ------------------------------------------------------------------
    //  Gemini "Vibe Coding" Integration (Multi-Turn History)
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
                editor.text = extractedCode + "\n"
                lastErrorText = ""
                logMessage("INFO", "Editor updated by " + aiActiveModel + ". Press Ctrl+R to run.", "#b5cea8")
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

        // If user clicked Step Into on the caller, pause right at the first executable line of this callee
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

            // Check explicit breakpoints on every non-initial statement
            if (!firstStep && hasBreakpoint(curLine)) {
                pauseAtCurrentMachine("Paused at breakpoint")
                return
            }

            // Check single-step stopping criteria once we've advanced off the starting statement
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
                        if (depth === 0) { i++; break }
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
                    else if (depth === 0 && (ch === ";" || ch === "\n")) {
                        i++
                        break
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

    function compileBlockToMachineCode(src, matchIndex, openBraceIdx, closeBraceIdx, isSignal, targetName, fnParams) {
        var body = src.substring(openBraceIdx + 1, closeBraceIdx)
        var bodyBaseLine = lineNumberAtOffset(src, openBraceIdx + 1)
        var astNodes = parseBlockToNodes(body, bodyBaseLine)
        if (astNodes.length === 0) return null

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
                    var assignMatch = c.match(/^([A-Za-z_$][A-Za-z0-9_$.]*)\s*=\s*[^=][\s\S]*;$/)
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

        var entryPc = compileList(astNodes, -1, -1, -1)

        var lineMapPairs = []
        var caseClauses = []
        for (var s = 0; s < states.length; ++s) {
            lineMapPairs.push(states[s].id + ": " + states[s].line)
            caseClauses.push("case " + states[s].id + ": " + states[s].code + " break;")
        }

        var varHeader = Object.keys(sharedVars).length > 0
            ? ("var " + Object.keys(sharedVars).join(", ") + "; ")
            : ""

        var origNewlines = (src.substring(matchIndex, closeBraceIdx + 1).match(/\n/g) || []).length
        var padNewlines = ""
        for (var nl = 0; nl < origNewlines; ++nl) padNewlines += "\n"

        // Collect all parameter names and hoisted local variable names for REPL closure inspection
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

        return headerPrefix + varHeader
            + "var __m = { pc: " + entryPc + ", retVal: undefined, applyRetVal: null"
            + ", localNames: " + localNamesJson
            + ", evalLocal: function(__expr) { try { return eval(\"(\" + __expr + \")\"); } catch (e) { if (e instanceof SyntaxError) return eval(__expr); throw e; } }"
            + ", lines: { " + lineMapPairs.join(", ") + " }"
            + ", step: function() { switch (this.pc) { " + caseClauses.join(" ") + " default: this.pc = -1; } }"
            + " }; sandboxConsole.runMachine(__m, \"" + targetName + "\");" + returnSuffix + padNewlines + "}"
    }

    // Instruments signal handlers and helper functions whenever any breakpoints are set
    // so both multi-breakpoints and Step Into (F11) work seamlessly across function calls.
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

            var replacement = compileBlockToMachineCode(src, match.index, openBraceIdx, closeBraceIdx, isSignal, targetName, fnParams)
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
            var targetParent = popOutPreview ? floatingHost : sandboxHost

            var obj = Qt.createQmlObject(instrumentedCode, targetParent, baseUrl)
            activeInstance = obj

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

        Keys.onShortcutOverride: function(e) {
            if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_F) {
                e.accepted = true
            } else if (e.key === Qt.Key_F3 || e.key === Qt.Key_F9) {
                e.accepted = true
            } else if (root.isStepping && (e.key === Qt.Key_F10 || e.key === Qt.Key_F11)) {
                e.accepted = true
            }
        }

        Keys.onPressed: function(e) {
            if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_F) {
                root.toggleFind(true)
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

        // Tier 1 Top Toolbar: Side-Park Toggle + Compact File & Workspace Actions
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
                tip: "Open an existing QML plugin"
                onClicked: root.openPluginFile()
            }
            ToolBtn {
                text: "Save"
                tip: "Save current plugin (Ctrl+S)"
                onClicked: root.saveCurrentFile()
            }
            ToolBtn {
                text: "Find"
                tip: "Find text in editor (Ctrl+F)"
                onClicked: root.toggleFind(false)
            }

            Item { Layout.fillWidth: true }

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
                    text: "Remembers recent turns + sends current code."
                    opacity: 0.65
                }
            }
        }

        // Collapsible Find Bar
        Rectangle {
            Layout.fillWidth: true
            Layout.maximumWidth: mainCol.width
            implicitHeight: 34
            visible: root.showFindBar
            color: ui.theme.backgroundSecondaryColor
            border.color: ui.theme.strokeColor
            border.width: 1
            radius: 4

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 6

                MU.StyledTextLabel { text: "Find:" }
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
                        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Escape) e.accepted = true
                    }
                    Keys.onPressed: function(e) {
                        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                            root.findNext(e.modifiers & Qt.ShiftModifier)
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
                    tip: "Find next match (F3)"
                    onClicked: root.findNext(false)
                }
                ToolBtn {
                    text: "Prev"
                    tip: "Find previous match (Shift+Enter)"
                    onClicked: root.findNext(true)
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
                    tip: "Close find bar (Esc)"
                    implicitWidth: 24
                    onClicked: {
                        root.showFindBar = false
                        editor.forceActiveFocus()
                    }
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

            // Left Pane: Light-Theme Code Editor with Multi-Breakpoint Gutter & Exact Highlights
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

                    Row {
                        width: Math.max(editorScroll.availableWidth, gutter.width + editor.implicitWidth)
                        height: Math.max(editorScroll.availableHeight, editor.implicitHeight)

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

                            // Red Breakpoint Badges in Gutter (supports multiple breakpoints)
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

                        // Code Editor with Exact Character-Geometry Highlights
                        Item {
                            width: Math.max(editorScroll.availableWidth - gutter.width, editor.implicitWidth)
                            height: parent.height

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

                            QQC.TextArea {
                                id: editor
                                anchors.fill: parent
                                font.family: "monospace"
                                font.pixelSize: 13
                                color: "#111111"
                                selectionColor: "#b4d5fe"
                                selectedTextColor: "#000000"
                                selectByMouse: true
                                wrapMode: TextEdit.NoWrap
                                topPadding: 8
                                bottomPadding: 8
                                leftPadding: 8
                                rightPadding: 16

                                onImplicitHeightChanged: root.updateLineVisuals()
                                onTextChanged: {
                                    root.updateLineVisuals()
                                    root.isDirty = (editor.text !== root.cleanTextSnapshot)
                                }

                                background: Rectangle {
                                    color: "transparent"
                                }

                                Keys.onShortcutOverride: function(event) {
                                    if ((event.modifiers & Qt.ControlModifier) &&
                                        (event.key === Qt.Key_R || event.key === Qt.Key_S ||
                                         event.key === Qt.Key_F || event.key === Qt.Key_C ||
                                         event.key === Qt.Key_V || event.key === Qt.Key_X ||
                                         event.key === Qt.Key_A)) {
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_F3 || event.key === Qt.Key_F9 ||
                                               (root.isStepping && (event.key === Qt.Key_F10 || event.key === Qt.Key_F11))) {
                                        event.accepted = true
                                    }
                                }

                                Keys.onPressed: function(event) {
                                    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_R) {
                                        root.runCode()
                                        event.accepted = true
                                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) {
                                        root.saveCurrentFile()
                                        event.accepted = true
                                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_F) {
                                        root.toggleFind(true)
                                        event.accepted = true
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
                    Rectangle {
                        id: sandboxHost
                        QQC.SplitView.fillHeight: true
                        QQC.SplitView.minimumHeight: 120
                        color: ui.theme.backgroundSecondaryColor
                        border.color: ui.theme.strokeColor
                        border.width: 1
                        clip: true

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
}
