# Drop-in replacement image: the stock Lidarr container image with its application
# directory replaced by a locally built Lidarr. Everything else (s6 init, PUID/PGID
# handling, chromaprint, package_info marking updates as Docker-managed) comes from
# the base image, so the result runs with the stock container's exact settings.
#
# Build context must contain a "Lidarr/" directory produced by build.sh. The runtime
# MUST match the base image's C library: linuxserver images are Alpine, so use
#   ./build.sh --backend --frontend --packages --runtime linux-musl-x64 --framework net8.0
#   (output: _artifacts/linux-musl-x64/net8.0/Lidarr)
# A glibc (linux-x64) build fails inside Alpine with "unable to exec ...: No such file".
#
# BASE_IMAGE: the image the stock container runs (linuxserver or hotio).
# APP_DIR:    where that image keeps the Lidarr binaries:
#             linuxserver -> /app/lidarr/bin, hotio -> /app/bin
ARG BASE_IMAGE=lscr.io/linuxserver/lidarr:latest
FROM ${BASE_IMAGE}
ARG APP_DIR=/app/lidarr/bin

RUN rm -rf "${APP_DIR}"
COPY Lidarr/ ${APP_DIR}/
