#!/bin/bash
# MPFever dedicated server entrypoint (runs as an unprivileged user).
#   run                      start the server (default)
#   login                    sign in to Steam once with a QR code (no password, no GUI); the session is remembered
#   install-game <steamapps> build the lite game install from your own Steam library folder (mounted read-only)
#   import-save <file.sav>.. copy savegame files into the server account's save folder
#   mods login|list|sync|status   the mods of the worlds, from mod.io with your own API key (see mods.py)
#   status                   check everything the server needs and print what is missing
#   shell                    a shell in the container
set -u
. /opt/mpfever/scripts/lib.sh

MODE=${1:-run}; [ $# -gt 0 ] && shift

# ---------------------------------------------------------------- helpers

ensure_dirs() {
  mkdir -p "$DATA" "$SRV" "$RUN" "$STEAM_DIR/steamapps/common" "$STEAM_DIR/config" 2>/dev/null \
    && mkdir -p "$SECRETS" && chmod 700 "$SECRETS" && [ -w "$DATA" ] \
    || die "$DATA is not writable by uid $(id -u): fix the volume ownership (chown -R $(id -u):$(id -g) <volume>)" 10
}

init_prefix() {   # idempotent: only the first start builds the Wine prefix
  if [ ! -f "$DATA/.prefix-v1" ]; then
    log "first start: creating the Wine prefix (about a minute)"
    wineboot -u >/dev/null 2>&1 || true; wineserver -w
    touch "$DATA/.prefix-v1"
  fi
  # the game's own Visual C++ runtime, native, for Wine (the builtin stubs are incomplete)
  local f d="$WINEPREFIX/drive_c/windows/system32"
  for f in "$GAME"/msvcp140*.dll "$GAME"/vcruntime140*.dll "$GAME"/concrt140.dll; do
    [ -f "$f" ] && [ ! -f "$d/$(basename "$f")" ] && cp "$f" "$d/"
  done
  return 0
}

ensure_client() {  # Valve's pinned client library, fetched from Valve's own server, once
  [ "$(sha256_of "$STEAM_DIR/steamclient64.dll")" = "$CLIENT_DLL_SHA256" ] && return 0
  log "fetching Valve's Steam client package from Valve (pinned, about 60 MB)"
  local z; z=$(mktemp -p "$DATA" client.XXXXXX.zip)
  curl -fsSL --retry 3 -o "$z" "$CLIENT_URL" || { rm -f "$z"; die "cannot download Valve's client package from $CLIENT_URL" 20; }
  [ "$(sha256_of "$z")" = "$CLIENT_ZIP_SHA256" ] || { rm -f "$z"; die "the downloaded Steam client package does not match the pinned hash: refusing it" 21; }
  python3 -m zipfile -e "$z" "$STEAM_DIR" && rm -f "$z"
  [ "$(sha256_of "$STEAM_DIR/steamclient64.dll")" = "$CLIENT_DLL_SHA256" ] || die "steamclient64.dll does not match the pinned build" 21
}

link_game() {
  [ -f "$GAME/TransportFever3.exe" ] || die "no game install in $GAME: run  install-game  (docs/DOCKER-SERVER.md, quick start step 2)" 30
  [ -f "$STEAM_DIR/steamapps/appmanifest_$APPID.acf" ] || die "the Steam app manifest is missing: run  install-game  again" 30
  [ -L "$GAME_LINK" ] || { rmdir "$GAME_LINK" 2>/dev/null; ln -sfn "$GAME" "$GAME_LINK"; }
  if [ ! -f "$STEAM_DIR/steamapps/libraryfolders.vdf" ]; then   # the single library the Valve client needs to find the game
    printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"\n\t\t"label"\t\t""\n\t\t"apps"\n\t\t{\n\t\t\t"%s"\t\t"0"\n\t\t}\n\t}\n}\n' "$APPID" > "$STEAM_DIR/steamapps/libraryfolders.vdf"
  fi
}

account_id() { python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["steamid"]) - 76561197960265728)' "$SESSION_FILE"; }

save_dir() { echo "$STEAM_DIR/userdata/$(account_id)/$APPID/local/save"; }
local_dir() { echo "$STEAM_DIR/userdata/$(account_id)/$APPID/local"; }

