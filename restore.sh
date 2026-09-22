#!/usr/bin/env bash
# Reverts the changes made by install.sh: removes the ~/.secure-opencode/bin
# shims and the PATH entry from the shell startup files. The native opencode
# install was never touched by install.sh, so there is nothing to restore
# there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WRAPPER_SCRIPT="$SCRIPT_DIR/src/opencode.sh"
PATH_UTILS="$SCRIPT_DIR/src/lib/path-utils.sh"
INSTALL_COMMON="$SCRIPT_DIR/src/lib/install-common.sh"

for lib in "$PATH_UTILS" "$INSTALL_COMMON"; do
  if [ ! -f "$lib" ]; then
    echo "Error: could not find required file at $lib" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$lib"
done

require_supported_os

SHIM_DIR="$SECURE_OPENCODE_SHIM_DIR"
SHIM_OPENCODE="$SHIM_DIR/opencode"
SHIM_OPENCODE_ORIGINAL="$SHIM_DIR/opencode-original"
WRAPPER_REAL="$(resolve_path "$WRAPPER_SCRIPT")"

if [ ! -L "$SHIM_OPENCODE" ] || [ "$(resolve_path "$SHIM_OPENCODE")" != "$WRAPPER_REAL" ]; then
  echo "Error: $SHIM_OPENCODE does not point to the secure-opencode wrapper ($WRAPPER_SCRIPT)." >&2
  echo "Nothing to restore." >&2
  exit 1
fi

rm -f "$SHIM_OPENCODE"
echo "Removed: $SHIM_OPENCODE"

if [ -e "$SHIM_OPENCODE_ORIGINAL" ]; then
  rm -f "$SHIM_OPENCODE_ORIGINAL"
  echo "Removed: $SHIM_OPENCODE_ORIGINAL"
fi

if [ -d "$SHIM_DIR" ] && [ -z "$(ls -A "$SHIM_DIR")" ]; then
  rmdir "$SHIM_DIR"
  echo "Removed empty directory: $SHIM_DIR"

  SHIM_PARENT_DIR="$(dirname "$SHIM_DIR")"
  if [ -d "$SHIM_PARENT_DIR" ] && [ -z "$(ls -A "$SHIM_PARENT_DIR")" ]; then
    rmdir "$SHIM_PARENT_DIR"
    echo "Removed empty directory: $SHIM_PARENT_DIR"
  fi
fi

echo "Removing PATH entry..."
deconfigure_shell_path

cat <<EOF

Restore complete. The native opencode install was never modified. Start a new
shell (or re-source your shell startup files) for 'opencode' to resolve to it
again.
EOF
