// Testing extension for AppLoad's PC emulator (it dlopens ./testing_extensions/*.so
// before creating the app). Waits PP_SHOT_DELAY_MS (default 3000), saves the
// window to PP_SHOT (default shot.png), plays PP_EVENTS, and quits.
// PP_EVENTS is a script in window pixels (the Pure's 1404x1872), e.g.
//   "tap 702 1692; wait 1500; shot /out/after.png"
// tap X Y: a press and release there, as a finger would. wait MS. shot PATH.
// Our own code, not upstream's.
#include <QCoreApplication>
#include <QGuiApplication>
#include <QMouseEvent>
#include <QQuickWindow>
#include <QTimer>
#include <cstdio>

static QQuickWindow *window() {
    for (QWindow *w : QGuiApplication::topLevelWindows())
        if (auto *q = qobject_cast<QQuickWindow *>(w)) return q;
    return nullptr;
}

static int shot(const QString &path) {
    QQuickWindow *q = window();
    if (!q) return 1;
    QImage img = q->grabWindow();
    int rc = img.save(path) ? 0 : 1;
    fprintf(stderr, "pp-shot: %dx%d -> %s (%s)\n", img.width(), img.height(), qPrintable(path), rc ? "FAILED" : "ok");
    return rc;
}

static void tap(qreal x, qreal y) {
    QQuickWindow *q = window();
    if (!q) return;
    const QPointF p(x, y), g = q->mapToGlobal(p);
    QMouseEvent press(QEvent::MouseButtonPress, p, g, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    QCoreApplication::sendEvent(q, &press);
    QMouseEvent release(QEvent::MouseButtonRelease, p, g, Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
    QCoreApplication::sendEvent(q, &release);
    fprintf(stderr, "pp-shot: tap %g %g\n", x, y);
}

// One event per call; the next one runs from the event loop, so the UI
// reacts to each before the next.
static void play(QStringList events, int rc) {
    QStringList w;
    while (w.isEmpty() && !events.isEmpty()) w = events.takeFirst().split(' ', Qt::SkipEmptyParts);
    if (w.isEmpty()) {
        QCoreApplication::exit(rc);
        return;
    }
    int wait = 0;
    if (w[0] == "tap" && w.size() == 3) tap(w[1].toDouble(), w[2].toDouble());
    else if (w[0] == "wait" && w.size() == 2) wait = w[1].toInt();
    else if (w[0] == "shot" && w.size() == 2) rc |= shot(w[1]);
    else {
        fprintf(stderr, "pp-shot: bad event '%s'\n", qPrintable(w.join(' ')));
        QCoreApplication::exit(2);
        return;
    }
    QTimer::singleShot(wait, [events, rc] { play(events, rc); });
}

static void arm() {
    int delay = qEnvironmentVariableIntValue("PP_SHOT_DELAY_MS");
    QTimer::singleShot(delay > 0 ? delay : 3000, [] {
        int rc = shot(qEnvironmentVariable("PP_SHOT", "shot.png"));
        play(qEnvironmentVariable("PP_EVENTS").split(';'), rc);
    });
}
Q_COREAPP_STARTUP_FUNCTION(arm)

extern "C" void _ext_load() {}
