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
  "$T/home/.local/share/opencode/log" \
  "$T/home/.local/state/opencode/locks" \
  "$T/home/.local/state/opencode/latest/locks" \
  "$T/home/.local/state/opencode/latest/tui" \
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

# --- host fixtures: config / data / state dirs ------------------------------
cat > "$T/home/.config/opencode/opencode.json" <<EOF
{
  "plugin": [
    "$T/plugins/ext-global.js",
    ["$T/home/.config/opencode/cfgplugin.js", "opt"],
    "$T/plugins/missing-plugin.js"
  ]
}
EOF
echo "cfg plugin" > "$T/home/.config/opencode/cfgplugin.js"
echo "service pw" > "$T/home/.config/opencode/service.json"
echo "agent" > "$T/home/.config/opencode/agents/agent1.md"

echo "creds" > "$T/home/.local/share/opencode/auth.json"
echo "db" > "$T/home/.local/share/opencode/opencode.db"
echo "wal" > "$T/home/.local/share/opencode/opencode.db-wal"
echo "log" > "$T/home/.local/share/opencode/log/session1.log"

echo "profile" > "$T/home/.local/state/opencode/profile.json"
echo "service pw" > "$T/home/.local/state/opencode/service.json"
echo "lock" > "$T/home/.local/state/opencode/locks/l1"
echo "machines" > "$T/home/.local/state/opencode/latest/machines.json"
echo "lock" > "$T/home/.local/state/opencode/latest/locks/l2"
echo "tabs" > "$T/home/.local/state/opencode/latest/tui/tabs.json"
echo "theme" > "$T/home/.local/state/opencode/latest/tui/theme.json"

cat > "$T/home/.gitconfig" <<'EOF'
[user]
	name = Test User
	email = test@example.com
[credential]
	helper = osxkeychain
EOF

