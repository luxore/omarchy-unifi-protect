pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  readonly property string pluginId: "io.github.luxore.unifi-protect"
  // Nerd Fonts Material Design Icons: cctv (U+F07AE).
  readonly property string barIcon: "󰞮"
  readonly property string helperPath:
    decodeURIComponent(String(Qt.resolvedUrl("bin/omarchy-protect")).replace(/^file:\/\//, ""))

  moduleName: pluginId
  ipcTarget: pluginId
  manageIpc: false

  property var cameras: []
  property int selectedIndex: 0
  property string frameUrl: ""
  property string liveStreamUrl: ""
  property int frameSerial: 0
  property string snapshotError: ""
  property string streamError: ""
  property string lastError: ""
  property string actionError: ""
  property real lastFrameAt: 0
  property real nowMs: Date.now()
  property bool loading: false
  property bool connecting: false
  property bool savingPreference: false
  property bool streamLoading: false
  property bool abandoningWatch: false
  property bool abandoningStreamRequest: false
  property bool abandoningConnect: false
  property string currentTab: setupComplete ? "viewer" : "connection"
  property bool chooseFavoriteOnNextLoad: true
  property string pendingKey: ""
  property string pendingPreferenceKey: ""
  property string pendingPreferenceValue: ""

  readonly property string instanceUrl: String(setting("instanceUrl", "https://unifi.local")).trim()
  readonly property bool setupComplete: boolSetting("setupComplete", false)
  readonly property bool verifyTls: boolSetting("verifyTls", true)
  readonly property string favoriteCameraId: String(setting("favoriteCameraId", ""))
  readonly property string frameFit: String(setting("frameFit", "fit"))
  readonly property bool liveMuted: boolSetting("liveMuted", false)
  readonly property string liveQuality: String(setting("liveQuality", "auto"))
  readonly property string refreshMode: String(setting("refreshMode", "fast"))
  readonly property bool showOfflineCameras: boolSetting("showOfflineCameras", true)
  readonly property string viewerSize: String(setting("viewerSize", "large"))
  readonly property bool showingViewer: currentTab === "viewer"
  readonly property bool showingPreferences: currentTab === "preferences"
  readonly property bool showingSetup: currentTab === "connection"
  readonly property bool realtimeMode: refreshMode === "realtime"
  readonly property real snapshotInterval: refreshMode === "efficient" ? 2.0
    : (refreshMode === "balanced" ? 1.0 : 0.75)
  readonly property real desiredPanelWidth: viewerSize === "comfortable"
    ? Style.space(540) : Style.space(680)
  readonly property var selectedCamera: cameras.length > 0
    ? cameras[Math.max(0, Math.min(selectedIndex, cameras.length - 1))] : null
  readonly property bool selectedConnected: selectedCamera && selectedCamera.state === "CONNECTED"
  readonly property bool selectedIsFavorite: selectedCamera
    && String(selectedCamera.id || "") === favoriteCameraId
  readonly property string cameraError: realtimeMode ? streamError : snapshotError
  readonly property bool frameStale: frameUrl !== "" && nowMs - lastFrameAt > 4000
  readonly property color detailColor:
    Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.72)

  function boolSetting(key, fallback) {
    var value = settings ? settings[key] : undefined
    if (value === undefined || value === null) return fallback
    if (typeof value === "string") return value !== "false" && value !== "0" && value !== ""
    return value !== false
  }

  function baseCommand() {
    return [helperPath, "--url", instanceUrl, "--verify-tls", verifyTls ? "true" : "false"]
  }

  function acceptJson(output, fallback) {
    try { return JSON.parse(String(output || "")) }
    catch (error) { return { error: fallback } }
  }

  function refreshCameras() {
    if (cameraListProcess.running || instanceUrl === "") return
    loading = true
    lastError = ""
    cameraListProcess.command = baseCommand().concat(["cameras"])
    cameraListProcess.running = true
  }

  function selectCamera(index) {
    if (cameras.length === 0) return
    selectedIndex = (index + cameras.length) % cameras.length
    frameUrl = ""
    frameViewport.videoZoom = 1.0
    lastFrameAt = 0
    snapshotError = ""
    streamError = ""
    actionError = ""
    restartWatch()
  }

  function restartWatch() {
    watchRetry.stop()
    stopWatch()
    if (!opened || !showingViewer || !selectedConnected) {
      return
    }
    Qt.callLater(startCurrentFeed)
  }

  function startCurrentFeed() {
    if (!opened || !showingViewer || !selectedConnected) return
    if (realtimeMode) {
      startSnapshotPreview()
      startStream()
    } else {
      startSnapshotWatch()
    }
  }

  function startSnapshotPreview() {
    if (!realtimeMode || !opened || !showingViewer || !selectedConnected
        || previewProcess.running || (frameUrl !== "" && !frameStale)) return
    previewProcess.command = baseCommand().concat([
      "watch", "--camera", String(selectedCamera.id), "--interval", "0.75", "--once"
    ])
    previewProcess.running = true
  }

  function startSnapshotWatch() {
    if (realtimeMode || !opened || !showingViewer || !selectedConnected
        || watchProcess.running) return
    watchProcess.command = baseCommand().concat([
      "watch", "--camera", String(selectedCamera.id), "--interval", String(snapshotInterval)
    ])
    watchProcess.running = true
  }

  function startStream() {
    if (!realtimeMode || !opened || !showingViewer || !selectedConnected
        || streamProcess.running || liveStreamUrl !== "") return
    streamLoading = true
    streamError = ""
    streamProcess.command = baseCommand().concat([
      "stream", "--camera", String(selectedCamera.id), "--quality", liveQuality
    ])
    streamProcess.running = true
  }

  function stopWatch() {
    watchRetry.stop()
    if (previewProcess.running) previewProcess.running = false
    if (watchProcess.running) {
      abandoningWatch = true
      watchProcess.running = false
    }
    if (streamProcess.running) {
      abandoningStreamRequest = true
      streamProcess.running = false
    }
    embeddedPlayer.stop()
    embeddedPlayer.source = ""
    liveStreamUrl = ""
    streamLoading = false
  }

  function acceptStreamUrl(line) {
    var parsed = acceptJson(line, "The live stream response was unreadable")
    if (parsed.error || typeof parsed.url !== "string"
        || !parsed.url.startsWith("http://127.0.0.1:")) {
      streamError = String(parsed.error || "Protect returned an invalid live stream")
      streamLoading = false
      return
    }
    liveStreamUrl = String(parsed.url)
    embeddedPlayer.source = liveStreamUrl
    Qt.callLater(embeddedPlayer.play)
  }

  function acceptFrame(line) {
    var parsed = acceptJson(line, "The camera returned unreadable data")
    if (parsed.error) {
      snapshotError = String(parsed.error)
      return
    }
    if (parsed.path) {
      snapshotError = ""
      frameSerial += 1
      lastFrameAt = Number(parsed.fetchedAt || Date.now())
      frameUrl = String(parsed.path) + "?frame=" + frameSerial
    }
  }

  function connect(url, tls, apiKey) {
    if (connectProcess.running) return
    pendingKey = String(apiKey)
    connecting = true
    lastError = ""
    setupPane.message = ""
    connectProcess.command = [helperPath, "--url", String(url), "--verify-tls",
                              tls ? "true" : "false", "connect", "--stdin"]
    connectProcess.running = true
  }

  function openTarget(target) {
    openProcess.command = target === "api-keys"
      ? baseCommand().concat(["open-api-keys"])
      : baseCommand().concat(["open"])
    openProcess.running = true
  }

  function openLive() {
    if (!selectedCamera || viewProcess.running) return
    actionError = ""
    viewProcess.command = baseCommand().concat([
      "view", "--camera", String(selectedCamera.id),
      "--quality", liveQuality,
      "--muted", liveMuted ? "true" : "false"
    ])
    viewProcess.running = true
  }

  function forget(url) {
    forgetProcess.command = [helperPath, "--url", String(url), "forget"]
    forgetProcess.running = true
  }

  function showConnection() {
    stopWatch()
    currentTab = "connection"
    setupPane.load()
    Qt.callLater(setupPane.forceActiveFocus)
  }

  function showPreferences() {
    stopWatch()
    currentTab = "preferences"
    Qt.callLater(preferencesPane.forceActiveFocus)
  }

  function showViewer() {
    currentTab = "viewer"
    chooseFavoriteOnNextLoad = true
    Qt.callLater(keyCatcher.forceActiveFocus)
    refreshCameras()
    restartWatch()
  }

  function switchTab(tab) {
    if (tab === "viewer") showViewer()
    else if (tab === "preferences") showPreferences()
    else showConnection()
  }

  function cameraStateLabel() {
    if (!selectedCamera) return ""
    var state = String(selectedCamera.state || "UNKNOWN")
    if (state === "CONNECTED") return "Connected"
    if (state === "CONNECTING") return "Connecting"
    if (state === "DISCONNECTED") return "Offline"
    return "Unavailable"
  }

  function toggleFavorite() {
    if (!selectedCamera || preferenceProcess.running) return
    savePreference("favoriteCameraId", selectedIsFavorite ? "" : String(selectedCamera.id))
  }

  function savePreference(key, value) {
    if (preferenceProcess.running) return
    pendingPreferenceKey = String(key)
    pendingPreferenceValue = String(value)
    savingPreference = true
    preferencesPane.message = ""
    preferenceProcess.command = baseCommand().concat([
      "preference", "--key", pendingPreferenceKey, "--value", pendingPreferenceValue
    ])
    preferenceProcess.running = true
  }

  Process {
    id: cameraListProcess
    running: false
    command: []
    stdout: StdioCollector { id: cameraListStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      var parsed = root.acceptJson(cameraListStdout.text, "The camera list was unreadable")
      if (exitCode !== 0 || parsed.error) {
        root.lastError = String(parsed.error || "Could not load UniFi Protect cameras")
        root.cameras = []
        root.stopWatch()
        return
      }
      var activeCameraId = root.selectedCamera
        ? String(root.selectedCamera.id || "") : ""
      var feedWasActive = watchProcess.running || previewProcess.running
        || streamProcess.running || root.liveStreamUrl !== ""
      var previousId = root.chooseFavoriteOnNextLoad ? root.favoriteCameraId
        : (root.selectedCamera ? String(root.selectedCamera.id || "") : "")
      var received = parsed.cameras instanceof Array ? parsed.cameras : []
      root.cameras = root.showOfflineCameras ? received
        : received.filter(function(camera) { return camera.state === "CONNECTED" })
      root.chooseFavoriteOnNextLoad = false
      root.lastError = ""
      var nextIndex = -1
      if (previousId !== "") {
        for (var i = 0; i < root.cameras.length; i++) {
          if (String(root.cameras[i].id || "") === previousId) {
            nextIndex = i
            break
          }
        }
      }
      if (nextIndex < 0) {
        for (var j = 0; j < root.cameras.length; j++) {
          if (root.cameras[j].state === "CONNECTED") {
            nextIndex = j
            break
          }
        }
      }
      root.selectedIndex = nextIndex < 0 ? 0 : nextIndex
      var selectedCameraId = root.selectedCamera
        ? String(root.selectedCamera.id || "") : ""
      if (!feedWasActive || activeCameraId !== selectedCameraId || !root.selectedConnected)
        root.restartWatch()
    }
  }

  Process {
    id: watchProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function(line) { root.acceptFrame(line) } }
    onExited: function(_exitCode) {
      if (root.abandoningWatch) {
        root.abandoningWatch = false
        if (root.opened && root.showingViewer && root.selectedConnected)
          Qt.callLater(root.startCurrentFeed)
        return
      }
      if (!root.realtimeMode && root.opened && root.showingViewer && root.selectedConnected) {
        if (root.snapshotError === "") root.snapshotError = "Camera refresh stopped"
        watchRetry.restart()
      }
    }
  }

  Process {
    id: previewProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function(line) { root.acceptFrame(line) } }
  }

  Process {
    id: streamProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function(line) { root.acceptStreamUrl(line) } }
    onExited: function(exitCode) {
      if (root.abandoningStreamRequest) {
        root.abandoningStreamRequest = false
        if (root.opened && root.showingViewer && root.selectedConnected)
          Qt.callLater(root.startCurrentFeed)
        return
      }
      if (root.realtimeMode && root.opened && root.showingViewer && root.selectedConnected) {
        if (root.streamError === "") root.streamError = exitCode === 0
          ? "The real-time stream stopped" : "Could not start the live stream"
        root.streamLoading = false
        watchRetry.restart()
      }
    }
  }

  Process {
    id: connectProcess
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector { id: connectStdout; waitForEnd: true }
    onStarted: {
      write(root.pendingKey + "\n")
      root.pendingKey = ""
    }
    onExited: function(exitCode) {
      root.connecting = false
      if (root.abandoningConnect) {
        root.abandoningConnect = false
        return
      }
      var parsed = root.acceptJson(connectStdout.text, "Connection returned unreadable data")
      if (exitCode !== 0 || parsed.error) {
        setupPane.message = String(parsed.error || "Could not connect to UniFi Protect")
        setupPane.messageIsError = true
        return
      }
      root.settings = Object.assign({}, root.settings, {
        instanceUrl: String(parsed.url || root.instanceUrl),
        verifyTls: parsed.verifyTls !== false,
        setupComplete: true
      })
      setupPane.message = "Connected to UniFi Protect"
      setupPane.messageIsError = false
      root.showViewer()
    }
  }

  Process {
    id: viewProcess
    running: false
    command: []
    stdout: StdioCollector { id: viewStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = root.acceptJson(viewStdout.text, "Live view returned unreadable data")
      if (exitCode !== 0 || parsed.error)
        root.actionError = String(parsed.error || "Could not open the live stream")
    }
  }

  Process {
    id: forgetProcess
    running: false
    command: []
    stdout: StdioCollector { id: forgetStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = root.acceptJson(forgetStdout.text, "Key removal returned unreadable data")
      setupPane.message = exitCode === 0 && !parsed.error
        ? "Saved key removed" : String(parsed.error || "Could not remove the saved key")
      setupPane.messageIsError = exitCode !== 0 || !!parsed.error
      if (exitCode === 0 && !parsed.error) {
        root.settings = Object.assign({}, root.settings, { setupComplete: false })
        root.showConnection()
      }
    }
  }

  Process {
    id: preferenceProcess
    running: false
    command: []
    stdout: StdioCollector { id: preferenceStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.savingPreference = false
      var parsed = root.acceptJson(preferenceStdout.text, "Preference returned unreadable data")
      if (exitCode !== 0 || parsed.error) {
        preferencesPane.message = String(parsed.error || "Could not save the preference")
        preferencesPane.messageIsError = true
        return
      }
      var changed = ({})
      changed[root.pendingPreferenceKey] = root.pendingPreferenceValue
      root.settings = Object.assign({}, root.settings, changed)
      preferencesPane.message = ""
      preferencesPane.messageIsError = false
      if (root.pendingPreferenceKey === "favoriteCameraId") root.chooseFavoriteOnNextLoad = true
      if (root.pendingPreferenceKey === "showOfflineCameras") root.refreshCameras()
      if (root.pendingPreferenceKey === "refreshMode"
          || root.pendingPreferenceKey === "liveQuality") root.restartWatch()
      root.pendingPreferenceKey = ""
      root.pendingPreferenceValue = ""
    }
  }

  Process { id: openProcess; running: false; command: [] }

  Timer {
    id: watchRetry
    interval: root.realtimeMode ? 3000 : 1200
    repeat: false
    onTriggered: root.startCurrentFeed()
  }

  Timer {
    interval: 30000
    running: root.opened && root.showingViewer
    repeat: true
    onTriggered: root.refreshCameras()
  }

  Timer {
    interval: 1000
    running: root.opened && root.showingViewer
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  AudioOutput {
    id: embeddedAudio
    muted: root.liveMuted
  }

  MediaPlayer {
    id: embeddedPlayer
    audioOutput: embeddedAudio
    videoOutput: embeddedVideo
    playbackOptions.playbackIntent: PlaybackOptions.LowLatencyStreaming

    onPlaybackStateChanged: {
      if (playbackState === MediaPlayer.PlayingState) {
        root.streamError = ""
        root.streamLoading = false
        if (previewProcess.running) previewProcess.running = false
      }
    }

    onErrorOccurred: function(error, _errorString) {
      if (error === MediaPlayer.NoError || !root.realtimeMode || root.liveStreamUrl === "") return
      root.streamError = "The real-time stream stopped"
      root.streamLoading = false
      stop()
      source = ""
      root.liveStreamUrl = ""
      if (streamProcess.running) {
        root.abandoningStreamRequest = true
        streamProcess.running = false
      } else if (root.opened && root.showingViewer && root.selectedConnected) {
        watchRetry.restart()
      }
    }
  }

  onOpenedChanged: {
    if (opened) {
      if (!setupComplete) showConnection()
      else showViewer()
    } else {
      stopWatch()
      if (connectProcess.running) {
        abandoningConnect = true
        connecting = false
        connectProcess.running = false
      }
      pendingKey = ""
    }
  }

  onInstanceUrlChanged: {
    cameras = []
    selectedIndex = 0
    frameUrl = ""
    stopWatch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    labelVisible: false
    fixedWidth: root.bar && root.bar.vertical ? root.bar.barSize : Style.bar.statusSlot
    fixedHeight: root.bar && root.bar.vertical ? Style.bar.statusSlot
      : (root.bar ? root.bar.barSize : Style.bar.sizeHorizontal)
    dimmed: false
    tooltipText: "UniFi Protect Viewer"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }

    OpticalGlyph {
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: width
      text: root.barIcon
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      fontSize: Style.bar.iconFont
      color: root.barForeground
    }
  }

  KeyboardPanel {
    id: protectPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.showingSetup ? setupPane
      : (root.showingPreferences ? preferencesPane : keyCatcher)
    contentWidth: protectPanel.fittedContentWidth(root.desiredPanelWidth)
    contentHeight: protectPanel.fittedContentHeight(content.implicitHeight, Style.space(820))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: !root.showingViewer
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        root.selectCamera(root.selectedIndex + (dx !== 0 ? dx : dy))
      }
      onActivateRequested: root.openLive()
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (key === "o") root.openTarget("protect")
        else if (key === "m") root.savePreference("liveMuted", root.liveMuted ? "false" : "true")
        else if (key === "f") root.toggleFavorite()
        else if (key === "p") root.showPreferences()
        else if (key === "c") root.showConnection()
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Item {
          width: parent.width
          height: Math.max(brandRow.implicitHeight, panelTabs.implicitHeight)

          Row {
            id: brandRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(7)

            OpticalGlyph {
              width: Style.space(18)
              height: width
              text: root.barIcon
              fontFamily: Style.font.family
              fontSize: Style.space(16)
              color: Color.popups.text
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelSectionHeader {
              text: "UNIFI PROTECT"
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          ButtonGroup {
            id: panelTabs
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            options: [
              { value: "viewer", label: "Viewer" },
              { value: "preferences", label: "Preferences" },
              { value: "connection", label: "Connection" }
            ]
            value: root.currentTab
            focusable: false
            onChanged: function(value) { root.switchTab(value) }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.showingViewer

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              id: previousCamera
              iconText: ""
              tooltipText: "Previous camera"
              bordered: true
              enabled: root.cameras.length > 1
              onClicked: root.selectCamera(root.selectedIndex - 1)
            }

            Column {
              width: parent.width - previousCamera.implicitWidth - favoriteCamera.implicitWidth
                - nextCamera.implicitWidth - 3 * parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: root.selectedCamera
                  ? String(root.selectedCamera.name || "Unnamed camera") : "UniFi Protect"
                textFormat: Text.PlainText
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.cameras.length > 0
                  ? root.cameraStateLabel() + " · " + (root.selectedIndex + 1)
                    + " of " + root.cameras.length : (root.loading ? "Loading cameras…" : "")
                textFormat: Text.PlainText
                color: root.selectedConnected ? root.detailColor : Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Button {
              id: favoriteCamera
              iconText: root.selectedIsFavorite ? "" : ""
              tooltipText: root.selectedIsFavorite
                ? "Clear default camera" : "Make this the default camera"
              bordered: true
              selected: root.selectedIsFavorite
              enabled: !!root.selectedCamera && !preferenceProcess.running
              onClicked: root.toggleFavorite()
            }

            Button {
              id: nextCamera
              iconText: ""
              tooltipText: "Next camera"
              bordered: true
              enabled: root.cameras.length > 1
              onClicked: root.selectCamera(root.selectedIndex + 1)
            }
          }

          Rectangle {
            id: frameViewport
            property real videoZoom: 1.0
            readonly property real sourceAspect: root.realtimeMode
              && embeddedVideo.sourceRect.height > 0
                ? embeddedVideo.sourceRect.width / embeddedVideo.sourceRect.height
                : cameraFrame.sourceAspect
            width: parent.width
            height: Math.round(width / Math.max(1.1, Math.min(2.0, sourceAspect)))
            color: Color.background
            radius: Style.cornerRadius
            clip: true

            CameraFrame {
              id: cameraFrame
              anchors.fill: parent
              visible: !root.realtimeMode
                || embeddedPlayer.playbackState !== MediaPlayer.PlayingState
              frameUrl: root.frameUrl
              fillFrame: root.frameFit === "fill"
            }

            VideoOutput {
              id: embeddedVideo
              anchors.fill: parent
              visible: root.realtimeMode
              fillMode: root.frameFit === "fill"
                ? VideoOutput.PreserveAspectCrop : VideoOutput.PreserveAspectFit
              scale: frameViewport.videoZoom
            }

            WheelHandler {
              enabled: root.realtimeMode
                && embeddedPlayer.playbackState === MediaPlayer.PlayingState
              onWheel: function(event) {
                if (event.angleDelta.y === 0) return
                var step = event.angleDelta.y > 0 ? 0.25 : -0.25
                frameViewport.videoZoom = Math.max(1.0,
                  Math.min(4.0, frameViewport.videoZoom + step))
              }
            }

            Rectangle {
              anchors.fill: parent
              visible: root.frameUrl === "" && (root.realtimeMode
                ? embeddedPlayer.playbackState !== MediaPlayer.PlayingState : true)
              color: Color.background

              Column {
                anchors.centerIn: parent
                width: parent.width - Style.space(32)
                spacing: Style.space(6)

                OpticalGlyph {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Style.space(32)
                  height: width
                  text: root.barIcon
                  fontFamily: Style.font.family
                  fontSize: Style.space(28)
                  color: root.detailColor
                }

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                  text: root.lastError !== "" ? root.lastError
                    : (root.cameraError !== "" ? root.cameraError
                      : (root.realtimeMode ? (root.streamLoading
                          ? "Starting real-time video…" : "Waiting for live stream")
                      : (root.loading ? "Loading cameras…"
                        : (root.selectedCamera && !root.selectedConnected
                          ? "Camera " + String(root.selectedCamera.state || "unavailable").toLowerCase()
                          : (root.cameras.length === 0 ? "No Protect cameras found" : "Waiting for camera")))))
                  textFormat: Text.PlainText
                  color: root.lastError !== "" || root.cameraError !== "" ? Color.urgent : root.detailColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Rectangle {
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              width: updateLabel.implicitWidth + Style.space(14)
              height: updateLabel.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: Color.background
              opacity: 0.88
              visible: root.frameUrl !== "" && (root.realtimeMode
                ? embeddedPlayer.playbackState !== MediaPlayer.PlayingState
                : root.frameStale)

              Text {
                id: updateLabel
                anchors.centerIn: parent
                text: root.cameraError !== "" ? root.cameraError
                  : (root.realtimeMode ? "Starting live video…" : "Updating…")
                textFormat: Text.PlainText
                color: root.cameraError !== "" ? Color.urgent : root.detailColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              id: liveButton
              width: parent.width - muteButton.implicitWidth - protectButton.implicitWidth
                - 2 * parent.spacing
              text: viewProcess.running ? "Opening…" : "Pop out"
              iconText: ""
              tooltipText: "Open this camera in a tileable window"
              bordered: true
              enabled: root.selectedConnected && !viewProcess.running
              onClicked: root.openLive()
            }

            Button {
              id: muteButton
              iconText: root.liveMuted ? "" : ""
              tooltipText: root.liveMuted ? "Start live video with audio" : "Start live video muted"
              bordered: true
              selected: root.liveMuted
              enabled: !preferenceProcess.running
              onClicked: root.savePreference("liveMuted", root.liveMuted ? "false" : "true")
            }

            Button {
              id: protectButton
              text: "Protect"
              iconText: ""
              tooltipText: "Open UniFi Protect"
              bordered: true
              onClicked: root.openTarget("protect")
            }
          }

          Text {
            width: parent.width
            visible: root.actionError !== ""
            text: root.actionError
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

        }

        ProtectSetup {
          id: setupPane
          width: parent.width
          visible: root.showingSetup
          configuredUrl: root.instanceUrl
          configuredVerifyTls: root.verifyTls
          connecting: root.connecting
          onConnectRequested: function(url, verifyTls, apiKey) { root.connect(url, verifyTls, apiKey) }
          onForgetRequested: function(url) { root.forget(url) }
          onExternalRequested: function(target) { root.openTarget(target) }
          onViewerRequested: root.showViewer()
        }

        ProtectPreferences {
          id: preferencesPane
          width: parent.width
          visible: root.showingPreferences
          frameFit: root.frameFit
          liveMuted: root.liveMuted
          liveQuality: root.liveQuality
          refreshMode: root.refreshMode
          showOfflineCameras: root.showOfflineCameras
          viewerSize: root.viewerSize
          saving: root.savingPreference
          onPreferenceRequested: function(key, value) { root.savePreference(key, value) }
          onViewerRequested: root.showViewer()
        }
      }
    }
  }
}
