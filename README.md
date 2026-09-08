# Granola for Linux with a macOS identity

An unofficial, source-only compatibility builder for running Granola's desktop
client on x86-64 Linux. It uses your own official Granola installer and account;
this repository does not contain or redistribute Granola.

Granola does not currently publish a Linux desktop client. Its
[official setup documentation](https://docs.granola.ai/help-center/getting-started/setting-up-granola-for-the-first-time)
lists macOS, Windows, and iPhone. This project is experimental, unaffiliated
with Granola, and can stop working whenever Granola changes its desktop bundle.

## What it does

The builder combines Granola's application payload with the exact matching
official Linux Electron runtime, then rebuilds Granola's encrypted SQLite addon
for Linux.

The identity patch is deliberately split:

| Layer | Identity | Reason |
| --- | --- | --- |
| Renderer and Granola backend metadata | macOS / `darwin` | Gives Granola the requested product identity |
| Electron, Node native modules, and audio selection | Linux | Keeps Linux libraries, PipeWire/PulseAudio capture, and ELF modules working |

A global `process.platform = "darwin"` spoof is intentionally not used. That
would make Granola select CoreAudio, EventKit, Keychain, and other Mach-O-only
components that cannot run on Linux.

## Current status

Originally tested on Pop!_OS 24.04 with COSMIC/Wayland using Granola 7.469.1.
The containerized runtime was verified on Ubuntu 24.04 with GNOME/Wayland using
Granola 7.488.3 and Electron 42.7.0.

| Capability | Status |
| --- | --- |
| App startup and login UI | Verified |
| Encrypted local SQLite storage | Verified, including Granola's custom update hook |
| Container sandbox | Verified: tmpfs home, app mounted read-only, GPU working, container removed when the window closes |
| Google login callback | Verified: `run-granola 'granola://…'` reaches an already-running instance through its single-instance lock. `GRANOLA_SCHEME_HANDLER=1` lets the browser do that for you; with it off, paste the callback by hand |
| Microphone capture | Verified through the container: live transcription from a USB microphone, `microphoneCapture: active`, no capture errors |
| System/meeting audio | Verified through the container: Granola's all-output-devices loopback path reaches the host's PulseAudio monitor sources, `systemCapture: active`. Tested in a call with one participant; a busy multi-party meeting is still worth a disposable trial |
| Tray icon and notifications | Unavailable; no session D-Bus socket is passed into the sandbox |
| Global shortcuts | Limited on Wayland; Granola's bundle does not ship the Linux X11 key server |
| Google Meet consent helper | Unavailable; the official helper in the macOS installer is Mach-O-only |
| Self-update | Unavailable; rebuild from a new official DMG instead |

Do a disposable test meeting before relying on this for an important call.
Granola's web app can view and edit notes, but
[transcription is performed by the desktop client](https://docs.granola.ai/help-center/taking-notes/transcription).

## Requirements

To **run** the app you need x86-64 Linux, your own Granola account, and Docker.
The Electron runtime libraries live in the container, not on your host. Add
`pactl` only if you turn Bluetooth HFP switching on.

```bash
sudo apt install pulseaudio-utils   # only for GRANOLA_BLUETOOTH_HFP=1
```

To **build** it without Docker you additionally need Node.js `22.22.2+`, `24.15.0+`, or `26+`,
7-Zip's `7zz` (or `GRANOLA_7ZZ`), pnpm, Python 3, curl, jq, tar, xz, make,
`file`, and GCC/G++ 11 or newer. If your distribution's Node.js is too old, or
you would rather the build toolchain never touch your system, use the Docker
path below instead — then Docker is the only build requirement.

```bash
sudo apt install 7zip build-essential curl file jq make npm python3 xz-utils
export GRANOLA_7ZZ=/usr/bin/7z   # Ubuntu's 7zip package installs 7z, not 7zz
```

## Build and install

Download the official DMG yourself from
<https://api.granola.ai/v1/download-latest>, then either build in Docker:

```bash
./docker-build.sh /path/to/Granola.dmg
```

or build directly on the host:

```bash
./build.sh /path/to/Granola.dmg
```

Both produce the runnable app at `build/granola`. Then install the launcher —
this is a host action, so it is never done inside the container:

```bash
./desktop.sh install
```

Start it from your application launcher or run `./build/granola/run-granola`.
The launcher is displayed simply as **Granola**; the compatibility details
remain in the entry's description and build metadata.

## Configuration

Three choices live in `granola.conf` at the root of this checkout (gitignored;
copy `granola.conf.example` to start). Each key is `0` or `1`, and the
environment overrides the file, so a one-off run can always say
`GRANOLA_AUDIO=0 ./build/granola/run-granola`.

| Key | Default | Effect |
| --- | --- | --- |
| `GRANOLA_AUDIO` | `1` | Binds the host PipeWire and PulseAudio sockets into the sandbox. Off means no audio device reaches Granola at all. |
| `GRANOLA_BLUETOOTH_HFP` | `0` | Lets Granola switch a Bluetooth headset to HSP/HFP so its microphone works. Off means no `pactl` call is ever made. |
| `GRANOLA_SCHEME_HANDLER` | `0` | Registers `granola://` on this host when installing the desktop entry. |

An unset key is asked about on the first run from a terminal, and the answer is
written back to `granola.conf` so you are only asked once. A launcher started
from your desktop has no terminal to ask on, which is why `desktop.sh` bakes the
audio choices into the entry's `Exec=` line — re-run `./desktop.sh install`
after changing them. `desktop.sh` refuses to guess about `granola://` on a
non-interactive run; pass `--scheme-handler` or `--no-scheme-handler`.

## The sandbox

`run-granola` starts Electron in a container. The home directory inside is a
tmpfs with only `~/.config/Granola` mounted through it, the built app is mounted
read-only at `/opt/granola`, there is no session D-Bus, and `--rm` means the
container disappears when you close the window.

The app is **not** baked into an image. Rebuilding the app never means
rebuilding an image, and `docker-build.sh` produces both images for you.

### Why a container rather than bwrap

`bubblewrap` would give a tighter, daemon-free sandbox, and it is the natural
choice on paper. It does not work here. This host sets
`kernel.apparmor_restrict_unprivileged_userns=1`, so an unconfined process that
creates a user namespace transitions into the `unprivileged_userns` AppArmor
profile, whose denied capabilities make bwrap fail at startup with:

```
bwrap: setting up uid map: Permission denied
```

Docker's daemon runs as root, so it never needs an *unprivileged* user
namespace. Fixing bwrap instead would mean a root policy change — an AppArmor
profile granting `userns` to `/usr/bin/bwrap`, or disabling the sysctl
host-wide.

The same restriction means Chromium cannot build its own namespace sandbox
inside the container, so **`--no-sandbox` is passed deliberately**. A renderer
compromise reaches the rest of the container — which holds your Granola profile
and the Wayland socket — but not the host. The alternative, `--cap-add
SYS_ADMIN` with a setuid `chrome-sandbox`, trades the outer boundary for the
inner one; keeping the boundary that protects the host is the better trade.

What this buys is isolation from the rest of your home directory and an on/off
switch for audio. It is not a hard boundary against the application: the Wayland
socket and the network still go in. Withholding the session bus is part of
keeping that claim honest, and it costs you the tray icon and notifications.

## Signing in

With `GRANOLA_SCHEME_HANDLER=1`, browser sign-in completes on its own.

With it off — the default — nothing on your host claims `granola://`, so the
callback is delivered by hand once per login. Click sign in; the sandbox has no
browser, so Granola's `xdg-open` call is relayed to your host browser (only
`https://` URLs are forwarded — see [SECURITY.md](SECURITY.md)). Complete the
flow; the redirect to `granola://…` will fail to open an app. In Firefox the
"open with application" dialog shows the full URL, so copy it and run
`./build/granola/run-granola 'granola://…'`. That is verified to reach a
running instance; the callback path Granola accepts is `login-complete`.

## Audio on Linux

Granola already contains a browser audio implementation for Linux. The patcher
preserves that branch even while the renderer-facing identity says macOS.

### How audio reaches the container

Two host sockets are mounted when `GRANOLA_AUDIO=1`: PipeWire's `pipewire-0`,
and PulseAudio's native socket. The Pulse socket is mounted **flat** as
`pulse-native` inside the container's runtime directory and addressed through
`PULSE_SERVER`, not at the host's `pulse/native` path. Mounting into a
subdirectory makes Docker create that subdirectory as root, and libpulse
refuses a runtime directory it does not own:

```
XDG_RUNTIME_DIR (/run/user/1000) is not owned by us (uid 1000), but by uid 0!
Connection failure: Connection refused
```

That failure is quiet in the worst way — Granola's transcription sessions still
report `active` while both capture states go to `error`, so it looks like
transcription is running with nothing feeding it. The runtime image also needs
`libpulse0`: Chromium `dlopen`s it and otherwise falls back silently to ALSA,
which has no devices in the container.

**System audio does not need the desktop portal.** The obvious assumption is
that `getDisplayMedia` requires xdg-desktop-portal over the session D-Bus,
which this deliberately does not pass in. It does not: Electron's
`loopbackAllDevices` handler reaches the host's PulseAudio monitor sources
directly, so system capture works with no portal and no session bus.

The current Granola bundle contains a Linux-specific Electron handler named
`loopbackAllDevices`. The patcher verifies and preserves its original audio-only
permission and capture requests. It does not add a display/video track: doing so
would conflict with Granola's audio-only handler and cause Chromium to reject the
request.

The builder also replaces one macOS-only microphone permission probe in
Granola's Linux browser-audio manager. Actual microphone access still goes
through Chromium's `getUserMedia` and the host's audio server; the patch only
prevents the onboarding screen from treating Electron's unavailable Apple TCC
API as a Linux denial. That probe is reached in the container too: the log line
`check-tcc-system-audio-permission {"audioCapture":"authorized"}` is the patched
bridge answering.

### Bluetooth headsets — opt-in

Classic Bluetooth exposes a microphone through HSP/HFP, not the A2DP stereo
playback profile, and HFP has lower playback quality because Bluetooth must
carry the mic and speaker in both directions. Switching profiles after Chromium
has begun capture can also invalidate Granola's first audio tracks.

`GRANOLA_BLUETOOTH_HFP=1` manages that: when the selected default input is a
Bluetooth headset, `run-granola` selects the headset's HFP profile before
Electron starts and keeps it selected while Granola is running. It does not fall
back to the laptop microphone. On a normal exit, the launcher restores the
headset's previous profile, so closing Granola restores stereo playback.

This is **off by default**, because the quality tradeoff is real and profile
switching disturbs headsets that some setups would rather leave alone. With it
off, `run-granola` makes no `pactl` call of any kind and your headset profile is
never touched — but a Bluetooth microphone will not be usable for capture.

The project never adds `--no-sandbox` to the launcher.

[Electron display-media documentation](https://www.electronjs.org/docs/latest/api/session#sessetdisplaymediarequesthandlerhandler-opts)

## Updating and uninstalling

Update the builder and installed app with:

```bash
git pull --ff-only
./docker-build.sh /path/to/Granola.dmg   # or ./build.sh /path/to/Granola.dmg
./desktop.sh install
```

A completed build is staged on the destination filesystem before it is activated.
A recognized existing build is preserved next to the new one as
`granola.previous-<timestamp>` so an upstream breakage does not destroy the last
working copy.

Remove only the desktop integration with:

```bash
./desktop.sh uninstall
```

This does not delete generated builds or Granola's user data. Granola stores its
profile under `~/.config/Granola`; treat that directory as sensitive because it
can contain account and meeting metadata.

## Verification and failure behavior

The builder:

- downloads Granola only from Granola's official HTTPS endpoint;
- refuses redirects from HTTPS downloads to non-HTTPS protocols;
- records the DMG SHA-256 in the local build metadata;
- downloads the exact Electron version named by the installer and verifies it
  against Electron's official `SHASUMS256.txt`;
- verifies the pinned 7-Zip archive with SHA-256;
- verifies reviewed npm source tarballs with locked SHA-512 SRI values;
- performs only same-size ASAR patches and recalculates Electron's per-file ASAR
  integrity hashes;
- refuses to build if expected upstream code markers are missing or duplicated;
- compiles the native database addon and tests encryption, reopen, read/write,
  and the custom update hook before staging and replacing a working build;
- validates a new desktop entry before replacing the installed launcher.

The DMG itself is trusted through Granola's HTTPS download; this Linux workflow
does not validate Apple's code-signing chain. See [SECURITY.md](SECURITY.md) for
the full trust model.

## Legal and project scope

The MIT license in this repository covers only these scripts and documentation.
It does not cover Granola, Electron, generated application bundles, icons, or
third-party native modules. Do not upload or redistribute the generated build.
This tool does not bypass Granola login, subscriptions, or service-side access
controls. Review Granola's terms before use.

Thanks to the independent
[Granola-for-Linux](https://github.com/tirtha4/Granola-for-Linux) experiment for
demonstrating community interest in a Linux compatibility path. This project
uses a separate fail-closed patcher and split macOS/Linux identity design.
