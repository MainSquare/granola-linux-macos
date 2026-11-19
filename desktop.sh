#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-}"
APP_DIR="${2:-$PROJECT_DIR/build/granola}"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$APPLICATIONS_DIR/granola-linux-macos.desktop"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
NATIVE_HOST_MANIFEST="com.granola.app.json"
# Granola registers its Meet consent host only in macOS and Windows browser
# locations, so the Granola Companion extension needs the Linux ones from here.
BROWSER_CONFIG_DIRS=(
  google-chrome google-chrome-beta google-chrome-unstable chromium
  BraveSoftware/Brave-Browser microsoft-edge vivaldi
)

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "Usage: $0 install [build-directory]" \
    "       $0 uninstall"
}

case "$ACTION" in
  install)
    [[ $# -le 2 ]] || die "install accepts at most one build directory"
    APP_DIR="$(realpath -m "$APP_DIR")"
    [[ -x "$APP_DIR/run-granola" ]] || die "build not found at $APP_DIR"
    [[ -f "$APP_DIR/.granola-linux-macos-build" ]] \
      || die "unrecognized build directory: $APP_DIR"
    [[ "$APP_DIR" != *$'\n'* \
      && "$APP_DIR" != *$'\r'* \
      && "$APP_DIR" != *'"'* \
      && "$APP_DIR" != *'%'* \
      && "$APP_DIR" != *'\\'* ]] \
      || die "application path contains unsupported desktop-entry characters"
    mkdir -p "$APPLICATIONS_DIR"
    TEMP_FILE="$(mktemp "$APPLICATIONS_DIR/.granola-linux-macos.XXXXXX.desktop")"
    trap 'rm -f -- "$TEMP_FILE"' EXIT
    cat >"$TEMP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Granola
Comment=Unofficial Linux compatibility build for Granola
Exec="$APP_DIR/run-granola" %U
Icon=$APP_DIR/granola-app-icon.png
Terminal=false
Categories=Office;
Keywords=meeting;notes;transcription;
StartupNotify=true
StartupWMClass=granola
MimeType=x-scheme-handler/granola;
X-Granola-Linux-MacOS-Identity=true
EOF
    chmod 0644 "$TEMP_FILE"
    command -v desktop-file-validate >/dev/null \
      && desktop-file-validate "$TEMP_FILE"
    mv "$TEMP_FILE" "$DESKTOP_FILE"
    command -v update-desktop-database >/dev/null \
      && update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
    command -v xdg-mime >/dev/null \
      && xdg-mime default "$(basename "$DESKTOP_FILE")" \
        x-scheme-handler/granola >/dev/null 2>&1 || true
    printf 'Installed desktop entry: %s\n' "$DESKTOP_FILE"
    NATIVE_HOST="$APP_DIR/resources/native-host/meet-consent-host"
    if [[ -x "$NATIVE_HOST" ]]; then
      NATIVE_HOST_JSON="$(python3 -I -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$NATIVE_HOST")"
      for browser_dir in "${BROWSER_CONFIG_DIRS[@]}"; do
        [[ -d "$CONFIG_DIR/$browser_dir" ]] || continue
        mkdir -p "$CONFIG_DIR/$browser_dir/NativeMessagingHosts"
        manifest="$CONFIG_DIR/$browser_dir/NativeMessagingHosts/$NATIVE_HOST_MANIFEST"
        cat >"$manifest" <<EOF
{
  "name": "com.granola.app",
  "description": "Granola meeting notes - consent messaging",
  "path": $NATIVE_HOST_JSON,
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://fihphjchjdimokpleomddhnapnobdphn/",
    "chrome-extension://ephifgbopdapgehlpnakaddgmmgcbmjp/",
    "chrome-extension://opaadbjlebbbnmjjgdmdllingedoleml/"
  ]
}
EOF
        printf 'Installed Granola Companion host for %s: %s\n' "$browser_dir" "$manifest"
      done
    fi
    ;;
  uninstall)
    [[ $# -eq 1 ]] || die "uninstall does not accept additional arguments"
    if [[ -f "$DESKTOP_FILE" ]]; then
      rm -- "$DESKTOP_FILE"
      printf 'Removed desktop entry: %s\n' "$DESKTOP_FILE"
    else
      printf 'Desktop entry is already absent: %s\n' "$DESKTOP_FILE"
    fi
    for browser_dir in "${BROWSER_CONFIG_DIRS[@]}"; do
      manifest="$CONFIG_DIR/$browser_dir/NativeMessagingHosts/$NATIVE_HOST_MANIFEST"
      if [[ -f "$manifest" ]]; then
        rm -- "$manifest"
        printf 'Removed Granola Companion host: %s\n' "$manifest"
      fi
    done
    command -v update-desktop-database >/dev/null \
      && update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
    ;;
  -h|--help)
    [[ $# -eq 1 ]] || die "help does not accept additional arguments"
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
