// Testing extension for AppLoad's PC emulator (it dlopens ./testing_extensions/*.so
// before creating the app). Waits PP_SHOT_DELAY_MS (default 3000), saves the
// window to PP_SHOT (default shot.png) and quits. Our own code, not upstream's.
#include <QCoreApplication>
#include <QGuiApplication>
#include <QQuickWindow>
#include <QTimer>
#include <cstdio>

static void arm() {
    int delay = qEnvironmentVariableIntValue("PP_SHOT_DELAY_MS");
    QTimer::singleShot(delay > 0 ? delay : 3000, [] {
        const QString path = qEnvironmentVariable("PP_SHOT", "shot.png");
        int rc = 1;
        for (QWindow *w : QGuiApplication::topLevelWindows()) {
            if (auto *q = qobject_cast<QQuickWindow *>(w)) {
                QImage img = q->grabWindow();
                rc = img.save(path) ? 0 : 1;
                fprintf(stderr, "pp-shot: %dx%d -> %s (%s)\n", img.width(), img.height(),
                        qPrintable(path), rc ? "FAILED" : "ok");
                break;
            }
        }
        QCoreApplication::exit(rc);
    });
}
Q_COREAPP_STARTUP_FUNCTION(arm)

extern "C" void _ext_load() {}
