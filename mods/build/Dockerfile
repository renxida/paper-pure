# Builds xovi, qt-resource-rebuilder, AppLoad and our apps for the Paper Pure
# (aarch64). Native arm64 container; on x86 hosts it runs under qemu-user.
#
# Why Ubuntu 25.04: the tablet's OS 3.27.2.2 ships Qt 6.8.2. AppLoad needs
# Qt >= 6.7 headers (QQuickItem::setFocusPolicy), Ubuntu 24.04 has 6.4.
# 25.04 has 6.8.3, the same minor (Qt keeps patch releases binary compatible
# both ways). Debian trixie (6.8.2) would be exact, but deb.debian.org is
# not reachable from our build hosts. The tablet has glibc 2.39 and GCC 13's
# libstdc++, so we compile with g++-13 and check-abi.sh proves no newer symbol
# version is needed.
#
# Inputs (build context, prepared by mods/build.sh): src/<repo> at the commits
# pinned in mods/versions.lock, plus apps/.
# Output (--output type=local): /out/xovi-tatsu.tar.gz and friends.

ARG RUST_IMAGE=rust:1.89.0-slim-bookworm@sha256:d7fc7de78bb8c1469933aeecbf801314d30d7d6e9f0578bba4cfa285bfa37fe6
ARG UBUNTU_IMAGE=ubuntu:25.04@sha256:27771fb7b40a58237c98e8d3e6b9ecdd9289cec69a857fccfb85ff36294dac20

# qmldiff (Rust) is only a static library, so cross-compiling it on the build
# host needs no aarch64 linker and skips running cargo under qemu.
# Behind a TLS-intercepting proxy, pass its CA as the optional "ca" secret
# (mods/build.sh does when PP_BUILD_CA is set); it stays in this stage only.
FROM --platform=$BUILDPLATFORM ${RUST_IMAGE} AS qmldiff
COPY src/qmldiff /src/qmldiff
WORKDIR /src/qmldiff
RUN --mount=type=secret,id=ca,required=false \
    if [ -s /run/secrets/ca ]; then cp /run/secrets/ca /usr/local/share/ca-certificates/build-ca.crt && update-ca-certificates >/dev/null; fi && \
    rustup target add aarch64-unknown-linux-gnu && \
    cargo build --locked --release --lib --target aarch64-unknown-linux-gnu && \
    cp target/aarch64-unknown-linux-gnu/release/libqmldiff.a /libqmldiff.a

FROM ${UBUNTU_IMAGE} AS base
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      make cmake python3 file binutils \
      qt6-base-dev qt6-base-dev-tools qt6-declarative-dev qmake6 >/dev/null
# GCC 13, like the tablet's libstdc++ (qmake uses plain g++, hence the links).
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends gcc-13 g++-13 >/dev/null && \
    ln -sf /usr/bin/gcc-13 /usr/local/bin/gcc; ln -sf /usr/bin/gcc-13 /usr/local/bin/cc; \
    ln -sf /usr/bin/g++-13 /usr/local/bin/g++; ln -sf /usr/bin/g++-13 /usr/local/bin/c++
ENV PATH=/usr/local/bin:/usr/lib/qt6/libexec:$PATH XOVI_REPO=/src/xovi

FROM base AS build
COPY src/ /src/
COPY --from=qmldiff /libqmldiff.a /src/rm-xovi-extensions/qt-resource-rebuilder/libqmldiff.a

# xovi: the LD_PRELOAD loader
RUN cmake -S /src/xovi -B /build/xovi -DCMAKE_BUILD_TYPE=Release >/dev/null && \
    cmake --build /build/xovi -j"$(nproc)" >/dev/null

# qt-resource-rebuilder (its Makefile expects a Yocto SDK environment; these
# variables stand in for it). libqmldiff.a is already in place.
RUN cd /src/rm-xovi-extensions/qt-resource-rebuilder && \
    make OECORE_TARGET_ARCH=aarch64 SDKTARGETSYSROOT=/ CFLAGS=-O2 \
         CC="gcc -D_GNU_SOURCE -fPIC" \
         CXX="g++ -O2 -fPIC -I/usr/include/aarch64-linux-gnu/qt6 -I/usr/include/aarch64-linux-gnu/qt6/QtCore" >/dev/null

# AppLoad (xovi extension build). make.sh uses qmake6 and rcc from PATH.
RUN cd /src/rm-appload/xovi && \
    ./make.sh > /build/appload.log 2>&1 || { tail -40 /build/appload.log; exit 1; }

# Our apps
ARG RELEASE_ID=dev
COPY apps/ /apps/
RUN RELEASE_ID=${RELEASE_ID} RCC=/usr/lib/qt6/libexec/rcc /apps/hello/build.sh /build/apps/paper-pure-hello

# Our glue for the device (hashtab, status, emulator start).
COPY device/ /src/device/
COPY BUILDINFO /src/BUILDINFO

# Assemble /home/root/xovi exactly like upstream's release workflow
# (rm-xovi-extensions .github/workflows/build-release.yml), plus AppLoad and
# our apps.
RUN set -e; x=/out/tree/xovi; \
    mkdir -p $x/extensions.d $x/inactive-extensions $x/exthome/qt-resource-rebuilder $x/exthome/appload \
             $x/scripts/debug $x/scripts/pre-start $x/scripts/post-start $x/scripts/pre-stock $x/scripts/post-stock \
             $x/services/xochitl.service; \
    cp -r /src/rm-xovi-extensions/xovi-setup/* $x/; \
    cp /build/xovi/xovi.so $x/xovi.so; \
    cp /src/rm-xovi-extensions/qt-resource-rebuilder/qt-resource-rebuilder.so $x/extensions.d/; \
    cp /src/rm-appload/xovi/appload.so $x/extensions.d/; \
    cp -r /build/apps/paper-pure-hello $x/exthome/appload/; \
    cp -r /src/device $x/paper-pure; \
    chmod a+x $x/start $x/stock $x/debug $x/rebuild_hashtable; \
    ln -s /home/root/xovi/extensions.d $x/services/xochitl.service/extensions.d; \
    ln -s /home/root/xovi/exthome $x/services/xochitl.service/exthome; \
    cp /src/BUILDINFO $x/BUILDINFO; \
    (cd $x && find . -type f -name '*.so' | sort | xargs sha256sum) >> $x/BUILDINFO; \
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -C /out/tree -czf /out/xovi-tatsu.tar.gz xovi; \
    cp $x/BUILDINFO /out/BUILDINFO; \
    for f in $x/xovi.so $x/extensions.d/*.so; do echo "== $(basename $f)"; readelf -V -d -W "$f"; done > /out/elf-info.txt

FROM scratch
COPY --from=build /out/ /
