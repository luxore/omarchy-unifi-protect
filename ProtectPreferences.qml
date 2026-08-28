pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui

FocusScope {
  id: root

  property string frameFit: "fit"
  property bool liveMuted: false
  property string liveQuality: "auto"
  property string refreshMode: "fast"
  property bool showOfflineCameras: true
  property string viewerSize: "large"
  property bool saving: false
  property string message: ""
  property bool messageIsError: false
  signal preferenceRequested(string key, string value)
  signal viewerRequested()

  implicitWidth: Style.space(680)
  implicitHeight: Math.min(preferencesColumn.implicitHeight, Style.space(560))

  Keys.onEscapePressed: function(event) {
    root.viewerRequested()
    event.accepted = true
  }

  Controls.ScrollView {
    anchors.fill: parent
    clip: true
    contentWidth: availableWidth
    Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff
    Controls.ScrollBar.vertical.policy: Controls.ScrollBar.AsNeeded

    Column {
      id: preferencesColumn
      width: parent.width
      spacing: Style.space(12)

      PanelSectionHeader { text: "VIEWER" }

      Text {
        width: parent.width
        text: "Viewer size"
        textFormat: Text.PlainText
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      ButtonGroup {
        options: [
          { value: "comfortable", label: "Medium" },
          { value: "large", label: "Large" }
        ]
        value: root.viewerSize
        enabled: !root.saving
        onChanged: function(value) { root.preferenceRequested("viewerSize", value) }
      }

      Text {
        width: parent.width
        text: "Viewer framing"
        textFormat: Text.PlainText
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      ButtonGroup {
        options: [
          { value: "fit", label: "Fit whole image" },
          { value: "fill", label: "Fill frame" }
        ]
        value: root.frameFit
        enabled: !root.saving
        onChanged: function(value) { root.preferenceRequested("frameFit", value) }
      }

      Text {
        width: parent.width
        text: "Viewer mode"
        textFormat: Text.PlainText
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      ButtonGroup {
        options: [
          { value: "realtime", label: "Real-time" },
          { value: "fast", label: "Fast · 0.75 s" },
          { value: "balanced", label: "Balanced · 1 s" },
          { value: "efficient", label: "Efficient · 2 s" }
        ]
        value: root.refreshMode
        enabled: !root.saving
        onChanged: function(value) { root.preferenceRequested("refreshMode", value) }
      }

      Toggle {
        width: parent.width
        label: "Show offline cameras"
        description: "Keep disconnected cameras in the camera switcher"
        checked: root.showOfflineCameras
        enabled: !root.saving
        onClicked: root.preferenceRequested(
          "showOfflineCameras", root.showOfflineCameras ? "false" : "true")
      }

      PanelSeparator { foreground: Color.popups.text }
      PanelSectionHeader { text: "LIVE VIDEO" }

      Text {
        width: parent.width
        text: "Preferred quality"
        textFormat: Text.PlainText
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      ButtonGroup {
        options: [
          { value: "auto", label: "Auto" },
          { value: "high", label: "High" },
          { value: "medium", label: "Medium" },
          { value: "low", label: "Low" }
        ]
        value: root.liveQuality
        enabled: !root.saving
        onChanged: function(value) { root.preferenceRequested("liveQuality", value) }
      }

      Toggle {
        width: parent.width
        label: "Start live video muted"
        description: "Use the speaker button in Viewer to change this quickly"
        checked: root.liveMuted
        enabled: !root.saving
        onClicked: root.preferenceRequested("liveMuted", root.liveMuted ? "false" : "true")
      }

      Text {
        width: parent.width
        text: "Pop-out controls: scroll to zoom, horizontal scroll or Ctrl+arrows to pan, Ctrl+0 to reset, M to mute, and F for fullscreen."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(Color.popups.text, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        visible: root.message !== ""
        text: root.message
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.messageIsError ? Color.urgent : Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
