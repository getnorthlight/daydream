#!/bin/bash
set -euo pipefail
trial_kit="$(cd "$(dirname "$0")" && pwd -P)"
trial_app="$trial_kit/Daydream Development Trial.app"
read -r expected < "$trial_kit/executable.sha256"
actual="$(/usr/bin/shasum -a 256 "$trial_app/Contents/MacOS/MacMem" | /usr/bin/awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then echo 'Development executable changed. Stop and request the matching kit.'; exit 1; fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :DaydreamDevelopmentTrial' "$trial_app/Contents/Info.plist")" != true ]]; then echo 'Not the isolated development app.'; exit 1; fi
/usr/bin/codesign --verify --deep --strict "$trial_app"
if [[ -f "$trial_kit/.trial-root" ]]; then
  read -r trial_data < "$trial_kit/.trial-root"
  if [[ "$trial_data" != /private/tmp/daydream-development-trial-* || ! -d "$trial_data" || -L "$trial_data" ]]; then echo 'Trial directory missing or invalid. Stop and request a fresh kit.'; exit 1; fi
else
  trial_data="$(/usr/bin/mktemp -d /private/tmp/daydream-development-trial-XXXXXXXX)"
  /bin/chmod 700 "$trial_data"
  /bin/mkdir -m 700 "$trial_data/memory" "$trial_data/preferences" "$trial_data/backups"
  printf 'synthetic-only\n' > "$trial_data/DEVELOPMENT-ONLY"
  printf '%s\n' "$trial_data" > "$trial_kit/.trial-root"
fi
printf 'Development app: %s\nSynthetic data: %s\nBackups: %s/backups\n' "$trial_app" "$trial_data" "$trial_data"
if ! /usr/bin/open -n --env "DAYDREAM_DEVELOPMENT_ROOT=$trial_data" --env "MAC_MEM_HOME=$trial_data/memory" --env "CFFIXED_USER_HOME=$trial_data/preferences" "$trial_app" --args --development-trial; then
  printf 'macOS blocked opening this exact app: %s\nUse only its user-specific Open Anyway approval, then rerun this launcher.\n' "$trial_app"
  exit 1
fi
printf 'Opening requested through macOS. If blocked, approve only this app in Privacy & Security, then rerun this launcher. Never disable Gatekeeper.\n'
