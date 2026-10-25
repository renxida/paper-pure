# apps/hello

The smallest AppLoad app. It shows "hello from paper-pure", the release id it was built for, and the OS version it is running on (read live from `/etc/os-release`). It has a Close button and no backend. It exists to prove the whole path: build, emulator, tablet.

```
manifest.json      AppLoad manifest (id paper-pure-hello, frontend only)
application.qrc    what goes into resources.rcc
ui/main.qml        the app; root item has AppLoad's `signal close` and `unloading()`
build.sh           -> out/paper-pure-hello/{manifest.json,resources.rcc,release-id}
test.sh            rung 1: run it headless in AppLoad's PC emulator, compare with test/host-golden.png
```

- **Release id.** `RELEASE_ID=<id> apps/hello/build.sh` bakes the id into `ui/release.js`, which is generated at build time and never committed. `mods/build.sh` passes its own `RELEASE_ID` through, so the id on screen is the id of the release the tablet runs. The default is `dev-<git short sha>`.
- **On the device.** The app lives in `/home/root/xovi/exthome/appload/paper-pure-hello/`. Open it from the side menu, then **AppLoad**, then **Hello**. Close it with its Close button, or with AppLoad's swipe down from the top centre.
- **Requirements.** `build.sh` needs Qt's `rcc` (apt `qt6-base-dev-tools`). The `.rcc` is plain data, so one build serves both the device and the host emulator. `test.sh` needs Docker; the first run builds the `pp-mods-host` image (about 4 min).

## Status

Verified Oct 25 2026 (x86_64 dev container):

- **Rung 1.** `apps/hello/test.sh --update` and then `apps/hello/test.sh` both ran AppLoad's PC emulator (rm-appload v0.5.3, Qt 6.8.3, `QT_QPA_PLATFORM=offscreen`). The log shows `paper-pure-hello: shown, release test` and `pp-shot: 1404x1872 -> /out/shot.png (ok)`. `pngdiff` then reported `0 of 2628288 pixels differ`. A run takes about 5 s plus 10 s for the pixel diff. Negative check: a screenshot from a build with another release id differs by 10632 pixels, exit 1.
- **Rung 2, manual install.** After `mods/install.sh emu` on a freshly reset emulator, the side menu shows **AppLoad**, AppLoad lists **Hello**, and the app shows `release dev-7581a30` and `OS 3.27.2.2`. The xochitl log has `paper-pure-hello: shown, release dev-7581a30`. Close calls `unloading()` (log `[AppLoad]: Resources unloaded for "paper-pure-hello"`). `mods/emu-smoke.sh` does all this in 27 s.
- **Rung 2, through the update agent.** After pp-agent installed the signed release `e2e-1`, the app shows `release e2e-1` (`mods/emu-smoke.sh`).

Not verified:

- **The real tablet.** Fonts there are xochitl's own: the host rendering uses DejaVu, so host and device screenshots differ by design.
- **Pen input inside the app.** Only finger taps were used.
- **AppLoad's windowed mode** (long-press the icon).

Open question for Cedar: the host golden is pixel-exact. Fine while only we change the app; loosen the tolerance (`pngdiff.py --max-diff N --tol T`) if font or Qt updates make it flaky.
