#!/bin/bash
# DayDream Chrome device test: the one command the owner runs on the MacBook.
#
#   bash "/Volumes/DayDream Chrome Test/run.sh"
#
# It walks through the whole test (README.md steps 2-7) one thing at a time,
# in plain words. It needs only what every Mac has: /bin/bash 3.2 and system
# tools. No Python, Swift, git, Homebrew, sudo, curl or network.
#
# It never reads, copies or changes your own Chrome profile, and never quits
# or signals your own Chrome. It writes only: a throwaway Chrome profile and
# its own temporary folder (both deleted at the end), a lock folder so that
# only one copy runs at a time (deleted at the end), a small note of whether
# Terminal had Accessibility before (kept until the guided test has run, so a
# Terminal restart or a stop does not lose it), and the report (home folder).
#
# Options: --only a,b   --settle N   --dry-run   --help
# Source rules for this file: ../check_harness_source.py (test_kit_run_script).

[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
# As root every "is it running?" check below would miss the owner's own
# Chrome and DayDream, and the files and permissions would be root's.
if [ "$(id -u)" = 0 ] || [ -n "${SUDO_USER:-}" ]; then
  printf '%s\n' "Please don't run this as the administrator (root)." \
    "Paste the line from READ ME FIRST exactly as it is written, starting with bash."
  exit 1
fi

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
HARNESS="$KIT_DIR/bin/chrome-device-test"
SERVER="$KIT_DIR/bin/chrome-device-test-serve"
PAGE_DIR="$KIT_DIR/testpage"
PORT=8765
# Must equal Harness.minimumChromeMajor in Sources/ChromeProbeCore/Model.swift (checked).
MIN_CHROME=151
TMP_ROOT="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)}"
TMP_ROOT="${TMP_ROOT:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"
STATE_FILE="$TMP_ROOT/ddchrometest-kit-state.txt"
# Not matched by the leftover sweep (ddchrometest.* and ddchrometest-kit.*).
LOCK_DIR="$TMP_ROOT/ddchrometest-lock"
MY_UID="$(id -u)"
# Must equal Steps.all in Sources/ChromeProbeCore/Steps.swift (checked).
STEP_IDS="descriptor plain-input textarea contenteditable typing password-hidden password-shown card otp terminal iframe-same iframe-cross address-bar two-windows-new two-windows-old two-windows-zoomed minimized-window many-windows spotlight native-editors incognito-race incognito-background incognito-closing guest combo-input password-combo"

DRY=0
ONLY=""
SETTLE=""
APP="Terminal"
APP_BUNDLE="com.apple.Terminal"
APP_PICK="click Applications on the left, open the Utilities folder, click Terminal, then click Open"
CHROME_APP=""
CHROME_VERSION=""
WORK=""
PROFILE=""
SERVER_PID=""
SERVER_RC=""
AX=""
AX_OUT=""
AX_BEFORE=""
AX_CHECKED=0
RESTARTS=0
ASKED_AUTOMATION=0
SKIP_PROFILE=0
RUN_RC=""
REPORT=""
PF_RC=""
IN_CLEANUP=0
CLEANED=0
CLEANUP_DONE=0
ENDED=0
LOCKED=0
INTERRUPTED=0
RESUMING=0
NO_INPUT=0
FINAL_NOTE=""
ONLY_ADDED=""
RERUN_BASE=""
RERUN_CMD=""

if [ -t 1 ]; then BOLD=$'\033[1m'; PLAIN=$'\033[0m'; else BOLD=""; PLAIN=""; fi

# ---------------------------------------------------------------- printing

say() { printf '%s\n' "$@"; }
title() { printf '\n%s%s%s\n' "$BOLD" "$1" "$PLAIN"; }
step() { printf '\n%s== Step %s of 8: %s ==%s\n\n' "$BOLD" "$1" "$2" "$PLAIN"; }
dry() { printf '  [dry-run] %s\n' "$*"; }
shown() {
  local out="" a
  for a in "$@"; do out="$out $(printf '%q' "$a")"; done
  printf '%s' "${out# }"
}

usage() {
  cat <<'EOF'
DayDream Chrome device test kit

  bash "/Volumes/DayDream Chrome Test/run.sh" [options]

Walks you through the whole Chrome test in plain words (about 50 minutes).
Run it in the Terminal app. You can stop with Ctrl+C at any time and run the
same command again later; it starts from the beginning and cleans up first.

Options:
  --only a,b    re-run only these steps (names below), for example
                --only incognito-race,incognito-background,incognito-closing
                A step that needs windows from an earlier step gets that
                step added (incognito-race or two-windows-new).
  --settle N    seconds to wait after Chrome comes to the front (default 3);
                use 5 if the results say G4 failed
  --dry-run     print every action instead of doing it: nothing is started,
                opened, changed or asked
  --help        this text

Step names:
EOF
  printf '  %s\n' $STEP_IDS
}

# True when --only names this step.
only_has() { case ",$ONLY," in (*",$1,"*) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------- input

# Waits for Return. Typing q (then Return) stops; clean-up still runs.
wait_return() {
  local prompt="${1:-Press Return to continue.}" answer=""
  printf '\n  %s> %s%s ' "$BOLD" "$prompt" "$PLAIN"
  if [ "$DRY" = 1 ]; then printf '\n'; dry "would wait for Return here"; return 0; fi
  if [ "$NO_INPUT" = 1 ] || ! IFS= read -r answer; then input_closed; return 0; fi
  case "$answer" in
    (q|Q|quit|stop) [ "$IN_CLEANUP" = 1 ] || quit_now ;;
  esac
  return 0
}

# Yes/no question; the answer is no unless y is typed.
ask_yes() {
  local answer=""
  printf '\n  %s> %s%s\n    Type y and press Return for yes. Just press Return for no: ' "$BOLD" "$1" "$PLAIN"
  if [ "$DRY" = 1 ]; then printf '\n'; dry "would wait for an answer (the default is no)"; return 1; fi
  if [ "$NO_INPUT" = 1 ] || ! IFS= read -r answer; then printf '\n'; input_closed; return 1; fi
  case "$answer" in
    (y|Y|yes|Yes|YES) return 0 ;;
  esac
  return 1
}

ask_retry() {
  wait_return "Press Return to try again (or type q and press Return to stop)."
}

input_closed() {
  NO_INPUT=1
  [ "$IN_CLEANUP" = 1 ] && return 0
  printf '\n'
  say "The keyboard input ended, so the test stops here."
  finish 1
}

quit_now() {
  INTERRUPTED=1
  say "" "Stopping. Cleaning up first."
  finish 0
}

# Prints a message and stops (clean-up runs). In --dry-run it carries on.
stop_here() {
  printf '\n'
  say "$@"
  if [ "$DRY" = 1 ]; then dry "the real run would stop here; carrying on to show the rest"; return 0; fi
  finish 1
}

blocked_by_macos() {
  printf '\n'
  say "macOS stopped the test program \"$1\" from running (exit code $2)."
  say "This usually means this copy of the kit is damaged, or macOS did not"
  say "accept its signature. Please copy this line into your chat with Claude:"
  say "   kit: $1 blocked with exit $2 on macOS $(sw_vers -productVersion 2>/dev/null)"
  finish 1
}

# ---------------------------------------------------------------- processes

proc_comm() { ps -ww -o comm= -p "$1" 2>/dev/null; }
proc_args() { ps -ww -o args= -p "$1" 2>/dev/null; }
proc_uid() { ps -o uid= -p "$1" 2>/dev/null | tr -d ' '; }

# Main Chrome processes of this user, one "pid<TAB>name" per line
# (Google Chrome, Beta, Canary or Dev; never the helper processes).
chrome_mains() {
  ps -axww -o pid=,uid=,comm= 2>/dev/null | awk -v me="$MY_UID" '
    $2 == me {
      line = $0
      sub(/^ *[0-9]+ +[0-9]+ +/, "", line)
      n = split(line, parts, "/Contents/MacOS/")
      if (n < 2) next
      name = parts[n]
      if (name == "Google Chrome" || name == "Google Chrome Beta" || name == "Google Chrome Canary" || name == "Google Chrome Dev")
        print $1 "\t" name
    }'
}

# The throwaway profile a Chrome process was started with, if it is one of
# this kit's ($TMPDIR/ddchrometest.XXXXXXXX); empty otherwise.
test_profile_of() {
  local word
  proc_args "$1" | tr ' ' '\n' | while IFS= read -r word; do
    case "$word" in
      (--user-data-dir="$TMP_ROOT"/ddchrometest.*) printf '%s\n' "${word#--user-data-dir=}"; break ;;
    esac
  done
}

# True only for this user's main Google Chrome process that was started with
# exactly this throwaway profile folder. Nothing else is ever closed.
is_test_chrome_pid() {
  local pid="$1" profile="$2" comm args
  case "$profile" in
    ("$TMP_ROOT"/ddchrometest.*) ;;
    (*) return 1 ;;
  esac
  case "$profile" in
    (*[[:space:]]*|*/../*|*/..) return 1 ;;
  esac
  [ "$(proc_uid "$pid")" = "$MY_UID" ] || return 1
  comm="$(proc_comm "$pid")"
  case "$comm" in
    (*/Contents/MacOS/"Google Chrome") ;;
    (*) return 1 ;;
  esac
  args="$(proc_args "$pid")"
  case " $args " in
    (*" --user-data-dir=$profile "*) return 0 ;;
  esac
  return 1
}

# The main process of the throwaway Chrome for $PROFILE, if it is running.
find_test_chrome() {
  local pid name
  [ -n "$PROFILE" ] || return 0
  chrome_mains | while IFS=$'\t' read -r pid name; do
    if is_test_chrome_pid "$pid" "$PROFILE"; then printf '%s\n' "$pid"; break; fi
  done
}

# True while any process (Chrome or its helpers) still uses this profile.
profile_in_use() {
  ps -axww -o args= 2>/dev/null | awk -v want="--user-data-dir=$1" '
    { n = split($0, w, " "); for (i = 1; i <= n; i++) if (w[i] == want) found = 1 }
    END { exit found ? 0 : 1 }'
}

# Closes one throwaway Chrome, re-checking before every signal that it is
# the test Chrome for exactly this profile.
close_test_chrome_pid() {
  local pid="$1" profile="$2" i=0
  if [ "$DRY" = 1 ]; then dry "would close only the test Chrome (process $pid)"; return 0; fi
  is_test_chrome_pid "$pid" "$profile" && kill -TERM "$pid" 2>/dev/null
  while [ $i -lt 15 ] && is_test_chrome_pid "$pid" "$profile"; do sleep 1; i=$((i + 1)); done
  is_test_chrome_pid "$pid" "$profile" && kill -KILL "$pid" 2>/dev/null
  i=0
  while [ $i -lt 15 ] && profile_in_use "$profile"; do sleep 1; i=$((i + 1)); done
  return 0
}

# This user's chrome-device-test-serve processes (test pages left running).
leftover_server_pids() {
  ps -axww -o pid=,uid=,comm= 2>/dev/null | awk -v me="$MY_UID" '
    $2 == me { line = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", line); if (line ~ /\/chrome-device-test-serve$/) print $1 }'
}

is_our_server_pid() {
  [ "$(proc_uid "$1")" = "$MY_UID" ] || return 1
  case "$(proc_comm "$1")" in
    (*/chrome-device-test-serve) return 0 ;;
  esac
  return 1
}

daydream_running() { pgrep -U "$MY_UID" -i -x 'macmem|daydream' >/dev/null 2>&1; }

# ---------------------------------------------------------------- lock

# One copy at a time: a second copy would stop the first one's test page and
# delete its work folder as "left over".
drop_lock() {
  if [ "$DRY" = 1 ]; then return 0; fi
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] && rm -rf -- "$LOCK_DIR"
  return 0
}

make_lock() {
  [ "$DRY" = 1 ] && return 0
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  LOCKED=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  return 0
}

take_lock() {
  local pid=""
  if [ "$DRY" = 1 ]; then dry "would check that the test is not already running in another window ($LOCK_DIR)"; return 0; fi
  make_lock && return 0
  if [ -L "$LOCK_DIR" ] || [ ! -d "$LOCK_DIR" ]; then
    stop_here "Could not start: $LOCK_DIR is in the way." "Please restart the Mac, then run the same command again."
    return 0
  fi
  pid="$(head -n 1 "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -z "$pid" ]; then sleep 1; pid="$(head -n 1 "$LOCK_DIR/pid" 2>/dev/null)"; fi
  case "$pid" in (''|*[!0-9]*) pid="" ;; esac
  if [ -n "$pid" ] && [ "$pid" != "$$" ] && [ "$(proc_uid "$pid")" = "$MY_UID" ]; then
    case "$(proc_args "$pid")" in
      (*run.sh*)
        stop_here "The test is already running in another Terminal window." \
                  "Use that window, or close it and run this again."
        return 0 ;;
    esac
  fi
  # Left behind by a try that could not clean up (for example a forced quit).
  drop_lock
  make_lock && return 0
  stop_here "Could not start: another copy of this test may be starting right now." "Wait a moment, then run the same command again."
}

open_settings() {
  if [ "$DRY" = 1 ]; then dry "would open System Settings > Privacy & Security > $1"; return 0; fi
  case "$1" in
    (Accessibility) open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" ;;
    (Automation) open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation" ;;
  esac
  say "  (If System Settings did not open: Apple menu > System Settings >"
  say "   Privacy & Security, then scroll down and click $1.)"
}

plist_value() {
  plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || defaults read "$1/Contents/Info" "$2" 2>/dev/null
}

# ---------------------------------------------------------------- state

# Whether Terminal had Accessibility before the first try, so the clean-up
# can say whether to switch it off, and how many Terminal restarts step 2 has
# asked for. Kept until the guided test has run; a note older than two days
# is from another occasion and is ignored.
load_state() {
  local n
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 0
  [ -n "$(find "$STATE_FILE" -mtime -2 2>/dev/null)" ] || return 0
  grep -qx "app=$APP_BUNDLE" "$STATE_FILE" 2>/dev/null || return 0
  AX_BEFORE="$(grep -E '^ax_before=(on|off)$' "$STATE_FILE" | head -n 1 | cut -d= -f2)"
  n="$(grep -E '^restarts=[0-9]$' "$STATE_FILE" | head -n 1 | cut -d= -f2)"
  RESTARTS="${n:-0}"
}

write_state() {
  if [ "$DRY" = 1 ]; then dry "would note in $STATE_FILE: $APP's Accessibility before the test, and $RESTARTS restart(s) so far (deleted once the test has run)"; return 0; fi
  [ -n "$AX_BEFORE" ] || return 0
  [ -L "$STATE_FILE" ] && return 0
  [ -f "$STATE_FILE" ] && rm -f -- "$STATE_FILE"
  ( set -C; printf 'app=%s\nax_before=%s\nrestarts=%s\n' "$APP_BUNDLE" "$AX_BEFORE" "$RESTARTS" > "$STATE_FILE" ) 2>/dev/null
  return 0
}

# Records the setting before this test changed anything (first reading only).
save_state() {
  [ -z "$AX_BEFORE" ] || return 0
  if [ "$DRY" = 1 ]; then write_state; return 0; fi
  AX_BEFORE="$1"
  write_state
}

delete_note() {
  if [ "$DRY" = 1 ]; then dry "would delete the note $STATE_FILE"; return 0; fi
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] && rm -f -- "$STATE_FILE"
  return 0
}

