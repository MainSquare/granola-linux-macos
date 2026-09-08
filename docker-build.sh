#!/usr/bin/env bash
# Run build.sh inside the toolchain image, writing build/granola back to this
# checkout. Use this when the host lacks Node 22.22.2+ or 7-Zip, or when you
# would rather the build toolchain never touch the host at all.
#
# Desktop integration is deliberately not available here: it is a host action.
# Run ./desktop.sh install afterwards.

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${GRANOLA_BUILD_IMAGE:-granola-linux-macos-build}"
RUNTIME_IMAGE="${GRANOLA_IMAGE:-granola-linux-macos}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

DMG_PATH="${1:-}"
[[ -n "$DMG_PATH" ]] || die "usage: $0 /path/to/Granola.dmg [build.sh options]"
shift

DMG_PATH="$(realpath "$DMG_PATH")"
[[ -f "$DMG_PATH" ]] || die "DMG not found: $DMG_PATH"

for argument in "$@"; do
  [[ "$argument" != "--install-desktop" ]] \
    || die "--install-desktop is a host action; run ./desktop.sh install after the build"
done

command -v docker >/dev/null || die "docker is required"

docker build --target build -t "$IMAGE" "$PROJECT_DIR"
# The runtime image run-granola launches into. Cheap once the build
# stage is cached: they share the same base layer.
docker build --target runtime -t "$RUNTIME_IMAGE" "$PROJECT_DIR"

# Running as the invoking user keeps build/granola and .cache/ owned by the
# host user. That uid has no passwd entry in the image, so give pnpm a HOME.
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --env GRANOLA_PROJECT_DIR="$PROJECT_DIR" \
  --volume "$PROJECT_DIR:/src" \
  --volume "$DMG_PATH:/Granola.dmg:ro" \
  --workdir /src \
  "$IMAGE" \
  ./build.sh "$@" /Granola.dmg

printf '\nRun: %s/build/granola/run-granola\n' "$PROJECT_DIR"
printf 'Desktop integration: %s/desktop.sh install\n' "$PROJECT_DIR"
