#!/usr/bin/env bash

# Shared helpers, constants, and shell-rc machinery for install.sh and
# restore.sh. opencode.sh also sources this file, for the sandbox image name
# and the ensure_sandbox_image_current build/version-check machinery.
#
# Design: rather than replacing the native 'opencode' in place, we keep it
# completely untouched (so opencode's own installer/'opencode upgrade' is
# free to manage it however it likes) and instead put our own 'opencode'
# symlink in a dedicated directory that we prepend to PATH. Because it comes
# first in PATH, it always wins over whatever the native install currently
# looks like, regardless of what the native upgrade does to it.

SECURE_OPENCODE_SHIM_DIR="$HOME/.secure-opencode/bin"
SECURE_OPENCODE_IMAGE_NAME="opencode-sandbox"

# The sandbox no longer tracks whatever opencode happens to be installed on
# the host: it builds opencode itself from the official source, straight from
# upstream, at the latest stable release of this major version line.
OPENCODE_UPSTREAM_REPO="https://github.com/anomalyco/opencode.git"
OPENCODE_MAJOR="2"
OPENCODE_VERSION_LABEL="org.opencode-sandbox.version"

SECURE_OPENCODE_RC_FILES=(
  "$HOME/.zshrc"
  "$HOME/.bashrc"
  "$HOME/.bash_profile"
  "$HOME/.profile"
)

SECURE_OPENCODE_PATH_MARKER_START="# >>> secure-opencode PATH (managed by install.sh, see restore.sh) >>>"
SECURE_OPENCODE_PATH_MARKER_END="# <<< secure-opencode PATH <<<"

require_supported_os() {
  local os
  os="$(uname -s)"
  case "$os" in
    Darwin | Linux) ;;
    *)
      echo "Error: unsupported OS '$os' (only macOS and Linux are supported)" >&2
      return 1
      ;;
  esac
}

# Finds the first 'opencode' executable on PATH, ignoring any entry that
# resolves to $1. Used to locate the native install while ignoring our own
# shim directory (which may itself already be on PATH from a previous run).
find_native_opencode() {
  local exclude_dir="$1"
  local old_ifs="$IFS"
  local -a path_dirs
  IFS=':' read -r -a path_dirs <<< "$PATH"
  IFS="$old_ifs"

  local dir resolved_dir
  for dir in "${path_dirs[@]}"; do
    [ -n "$dir" ] || continue
    resolved_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || continue
    [ "$resolved_dir" = "$exclude_dir" ] && continue
    if [ -f "$dir/opencode" ] && [ -x "$dir/opencode" ]; then
      printf '%s\n' "$dir/opencode"
      return 0
    fi
  done
  return 1
}

path_block_present() {
  local rc_file="$1"
  [ -f "$rc_file" ] && grep -qF "$SECURE_OPENCODE_PATH_MARKER_START" "$rc_file"
}

any_rc_has_path_block() {
  local rc_file
  for rc_file in "${SECURE_OPENCODE_RC_FILES[@]}"; do
    path_block_present "$rc_file" && return 0
  done
  return 1
}

add_path_block_to_rc_file() {
  local rc_file="$1"
  {
    echo ""
    echo "$SECURE_OPENCODE_PATH_MARKER_START"
    # shellcheck disable=SC2016 # '$PATH' must stay literal, expanded on shell startup, not now
    printf 'export PATH="%s:$PATH"\n' "$SECURE_OPENCODE_SHIM_DIR"
    echo "$SECURE_OPENCODE_PATH_MARKER_END"
  } >> "$rc_file"
}

remove_path_block_from_rc_file() {
  local rc_file="$1"
  local tmp_file
  tmp_file="$(mktemp "${rc_file}.secure-opencode.XXXXXX")"
  awk -v start="$SECURE_OPENCODE_PATH_MARKER_START" -v end="$SECURE_OPENCODE_PATH_MARKER_END" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    skip != 1 { print }
  ' "$rc_file" > "$tmp_file"
  mv "$tmp_file" "$rc_file"
}

