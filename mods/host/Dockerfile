# Rung 1: AppLoad's PC emulator, headless (Qt offscreen platform, software
# Quick backend). Native on the build host; no qemu. Same Ubuntu and Qt
# minor (6.8) as the device build in ../build/Dockerfile.
ARG UBUNTU_IMAGE=ubuntu:25.04@sha256:27771fb7b40a58237c98e8d3e6b9ecdd9289cec69a857fccfb85ff36294dac20
FROM ${UBUNTU_IMAGE}
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      g++ make qt6-base-dev qt6-base-dev-tools qt6-declarative-dev qmake6 \
      qml6-module-qtquick qml6-module-qtquick-window qml6-module-qtquick-controls \
      qml6-module-qtquick-templates qml6-module-qtquick-layouts qml6-module-qtqml \
      qml6-module-qtqml-workerscript qt6-svg-plugins fonts-dejavu-core >/dev/null
ENV PATH=/usr/lib/qt6/libexec:$PATH
COPY src/rm-appload /src/rm-appload
RUN cd /src/rm-appload && qmake6 . >/dev/null && make -j"$(nproc)" >/dev/null 2>&1 && \
    mkdir -p /opt/appload/testing_extensions /opt/appload/applications_root && \
    cp appload /opt/appload/
COPY host/ /src/host/
RUN cd /src/host && qmake6 shot.pro >/dev/null && make >/dev/null && \
    cp pp-shot.so /opt/appload/testing_extensions/ && cp start.qml /opt/appload/_start.qml
WORKDIR /opt/appload
ENV QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QML_XHR_ALLOW_FILE_READ=1
ENTRYPOINT ["/opt/appload/appload"]
