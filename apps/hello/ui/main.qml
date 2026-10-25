// paper-pure hello: the smallest AppLoad app. Shows who we are, which
// release this is, and which OS it runs on. No backend.
import QtQuick
import "release.js" as Release

Rectangle {
    id: root
    anchors.fill: parent
    color: "white"

    // AppLoad's contract for a root item.
    signal close
    function unloading() {
        console.log("paper-pure-hello: unloading");
    }

    property string osVersion: "?"

    Component.onCompleted: {
        console.log("paper-pure-hello: shown, release " + Release.id);
        // Needs QML_XHR_ALLOW_FILE_READ=1, which xovi sets for xochitl.
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            const m = xhr.responseText.match(/IMG_VERSION="?([^"\n]+)/);
            root.osVersion = m ? m[1] : "not a reMarkable";
        };
        xhr.open("GET", "file:///etc/os-release");
        xhr.send();
    }

    Column {
        anchors.centerIn: parent
        spacing: 48

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "hello from paper-pure"
            font.pixelSize: 88
            font.bold: true
            color: "black"
        }
        Text {
            objectName: "releaseId"
            anchors.horizontalCenter: parent.horizontalCenter
            text: "release " + Release.id
            font.pixelSize: 56
            color: "black"
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "OS " + root.osVersion
            font.pixelSize: 40
            color: "black"
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 120
        anchors.horizontalCenter: parent.horizontalCenter
        width: 360
        height: 120
        border.width: 4
        border.color: "black"
        color: "white"

        Text {
            anchors.centerIn: parent
            text: "Close"
            font.pixelSize: 48
            color: "black"
        }
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }
    }
}