# the server settings come from .env through Compose: refuse a value that is not meant (a stray variable of the host once turned the public list on)
need_choice() { local n=$1 v=$2 a; shift 2; for a in "$@"; do [ "$v" = "$a" ] && return 0; done; die "SRV_$n must be one of: $* (got '$v')" 2; }
need_int()    { [[ "$2" =~ ^[0-9]+$ ]] || die "SRV_$1 must be a number (got '$2')" 2; }
check_settings() {
  need_choice PUBLIC "${PUBLIC:-false}" true false
  need_choice PAUSE_WHEN_EMPTY "${PAUSE_WHEN_EMPTY:-false}" true false
  need_choice PLAYER_SPEED_CONTROL "${PLAYER_SPEED_CONTROL:-true}" true false
  need_choice COMPANY_MODE "${COMPANY_MODE:-shared}" shared separate
  need_choice START_SPEED "${START_SPEED:-1}" 1 2 4
  need_choice LOG_FORMAT "${LOG_FORMAT:-json}" json text
  need_choice UPDATE_CHECK "${UPDATE_CHECK:-notify}" notify off
  need_choice MODS_SYNC "${MODS_SYNC:-auto}" auto off
  need_choice GAME_LOG "${GAME_LOG:-info}" off error warn info debug
  need_choice ADMIN_UI "${ADMIN_UI:-off}" on off
  need_int PORT "${PORT:-28090}"; need_int MAX_PLAYERS "${MAX_PLAYERS:-8}"; need_int AUTOSAVE_MINUTES "${AUTOSAVE_MINUTES:-10}"; need_int BACKUPS "${BACKUPS:-10}"
}

# ---------------------------------------------------------------- modes

cmd_status() {
  local bad=0
  ensure_dirs
  echo "data volume : $DATA ($(free_gb "$DATA") GB free)   game volume: $GAME ($(free_gb "$GAME") GB free)"
  if supports_sparse "$GAME"; then echo "sparse files: yes"; else echo "sparse files: NO (the lite game install needs ext4, xfs or btrfs)"; bad=1; fi
  [ -f "$GAME/TransportFever3.exe" ] && echo "game        : installed" || { echo "game        : missing (install-game)"; bad=1; }
  python3 "$OPT/scripts/steam_session.py" status --file "$SESSION_FILE" || { echo "steam       : not signed in (login)"; bad=1; }
  [ "$(sha256_of "$STEAM_DIR/steamclient64.dll")" = "$CLIENT_DLL_SHA256" ] && echo "steam client: pinned build present" || echo "steam client: will be fetched at start"
  if [ -n "${WORLD:-}" ] && [ -f "$SESSION_FILE" ]; then
    [ -f "$(save_dir)/$WORLD.sav" ] && echo "savegame    : $WORLD.sav present" || { echo "savegame    : $WORLD.sav missing (import-save)"; bad=1; }
  fi
  return $bad
}

cmd_login() {
  ensure_dirs
  exec python3 "$OPT/scripts/steam_session.py" login --file "$SESSION_FILE"
}

cmd_install_game() {
  local src=${1:?usage: install-game <steamapps folder of your Steam library, mounted read-only>}
  ensure_dirs
  [ -d "$src/common/Transport Fever 3" ] && [ -f "$src/appmanifest_$APPID.acf" ] \
    || die "$src is not a Steam library folder holding Transport Fever 3 (expected common/Transport Fever 3 and appmanifest_$APPID.acf)" 31
  supports_sparse "$GAME" || die "$GAME does not support sparse files: put the game volume on ext4, xfs or btrfs" 32
  local need=3; [ "$(free_gb "$GAME")" -ge $need ] || die "less than $need GB free on $GAME" 33
  log "building the lite install (a few minutes: the host's own files are read once, the 3D data is left out)"
  python3 "$OPT/scripts/mklite.py" "$src/common/Transport Fever 3" "$GAME" || die "lite install failed" 34
  cp "$src/appmanifest_$APPID.acf" "$STEAM_DIR/steamapps/"
  log "game installed ($(du -sh --apparent-size "$GAME" | cut -f1) apparent, $(du -sh "$GAME" | cut -f1) on disk)"
}

