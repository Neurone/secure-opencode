#!/usr/bin/env bash
# Integration tests for src/opencode.sh (the Docker sandbox wrapper), driven
# with fake `docker` and `git` executables so no real Docker daemon, network
# access, or installed opencode is needed.
#
# Usage: bash tests/test-opencode-wrapper.sh
#
# The fake tools are controlled via env vars (documented where they are
# written below). Each scenario gets its own record directory holding the
# args the fake docker saw, plus the wrapper's stdout/stderr.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WRAPPER="$REPO_DIR/src/opencode.sh"
INSTALL_SH="$REPO_DIR/install.sh"
RESTORE_SH="$REPO_DIR/restore.sh"
REAL_GIT="$(command -v git)"

# PATH with every directory that has its own 'opencode' executable stripped
# out, so S10b (install without a native opencode) is not accidentally
# satisfied by a real opencode install on the host running these tests.
PATH_WITHOUT_OPENCODE="$(
  IFS=':'
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    [ -x "$dir/opencode" ] && continue
    printf '%s:' "$dir"
  done
)"

if [ -z "$REAL_GIT" ]; then
  echo "Error: real git not found in PATH (needed by the fake git for 'git config')." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required to run these tests (it is also a wrapper requirement)." >&2
  exit 1
fi

T="$(mktemp -d)"
#trap 'rm -rf "$T"' EXIT

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Assert an exact line exists in a file.
has_line() {
  if grep -Fxq -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 (missing line: $2)"; fi
}
# Assert an exact line does NOT exist in a file.
has_no_line() {
  if grep -Fxq -- "$2" "$1" 2>/dev/null; then fail "$3 (unexpected line: $2)"; else pass "$3"; fi
}
# Assert at least one line matches an extended regex.
has_pattern() {
  if grep -Eq -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 (no match for: $2)"; fi
}
# Assert no line matches an extended regex.
has_no_pattern() {
  if grep -Eq -- "$2" "$1" 2>/dev/null; then fail "$3 (unexpected match: $2)"; else pass "$3"; fi
}
# Assert an exact line occurs exactly once.
occurs_once() {
  local n
  n="$(grep -Fc -- "$2" "$1" 2>/dev/null || true)"
  if [ "$n" = "1" ]; then pass "$3"; else fail "$3 (expected exactly 1 occurrence, got ${n:-0})"; fi
}
# Assert a file's (entire) content equals a string.
content_is() {
  local actual
  actual="$(cat "$1" 2>/dev/null || echo __missing__)"
  if [ "$actual" = "$2" ]; then pass "$3"; else fail "$3 (content: '$actual', expected '$2')"; fi
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

mkdir -p \
  "$T/bin" \
  "$T/native" \
  "$T/home/.config/opencode/agents" \
  "$T/home/.config/opencode/cfgplugin" \
  "$T/home/.local/share/opencode/log" \
  "$T/home/.local/state/opencode/locks" \
  "$T/home/.cache/opencode/npm" \
  "$T/project" \
  "$T/plugins" \
  "$T/record"

# --- fake docker -----------------------------------------------------------
# Env:
#   FAKE_DOCKER_RECORD  record dir (required)
#   FAKE_IMAGE_STATE    "present" (default) or "absent" for `image inspect`
#   FAKE_IMAGE_VERSION  version label the image reports (present state)
#   FAKE_BUILD_FAIL     "1" to make `docker build` fail
cat > "$T/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  image)
    if [ "${2:-}" != "inspect" ]; then
      echo "fake docker: unhandled: $*" >&2
      exit 1
    fi
    if [ "${FAKE_IMAGE_STATE:-present}" = "present" ] && [ -n "${FAKE_IMAGE_VERSION:-}" ]; then
      printf '%s\n' "$FAKE_IMAGE_VERSION"
      exit 0
    fi
    echo "Error: No such image: opencode-sandbox:current" >&2
    exit 1
    ;;
  build)
    printf '%s\n' "$@" >> "${FAKE_DOCKER_RECORD:?}/build.args"
    if [ "${FAKE_BUILD_FAIL:-0}" = "1" ]; then
      echo "fake build failure" >&2
      exit 1
    fi
    exit 0
    ;;
  tag)
    printf '%s\n' "$@" >> "${FAKE_DOCKER_RECORD:?}/tag.args"
    exit 0
    ;;
  run)
    # Merge `-v <spec>` and `-e <value>` pairs into single lines so tests can
    # assert on them as one unit (docker receives them as two args).
    {
      prev=""
      for arg in "$@"; do
        if [ -n "$prev" ]; then
          if [ "$prev" = "-v" ] || [ "$prev" = "-e" ]; then
            printf '%s\n' "$prev $arg"
            prev=""
          else
            printf '%s\n' "$prev"
            prev="$arg"
          fi
        else
          prev="$arg"
        fi
      done
      [ -n "$prev" ] && printf '%s\n' "$prev"
    } > "${FAKE_DOCKER_RECORD:?}/run.args"
    # While the wrapper is still alive, capture whether the mounted gitconfig
    # copy still contains a [credential] section (it must not).
    while IFS= read -r line; do
      case "$line" in
        "-v "*:/home/node/.gitconfig:ro)
          src="${line#-v }"
          src="${src%%:*}"
          if grep -q '^\[credential\]' "$src" 2>/dev/null; then
            echo 1 > "${FAKE_DOCKER_RECORD:?}/gitconfig-credential-count"
          else
            echo 0 > "${FAKE_DOCKER_RECORD:?}/gitconfig-credential-count"
          fi
          ;;
      esac
    done < "${FAKE_DOCKER_RECORD:?}/run.args"
    exit 0
    ;;
  *)
    echo "fake docker: unhandled: $*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$T/bin/docker"

