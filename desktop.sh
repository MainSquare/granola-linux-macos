#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${GRANOLA_CONFIG_FILE:-$PROJECT_DIR/granola.conf}"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$APPLICATIONS_DIR/granola-linux-macos.desktop"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "Usage: $0 install [--scheme-handler|--no-scheme-handler] [build-directory]" \
    "       $0 uninstall" \
    "" \
    "  --scheme-handler      Register granola:// on this host, so the browser can" \
    "                        hand the OAuth callback straight to Granola." \
    "  --no-scheme-handler   Leave the scheme unclaimed. The callback URL is then" \
    "                        delivered by hand, once per login." \
    "" \
    "Unset options are read from granola.conf, then asked for interactively." \
    "The answer to a prompt is saved back to granola.conf."
}

remember() {
  local key="$1" value="$2" directory
  directory="$(dirname "$CONFIG_FILE")"
  [[ -d "$directory" && -w "$directory" ]] || return 0
  if [[ -f "$CONFIG_FILE" ]] && grep -q "^$key=" "$CONFIG_FILE"; then
    sed -i "s|^$key=.*|$key=$value|" "$CONFIG_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >>"$CONFIG_FILE"
  fi
  printf 'Saved %s=%s in %s\n' "$key" "$value" "$CONFIG_FILE"
}

# Prints 0 or 1 on stdout; prompts and notices go to stderr. With required=1 a
# missing value on a non-interactive run is an error rather than a default,
# because silently claiming a host MIME association is the surprise to avoid.
setting() {
  local key="$1" default="$2" required="$3" question="$4"
  local value="${!key-}" hint reply

  if [[ -z "$value" ]]; then
    if [[ -t 0 ]]; then
      if [[ "$default" == 1 ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
      printf '%s %s ' "$question" "$hint" >&2
      read -r reply || reply=""
      case "${reply,,}" in
        y|yes) value=1 ;;
        n|no) value=0 ;;
        *) value="$default" ;;
      esac
      remember "$key" "$value" >&2
    elif [[ "$required" == 1 ]]; then
      die "$key is not set: pass --scheme-handler or --no-scheme-handler, or set it in $CONFIG_FILE"
    else
      value="$default"
      printf '%s is not configured; using %s.\n' "$key" "$value" >&2
    fi
  fi

  case "$value" in
    0 | 1) ;;
    *) die "invalid $key=$value (expected 0 or 1)" ;;
  esac
  printf '%s' "$value"
}

ACTION="${1:-}"
shift || true

