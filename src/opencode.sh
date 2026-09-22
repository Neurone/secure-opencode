#!/usr/bin/env bash
set -euo pipefail

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

  # The same file can be declared in more than one config (e.g. a plugin
  # listed in both the global and the project config); mount it once.
  for ((i = 1; i < ${#MOUNT_ARGS[@]}; i += 2)); do
    if [ "${MOUNT_ARGS[$i]}" = "$spec" ]; then
      return 0
    fi
  done

  MOUNT_ARGS+=(-v "$spec")
}

# Mounts each entry of $1 individually as a sibling under $2 (rather than one
# whole-directory mount), skipping names matching any of the shell glob
# patterns in $3.... Used for the config/data/state dirs: Docker Desktop's
# virtiofs backend can't mount a path from a different host source on top of
# a path already covered by another bind mount, so specific entries need
# their own mount to be left out or overlaid read-only without dragging the
# rest of the directory along.
mount_sibling_entries() {
  local src_dir="$1" container_dir="$2"
  shift 2
  local entry name pattern excluded
  shopt -s nullglob dotglob
  for entry in "$src_dir"/*; do
    name="$(basename "$entry")"
    excluded=0
    for pattern in "$@"; do
      case "$name" in
        $pattern)
          excluded=1
          break
          ;;
      esac
    done
    [ "$excluded" -eq 1 ] && continue
    MOUNT_ARGS+=(-v "$entry:$container_dir/$name")
  done
  shopt -u nullglob dotglob
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

# opencode plugins can be declared in the config as npm package names,
# relative paths (both resolved from inside the container, nothing to mount),
# or absolute host paths (e.g. a corporate/managed plugin living outside both
# $CONFIG_DIR_SRC and $PROJECT_DIR). Only the latter need an explicit mount so
# the container can see them at the same absolute path opencode will look
# them up at. Entries already under $CONFIG_DIR_SRC or $PROJECT_DIR are
# reported as mounted without being bind-mounted a second time (Docker
# Desktop's virtiofs backend rejects overlapping mounts from different
# sources).
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
      | jq -r '(.plugin // []) | if type == "array" then .[] else . end | if type == "array" then .[0] else . end' 2>"$TMPDIR_RUN/plugin-jq.err" \
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
      "$CONFIG_DIR_SRC"/* | "$PROJECT_DIR"/*)
        PLUGIN_FILES_MOUNTED+=("$plugin_path")
        continue
        ;;
    esac

    if [ -f "$plugin_path" ]; then
      append_mount_if_file "$plugin_path" "$plugin_path" "ro"
      PLUGIN_FILES_MOUNTED+=("$plugin_path")
    else
      PLUGIN_FILES_MISSING+=("$plugin_path")
    fi
  done <<< "$plugin_entries"
}

print_plugin_mount_manifest() {
  if [ "${#PLUGIN_FILES_MISSING[@]}" -gt 0 ]; then
    echo "Warning: plugin files referenced in your opencode config files were not found on the host and will not run in the container:" >&2
    local plugin_file
    for plugin_file in "${PLUGIN_FILES_MISSING[@]}"; do
      echo "  - $plugin_file" >&2
    done
  fi

  if [ "${#PLUGIN_FILES_MOUNTED[@]}" -gt 0 ]; then
    echo "Plugin files available in the container:" >&2
    local plugin_file
    for plugin_file in "${PLUGIN_FILES_MOUNTED[@]}"; do
      echo "  - $plugin_file" >&2
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

# Needed to read plugin paths out of opencode.json so they can be mounted
# into the container (see collect_plugin_mounts).
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required to mount plugin files declared in opencode.json. Install jq and try again." >&2
  exit 1
fi

declare -a PLUGIN_FILES_MOUNTED=()
declare -a PLUGIN_FILES_MISSING=()

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

# opencode resolves its config/data/state dirs via XDG base dirs, defaulting
# to ~/.config/opencode, ~/.local/share/opencode and ~/.local/state/opencode
# respectively when the XDG env vars aren't set (see
# https://opencode.ai/docs/config/).
CONFIG_DIR_SRC="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
DATA_DIR_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
STATE_DIR_SRC="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"
CONTAINER_CONFIG_DIR="/home/node/.config/opencode"
CONTAINER_DATA_DIR="/home/node/.local/share/opencode"
CONTAINER_STATE_DIR="/home/node/.local/state/opencode"

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
# host files recursively, which must not happen to $CONFIG_DIR_SRC,
# $DATA_DIR_SRC, or $STATE_DIR_SRC.
MOUNT_SUFFIX=""
if [ "$OS" = "Linux" ] && command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  MOUNT_SUFFIX=":z"
fi

MOUNT_ARGS=(-v "$PROJECT_DIR:$CONTAINER_WORKDIR$MOUNT_SUFFIX")

# Mount each entry of the config dir individually (siblings), instead of the
# whole directory: Docker Desktop's virtiofs backend cannot mount a path from
# a different host source on top of a path already covered by another bind
# mount, so opencode.json/opencode.jsonc can't be overlaid read-only on a
# single whole-directory mount. The rest (agents/, commands/, modes/,
# plugins/, skills/, tools/, themes/, and opencode's own node_modules/
# package.json for npm-package plugins) stays writable, since opencode
# manages plugin installs there at runtime.
#
# service.json lives here too (alongside its namesake in the state dir) and
# holds a password for opencode's background service; it is never mounted,
# same rationale as skipping the state dir's service.json/locks below.
if [ -d "$CONFIG_DIR_SRC" ]; then
  mount_sibling_entries "$CONFIG_DIR_SRC" "$CONTAINER_CONFIG_DIR" "opencode.json" "opencode.jsonc" "service.json"
else
  echo "Warning: $CONFIG_DIR_SRC not found, container will start with no opencode config" >&2
fi

# opencode.json/opencode.jsonc declare which plugins/hooks run, so they are
# mounted read-only: this stops the sandboxed process from rewriting its own
# plugin configuration (which would persist back to the host, since this is
# a live bind mount).
append_mount_if_file "$CONFIG_DIR_SRC/opencode.json" "$CONTAINER_CONFIG_DIR/opencode.json" "ro"
append_mount_if_file "$CONFIG_DIR_SRC/opencode.jsonc" "$CONTAINER_CONFIG_DIR/opencode.jsonc" "ro"

# Mount each entry of the data dir individually (siblings), instead of the
# whole directory: Docker Desktop's virtiofs backend cannot mount a path from
# a different host source on top of a path already covered by another bind
# mount, so specific entries can be left out entirely without dragging the
# rest along. The rest (log/, repos/, ...) stays writable so it persists back
# to the host across runs.
#
# auth.json (provider credentials) is excluded on purpose: this wrapper does
# not carry any credentials into the container. Point opencode at a local
# provider (LM Studio, Ollama, ...) that needs none, or run 'opencode auth
# login' inside the container itself.
#
# opencode.db* (the SQLite session store) is excluded for a different
# reason: it's schema-versioned, and the container's opencode (built from
# upstream independently of whatever's on the host, see
# ensure_sandbox_image_current in lib/install-common.sh) can be on a
# different version than the host's own install. Confirmed by testing:
# pointing an older opencode at a newer host's opencode.db hard-crashes with
# "Database is not empty and has no session table" instead of migrating or
# ignoring the mismatch. Leaving it out costs cross-run session history
# inside the container, but that's consistent with the container being
# disposable anyway.
if [ -d "$DATA_DIR_SRC" ]; then
  mount_sibling_entries "$DATA_DIR_SRC" "$CONTAINER_DATA_DIR" "auth.json" "opencode.db*"
else
  echo "Warning: $DATA_DIR_SRC not found, container will start with no opencode session data" >&2
fi

# Mount the state dir (recent models, prompt history, TUI tab state) the
# same way, except service.json and locks/: these coordinate opencode's
# background service (host, port, an auth password) for the *host* machine.
# Mounting them in would make the container either try to reach a service
# that only exists on the host's network namespace, or hand the host's
# service password to the sandboxed process. Leaving them out makes the
# container start its own private, disposable service the first time
# opencode runs inside it, exactly as if $CONTAINER_STATE_DIR were empty.
if [ -d "$STATE_DIR_SRC" ]; then
  mount_sibling_entries "$STATE_DIR_SRC" "$CONTAINER_STATE_DIR" "service.json" "locks" "latest"

  # latest/ holds the actual per-profile state (recent models, prompt
  # history, TUI tab list) one level deeper, and needs the same sibling
  # treatment: latest/tui/tabs.json records open tabs by session ID, which
  # point into opencode.db -- excluded above for the same schema-mismatch
  # reason as service.json/locks. Mounting it verbatim lets an old tab reopen
  # against a session the container's own (separate, disposable) database
  # never had, and opencode reports "invalid session" and closes the tab.
  if [ -d "$STATE_DIR_SRC/latest" ]; then
    mount_sibling_entries "$STATE_DIR_SRC/latest" "$CONTAINER_STATE_DIR/latest" "locks" "tui"
    if [ -d "$STATE_DIR_SRC/latest/tui" ]; then
      mount_sibling_entries "$STATE_DIR_SRC/latest/tui" "$CONTAINER_STATE_DIR/latest/tui" "tabs.json"
    fi
  fi
fi

# OPENCODE_CONFIG can point at an extra config file anywhere on disk (see
# https://opencode.ai/docs/config/); mount it if it isn't already covered by
# the config dir or project mounts above.
if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "$OPENCODE_CONFIG" ]; then
  case "$OPENCODE_CONFIG" in
    "$CONFIG_DIR_SRC"/* | "$PROJECT_DIR"/*) ;;
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

# Mount every plugin file the config's "plugin" entries point to at an
# absolute host path (e.g. a corporate/managed plugin), so the container is
# monitored the same way the host session is. Checked in the global config
# (opencode.json and opencode.jsonc), the project's own config files, and
# OPENCODE_CONFIG when it points somewhere else.
collect_plugin_mounts "$CONFIG_DIR_SRC/opencode.json"
collect_plugin_mounts "$CONFIG_DIR_SRC/opencode.jsonc"
collect_plugin_mounts "$PROJECT_DIR/opencode.json"
collect_plugin_mounts "$PROJECT_DIR/opencode.jsonc"
if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "$OPENCODE_CONFIG" ]; then
  case "$OPENCODE_CONFIG" in
    "$CONFIG_DIR_SRC/opencode.json" | "$CONFIG_DIR_SRC/opencode.jsonc" \
    | "$PROJECT_DIR/opencode.json" | "$PROJECT_DIR/opencode.jsonc")
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
# '"baseURL": "{env:OPENCODE_LMSTUDIO_BASEURL}"' and export the localhost
# equivalent yourself for native use (see README.md).
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
  "${TZ_ARGS[@]+"${TZ_ARGS[@]}"}" \
  "${CA_BUNDLE_ARGS[@]+"${CA_BUNDLE_ARGS[@]}"}" \
  "$SECURE_OPENCODE_IMAGE_NAME:current" \
  "$@"
