# Secure OpenCode

Runs [opencode](https://opencode.ai) inside a Docker sandbox instead of directly on the host, while still behaving like a normal `opencode` install: same `~/.config/opencode` config, same git identity (no credentials), same shell workflow. It works standalone, with no native OpenCode install required.

No provider credentials are carried into the container (see [Credentials](#credentials)). This is built with a **local model provider** (LM Studio, Ollama, a local proxy) in mind, which typically needs none anyway. What matters for those is network reachability: `--add-host=host.docker.internal:host-gateway` is always added (see [How it works](#how-it-works) and [Local providers](#local-providers) for the config change this requires).

## Why

**opencode can read and write anywhere it can reach, and run arbitrary shell commands**. A container puts a hard wall around that: only the project directory and a short, explicit allowlist of mounts are visible inside, a filtered opencode config, a git identity with its credential helpers stripped out, the host's CA bundle. **Everything else, `~/.aws`, `~/.ssh`, other cloud CLI configs, simply isn't there**. Tokens for services like `gh` or AWS only get in if you explicitly export and pass them through.

It doesn't take malice for that to matter, just a wrong command, or a manipulated one:

- A prompt-injection payload hidden in a dependency, README, or fetched file tells the agent to grab `gh auth token` and slip it into a PR description. On the host, that hands over your GitHub session. In the container, `gh` isn't authenticated, so there's nothing to steal.
- Debugging a failing deploy, opencode runs `aws sts get-caller-identity` and pastes the output into a log or commit to explain what's wrong. On the host, that can leak live AWS keys. In the container, `~/.aws` was never mounted, so there's nothing to leak.

Each run is also disposable and reproducible: `--rm` plus a pinned toolchain (`src/container/Dockerfile.opencode`) means stray global installs never accumulate on the host or drift between machines. `opencode` itself is compiled from the official upstream source at the latest stable release, independently of whatever's installed on the host (see [How it works](#how-it-works)).

## Requirements

- macOS or Linux
- `bash`
- `jq` (used to read plugin paths out of the opencode config files — the global and project `opencode.json`/`opencode.jsonc`, plus the file pointed to by `OPENCODE_CONFIG` when set — so they can be mounted into the container)
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
5. Build the `opencode-sandbox` Docker image from `src/container/Dockerfile.opencode`, compiling `opencode` from the latest stable upstream release (see [How it works](#how-it-works)).

No native `opencode` install is required: if step 2 doesn't find one, the script warns and just skips `opencode-original` — the sandboxed `opencode` from step 5 works regardless, since it's built entirely from upstream source inside Docker. Install `opencode` natively and re-run `./install.sh` at any later point to add the `opencode-original` shim.

The native install itself is never touched. The symlink/PATH setup (steps 2-4) is idempotent and skipped when already installed, but the image build in step 5 always runs from scratch. That makes re-running `./install.sh` the supported way to pick up an edit to `Dockerfile.opencode`: `opencode.sh` on its own only rebuilds when a newer stable upstream release is out, not on a local Dockerfile edit (see [How it works](#how-it-works)). If the rebuild on a re-run fails (e.g. you're offline), the script warns and keeps the existing image rather than failing; a fresh install without a working build exits with an error, since there is no image to fall back to. The script refuses to proceed if it finds a state it can't safely resolve on its own (e.g. an `opencode`/`opencode-original` in the shim directory that isn't a symlink it manages), explaining what to check.

## Usage

Once installed (and after starting a new shell, so the updated `PATH` takes effect), use `opencode` exactly as before:

```bash
opencode
```

It now runs sandboxed in Docker, with the project directory, your opencode config, and your git identity mounted in.

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

- `src/opencode.sh` is a wrapper that mounts the current project directory, your opencode config/data/state, and git identity into the container, and runs the real `opencode` binary inside it.
- opencode resolves config under `$XDG_CONFIG_HOME/opencode` (default `~/.config/opencode`), session/provider data under `$XDG_DATA_HOME/opencode` (default `~/.local/share/opencode`), and TUI/service state under `$XDG_STATE_HOME/opencode` (default `~/.local/state/opencode`). All three are mounted, each split into individual sibling mounts (rather than one mount per whole directory) so specific files inside them can get a different mode or be left out entirely — Docker Desktop's virtiofs backend can't otherwise overlay a path from a different host source on top of a directory already covered by another bind mount.
  - `opencode.json`/`opencode.jsonc` are mounted read-only: they declare which plugins run, so the sandboxed process can't rewrite its own plugin configuration (which would otherwise persist back to the host, since these are live bind mounts). Everything else in the config dir (`agents/`, `commands/`, `modes/`, `plugins/`, `skills/`, `tools/`, `themes/`, and opencode's own `node_modules/`/`package.json` it uses to install npm-package plugins) stays writable.
  - `auth.json` (provider credentials, when present) is never mounted — see [Credentials](#credentials).
  - `opencode.db*` (the SQLite session store, when present) is also never mounted: it's schema-versioned, and the container's opencode — built from upstream independently of the host install — can be on a different version, and pointing an older opencode at a newer database hard-crashes instead of migrating. The trade-off is no cross-run session history inside the container, consistent with the container being disposable anyway.
  - `service.json` (in the config dir and the state dir) and `locks/` (in the state dir, including `state/latest/locks/`) are never mounted. They coordinate opencode's background service (host, port, an auth password) for the *host* machine specifically; mounting them in would make the container either try to reach a service that only exists on the host's network namespace, or hand the host's service password to the sandboxed process. Leaving them out makes the container start its own private, disposable service the first time opencode runs inside it.
  - `state/latest/` (recent models, prompt history, TUI state) gets the same sibling-mount treatment one level down, except `latest/tui/tabs.json`: it records open tabs by session ID, and those IDs point into the excluded `opencode.db*`, so a stale tab would reopen against a session the container's own disposable database never had.
- Any absolute host path referenced by a `"plugin"` entry in your opencode config files (e.g. a corporate/managed plugin) is read-only bind-mounted into the container at the same path, so plugins configured on the host keep working unchanged inside the sandbox — but only for absolute paths outside both the config dir and the project dir, since those are already covered by the mounts above. `opencode.sh` reports which plugin files got mounted, and warns about any it couldn't find on the host. Plugin entries that are npm package names or relative paths need no extra mount: they resolve from the config dir's own `node_modules/`, already mounted.
  - Plugin entries are collected from the global and project `opencode.json`/`opencode.jsonc`, plus the file pointed to by `OPENCODE_CONFIG` when it's set and points somewhere other than those four files (JSONC syntax — comments and trailing commas — is accepted). A plugin the same config lists twice, or that is listed in both the global and the project config, is mounted once. A config file that can't be parsed is reported as a warning and skipped rather than aborting the launch.
- `--add-host=host.docker.internal:host-gateway` is always added, so a provider pointed at a local server on the host (LM Studio, Ollama, a local proxy) stays reachable from inside the container — but only if your `opencode.json` addresses it as `host.docker.internal` rather than `localhost`/`127.0.0.1` (see [Local providers](#local-providers)).
- The native opencode install is left completely untouched, and the container's own `opencode` is never compared against it. Instead, `opencode.sh` checks `github.com/anomalyco/opencode` on every launch for the latest stable tag of the major version line pinned in `src/lib/install-common.sh` (`OPENCODE_MAJOR`, currently `2`, i.e. `v2.*` tags, ignoring pre-release/CI tags like `v2.0.0-beta1`). If that's already what the `opencode-sandbox:current` image was last built from, it's reused as-is. If a newer stable release is out, `Dockerfile.opencode`'s `builder` stage clones that tag and compiles it from source with the project's own release build script (`packages/cli/script/build.ts`), and only the resulting binary is copied into the final image — Bun and the full source checkout never end up in the image you actually run. A build failure (network hiccup, upstream breakage) falls back to the last successful local build with a warning instead of failing the run; if there is no previous successful build to fall back to, `opencode.sh` stops rather than run nothing. A stable release of the *next* major version (e.g. `v3.x`) only prints a notice — it's never built automatically, since that'd be a deliberate upgrade decision, not an automatic one.
- `install.sh` creates `~/.secure-opencode/bin/`, with an `opencode` symlink to `src/opencode.sh` and, only if a native `opencode` is found on `PATH`, an `opencode-original` symlink to it, then prepends that directory to `PATH` in your shell startup files. Because it comes first on `PATH`, typing `opencode` anywhere resolves to the sandboxed wrapper instead of the native binary.
- `restore.sh` undoes exactly that: removes the shim directory and the `PATH` entry.

### Credentials

`src/opencode.sh` forwards no provider credentials into the container at all: no `auth.json`, no API key env vars (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, ...), no `OPENCODE_CONFIG_CONTENT`/`OPENCODE_AUTH_CONTENT`. Use a provider that needs none, like a local one reachable via `host.docker.internal`, or run `opencode auth login` inside the container itself. If you do need to forward something explicitly, add your own `-e VAR` to the `docker run` invocation in `src/opencode.sh`.

### Local providers

`opencode.json`/`opencode.jsonc` is the same file used both natively and inside the sandbox (it's bind-mounted, see [How it works](#how-it-works)), so a provider's `baseURL` can't be hardcoded to either `localhost` (breaks in the container) or `host.docker.internal` (breaks natively) without breaking the other. Use opencode's `{env:VAR}` config substitution instead, so the same file resolves differently in each context:

```jsonc
{
  "provider": {
    "lmstudio": {
      "options": {
        "baseURL": "{env:OPENCODE_LMSTUDIO_BASEURL}"
      }
    }
  }
}
```

`src/opencode.sh` always sets `OPENCODE_LMSTUDIO_BASEURL` to `http://host.docker.internal:$SECURE_OPENCODE_LMSTUDIO_PORT/v1` (port defaults to `1234`, LM Studio's default, overridable via the `SECURE_OPENCODE_LMSTUDIO_PORT` environment variable). For native use, export the same variable yourself (e.g. `http://127.0.0.1:1234/v1`, the default LM Studio endpoint per opencode's own provider registry) in your shell profile.

**Known limitation**: `--add-host=host.docker.internal:host-gateway` (or its absence) does not scope down *which* host ports are reachable — it's only needed at all on Linux, where this hostname isn't resolved by default. On Docker Desktop (macOS/Windows), `host.docker.internal` is reachable from any container regardless of this flag or which Docker network it's on, so the sandbox can reach any host port this way, not just the one your provider uses. A single-purpose proxy container that only forwards one port was tried and doesn't help, for the same reason: it doesn't stop the sandbox from also reaching `host.docker.internal` directly. Actually restricting this would require running the container as root with `--cap-add=NET_ADMIN` to set a firewall rule before dropping to the unprivileged user — a real change to this project's privilege model, not implemented here.

### Repository structure

```text
src/
├── opencode.sh                      # sandbox wrapper, installed as 'opencode'
├── lib/
│   ├── path-utils.sh                 # symlink resolution helper
│   └── install-common.sh             # shared helpers: install.sh / restore.sh, plus the
│                                      # upstream-tag-check-and-build machinery opencode.sh uses
└── container/
    ├── Dockerfile.opencode           # multi-stage: builds opencode from source, then a
    │                                  # lightweight node:24-slim image with just the binary
    └── plugins/
        └── sandbox-banner/           # baked-in plugin: shows a "Docker sandbox" toast in the TUI
            ├── index.js               # no-op server role (required for opencode to load the plugin at all)
            └── tui.js                 # tui role: the actual toast, via context.ui.toast
```

## License

MIT
