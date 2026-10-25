// Host stand-in for xochitl's screen: AppLoad's PC emulator loads ./_start.qml.
// Upstream's is sized for the Paper Pro (1620x2160); this one is the Pure's
// panel, 1404x1872, unscaled, and starts the app named on the command line.
import QtQuick
import QtQuick.Window
import net.asivery.AppLoad 1.0

Window {
    visible: true
    width: 1404
    height: 1872
    color: "white"

    Loader {
        // A fixed size, not anchors: AppLoad picks the app's aspect ratio from
        // this size as soon as the app is launched below.
        width: 1404
        height: 1872
        source: "qrc:/appload/qml/appload.qml"
        onLoaded: {
            item.visible = true;
            if (AppLoadEmuOnly.startApp) {
                console.log("pp-host: starting " + AppLoadEmuOnly.startApp);
                AppLoadLauncher.requestLaunch(AppLoadEmuOnly.startApp, [], {}, false);
            }
        }
    }
}