cmd_mods() {
  ensure_dirs
  local sub=${1:-status}; [ $# -gt 0 ] && shift
  case "$sub" in
    login|status|setup-root) exec python3 "$OPT/scripts/mods.py" "$sub" "$@" ;;
    list|sync)
      local w=${1:-${WORLD:-}}; [ -n "$w" ] || die "usage: mods $sub <world>" 2
      [ -f "$SESSION_FILE" ] || die "sign in first (login): the save folder depends on the Steam account" 40
      [ $# -gt 0 ] && shift
      exec python3 "$OPT/scripts/mods.py" "$sub" "$(save_dir)/$w.sav" "$@" ;;
    import)
      [ $# -gt 0 ] || die "usage: mods import <folder>   (mount your mods folder: docker compose run --rm -v <folder>:/import:ro mpfever-server mods import /import)" 2
      [ -f "$SESSION_FILE" ] || die "sign in first (login): the game's mods folder depends on the Steam account" 40
      mkdir -p "$(local_dir)/mods"
      exec python3 "$OPT/scripts/mods.py" import "$1" --dest "$(local_dir)/mods" ;;
    *) die "mods: login | list <world> | sync <world> [--check] | import <folder> | status" 2 ;;
  esac
}

cmd_import_save() {
  [ $# -gt 0 ] || die "usage: import-save <file.sav> [more files of the same save]" 2
  [ -f "$SESSION_FILE" ] || die "sign in first (login): the save folder depends on the Steam account" 40
  local d f; d=$(save_dir); mkdir -p "$d"
  for f in "$@"; do cp -v "$f" "$d/"; done
}

# The launcher's session folders live in /tmp (memory: gone when the container stops) and hold the files that explain a desynchronisation (in.log, mod.log, native.log, mp_status.txt ...):
# they are copied to the data volume now and then, when the launcher exits and when the container stops, the last SESSIONS_KEEP (5) kept. The game rewrites its log (stdout.txt) at each start:
# the previous one is kept in srv/gamelogs, the last GAMELOGS_KEEP (5).
keep_newest() {   # keep_newest <folder> <n>: removes all but the n newest entries of a folder of this server's data
  local d=$1 n=$2 e
  case "$d" in "$SRV"/*) ;; *) return 0 ;; esac
  while IFS= read -r e; do [ -n "$e" ] && rm -rf -- "$e"; done < <(ls -1dt "$d"/* 2>/dev/null | tail -n +$((n + 1)))
}
persist_sessions() {
  local d name
  mkdir -p "$SRV/sessions"
  for d in /tmp/mpfever/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d"); mkdir -p "$SRV/sessions/$name"
    find "$d" -maxdepth 1 -type f -size -50M -exec cp -p {} "$SRV/sessions/$name/" \; 2>/dev/null
  done
  keep_newest "$SRV/sessions" "${SESSIONS_KEEP:-5}"
}
archive_game_log() {
  local f; f="$(local_dir)/crash_dump/stdout.txt"
  [ -s "$f" ] || return 0
  mkdir -p "$SRV/gamelogs"
  cp -p "$f" "$SRV/gamelogs/stdout-$(date -u +%Y%m%d-%H%M%S).txt" && : > "$f"
  keep_newest "$SRV/gamelogs" "${GAMELOGS_KEEP:-5}"
}

cmd_run() {
  ensure_dirs
  : "${WORLD:?set SRV_WORLD to the name of a savegame (without .sav)}"
  check_settings
  [ -f "$SESSION_FILE" ] || die "no Steam session: run  login  first (docs/DOCKER-SERVER.md, quick start step 3)" 40
  python3 "$OPT/scripts/steam_session.py" status --file "$SESSION_FILE" >/dev/null \
    || die "the Steam session has expired: run  login  again" 41
  [ -f "$GAME/TransportFever3.exe" ] || die "no game install in $GAME: run  install-game  (docs/DOCKER-SERVER.md, quick start step 2)" 30
  supports_sparse "$GAME" || warn "$GAME has no sparse-file support: only a full copy of the game works there"
  local ram; ram=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
  [ "$ram" -ge 12 ] || warn "only $ram GB of RAM visible: the game needs about 11 GB"
  init_prefix; ensure_client; link_game
  [ -f "$(save_dir)/$WORLD.sav" ] || die "savegame '$WORLD.sav' not found: run  import-save  (docs/DOCKER-SERVER.md, quick start step 4)" 42
  # the game's settings: a minimal profile (lowest graphics) the first time; MPFever activates its mod in it
  mkdir -p "$(local_dir)/mods" "$(save_dir)"   # where the game and MPFever look for the mod and the saves (a new profile has none of them)
  [ -f "$(local_dir)/settings.lua" ] || cp "$OPT/config/settings.lua" "$(local_dir)/settings.lua"
  # the world's mods: the launcher and the game both look for mod.io mods in /data/modio; with a mod.io key (mods login) the world's mods are installed or updated first
  python3 "$OPT/scripts/mods.py" setup-root
  if [ "${MODS_SYNC:-auto}" = auto ] && [ -f "$SECRETS/modio.json" ]; then
    log "mods: installing or updating the world's mods from mod.io"
    python3 "$OPT/scripts/mods.py" sync "$(save_dir)/$WORLD.sav" || warn "mods: not every mod could be updated (the installed versions are used)"
  fi

  # the launcher package of this image version, and the server settings from the environment (the file is rewritten at every start)
  cp -a "$OPT/pkg/." "$SRV/"
  cd "$SRV" || die "cannot enter $SRV" 10
  # autoupdate=notify: the launcher looks for a new MPFever release and announces it in the log, never installs it (the image is updated); 0: no check
  [ "${UPDATE_CHECK:-notify}" = notify ] && au=notify || au=0
  printf 'servermode=headless\nautoupdate=%s\n' "$au" > mpfever_settings.txt
  {
    echo "server-name=${SERVER_NAME:-MPFever Server}"
    echo "world=$WORLD"
    echo "port=${PORT:-28090}"
    echo "password=${PASSWORD:-}"
    echo "max-players=${MAX_PLAYERS:-8}"
    echo "company-mode=${COMPANY_MODE:-shared}"
    echo "start-speed=${START_SPEED:-1}"
    echo "pause-when-empty=${PAUSE_WHEN_EMPTY:-false}"
    echo "player-speed-control=${PLAYER_SPEED_CONTROL:-true}"
    echo "autosave-minutes=${AUTOSAVE_MINUTES:-10}"
    echo "backups=${BACKUPS:-10}"
    echo "restart-on-crash=true"
    echo "public=${PUBLIC:-false}"
    echo "public-address=${PUBLIC_ADDRESS:-}"
    echo "motd=${MOTD:-}"
  } > mpfever_server.properties

  # Madeira Dock: Valve's own client library signs in with the remembered session, checks the licence and starts the game
  AUTH="$RUN/dock-auth.mdock"; STOPFILE="$RUN/stop"
  rm -f "$AUTH" "$STOPFILE"
  python3 "$OPT/scripts/steam_session.py" feed --file "$SESSION_FILE" --out "$AUTH" --app "$APPID" & FEEDER=$!
  export MADEIRA_STEAM_HOST_PROBE=1 MADEIRA_STEAM_HOST_SESSION=1 MADEIRA_STEAM_HOST_LOGIN=1 MADEIRA_STEAM_HOST_APPID=$APPID
  export MADEIRA_DOCK_AUTH_FILE="Z:${AUTH//\//\\}"
  export MADEIRA_STEAM_HOST_CLIENT_DIR='C:\Program Files (x86)\Steam'
  export MADEIRA_STEAM_HOST_EXPECTED_INSTALL='C:\Program Files (x86)\Steam\steamapps\common\Transport Fever 3'
  export MADEIRA_STEAM_HOST_LOG=$SRV/dock.log
  export MPFEVER_DOCK='Z:\opt\mpfever\dockhost.exe'
  export MPFEVER_WINE=1 MPFEVER_STEAMPATH="$STEAM_DIR" MPFEVER_JOINREVIEW=0 MPFEVER_STOPFILE=$STOPFILE
  export MPFEVER_CMDDIR=$RUN/cmd; mkdir -p "$MPFEVER_CMDDIR"; rm -f "$MPFEVER_CMDDIR"/*   # the commands of `mpfever-admin`
  # logs: the launcher writes the same JSON lines as this script (SRV_LOG_FORMAT=text: plain lines)
  if [ "${LOG_FORMAT:-json}" = json ]; then export MPFEVER_LOG_JSON=1; else unset MPFEVER_LOG_JSON; fi
  export MPFEVER_MODSTORE=$DATA/mods/full   # the mod.io mods in full: the launcher offers them to the players who join (the game itself runs from the reduced copies of /data/modio)
  # no 3D output: software Vulkan with a layer that makes every draw and copy a no-op and gives back the GPU memory nobody reads;
  # MPF_VKNULL=0 (docker compose: GPU=1) leaves a real GPU alone
  export MPF_VKNULL=${MPF_VKNULL:-1} MPF_VKNULL_MODE=all MPF_VKNULL_TRIM=${MPF_VKNULL_TRIM:-1}
  export MPFEVER_ENV_HOST="${MPFEVER_ENV_HOST:-MPFEVER_HEADLESS_NORENDER=1;MPFEVER_HEADLESS_FPS=10}"

  rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
  Xvfb :1 -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 & XVFB=$!
  sleep 2

  # the game's and Dock's own logs join the stream (SRV_GAME_LOG: off, error, warn (default), info or debug): components "game" and "dock"
  SHIPPERS=()
  if [ "${GAME_LOG:-info}" != off ]; then
    python3 "$OPT/scripts/logship.py" game "$(local_dir)/crash_dump/stdout.txt" "${GAME_LOG:-info}" & SHIPPERS+=($!)
    python3 "$OPT/scripts/logship.py" dock "$SRV/dock.log" "${GAME_LOG:-info}" & SHIPPERS+=($!)
  fi

  ( while sleep 300; do persist_sessions; done ) & SHIPPERS+=($!)

  # the administration page, only when asked (SRV_ADMIN_UI=on): see docs/DOCKER-SERVER.md
  if [ "${ADMIN_UI:-off}" = on ]; then
    python3 "$OPT/scripts/webadmin.py" & SHIPPERS+=($!)
  fi

  STOPPING=0; LAUNCHER=0
  on_term() {
    STOPPING=1; log "stop requested: saving the world and closing the game"
    touch "$STOPFILE"
    local t=0; while kill -0 "$LAUNCHER" 2>/dev/null && [ "$t" -lt "${STOP_TIMEOUT:-90}" ]; do sleep 1; t=$((t + 1)); done
    kill "$LAUNCHER" 2>/dev/null; wineserver -k 2>/dev/null
  }
  trap on_term TERM INT

  log "starting the server '${SERVER_NAME:-MPFever Server}': world '$WORLD', port ${PORT:-28090}, Steam account $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["account"])' "$SESSION_FILE")"
  local quick=0 t0
  while [ "$STOPPING" = 0 ]; do
    t0=$(date +%s)
    archive_game_log                                      # the previous start's log, before the game rewrites it
    mono MPFever.exe --server --server-start headless >> "$SRV/launcher.out" 2>&1 & LAUNCHER=$!
    # the launcher's own log (one file per start) is the useful log: show it in `docker logs`
    sleep 5; tail -n 0 -F "$(ls -t "$SRV"/logs/launcher-*.log 2>/dev/null | head -1)" 2>/dev/null & TAILER=$!
    wait "$LAUNCHER"; rc=$?
    kill "$TAILER" 2>/dev/null
    persist_sessions
    [ "$STOPPING" = 1 ] && break
    [ "$(date +%s)" -lt $((t0 + 60)) ] && quick=$((quick + 1)) || quick=0
    [ "$quick" -lt 5 ] || { kill "$FEEDER" "$XVFB" 2>/dev/null; die "the launcher stopped 5 times within a minute (last status $rc): see $SRV/launcher.out and $SRV/dock.log" 50; }
    log "the launcher stopped (status $rc): starting it again in 10 s"; sleep 10
  done
  persist_sessions; archive_game_log
  kill "$FEEDER" "$XVFB" "${SHIPPERS[@]}" 2>/dev/null; wineserver -k 2>/dev/null
  log "stopped"
}

case "$MODE" in
  run)          cmd_run ;;
  login)        cmd_login ;;
  install-game) cmd_install_game "$@" ;;
  import-save)  cmd_import_save "$@" ;;
  mods)         cmd_mods "$@" ;;
  status)       cmd_status ;;
  shell)        exec bash ;;
  *)            die "unknown mode '$MODE' (run, login, install-game, import-save, mods, status, shell)" 2 ;;
esac
