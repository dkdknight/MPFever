#!/usr/bin/env bash
# Smoke tests of the built image (no game, no Steam): used by ci.yml and release.yml.   Usage: smoke.sh <image>
set -eu
img=${1:?usage: smoke.sh <image>}
echo "== runs unprivileged"
test "$(docker run --rm --entrypoint id "$img" -u)" = 1001
echo "== contains no game file, no Valve file, no secret"
docker run --rm --entrypoint find "$img" / -xdev \( -iname 'TransportFever3.exe' -o -iname 'steamclient*.dll' -o -iname 'steam.exe' -o -iname 'steam.json' -o -iname '*.sav' \) -not -path '/proc/*' 2>/dev/null | tee /tmp/smoke-found
test ! -s /tmp/smoke-found
echo "== Dock, licences, package, healthcheck"
docker run --rm --entrypoint sh "$img" -c 'test -f /opt/mpfever/dockhost.exe && test -f /opt/mpfever/licenses/madeira-dock/COPYING && test -f /opt/mpfever/pkg/MPFever.exe && test -f /opt/mpfever/pkg/winhttp.dll'
docker inspect --format '{{.Config.Healthcheck.Test}}' "$img" | grep -q healthcheck.sh
echo "== pinned runtimes"
docker run --rm --entrypoint sh "$img" -c 'wine --version | grep -q "wine-11.0" && mono --version | head -1 && python3 -c "import qrcode"'
echo "== an empty volume gives explicit messages, not a crash"
vol=smoke-$$
docker volume create "$vol-data" >/dev/null; docker volume create "$vol-game" >/dev/null
trap 'docker volume rm "$vol-data" "$vol-game" >/dev/null 2>&1 || true' EXIT
set +e
out=$(docker run --rm -v "$vol-data":/data -v "$vol-game":/game "$img" status 2>&1); echo "$out"
echo "$out" | grep -q "login" && echo "$out" | grep -q "install-game" || { echo "status: unexpected output"; exit 1; }
out=$(docker run --rm -e WORLD=x -v "$vol-data":/data -v "$vol-game":/game "$img" run 2>&1); rc=$?; echo "$out"
test $rc -eq 40 && echo "$out" | grep -q "run  login" || { echo "run: expected exit 40 and a login message"; exit 1; }
set -e
echo "== the Vulkan layer is in place"
docker run --rm --entrypoint sh "$img" -c 'ls -l /opt/mpfever/libVkLayer_mpf_nulldraw.so /etc/vulkan/implicit_layer.d/'
echo "SMOKE TESTS PASSED"