# Adds the PATH block to every existing candidate rc file, or, if none of
# them exist yet, creates the one matching $SHELL. No-op if the block is
# already present anywhere (idempotent).
configure_shell_path() {
  if any_rc_has_path_block; then
    echo "  PATH entry already present in shell startup files."
    return 0
  fi

  local rc_file touched=0
  for rc_file in "${SECURE_OPENCODE_RC_FILES[@]}"; do
    [ -f "$rc_file" ] || continue
    add_path_block_to_rc_file "$rc_file"
    echo "  -> added PATH entry to: $rc_file"
    touched=1
  done

  if [ "$touched" -eq 0 ]; then
    local default_rc
    case "$(basename "${SHELL:-}")" in
      zsh) default_rc="$HOME/.zshrc" ;;
      bash) default_rc="$HOME/.bash_profile" ;;
      *) default_rc="$HOME/.profile" ;;
    esac
    add_path_block_to_rc_file "$default_rc"
    echo "  -> created and updated: $default_rc"
  fi
}

# Removes the PATH block from every rc file that has it. No-op if absent.
deconfigure_shell_path() {
  local rc_file found=0
  for rc_file in "${SECURE_OPENCODE_RC_FILES[@]}"; do
    if path_block_present "$rc_file"; then
      remove_path_block_from_rc_file "$rc_file"
      echo "  -> removed PATH entry from: $rc_file"
      found=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "  No PATH entry found in shell startup files."
  fi
}

# Prints the highest stable vX.Y.Z tag (no pre-release/CI suffix) for the
# given major version line, e.g. `latest_stable_opencode_tag 2` -> v2.0.14.
# Prints nothing (and returns success) if the line has no stable tag yet or
# the tag list cannot be fetched (offline). Callers rely on the empty-output
# contract to decide on fallbacks; a non-zero return here would abort them
# under set -e before those fallbacks run (which is what happened to
# install.sh whenever the next major line had no stable tag yet).
# Bounded with a low-speed timeout so a dead network fails fast instead of
# hanging opencode.sh on every launch.
latest_stable_opencode_tag() {
  local major="$1"
  # The subshell disables pipefail on purpose: with it inherited, an empty
  # result (no matching tag, or git failing offline) leaves the pipeline
  # non-zero (grep exits 1 on no match, git exits 128 offline), which would
  # surface through the caller's command substitution and trip set -e. tail
  # is the final stage, so the pipeline status is 0 without pipefail
  # regardless of what git/grep did.
  #
  # sort -t . -k 2,2n -k 3,3n is the POSIX-portable equivalent of GNU's
  # `sort -V` for tag-shaped input: the grep above already guarantees
  # exactly vMAJOR.MINOR.PATCH, so the minor and patch fields sort numerically
  # (lexical order would pick v2.0.9 over v2.0.15). macOS's BSD sort lacks
  # -V, so it cannot be used.
  (
    set +o pipefail
    GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=10 \
      git ls-remote --tags "$OPENCODE_UPSTREAM_REPO" "refs/tags/v${major}.*" 2>/dev/null \
      | awk -F'/' '{print $NF}' \
      | grep -E "^v${major}\.[0-9]+\.[0-9]+\$" \
      | sort -t . -k 2,2n -k 3,3n \
      | tail -1
  )
}

# Warns (does not build) if a stable tag exists for the major version line
# after $1: e.g. with OPENCODE_MAJOR=2, a published v3.x.y means a new major
# is available upstream that this wrapper won't pick up on its own.
warn_if_newer_major_opencode_available() {
  local current_major="$1"
  local newer
  newer="$(latest_stable_opencode_tag "$((current_major + 1))")"
  [ -n "$newer" ] && echo "Notice: opencode $newer is available upstream. This wrapper only builds v$current_major.x automatically; bump OPENCODE_MAJOR in src/lib/install-common.sh to move to it." >&2
  return 0
}

# opencode-sandbox:current's org.opencode-sandbox.version label, i.e. which
# upstream tag the currently-installed image was built from. Empty if the
# image doesn't exist yet.
installed_sandbox_image_version() {
  docker image inspect --format "{{ index .Config.Labels \"$OPENCODE_VERSION_LABEL\" }}" "$SECURE_OPENCODE_IMAGE_NAME:current" 2>/dev/null
}