# --- fake git ---------------------------------------------------------------
# Env:
#   FAKE_GIT_FAIL   "1" to make ls-remote fail (simulated offline)
#   FAKE_TAGS_V2    space-separated v2 tags to report (one ls-remote line each)
#   FAKE_TAGS_V3    space-separated v3 tags to report
# Every other subcommand (the wrapper uses `git config` for the filtered
# gitconfig copy) delegates to the real git.
cat > "$T/bin/git" <<FAKE
#!/usr/bin/env bash
case "\${1:-}" in
  ls-remote)
    if [ "\${FAKE_GIT_FAIL:-0}" = "1" ]; then
      echo "fatal: unable to access repo (simulated offline)" >&2
      exit 128
    fi
    for arg in "\$@"; do
      case "\$arg" in
        refs/tags/v2.*) [ -n "\${FAKE_TAGS_V2:-}" ] && printf 'deadbeef\trefs/tags/%s\n' \$FAKE_TAGS_V2 ;;
        refs/tags/v3.*) [ -n "\${FAKE_TAGS_V3:-}" ] && printf 'deadbeef\trefs/tags/%s\n' \$FAKE_TAGS_V3 ;;
      esac
    done
    exit 0
    ;;
  *)
    exec $REAL_GIT "\$@"
    ;;
esac
FAKE
chmod +x "$T/bin/git"

# --- fake native opencode (for install.sh tests) ----------------------------
printf '#!/usr/bin/env bash\necho "native opencode"\n' > "$T/native/opencode"
chmod +x "$T/native/opencode"

# --- host fixtures: config / data / state / cache dirs -----------------------
# Global config, v2 "plugins" key: an external dir, a {package, options}
# object entry inside the config dir, and a path that does not exist.
cat > "$T/home/.config/opencode/opencode.json" <<EOF
{
  "plugins": [
    "$T/plugins/ext-global",
    {"package": "$T/home/.config/opencode/cfgplugin", "options": {"opt": 1}},
    "$T/plugins/missing-plugin"
  ]
}
EOF
echo "cfg plugin" > "$T/home/.config/opencode/cfgplugin/index.js"
echo "service pw" > "$T/home/.config/opencode/service.json"
# v2's CLI/TUI settings file (theme, keybinds, the plugins list 'plugin add'
# records); it lives in the config dir and is part of the whole-dir mount.
cat > "$T/home/.config/opencode/cli.json" <<'EOF'
{
  "theme": "tokyo-night"
}
EOF
echo "agent" > "$T/home/.config/opencode/agents/agent1.md"

# Data dir: the session database plus the v1-style credentials file; all of
# it rides along inside the whole-dir mount (see README.md, Credentials).
echo "creds" > "$T/home/.local/share/opencode/auth.json"
echo "db" > "$T/home/.local/share/opencode/opencode.db"
echo "wal" > "$T/home/.local/share/opencode/opencode.db-wal"
echo "log" > "$T/home/.local/share/opencode/log/session1.log"

# State dir, v2 layout: the background-service registration (with its pty
# handoff sidecar), the file locks, and an ordinary state file that the
# entrypoint must leave alone.
echo "service pw" > "$T/home/.local/state/opencode/service.json"
echo "pty" > "$T/home/.local/state/opencode/service.json.pty-handoff"
echo "kv" > "$T/home/.local/state/opencode/kv.json"
echo "lock" > "$T/home/.local/state/opencode/locks/l1"

echo "npm cache" > "$T/home/.cache/opencode/npm/pkgsomeplugin"

cat > "$T/home/.gitconfig" <<'EOF'
[user]
	name = Test User
	email = test@example.com
[credential]
	helper = osxkeychain
EOF

# --- project fixture: JSONC on purpose (comments + trailing commas) ---------
# "ext-global" is deliberately referenced in BOTH this file and the global
# opencode.json, to check the wrapper does not mount it twice. The v1-style
# "plugin" key is kept on purpose: v2 still decodes it, and the wrapper must.
cat > "$T/project/opencode.jsonc" <<EOF
{
  // project-level config
  "plugin": [
    "$T/plugins/ext-global",
    "$T/plugins/proj-ext", /* block comment mid-array */
    "./relative-plugin.js", // relative entries need no mount
    "@scope/npm-plugin", // npm names install into the cache dir; nothing to mount
  ],
  "provider": {
    "lmstudio": {
      "options": {
        "baseURL": "http://host.docker.internal:1234/v1 // not a comment /* nor this */",
      },
    },
  },
}
EOF
echo "main" > "$T/project/main.txt"

