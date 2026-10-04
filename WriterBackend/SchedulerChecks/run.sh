#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
trial=$(mktemp -d "${TMPDIR:-/private/tmp}/macmem-scheduler-check.XXXXXX")
trap 'rm -f "$trial/checks"; rmdir "$trial"' EXIT
swiftc -parse-as-library "$base/SchedulerChecks/Support.swift" "$base/Sources/WriterBackend/PendingNoteScheduler.swift" "$base/SchedulerChecks/main.swift" -o "$trial/checks"
"$trial/checks"