docker_host_arch() {
  case "$(uname -m)" in
    arm64 | aarch64) echo "arm64" ;;
    x86_64 | amd64) echo "x64" ;;
    *) echo "" ;;
  esac
}

# Builds opencode-sandbox compiled from source at the given upstream tag
# (Dockerfile.opencode's builder stage clones and compiles it; see there).
# Tags the result both :$tag and, only on success, repoints :current to it.
build_sandbox_image_for_tag() {
  local dockerfile="$1"
  local build_context="$2"
  local tag="$3"
  local arch
  arch="$(docker_host_arch)"
  if [ -z "$arch" ]; then
    echo "Error: unsupported host architecture '$(uname -m)' for building opencode from source." >&2
    return 1
  fi

  echo "Building opencode $tag from source (github.com/anomalyco/opencode) -- this can take a few minutes..." >&2
  if ! docker build \
    --build-arg "OPENCODE_TAG=$tag" \
    --build-arg "OPENCODE_TARGET=linux-$arch" \
    --label "$OPENCODE_VERSION_LABEL=$tag" \
    -t "$SECURE_OPENCODE_IMAGE_NAME:$tag" \
    -f "$dockerfile" "$build_context"; then
    return 1
  fi
  docker tag "$SECURE_OPENCODE_IMAGE_NAME:$tag" "$SECURE_OPENCODE_IMAGE_NAME:current"
}

# Used by opencode.sh on every launch: builds the latest stable opencode v2
# release only if it isn't already what :current was last built from. On
# build failure, falls back to whatever :current already points at (a prior
# successful build) with a warning; only errors out if there is no previous
# build to fall back to (or Docker itself isn't available).
ensure_sandbox_image_current() {
  local dockerfile="$1"
  local build_context="$2"

  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker is required to run the sandboxed opencode." >&2
    return 1
  fi

  local current
  current="$(installed_sandbox_image_version)"

  local latest
  latest="$(latest_stable_opencode_tag "$OPENCODE_MAJOR")"
  if [ -z "$latest" ]; then
    echo "Warning: could not resolve the latest stable opencode v$OPENCODE_MAJOR release from $OPENCODE_UPSTREAM_REPO (offline?)." >&2
    if [ -n "$current" ]; then
      echo "Continuing with cached build: opencode $current" >&2
      return 0
    fi
    echo "Error: no previously built opencode-sandbox image is available either. Nothing to run." >&2
    return 1
  fi

  warn_if_newer_major_opencode_available "$OPENCODE_MAJOR"

  if [ "$current" = "$latest" ]; then
    return 0
  fi

  if build_sandbox_image_for_tag "$dockerfile" "$build_context" "$latest"; then
    return 0
  fi

  echo "Warning: build of opencode $latest failed; falling back to the last successful local build." >&2
  if [ -n "$current" ]; then
    echo "Continuing with cached build: opencode $current" >&2
    return 0
  fi

  echo "Error: no previously built opencode-sandbox image is available either. Nothing to run." >&2
  return 1
}

# Used by install.sh: always builds the latest stable release from scratch,
# so a Dockerfile edit made since the last install is picked up even when the
# upstream version hasn't changed (ensure_sandbox_image_current would skip
# the build in that case). No-op if Docker isn't installed; install.sh
# already warns about that separately.
force_rebuild_sandbox_image() {
  local dockerfile="$1"
  local build_context="$2"

  command -v docker >/dev/null 2>&1 || return 0

  local latest
  latest="$(latest_stable_opencode_tag "$OPENCODE_MAJOR")"
  if [ -z "$latest" ]; then
    echo "Error: could not resolve the latest stable opencode v$OPENCODE_MAJOR release from $OPENCODE_UPSTREAM_REPO." >&2
    return 1
  fi
  warn_if_newer_major_opencode_available "$OPENCODE_MAJOR"

  build_sandbox_image_for_tag "$dockerfile" "$build_context" "$latest"
}
