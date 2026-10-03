#!/usr/bin/env bash
# One-shot rebuild: backend + admin UI + H5, then the signed release Android APK.
#
#   ./deploy.sh                  everything
#   ./deploy.sh --skip-app       backend + web UIs only (restarts the server)
#   ./deploy.sh --skip-server    Android release APK only
#
# 1. server/run.sh restart -w   rebuilds admin (../admin) and H5 (../h5) into the Go
#                               binary, then restarts the background server.
# 2. flutter build apk --release   signed with app/android/key.properties; the script
#                               refuses to run without it so a debug-signed APK can
#                               never be produced by accident.
# The APK is copied to release/quizmind-<version>.apk (also release/quizmind-latest.apk).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

DO_SERVER=1
DO_APP=1
for arg in "$@"; do
  case "$arg" in
    --skip-server) DO_SERVER=0 ;;
    --skip-app) DO_APP=0 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"; }

# --- preflight: fail before doing any slow work -------------------------------
if [ "$DO_SERVER" = 1 ]; then
  need go; need node; need npm; need make
fi

if [ "$DO_APP" = 1 ]; then
  need flutter
  KEYPROPS=app/android/key.properties
  [ -f "$KEYPROPS" ] || die "$KEYPROPS missing: a release build would fall back to the debug key"
  for k in storePassword keyPassword keyAlias storeFile; do
    grep -q "^$k=." "$KEYPROPS" || die "$KEYPROPS has no $k"
  done
  STORE=$(sed -n 's/^storeFile=//p' "$KEYPROPS" | tr -d '\r')
  case "$STORE" in /*) ;; *) STORE="app/android/app/$STORE" ;; esac
  [ -f "$STORE" ] || die "keystore not found: $STORE"
fi

# --- backend + admin + H5 -------------------------------------------------------
if [ "$DO_SERVER" = 1 ]; then
  step "Server: build admin + H5, rebuild binary, restart"
  (cd server && ./run.sh restart -w)
fi

# --- Android release APK --------------------------------------------------------
if [ "$DO_APP" = 1 ]; then
  step "Android: flutter pub get"
  (cd app && flutter pub get)

  step "Android: flutter build apk --release"
  (cd app && flutter build apk --release)

  APK=app/build/app/outputs/flutter-apk/app-release.apk
  [ -f "$APK" ] || die "build finished but $APK is missing"

  VERSION=$(sed -n 's/^version:[[:space:]]*//p' app/pubspec.yaml | tr -d '\r' | tr '+' '-')
  mkdir -p release
  cp "$APK" "release/quizmind-${VERSION}.apk"
  cp "$APK" release/quizmind-latest.apk

  # Confirm it is signed with the release key, not the debug one.
  if command -v apksigner >/dev/null 2>&1; then
    apksigner verify --print-certs "$APK" | sed -n '1,3p'
  fi
fi

step "Done"
if [ "$DO_SERVER" = 1 ]; then
  (cd server && ./run.sh status)
fi
if [ "$DO_APP" = 1 ]; then
  echo "APK: $ROOT/release/quizmind-${VERSION}.apk ($(du -h "release/quizmind-${VERSION}.apk" | cut -f1))"
fi
