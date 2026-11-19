#!/usr/bin/env bash
# Unit tests of Dock's pure logic (transfer parser, client-layout table, callbacks, licence list, launch result, service decisions): synthetic data,
# no Steam, no Wine. Sanitizers (ASan, UBSan) are used when the compiler has them.   Usage: check.sh   (CC=... to choose the compiler)
set -euo pipefail
cd "$(dirname "$0")"
cc=${CC:-$(command -v gcc || command -v clang)}
san=""
if echo 'int main(void){return 0;}' | "$cc" -x c - -fsanitize=address,undefined -o /dev/null 2>/dev/null; then san="-fsanitize=address,undefined"; fi
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
for t in probe validation auth client_layout; do
  "$cc" -std=c11 -g -O1 -Wall -Wextra -Werror $san -Isrc "src/$t.c" "tests/test-$t.c" -o "$out/test-$t"
  "$out/test-$t"
done
echo "dock unit tests passed${san:+ (with sanitizers)}"
