# syntax=docker/dockerfile:1
# MPFever dedicated server (experimental): the Windows game under Wine 11 on Linux, Steam through Madeira Dock (Valve's own client library),
# no GPU needed. See docs/LINUX-SERVER.md.
#
# Build context: this folder. The MPFever package (launcher, native module, mod, built from this repository by build.bat / CI) is an input:
#   server/dist/MPFever-server.zip   (the release\MPFever-<version>-server.zip of a build)
# The image contains no Transport Fever 3 file and no Valve file: the game is imported from the user's own copy (install-game) and Valve's
# client library is fetched from Valve at the first start.
# --build-arg APT_MIRROR=http://<mirror>/ubuntu uses another Ubuntu mirror (when archive.ubuntu.com is unreachable).

ARG UBUNTU=ubuntu:24.04

# ---------------------------------------------------------------- Madeira Dock, from source at a pinned commit (GPL-3.0-or-later)
FROM ${UBUNTU} AS dock
ARG APT_MIRROR=
RUN if [ -n "$APT_MIRROR" ]; then sed -i "s#http://archive.ubuntu.com/ubuntu#$APT_MIRROR#g; s#http://security.ubuntu.com/ubuntu#$APT_MIRROR#g" /etc/apt/sources.list.d/ubuntu.sources; fi
ARG DOCK_REPO=https://github.com/willfaust/madeira-dock.git
ARG DOCK_REF=67780ba92e60dbfac4fe80eaf2ce34b9ea1a1c60
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates git gcc-mingw-w64-x86-64 >/dev/null \
 && git clone -q "$DOCK_REPO" /src && git -C /src checkout -q "$DOCK_REF" && test "$(git -C /src rev-parse HEAD)" = "$DOCK_REF"
WORKDIR /src
RUN x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wno-cast-function-type -static -s -o /dockhost.exe \
      src/main.c src/probe.c src/session.c src/launch.c src/validation.c src/auth.c src/client_layout.c src/scm.c src/hold.c -ladvapi32 -luser32

# ---------------------------------------------------------------- the Vulkan layer that makes drawing a no-op
FROM ${UBUNTU} AS vklayer
ARG APT_MIRROR=
RUN if [ -n "$APT_MIRROR" ]; then sed -i "s#http://archive.ubuntu.com/ubuntu#$APT_MIRROR#g; s#http://security.ubuntu.com/ubuntu#$APT_MIRROR#g" /etc/apt/sources.list.d/ubuntu.sources; fi
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc libc6-dev libvulkan-dev >/dev/null
COPY vklayer/vk_nulldraw.c /src/vk_nulldraw.c
RUN gcc -O2 -shared -fPIC -Wall -Werror -o /libVkLayer_mpf_nulldraw.so /src/vk_nulldraw.c -lpthread

# ---------------------------------------------------------------- runtime
FROM ${UBUNTU} AS runtime
ARG APT_MIRROR=
RUN if [ -n "$APT_MIRROR" ]; then sed -i "s#http://archive.ubuntu.com/ubuntu#$APT_MIRROR#g; s#http://security.ubuntu.com/ubuntu#$APT_MIRROR#g" /etc/apt/sources.list.d/ubuntu.sources; fi
ARG WINE_VERSION=11.0.0.0~noble-1
ENV DEBIAN_FRONTEND=noninteractive
RUN dpkg --add-architecture i386 \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends ca-certificates curl wget gnupg2 procps xvfb xauth \
      libvulkan1 mesa-vulkan-drivers libgl1 libasound2t64 libgnutls30t64 libfreetype6 fonts-dejavu-core \
      python3-minimal python3-qrcode mono-runtime libmono-system-windows-forms4.0-cil libmono-system-drawing4.0-cil \
      libmono-system-core4.0-cil libmono-system-io-compression4.0-cil libmono-system-io-compression-filesystem4.0-cil \
      libmono-security4.0-cil ca-certificates-mono libgdiplus \
 && mkdir -pm755 /etc/apt/keyrings \
 && wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
 && wget -qNP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends wine-stable=${WINE_VERSION} wine-stable-amd64=${WINE_VERSION} wine-stable-i386=${WINE_VERSION} \
 && for b in wine wineserver wineboot; do ln -s /opt/wine-stable/bin/$b /usr/local/bin/$b; done \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -d /data -u 1001 -s /bin/bash tf3 \
 && mkdir -p /data /game /opt/mpfever && chown tf3:tf3 /data /game

# the MPFever package built from this repository (launcher patched for Wine + Dock, native module, mod, signatures)
COPY dist/MPFever-server.zip /tmp/mpfever-server.zip
RUN python3 -m zipfile -e /tmp/mpfever-server.zip /tmp/pkg && mkdir -p /opt/mpfever/pkg \
 && cp -r /tmp/pkg/*/mod /tmp/pkg/*/winhttp.dll /tmp/pkg/*/mpfever_sigs.txt /tmp/pkg/*/MPFever.exe /tmp/pkg/*/MPFever.exe.config /tmp/pkg/*/LICENSE.txt /opt/mpfever/pkg/ \
 && rm -rf /tmp/pkg /tmp/mpfever-server.zip

COPY --from=dock /dockhost.exe /opt/mpfever/dockhost.exe
COPY --from=dock /src/LICENSE /src/COPYING /src/LICENSE-EXCEPTION.md /opt/mpfever/licenses/madeira-dock/
COPY --from=vklayer /libVkLayer_mpf_nulldraw.so /opt/mpfever/libVkLayer_mpf_nulldraw.so
COPY vklayer/VkLayer_mpf_nulldraw.json /etc/vulkan/implicit_layer.d/VkLayer_mpf_nulldraw.json
COPY scripts/ /opt/mpfever/scripts/
COPY config/ /opt/mpfever/config/
RUN sed -i 's/\r$//' /opt/mpfever/scripts/*.sh && chmod 755 /opt/mpfever/scripts/*.sh

ARG VCS_REF=unknown
ARG SOURCE_REPO=https://github.com/dkdknight/MPFever
ARG VERSION=experimental
LABEL org.opencontainers.image.title="MPFever dedicated server (experimental)" \
      org.opencontainers.image.description="Transport Fever 3 under Wine with Madeira Dock; contains no game or Valve files" \
      org.opencontainers.image.source="${SOURCE_REPO}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.revision="${VCS_REF}" org.opencontainers.image.version="${VERSION}"

USER tf3
WORKDIR /data
VOLUME ["/data", "/game"]
EXPOSE 28090
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=60s --timeout=10s --start-period=300s --retries=3 CMD ["/opt/mpfever/scripts/healthcheck.sh"]
ENTRYPOINT ["/opt/mpfever/scripts/entrypoint.sh"]
CMD ["run"]