# --- external plugins (absolute paths outside config + project dirs) --------
# Directories, as v2 loads them (a bare file entry is rejected upstream with
# a warning; the wrapper still mounts a found file, and ext-config.js below
# exercises exactly that branch via the OPENCODE_CONFIG fixture).
mkdir -p "$T/plugins/ext-global" "$T/plugins/proj-ext"
echo "global ext" > "$T/plugins/ext-global/index.js"
echo "proj ext" > "$T/plugins/proj-ext/index.js"
echo "cfg ext" > "$T/plugins/ext-config.js"

# --- OPENCODE_CONFIG fixture: extra config file outside both dirs -----------
cat > "$T/custom-oc.json" <<EOF
{
  "plugin": ["$T/plugins/ext-config.js"]
}
EOF

# Same SELinux relabeling rule as src/opencode.sh, to build expected mounts.
MOUNT_SUFFIX=""
if [ "$(uname -s)" = "Linux" ] && command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  MOUNT_SUFFIX=":z"
fi
CA_BUNDLE_CANDIDATE=""
for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
  if [ -s "$candidate" ]; then CA_BUNDLE_CANDIDATE="$candidate"; break; fi
done

# Whether src/opencode.sh adds a CA-bundle mount. The Linux candidates above
# find nothing on macOS, where the wrapper exports the keychain trust store
# into a tmpdir of its own instead, so the check is mirrored here to keep the
# mount allowlist in S1 exact on both platforms.
expect_ca_bundle_mount() {
  case "$(uname -s)" in
    Darwin)
      command -v security >/dev/null 2>&1 || return 1
      local exported
      exported="$(mktemp)"
      if { security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain \
               security find-certificate -a -p /Library/Keychains/System.keychain; } >"$exported" 2>/dev/null \
         && [ -s "$exported" ]; then
        rm -f "$exported"
        return 0
      fi
      rm -f "$exported"
      return 1
      ;;
    *)
      [ -n "$CA_BUNDLE_CANDIDATE" ]
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Run helpers
# ---------------------------------------------------------------------------

# run_wrapper <record-dir> [wrapper args...]
# Runs the wrapper from the fixture project dir with a controlled environment.
# FAKE_* / OPENCODE_CONFIG / WRAPPER_HOME env vars set by the caller are
# forwarded (WRAPPER_HOME overrides the default $T/home fixture home).
run_wrapper() {
  local record="$1"
  shift
  mkdir -p "$record"
  rm -f "$record"/run.args "$record"/build.args "$record"/tag.args \
        "$record"/gitconfig-credential-count "$record"/stdout.txt "$record"/stderr.txt
  (
    cd "$T/project" || exit 99
    env HOME="${WRAPPER_HOME:-$T/home}" \
        SHELL=/bin/zsh \
        TZ=Europe/Rome \
        XDG_CONFIG_HOME= XDG_DATA_HOME= XDG_STATE_HOME= \
        OPENCODE_CONFIG="${OPENCODE_CONFIG:-}" \
        FAKE_DOCKER_RECORD="$record" \
        PATH="$T/bin:$PATH" \
        bash "$WRAPPER" "$@" >"$record/stdout.txt" 2>"$record/stderr.txt"
  )
}

# run_install <record-dir> <home-dir>
run_install() {
  local record="$1" home_dir="$2"
  mkdir -p "$record"
  rm -f "$record"/build.args "$record"/tag.args "$record"/stdout.txt "$record"/stderr.txt
  env HOME="$home_dir" \
      SHELL=/bin/zsh \
      FAKE_DOCKER_RECORD="$record" \
      PATH="$T/bin:$T/native:$PATH" \
      bash "$INSTALL_SH" >"$record/stdout.txt" 2>"$record/stderr.txt"
}

# run_restore <record-dir> <home-dir>
run_restore() {
  local record="$1" home_dir="$2"
  mkdir -p "$record"
  env HOME="$home_dir" \
      SHELL=/bin/zsh \
      PATH="$T/bin:$PATH" \
      bash "$RESTORE_SH" >"$record/stdout.txt" 2>"$record/stderr.txt"
}

