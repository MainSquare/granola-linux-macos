# Security policy

## Reporting a problem

Please use GitHub's private security-advisory feature for vulnerabilities in
this builder. Ordinary compatibility failures can use a public issue after
removing account data, meeting content, tokens, cookies, and local paths from
logs.

Vulnerabilities in Granola itself should be reported to Granola through its
official security channel, not published in this repository.

## Trust model

This project is a local repackaging tool. It necessarily executes code from:

- the Granola DMG fetched from Granola's official HTTPS endpoint or supplied by
  the user;
- the exact Linux Electron release identified by that DMG;
- the reviewed npm source packages listed in `locks/npm-sources.json`;
- the host compiler, Node.js, npm, Python, shell, and system libraries.

Electron releases are checked against Electron's official SHA-256 list. The
7-Zip download is pinned by SHA-256, and the reviewed npm package sources are
checked by SHA-512 SRI. The Granola DMG hash is recorded for auditability, but
there is no pinned expected DMG hash because Granola's latest-download endpoint
changes over time. The builder does not validate Apple's code-signing chain.
All builder-managed downloads and redirects are restricted to HTTPS. When the
bundled 7-Zip fallback is needed, its executable is freshly extracted from the
verified archive for each build rather than trusted from a previous cache.

npm may resolve transitive dependencies of the locked `node-gyp` package on a
first build. npm's registry integrity checks still apply, but those transitive
versions are not fully vendored or reproducibly locked by this project.

## Fail-closed patching

The ASAR patcher requires exact, unique source markers and same-size
replacements. It updates the affected ASAR integrity fields and aborts if the
archive layout, marker count, native Linux branch, or integrity format differs
from what was reviewed. A failed build does not replace a recognized working
output directory. A successful build is copied to a staging directory on the
destination filesystem before the previous build is moved and the staged build
is atomically activated.

## Runtime sandbox

`run-granola` starts Electron in a container. The home directory inside is a
tmpfs with only `~/.config/Granola` mounted through it, the built app is mounted
read-only at `/opt/granola`, no session D-Bus socket is passed in, and `--rm`
removes the container when the window closes.

**Chromium's own sandbox is disabled (`--no-sandbox`), deliberately.** This host
sets `kernel.apparmor_restrict_unprivileged_userns=1`, and a container's payload
cannot create the nested user namespace Chromium's namespace sandbox needs —
verified against the default profile and with `seccomp=unconfined`,
`apparmor=unconfined`, and both. The two working configurations are:

- `--no-sandbox`, keeping Docker's boundary around the host. A renderer
  compromise reaches the rest of the container — which holds your Granola
  profile and the Wayland socket — but not the host.
- `--cap-add SYS_ADMIN` with a setuid `chrome-sandbox`, which restores
  Chromium's inner sandbox but broadly weakens the container boundary itself.

Keeping the boundary that protects the host is the better trade, so the first is
the default. `bubblewrap` was evaluated and does not work on this host: an
unconfined process creating a user namespace transitions into the
`unprivileged_userns` AppArmor profile and bwrap fails with `setting up uid map:
Permission denied`. Making it work needs a root policy change.

Be clear-eyed about the boundary. The Wayland socket, the network, and
optionally the PipeWire and PulseAudio sockets are passed in. This isolates
Granola from the rest of your home directory and gives you an on/off switch for
audio; it is not a hard boundary against the application itself.

`GRANOLA_AUDIO=0` passes no audio device into the sandbox at all.
`GRANOLA_BLUETOOTH_HFP=0`, the default, additionally guarantees that no `pactl`
call is ever made, so a Bluetooth headset's profile is never touched.

### The `xdg-open` relay

Granola shells out to `xdg-open` for browser sign-in, and the container has no
usable browser profile. `scripts/sandbox-xdg-open` is mounted over
`/usr/bin/xdg-open` inside the container and only prints the URL; `run-granola`
reads that marker on the host side.

**Only `https://` URLs are forwarded to the host's real `xdg-open`.** This is a
container-to-host channel, and handing the host's `xdg-open` an arbitrary string —
a `file://` path, a `.desktop` file — is how it would become arbitrary execution
on the host. Do not relax that filter.

## `granola://` scheme registration

`desktop.sh install` requires an explicit `--scheme-handler` or
`--no-scheme-handler` (or the corresponding `granola.conf` value) and refuses to
guess on a non-interactive run. Registering the scheme makes this host answer
`granola://` URLs from any application that can open a URL; declining means the
login callback is delivered by hand, once per login.

## Sensitive local state

Generated builds, downloads, DMGs, ASAR files, compiler logs, and caches are
ignored by Git. Granola's runtime profile is outside this repository, normally
at `~/.config/Granola`. It can contain credentials and meeting metadata. Never
attach that directory to an issue or commit it.

The public repository must contain only source tooling. Generated Granola
bundles are proprietary and must not be committed or attached to releases.
