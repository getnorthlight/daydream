#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
trial=$(mktemp -d "${TMPDIR:-/private/tmp}/macmem-pause-check.XXXXXX")
trap 'rm -f "$trial/checks"; rmdir "$trial"' EXIT
nice -n 15 clang++ -std=c++17 -pthread -Wall -Wextra "$base/PauseChecks/main.cpp" -o "$trial/checks"
nice -n 15 "$trial/checks"