# ---------------------------------------------------------------- clean-up

stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  if [ "$DRY" = 1 ]; then dry "would stop the test page"; SERVER_PID=""; return 0; fi
  # After Ctrl+C the page has usually stopped already: signal the number only
  # while it still belongs to this kit's test page.
  is_our_server_pid "$SERVER_PID" && kill -TERM "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
  return 0
}

delete_profile() {
  [ -n "$PROFILE" ] || return 0
  if [ "$DRY" = 1 ]; then dry "would delete the throwaway profile folder $PROFILE"; PROFILE=""; return 0; fi
  case "$PROFILE" in
    ("$TMP_ROOT"/ddchrometest.*) ;;
    (*) PROFILE=""; return 0 ;;
  esac
  if [ ! -d "$PROFILE" ] || [ -L "$PROFILE" ]; then PROFILE=""; return 0; fi
  if profile_in_use "$PROFILE"; then
    FINAL_NOTE="The throwaway Chrome profile was still in use, so it was not deleted yet. Running the test again removes it."
    return 1
  fi
  rm -rf -- "$PROFILE"
  PROFILE=""
  return 0
}

quit_test_chrome() {
  local pid answer start quick=0
  pid="$(find_test_chrome)"
  if [ -z "$pid" ] && [ "$DRY" != 1 ]; then say "OK: the test Chrome is closed."; return 0; fi
  say "Quit the test Chrome now: click on its window, then press Cmd+Q."
  say "If Chrome asks \"Leave site?\", click Leave. If it asks whether to quit"
  say "with windows open, click Quit."
  say ""
  say "If it will not quit, type y and press Return here. This script then"
  say "closes the test Chrome for you. Only the test Chrome is closed, never"
  say "your own."
  if [ "$DRY" = 1 ]; then dry "would wait here until the test Chrome has quit"; return 0; fi
  while [ -n "$(find_test_chrome)" ]; do
    if [ "$NO_INPUT" = 1 ]; then sleep 2; continue; fi
    start=$SECONDS
    if IFS= read -r -t 2 answer; then
      quick=0
      case "$answer" in
        (y|Y|yes) pid="$(find_test_chrome)"; [ -n "$pid" ] && close_test_chrome_pid "$pid" "$PROFILE" ;;
      esac
    elif [ $((SECONDS - start)) -lt 1 ]; then
      quick=$((quick + 1)); [ $quick -ge 3 ] && NO_INPUT=1
    fi
  done
  local i=0
  while [ $i -lt 15 ] && profile_in_use "$PROFILE"; do sleep 1; i=$((i + 1)); done
  say "OK: the test Chrome has quit."
}

