#!/usr/bin/env bash
# Builds dockhost.exe (x86-64 Windows, static, stripped) with MinGW-w64: the build the server image uses.   Usage: build.sh [output.exe]
set -euo pipefail
cd "$(dirname "$0")"
out=${1:-dockhost.exe}
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type -static -s -o "$out" \
  src/main.c src/probe.c src/session.c src/launch.c src/validation.c src/auth.c src/client_layout.c src/scm.c src/hold.c -ladvapi32 -luser32
echo "built $out"
