#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/granola"
CACHE_DIR="$PROJECT_DIR/.cache"
MACOS_VERSION=""
DMG_PATH=""
INSTALL_DESKTOP=0
DESKTOP_ARGS=()

GRANOLA_DOWNLOAD_URL="https://api.granola.ai/v1/download-latest"

usage() {
  printf '%s\n' \
    "Build Granola's official macOS Electron payload for a Linux runtime while" \
    "exposing a macOS product identity to Granola's renderer and backend." \
    "" \
    "This build downloads only from reviewed official sources: npm registry" \
    "tarballs (SRI-locked) plus node-gyp's dependencies via pnpm, and the" \
    "Electron runtime zip + SHASUMS from github.com/electron releases." \
    "The DMG and Electron headers must already exist locally; a missing" \
    "file aborts with the exact URL. 7-Zip (7zz) must be installed." \
    "" \
    "Usage:" \
    "  ./build.sh [options] /path/to/Granola.dmg" \
    "" \
    "Options:" \
    "  --output DIR                   Build destination (default: build/granola)" \
    "  --cache-dir DIR                Local artifact cache (default: .cache)" \
    "  --macos-version VERSION        Identity version (default: installer SDK)" \
    "  --install-desktop              Install/update the desktop launcher after building" \
    "  --scheme-handler               Register granola:// when installing the launcher" \
    "  --no-scheme-handler            Leave granola:// unclaimed on this host" \
    "  -h, --help                     Show this help"
}

# Build Granola's official macOS Electron payload for a Linux runtime while
# exposing a macOS product identity to Granola's renderer and backend.
#
# This build downloads only from reviewed official sources: npm registry
# tarballs (SRI-locked) plus node-gyp's dependencies via pnpm, and the
# Electron runtime zip + SHASUMS from github.com/electron releases. The
# DMG and Electron headers must already exist locally; a missing file
# aborts with the URL.
#
# Usage:
#   ./build.sh [options] /path/to/Granola.dmg
#
# Options:
#   --output DIR                   Build destination (default: build/granola)
#   --cache-dir DIR                Local artifact cache (default: .cache)
#   --macos-version VERSION        Identity version (default: installer SDK)
#   --install-desktop              Install/update the desktop launcher after building
#   -h, --help                     Show this help

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n==> %s\n' "$*"
}

note() {
  printf '    %s\n' "$*"
}

require_local_file() {
  local path="$1"
  local url="$2"
  [[ -f "$path" ]] || die \
    "offline build: missing $path - download it yourself (e.g. from $url) and place it there"
}

# Used only for reviewed official sources: registry.npmjs.org tarballs
# (verified with locked SRI values) and github.com/electron/electron
# release assets (verified against Electron's SHASUMS256.txt).
download_official() {
  local url="$1"
  local destination="$2"
  local partial="${destination}.part"
  mkdir -p "$(dirname "$destination")"
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --retry 3 --retry-delay 1 \
    --output "$partial" "$url"
  mv "$partial" "$destination"
}

plist_string() {
  local key="$1"
  local plist="$2"
  sed -n "/<key>${key}<\/key>/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;q}" "$plist"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || die "--output requires a directory"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || die "--cache-dir requires a directory"
      CACHE_DIR="$2"
      shift 2
      ;;
    --macos-version)
      [[ $# -ge 2 ]] || die "--macos-version requires a version"
      MACOS_VERSION="$2"
      shift 2
      ;;
    --download-latest)
      die "downloads are disabled in this build; download the DMG yourself from $GRANOLA_DOWNLOAD_URL and pass its path"
      ;;
    --install-desktop)
      INSTALL_DESKTOP=1
      shift
      ;;
    --scheme-handler|--no-scheme-handler)
      DESKTOP_ARGS+=("$1")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$DMG_PATH" ]] || die "only one DMG may be supplied"
      DMG_PATH="$1"
      shift
      ;;
  esac
done

[[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
[[ -n "$DMG_PATH" ]] \
  || die "supply the official Granola DMG (download it yourself from $GRANOLA_DOWNLOAD_URL)"

for command_name in curl tar node pnpm python3 make sha256sum jq realpath file nproc install; do
  command -v "$command_name" >/dev/null || die "missing prerequisite: $command_name"
done
if ! node -e '
const [major, minor, patch] = process.versions.node.split(".").map(Number);
const atLeast = (wantedMinor, wantedPatch) =>
  minor > wantedMinor || (minor === wantedMinor && patch >= wantedPatch);
const supported =
  (major === 22 && atLeast(22, 2)) ||
  (major === 24 && atLeast(15, 0)) ||
  major >= 26;
process.exit(supported ? 0 : 1);
'; then
  die "Node.js 22.22.2+, 24.15.0+, or 26+ is required by the locked node-gyp"
fi

case "$(uname -m)" in
  x86_64|amd64) ELECTRON_ARCH="x64" ;;
  *) die "this release supports x86-64 Linux only" ;;