# ---------------------------------------------------------------------------
# S1: up-to-date image -> plain run, full mount allowlist
# ---------------------------------------------------------------------------
echo "=== S1: up-to-date image, full mount allowlist ==="
REC="$T/record/s1"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG= run_wrapper "$REC" --version
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
if [ -e "$REC/build.args" ]; then fail "no image build"; else pass "no image build"; fi
has_line "$REC/run.args" "-v $T/project:$T/project$MOUNT_SUFFIX" "project dir mounted"
has_line "$REC/run.args" "-v $T/home/.config/opencode:/home/node/.config/opencode" "config dir mounted whole"
has_line "$REC/run.args" "-v $T/home/.local/share/opencode:/home/node/.local/share/opencode" "data dir mounted whole"
has_line "$REC/run.args" "-v $T/home/.local/state/opencode:/home/node/.local/state/opencode" "state dir mounted whole"
has_line "$REC/run.args" "-v $T/home/.cache/opencode:/home/node/.cache/opencode" "cache dir mounted whole"
has_line "$REC/run.args" "-v $T/home/.config/opencode/opencode.json:/home/node/.config/opencode/opencode.json:ro" "global opencode.json overlaid read-only"
has_no_line "$REC/run.args" "-v $T/home/.config/opencode/opencode.jsonc:/home/node/.config/opencode/opencode.jsonc:ro" "no overlay where the host file is absent"
has_line "$REC/run.args" "-v $T/plugins/ext-global:$T/plugins/ext-global:ro" "external plugin dir (global config) mounted read-only"
has_line "$REC/run.args" "-v $T/plugins/proj-ext:$T/plugins/proj-ext:ro" "external plugin dir (project JSONC config) mounted read-only"
occurs_once "$REC/run.args" "-v $T/plugins/ext-global:$T/plugins/ext-global:ro" "plugin referenced in two configs mounted exactly once"
has_line "$REC/run.args" "-e TZ=Europe/Rome" "TZ forwarded"
has_line "$REC/run.args" "-e HOME=/home/node" "HOME overridden"
has_line "$REC/run.args" "-e OPENCODE_LMSTUDIO_BASEURL=http://host.docker.internal:1234/v1" "OPENCODE_LMSTUDIO_BASEURL set"
has_line "$REC/run.args" "--add-host=host.docker.internal:host-gateway" "host.docker.internal add-host"
has_line "$REC/run.args" "opencode-sandbox:current" "image reference"
has_line "$REC/run.args" "--version" "arguments passed through"
has_pattern "$REC/run.args" '^-v /[^:]+:/home/node/\.gitconfig:ro$' "filtered gitconfig mounted read-only"
content_is "$REC/gitconfig-credential-count" "0" "gitconfig credential section stripped"
# The mount list is the allowlist: exactly the expected set, nothing else.
# The sensitive files (auth.json, opencode.db*, service.json, cli.json,
# locks/...) ride along inside the whole-dir mounts by design (README.md,
# Credentials); no sensitive file is ever mounted per-file.
if expect_ca_bundle_mount; then
  EXPECTED_MOUNTS=10
  if [ "$(uname -s)" = "Darwin" ]; then
    has_pattern "$REC/run.args" '^-v .*ca-certificates\.crt:/etc/ssl/certs/ca-certificates\.crt:ro$' "host CA bundle mounted (from the macOS keychain)"
  else
    has_line "$REC/run.args" "-v $CA_BUNDLE_CANDIDATE:/etc/ssl/certs/ca-certificates.crt:ro" "host CA bundle mounted"
  fi
else
  EXPECTED_MOUNTS=9
  has_no_pattern "$REC/run.args" 'ca-certificates\.crt' "no CA bundle mount"
fi
ACTUAL_MOUNTS=$(grep -c '^-v ' "$REC/run.args")
if [ "$ACTUAL_MOUNTS" = "$EXPECTED_MOUNTS" ]; then
  pass "mount list is exactly the expected allowlist ($ACTUAL_MOUNTS mounts)"
else
  fail "mount list is exactly the expected allowlist (got $ACTUAL_MOUNTS, expected $EXPECTED_MOUNTS)"
fi
has_no_pattern "$REC/run.args" 'missing-plugin' "missing plugin NOT mounted"
has_pattern "$REC/stderr.txt" "Plugin entries available in the container" "plugin manifest printed"
has_pattern "$REC/stderr.txt" "missing-plugin" "missing plugin warned about"

# ---------------------------------------------------------------------------
# S2: newer upstream release -> build then run (numeric tag sort check)
# ---------------------------------------------------------------------------
echo "=== S2: newer upstream release, build then run ==="
REC="$T/record/s2"
FAKE_TAGS_V2="v2.0.9 v2.0.15 v2.1.0" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG= run_wrapper "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_line "$REC/build.args" "OPENCODE_TAG=v2.1.0" "highest tag picked (numeric sort, not lexical)"
has_line "$REC/tag.args" "opencode-sandbox:v2.1.0" "built image tagged with release tag"
has_line "$REC/tag.args" "opencode-sandbox:current" ":current repointed"
if [ -e "$REC/run.args" ]; then pass "container run proceeded"; else fail "container run proceeded"; fi

# ---------------------------------------------------------------------------
# S3: offline, cached image available -> continue with cache
# ---------------------------------------------------------------------------
echo "=== S3: offline with cached image ==="
REC="$T/record/s3"
FAKE_TAGS_V2= FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=1 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG= run_wrapper "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "could not resolve the latest stable" "offline warning printed"
has_pattern "$REC/stderr.txt" "Continuing with cached build" "fell back to cached image"
if [ -e "$REC/run.args" ]; then pass "container run proceeded"; else fail "container run proceeded"; fi

# ---------------------------------------------------------------------------
# S4: offline, no image -> clean error
# ---------------------------------------------------------------------------
echo "=== S4: offline, no image ==="
REC="$T/record/s4"
FAKE_TAGS_V2= FAKE_IMAGE_STATE=absent FAKE_GIT_FAIL=1 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG= run_wrapper "$REC"
rc=$?
if [ "$rc" = 1 ]; then pass "exit 1"; else fail "exit 1 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "no previously built opencode-sandbox image" "clean error message"
if [ -e "$REC/run.args" ]; then fail "no container run"; else pass "no container run"; fi

