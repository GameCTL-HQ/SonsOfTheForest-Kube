#!/usr/bin/env bash
# GameCTL Sons of the Forest entrypoint. Fleet NFS-install model: the server
# (~2GB, Windows depot 2465200, anonymous) lives on the volume at
# $DATA_DIR/.gamectl/install; steam HOME and the wine prefix live beside it
# so pod reschedules never re-download or re-init. A normal boot never runs
# steamcmd — UPDATE_ON_START=true / GAMECTL_VALIDATE=1 updates on the next
# restart. dedicatedserver.cfg (JSON) is generated from env each boot while
# GAMECTL_MANAGE_CONFIG=1; set 0 to hand-manage it on the volume.
set -euo pipefail

DATA="${DATA_DIR:-/data}"
uid="${UID:-1000}"; gid="${GID:-1000}"
INSTALL="$DATA/.gamectl/install"
STEAMHOME="$DATA/.gamectl/steamhome"
GAMEHOME="$DATA/.gamectl/gamehome"
PREFIX="$DATA/.gamectl/wineprefix"
SAVEDIR="$DATA/server"

echo "gamectl: entrypoint starting (data: $DATA)"
mkdir -p "$INSTALL" "$STEAMHOME" "$GAMEHOME" "$PREFIX" "$SAVEDIR"
# steamcmd runs as root with HOME on the volume (fleet pattern — "Missing
# configuration" haunts de-privileged steamcmd; the install only needs
# read/exec for the run user, so no recursive chown either). The game itself
# runs as $uid with its own writable HOME + wine prefix.
export HOME="$STEAMHOME"
chown "$uid:$gid" "$DATA" "$DATA/.gamectl" "$GAMEHOME" "$PREFIX" "$SAVEDIR" 2>/dev/null || true
# Fix ownership of files dropped onto the share as root (e.g. an operator
# scp'ing in saves/worlds) — kubelet does not apply fsGroup to NFS volumes,
# and root-owned data files can break the server in silent ways (see
# Necesse-Kube d4b719f). Only touches mismatched files; the steamcmd install
# tree is pruned (large, root-managed, read-only for the run user).
find "$DATA" -path "$DATA/.gamectl" -prune -o ! -user "$uid" -exec chown "$uid:$gid" {} + 2>/dev/null || true

as_user() {
  if [ "$(id -u)" = "0" ]; then setpriv --reuid "$uid" --regid "$gid" --clear-groups "$@"; else "$@"; fi
}

steamcmd_update() {
  for i in 1 2 3 4 5 6; do
    /opt/steamcmd/steamcmd.sh \
      +@sSteamCmdForcePlatformType windows \
      +force_install_dir "$INSTALL" +login anonymous +app_update 2465200 "$@" +quit && return 0
    echo "gamectl: steamcmd attempt $i failed — clearing appcache and retrying" >&2
    rm -rf "$HOME/Steam/appcache" 2>/dev/null || true
    [ "$i" -ge 4 ] && { echo "gamectl: resetting steam state" >&2; rm -rf "$HOME/Steam" 2>/dev/null || true; }
    sleep 10
  done
  return 1
}

find_exe() {
  find "$INSTALL" -maxdepth 3 -iname "SonsOfTheForestDS*.exe" ! -iname "*eac*" 2>/dev/null | head -1
}

