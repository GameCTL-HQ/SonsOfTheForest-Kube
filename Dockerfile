# GameCTL Sons of the Forest dedicated server image — built from scratch so GameCTL
# controls exactly what runs. The server is Windows-only (app 2465200,
# anonymous), so it runs under Wine (WineHQ's official stable build) with a
# virtual display (xvfb). The ~2GB server installs to the persistent volume
# at first boot (fleet NFS-install model); a normal boot never runs steamcmd.
# GAMECTL_VALIDATE=1 / UPDATE_ON_START=true forces a validate/update.
#
# Sources: Debian's official base, Valve's official steamcmd tarball,
# WineHQ's official apt repository. No community images anywhere.
FROM debian:12-slim

RUN dpkg --add-architecture i386 && apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl gnupg tini util-linux coreutils procps \
       lib32gcc-s1 xvfb xauth cabextract \
    && rm -rf /var/lib/apt/lists/*

# WineHQ official repo — stable line (Debian bookworm ships wine 8, too old
# for a 2025 title; WineHQ stable is the upstream-supported build).
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://dl.winehq.org/wine-builds/winehq.key -o /etc/apt/keyrings/winehq-archive.key \
    && curl -fsSL https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources -o /etc/apt/sources.list.d/winehq-bookworm.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends --install-recommends winehq-stable \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/steamcmd && cd /opt/steamcmd \
    && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar xz \
    && /opt/steamcmd/steamcmd.sh +quit \
    && useradd -u 1000 -d /home/sotf -m -s /bin/bash sotf

COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

ENV DATA_DIR=/data \
    SERVER_NAME="GameCTL Sons of the Forest" \
    SERVER_PASSWORD="" \
    GAME_PORT=8766 \
    QUERY_PORT=27016 \
    BLOB_PORT=9700 \
    MAX_PLAYERS=8 \
    SAVE_SLOT=1 \
    OWNER_STEAMIDS="" \
    GAME_MODE=Normal \
    GAMECTL_MANAGE_CONFIG=1 \
    UPDATE_ON_START=false \
    GAMECTL_VALIDATE=0 \
    UID=1000 \
    GID=1000

EXPOSE 8766/udp 27016/udp 9700/udp
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint"]