automation_cleanup() {
  title "Terminal's permission to control Chrome"
  say "$APP is still allowed to control Google Chrome. You can switch that off."
  say "This script can do it with one macOS command, but that command switches"
  say "off ALL of $APP's \"control other apps\" permissions, including any you"
  say "gave in the past (for example for Finder or System Events)."
  say "If you are not sure, answer no and switch it off by hand (see below)."
  [ "$DRY" = 1 ] && dry "if you answer y: $(shown tccutil reset AppleEvents "$APP_BUNDLE")"
  if ask_yes "Switch off all of $APP's Automation permissions now?"; then
    if tccutil reset AppleEvents "$APP_BUNDLE" >/dev/null 2>&1; then
      say "OK: done. $APP can no longer control Chrome."
      return 0
    fi
    say "That did not work. Please switch it off by hand:"
  else
    say "To switch it off by hand, any time:"
  fi
  say "  System Settings > Privacy & Security > Automation > $APP >"
  say "  switch off Google Chrome."
}

accessibility_cleanup() {
  title "Accessibility for $APP"
  case "$AX_BEFORE" in
    (on)
      say "$APP already had Accessibility before this test, so leave it as it is." ;;
    (*)
      if [ "$AX_BEFORE" = off ]; then
        say "$APP did not have Accessibility before this test. Switch it off now:"
      else
        say "If $APP did not have Accessibility before today, switch it off now:"
      fi
      say "  System Settings > Privacy & Security > Accessibility > switch off $APP"
      say "  (or click $APP in the list and then the - button to remove it)."
      if ask_yes "Open that settings page now?"; then
        open_settings Accessibility
        wait_return "When $APP is switched off, press Return."
      fi ;;
  esac
}

# The permission reminders. They do not depend on how far the test got: step 2
# may have switched Accessibility on long before step 4 made the work folder.
permission_cleanup() {
  [ "$ASKED_AUTOMATION" = 1 ] && automation_cleanup
  if [ "$AX_CHECKED" = 1 ] || [ -n "$AX_BEFORE" ]; then accessibility_cleanup; fi
  # The note is needed only until the guided test has run: after a stop, the
  # next try still knows what the setting was before the first try.
  [ -n "$RUN_RC" ] && delete_note
  return 0
}

# The interactive clean-up (step 7). Runs once, also after q or Ctrl+C.
cleanup_interactive() {
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  IN_CLEANUP=1
  if [ -n "$WORK" ]; then
    step 7 "Clean up"
    quit_test_chrome
    if delete_profile; then say "OK: the throwaway Chrome profile is deleted."; fi
    stop_server
    say "OK: the test page is stopped."
  elif [ "$RESUMING" = 0 ] && { [ "$ASKED_AUTOMATION" = 1 ] || [ "$AX_CHECKED" = 1 ] || [ -n "$AX_BEFORE" ]; }; then
    title "Clean up"
  fi
  if [ "$RESUMING" = 0 ]; then
    permission_cleanup
    if [ -n "$WORK" ] || [ "$AX_CHECKED" = 1 ] || [ -n "$AX_BEFORE" ]; then
      say "" "You can open your own Chrome and DayDream again now."
      [ -n "$RUN_RC" ] || say "You can run the same command again later."
    fi
  fi
  IN_CLEANUP=0
  CLEANUP_DONE=1
}

