#!/bin/sh
# Entrypoint for the opencode sandbox image. Runs under the image's /bin/sh
# (dash), so it stays POSIX.
#
# src/opencode.sh bind-mounts the four opencode directories (config/data/
# state/cache) whole, so everything in them persists to the host -- and the
# one kind of content that must NOT be adopted from a native host run is the
# per-machine coordination state in the state dir:
#
#   service*.json*  the background-service registration (pid, url) and its
#                   .tmp / .pty-handoff sidecars
#   locks/          the file locks
#
# It is deleted at startup and again on exit:
#
#  - startup: opencode inside finds no registration, so it starts its own
#    private service (a new registration with a container-local pid/url).
#    The host's running service monitors the same file through the mount,
#    notices the replacement, and terminates itself within seconds.
#  - exit: the registration is deleted again (the container teardown kills
#    the service itself), so a native run afterwards starts a fresh service
#    instead of adopting a dead one.
#
# The background-service *config* (config dir: hostname, port, password) is
# intentionally kept: the container reuses the host's password when one
# exists, and a generated one persists through the mount.
#
# Paths are $HOME-relative: opencode resolves its dirs the same way, and the
# wrapper runs the container with -e HOME=/home/node.
set -u

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"

mkdir -p "$config_dir" "$data_dir" "$state_dir" "$cache_dir"

# Deletes the background-service registration files and the file locks. Safe
# to call when nothing is there (rm -f / -rf).
cleanup_service_files() {
  rm -f "$state_dir"/service*.json*
  rm -rf "$state_dir/locks"
}

cleanup_service_files

# The "you are in a sandbox" banner plugin, baked into the image at
# /opt/sandbox-banner. It is declared through OPENCODE_CONFIG_CONTENT -- a
# config document opencode loads on top of the others (plugins from every
# config source are unioned, so a host plugin list is never shadowed) -- and
# is never written into the mounted config dir: anything placed there would
# be picked up by a native `opencode` on the host too, and a banner claiming
# "sandbox" for a session that is not sandboxed is worse than no banner.
banner_src="${SECURE_OPENCODE_BANNER_SRC:-/opt/sandbox-banner}"
if [ ! -d "$banner_src" ]; then
  echo "Error: sandbox banner source $banner_src not found in the image; the sandbox indicator would be missing, refusing to start" >&2
  exit 1
fi

# Merge with a content config the caller set itself (`docker run -e
# OPENCODE_CONFIG_CONTENT=...`): the banner is appended to its plugin list
# instead of replacing it, and unparseable content fails loudly rather than
# silently dropping the configuration.
existing_content="${OPENCODE_CONFIG_CONTENT:-}"
[ -n "$existing_content" ] || existing_content='{}'
if ! merged_content="$(printf '%s' "$existing_content" \
    | jq -c --arg banner "$banner_src" \
        'if ((.plugins // []) | index($banner)) then . else .plugins = ((.plugins // []) + [$banner]) end')"; then
  echo "Error: could not merge the sandbox banner plugin into OPENCODE_CONFIG_CONTENT; refusing to start (jq reported the problem above)" >&2
  exit 1
fi
export OPENCODE_CONFIG_CONTENT="$merged_content"

# An asynchronous command gets its stdin redirected from /dev/null by POSIX
# shells (both dash here and bash on a test host), which would cut the TUI off
# from the terminal: it writes its queries (background/foreground color,
# capabilities, mouse) to the pty but never reads the replies, which the tty
# line discipline then echoes back as raw escape sequences. fd 3 keeps the
# entrypoint's own stdin across that redirect; opencode reads it and closes
# the extra descriptor.
exec 3<&0
opencode "$@" <&3 3<&- &
child=$!
trap 'kill -TERM "$child" 2>/dev/null' TERM
trap 'kill -INT "$child" 2>/dev/null' INT

status=0
while :; do
  wait "$child"
  status=$?
  # A trapped signal makes wait return 128+signum before the child has
  # necessarily exited: re-wait while it is still running.
  if [ "$status" -gt 128 ] && kill -0 "$child" 2>/dev/null; then
    continue
  fi
  # The child may have exited in the same moment the signal was delivered:
  # try to recover its real exit status (127 means it is no longer waitable).
  if [ "$status" -gt 128 ]; then
    wait "$child" 2>/dev/null
    real_status=$?
    if [ "$real_status" -ne 127 ]; then
      status=$real_status
    fi
  fi
  break
done

cleanup_service_files
exit "$status"
