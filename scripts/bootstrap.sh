#!/usr/bin/env bash
# Fetch DayDream's pinned third-party build dependencies into Vendor/.
#
# Today that is one thing: the Sparkle 2.9.6 framework (the app's updater),
# downloaded from Sparkle's official GitHub release and checked against a
# pinned SHA-256 before anything is unpacked. Run it once after cloning, then
# run `swift build`. Running it again is safe: it does nothing when the
# dependency is already in place.
#
# Usage: scripts/bootstrap.sh [--offline]
#   --offline   Never use the network. Unpack only from the cached archive in
#               .build/dependencies/, and fail if it is missing or wrong.
#
# This script installs nothing system-wide, changes no settings, requests no
# permissions and signs nothing. It writes only to Vendor/ and .build/.

set -euo pipefail

SPARKLE_VERSION="2.9.6"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip"
# SHA-256 of the release asset above. packaging/sparkle.json carries the same
# pin for the packaging scripts; this script stops if the two ever disagree.
SPARKLE_SHA256="8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"

# Headers that WriterBackend/Sources/CLlamaBridge/WriterLlama.cpp includes.
# They are committed to the repository; this script only checks they exist.
LLAMA_HEADERS="llama.h ggml.h gguf.h ggml-alloc.h ggml-backend.h ggml-cpu.h ggml-opt.h"

offline=0
for arg in "$@"; do
  case "$arg" in
    --offline) offline=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'bootstrap: unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
vendor="$root/Vendor"
target="$vendor/Sparkle-$SPARKLE_VERSION"
framework="$target/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
stamp="$target/.bootstrap-sha256"
cache="$root/.build/dependencies"
# Same cache path as scripts/bootstrap-sparkle.py, so the two share one download.
archive="$cache/Sparkle-$SPARKLE_VERSION.zip"

say()  { printf 'bootstrap: %s\n' "$*"; }
warn() { printf 'bootstrap: warning: %s\n' "$*" >&2; }
die()  { printf 'bootstrap: error: %s\n' "$*" >&2; exit 1; }

# Temporary paths are removed on any exit, including failures.
partial=""
stage_dir=""
cleanup() {
  if [[ -n "$partial" ]]; then rm -f "$partial"; fi
  if [[ -n "$stage_dir" ]]; then rm -rf "$stage_dir"; fi
  return 0
}
trap cleanup EXIT

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

check_environment() {
  [[ "$(uname -s)" == Darwin ]] || die "DayDream builds on macOS only."
  local tool
  for tool in curl shasum ditto zipinfo codesign plutil awk; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
  done
  if [[ "$(uname -m)" != arm64 ]]; then
    warn "DayDream supports Apple silicon Macs only; building on $(uname -m) is untested."
  fi
  if ! command -v swift >/dev/null 2>&1; then
    warn "swift not found. Install Xcode or the Xcode Command Line Tools before running 'swift build'."
  fi
}

# The pin in this script and the one in packaging/sparkle.json must agree.
check_pin_file() {
  local pin_file="$root/packaging/sparkle.json" key value expected
  [[ -f "$pin_file" ]] || return 0
  for key in version url sha256; do
    value="$(plutil -extract "$key" raw -o - "$pin_file" 2>/dev/null)" \
      || die "could not read '$key' from packaging/sparkle.json"
    case "$key" in
      version) expected="$SPARKLE_VERSION" ;;
      url)     expected="$SPARKLE_URL" ;;
      sha256)  expected="$SPARKLE_SHA256" ;;
    esac
    [[ "$value" == "$expected" ]] \
      || die "packaging/sparkle.json has $key '$value' but this script pins '$expected'. Update both together."
  done
}

framework_verifies() {
  [[ -d "$framework" ]] && codesign --verify --deep --strict "$framework" >/dev/null 2>&1
}

