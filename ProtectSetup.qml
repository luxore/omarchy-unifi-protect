pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui

FocusScope {
  id: root

  property string configuredUrl: ""
  property bool configuredVerifyTls: true
  property bool connecting: false
  property string message: ""
  property bool messageIsError: false

  signal connectRequested(string url, bool verifyTls, string apiKey)
  signal forgetRequested(string url)
  signal externalRequested(string target)
  signal viewerRequested()

  property string localError: ""
  property bool draftVerifyTls: true

  implicitWidth: Style.space(430)
  implicitHeight: Math.min(setupColumn.implicitHeight, Style.space(570))

  function load() {
    urlField.text = configuredUrl
    apiKeyField.text = ""
    draftVerifyTls = configuredVerifyTls
    localError = ""
  }

  function connect() {
    localError = ""
    var address = urlField.text.trim()
    var key = apiKeyField.text.trim()
    if (address === "") {
      localError = "Enter the HTTPS address of the UniFi console"
      urlField.forceActiveFocus()
      return
    }
    if (key === "") {
      localError = "Enter a UniFi API key"
      apiKeyField.forceActiveFocus()
      return
    }
    root.connectRequested(address, draftVerifyTls, key)
    apiKeyField.text = ""
  }

  Component.onCompleted: load()

  Keys.onEscapePressed: function(event) {
    root.viewerRequested()
    event.accepted = true
  }

  Controls.ScrollView {
    anchors.fill: parent
    clip: true
    contentWidth: availableWidth
    Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

    Column {
      id: setupColumn
      width: parent.width
      spacing: Style.space(12)

      PanelSectionHeader { text: "UNIFI CONSOLE" }

      Text {
        width: parent.width
        text: "Use the HTTPS root address of the UniFi OS console that runs Protect."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(Color.popups.text, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: urlField
        width: parent.width
        placeholderText: "https://unifi.local"
        enabled: !root.connecting
      }

      Toggle {
        width: parent.width
        label: "Verify TLS certificate"
        description: "Recommended. Turn off only for a known self-signed console on a private network."
        checked: root.draftVerifyTls
        enabled: !root.connecting
        onClicked: root.draftVerifyTls = !root.draftVerifyTls
      }

      Text {
        width: parent.width
        visible: !root.draftVerifyTls
        text: "Certificate verification is off. HTTPS remains encrypted, but console impersonation cannot be detected."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      PanelSeparator { foreground: Color.popups.text }
      PanelSectionHeader { text: "API KEY" }

      Text {
        width: parent.width
        text: "Create a dedicated key in UniFi Site Manager under Settings > API Keys. It is tested before being stored in Secret Service."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(Color.popups.text, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: apiKeyField
          width: parent.width - connectButton.implicitWidth - parent.spacing
          password: true
          placeholderText: "UniFi API key"
          enabled: !root.connecting
          Keys.onReturnPressed: root.connect()
        }

        Button {
          id: connectButton
          text: root.connecting ? "Connecting…" : "Connect"
          bordered: true
          focusable: true
          enabled: !root.connecting
          onClicked: root.connect()
        }
      }

      Row {
        spacing: Style.space(8)

        Button {
          text: "Open API keys"
          iconText: ""
          focusable: true
          onClicked: root.externalRequested("api-keys")
        }

        Button {
          text: "Forget local key"
          foreground: Color.urgent
          focusable: true
          enabled: !root.connecting && root.configuredUrl !== ""
          onClicked: root.forgetRequested(root.configuredUrl)
        }
      }

      Text {
        width: parent.width
        visible: root.localError !== "" || root.message !== ""
        text: root.localError !== "" ? root.localError : root.message
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.localError !== "" || root.messageIsError ? Color.urgent : Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