# ---------------------------------------------------------------------------
# S5: online but no stable tag on the line, cached image -> continue
# ---------------------------------------------------------------------------
echo "=== S5: no stable v2 tag, cached image ==="
REC="$T/record/s5"
FAKE_TAGS_V2= FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG= run_wrapper "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "could not resolve the latest stable" "warning printed"
has_pattern "$REC/stderr.txt" "Continuing with cached build" "fell back to cached image"
if [ -e "$REC/run.args" ]; then pass "container run proceeded"; else fail "container run proceeded"; fi

# ---------------------------------------------------------------------------
# S6: newer major available -> notice only
# ---------------------------------------------------------------------------
echo "=== S6: newer major available, notice only ==="
REC="$T/record/s6"
FAKE_TAGS_V2="v2.0.14" FAKE_TAGS_V3="v3.1.0" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG= run_wrapper "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "opencode v3\.1\.0 is available upstream" "newer-major notice printed"
if [ -e "$REC/build.args" ]; then fail "no build for the newer major"; else pass "no build for the newer major"; fi

# ---------------------------------------------------------------------------
# S7: OPENCODE_CONFIG outside config/project dirs -> file + its plugins mounted
# ---------------------------------------------------------------------------
echo "=== S7: OPENCODE_CONFIG handling ==="
REC="$T/record/s7"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG="$T/custom-oc.json" run_wrapper "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_line "$REC/run.args" "-v $T/custom-oc.json:$T/custom-oc.json:ro" "OPENCODE_CONFIG file mounted read-only"
has_line "$REC/run.args" "-e OPENCODE_CONFIG=$T/custom-oc.json" "OPENCODE_CONFIG forwarded to container"
has_line "$REC/run.args" "-v $T/plugins/ext-config.js:$T/plugins/ext-config.js:ro" "plugin from OPENCODE_CONFIG mounted"

# Baseline run (no extra args, no OPENCODE_CONFIG) to compare against.
REC="$T/record/s7a"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG= run_wrapper "$REC"

# OPENCODE_CONFIG pointing at the global opencode.json adds the env-var
# forward but no mounts and no plugin re-collection (the file is inside the
# mounted config dir), so compare the mount lines only.
REC="$T/record/s7b"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG="$T/home/.config/opencode/opencode.json" run_wrapper "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_line "$REC/run.args" "-e OPENCODE_CONFIG=$T/home/.config/opencode/opencode.json" "OPENCODE_CONFIG forwarded to container"
# Normalizes the volatile mount sources (the wrapper's per-run tmpdir paths)
# so two runs' mount lists can be compared. Reads the list on stdin, as both
# sides of the comparison below pipe it through: taking it from "$1" instead
# would be an unbound variable under `set -u` here (this runs inside a
# pipeline, no argument is passed) and its empty output made the diff compare
# nothing with nothing.
norm() { sed -E -e 's#^-v [^:]+:/home/node/\.gitconfig:ro$#-v GITCFG:/home/node/.gitconfig:ro#' \
                -e 's#^-v [^:]+(/[^:]*)?/ca-certificates\.crt:#-v CACERTS:\1/ca-certificates.crt:#'; }
if diff <(grep '^-v ' "$REC/run.args" | norm) <(grep '^-v ' "$T/record/s7a/run.args" | norm) >/dev/null 2>&1; then
  pass "OPENCODE_CONFIG at global config adds no mounts"
else
  fail "OPENCODE_CONFIG at global config adds no mounts"
fi

# ---------------------------------------------------------------------------
# S8: build failure, cached image -> fallback
# ---------------------------------------------------------------------------
echo "=== S8: build failure with cached image ==="
REC="$T/record/s8"
FAKE_TAGS_V2="v2.0.15" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=1 \
  OPENCODE_CONFIG= run_wrapper "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "falling back to the last successful local build" "build-failure fallback warning"
if [ -e "$REC/run.args" ]; then pass "container run proceeded"; else fail "container run proceeded"; fi

# ---------------------------------------------------------------------------
# S9: build failure, no image -> clean error
# ---------------------------------------------------------------------------
echo "=== S9: build failure, no image ==="
REC="$T/record/s9"
FAKE_TAGS_V2="v2.0.15" FAKE_IMAGE_STATE=absent FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=1 \
  OPENCODE_CONFIG= run_wrapper "$REC"
rc=$?
if [ "$rc" = 1 ]; then pass "exit 1"; else fail "exit 1 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "no previously built opencode-sandbox image" "clean error message"
if [ -e "$REC/run.args" ]; then fail "no container run"; else pass "no container run"; fi

# ---------------------------------------------------------------------------
# S10: install.sh fresh install
# ---------------------------------------------------------------------------
echo "=== S10: fresh install ==="
REC="$T/record/s10"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_STATE=absent FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  run_install "$REC" "$T/home2"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
SHIM="$T/home2/.secure-opencode/bin"
if [ -L "$SHIM/opencode" ] && [ "$(readlink -f "$SHIM/opencode")" = "$(readlink -f "$WRAPPER")" ]; then
  pass "opencode shim links to the wrapper"
