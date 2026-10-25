# Firmware: what the tablet runs, and why it stays there

The Paper Pure (codename **tatsu**) is frozen on **OS 3.27.2.2**. That is what it shipped with (checked in Settings, Oct 25, 2026), and every hook, the emulator and sync are proven against that exact build.

reMarkable's firmware never goes in this repo or in our releases (desiderata, "Saying no"). `.gitignore` blocks `*.swu`, `*.ext4` and `rootfs-*/`. Tools download it locally (`emu/bin/ppemu setup`) and check it.

## The image

| | 3.27.2.2 (frozen) | 3.27.1.0 (fallback) |
| --- | --- | --- |
| File | `remarkable-production-image-3.27.2.2-tatsu-public.swu` | `remarkable-production-image-3.27.1.0-tatsu-public.swu` |
| sha256 | `2c64bea8d89ebd2eb81f84485db97bec36dd4bd1fcfbb13e99e0c3ca446a997d` | `7008c8376e49a65b766bbd672f83454d55290af73b099bba396f3d9b2276ce3f` |
| Size | 141,891,584 bytes | 141,768,192 bytes |
| On the mirror since | 2026-05-28 | 2026-05-07 |
| Root fs image inside, sha256 | `bd54d2e5c0c368d28ea62f805e4e78195fa6eafd02c6812e4fafd334a1291cb6` | `fecc5ffccdb90aba9619f01486c9ca40bcebc9ddb640fb20973e3411d7b5badb` |
| In codexctl's index | no | yes, same sha256 |

Where it comes from: reMarkable's public update bucket, the one [codexctl](https://github.com/Jayy001/codexctl) uses. It is listable:

```
https://remarkable-software.s3.us-east-2.amazonaws.com/<file>
https://remarkable-software.s3.us-east-2.amazonaws.com/?prefix=remarkable-production-image-3.2
```

What is inside (3.27.2.2): `/etc/os-release` says `IMG_VERSION="3.27.2.2"`, Codex Linux 5.7.124 (Yocto scarthgap). `/etc/version` is `20260520084102`. Kernel `6.12.49+git-imx93-tatsu`. Every device tree says `model = "reMarkable Tatsu"`. swupdate runs with `-H tatsu:1.0`.

## Checking it

A `.swu` is a cpio archive. `sw-description` lists every part with its sha256, and `sw-description.sig` signs it: RSA 3072, PKCS#1 v1.5, SHA-256. The public key ships inside the image at `/usr/share/swupdate/swupdate-payload-key-pub.pem` (sha256 `7f77934c86f157a887e942ee64b1916ea957dba2bc970fb1696501d3bdc2ce78`).

```bash
sha256sum remarkable-production-image-3.27.2.2-tatsu-public.swu       # 2c64bea8...a997d
mkdir x && cd x && cpio -id < ../remarkable-production-image-3.27.2.2-tatsu-public.swu
openssl dgst -sha256 -verify swupdate-payload-key-pub.pem \
    -signature sw-description.sig sw-description                       # Verified OK
sha256sum remarkable-production-image-3.27.2.2-tatsu-public.ext4.verity.gz   # = sha256 in sw-description
```

`emu/tools/import-rootfs.sh` does all three, with the key's sha256 pinned.

Why trust a key that comes out of the image it checks? Because it also checks a release someone else indexed. 3.27.1.0's sha256 matches codexctl's public index, and its `sw-description.sig` verifies with the same key found in 3.27.2.2 (run Oct 25, 2026: `Verified OK`). So 3.27.2.2 is signed by the key reMarkable signs real releases with.

## Newer builds exist; we don't move

On the mirror for tatsu, Oct 25, 2026:

| Version | On the mirror since |
| --- | --- |
| 3.27.1.0 | 2026-05-07 |
| **3.27.2.2** | 2026-05-28 |
| 3.27.3.0 | 2026-06-30 |
| 3.28.0.172 | 2026-09-03 |
| 3.29.0.153 | 2026-10-19 |

Why we stay:

- **Hooks are pinned to the OS.** AppLoad v0.5.3 targets 3.27. v0.6.0 and later hook the 3.28/3.29 side menu (see `mods/README.md`). qt-resource-rebuilder's hashtab is made from the exact xochitl binary.
- **Sync.** rmfakecloud says it is tested up to 3.27.1. 3.27.2.2 is one patch newer and is being proven in the emulator. Newer is further out.
- **The emulator runs the same build**, so a pass there means the same hooks resolve on the tablet. That only holds while the tablet stays on it.
- **Nothing is broken.** The tablet is offline-first. Writing feel is stock.

How the tablet stays there: `device/` masks the update units and blocks the update hosts. See `device/README.md`.

Moving later is a project, not an update: fetch and check the new image, boot it in the emulator, re-pin and re-prove the mods and sync, then install it on purpose. 3.27.1.0 is the fallback if sync can't be made to work on 3.27.2.2. It is inside rmfakecloud's tested range and verifies with the same key.

## On the tablet

- **Two root slots, A and B** (`root_a`, `root_b`). An OTA writes the slot it isn't running from, then switches slots at the next reboot (`rm-apply-ota.service`). The boot ROM also switches slots by itself if a slot keeps failing to boot (SPL log: `ABINFO: A in error state, switch to B`). `rm-sanity.service` clears that error count 60 s after each boot.
- **Developer mode turns off verity.** In u-boot's environment, `unlocked=yes` boots `root=/dev/mmcblk0pN` directly. With it off, the root is `/dev/dm-0` through dm-verity, with signed root hashes and module signatures enforced. So in developer mode `/` is plain ext4 that can be remounted read-write. (Read from the u-boot image, not yet seen on the tablet.)
- `/home` is the encrypted user partition. It survives reboots and slot switches. `/data` and `/var/lib/remarkable` are small persistent partitions.
- **With a passcode set, `/home` waits for xochitl.** `homecryptor` runs `homekey load`, which waits in `systemd-ask-password` (`--timeout=0`) for the passcode, and only xochitl's passcode screen answers it (its pincode module). reMarkable's own comment in `xochitl-shutdown.service`: "Xochitl needs to be started before home.mount, as it runs pincode-rs to unlock the home partition." Everything of ours lives on `/home`, so **nothing of ours may be ordered before xochitl**: xochitl would wait for `/home`, its 60 s `JobTimeoutSec` would run out, and `OnFailure=emergency.target` reboots, every boot, with no UI to type the passcode into. `pp-device.sh verify` checks this, and the device test bed boots with a passcode stand-in (`device/README.md`). Without a passcode there is nothing to ask for and `/home` mounts by itself (read from `homekey`'s strings, `userPinSet`, `Token PIN not set`; the emulator mounts `/home` as a volume, so never seen).
