import QtQuick

Item {
  id: root
  property string frameUrl: ""
  property bool fillFrame: false
  property int visibleIndex: 0
  property real sourceAspect: current.sourceSize.height > 0
    ? current.sourceSize.width / current.sourceSize.height : 16 / 9

  function swapFrame() {
    if (frameUrl === "") return
    var next = visibleIndex === 0 ? second : first
    next.source = frameUrl
  }

  onFrameUrlChanged: swapFrame()

  Image {
    id: first
    anchors.fill: parent
    fillMode: root.fillFrame ? Image.PreserveAspectCrop : Image.PreserveAspectFit
    asynchronous: true
    cache: false
    smooth: true
    visible: root.visibleIndex === 0
    onStatusChanged: if (status === Image.Ready && root.visibleIndex !== 0) root.visibleIndex = 0
  }

  Image {
    id: second
    anchors.fill: parent
    fillMode: root.fillFrame ? Image.PreserveAspectCrop : Image.PreserveAspectFit
    asynchronous: true
    cache: false
    smooth: true
    visible: root.visibleIndex === 1
    onStatusChanged: if (status === Image.Ready && root.visibleIndex !== 1) root.visibleIndex = 1
  }

  readonly property var current: visibleIndex === 0 ? first : second
}