else
  fail "opencode shim links to the wrapper"
fi
if [ -L "$SHIM/opencode-original" ] && [ "$(readlink -f "$SHIM/opencode-original")" = "$(readlink -f "$T/native/opencode")" ]; then
  pass "opencode-original shim links to the native binary"
else
  fail "opencode-original shim links to the native binary"
fi
has_pattern "$T/home2/.zshrc" "secure-opencode PATH" "PATH block added to .zshrc (SHELL=/bin/zsh fallback)"
has_line "$REC/build.args" "OPENCODE_TAG=v2.0.14" "image built during install"

# ---------------------------------------------------------------------------
# S10b: install.sh fresh install, no native opencode on PATH -> still works
# ---------------------------------------------------------------------------
echo "=== S10b: fresh install, no native opencode found ==="
REC="$T/record/s10b"
mkdir -p "$T/home2b" "$REC"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_STATE=absent FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  env HOME="$T/home2b" \
      SHELL=/bin/zsh \
      FAKE_DOCKER_RECORD="$REC" \
      PATH="$T/bin:$PATH_WITHOUT_OPENCODE" \
      bash "$INSTALL_SH" >"$REC/stdout.txt" 2>"$REC/stderr.txt"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
SHIM_NO_NATIVE="$T/home2b/.secure-opencode/bin"
if [ -L "$SHIM_NO_NATIVE/opencode" ] && [ "$(readlink -f "$SHIM_NO_NATIVE/opencode")" = "$(readlink -f "$WRAPPER")" ]; then
  pass "opencode shim links to the wrapper without a native opencode"
else
  fail "opencode shim links to the wrapper without a native opencode"
fi
if [ -e "$SHIM_NO_NATIVE/opencode-original" ]; then
  fail "opencode-original NOT created when no native opencode is found"
else
  pass "opencode-original NOT created when no native opencode is found"
fi
has_pattern "$REC/stderr.txt" "no native 'opencode' command found" "warns instead of failing"
has_pattern "$T/home2b/.zshrc" "secure-opencode PATH" "PATH block added even without native opencode"
has_line "$REC/build.args" "OPENCODE_TAG=v2.0.14" "image built during install without native opencode"

# ---------------------------------------------------------------------------
# S11: install.sh already installed + offline -> warning, not failure
# ---------------------------------------------------------------------------
echo "=== S11: re-run install while offline (already installed) ==="
REC="$T/record/s11"
FAKE_TAGS_V2= FAKE_GIT_FAIL=1 FAKE_BUILD_FAIL=0 \
  run_install "$REC" "$T/home2"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_pattern "$REC/stdout.txt" "Already installed" "reported already installed"
has_pattern "$REC/stdout.txt" "Warning" "rebuild failure demoted to a warning"
if [ -L "$SHIM/opencode" ]; then pass "shim still in place"; else fail "shim still in place"; fi

# ---------------------------------------------------------------------------
# S12: install.sh fresh + offline -> hard failure (no image = unusable)
# ---------------------------------------------------------------------------
echo "=== S12: fresh install while offline ==="
REC="$T/record/s12"
FAKE_TAGS_V2= FAKE_IMAGE_STATE=absent FAKE_GIT_FAIL=1 FAKE_BUILD_FAIL=0 \
  run_install "$REC" "$T/home3"
rc=$?
if [ "$rc" = 1 ]; then pass "exit 1"; else fail "exit 1 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "could not resolve the latest stable" "clear error, not a silent death"

# ---------------------------------------------------------------------------
# S13: restore.sh
# ---------------------------------------------------------------------------
echo "=== S13: restore ==="
REC="$T/record/s13"
run_restore "$REC" "$T/home2"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
if [ -e "$SHIM/opencode" ] || [ -e "$SHIM/opencode-original" ]; then
  fail "shims removed"
else
  pass "shims removed"
fi
has_no_pattern "$T/home2/.zshrc" "secure-opencode PATH" "PATH block removed"
if [ -d "$T/home2/.secure-opencode" ]; then fail "empty shim dirs removed"; else pass "empty shim dirs removed"; fi

# ---------------------------------------------------------------------------
# S14: restore.sh without install -> refusal
# ---------------------------------------------------------------------------
echo "=== S14: restore without install ==="
REC="$T/record/s14"
run_restore "$REC" "$T/home4"
rc=$?
if [ "$rc" = 1 ]; then pass "exit 1"; else fail "exit 1 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "Nothing to restore" "refusal message"

# ---------------------------------------------------------------------------
# S15: host config dir without cli.json -> nothing special to do (the config
# dir is mounted whole anyway; v2 creates the file in the container if needed)
# ---------------------------------------------------------------------------
echo "=== S15: no host cli.json, config dir still mounted whole ==="
mkdir -p "$T/home-nocli/.config/opencode"
echo '{}' > "$T/home-nocli/.config/opencode/opencode.json"
REC="$T/record/s15"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG= WRAPPER_HOME="$T/home-nocli" run_wrapper "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_line "$REC/run.args" "-v $T/home-nocli/.config/opencode/opencode.json:/home/node/.config/opencode/opencode.json:ro" "config dir still processed"
has_no_pattern "$REC/run.args" 'cli\.json' "no cli.json line anywhere (it rides along inside the whole-dir mount)"

