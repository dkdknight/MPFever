# shellcheck shell=bash disable=SC2034
# Shared definitions of the MPFever dedicated server scripts (sourced by entrypoint.sh).

export HOME=/data
export DATA=/data GAME=/game
export WINEPREFIX=$DATA/wine WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" DISPLAY=:1
export STEAM_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
export SRV=$DATA/srv RUN=$DATA/run SECRETS=$DATA/secrets
export SESSION_FILE=$SECRETS/steam.json
export APPID=3493540
GAME_LINK="$STEAM_DIR/steamapps/common/Transport Fever 3"
OPT=/opt/mpfever

# Valve's Steam client build driven by Madeira Dock, pinned (docs/DOCKER-SERVER.md). Never updated by itself.
CLIENT_URL=https://client-update.akamai.steamstatic.com/bins_win32.zip.23e34a6d4b10596a44561a5100dac5585d2517da
CLIENT_ZIP_SHA256=8b712b2a3412a9066b7725f4e1c5cef9a7ca5b187b6585a5b92d25d09df0ba62
CLIENT_DLL_SHA256=71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640

# Logs: one JSON object per line on stdout/stderr, {"ts","level","component","msg"}, the same shape as the launcher's (SRV_LOG_FORMAT=text, set in .env: "HH:MM:SS LEVEL message").
emit() {
  local level=$1; shift
  if [ "${LOG_FORMAT:-json}" = json ]; then
    local m; m=$(printf '%s' "$*" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf '{"ts":"%s","level":"%s","component":"entrypoint","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$level" "$m"
  else
    printf '%s %-5s %s\n' "$(date -u +%H:%M:%S)" "$(echo "$level" | tr a-z A-Z)" "$*"
  fi
}
log()  { emit info "$*"; }
warn() { emit warn "$*" >&2; }
die()  { emit error "$1" >&2; exit "${2:-1}"; }

sha256_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# true if the game volume supports sparse files (the lite install needs them)
supports_sparse() {
  local f; f=$(mktemp -p "$1" .sparse-test.XXXXXX) || return 1
  truncate -s 64M "$f"; local blocks; blocks=$(stat -c %b "$f"); rm -f "$f"
  [ "$blocks" -lt 1024 ]
}

free_gb() { df -BG --output=avail "$1" | tail -1 | tr -dc '0-9'; }
