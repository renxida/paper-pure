# Emulator image: stock Paper Pure (tatsu) rootfs + the rmemu shim and fake hardware tree.
# Build it with --platform linux/arm64 (bin/ppemu does), or the image index says amd64.
ARG ROOTFS=pp-emu-rootfs:3.27.2.2

FROM --platform=linux/arm64 ubuntu:24.04 AS build
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    gcc libc6-dev libdrm-dev libp11-kit-dev libssl-dev zlib1g-dev >/dev/null
COPY shim/ /src/shim/
COPY daemon/ /src/daemon/
RUN cd /src && \
    gcc -O2 -Wall -shared -fPIC -o /rmemu-shim.so shim/*.c -ldl -lpthread -lz && \
    gcc -O2 -Wall -shared -fPIC -I/usr/include/p11-kit-1 -o /rmemu-pkcs11.so shim/pkcs11/*.c -lcrypto && \
    gcc -O2 -Wall -o /rmemud daemon/rmemud.c

FROM ${ROOTFS} AS stock

FROM ${ROOTFS}
COPY --from=build /rmemu-shim.so /rmemu-pkcs11.so /rmemud /opt/rmemu/
COPY docker/root/ /opt/rmemu/root/
COPY docker/units/ /opt/rmemu/units/
COPY docker/boot.sh /opt/rmemu/boot.sh
# The stock files docker hides under its own bind mounts (boot.sh restores them).
COPY --from=stock /etc/hosts /etc/hostname /opt/rmemu/stock/
# Every process (including SSH sessions, which get a fresh environment) sees
# the fake hardware, like a shell on the real device. Blank root password for
# the container-only SSH server.
RUN echo /opt/rmemu/rmemu-shim.so > /etc/ld.so.preload && \
    sed -i 's/^root:[^:]*:/root::/' /etc/shadow
EXPOSE 22 8888
# systemd halts on SIGRTMIN+3 (docker stop = shut down cleanly).
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/bin/sh", "/opt/rmemu/boot.sh"]
