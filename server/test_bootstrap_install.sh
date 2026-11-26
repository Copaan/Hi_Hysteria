#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/server/install.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
reject() { if "$@" >/dev/null 2>&1; then echo 'FAIL: invalid installer operation accepted' >&2; exit 1; fi; }
# 函数由安装器加载；后面的同名定义仅用于故障注入。
# shellcheck disable=SC2218
extractEmbeddedRuntime >"$TMP/runtime"
cmp -s "$TMP/runtime" "$ROOT/server/hy2.sh"
verifyEmbeddedRuntime "$TMP/runtime"
printf '\n# tampered\n' >>"$TMP/runtime"
reject verifyEmbeddedRuntime "$TMP/runtime"
ln -s "$ROOT/server/hy2.sh" "$TMP/link"
reject verifyEmbeddedRuntime "$TMP/link"
head -c 800 "$ROOT/server/hy2.sh" >"$TMP/truncated"
reject verifyEmbeddedRuntime "$TMP/truncated"
(cd "$TMP" && bash "$ROOT/server/install.sh" --help >help)
grep -q '中文菜单' "$TMP/help"
reject bash "$ROOT/server/install.sh" --lang zh
reject bash "$ROOT/server/install.sh" --unknown
printf 'PASS: self-contained payload, corruption/truncation/symlink refusal, help and removed language flags\n'
cat >"$TMP/fixture" <<'FIXTURE'
#!/bin/bash
HIHY_ROOT_DIR="${HIHY_ROOT_DIR:?}"
getArchitecture() { echo "${TEST_ARCH:-amd64}"; }
classifyInstallState() { if [ -f "$1/conf/config.yaml" ]; then echo installed; else echo not-installed; fi; }
ensureSystemDependencies() { echo dependencies >>"$TEST_LOG"; return "${TEST_DEPS_RESULT:-0}"; }
installPrivateYq() { echo private-yq >>"$TEST_LOG"; return "${TEST_YQ_RESULT:-0}"; }
installHihyLauncher() { echo launcher >>"$TEST_LOG"; mkdir -p "$(dirname "$2")" && cp -- "$1" "$2" && chmod 700 "$2"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then printf 'entry:%s\n' "${1:-menu}" >>"$TEST_LOG"; fi
FIXTURE
HIHY_EMBEDDED_SHA256=$(sha256sum "$TMP/fixture" | cut -d' ' -f1)
extractEmbeddedRuntime() { cat "$TMP/fixture"; }
id() { if [ "$1" = -u ]; then echo 0; else command id "$@"; fi; }
installerAcquireLock() { echo lock >>"$TEST_LOG"; }
installerReleaseLock() { echo unlock >>"$TEST_LOG"; }
export TEST_LOG="$TMP/events" HIHY_ROOT_DIR="$TMP/project" HIHY_BIN_LINK="$TMP/hihy" TMPDIR="$TMP"
installerMain >"$TMP/default.log" 2>&1
printf 'dependencies\nlock\nprivate-yq\nlauncher\nunlock\nentry:menu\n' >"$TMP/expected"
cmp -s "$TEST_LOG" "$TMP/expected"
[ "$(stat -c %a "$HIHY_ROOT_DIR/conf")" = 700 ]
[ "$(stat -c %a "$HIHY_BIN_LINK")" = 700 ]
installerMain --auto >"$TMP/auto.log" 2>&1
tail -1 "$TEST_LOG" | grep -qx 'entry:autoinstall'
[ -z "$(find "$TMP" -maxdepth 1 -name 'hihy-bootstrap.*' -print)" ]
printf old >"$HIHY_ROOT_DIR/conf/config.yaml"
cp "$TEST_LOG" "$TMP/events-before"
reject installerMain
cmp -s "$TEST_LOG" "$TMP/events-before"
[ "$(cat "$HIHY_ROOT_DIR/conf/config.yaml")" = old ]
rm -f "$HIHY_ROOT_DIR/conf/config.yaml" "$HIHY_BIN_LINK"
export TEST_DEPS_RESULT=1
reject installerMain
[ ! -e "$HIHY_BIN_LINK" ]
export TEST_DEPS_RESULT=0 TEST_YQ_RESULT=1
reject installerMain
[ ! -e "$HIHY_BIN_LINK" ]
export TEST_YQ_RESULT=0 TEST_ARCH=unknown
cp "$TEST_LOG" "$TMP/events-before"
reject installerMain
cmp -s "$TEST_LOG" "$TMP/events-before"
unset TEST_ARCH
mkdir "$TMP/outside"
ln -s "$TMP/outside" "$TMP/symlink"
HIHY_ROOT_DIR="$TMP/symlink" reject installerMain
[ -z "$(ls -A "$TMP/outside")" ]
id() { echo 1000; }
reject installerMain
printf 'PASS: dependency ordering, default menu, automatic mode, retry, permissions and existing-install protection\n'
