# Two stages, two jobs.
#
#   --target runtime  the image Granola actually runs in (run-granola)
#   --target build    the build toolchain (docker-build.sh)
#
# The app is never baked into either image. docker-build.sh writes build/granola
# to the host, and run-granola bind-mounts it read-only, so rebuilding the app
# does not mean rebuilding an image.

# ---------------------------------------------------------------------------
# runtime: Electron's shared-library dependencies and nothing else.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      fonts-liberation \
      libasound2t64 \
      libatk-bridge2.0-0t64 \
      libcups2t64 \
      libegl1 \
      libgbm1 \
      libgl1-mesa-dri \
      libgtk-3-0t64 \
      libnss3 \
      libpulse0 \
      libxkbcommon0 \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# build: the same libraries plus the toolchain. They are needed here too,
# because build.sh smoke-tests the rebuilt SQLite addon by running the real
# electron binary with ELECTRON_RUN_AS_NODE=1, which still resolves its
# GTK/NSS DT_NEEDED entries at load time.
# ---------------------------------------------------------------------------
FROM runtime AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
      7zip \
      build-essential \
      curl \
      file \
      jq \
      make \
      python3 \
      xz-utils \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install --global --no-fund --no-audit pnpm \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu's 7zip package installs the same 7-Zip 23.01 CLI as 7z, not 7zz.
ENV GRANOLA_7ZZ=/usr/bin/7z

WORKDIR /src
