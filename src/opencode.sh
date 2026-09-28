#!/usr/bin/env bash
set -euo pipefail

# Runs opencode inside a Docker sandbox, with the same behavior as a local
# install.
#
# The four opencode directories -- $HOME/.config/opencode (config, settings,
# plugins), $HOME/.local/share/opencode (session database, credentials, logs),
# $HOME/.local/state/opencode (background-service registration, file locks)
# and $HOME/.cache/opencode (npm plugin cache), each honoring the XDG_*
# environment variables -- are bind-mounted whole, read/write, into the
# container: everything persists and stays host-editable, exactly as with a
# native install.
#
# The exceptions, deliberately:
#   - the global opencode.json/opencode.jsonc are overlaid read-only on top
#     of the writable config mount: they hold the provider configuration and
#     the plugin declarations, and a sandboxed process rewriting them would
#     persist the change back to the host;
#   - nothing else in the home dir (~/.ssh, ~/.aws, other tools) is mounted;
#   - no credentials are forwarded as environment variables (see the docker
#     run block below).
#
# The credentials opencode itself stores in the session database (v2 keeps
# them in the database, in the data dir) come along with the data dir: that
# is what "like a local install" means -- the sandbox is trusted with exactly
# the data a native opencode run would have (see README.md).

# Resolve this script's real location, following symlinks: once install.sh
# runs, 'opencode' is a symlink to this file, so BASH_SOURCE[0] alone would
# point at the symlink's directory instead of this repo's src/ directory.
# path-utils.sh (which has a general resolve_path helper) cannot be sourced
# yet, since its own path is derived from SCRIPT_DIR, hence this inline loop.
SELF_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SELF_SOURCE" ]; do
  SELF_SOURCE_DIR="$(cd -P "$(dirname "$SELF_SOURCE")" && pwd)"
  SELF_SOURCE="$(readlink "$SELF_SOURCE")"
  [[ "$SELF_SOURCE" = /* ]] || SELF_SOURCE="$SELF_SOURCE_DIR/$SELF_SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SELF_SOURCE")" && pwd -P)"
CONTAINER_DIR="$SCRIPT_DIR/container"
DOCKERFILE="$CONTAINER_DIR/Dockerfile.opencode"
PATH_UTILS="$SCRIPT_DIR/lib/path-utils.sh"
INSTALL_COMMON="$SCRIPT_DIR/lib/install-common.sh"

# Appends a read-write or read-only -v for an existing host file, at the same
# container path, once. (The same file can be declared in more than one
# config, e.g. a plugin listed in both the global and the project config;
# mounting it twice would fail or shadow.)
append_mount_if_file() {
  local source_path="$1"
  local target_path="$2"
  local mode="${3:-}"
  local spec i

  if [ ! -f "$source_path" ]; then
    return 0
  fi

  if [ -n "$mode" ]; then
    spec="$source_path:$target_path:$mode"
  else
    spec="$source_path:$target_path"
  fi

  for ((i = 1; i < ${#MOUNT_ARGS[@]}; i += 2)); do
    if [ "${MOUNT_ARGS[$i]}" = "$spec" ]; then
      return 0
    fi
  done

  MOUNT_ARGS+=(-v "$spec")
}

# Appends a read-only -v for an existing host path (file or directory), at
# the same container path, once. Used for plugin paths outside the mounted
# directories: opencode only reads configured plugins, so :ro is enough.
append_plugin_mount() {
  local path="$1"
  local i

  if [ ! -e "$path" ]; then
    return 0
  fi

  for ((i = 1; i < ${#MOUNT_ARGS[@]}; i += 2)); do
    if [ "${MOUNT_ARGS[$i]}" = "$path:$path:ro" ]; then
      return 0
    fi
  done

  MOUNT_ARGS+=(-v "$path:$path:ro")
}

# Converts JSONC (// and /* */ comments, trailing commas) to strict JSON on
# standard input, one character at a time so it works with mawk (no gensub).
# The whole input is buffered first: a trailing comma sits on the line before
# the }/] that closes the array/object, so the lookahead must cross lines.
# Both passes are string- and escape-aware: a "//", "/*" or a trailing comma
# inside a string value is preserved, not treated as JSONC syntax. A no-op on
# strict JSON.
normalize_json_stream() {
  # With a file argument the file is read; without one, standard input.
  awk '
    { buf = buf $0 "\n" }
    END {
      # Pass 1: drop // and /* */ comments.
      n = length(buf)
      out = ""
      in_str = 0
      esc = 0
      in_block = 0
      i = 1
      while (i <= n) {
        c = substr(buf, i, 1)
        if (in_block) {
          if (c == "*" && substr(buf, i + 1, 1) == "/") { in_block = 0; i += 2 }
          else i++
          continue
        }
        if (in_str) {
          out = out c
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") in_str = 0
          i++
          continue
        }
        if (c == "\"") { in_str = 1; out = out c; i++; continue }
        if (c == "/") {
          d = substr(buf, i + 1, 1)
          if (d == "/") {
            while (i <= n && substr(buf, i, 1) != "\n") i++
            continue
          }
          if (d == "*") { in_block = 1; i += 2; continue }
        }
        out = out c
        i++
      }
      # Pass 2: drop trailing commas (next significant character is } or ]).
      n = length(out)
      res = ""
      in_str = 0
      esc = 0
      i = 1
      while (i <= n) {
        c = substr(out, i, 1)
        if (in_str) {
          res = res c
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") in_str = 0
          i++
          continue
        }
        if (c == "\"") { in_str = 1; res = res c; i++; continue }
        if (c == ",") {
          j = i + 1
          while (j <= n && index(" \t\r\n", substr(out, j, 1)) != 0) j++
          if (j <= n && (substr(out, j, 1) == "}" || substr(out, j, 1) == "]")) {
            i++
            continue
          }
        }
        res = res c
        i++
      }
      printf "%s", res
    }
  ' "$@"
}

# Reads the plugin entries of an opencode config file and prepares the mounts
# they need.
#
# opencode v2 lists plugins under the "plugins" key (v1 used "plugin"; both
# are accepted, v2 still decodes the legacy key). An entry can be:
#   - an npm package name (or a [name, options] pair, or a {package, options}
#     object): opencode installs it into its cache dir on first use. The
#     cache dir is mounted whole, so there is nothing to mount -- the
#     container sees whatever the host has already installed and vice versa;
#   - a relative path: opencode resolves it against the directory of the
#     config file that declares it (the config dir or the project dir, both
#     mounted whole). Nothing to mount;
#   - an absolute host path outside all the mounted directories (e.g. a
#     corporate/managed plugin): mounted read-only at the same path. v2 only
#     accepts a *directory* here (a bare file path is rejected with a
#     warning), but a found file is mounted anyway -- harmless, and it keeps
#     a v1-style config working if one is ever pointed at the sandbox.
# Entries already under one of the mounted directories are reported as
# available without a second mount: a whole-directory mount cannot be
# shadowed by another from the same source, and the entry is visible through
# it as-is.
#
# The file may be strict JSON or JSONC (opencode accepts .jsonc, and some
# users write comments in opencode.json too); JSONC syntax is normalized
# before jq reads it. A file that cannot be parsed after normalization is
# reported loudly, not silently skipped: a config the user meant to be
# active quietly losing its plugins is worse than a warning.
collect_plugin_mounts() {
  local config_file="$1"
  local plugin_path
  local plugin_entries

  if [ ! -f "$config_file" ]; then
    return 0
  fi

  if ! plugin_entries="$(normalize_json_stream "$config_file" \
      | jq -r '(.plugin // .plugins // []) | if type == "array" then .[] else . end | if type == "array" then .[0] elif type == "object" then .package // empty else . end' 2>"$TMPDIR_RUN/plugin-jq.err" \
      | sort -u)"; then
    echo "Warning: could not read plugin entries from $config_file; its plugins will not be mounted. jq said:" >&2
    head -n 1 "$TMPDIR_RUN/plugin-jq.err" >&2
    return 0
  fi

  while IFS= read -r plugin_path; do
    [ -z "$plugin_path" ] && continue

    case "$plugin_path" in
      /*) ;;
      *) continue ;;
    esac

    case "$plugin_path" in
      "$CONFIG_DIR_SRC"/* | "$DATA_DIR_SRC"/* | "$STATE_DIR_SRC"/* | "$CACHE_DIR_SRC"/* | "$PROJECT_DIR"/*)
        record_plugin_available "$plugin_path"
        continue
        ;;
    esac

    if [ -e "$plugin_path" ]; then
      append_plugin_mount "$plugin_path"
      record_plugin_available "$plugin_path"
    else
      record_plugin_missing "$plugin_path"
    fi
  done <<< "$plugin_entries"
}

# Lists a plugin path as available/missing, once (the same path can be
# declared in more than one config file).
record_plugin_available() {
  local candidate="$1"
  local known
  for known in ${PLUGIN_PATHS_AVAILABLE[@]+"${PLUGIN_PATHS_AVAILABLE[@]}"}; do
    if [ "$known" = "$candidate" ]; then
      return 0
    fi
  done
  PLUGIN_PATHS_AVAILABLE+=("$candidate")
}

record_plugin_missing() {
  local candidate="$1"
  local known
  for known in ${PLUGIN_PATHS_MISSING[@]+"${PLUGIN_PATHS_MISSING[@]}"}; do
    if [ "$known" = "$candidate" ]; then
      return 0
    fi
  done
  PLUGIN_PATHS_MISSING+=("$candidate")
}

print_plugin_mount_manifest() {
  if [ "${#PLUGIN_PATHS_MISSING[@]}" -gt 0 ]; then
    echo "Warning: plugin entries referenced in your opencode config files were not found on the host and will not run in the container:" >&2
    local plugin_path
    for plugin_path in "${PLUGIN_PATHS_MISSING[@]}"; do
      echo "  - $plugin_path" >&2
    done
  fi

  if [ "${#PLUGIN_PATHS_AVAILABLE[@]}" -gt 0 ]; then
    echo "Plugin entries available in the container:" >&2
    local plugin_path
    for plugin_path in "${PLUGIN_PATHS_AVAILABLE[@]}"; do
      echo "  - $plugin_path" >&2
    done
  fi
}

if [ ! -f "$PATH_UTILS" ]; then
  echo "Error: could not find path utils at $PATH_UTILS" >&2
  exit 1
fi

# shellcheck source=lib/path-utils.sh
source "$PATH_UTILS"

if [ ! -f "$INSTALL_COMMON" ]; then
  echo "Error: could not find install-common helpers at $INSTALL_COMMON" >&2
  exit 1
fi

# shellcheck source=lib/install-common.sh
source "$INSTALL_COMMON"

OS="$(uname -s)"

if [ ! -f "$DOCKERFILE" ]; then
  echo "Error: could not find Dockerfile at $DOCKERFILE" >&2
  exit 1
fi

# Needed to read plugin paths out of the opencode config files so they can be
# mounted into the container (see collect_plugin_mounts).
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required to mount plugin paths declared in the opencode config files. Install jq and try again." >&2
  exit 1
fi

declare -a PLUGIN_PATHS_AVAILABLE=()
declare -a PLUGIN_PATHS_MISSING=()

# ---------------------------------------------------------------------------
# opencode itself is built from the official upstream source at the latest
# stable release, not tracked against whatever's installed on the host (see
# ensure_sandbox_image_current in lib/install-common.sh): it builds only when
# a newer stable release is out, and falls back to the last successful local
# build if that build fails.
# ---------------------------------------------------------------------------
if ! ensure_sandbox_image_current "$DOCKERFILE" "$CONTAINER_DIR"; then
  exit 1
fi

# ---------------------------------------------------------------------------
# Timezone. The base image has no local timezone configured, so without this
# the container clock defaults to UTC while the host shows local time.
# ---------------------------------------------------------------------------
TZ_VALUE="${TZ:-}"
if [ -z "$TZ_VALUE" ] && [ -f /etc/timezone ]; then
  TZ_VALUE="$(< /etc/timezone)"
fi
if [ -z "$TZ_VALUE" ] && [ -e /etc/localtime ]; then
  TZ_VALUE="$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p')"
fi
TZ_ARGS=()
if [ -n "$TZ_VALUE" ]; then
  TZ_ARGS=(-e "TZ=$TZ_VALUE")
else
  echo "Warning: could not determine host timezone; container clock will show UTC" >&2
fi

# opencode resolves its directories via XDG base dirs, defaulting to
# ~/.config/opencode, ~/.local/share/opencode, ~/.local/state/opencode and
# ~/.cache/opencode when the XDG env vars aren't set (see
# https://opencode.ai/docs/config/). All four are bind-mounted whole,
# read/write, into the container at the same paths under its HOME
# (/home/node, set in the docker run below): everything persists and stays
# host-editable, exactly as with a native install.
CONFIG_DIR_SRC="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
DATA_DIR_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
STATE_DIR_SRC="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"
CACHE_DIR_SRC="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"
CONTAINER_CONFIG_DIR="/home/node/.config/opencode"
CONTAINER_DATA_DIR="/home/node/.local/share/opencode"
CONTAINER_STATE_DIR="/home/node/.local/state/opencode"
CONTAINER_CACHE_DIR="/home/node/.cache/opencode"

# A missing dir is created (empty): a fresh host then gets whatever opencode
# first creates inside the container, through the mount.
mkdir -p "$CONFIG_DIR_SRC" "$DATA_DIR_SRC" "$STATE_DIR_SRC" "$CACHE_DIR_SRC"
TMPDIR_RUN="$(mktemp -d)"
GITCONFIG_TMP="$TMPDIR_RUN/gitconfig"
CA_BUNDLE_TMP="$TMPDIR_RUN/ca-certificates.crt"
cleanup() { rm -rf "$TMPDIR_RUN"; }
trap cleanup EXIT

# The host port a local model provider (e.g. LM Studio) listens on. Note
# this does not by itself restrict the container to only this port:
# host.docker.internal is reachable on Docker Desktop (macOS/Windows)
# regardless of any flag or network, so a sandboxed process could still
# reach any other host port directly. This only sets the value handed to
# opencode for the one provider it's meant to reach (see below).
SECURE_OPENCODE_LMSTUDIO_PORT="${SECURE_OPENCODE_LMSTUDIO_PORT:-1234}"

# ---------------------------------------------------------------------------
# CA certificates. The image has no ca-certificates package, so without this
# every HTTPS request inside the container fails with curl exit 77 ("error
# setting certificate file"). The host's trust store is mounted in rather
# than installing a generic one, so the container also trusts whatever
# corporate root CA (e.g. a TLS-inspecting proxy) the host already trusts.
# ---------------------------------------------------------------------------
CA_BUNDLE_ARGS=()
case "$OS" in
  Darwin)
    if { security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain
         security find-certificate -a -p /Library/Keychains/System.keychain; } >"$CA_BUNDLE_TMP" 2>/dev/null \
       && [ -s "$CA_BUNDLE_TMP" ]; then
      CA_BUNDLE_ARGS=(-v "$CA_BUNDLE_TMP:/etc/ssl/certs/ca-certificates.crt:ro")
    else
      rm -f "$CA_BUNDLE_TMP"
      echo "Warning: could not export CA certificates from the macOS keychain; HTTPS requests inside the container may fail" >&2
    fi
    ;;
  *)
    for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
      if [ -s "$candidate" ]; then
        CA_BUNDLE_ARGS=(-v "$candidate:/etc/ssl/certs/ca-certificates.crt:ro")
        break
      fi
    done
    if [ "${#CA_BUNDLE_ARGS[@]}" -eq 0 ]; then
      echo "Warning: no host CA bundle found; HTTPS requests inside the container may fail" >&2
    fi
    ;;
esac

PROJECT_DIR="$(pwd)"
CONTAINER_WORKDIR="$PROJECT_DIR"

# On SELinux hosts (Fedora/RHEL and derivatives) bind mounts are inaccessible
# without relabelling. Only the project mount gets :z — the flag relabels the
# host files recursively, which must not happen to the four opencode dirs.
MOUNT_SUFFIX=""
if [ "$OS" = "Linux" ] && command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  MOUNT_SUFFIX=":z"
fi

MOUNT_ARGS=(-v "$PROJECT_DIR:$CONTAINER_WORKDIR$MOUNT_SUFFIX")

# The four opencode directories, each mounted whole at the same path under
# the container's HOME. What each holds, and why whole:
#
# config: opencode.json/opencode.jsonc (provider configuration), cli.json
#   (v2's CLI/TUI settings: theme, keybinds, the plugins list recorded by
#   `opencode plugin add`), the background-service config (service.json:
#   hostname, port, password) and the user-content dirs (agents/, commands/,
#   modes/, plugins/, skills/ -- v2 also scans their singular forms -- and
#   themes/, which is plural-only).
# data: the session database (opencode.db*) plus log/, repos/ ... In v2 the
#   provider credentials live inside the database, so they come along with
#   the sessions: the sandbox is trusted with exactly the data a native
#   opencode run would have (see README.md, Credentials).
# state: the background-service registration (service*.json, with their
#   .tmp and .pty-handoff sidecars) and the file locks (locks/). Both are
#   per-machine coordination state: the entrypoint
#   (src/container/entrypoint.sh) deletes them at startup and again on exit,
#   so the host's running service notices its registration was replaced and
#   shuts itself down, and a stale lock cannot stall the sandbox. Everything
#   else in the dir just persists.
# cache: where opencode installs npm-package plugins (keyed per platform,
#   ~7-day retention): a package the sandbox installed is ready for the
#   host's next run, and vice versa.
MOUNT_ARGS+=(
  -v "$CONFIG_DIR_SRC:$CONTAINER_CONFIG_DIR"
  -v "$DATA_DIR_SRC:$CONTAINER_DATA_DIR"
  -v "$STATE_DIR_SRC:$CONTAINER_STATE_DIR"
  -v "$CACHE_DIR_SRC:$CONTAINER_CACHE_DIR"
)

# One overlay on the writable config mount: the global
# opencode.json/opencode.jsonc, read-only. They declare the provider
# configuration and which plugins/hooks run; letting a sandboxed process
# rewrite them would persist the change to the host. Same host source as the
# directory mount (Docker applies the file mounts on top of it, in order), so
# in-sandbox writes fail while the container keeps seeing the current host
# content, and host edits are picked up immediately -- it is the same file.
append_mount_if_file "$CONFIG_DIR_SRC/opencode.json" "$CONTAINER_CONFIG_DIR/opencode.json" "ro"
append_mount_if_file "$CONFIG_DIR_SRC/opencode.jsonc" "$CONTAINER_CONFIG_DIR/opencode.jsonc" "ro"

# OPENCODE_CONFIG can point at an extra config file anywhere on disk (see
# https://opencode.ai/docs/config/). It is forwarded into the container so
# the sandboxed opencode applies the same alternative config the host does;
# if the file isn't under one of the mounted dirs, it is mounted read-only
# at the same path.
OPENCODE_CONFIG_ARGS=()
if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "$OPENCODE_CONFIG" ]; then
  OPENCODE_CONFIG_ARGS=(-e "OPENCODE_CONFIG=$OPENCODE_CONFIG")
  case "$OPENCODE_CONFIG" in
    "$CONFIG_DIR_SRC"/* | "$DATA_DIR_SRC"/* | "$STATE_DIR_SRC"/* | "$CACHE_DIR_SRC"/* | "$PROJECT_DIR"/*) ;;
    *) append_mount_if_file "$OPENCODE_CONFIG" "$OPENCODE_CONFIG" "ro" ;;
  esac
fi

# Carry the host git identity and aliases into the container. A filtered copy
# is mounted rather than the original: credential helpers configured on the
# host (osxkeychain, libsecret) do not exist inside the image and would make
# any authenticating git command fail.
if [ -f "$HOME/.gitconfig" ]; then
  cp "$HOME/.gitconfig" "$GITCONFIG_TMP"
  git config --file "$GITCONFIG_TMP" --remove-section credential 2>/dev/null || true
  MOUNT_ARGS+=(-v "$GITCONFIG_TMP:/home/node/.gitconfig:ro")
fi

# Mount every plugin the config files point to at an absolute host path
# (e.g. a corporate/managed plugin), so the container is monitored the same
# way the host session is. Checked in the global config (opencode.json,
# opencode.jsonc), the v2 settings file (cli.json: where `opencode plugin
# add` records its list), the project's own config files, and
# OPENCODE_CONFIG when it points somewhere else.
collect_plugin_mounts "$CONFIG_DIR_SRC/opencode.json"
collect_plugin_mounts "$CONFIG_DIR_SRC/opencode.jsonc"
collect_plugin_mounts "$CONFIG_DIR_SRC/cli.json"
collect_plugin_mounts "$PROJECT_DIR/opencode.json"
collect_plugin_mounts "$PROJECT_DIR/opencode.jsonc"
if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "$OPENCODE_CONFIG" ]; then
  case "$OPENCODE_CONFIG" in
    "$CONFIG_DIR_SRC/opencode.json" | "$CONFIG_DIR_SRC/opencode.jsonc" \
    | "$CONFIG_DIR_SRC/cli.json" | "$PROJECT_DIR/opencode.json" \
    | "$PROJECT_DIR/opencode.jsonc")
      ;;
    *)
      collect_plugin_mounts "$OPENCODE_CONFIG"
      ;;
  esac
fi

print_plugin_mount_manifest

# --user keeps files created in the project mount owned by the invoking user
# (which matters on Linux, where there is no UID remapping layer).
# --group-add 0 grants access to /home/node, whose contents are owned by
# node:0 with group permissions mirroring the owner's.
#
# No credentials (env vars or files) are forwarded into the container by
# this wrapper: use a provider that needs none (LM Studio, Ollama, ...), or
# run 'opencode auth login' inside the container itself.
#
# host.docker.internal lets a provider configured against a local server on
# the host (e.g. LM Studio, Ollama) stay reachable from inside the
# container. On Linux this requires --add-host explicitly; on Docker Desktop
# (macOS/Windows) it resolves regardless of this flag, and so does every
# other port on the host — there is no way to scope it down to a single
# port from inside this wrapper (see README.md for what was tried).
# OPENCODE_LMSTUDIO_BASEURL is set so the same opencode.json works both
# natively and sandboxed: reference it as
# '"baseURL": "{env:OPENCODE_LMSTUDIO_BASEURL}"'. For native use nothing is
# needed when your LM Studio listens on the default endpoint -- an unset
# variable substitutes to an empty string, which opencode treats as no
# override, so the provider falls back to its built-in
# http://127.0.0.1:1234/v1 default; export the variable only if it listens
# elsewhere (see README.md).
#
# The ${arr[@]+...} idiom on TZ_ARGS/CA_BUNDLE_ARGS keeps this working on
# macOS's default bash 3.2, where expanding an empty array under set -u is
# an unbound-variable error (fixed only in bash 4.4+).
docker run -it --rm \
  --add-host=host.docker.internal:host-gateway \
  --user "$(id -u):$(id -g)" \
  --group-add 0 \
  -e HOME=/home/node \
  "${MOUNT_ARGS[@]}" \
  -w "$CONTAINER_WORKDIR" \
  -e OPENCODE_LMSTUDIO_BASEURL="http://host.docker.internal:$SECURE_OPENCODE_LMSTUDIO_PORT/v1" \
  "${OPENCODE_CONFIG_ARGS[@]+"${OPENCODE_CONFIG_ARGS[@]}"}" \
  "${TZ_ARGS[@]+"${TZ_ARGS[@]}"}" \
  "${CA_BUNDLE_ARGS[@]+"${CA_BUNDLE_ARGS[@]}"}" \
  "$SECURE_OPENCODE_IMAGE_NAME:current" \
  "$@"