# Leaves a verified copy of the pinned archive at $archive.
fetch_archive() {
  mkdir -p "$cache"
  if [[ -f "$archive" ]]; then
    if [[ "$(sha256_of "$archive")" == "$SPARKLE_SHA256" ]]; then
      say "Using the cached archive in .build/dependencies/ (SHA-256 matches the pin)."
      return 0
    fi
    warn "the cached archive does not match the pinned SHA-256; discarding it."
    rm -f "$archive"
  fi
  if [[ "$offline" == 1 ]]; then
    die "--offline was given and no verified archive is cached at .build/dependencies/Sparkle-$SPARKLE_VERSION.zip"
  fi

  say "Downloading Sparkle $SPARKLE_VERSION from its official GitHub release..."
  partial="$(mktemp "$cache/Sparkle-$SPARKLE_VERSION.zip.partial.XXXXXX")"
  curl --fail --location --silent --show-error \
       --proto '=https' --proto-redir '=https' --tlsv1.2 \
       --retry 2 --connect-timeout 20 --max-time 300 \
       --output "$partial" "$SPARKLE_URL" \
    || die "download failed: $SPARKLE_URL"

  local actual
  actual="$(sha256_of "$partial")"
  if [[ "$actual" != "$SPARKLE_SHA256" ]]; then
    die "checksum mismatch: got $actual, expected $SPARKLE_SHA256. Nothing was unpacked."
  fi
  mv -f "$partial" "$archive"
  partial=""
  say "Download verified (SHA-256 matches the pin)."
}

# Unpacks $archive into $target through a staging folder, so an interrupted
# run never leaves a half-written Vendor/Sparkle-<version>.
unpack_archive() {
  local names name
  names="$(zipinfo -1 "$archive")" || die "could not list the archive contents."
  while IFS= read -r name; do
    case "$name" in
      /*|..|../*|*/..|*/../*) die "refusing to unpack: unsafe path in archive: $name" ;;
    esac
  done <<< "$names"

  mkdir -p "$vendor"
  stage_dir="$(mktemp -d "$vendor/.sparkle-bootstrap.XXXXXX")"
  ditto -x -k "$archive" "$stage_dir/payload" || die "could not unpack the archive."
  [[ -d "$stage_dir/payload/Sparkle.xcframework" ]] \
    || die "unexpected archive layout: no Sparkle.xcframework at the top level."
  printf '%s\n' "$SPARKLE_SHA256" > "$stage_dir/payload/.bootstrap-sha256"

  [[ ! -e "$target" ]] || die "Vendor/Sparkle-$SPARKLE_VERSION appeared while unpacking. Run this script again."
  mv "$stage_dir/payload" "$target"
  rm -rf "$stage_dir"
  stage_dir=""
}

# An existing folder is accepted only with the stamp that unpack_archive (or
# scripts/bootstrap-sparkle.py) writes after checking the archive's SHA-256.
# Sparkle's framework is ad-hoc signed, so codesign alone proves the files are
# intact, not where they came from.
ensure_sparkle() {
  if [[ -d "$target" ]]; then
    if [[ ! -f "$stamp" || "$(cat "$stamp")" != "$SPARKLE_SHA256" ]]; then
      die "Vendor/Sparkle-$SPARKLE_VERSION wasn't installed from the pinned archive by this script. Delete it and run this script again."
    fi
    if framework_verifies; then
      say "Sparkle $SPARKLE_VERSION is already in Vendor/ (installed from the pinned archive). Nothing to do."
      return 0
    fi
    die "Vendor/Sparkle-$SPARKLE_VERSION exists but its framework failed code-signature verification. Delete that folder and run this script again."
  fi

  fetch_archive
  unpack_archive
  if ! framework_verifies; then
    rm -rf "$target"
    die "the unpacked Sparkle framework failed code-signature verification; removed it again."
  fi
  say "Installed Sparkle $SPARKLE_VERSION into Vendor/Sparkle-$SPARKLE_VERSION (installed from the pinned archive; code signature intact)."
}

check_llama_headers() {
  local dir="$root/WriterBackend/Sources/CLlamaBridge/vendor" missing="" header
  for header in $LLAMA_HEADERS; do
    [[ -f "$dir/$header" ]] || missing="$missing $header"
  done
  if [[ -n "$missing" ]]; then
    warn "missing llama.cpp headers in WriterBackend/Sources/CLlamaBridge/vendor/:$missing"
    warn "they are part of the repository and 'swift build' fails without them. Re-clone, and check that no ignore rule hides that folder."
    return 1
  fi
  return 0
}

check_environment
check_pin_file
ensure_sparkle
if check_llama_headers; then
  say "Done. Next: swift build"
else
  say "Sparkle is ready, but fix the warning above before running swift build."
  exit 1
fi