# Printed on exit when the interactive clean-up was cut short (Ctrl+C during
# it, or the window closed): what is still left to do, without questions.
short_reminders() {
  local lines="" ax=""
  [ "$DRY" = 1 ] && return 0
  if [ -n "$PROFILE" ] && [ -n "$(find_test_chrome)" ]; then
    lines="$lines  - The test Chrome is still open. Quit it: click on it and press Cmd+Q."$'\n'
  fi
  if [ "$ASKED_AUTOMATION" = 1 ]; then
    lines="$lines  - $APP may still control Google Chrome. To switch that off: System Settings >"$'\n'
    lines="$lines    Privacy & Security > Automation > $APP > switch off Google Chrome."$'\n'
  fi
  case "$AX_BEFORE" in
    (on) ;;
    (off) ax="  - $APP did not have Accessibility before this test. Switch it off:" ;;
    (*) [ "$AX_CHECKED" = 1 ] && ax="  - If $APP did not have Accessibility before today, switch it off:" ;;
  esac
  if [ -n "$ax" ]; then
    lines="$lines$ax"$'\n'"    System Settings > Privacy & Security > Accessibility > switch off $APP."$'\n'
  fi
  if [ -n "$REPORT" ] && [ -f "$REPORT" ]; then
    lines="$lines  - The report is this file. Please attach it to a GitHub issue:"$'\n'"      $REPORT"$'\n'
  fi
  [ -n "$lines" ] || return 0
  printf '\n%sBefore you go:%s\n%s' "$BOLD" "$PLAIN" "$lines"
}

# Runs on every exit: stop the page, remove temporary files, last notes.
final_cleanup() {
  stop_server
  if [ "$DRY" != 1 ]; then
    [ -n "$PROFILE" ] && delete_profile
    if [ -n "$WORK" ]; then
      case "$WORK" in
        ("$TMP_ROOT"/ddchrometest-kit.*) [ -d "$WORK" ] && [ ! -L "$WORK" ] && rm -rf -- "$WORK" ;;
      esac
    fi
  fi
  if [ -n "$FINAL_NOTE" ]; then printf '\n'; say "$FINAL_NOTE"; fi
  if [ "$RESUMING" = 1 ]; then
    restart_note
  elif [ "$CLEANUP_DONE" != 1 ]; then
    short_reminders
  fi
  [ "$LOCKED" = 1 ] && drop_lock
  return 0
}

restart_note() {
  printf '\n%sOne more thing: macOS applies the new permission after %s restarts.%s\n' "$BOLD" "$APP" "$PLAIN"
  say "  1. Press Cmd+Q to quit $APP."
  say "  2. Open $APP again: press Cmd+Space, type $APP, press Return."
  say "  3. Paste this command again and press Return:"
  say "" "       $RERUN_CMD" ""
  say "The test starts again from the beginning. The steps you already did go fast."
  if [ "$AX_BEFORE" != on ]; then
    say "(If you decide not to go on, switch $APP off again in System Settings >"
    say " Privacy & Security > Accessibility.)"
  fi
}

finish() {
  cleanup_interactive
  if [ -n "$WORK" ] && [ "$RESUMING" = 0 ]; then end_screen; fi
  exit "$1"
}

on_interrupt() {
  if [ "$IN_CLEANUP" = 1 ]; then printf '\n'; say "Stopping the clean-up now."; exit 130; fi
  INTERRUPTED=1
  printf '\n\n'
  say "Stopped (Ctrl+C). Cleaning up first."
  finish 130
}

trap on_interrupt INT
trap 'NO_INPUT=1; exit 129' HUP TERM
trap final_cleanup EXIT

# ---------------------------------------------------------------- step 1

check_terminal() {
  local ok=1
  if [ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]; then
    ok=0; stop_here "This must run on the MacBook itself, in its Terminal app, not over a remote connection."
  fi
  if [ -n "${TMUX:-}${STY:-}" ]; then
    ok=0; stop_here "Please run this in a plain Terminal window, not inside tmux or screen."
  fi
  case "${TERM_PROGRAM:-}" in
    (Apple_Terminal) ;;
    (iTerm.app)
      APP="iTerm"; APP_BUNDLE="com.googlecode.iterm2"
      APP_PICK="click Applications on the left, click iTerm, then click Open" ;;
    (*)
      ok=0
      stop_here "Please run this in the Terminal app: press Cmd+Space, type Terminal," \
                "press Return, then paste the same command there." ;;
  esac
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    ok=0
    stop_here "Please paste the command into a Terminal window and press Return." \
              "(This script needs to read the keyboard.)"
  fi
  if [ "$ok" = 1 ]; then say "OK: running in $APP."; fi
}

check_kit_files() {
  local f missing=""
  for f in "$HARNESS" "$SERVER"; do
    if [ ! -f "$f" ] || [ ! -x "$f" ]; then missing="$missing ${f#"$KIT_DIR"/}"; fi
  done
  for f in "$PAGE_DIR/index.html" "$PAGE_DIR/frame.html"; do
    [ -f "$f" ] || missing="$missing ${f#"$KIT_DIR"/}"
  done
  if [ -n "$missing" ]; then
    stop_here "Part of the kit is missing:$missing" "Please ask Claude for a new copy of the kit."
  else
    say "OK: the kit is complete ($KIT_DIR)."
  fi
}

check_mac() {
  local version major
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != 1 ]; then
    stop_here "This kit needs a Mac with Apple silicon (M1 or later)."
  fi
  version="$(sw_vers -productVersion 2>/dev/null)"
  major="${version%%.*}"
  case "$major" in (''|*[!0-9]*) major=0 ;; esac
  if [ "$major" -lt 13 ]; then
    stop_here "This kit needs macOS 13 or later. This Mac has macOS $version."
  elif [ "$major" -lt 15 ]; then
    say "Note: this Mac has macOS $version. The kit was made for macOS 15 or later; carrying on."
  else
    say "OK: Apple silicon Mac with macOS $version."
  fi
}

check_chrome() {
  local app bundle major
  for app in "/Applications/Google Chrome.app" "$HOME/Applications/Google Chrome.app"; do
    if [ -f "$app/Contents/Info.plist" ]; then CHROME_APP="$app"; break; fi
  done
  if [ -z "$CHROME_APP" ]; then
    stop_here "Google Chrome is not in your Applications folder." \
              "Install it from https://www.google.com/chrome/ (or move it into" \
              "Applications), then run the same command again."
    return 0
  fi
  bundle="$(plist_value "$CHROME_APP" CFBundleIdentifier)"
  CHROME_VERSION="$(plist_value "$CHROME_APP" CFBundleShortVersionString)"
  major="${CHROME_VERSION%%.*}"
  case "$major" in (''|*[!0-9]*) major=0 ;; esac
  if [ "$bundle" != "com.google.Chrome" ]; then
    stop_here "\"$CHROME_APP\" is not Google Chrome (it says $bundle)."
  elif [ "$major" -lt "$MIN_CHROME" ]; then
    # Not a gate: the results grade the version as F8 (a FIX), like README.
    say "Google Chrome ${CHROME_VERSION:-(unknown version)} is older than version $MIN_CHROME. Please update it first:"
    say "  1. Open Chrome, then choose Chrome > About Google Chrome in the menu bar at"
    say "     the top of the screen, and wait. When it says Relaunch, click it."
    say "  2. Quit Chrome with Cmd+Q and run the same command again."
    say "If Chrome cannot update itself: download the newest Chrome from"
    say "https://www.google.com/chrome/, open the download, and drag Google Chrome"
    say "into the Applications folder, replacing the old one."
    say "If updating is not possible, the test can still run with this Chrome. The"
    say "results then list rule F8 (Chrome version) as something to fix."
    if ask_yes "Carry on with Chrome ${CHROME_VERSION:-(unknown version)} anyway?"; then
      say "OK: carrying on with Google Chrome ${CHROME_VERSION:-(unknown version)}."
    else
      stop_here "Stopped so you can update Chrome. Run the same command again afterwards."
    fi
  else
    say "OK: Google Chrome $CHROME_VERSION is installed. It was not opened to check this."
  fi
}