need_install=0
[ -n "$(find_exe)" ] || need_install=1
if [ "${GAMECTL_VALIDATE:-0}" = "1" ] || [ "$(echo "${UPDATE_ON_START:-false}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
  echo "gamectl: forced validate/update requested"
  rm -f "$INSTALL/steamapps/appmanifest_2465200.acf" 2>/dev/null || true
  steamcmd_update validate || { [ "$need_install" = "0" ] && echo "gamectl: WARN update failed, starting existing install" || { echo "ERROR: install failed" >&2; exit 1; }; }
elif [ "$need_install" = "1" ]; then
  echo "gamectl: installing Sons of the Forest server into $INSTALL (~2GB — first boot only)"
  steamcmd_update validate || { echo "ERROR: install failed" >&2; exit 1; }
else
  echo "gamectl: existing install found — starting without steamcmd (auto-update toggle to update)"
fi

EXE="$(find_exe)"
[ -n "$EXE" ] || { echo "ERROR: Wreckfest2 exe not found under $INSTALL" >&2; find "$INSTALL" -maxdepth 2 | head -20 >&2; exit 1; }
echo "gamectl: server exe: $EXE"

# SOTF's startup self-tests write steam_appid.txt (and friends) into the
# install dir, which the fleet pattern keeps root-owned. Pre-create the
# file and hand the run user the top-level dir so those writes succeed.
# steam_appid.txt must carry the GAME's appid (1326470), not the DS app —
# the server's self-test rejects anything else.
printf '1326470' > "$INSTALL/steam_appid.txt"
chown "$uid:$gid" "$INSTALL" "$INSTALL/steam_appid.txt" 2>/dev/null || true

# SOTF's self-tests refuse to serve until an owners whitelist exists (it
# generates one, then demands a restart). Pre-create it — with the operator's
# OWNER_STEAMIDS when given — so the first boot passes the self-tests.
WL="$SAVEDIR/ownerswhitelist.txt"
if [ ! -f "$WL" ] || [ -n "${OWNER_STEAMIDS:-}" ]; then
  {
    echo "# Server owners: one SteamID64 per line (in-game admin)."
    [ -n "${OWNER_STEAMIDS:-}" ] && printf '%s\n' ${OWNER_STEAMIDS//,/ }
  } > "$WL"
  chown "$uid:$gid" "$WL" 2>/dev/null || true
fi

# --- dedicatedserver.cfg (JSON, in the -userdatapath dir) -------------------
CFG="$SAVEDIR/dedicatedserver.cfg"
if [ "${GAMECTL_MANAGE_CONFIG:-1}" = "1" ] || [ ! -f "$CFG" ]; then
  echo "gamectl: writing dedicatedserver.cfg (name: ${SERVER_NAME})"
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  lan="false"
  cat > "$CFG" <<CFGEOF
{
    "IpAddress": "0.0.0.0",
    "GamePort": ${GAME_PORT:-8766},
    "QueryPort": ${QUERY_PORT:-27016},
    "BlobSyncPort": ${BLOB_PORT:-9700},
    "ServerName": "$(esc "${SERVER_NAME}")",
    "MaxPlayers": ${MAX_PLAYERS:-8},
    "Password": "$(esc "${SERVER_PASSWORD}")",
    "LanOnly": ${lan},
    "SaveSlot": ${SAVE_SLOT:-1},
    "SaveMode": "Continue",
    "GameMode": "${GAME_MODE:-Normal}",
    "SaveInterval": 600,
    "IdleDayCycleSpeed": 0.0,
    "IdleTargetFramerate": 5,
    "ActiveTargetFramerate": 60,
    "LogFilesEnabled": true,
    "TimestampLogFilenames": false,
    "TimestampLogEntries": true,
    "SkipNetworkAccessibilityTest": true,
    "GameSettings": {},
    "CustomGameModeSettings": {}
}
CFGEOF
  chown "$uid:$gid" "$CFG" 2>/dev/null || true
fi

# --- wine prefix (persisted on the volume) ----------------------------------
export WINEPREFIX="$PREFIX"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"   # no gecko/mono prompts
if [ ! -f "$PREFIX/system.reg" ]; then
  echo "gamectl: initializing wine prefix (first boot only)"
  as_user env HOME="$GAMEHOME" WINEPREFIX="$PREFIX" wineboot --init >/dev/null 2>&1 || true
  as_user env HOME="$GAMEHOME" WINEPREFIX="$PREFIX" wineserver --wait 2>/dev/null || true
fi

# --- launch -----------------------------------------------------------------
WINSAVE="Z:$(printf '%s' "$SAVEDIR" | tr '/' '\\')"
cd "$(dirname "$EXE")"
echo "gamectl: starting Sons of the Forest server — game ${GAME_PORT:-8766}/udp, query ${QUERY_PORT:-27016}/udp, blob ${BLOB_PORT:-9700}/udp"
run=(env HOME="$GAMEHOME" WINEPREFIX="$PREFIX" WINEDEBUG="$WINEDEBUG" WINEDLLOVERRIDES="$WINEDLLOVERRIDES"
     xvfb-run -a stdbuf -oL -eL wine "$EXE" -batchmode -dedicatedserver.IpAddress 0.0.0.0 -userdatapath "$WINSAVE")
if [ "$(id -u)" = "0" ]; then
  chown -R "$uid:$gid" "$PREFIX" 2>/dev/null || true
  exec setpriv --reuid "$uid" --regid "$gid" --clear-groups "${run[@]}"
else
  exec "${run[@]}"
fi
