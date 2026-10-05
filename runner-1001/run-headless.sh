#!/bin/bash
# Headless synthetic checks. All builds and outputs stay in WORKDIR (default .build/checks in this repo).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export SRC=${SRC:-$(dirname "$HERE")}
export WORKDIR=${WORKDIR:-$SRC/.build/checks}
# /tmp is a symlink; the checks compare resolved paths, so the root is resolved (/private/tmp/...).
SOCKROOT=${SOCKROOT:-$(mktemp -d /private/tmp/ddchk.XXXXXX)}; mkdir -p "$SOCKROOT"; export SOCKROOT=$(cd "$SOCKROOT" && pwd -P)
# Default homes are isolated too, even for a step that forgets its own fixture HOME.
mkdir -p "$WORKDIR/headless-home/Library/Preferences"
export HOME="$WORKDIR/headless-home" CFFIXED_USER_HOME="$WORKDIR/headless-home"
export SKIP='^(owner-)?(recording-permission|docs-install-render|honesty-ui|honesty-ui-checks|update-quit|dd-menubar-checks|dd-app-menu-checks|dd-settings-status-checks|typing-ui-checks|setup-upgrade-checks|onboarding-screen-checks|dd-kit-checks|dd-recall-checks|permission-window-checks|chrome-ask-checks)$'
printf 'start %s HEAD %s; timings contaminated under parallel workload\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$(git -C "$SRC" rev-parse HEAD)"
nice bash "$HERE/run-checks.sh" "${1:-run}"