esac

CC_BIN=""
CXX_BIN=""
for compiler_version in 15 14 13 12 11; do
  if command -v "g++-$compiler_version" >/dev/null \
    && command -v "gcc-$compiler_version" >/dev/null; then
    CXX_BIN="g++-$compiler_version"
    CC_BIN="gcc-$compiler_version"
    break
  fi
done
if [[ -z "$CXX_BIN" ]] && command -v g++ >/dev/null && command -v gcc >/dev/null; then
  compiler_major="$(g++ -dumpversion | cut -d. -f1)"
  if [[ "$compiler_major" =~ ^[0-9]+$ ]] && (( compiler_major >= 11 )); then
    CXX_BIN="g++"
    CC_BIN="gcc"
  fi
fi
[[ -n "$CXX_BIN" ]] || die "GCC/G++ 11 or newer is required"

OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
CACHE_DIR="$(realpath -m "$CACHE_DIR")"
case "$OUTPUT_DIR" in
  /|"$HOME"|"$PROJECT_DIR") die "refusing unsafe output directory: $OUTPUT_DIR" ;;
esac
mkdir -p "$CACHE_DIR" "$(dirname "$OUTPUT_DIR")"

DMG_PATH="$(realpath -m "$DMG_PATH")"
[[ -f "$DMG_PATH" ]] || die "DMG not found: $DMG_PATH"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/granola-linux-macos.XXXXXXXX")"
ACTIVATION_DIR=""
cleanup() {
  rm -rf -- "$WORK_DIR"
  if [[ -n "$ACTIVATION_DIR" ]]; then
    rm -rf -- "$ACTIVATION_DIR"
  fi
}
trap cleanup EXIT

if [[ -n "${GRANOLA_7ZZ:-}" ]]; then
  SEVENZZ="$GRANOLA_7ZZ"
else
  SEVENZZ="$(command -v 7zz)" || die "7zz not found; install 7-Zip or set GRANOLA_7ZZ"
fi
[[ -x "$SEVENZZ" ]] || die "7zz is not executable: $SEVENZZ"

step "Inspecting the official DMG"
DMG_METADATA="$WORK_DIR/metadata"
mkdir -p "$DMG_METADATA"
"$SEVENZZ" e "$DMG_PATH" \
  'Granola/Granola.app/Contents/Info.plist' \
  -o"$DMG_METADATA/app" -y >/dev/null \
  || die "cannot read Granola's Info.plist"
"$SEVENZZ" e "$DMG_PATH" \
  'Granola/Granola.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist' \
  -o"$DMG_METADATA/electron" -y >/dev/null \
  || die "cannot read Granola's Electron metadata"

GRANOLA_VERSION="$(plist_string CFBundleShortVersionString "$DMG_METADATA/app/Info.plist")"
ELECTRON_VERSION="$(plist_string CFBundleVersion "$DMG_METADATA/electron/Info.plist")"
SDK_NAME="$(plist_string DTSDKName "$DMG_METADATA/app/Info.plist")"
[[ "$GRANOLA_VERSION" =~ ^[0-9]+([.][0-9]+)+$ ]] \
  || die "unexpected Granola version: ${GRANOLA_VERSION:-missing}"