sound_check() {
  local answer=""
  title "Sound"
  say "The test plays two sounds: Tink means \"go\", Glass means \"done\"."
  say "Turn the volume up now, and make sure the Mac is not muted."
  if [ "$DRY" = 1 ]; then dry "would play the Tink and Glass sounds (afplay) so you can check the volume"; return 0; fi
  while :; do
    wait_return "Press Return to hear both sounds."
    afplay /System/Library/Sounds/Tink.aiff 2>/dev/null
    sleep 0.4
    afplay /System/Library/Sounds/Glass.aiff 2>/dev/null
    printf '\n  %s> Heard both? Press Return to go on (or type a and Return to hear them again).%s ' "$BOLD" "$PLAIN"
    IFS= read -r answer || input_closed
    case "$answer" in
      (a|A) continue ;;
      (q|Q) quit_now ;;
    esac
    break
  done
}

# DayDream must not run during any of the test, including the permission
# steps (README safety rule 5), so this comes before step 2.
quit_daydream() {
  local waited=0
  if daydream_running; then
    say "DayDream is running. Quit it so it records none of the test: click the"
    say "DayDream icon in the menu bar at the top of the screen and choose Quit."
    if [ "$DRY" = 1 ]; then
      dry "DayDream is running on this Mac now; the real run would wait here until it has quit"
    else
      while daydream_running; do
        if [ $waited = 30 ]; then
          say "If you cannot see the icon: open Activity Monitor (Cmd+Space, type"
          say "Activity Monitor), click MacMem, click the X button at the top, then Quit."
        fi
        sleep 1
        waited=$((waited + 1))
      done
    fi
  fi
  daydream_running || say "OK: DayDream is not running."
}

# ---------------------------------------------------------------- step 2

ax_check() {
  local rc
  AX=""; AX_OUT=""
  if [ "$DRY" = 1 ]; then
    dry "would run: $(shown "$HARNESS" access)"
    dry "(it only asks macOS whether $APP has Accessibility; no prompt, no Chrome)"
    AX="dry"; return 0
  fi
  AX_OUT="$("$HARNESS" access 2>&1)"
  rc=$?
  case "$rc" in
    (0) AX=on ;;
    (1) AX=off ;;
    (126|137|9) blocked_by_macos chrome-device-test "$rc" ;;
    (*) AX=error
        say "$AX_OUT"
        stop_here "Could not check Accessibility (exit code $rc). Please copy the lines above into your chat with Claude." ;;
  esac
}

accessibility_instructions() {
  say "Here is how to switch it on:"
  say "  1. System Settings opens at Privacy & Security > Accessibility."
  say "  2. Click the + button under the list. If asked, type your Mac"
  say "     password or use Touch ID."
  say "  3. In the window that opens, $APP_PICK."
  say "  4. Make sure the switch next to $APP is on (blue)."
  say "  5. Come back to this window."
  say "(If $APP is already in the list but switched off, just switch it on.)"
}

# After a restart that did not help: take the entry out and add it again
# (a stale entry can show as on without counting).
readd_instructions() {
  say "It was switched on before $APP restarted, but macOS still does not count it."
  say "Let's put $APP in the list again:"
  say "  1. System Settings opens at Privacy & Security > Accessibility."
  say "  2. Click $APP in the list, then click the - button under the list."
  say "     If asked, type your Mac password or use Touch ID."
  say "  3. Click the + button, then $APP_PICK."
  say "  4. Make sure the switch next to $APP is on (blue)."
  say "  5. Come back to this window."
}

accessibility_on() {
  if [ "$RESTARTS" != 0 ]; then RESTARTS=0; write_state; fi
  return 0
}

# Returns when Accessibility is on. Otherwise explains how to switch it on,
# checks again in a new process, and asks for a Terminal restart. After one
# restart it has the entry removed and added again; after two it stops with a
# line to copy to Claude instead of asking for yet another restart.
ensure_accessibility() {
  local tries=0
  AX_CHECKED=1
  ax_check
  # Remember the state before this test changed anything (first try only).
  case "$AX" in
    (on|off) save_state "$AX" ;;
    (dry) save_state "on or off" ;;
  esac
  if [ "$AX" = on ]; then say "OK: $APP has Accessibility."; accessibility_on; return 0; fi
  if [ "$AX" = dry ]; then dry "showing what happens when it is off:"; fi
  say "$APP does not have Accessibility yet."
  if [ "$RESTARTS" -ge 1 ]; then readd_instructions; else accessibility_instructions; fi
  open_settings Accessibility
  while :; do
    wait_return "When the switch next to $APP is on, press Return."
    ax_check
    if [ "$AX" = on ]; then say "OK: $APP has Accessibility now."; accessibility_on; return 0; fi
    if [ "$AX" = dry ]; then
      dry "if it still read off, the real run would explain again, then ask for a $APP restart;"
      dry "after one restart it has $APP removed and added again; after two it stops with a line to copy to Claude"
      return 0
    fi
    tries=$((tries + 1))
    [ $tries -ge 2 ] && break
    say "It still reads off. Check that the switch next to $APP is on (blue)."
    say "If $APP is not in the list, click + again and add it."
  done
  if [ "$RESTARTS" -ge 2 ]; then
    stop_here "$APP's Accessibility still reads off after $RESTARTS restarts of $APP." \
              "Please copy this line into your chat with Claude:" \
              "   kit: Accessibility still off after $RESTARTS restarts, app=$APP_BUNDLE, macOS $(sw_vers -productVersion 2>/dev/null), access said: $AX_OUT"
    return 0
  fi
  say "It still reads off. macOS often notices the change only after $APP restarts."
  RESTARTS=$((RESTARTS + 1))
  write_state
  RESUMING=1
  finish 0
}

# ---------------------------------------------------------------- step 3

