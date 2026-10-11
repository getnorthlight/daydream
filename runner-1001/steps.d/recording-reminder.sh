# rel-019: the recording-off reminder (Sources/MacMemApp/RecordingReminder.swift, RecordingReminderPanel.swift). Row in
# scripts/checks-manifest.d/recording-reminder.tsv, bug re-injections in scripts/mutations.d/recording-reminder.tsv.
# Sourced by run-checks.sh (steps.d/README).
#
#   owner-recording-reminder   the hour of active use (idle, lock, sleep and another user don't count), once a day
#                              across a relaunch, no reminder while setup is unfinished, during a timed pause, with a
#                              permission missing or while recording; Start Recording is the menu bar's own Start. The
#                              pure rules, then the REAL MemoryViewModel with the check seams and a fake reminder system
#                              (its own clock, idle read, defaults and panel). No window, notification or permission read.
if have_ob && [ -f scripts/recording-reminder-checks.swift ]; then
  ORRHOME=$OUT/owner-recording-reminder-home; ORRDD=$OUT/owner-recording-reminder-dd
  [ -n "${DRYRUN:-}" ] || { mkdir -p "$ORRHOME/Library/Preferences" "$ORRDD"; chmod 700 "$ORRDD"; }
  step compile-owner-recording-reminder app_link "$OB" "$OUT/owner-recording-reminder" scripts/recording-reminder-checks.swift "${OMF[@]}"
  step owner-recording-reminder env HOME="$ORRHOME" CFFIXED_USER_HOME="$ORRHOME" DD_CHECK_OUT="$ORRDD" "$OUT/owner-recording-reminder"
fi
