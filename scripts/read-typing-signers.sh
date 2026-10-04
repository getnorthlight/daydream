#!/bin/bash
# Read-only: print the signer of each app in the typing table that is
# installed on this Mac, so a row's TypingSigner can be filled in from what the
# app really carries (PrivacyPolicy/Sources/PrivacyPolicy/TypingCategories.swift).
# It only runs `codesign -d` (display). It never signs, launches or changes an app.
#
# A row may be opened only after its bundle ID and signer were read this way:
#   Identifier      -> the row's bundle ID (bundleConfirmed: true)
#   TeamIdentifier  -> .team("<TEAM>") for a Developer ID app
#   "Software Signing" authority, no team -> .apple
#   "Apple Mac OS Application Signing"   -> .appStore
set -u
apps=(
  "/System/Applications/Notes.app" "/System/Applications/TextEdit.app"
  "/Applications/Pages.app" "/Applications/Pages Creator Studio.app" "/Applications/Microsoft Word.app"
  "/Applications/Notion.app" "/Applications/Obsidian.app"
  "/System/Library/CoreServices/Spotlight.app" "/Applications/Claude.app" "/Applications/ChatGPT.app"
  "/Applications/Raycast.app" "/Applications/Perplexity.app"
  "/System/Applications/Utilities/Terminal.app" "/Applications/iTerm.app" "/Applications/Ghostty.app"
  "/Applications/Xcode.app" "/Applications/Visual Studio Code.app" "/Applications/Cursor.app"
  "/Applications/Zed.app" "/Applications/Warp.app"
  "/System/Applications/Messages.app" "/System/Applications/Mail.app" "/Applications/Slack.app"
  "/Applications/Discord.app" "/Applications/WhatsApp.app" "/Applications/Microsoft Outlook.app"
  # fix/app-coverage: launch apps not in the table yet (a row needs its identifier and signer from here first).
  "/Applications/Telegram.app" "/Applications/Signal.app" "/Applications/Microsoft Teams.app" "/Applications/zoom.us.app"
)
for app in "${apps[@]}"; do
  [ -d "$app" ] || { echo "-- not installed: $app"; continue; }
  info=$(codesign -dv --verbose=2 "$app" 2>&1)
  id=$(printf '%s\n' "$info" | sed -n 's/^Identifier=//p')
  team=$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p')
  leaf=$(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -1)
  req=$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')
  printf '%s\n  identifier: %s\n  team: %s\n  leaf: %s\n  designated: %s\n' "$app" "$id" "$team" "$leaf" "$req"
done