# ---------------------------------------------------------------------------
# S16: container entrypoint: startup/exit service-file cleanup, banner
# declaration through OPENCODE_CONFIG_CONTENT, argument passthrough, stdin
# inheritance, signal forwarding, status propagation
# ---------------------------------------------------------------------------
echo "=== S16: entrypoint cleanup, banner, run loop, signals ==="
ENTRYPOINT="$REPO_DIR/src/container/entrypoint.sh"
T16="$T/entry"
mkdir -p "$T16/home/.config/opencode" \
         "$T16/home/.local/share/opencode" \
         "$T16/home/.local/state/opencode/locks" \
         "$T16/home/.cache/opencode" \
         "$T16/bin" "$T16/banner-src" "$T16/nohome/home" \
         "$T16/record/s16" "$T16/record/s16content" \
         "$T16/record/s16sig" "$T16/record/s16nobanner" "$T16/record/s16stdin"

# The state dir as left by a native host run: the registration in both
# channel forms, its sidecars, the locks, and an ordinary file that must
# survive the cleanup.
echo "host reg"  > "$T16/home/.local/state/opencode/service.json"
echo "host reg2" > "$T16/home/.local/state/opencode/service-2.json"
echo "sidecar"   > "$T16/home/.local/state/opencode/service.json.pty-handoff"
echo "tmp"       > "$T16/home/.local/state/opencode/service.json.tmp"
echo "lock"      > "$T16/home/.local/state/opencode/locks/l1"
echo "kv"        > "$T16/home/.local/state/opencode/kv.json"
# The config dir: the service CONFIG (hostname/port/password, kept) and the
# CLI settings file (kept; the config dir is mounted whole and writable).
echo "pw" > "$T16/home/.config/opencode/service.json"
printf '{"theme":"host-theme"}\n' > "$T16/home/.config/opencode/cli.json"
# The banner as baked into the image; the test points the entrypoint at it.
echo "idx" > "$T16/banner-src/index.js"
echo "tui" > "$T16/banner-src/tui.js"

cat > "$T16/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
echo "opencode-args: $*"
printf 'running' > "${FAKE_OPENCODE_MARKER:-/dev/null}"
if [ -n "${FAKE_OPENCODE_REGISTER:-}" ]; then
  echo "container reg" > "$FAKE_OPENCODE_REGISTER"
fi
if [ -n "${FAKE_OPENCODE_ENV_RECORD:-}" ]; then
  env | grep '^OPENCODE_CONFIG_CONTENT=' > "$FAKE_OPENCODE_ENV_RECORD"
fi
if [ "${FAKE_OPENCODE_STDIN:-}" = 1 ]; then
  IFS= read -r line && echo "child-stdin:$line"
fi
if [ "${FAKE_OPENCODE_EXIT:-}" = 1 ]; then
  exit "${FAKE_OPENCODE_EXIT_CODE:-0}"
fi
trap 'echo "child-term"; exit 143' TERM
trap 'echo "child-int"; exit 130' INT
while :; do sleep 1; done
FAKE
chmod +x "$T16/bin/opencode"

# A normal run: the child re-registers the service (as the real opencode
# would), then exits; the entrypoint must propagate 0 and clean up.
FAKE_OPENCODE_EXIT=1 FAKE_OPENCODE_EXIT_CODE=0 \
FAKE_OPENCODE_MARKER="$T16/child-marker" \
FAKE_OPENCODE_REGISTER="$T16/home/.local/state/opencode/service.json" \
FAKE_OPENCODE_ENV_RECORD="$T16/record/s16/content-env" \
SECURE_OPENCODE_BANNER_SRC="$T16/banner-src" \
  env HOME="$T16/home" PATH="$T16/bin:$PATH" \
  sh "$ENTRYPOINT" run --print-logs >"$T16/record/s16/stdout.txt" 2>"$T16/record/s16/stderr.txt"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_line "$T16/record/s16/stdout.txt" "opencode-args: run --print-logs" "arguments passed through to opencode"
for f in service.json service-2.json service.json.pty-handoff service.json.tmp; do
  if [ -e "$T16/home/.local/state/opencode/$f" ]; then
    fail "registration files removed (startup + exit cleanup): $f"
  else
    pass "registration files removed (startup + exit cleanup): $f"
  fi
done
if [ -e "$T16/home/.local/state/opencode/locks" ]; then
  fail "locks/ removed (startup + exit cleanup)"
else
  pass "locks/ removed (startup + exit cleanup)"
fi
content_is "$T16/home/.local/state/opencode/kv.json" "kv" "ordinary state file kept"
content_is "$T16/home/.config/opencode/service.json" "pw" "service config (config dir) kept"
content_is "$T16/home/.config/opencode/cli.json" '{"theme":"host-theme"}' "cli.json untouched"
# The config dir is the host's (mounted whole): the banner must not be
# written into it, or a native opencode would show the sandbox banner too.
if [ -e "$T16/home/.config/opencode/plugins/sandbox-banner" ] || [ -e "$T16/home/.config/opencode/plugins/.sandbox-banner" ]; then
  fail "no banner file written into the config dir"
