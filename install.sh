#!/usr/bin/env bash
# Installs the secure-opencode sandbox wrapper so that 'opencode' resolves to it.
#
# The native opencode install is left completely untouched, so its own
# upgrade path keeps working exactly as before. Instead, this creates a
# dedicated directory (~/.secure-opencode/bin) containing:
#   - opencode          -> src/opencode.sh (the Docker sandbox wrapper)
#   - opencode-original -> the native binary (whatever it currently resolves to)
# and prepends that directory to PATH via the shell startup files, so
# 'opencode' always resolves to the sandbox wrapper first.
#
# Run restore.sh to undo this.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WRAPPER_SCRIPT="$SCRIPT_DIR/src/opencode.sh"
PATH_UTILS="$SCRIPT_DIR/src/lib/path-utils.sh"
INSTALL_COMMON="$SCRIPT_DIR/src/lib/install-common.sh"
CONTAINER_DIR="$SCRIPT_DIR/src/container"
DOCKERFILE="$CONTAINER_DIR/Dockerfile.opencode"

for lib in "$PATH_UTILS" "$INSTALL_COMMON"; do
  if [ ! -f "$lib" ]; then
    echo "Error: could not find required file at $lib" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$lib"
done

require_supported_os

if [ ! -f "$WRAPPER_SCRIPT" ]; then
  echo "Error: could not find wrapper script at $WRAPPER_SCRIPT" >&2
  exit 1
fi
chmod +x "$WRAPPER_SCRIPT"

if [ ! -f "$DOCKERFILE" ]; then
  echo "Error: could not find Dockerfile at $DOCKERFILE" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Warning: docker not found in PATH. The sandboxed 'opencode' command requires Docker to run; install it before using opencode." >&2
fi

SHIM_DIR="$SECURE_OPENCODE_SHIM_DIR"
SHIM_OPENCODE="$SHIM_DIR/opencode"
SHIM_OPENCODE_ORIGINAL="$SHIM_DIR/opencode-original"
WRAPPER_REAL="$(resolve_path "$WRAPPER_SCRIPT")"

SHIM_DIR_REAL="$SHIM_DIR"
if [ -d "$SHIM_DIR" ]; then
  SHIM_DIR_REAL="$(cd "$SHIM_DIR" && pwd -P)"
fi

# Already fully installed: report and exit without touching anything.
if [ -L "$SHIM_OPENCODE" ] && [ "$(resolve_path "$SHIM_OPENCODE")" = "$WRAPPER_REAL" ] \
   && [ -L "$SHIM_OPENCODE_ORIGINAL" ] && any_rc_has_path_block; then
  echo "Already installed:"
  echo "  $SHIM_OPENCODE -> $WRAPPER_SCRIPT"
  echo "  $SHIM_OPENCODE_ORIGINAL -> $(readlink "$SHIM_OPENCODE_ORIGINAL")"
  echo "PATH entry already present in shell startup files."
  # A rebuild failure here (e.g. offline) must not fail the re-run: the
  # installation is complete and the existing image keeps working. A fresh
  # install below still hard-fails, because it has no image to fall back to.
  force_rebuild_sandbox_image "$DOCKERFILE" "$CONTAINER_DIR" \
    || echo "Warning: could not rebuild the sandbox image now; keeping the current one."
  exit 0
fi

# Don't clobber anything at these two paths that we don't manage ourselves.
if [ -e "$SHIM_OPENCODE" ] && [ ! -L "$SHIM_OPENCODE" ]; then
  echo "Error: $SHIM_OPENCODE exists and is not a symlink managed by this installer. Inspect and remove it manually before re-running install.sh." >&2
  exit 1
fi
if [ -e "$SHIM_OPENCODE_ORIGINAL" ] && [ ! -L "$SHIM_OPENCODE_ORIGINAL" ]; then
  echo "Error: $SHIM_OPENCODE_ORIGINAL exists and is not a symlink managed by this installer. Inspect and remove it manually before re-running install.sh." >&2
  exit 1
fi

if ! NATIVE_OPENCODE_PATH="$(find_native_opencode "$SHIM_DIR_REAL")"; then
  echo "Error: no native 'opencode' command found in PATH (outside of $SHIM_DIR)." >&2
  echo "Install the native opencode CLI first, then re-run this script." >&2
  exit 1
fi

if ! mkdir -p "$SHIM_DIR" 2>/dev/null; then
  echo "Error: could not create $SHIM_DIR. Check permissions on $HOME." >&2
  exit 1
fi

echo "Found native opencode at: $NATIVE_OPENCODE_PATH"

ln -sf "$NATIVE_OPENCODE_PATH" "$SHIM_OPENCODE_ORIGINAL"
echo "  -> linked: $SHIM_OPENCODE_ORIGINAL -> $NATIVE_OPENCODE_PATH"

ln -sf "$WRAPPER_SCRIPT" "$SHIM_OPENCODE"
echo "  -> linked: $SHIM_OPENCODE -> $WRAPPER_SCRIPT"

if [ "$(resolve_path "$SHIM_OPENCODE")" != "$WRAPPER_REAL" ]; then
  echo "Error: verification failed, '$SHIM_OPENCODE' does not resolve to $WRAPPER_SCRIPT after linking." >&2
  exit 1
fi

echo "Configuring PATH..."
configure_shell_path

force_rebuild_sandbox_image "$DOCKERFILE" "$CONTAINER_DIR"

cat <<EOF

Install complete. The native opencode install at $NATIVE_OPENCODE_PATH is untouched,
so its own updates keep working normally.

  $SHIM_OPENCODE          -> $WRAPPER_SCRIPT (sandboxed, runs in Docker)
  $SHIM_OPENCODE_ORIGINAL -> $NATIVE_OPENCODE_PATH (native binary)

Start a new shell (or run 'source <rc file>' / 'export PATH="$SHIM_DIR:\$PATH"') for
'opencode' to resolve to the sandbox wrapper in your current session.

Run '$SCRIPT_DIR/restore.sh' at any time to undo this.
EOF