case "$ACTION" in
  install)
    APP_DIR=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --scheme-handler) GRANOLA_SCHEME_HANDLER=1; shift ;;
        --no-scheme-handler) GRANOLA_SCHEME_HANDLER=0; shift ;;
        -*) die "unknown option: $1" ;;
        *)
          [[ -z "$APP_DIR" ]] || die "install accepts at most one build directory"
          APP_DIR="$1"
          shift
          ;;
      esac
    done
    APP_DIR="$(realpath -m "${APP_DIR:-$PROJECT_DIR/build/granola}")"
    [[ -x "$APP_DIR/run-granola" ]] || die "build not found at $APP_DIR"
    [[ -f "$APP_DIR/.granola-linux-macos-build" ]] \
      || die "unrecognized build directory: $APP_DIR"
    [[ "$APP_DIR" != *$'\n'* \
      && "$APP_DIR" != *$'\r'* \
      && "$APP_DIR" != *'"'* \
      && "$APP_DIR" != *'%'* \
      && "$APP_DIR" != *'\\'* ]] \
      || die "application path contains unsupported desktop-entry characters"

    # The environment and the flags win over the file, so keep them across the
    # source. The launcher has no stdin, so its choices are baked into Exec=
    # and it never has to prompt.
    ENV_AUDIO="${GRANOLA_AUDIO-}"
    ENV_BLUETOOTH_HFP="${GRANOLA_BLUETOOTH_HFP-}"
    ENV_SCHEME_HANDLER="${GRANOLA_SCHEME_HANDLER-}"
    if [[ -f "$CONFIG_FILE" ]]; then
      # shellcheck source=/dev/null
      source "$CONFIG_FILE"
    fi
    [[ -z "$ENV_AUDIO" ]] || GRANOLA_AUDIO="$ENV_AUDIO"
    [[ -z "$ENV_BLUETOOTH_HFP" ]] || GRANOLA_BLUETOOTH_HFP="$ENV_BLUETOOTH_HFP"
    [[ -z "$ENV_SCHEME_HANDLER" ]] || GRANOLA_SCHEME_HANDLER="$ENV_SCHEME_HANDLER"

    AUDIO="$(setting GRANOLA_AUDIO 1 0 \
      'Give Granola access to your microphone and system audio?')"
    BLUETOOTH_HFP="$(setting GRANOLA_BLUETOOTH_HFP 0 0 \
      'Let Granola switch a Bluetooth headset to the HFP profile while it runs?')"
    SCHEME_HANDLER="$(setting GRANOLA_SCHEME_HANDLER 0 1 \
      'Register granola:// on this host, so browser sign-in can hand the callback to Granola?')"
    if [[ "$AUDIO" == 0 && "$BLUETOOTH_HFP" == 1 ]]; then
      printf 'Audio is disabled, so the Bluetooth HFP profile is left alone.\n' >&2
      BLUETOOTH_HFP=0
    fi

    EXEC_LINE="/usr/bin/env GRANOLA_AUDIO=$AUDIO"
    EXEC_LINE+=" GRANOLA_BLUETOOTH_HFP=$BLUETOOTH_HFP"
    EXEC_LINE+=" \"$APP_DIR/run-granola\""
    MIME_LINE=""
    if [[ "$SCHEME_HANDLER" == 1 ]]; then
      EXEC_LINE+=" %U"
      MIME_LINE="MimeType=x-scheme-handler/granola;"
    fi

    mkdir -p "$APPLICATIONS_DIR"
    TEMP_FILE="$(mktemp "$APPLICATIONS_DIR/.granola-linux-macos.XXXXXX.desktop")"
    trap 'rm -f -- "$TEMP_FILE"' EXIT
    cat >"$TEMP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Granola
Comment=Unofficial Linux compatibility build for Granola
Exec=$EXEC_LINE
Icon=$APP_DIR/granola-app-icon.png
Terminal=false
Categories=Office;
Keywords=meeting;notes;transcription;
StartupNotify=true
StartupWMClass=granola
${MIME_LINE}
X-Granola-Linux-MacOS-Identity=true
EOF
    chmod 0644 "$TEMP_FILE"
    command -v desktop-file-validate >/dev/null \
      && desktop-file-validate "$TEMP_FILE"
    mv "$TEMP_FILE" "$DESKTOP_FILE"
    command -v update-desktop-database >/dev/null \
      && update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
    if [[ "$SCHEME_HANDLER" == 1 ]]; then
      command -v xdg-mime >/dev/null \
        && xdg-mime default "$(basename "$DESKTOP_FILE")" \
          x-scheme-handler/granola >/dev/null 2>&1 || true
      printf 'Registered granola:// on this host.\n'
    else
      printf 'Left granola:// unclaimed; deliver the login callback by hand.\n'
    fi
    printf 'Installed desktop entry: %s\n' "$DESKTOP_FILE"
    ;;
  uninstall)
    [[ $# -eq 0 ]] || die "uninstall does not accept additional arguments"
    if [[ -f "$DESKTOP_FILE" ]]; then
      rm -- "$DESKTOP_FILE"
      printf 'Removed desktop entry: %s\n' "$DESKTOP_FILE"
    else
      printf 'Desktop entry is already absent: %s\n' "$DESKTOP_FILE"
    fi
    command -v update-desktop-database >/dev/null \
      && update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
    ;;
  -h|--help)
    [[ $# -eq 0 ]] || die "help does not accept additional arguments"
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