else
  pass "no banner file written into the config dir"
fi
content_is "$T16/record/s16/content-env" "OPENCODE_CONFIG_CONTENT={\"plugins\":[\"$T16/banner-src\"]}" "banner declared through OPENCODE_CONFIG_CONTENT"
has_no_pattern "$T16/record/s16/stderr.txt" "Error" "no errors on a clean start"

# The child must inherit the entrypoint's stdin: a POSIX shell redirects an
# asynchronous command from /dev/null, which would leave the TUI unable to
# read a single terminal reply (the tty then echoes the replies back as raw
# escape sequences, and mouse reports with them).
FAKE_OPENCODE_EXIT=1 FAKE_OPENCODE_EXIT_CODE=0 FAKE_OPENCODE_STDIN=1 \
SECURE_OPENCODE_BANNER_SRC="$T16/banner-src" \
  env HOME="$T16/home" PATH="$T16/bin:$PATH" \
  sh "$ENTRYPOINT" run <<< "hello-stdin" \
  >"$T16/record/s16stdin/stdout.txt" 2>"$T16/record/s16stdin/stderr.txt"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0 with a piped stdin"; else fail "exit 0 with a piped stdin (got $rc)"; fi
has_line "$T16/record/s16stdin/stdout.txt" "child-stdin:hello-stdin" "child inherits the entrypoint's stdin"

# A content config the caller set itself (`docker run -e
# OPENCODE_CONFIG_CONTENT=...`) must survive: the banner is appended to its
# plugin list, never substituted for it.
FAKE_OPENCODE_EXIT=1 FAKE_OPENCODE_MARKER= \
FAKE_OPENCODE_ENV_RECORD="$T16/record/s16content/content-env" \
SECURE_OPENCODE_BANNER_SRC="$T16/banner-src" \
  env HOME="$T16/home" PATH="$T16/bin:$PATH" \
      OPENCODE_CONFIG_CONTENT='{"plugins":["/host/plugin"],"theme":"x"}' \
  sh "$ENTRYPOINT" serve >"$T16/record/s16content/stdout.txt" 2>"$T16/record/s16content/stderr.txt"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0 with a caller-provided OPENCODE_CONFIG_CONTENT"; else fail "exit 0 with a caller-provided OPENCODE_CONFIG_CONTENT (got $rc)"; fi
expected_content="OPENCODE_CONFIG_CONTENT={\"plugins\":[\"/host/plugin\",\"$T16/banner-src\"],\"theme\":\"x\"}"
content_is "$T16/record/s16content/content-env" "$expected_content" "caller content config kept, banner appended"
has_no_pattern "$T16/record/s16content/stderr.txt" "Error" "no errors when merging the banner"

# Signal forwarding: the entrypoint is running with a child that stays up
# until signalled; SIGTERM on the entrypoint must reach the child, and the
# child's status (143) must come back as the entrypoint's exit code.
rm -f "$T16/child-marker"
FAKE_OPENCODE_MARKER="$T16/child-marker" \
FAKE_OPENCODE_REGISTER="$T16/home/.local/state/opencode/service.json" \
SECURE_OPENCODE_BANNER_SRC="$T16/banner-src" \
  env HOME="$T16/home" PATH="$T16/bin:$PATH" \
  sh "$ENTRYPOINT" run --slow >"$T16/record/s16sig/stdout.txt" 2>"$T16/record/s16sig/stderr.txt" &
entry_pid=$!
i=0
while [ ! -f "$T16/child-marker" ] && [ "$i" -lt 100 ]; do
  i=$((i + 1))
  sleep 0.1
done
if [ -f "$T16/child-marker" ]; then pass "child came up"; else fail "child came up"; fi
kill -TERM "$entry_pid"
wait "$entry_pid"
rc=$?
if [ "$rc" = 143 ]; then
  pass "SIGTERM forwarded, child status 143 propagated"
else
  fail "SIGTERM forwarded, child status 143 propagated (got $rc)"
fi
has_pattern "$T16/record/s16sig/stdout.txt" "child-term" "child received the signal"
if [ -e "$T16/home/.local/state/opencode/service.json" ]; then
  fail "exit cleanup removed the child's registration after the signal"
else
  pass "exit cleanup removed the child's registration after the signal"
fi

# A banner source that is not there (a corrupted image): the sandbox
# indicator would be missing, so the entrypoint refuses to start.
FAKE_OPENCODE_EXIT=1 \
  env HOME="$T16/nohome/home" PATH="$T16/bin:$PATH" \
  SECURE_OPENCODE_BANNER_SRC="$T16/no-such-banner" \
  sh "$ENTRYPOINT" run >"$T16/record/s16nobanner/stdout.txt" 2>"$T16/record/s16nobanner/stderr.txt"
rc=$?
if [ "$rc" = 1 ]; then pass "exit 1 when the banner source is missing"; else fail "exit 1 when the banner source is missing (got $rc)"; fi
has_pattern "$T16/record/s16nobanner/stderr.txt" "sandbox banner source" "clear refusal message"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) FAILED."
  exit 1
fi
