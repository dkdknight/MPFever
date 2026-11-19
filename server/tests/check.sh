#!/usr/bin/env bash
# Static, reproducible checks of server/ (no game, no network, no Docker build): run from the repository root or from server/.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
step() { echo "== $*"; }

step "shell syntax"
for f in scripts/*.sh tests/check.sh tests/smoke.sh; do bash -n "$f" || fail=1; done
if command -v shellcheck >/dev/null; then step "shellcheck"; shellcheck -S warning scripts/*.sh || fail=1; fi

step "python"
python3 -m py_compile scripts/*.py || fail=1
python3 -m unittest -q tests.test_steam_session tests.test_admin 2>&1 | tail -3 || fail=1
python3 tests/selftest_lite.py | tail -2 || fail=1

step "madeira dock (unit tests, tools)"
bash dock/check.sh | tail -2 || fail=1
python3 -m py_compile dock/tools/check-client-layout.py || fail=1

step "compose"
SRV_WORLD=check docker compose -f compose.yaml config -q || fail=1
SRV_WORLD=check docker compose -f compose.yaml -f compose.build.yaml config -q || fail=1
SRV_WORLD=check docker compose -f compose.yaml -f compose.gpu.yaml config -q || fail=1

step "compose reads only SRV_ and MPFEVER_ variables (a host variable such as PUBLIC must never reach the server)"
bad=$(grep -hoE '\$\{[A-Za-z_]+' compose*.yaml | grep -vE '^\$\{(SRV_|MPFEVER_)' || true)
[ -z "$bad" ] || { echo "unprefixed variables in compose: $bad"; fail=1; }

step "no secrets, no binaries, no proprietary files"
if git ls-files --error-unmatch . >/dev/null 2>&1; then files=$(git ls-files .); else files=$(find . -type f -not -path './dist/*' | sed 's#^\./##'); fi
bad=$(echo "$files" | grep -Ei '\.(exe|dll|so|zip|sav|ba[rs]|7z|pdb)$' || true)
[ -z "$bad" ] || { echo "binary or game file in server/: $bad"; fail=1; }
leak=$(echo "$files" | grep -v '^tests/' | xargs grep -lE 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|"refresh_token"[[:space:]]*:[[:space:]]*"[A-Za-z0-9._-]{20,}"|7656119[89][0-9]{9}' 2>/dev/null || true)
[ -z "$leak" ] || { echo "possible secret in: $leak"; fail=1; }
[ -f .env ] && { echo ".env must not be committed"; git ls-files --error-unmatch .env >/dev/null 2>&1 && fail=1; }

[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || { echo "CHECKS FAILED"; exit 1; }
