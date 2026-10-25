# Test bed only: the stock tatsu rootfs plus a tiny PID 1 wrapper that
# fakes the few hardware bits systemd and our scripts look at. Built locally
# from the extracted rootfs (pp-device-rootfs, made by test/run.sh with
# `docker import`); never pushed anywhere.
ARG BASE=pp-device-rootfs:3.27.2.2
FROM ${BASE}
COPY root/ /
ENTRYPOINT ["/pp-testbed/boot.sh"]