# --- project fixture: JSONC on purpose (comments + trailing commas) ---------
# "ext-global.js" is deliberately referenced in BOTH this file and the global
# opencode.json, to check the wrapper does not mount it twice.
cat > "$T/project/opencode.jsonc" <<EOF
{
  // project-level config
  "plugin": [
    "$T/plugins/ext-global.js",
    "$T/plugins/proj-ext.js", /* block comment mid-array */
    "./relative-plugin.js", // relative entries need no mount
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

# --- external plugin files (absolute paths outside config + project dirs) ---
echo "global ext" > "$T/plugins/ext-global.js"
echo "proj ext" > "$T/plugins/proj-ext.js"
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

# ---------------------------------------------------------------------------
# Run helpers
# ---------------------------------------------------------------------------

# run_wrapper <record-dir> [wrapper args...]
# Runs the wrapper from the fixture project dir with a controlled environment.
# FAKE_* / OPENCODE_CONFIG env vars set by the caller are forwarded.
run_wrapper() {
  local record="$1"
  shift
  mkdir -p "$record"
  rm -f "$record"/run.args "$record"/build.args "$record"/tag.args \
        "$record"/gitconfig-credential-count "$record"/stdout.txt "$record"/stderr.txt
  (
    cd "$T/project" || exit 99
    env HOME="$T/home" \
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
has_line "$REC/run.args" "-v $T/home/.config/opencode/agents:/home/node/.config/opencode/agents" "config sibling: agents/"
has_line "$REC/run.args" "-v $T/home/.config/opencode/cfgplugin.js:/home/node/.config/opencode/cfgplugin.js" "config sibling: loose file"
has_line "$REC/run.args" "-v $T/home/.config/opencode/opencode.json:/home/node/.config/opencode/opencode.json:ro" "global opencode.json mounted read-only"
has_line "$REC/run.args" "-v $T/home/.local/share/opencode/log:/home/node/.local/share/opencode/log" "data sibling: log/"
has_line "$REC/run.args" "-v $T/home/.local/state/opencode/profile.json:/home/node/.local/state/opencode/profile.json" "state sibling: top-level file"
has_line "$REC/run.args" "-v $T/home/.local/state/opencode/latest/machines.json:/home/node/.local/state/opencode/latest/machines.json" "state latest/ sibling"
has_line "$REC/run.args" "-v $T/home/.local/state/opencode/latest/tui/theme.json:/home/node/.local/state/opencode/latest/tui/theme.json" "state latest/tui/ sibling"
has_line "$REC/run.args" "-v $T/plugins/ext-global.js:$T/plugins/ext-global.js:ro" "external plugin (global config) mounted read-only"
has_line "$REC/run.args" "-v $T/plugins/proj-ext.js:$T/plugins/proj-ext.js:ro" "external plugin (project JSONC config) mounted read-only"
occurs_once "$REC/run.args" "-v $T/plugins/ext-global.js:$T/plugins/ext-global.js:ro" "plugin referenced in two configs mounted exactly once"
has_line "$REC/run.args" "-e TZ=Europe/Rome" "TZ forwarded"
has_line "$REC/run.args" "-e HOME=/home/node" "HOME overridden"
has_line "$REC/run.args" "-e OPENCODE_LMSTUDIO_BASEURL=http://host.docker.internal:1234/v1" "OPENCODE_LMSTUDIO_BASEURL set"
has_line "$REC/run.args" "--add-host=host.docker.internal:host-gateway" "host.docker.internal add-host"
has_line "$REC/run.args" "opencode-sandbox:current" "image reference"
has_line "$REC/run.args" "--version" "arguments passed through"
has_pattern "$REC/run.args" '^-v /[^:]+:/home/node/\.gitconfig:ro$' "filtered gitconfig mounted read-only"
if [ -n "$CA_BUNDLE_CANDIDATE" ]; then
  has_line "$REC/run.args" "-v $CA_BUNDLE_CANDIDATE:/etc/ssl/certs/ca-certificates.crt:ro" "host CA bundle mounted"
fi
content_is "$REC/gitconfig-credential-count" "0" "gitconfig credential section stripped"
has_no_pattern "$REC/run.args" 'auth\.json' "auth.json NOT mounted"
has_no_pattern "$REC/run.args" 'opencode\.db' "opencode.db* NOT mounted"
has_no_pattern "$REC/run.args" 'service\.json' "service.json NOT mounted"
has_no_pattern "$REC/run.args" '/locks' "locks/ NOT mounted"
has_no_pattern "$REC/run.args" 'tabs\.json' "latest/tui/tabs.json NOT mounted"
has_no_pattern "$REC/run.args" 'missing-plugin' "missing plugin NOT mounted"
has_pattern "$REC/stderr.txt" "Plugin files available in the container" "plugin manifest printed"
has_pattern "$REC/stderr.txt" "missing-plugin\.js" "missing plugin warned about"

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
has_line "$REC/run.args" "-v $T/plugins/ext-config.js:$T/plugins/ext-config.js:ro" "plugin from OPENCODE_CONFIG mounted"

# Baseline run (no extra args, no OPENCODE_CONFIG) to compare against.
REC="$T/record/s7a"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG= run_wrapper "$REC"

# OPENCODE_CONFIG pointing at the global opencode.json must not add mounts
# or re-collect plugins (it is already covered by the explicit handling).
REC="$T/record/s7b"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG="$T/home/.config/opencode/opencode.json" run_wrapper "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
norm() { sed -E -e 's#^-v [^:]+:/home/node/\.gitconfig:ro$#-v GITCFG:/home/node/.gitconfig:ro#' \
                -e 's#^-v [^:]+(/[^:]*)?/ca-certificates\.crt:#-v CACERTS:\1/ca-certificates.crt:#' "$1"; }
if diff <(norm "$REC/run.args") <(norm "$T/record/s7a/run.args") >/dev/null 2>&1; then
  pass "OPENCODE_CONFIG at global config adds nothing"
else
  fail "OPENCODE_CONFIG at global config adds nothing"
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