[[ "$ELECTRON_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] \
  || die "unexpected Electron version: ${ELECTRON_VERSION:-missing}"
if [[ -z "$MACOS_VERSION" ]]; then
  MACOS_VERSION="${SDK_NAME#macosx}"
  [[ "$MACOS_VERSION" != "$SDK_NAME" && -n "$MACOS_VERSION" ]] \
    || MACOS_VERSION="15.5"
  [[ "$MACOS_VERSION" == *.*.* ]] || MACOS_VERSION="${MACOS_VERSION}.0"
fi
[[ "$MACOS_VERSION" =~ ^[0-9]{1,2}([.][0-9]{1,2}){1,2}$ ]] \
  || die "invalid macOS identity version: $MACOS_VERSION"

DMG_SHA256="$(sha256sum "$DMG_PATH" | cut -d' ' -f1)"
note "Granola $GRANOLA_VERSION"
note "Electron $ELECTRON_VERSION"
note "DMG SHA-256 $DMG_SHA256"
note "Renderer identity macOS $MACOS_VERSION"
note "Native runtime identity Linux"

ELECTRON_NAME="electron-v${ELECTRON_VERSION}-linux-${ELECTRON_ARCH}.zip"
ELECTRON_BASE_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}"
ELECTRON_ZIP="$CACHE_DIR/$ELECTRON_NAME"
ELECTRON_SUMS="$CACHE_DIR/electron-v${ELECTRON_VERSION}-SHASUMS256.txt"

step "Preparing the matching official Linux Electron runtime"
[[ -f "$ELECTRON_SUMS" ]] \
  || download_official "$ELECTRON_BASE_URL/SHASUMS256.txt" "$ELECTRON_SUMS"
[[ -f "$ELECTRON_ZIP" ]] \
  || download_official "$ELECTRON_BASE_URL/$ELECTRON_NAME" "$ELECTRON_ZIP"
expected_electron_hash="$(awk -v name="$ELECTRON_NAME" '$2 == "*" name {print $1}' "$ELECTRON_SUMS")"
[[ "$expected_electron_hash" =~ ^[0-9a-f]{64}$ ]] \
  || die "official Electron checksum entry not found for $ELECTRON_NAME"
actual_electron_hash="$(sha256sum "$ELECTRON_ZIP" | cut -d' ' -f1)"
[[ "$actual_electron_hash" == "$expected_electron_hash" ]] \
  || die "Electron checksum mismatch"
note "Electron SHA-256 verified"

STAGE_DIR="$WORK_DIR/stage"
APP_DIR="$STAGE_DIR/granola"
mkdir -p "$APP_DIR"
"$SEVENZZ" x "$ELECTRON_ZIP" -o"$APP_DIR" -y >/dev/null
chmod 0755 "$APP_DIR/electron"
rm -f "$APP_DIR/resources/default_app.asar"

step "Extracting Granola's application payload"
DMG_EXTRACT="$WORK_DIR/dmg"
RESOURCE_PATH='Granola/Granola.app/Contents/Resources'
"$SEVENZZ" x "$DMG_PATH" \
  "$RESOURCE_PATH/app.asar" \
  "$RESOURCE_PATH/app.asar.unpacked" \
  "$RESOURCE_PATH/icons" \
  -o"$DMG_EXTRACT" -y >/dev/null \
  || die "cannot extract Granola's application payload"
cp -a "$DMG_EXTRACT/$RESOURCE_PATH/app.asar" \
  "$DMG_EXTRACT/$RESOURCE_PATH/app.asar.unpacked" \
  "$DMG_EXTRACT/$RESOURCE_PATH/icons" \
  "$APP_DIR/resources/"
[[ -f "$APP_DIR/resources/icons/mac-icon.png" ]] \
  || die "Granola app icon was not found in the installer"
cp "$APP_DIR/resources/icons/mac-icon.png" "$APP_DIR/granola-app-icon.png"

step "Applying the split macOS/Linux identity patch"
PATCH_ARGS=(
  "$APP_DIR/resources/app.asar"
  --macos-version "$MACOS_VERSION"
)
python3 "$PROJECT_DIR/scripts/patch_asar.py" "${PATCH_ARGS[@]}"

step "Rebuilding Granola's encrypted SQLite module for Linux"
SQLITE_MODULE="$APP_DIR/resources/app.asar.unpacked/node_modules/better-sqlite3-multiple-ciphers"
[[ -f "$SQLITE_MODULE/package.json" ]] || die "Granola's SQLite module is missing"
SQLITE_VERSION="$(node -p "require('$SQLITE_MODULE/package.json').version")"
[[ "$SQLITE_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] \
  || die "unexpected SQLite module version: $SQLITE_VERSION"
SQLITE_INTEGRITY="$(jq -r --arg version "$SQLITE_VERSION" \
  '."better-sqlite3-multiple-ciphers"[$version] // empty' \
  "$PROJECT_DIR/locks/npm-sources.json")"
[[ -n "$SQLITE_INTEGRITY" ]] || die \
  "better-sqlite3-multiple-ciphers $SQLITE_VERSION is not reviewed in locks/npm-sources.json"

NPM_SOURCE_DIR="$CACHE_DIR/npm-sources"
mkdir -p "$NPM_SOURCE_DIR"
SQLITE_TARBALL="$NPM_SOURCE_DIR/better-sqlite3-multiple-ciphers-${SQLITE_VERSION}.tgz"
[[ -f "$SQLITE_TARBALL" ]] || download_official \
  "https://registry.npmjs.org/better-sqlite3-multiple-ciphers/-/better-sqlite3-multiple-ciphers-${SQLITE_VERSION}.tgz" \
  "$SQLITE_TARBALL"
python3 "$PROJECT_DIR/scripts/verify_sri.py" "$SQLITE_TARBALL" "$SQLITE_INTEGRITY"

STOCK_SOURCE="$WORK_DIR/sqlite-stock"
mkdir -p "$STOCK_SOURCE"
tar xzf "$SQLITE_TARBALL" -C "$STOCK_SOURCE" package/binding.gyp
cp "$STOCK_SOURCE/package/binding.gyp" "$SQLITE_MODULE/binding.gyp"

NODE_GYP_VERSION="$(jq -r '."node-gyp".version' "$PROJECT_DIR/locks/npm-sources.json")"
[[ "$NODE_GYP_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] \
  || die "invalid locked node-gyp version"
NODE_GYP_INTEGRITY="$(jq -r '."node-gyp".integrity // empty' \
  "$PROJECT_DIR/locks/npm-sources.json")"
[[ -n "$NODE_GYP_INTEGRITY" ]] || die "node-gyp integrity lock is missing"
NODE_GYP_TARBALL="$NPM_SOURCE_DIR/node-gyp-${NODE_GYP_VERSION}.tgz"
[[ -f "$NODE_GYP_TARBALL" ]] || download_official \
  "https://registry.npmjs.org/node-gyp/-/node-gyp-${NODE_GYP_VERSION}.tgz" \
  "$NODE_GYP_TARBALL"
python3 "$PROJECT_DIR/scripts/verify_sri.py" \
  "$NODE_GYP_TARBALL" "$NODE_GYP_INTEGRITY"

ELECTRON_HEADERS="$CACHE_DIR/node-v${ELECTRON_VERSION}-headers.tar.gz"
require_local_file "$ELECTRON_HEADERS" \
  "https://electronjs.org/headers/v${ELECTRON_VERSION}/node-v${ELECTRON_VERSION}-headers.tar.gz"

# node-gyp only reads the Electron headers' config.gypi (module version,
# V8 sandbox/pointer-compression defines) with --nodedir or --dist-url,
# not with --tarball. Unpack the headers and use --nodedir so the native
# module compiles against Electron's ABI instead of the host Node's.
ELECTRON_HEADERS_DIR="$CACHE_DIR/electron-headers-${ELECTRON_VERSION}"
if [[ ! -f "$ELECTRON_HEADERS_DIR/include/node/config.gypi" ]]; then
  rm -rf "$ELECTRON_HEADERS_DIR"
  mkdir -p "$ELECTRON_HEADERS_DIR"
  tar xzf "$ELECTRON_HEADERS" -C "$ELECTRON_HEADERS_DIR" --strip-components=1
  [[ -f "$ELECTRON_HEADERS_DIR/include/node/config.gypi" ]] \
    || die "Electron headers tarball has an unexpected layout"
fi

NATIVE_LOG="$WORK_DIR/native-build.log"
if ! (
  cd "$SQLITE_MODULE"
  CC="$CC_BIN" CXX="$CXX_BIN" \
    npm_config_store_dir="$CACHE_DIR/pnpm-store" \
    npm_config_cache_dir="$CACHE_DIR/pnpm-cache" \
    npm_config_ignore_scripts=true \
    pnpm --package="file:$NODE_GYP_TARBALL" dlx \
      node-gyp rebuild --release \
      --runtime=electron \
      --target="$ELECTRON_VERSION" \
      --arch="$ELECTRON_ARCH" \
      --nodedir="$ELECTRON_HEADERS_DIR" \
      --jobs="$(nproc)"
) >"$NATIVE_LOG" 2>&1; then
  tail -n 60 "$NATIVE_LOG" >&2
  die "native SQLite build failed"
fi
file "$SQLITE_MODULE/build/Release/better_sqlite3.node" | grep -q 'ELF 64-bit' \
  || die "rebuilt SQLite module is not a 64-bit Linux ELF library"
note "Native SQLite module rebuilt with node-gyp $NODE_GYP_VERSION and $CXX_BIN"

install -m 0755 "$PROJECT_DIR/scripts/run-granola" "$APP_DIR/run-granola"
install -m 0755 "$PROJECT_DIR/scripts/sandbox-xdg-open" "$APP_DIR/sandbox-xdg-open"

# project_dir lets the installed run-granola find granola.conf. It cannot live
# in the build directory, which this script replaces wholesale on every build.
# A containerized build sees a bind-mounted path, so docker-build.sh passes the
# host path that run-granola will actually resolve.
cat >"$APP_DIR/.granola-linux-macos-build" <<EOF
granola_version=$GRANOLA_VERSION
electron_version=$ELECTRON_VERSION
macos_identity=$MACOS_VERSION
dmg_sha256=$DMG_SHA256
project_dir=${GRANOLA_PROJECT_DIR:-$PROJECT_DIR}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

step "Smoke-testing the Linux native module"
SMOKE_DB="$WORK_DIR/granola-linux-macos-smoke.db"
ELECTRON_RUN_AS_NODE=1 \
NODE_PATH="$APP_DIR/resources/app.asar/node_modules" \
  "$APP_DIR/electron" -e "
const fs = require('node:fs');
const Database = require('$SQLITE_MODULE/lib/index.js');
const db = new Database('$SMOKE_DB');
db.pragma(\"cipher='sqlcipher'\");
db.pragma(\"key='granola-linux-macos-smoke-test'\");
db.exec('CREATE TABLE smoke(value INTEGER)');
let hookFired = false;
db.updateHook(() => { hookFired = true; });
db.prepare('INSERT INTO smoke VALUES (?)').run(42);
if (db.prepare('SELECT value FROM smoke').get().value !== 42) process.exit(2);
if (!hookFired) process.exit(3);
db.close();
const sqliteHeader = Buffer.from('SQLite format 3\\0');
if (fs.readFileSync('$SMOKE_DB').subarray(0, 16).equals(sqliteHeader)) process.exit(4);
const reopened = new Database('$SMOKE_DB');
reopened.pragma(\"cipher='sqlcipher'\");
reopened.pragma(\"key='granola-linux-macos-smoke-test'\");
if (reopened.prepare('SELECT value FROM smoke').get().value !== 42) process.exit(5);
reopened.close();
"
note "Encrypted SQLite and Granola's updateHook extension work"

step "Activating the completed build"
ACTIVATION_DIR="$(mktemp -d \
  "$(dirname "$OUTPUT_DIR")/.granola-linux-macos.activate.XXXXXXXX")"
STAGED_OUTPUT="$ACTIVATION_DIR/granola"
mv "$APP_DIR" "$STAGED_OUTPUT"

BACKUP_DIR=""
if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
  [[ -f "$OUTPUT_DIR/.granola-linux-macos-build" ]] \
    || die "refusing to replace unrecognized output directory: $OUTPUT_DIR"
  BACKUP_DIR="${OUTPUT_DIR}.previous-$(date -u +%Y%m%dT%H%M%SZ)"
  [[ ! -e "$BACKUP_DIR" && ! -L "$BACKUP_DIR" ]] \
    || die "backup path already exists: $BACKUP_DIR"
  mv "$OUTPUT_DIR" "$BACKUP_DIR"
  note "Previous build preserved at $BACKUP_DIR"
fi
if ! mv "$STAGED_OUTPUT" "$OUTPUT_DIR"; then
  if [[ -n "$BACKUP_DIR" && ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]]; then
    mv "$BACKUP_DIR" "$OUTPUT_DIR" \
      || die "activation failed and the previous build could not be restored"
  fi
  die "could not activate the completed build"
fi
rmdir "$ACTIVATION_DIR"
ACTIVATION_DIR=""

printf '\nBuilt Granola %s for Linux with macOS %s product identity.\n' \
  "$GRANOLA_VERSION" "$MACOS_VERSION"
printf 'Run: %s/run-granola\n' "$OUTPUT_DIR"
if [[ "$INSTALL_DESKTOP" -eq 1 ]]; then
  step "Installing desktop integration"
  "$PROJECT_DIR/desktop.sh" install ${DESKTOP_ARGS[@]+"${DESKTOP_ARGS[@]}"} \
    "$OUTPUT_DIR"
else
  printf 'Desktop integration: %s/desktop.sh install %s\n' \
    "$PROJECT_DIR" "$OUTPUT_DIR"
fi