wait_until_no_chrome() {
  local mains pid profile waited=0 names asked=" "
  while :; do
    mains="$(chrome_mains)"
    [ -n "$mains" ] || return 0
    # A test Chrome left open by an earlier try: offer once to close it.
    for pid in $(printf '%s\n' "$mains" | cut -f1); do
      case "$asked" in (*" $pid "*) continue ;; esac
      asked="$asked$pid "
      profile="$(test_profile_of "$pid")"
      if [ -n "$profile" ] && is_test_chrome_pid "$pid" "$profile"; then
        say "A test Chrome from an earlier try is still open (process $pid)."
        if ask_yes "Close that test Chrome for you? (Only that test Chrome is closed.)"; then
          close_test_chrome_pid "$pid" "$profile"
        else
          say "Then please quit it yourself: click on it and press Cmd+Q."
        fi
      fi
    done
    mains="$(chrome_mains)"
    [ -n "$mains" ] || return 0
    names="$(printf '%s\n' "$mains" | cut -f2 | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    if [ $waited = 0 ]; then
      say "Chrome is open ($names)."
      say "Quit it now: click on a Chrome window, then press Cmd+Q."
      say "Closing its windows is not enough: it must quit. Your own Chrome is"
      say "never touched by this script; it just waits here until Chrome has quit."
    fi
    if [ "$DRY" = 1 ]; then dry "Chrome is running on this Mac now; the real run would wait here until it has quit"; return 0; fi
    if [ $waited = 20 ]; then
      say "Still waiting for Chrome to quit. If Chrome keeps running, click it in"
      say "the Dock, then choose Chrome > Quit Google Chrome in the menu bar at the"
      say "top of the screen. If a Chrome icon is in the menu bar at the top right,"
      say "click it and choose Quit."
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

step_quit_apps() {
  step 3 "Quit your own Chrome"
  wait_until_no_chrome
  [ -z "$(chrome_mains)" ] && say "OK: Chrome is not running."
  # Checked again in case DayDream was opened after step 1.
  quit_daydream
}

# ---------------------------------------------------------------- step 4

remove_leftovers() {
  local spid d
  for spid in $(leftover_server_pids); do
    if [ "$DRY" = 1 ]; then dry "would stop a test page left running by an earlier try (process $spid)"; continue; fi
    say "Stopping a test page left running by an earlier try."
    is_our_server_pid "$spid" && kill -TERM "$spid" 2>/dev/null
  done
  for d in "$TMP_ROOT"/ddchrometest.* "$TMP_ROOT"/ddchrometest-kit.*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    profile_in_use "$d" && continue
    if [ "$DRY" = 1 ]; then dry "would delete a folder left by an earlier try: $d"; continue; fi
    rm -rf -- "$d"
  done
  [ "$DRY" = 1 ] || sleep 0.5
}

make_work_dir() {
  if [ "$DRY" = 1 ]; then
    WORK="$TMP_ROOT/ddchrometest-kit.XXXXXXXX"
    dry "would create a temporary folder for this run: $(shown mktemp -d "$TMP_ROOT/ddchrometest-kit.XXXXXXXX")"
    return 0
  fi
  WORK="$(mktemp -d "$TMP_ROOT/ddchrometest-kit.XXXXXXXX")" || { WORK=""; stop_here "Could not create a temporary folder."; }
}

server_failure() {
  local who
  case "$SERVER_RC" in
    (3)
      who="$(lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $1 }' | sort -u | tr '\n' ' ')"
      if [ -n "$who" ]; then
        say "Another program ($who) is already using the test page's address (port $PORT)."
        say "Quit that program, then try again."
      else
        say "Another program is already using the test page's address (port $PORT)."
        say "Quit other developer tools, or restart the Mac, then try again."
      fi ;;
    (126|137|9) blocked_by_macos chrome-device-test-serve "$SERVER_RC" ;;
    (*)
      sed 's/^/    /' "$WORK/server.log" 2>/dev/null
      say "The test page did not start (${SERVER_RC:-no answer})." ;;
  esac
}

start_page() {
  local i
  while :; do
    if [ "$DRY" = 1 ]; then
      dry "would start the test page in the background: $(shown "$SERVER" --root "$PAGE_DIR" --port "$PORT")"
      return 0
    fi
    "$SERVER" --root "$PAGE_DIR" --port "$PORT" </dev/null >"$WORK/server.log" 2>&1 &
    SERVER_PID=$!
    SERVER_RC=""
    i=0
    while [ $i -lt 50 ]; do
      if grep -q '^Serving ' "$WORK/server.log" 2>/dev/null; then
        say "OK: the test page is running at http://127.0.0.1:$PORT/ (only this Mac can see it)."
        return 0
      fi
      if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        wait "$SERVER_PID" 2>/dev/null
        SERVER_RC=$?
        SERVER_PID=""
        break
      fi
      sleep 0.2
      i=$((i + 1))
    done
    [ -n "$SERVER_PID" ] && { stop_server; SERVER_RC="timeout"; }
    server_failure
    ask_retry
  done
}

make_profile() {
  if [ "$DRY" = 1 ]; then
    PROFILE="$TMP_ROOT/ddchrometest.XXXXXXXX"
    dry "would create the throwaway Chrome profile folder: $(shown mktemp -d "$TMP_ROOT/ddchrometest.XXXXXXXX")"
    return 0
  fi
  PROFILE="$(mktemp -d "$TMP_ROOT/ddchrometest.XXXXXXXX")" || PROFILE=""
  case "$PROFILE" in
    ("$TMP_ROOT"/ddchrometest.*) ;;
    (*) PROFILE=""; stop_here "Could not create the throwaway Chrome profile folder." ;;
  esac
}

launch_test_chrome() {
  local i
  while :; do
    wait_until_no_chrome
    if [ "$DRY" = 1 ]; then
      dry "would run: open -na \"Google Chrome\" --args --user-data-dir=\"$PROFILE\" --no-first-run --no-default-browser-check http://127.0.0.1:8765/"
      return 0
    fi
    if open -na "Google Chrome" --args --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check http://127.0.0.1:8765/; then
      i=0
      while [ $i -lt 30 ]; do
        if [ -n "$(find_test_chrome)" ]; then return 0; fi
        sleep 1
        i=$((i + 1))
      done
      say "The test Chrome did not open within 30 seconds."
    else
      say "macOS could not open Google Chrome."
    fi
    ask_retry
  done
}

chrome_tips() {
  say "A new, empty Chrome window shows the page \"DayDream device test\"."
  say "This is a throwaway Chrome, so it has no bookmarks or history. That is expected."
  say "  - If Chrome asks you to sign in, choose \"Don't sign in\", \"Skip\" or"
  say "    \"Use Chrome without an account\". Do not sign in."
  say "  - If it asks about the default browser or a search engine, pick anything."
  say "  - Box 8 on the page should say \"Loaded from localhost (a different site)\"."
  say "  - Keep just this one Chrome window open for now."
}

step_start() {
  step 4 "Open the test page in a throwaway Chrome"
  say "This starts a small test page that only this Mac can see, then opens a"
  say "separate, empty Chrome (a throwaway profile) just for the test."
  remove_leftovers
  make_work_dir
  start_page
  make_profile
  launch_test_chrome
  chrome_tips
  wait_return "When the test page shows, come back here and press Return."
}

# ---------------------------------------------------------------- step 5

pf_value() { grep -E "^$1:" "$WORK/preflight.txt" 2>/dev/null | tail -n 1 | sed -E "s/^$1:[[:space:]]*//"; }

run_preflight() {
  local -a extra
  extra=()
  [ "$SKIP_PROFILE" = 1 ] && extra=(--skip-profile-check)
  if [ "$DRY" = 1 ]; then
    dry "would run: $(shown "$HARNESS" preflight --request-permission) ${extra[*]+${extra[*]}}"
    dry "(this is when macOS asks; it checks the throwaway profile first)"
    PF_RC=0
    return 0
  fi
  printf '\n'
  "$HARNESS" preflight --request-permission ${extra[@]+"${extra[@]}"} >"$WORK/preflight.txt" 2>&1
  PF_RC=$?
  show_preflight
}

# Only the status lines, and only their first sentence for the profile: the
# harness's own hints (README steps, commands to type) are for developers,
# and this script explains each case itself. Anything unexpected is shown whole.
PF_LINES='^(Chrome profile|Chrome|Accessibility|Automation):'
show_preflight() {
  if grep -qE "$PF_LINES" "$WORK/preflight.txt" 2>/dev/null; then
    grep -E "$PF_LINES" "$WORK/preflight.txt" |
      sed -E -e '/^Chrome profile:/s/\. .*$/./' -e 's/ \(README step [0-9]+\)//' \
             -e "s/\\(Terminal\\)/($APP)/" -e 's/^/    /'
  else
    sed 's/^/    /' "$WORK/preflight.txt"
  fi
}

restart_test_chrome() {
  local pid
  say "Let's start the test Chrome again."
  pid="$(find_test_chrome)"
  if [ -n "$pid" ]; then
    if ask_yes "Close the test Chrome for you first? (Only the test Chrome is closed.)"; then
      close_test_chrome_pid "$pid" "$PROFILE"
    fi
  fi
  launch_test_chrome
  chrome_tips
  wait_return "When the test page shows, press Return."
}

explain_preflight() {
  local profile ax auto
  profile="$(pf_value 'Chrome profile')"
  ax="$(pf_value 'Accessibility')"
  auto="$(pf_value 'Automation')"
  printf '\n'
  case "$profile" in
    (*"Chrome is not running"*)
      say "The test Chrome is not open any more."
      restart_test_chrome; return 1 ;;
    (*"Chrome instances are running"*)
      say "More than one Chrome is open. Every other Chrome must quit."
      restart_test_chrome; return 1 ;;
    (*"real profile folder"*|*"not launched with --user-data-dir"*)
      say "The Chrome that is open is not the throwaway test Chrome."
      restart_test_chrome; return 1 ;;
    (*"Could not read Chrome's launch arguments"*)
      if [ -n "$(find_test_chrome)" ] && [ "$(chrome_mains | wc -l | tr -d ' ')" = 1 ]; then
        say "The test could not read Chrome's start options, but this script checked"
        say "that the only Chrome open is the test Chrome it started itself."
        if ask_yes "Carry on anyway? (The results will say this was not verified.)"; then SKIP_PROFILE=1; fi
      else
        restart_test_chrome
      fi
      return 1 ;;
  esac
  case "$ax" in
    (OFF*)
      say "$APP's Accessibility reads off again."
      ensure_accessibility
      # Wait for Return before checking again, even if it reads on now.
      return 0 ;;
  esac
  case "$auto" in
    (denied*)
      say "$APP is not allowed to control Chrome. Maybe \"Don't Allow\" was clicked,"
      say "or it was switched off earlier. Switch it on:"
      say "  1. System Settings opens at Privacy & Security > Automation."
      say "  2. Find $APP in the list (click the arrow next to it if there is one)."
      say "  3. Switch on \"Google Chrome\" under $APP."
      open_settings Automation
      wait_return "When it is on, press Return."
      return 1 ;;
    ("not decided"*)
      say "macOS did not show the box, or it was not answered yet." ;;
    ("Chrome not running"*)
      say "The test Chrome is not answering. Check that it is still open." ;;
    (error*)
      say "macOS reported a problem ($auto)." ;;
  esac
  return 0
}

step_permission() {
  local tries=0
  step 5 "Let $APP read the test Chrome's windows"
  say "Next, macOS shows a box:"
  say "   \"$APP\" wants access to control \"Google Chrome\"."
  say "Click Allow (on some Macs the button says OK)."
  say ""
  say "This lets the test read the test Chrome's window list and page addresses."
  say "It never clicks, types or reads what you type."
  say "(If you allowed it on an earlier try, no box appears. That is fine.)"
  wait_return "Press Return, then watch for the box."
  ASKED_AUTOMATION=1
  while :; do
    run_preflight
    case "$PF_RC" in
      (0) printf '\n'; say "OK: everything the test needs is allowed."; return 0 ;;
      (126|137|9) blocked_by_macos chrome-device-test "$PF_RC" ;;
    esac
    tries=$((tries + 1))
    if [ $tries -ge 6 ]; then
      stop_here "The permission check still does not pass after $tries tries." \
                "Please copy this line into your chat with Claude:" \
                "   kit: preflight exit $PF_RC after $tries tries; profile: $(pf_value 'Chrome profile' | sed -E 's/[:.].*//'); accessibility: $(pf_value Accessibility | cut -d' ' -f1); automation: $(pf_value Automation); macOS $(sw_vers -productVersion 2>/dev/null)"
      return 0
    fi
    explain_preflight && ask_retry
  done
}

# ---------------------------------------------------------------- step 6

# The report goes in the home folder: unlike the Desktop, macOS does not ask
# for a permission there, so Terminal gets no extra access for it.
pick_report() {
  local dir="$HOME" n=2
  if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then dir="$TMP_ROOT"; fi
  REPORT="$dir/chrome-device-test-report.json"
  while [ -e "$REPORT" ] && [ $n -lt 100 ]; do
    REPORT="$dir/chrome-device-test-report-$n.json"
    n=$((n + 1))
  done
  if [ "$dir" = "$HOME" ]; then
    say "The report will be saved in your home folder as $(basename "$REPORT")."
  else
    say "The report will be saved here: $REPORT"
  fi
}

step_guided_run() {
  local -a args
  step 6 "The guided test (about 35 minutes)"
  say "How it works:"
  say "  1. Terminal shows one test step at a time. First do the part under"
  say "     \"Before you press Return\"."
  say "  2. Press Return here in Terminal."
  say "  3. Click into the test Chrome and do the part under \"Then, in Chrome\"."
  say "  4. Tink = go: do the timed part now. Glass = done: come back to Terminal."
  say "  To skip a step: type s and press Return."
  say "  To stop early: type q and press Return. You still get the results."
  say "  (Please don't use Ctrl+C during the test: that loses the results.)"
  say ""
  say "Along the way you will need:"
  say "  - a second Chrome window (step 14, Cmd+N), later up to 10 (step 18)"
  say "  - Spotlight (step 19, Cmd+Space) and TextEdit (step 20)"
  say "  - an Incognito window (steps 21-23, Cmd+Shift+N) and a Guest window (step 24)"
  say "  - at steps 23 and 24 the test asks a question: type y and press Return"
  say "    when the answer is yes."
  say "  - before step 25, close the Guest window again (steps 25-26: boxes 12 and 13)"
  say "Use made-up words only. The only password is the dummy one on the page."
  if [ -n "$ONLY" ]; then
    say "" "Only these steps run this time: $ONLY"
    [ -n "$ONLY_ADDED" ] && say "$ONLY_ADDED"
  fi
  say ""
  pick_report
  args=(run --probe-labels --report "$REPORT")
  [ -n "$ONLY" ] && args+=(--only "$ONLY")
  [ -n "$SETTLE" ] && args+=(--settle "$SETTLE")
  [ "$SKIP_PROFILE" = 1 ] && args+=(--skip-profile-check)
  wait_return "Press Return to start the guided test."
  if [ "$DRY" = 1 ]; then
    dry "would run in this window, with the keyboard attached: $(shown "$HARNESS" "${args[@]}")"
    return 0
  fi
  printf '\n'
  "$HARNESS" "${args[@]}"
  RUN_RC=$?
  printf '\n'
  say "The guided test has finished. This script now does the clean-up with you."
}

# ---------------------------------------------------------------- step 8

end_screen() {
  local others settle_cmd
  [ "$ENDED" = 1 ] && return 0
  ENDED=1
  step 8 "Result"
  case "$RUN_RC" in
    (0) say "Result: CONTINUE. No stop rule failed." ;;
    (2) if [ "$DRY" != 1 ] && [ -n "$REPORT" ] && [ -f "$REPORT" ]; then
          settle_cmd="$RERUN_BASE"
          [ -n "$ONLY" ] && settle_cmd="$settle_cmd --only $ONLY"
          say "Result: RUN INVALID. A basic check (G1 to G4 in the table above) failed," \
              "so this run does not count on its own."
          say "If the G4 line says FAIL, macOS was slow to report which app is in front." \
              "Run the test again with --settle 5, which waits a little longer:" \
              "       $settle_cmd --settle 5" \
              "Otherwise, send the report and Claude will say what to do."
        else
          say "The test could not find the test Chrome when it started, so no step ran."
        fi ;;
    (3) say "Result: ABANDON. A stop rule failed." ;;
    (4) say "Result: INCOMPLETE. Some needed steps did not run. Send the report anyway:" \
            "Claude will tell you which steps to run again (with --only)." ;;
    (1) say "The test stopped before the steps began (a permission was missing)." ;;
    ("") if [ "$DRY" = 1 ]; then say "(dry run: nothing ran)";
         elif [ "$INTERRUPTED" = 1 ]; then say "You stopped the test before it finished.";
         else say "The guided test did not run."; fi ;;
    (*) say "The test ended with code $RUN_RC." ;;
  esac
  if [ "$DRY" != 1 ] && [ -n "$REPORT" ] && [ -f "$REPORT" ]; then
    say "" "Whatever the result, please send the report. It is this file (in your home folder):" "  $REPORT"
    open -R "$REPORT"
    say "A Finder window now shows it. Attach that one file to a GitHub issue:"
    say "Drag the file into the issue's comment box."
    say ""
    say "The report holds no typed text, no window titles and no full web"
    say "addresses: only pass/fail results, timings and short site names such as"
    say "http://127.0.0.1:8765."
    others="$(ls "$(dirname "$REPORT")"/chrome-device-test-report*.json 2>/dev/null | grep -vxF "$REPORT" | wc -l | tr -d ' ')"
    if [ "${others:-0}" != 0 ]; then
      say "" "There are also $others report file(s) from earlier tries next to it. Send those too."
    fi
  elif [ "$DRY" = 1 ]; then
    dry "would show the report in Finder: $(shown open -R "$REPORT")"
  else
    say "" "No report file was written this time."
  fi
  say "" "Thank you!"
}

# ---------------------------------------------------------------- main

while [ $# -gt 0 ]; do
  case "$1" in
    (--dry-run) DRY=1 ;;
    (--only)
      [ $# -ge 2 ] || { say "--only needs step names, for example --only guest,spotlight"; exit 64; }
      ONLY="$2"; shift ;;
    (--only=*) ONLY="${1#--only=}" ;;
    (--settle)
      [ $# -ge 2 ] || { say "--settle needs a number of seconds"; exit 64; }
      SETTLE="$2"; shift ;;
    (--help|-h) usage; exit 0 ;;
    (*) say "Unknown option: $1" ""; usage; exit 64 ;;
  esac
  shift
done

if [ -n "$ONLY" ]; then
  ONLY="$(printf '%s' "$ONLY" | tr -d ' ')"
  set -f
  old_ifs=$IFS
  IFS=,
  for id in $ONLY; do
    case " $STEP_IDS " in
      (*" $id "*) ;;
      (*) IFS=$old_ifs; say "Unknown step name: $id" ""; usage; exit 64 ;;
    esac
  done
  IFS=$old_ifs
  set +f
  # Every kit run starts with a new Chrome that has one window, so a step that
  # needs windows opened by an earlier step gets that step added. Without it,
  # incognito-background would run with no Incognito window at all.
  if { only_has incognito-background || only_has incognito-closing; } && ! only_has incognito-race; then
    ONLY="$ONLY,incognito-race"
    ONLY_ADDED="${ONLY_ADDED}Added incognito-race: it opens the Incognito window that the other Incognito steps need."$'\n'
  fi
  if { only_has two-windows-old || only_has two-windows-zoomed || only_has minimized-window; } && ! only_has two-windows-new; then
    ONLY="$ONLY,two-windows-new"
    ONLY_ADDED="${ONLY_ADDED}Added two-windows-new: it opens the second window that the other window steps need."$'\n'
  fi
  ONLY_ADDED="${ONLY_ADDED%$'\n'}"
fi
if [ -n "$SETTLE" ]; then
  case "$SETTLE" in
    (''|*[!0-9.]*|*.*.*|.) say "--settle needs a number of seconds, for example --settle 5"; exit 64 ;;
  esac
fi
if [ -z "$KIT_DIR" ]; then say "Could not find the kit folder."; exit 1; fi

case "$KIT_DIR" in
  (*[\"\$\`\\]*) RERUN_BASE="bash $(printf '%q' "$KIT_DIR/run.sh")" ;;
  (*) RERUN_BASE="bash \"$KIT_DIR/run.sh\"" ;;
esac
RERUN_CMD="$RERUN_BASE"
[ -n "$ONLY" ] && RERUN_CMD="$RERUN_CMD --only $ONLY"
[ -n "$SETTLE" ] && RERUN_CMD="$RERUN_CMD --settle $SETTLE"

printf '\n%sDayDream Chrome test%s\n\n' "$BOLD" "$PLAIN"
take_lock
if [ "$DRY" = 1 ]; then
  say "DRY RUN: nothing is started, opened, changed or asked. Each action is"
  say "printed instead, and questions take their default answer."
  say ""
fi
say "This checks whether DayDream can tell which Chrome window and which box you"
say "are typing in, from outside Chrome. It takes about 50 minutes."
say ""
say "Before you start:"
say "  - Use made-up words only, for example: purple lamp sings over quiet hills."
say "  - The only password you type is the dummy one already on the test page."
say "  - Your own Chrome and DayDream must be quit. Steps 1 and 3 help with that."
say "  - Stay near the Mac with the sound on."
say "You can stop at any time with Ctrl+C. The script cleans up and tells you"
say "anything left to switch off, and you can run the same command again later."
if [ -n "$ONLY_ADDED" ]; then say "" "$ONLY_ADDED"; fi
wait_return "Press Return to start."

step 1 "Quick checks"
check_terminal
load_state
check_kit_files
check_mac
check_chrome
sound_check
title "DayDream"
quit_daydream

step 2 "Let $APP see which window is in front (Accessibility)"
say "The test needs macOS's Accessibility permission for $APP. It lets the test"
say "see which window and which box are active. It never reads what you type."
ensure_accessibility

step_quit_apps
step_start
step_permission
step_guided_run
finish "${RUN_RC:-0}"
