# Secure OpenCode

Runs [opencode](https://opencode.ai) inside a Docker sandbox instead of directly on the host, while still behaving like a normal `opencode` install: same config, same sessions, same git identity, same shell workflow. Opencode's home directories are bind-mounted whole, so everything opencode persists — sessions, CLI settings, plugins, provider credentials — survives container restarts, exactly as if opencode were installed locally. It works standalone, with no native OpenCode install required.

Everything else on the host is **not** in the container (see [Credentials](#credentials)): no shell environment, no other dotfiles, no other CLI configs. What is in there is explicitly opencode's own data — the four directories above, a filtered git identity, the host's CA bundle, and the plugins your configs reference. This is built with a **local model provider** (LM Studio, Ollama, a local proxy) in mind, which typically needs no credentials at all; for those what matters is network reachability: `--add-host=host.docker.internal:host-gateway` is always added (see [How it works](#how-it-works) and [Local providers](#local-providers) for the config change this requires).

## Why

**opencode can read and write anywhere it can reach, and run arbitrary shell commands**. A container puts a hard wall around that: only the project directory, opencode's own four directories, a git identity with its credential helpers stripped out, and the host's CA bundle are visible inside. **Everything else — `~/.aws`, `~/.ssh`, other cloud CLI configs, your shell environment — simply isn't there.** Tokens for services like `gh` or AWS only get in if you explicitly export and pass them through.

It doesn't take malice for that to matter, just a wrong command, or a manipulated one:

- A prompt-injection payload hidden in a dependency, README, or fetched file tells the agent to grab `gh auth token` and slip it into a PR description. On the host, that hands over your GitHub session. In the container, `gh` isn't authenticated, so there's nothing to steal.
- Debugging a failing deploy, opencode runs `aws sts get-caller-identity` and pastes the output into a log or commit to explain what's wrong. On the host, that can leak live AWS keys. In the container, `~/.aws` was never mounted, so there's nothing to leak.

The one deliberate exception is opencode's own directories: a sandbox that behaves like a local install needs its sessions, settings, and provider credentials, so they ride along inside the wall — see [Credentials](#credentials) for the trade-off.

Each run is also disposable and reproducible: `--rm` plus a pinned toolchain (`src/container/Dockerfile.opencode`) means stray global installs never accumulate on the host or drift between machines. `opencode` itself is compiled from the official upstream source at the latest stable release of a pinned major version line (currently v2), independently of whatever's installed on the host (see [How it works](#how-it-works)).

## Requirements

- macOS or Linux
- `bash`
- `jq`
- [Docker](https://docs.docker.com/get-docker/)

### Optional

- opencode installed natively (`opencode` available in `PATH`) is **optional**: the sandboxed `opencode` is compiled from upstream source inside Docker (see [How it works](#how-it-works)) and needs no native install to run. A native install is only used, if found, to set up the `opencode-original` escape hatch (see [Install](#install) and [Usage](#usage)).

## Install

```bash
./install.sh
```

This will:

1. Check the OS and that Docker is available (warns, doesn't block, if Docker is missing).
2. Locate the native `opencode` binary via `PATH`, if there is one.
3. Create `~/.secure-opencode/bin/`, containing an `opencode` symlink to `src/opencode.sh` and, only if a native binary was found in step 2, an `opencode-original` symlink to it.
4. Prepend `~/.secure-opencode/bin` to `PATH` in your shell startup files (whichever of `.zshrc`, `.bashrc`, `.bash_profile`, `.profile` already exist; if none exist, the one matching your `$SHELL` is created — `.zshrc` for zsh, `.bash_profile` for bash, `.profile` otherwise), so it resolves before the native install.
5. Build the `opencode-sandbox` Docker image from `src/container/Dockerfile.opencode`, compiling `opencode` from the latest stable release of the pinned major line (currently v2) — see [How it works](#how-it-works) for what "latest stable" means and how the image is kept current afterwards.

No native `opencode` install is required: if step 2 doesn't find one, the script warns and just skips `opencode-original` — the sandboxed `opencode` from step 5 works regardless, since it's built entirely from upstream source inside Docker. Install `opencode` natively and re-run `./install.sh` at any later point to add the `opencode-original` shim.

**Note**. The native install itself is never touched. The symlink/PATH setup (steps 2-4) is idempotent and skipped when already installed, but the image build in step 5 always runs from scratch. That makes re-running `./install.sh` the supported way to pick up an edit to `Dockerfile.opencode`: `opencode.sh` on its own only rebuilds when a newer stable upstream release is out, not on a local Dockerfile edit (see [How it works](#how-it-works)). If the rebuild on a re-run fails (e.g. you're offline), the script warns and keeps the existing image rather than failing; a fresh install without a working build exits with an error, since there is no image to fall back to. The script refuses to proceed if it finds a state it can't safely resolve on its own (e.g. an `opencode`/`opencode-original` in the shim directory that isn't a symlink it manages), explaining what to check.

## Usage

Once installed (and after starting a new shell, so the updated `PATH` takes effect), use `opencode` exactly as before:

```bash
opencode
```

It now runs sandboxed in Docker, with the project directory, opencode's four home directories, and your git identity mounted in. Because those four directories are live mounts of the host's, everything a native install would persist persists here too: a container restart loses nothing, and a native `opencode` run afterwards picks up the sessions, settings, and plugins the sandbox worked on. The TUI shows a "sandbox" banner (a small plugin baked into the image and declared by the container entrypoint through the container-only `OPENCODE_CONFIG_CONTENT`, never written into your config directory) so you always know which one you're in — `opencode-original` never shows it.

**Upgrading from an earlier version.** If `~/.config/opencode/plugins/sandbox-banner` exists (along with the `~/.config/opencode/plugins/.sandbox-banner` marker), an older entrypoint installed it into your host config: delete both, otherwise a native run keeps showing the sandbox banner and the sandbox shows it twice.

If a native `opencode` was found at install time, `opencode-original` is also available to invoke the original, natively installed and **unconstrained** binary directly:

```bash
opencode-original
```

## Restore

```bash
./restore.sh
```

Removes `~/.secure-opencode/bin` (the `opencode` and `opencode-original` symlinks) and the `PATH` entry added to your shell startup files. The native install was never modified, so `opencode` resolves to it again as soon as you start a new shell.

## How it works

- `src/opencode.sh` is a wrapper that mounts the current project directory, opencode's four home directories, and your git identity into the container, and runs the real `opencode` binary inside it. The container runs with `HOME=/home/node`; the four mounts target the default paths opencode resolves there, while the *source* paths honor `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME`, so a host that moves those directories still gets its own mounted. The four directories, each mounted whole rather than split into per-file mounts:
  - **config** (`~/.config/opencode`): `opencode.json`/`opencode.jsonc` (provider configuration, and the primary place plugins are declared), `cli.json` (v2's CLI/TUI settings: theme, keybinds, the plugin list recorded by `opencode plugin add`), the background-service config (`service.json`: hostname, port, password), and the user-content directories (`agents/`, `commands/`, `modes/`, `plugins/`, `skills/`, `themes/`).
  - **data** (`~/.local/share/opencode`): the session database (`opencode.db*`) and logs. In v2, provider credentials live inside the database, so they come along with the sessions — see [Credentials](#credentials).
  - **state** (`~/.local/state/opencode`): the background-service registration (`service.json`, or `service-<channel>.json` for other channels, plus their `.tmp` and `.pty-handoff` sidecars) and the file locks. These are per-machine coordination state, and the container's entrypoint deletes them on startup and again on exit (see below), so the sandbox never adopts the host's service; everything else in the directory simply persists.
  - **cache** (`~/.cache/opencode`): where opencode installs npm-package plugins. Shared both ways: a package the sandbox installed is ready for the host's next run, and vice versa.
  
  Whole-directory mounts are what let the sandbox behave like a local install, including CLI settings saved through `rename()` on `cli.json` — which fails when the target is a bare bind-mounted file. The single in-directory overlay is the global `opencode.json`/`opencode.jsonc`, mounted read-only on top of the config mount: they declare the provider configuration and which plugins run, so a sandboxed process cannot rewrite them in place (`:ro`) or replace them (a bind-mounted file is a mount point that `rename()` refuses), while host-side edits are picked up on the next launch — the overlay is the same host file, and same-host-source overlays are allowed on Docker Desktop's virtiofs backend (only a *different* host source over an already-mounted path is not).
- One v2 source stays outside the wall: opencode also reads Claude-Code-compatible skills from the home-level `~/.claude/skills` and `~/.agents/skills` directories, and resolves the config's `skills` path list from the project directory (or from its own home for `~/` entries). The container's home (`/home/node`) contains only the four mounted directories and the project, so skills in those home-level locations — or at absolute paths outside the mounts — are simply not visible in the sandbox. If you keep skills there, store them under `~/.config/opencode/skills/` or the project's `.opencode/skills/` instead; both are mounted, and both are scanned.
- The background service is **private to each sandbox run**. In v2, opencode commands talk to one long-lived background service per machine: a running service registers itself in the state directory (id, version, url, pid, password, in a `0600` file written via temp-then-rename) and re-reads that file every 5 seconds, shutting itself down the moment its contents no longer match its own registration; on a clean stop it removes the file, but only if it still owns it. Because the state directory is a live mount of the host's, the container's entrypoint (`src/container/entrypoint.sh`) first deletes the registration files and locks left by a native run: the sandboxed opencode then finds no live service and starts its own private one, and the host's running service notices, through the same mount, within a few seconds that its registration is gone and exits. The entrypoint deletes the registration again when the sandbox exits, so a native run afterwards starts a fresh host service instead of trying to reach a dead container one. The service *config* (in the config directory) is deliberately kept: the container reuses the host's password when one exists, and a freshly generated one persists through the mount.
  - If the container is `kill -9`'d (or the host crashes) there is no exit cleanup, and a stale registration pointing at a dead pid survives. The next native run notices the registered service is unreachable, starts a new one, and overwrites the stale file — self-healing, no action needed.
  - A native `opencode` client running *at the same time* as a sandbox shares that one registration file with it: each service exits the moment the other rewrites the registration. That usually converges on one owner, but both sides can see a connection interruption while it does — avoid running a native client and a sandbox concurrently.
  - Version skew: the session database is schema-versioned, and the container runs the opencode version the image was built from. If a newer host opencode has migrated the database past what the container's build understands, the container can fail to open it. Rebuild the image (re-run `./install.sh`, or let the wrapper's next launch rebuild once a newer stable release exists).
- Plugin entries pointing at absolute host paths (npm package names and paths relative to the config file are resolved by opencode itself inside the container) are found and mounted into it read-only at the same path, so a plugin that exists on the host is reachable in the sandbox without being copied. The wrapper scans the `plugin`/`plugins` entries of the global and project `opencode.json`/`opencode.jsonc` (v2 decodes the legacy `plugin` key as well), the v2 `cli.json` settings file, and the file pointed to by `OPENCODE_CONFIG` when set, so any of these can declare a plugin path. JSONC (comments, trailing commas) is accepted, and a file that cannot be parsed is reported with a warning rather than aborting the launch; the same path declared in several files is mounted once. Paths under the project directory or any of the four mounted directories need no extra mount (they already ride along inside those mounts); a plugin entry that cannot be located on the host is reported as missing on the wrapper's manifest output rather than mounted.
- `OPENCODE_CONFIG`, when set, is forwarded into the container with `-e`, so the sandboxed opencode reads exactly the config file the host invocation would; the file itself is mounted read-only, and any plugin paths inside it are handled as in the previous point.
- `--add-host=host.docker.internal:host-gateway` is always added, so a provider pointed at a local server on the host (LM Studio, Ollama, a local proxy) stays reachable from inside the container — but only if your `opencode.json` addresses it via the `{env:OPENCODE_LMSTUDIO_BASEURL}` substitution rather than a hardcoded `localhost`/`127.0.0.1` (see [Local providers](#local-providers)).
- The host's CA bundle is mounted into the image (which ships without one) so HTTPS verification works and corporate TLS proxies are honored.
- The "you are in a sandbox" banner — the difference between a sandboxed session and `opencode-original` at a glance — is a plugin baked into the image at `/opt/sandbox-banner` and declared by the entrypoint through `OPENCODE_CONFIG_CONTENT`, a config document opencode loads on top of the others whose `plugins` list is unioned with the host's, never substituted for it. Nothing is written into the mounted config directory, so a native `opencode` never picks the banner up; a `OPENCODE_CONFIG_CONTENT` passed with `docker run -e` is kept, with the banner appended to its plugin list.
- The Docker image `opencode-sandbox:current` is built by `install.sh` from `src/container/Dockerfile.opencode`, a multi-stage build that compiles the real `opencode` binary from the official upstream source using the same build script and toolchain the upstream release uses — only the resulting single binary, the container entrypoint, and the sandbox banner plugin end up in a minimal `node:24-slim` image. At launch, `opencode.sh` checks `github.com/anomalyco/opencode` for the latest stable tag of the major version line pinned in `src/lib/install-common.sh` (`OPENCODE_MAJOR`, currently `2`, i.e. `v2.*` tags, pre-release/CI tags ignored). If that's already what the image was last built from, it's reused as-is; if a newer stable release is out, the `builder` stage clones that tag and compiles it from source. If the tag can't be resolved (offline) or the rebuild fails, the run continues on the last successful local build with a warning; if there is no previous build to fall back to, `opencode.sh` stops rather than run nothing. A stable release of the *next* major version (e.g. `v3.x`) only prints a notice — it's never built automatically, since that'd be a deliberate upgrade decision, not an automatic one.
- `install.sh` and `restore.sh` only set up the `~/.secure-opencode/bin` shim directory and the `PATH` entry in your shell startup files; they never touch a native opencode install, and `restore.sh` returns `opencode` to the native binary.

### Credentials

The wall keeps out everything that is not opencode's own: no provider API-key environment variables are forwarded into the container — the wrapper passes only a minimal, explicit set (the container's `HOME`, the local-provider base URL, the host timezone, and `OPENCODE_CONFIG` when set), never your shell's — and the git identity is a *filtered* copy of `~/.gitconfig` with its `[credential]` section removed, so a git push from the sandbox cannot use your stored git credentials or credential helper.

What is inside, though, is opencode's own storage — and in v2 the provider credentials (the ones `opencode auth login` stores) live in the session database, in the data directory, alongside the sessions and logs. So a sandboxed opencode can see the same provider credentials a native run has. That is the deliberate price of the "as if installed locally" model: sessions, CLI settings, and plugins only persist if their storage does, and in v2 the credentials share that storage. The exposure is the same as a compromised *native* opencode (e.g. a prompt injection exfiltrating stored provider keys), with everything else on the host still out of reach. If you do not want the sandbox to hold real provider credentials, `opencode auth logout` natively first, or run a local provider that needs none (see [Local providers](#local-providers)). To pass an explicit key in anyway, add your own `-e VAR` to the `docker run` invocation in `src/opencode.sh`; the wrapper forwards no credentials by design.

### Local providers

This setup is built with a local model provider in mind: LM Studio, Ollama, or any other server running on the host that needs no account. The `opencode.json`/`opencode.jsonc` config is the same file used both natively and inside the sandbox (it's bind-mounted, see [How it works](#how-it-works)), so a provider's `baseURL` can't be hardcoded to either `localhost` (breaks in the container) or `host.docker.internal` (breaks natively where the name isn't defined) without breaking the other. Use opencode's `{env:VAR}` config substitution instead, so the same file resolves differently in each context:

```jsonc
{
  "providers": {
    "lmstudio": {
      "settings": {
        "baseURL": "{env:OPENCODE_LMSTUDIO_BASEURL}"
      }
    }
  }
}
```

(the v1-style `"provider"`/`"options"` keys are still decoded as well, with their options mapped into `settings`.)

`src/opencode.sh` always sets `OPENCODE_LMSTUDIO_BASEURL` to `http://host.docker.internal:$SECURE_OPENCODE_LMSTUDIO_PORT/v1` (port defaults to `1234`, LM Studio's default, overridable via the `SECURE_OPENCODE_LMSTUDIO_PORT` environment variable). For native use, nothing extra is needed when your LM Studio listens on the default endpoint: in v2 an unset variable substitutes to an empty string, which opencode treats as no override, so the provider falls back to its built-in default (`http://127.0.0.1:1234/v1`). If it listens elsewhere, export the same variable in your shell profile pointing there (e.g. `http://127.0.0.1:1235/v1`) so a native run reaches it.

**Known limitation**: `--add-host=host.docker.internal:host-gateway` (or its absence) does not scope down *which* host ports are reachable — it's only needed at all on Linux, where this hostname isn't resolved by default. On Docker Desktop (macOS/Windows), `host.docker.internal` is reachable from any container regardless of this flag or which Docker network it's on, so the sandbox can reach any host port this way, not just the one your provider uses. A single-purpose proxy container that only forwards one port was tried and doesn't help, for the same reason: it doesn't stop the sandbox from also reaching `host.docker.internal` directly. Actually restricting this would require running the container as root with `--cap-add=NET_ADMIN` to set a firewall rule before dropping to the unprivileged user — a real change to this project's privilege model, not implemented here.

## Repository structure

```
├── install.sh                        # one-time setup: shim dir, PATH, image build
├── restore.sh                        # undo the install
├── src/
│   ├── opencode.sh                   # the wrapper: mounts, gitconfig filter,
│   │                                  # plugin discovery, config/env wiring, docker run
│   ├── lib/
│   │   ├── install-common.sh         # shared install/restore helpers (shims, PATH, builds)
│   │   └── path-utils.sh             # shared path-resolution helper
│   └── container/
│       ├── Dockerfile.opencode       # multi-stage: compiles opencode from upstream source,
│       │                              # minimal node:24-slim image with the binary, the
│       │                              # entrypoint, and the banner baked at /opt/sandbox-banner
│       ├── entrypoint.sh             # container entrypoint: deletes the host's background-
│       │                              # service registrations/locks on start and exit, declares
│       │                              # the banner plugin, runs opencode and forwards signals
│       └── plugins/
│           └── sandbox-banner/        # the "you are in a sandbox" indicator plugin
│               ├── index.js           # (baked to /opt, declared by the entrypoint through
│               └── tui.js              #  OPENCODE_CONFIG_CONTENT; never written to the host)
└── tests/
    └── test-opencode-wrapper.sh
```

## License

MIT. The banner plugin and this wrapper are original work. The `opencode` binary inside the image is compiled from [upstream opencode](https://github.com/anomalyco/opencode) source and remains under its own license.
