#!/bin/zsh
# Serialised build / preview helper for CycleJames.
#
# Only one xcodebuild or Simulator run happens at a time across every caller
# (a mkdir lock in scripts/dev/), with limited compile parallelism, so several
# agents or terminals can share an 8 GB Mac without exhausting memory.
#
#   scripts/dev/cj-build.sh build [file-filter]
#       xcodegen + simulator build. Prints errors and warnings; with a filter
#       (substring of a path, e.g. "Courses/Scene/Rider") only matching ones.
#       Exit 0 when the build succeeds.
#   scripts/dev/cj-build.sh test [TestClass[/testMethod]]
#       Builds and runs the unit tests on the preview simulator (only the
#       given class or test when one is named).
#   scripts/dev/cj-build.sh shot <out.png> [wait-seconds] [-- app launch args...]
#       Builds, installs and launches on the preview simulator, waits
#       (default 8 s), saves a screenshot, then terminates the app.
#       e.g. shot /tmp/a.png 10 -- -coursePreview koppenberg -courseStartS 450
#   scripts/dev/cj-build.sh shutdown
#       Shuts the preview simulator down to free memory.
#   scripts/dev/cj-build.sh run <command> [args...]
#       Runs any other heavy job (a texture bake, a course build) under the
#       same lock, e.g. run uv run --script scripts/courses/textures/bake_materials.py --only sky
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# Inside the repo, not /tmp: sandboxed callers may each see a private /tmp.
LOCK="$REPO/scripts/dev/.build.lock"
# Every caller shares one DerivedData so builds stay incremental.
DD="${CJ_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/CycleJames-agents}"
SIM_NAME="${CJ_SIM:-iPhone 17 Pro}"
BUNDLE_ID=com.jamesbrowne.cyclejames
JOBS="${CJ_JOBS:-3}"

acquire() {
  local waited=0 owner
  until mkdir "$LOCK" 2>/dev/null; do
    # Break a lock whose owner has died.
    owner=$(cat "$LOCK/pid" 2>/dev/null || echo "")
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$LOCK"; continue
    fi
    (( waited % 30 == 0 )) && echo "waiting for build lock (held by pid ${owner:-?})..." >&2
    sleep 2; waited=$((waited + 2))
    if (( waited > 1800 )); then echo "gave up waiting for build lock" >&2; exit 3; fi
  done
  echo $$ > "$LOCK/pid"
  HELD=1
}

# Released at script exit. These traps must stay at top level: in zsh an
# EXIT trap set inside a function fires as soon as that function returns.
HELD=""
release() { [[ -n "$HELD" ]] && rm -rf "$LOCK"; }
trap release EXIT
trap 'release; exit 130' INT TERM

sim_udid() {
  xcrun simctl list devices available | grep -F "    $SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

do_build() {
  local filter="${1:-}"
  cd "$REPO" || exit 1
  xcodegen --quiet >/dev/null 2>&1 || xcodegen
  local log; log=$(mktemp -t cjbuild)
  xcodebuild -project CycleJames.xcodeproj -scheme CycleJames \
    -destination "id=$(sim_udid)" \
    -derivedDataPath "$DD" -jobs "$JOBS" build >"$log" 2>&1
  local rc=$?
  if [[ -n "$filter" ]]; then
    grep -E "(error|warning):" "$log" | grep -F "$filter" | sort -u | head -80
  else
    grep -E "(error|warning):" "$log" | grep -v "appintentsmetadataprocessor" | sort -u | head -80
  fi
  grep -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*" "$log" | tail -1
  rm -f "$log"
  return $rc
}

boot_sim() {
  local udid; udid=$(sim_udid)
  [[ -z "$udid" ]] && { echo "simulator '$SIM_NAME' not found" >&2; exit 2; }
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid"
  echo "$udid"
}

cmd="${1:-build}"; shift || true
case "$cmd" in
  build)
    acquire; do_build "${1:-}"; exit $? ;;
  test)
    acquire
    cd "$REPO" || exit 1
    xcodegen --quiet >/dev/null 2>&1 || xcodegen
    only=()
    [[ -n "${1:-}" ]] && only=("-only-testing:CycleJamesTests/$1")
    xcodebuild -project CycleJames.xcodeproj -scheme CycleJames \
      -destination "id=$(sim_udid)" \
      -derivedDataPath "$DD" -jobs "$JOBS" test "${only[@]}" 2>&1 \
      | grep -E "error:|Test Case .*(passed|failed)|Executed|\*\* TEST (SUCCEEDED|FAILED) \*\*" | tail -80
    exit ${pipestatus[1]} ;;
  shot)
    out="${1:?output png path}"; shift
    wait_s=8
    if [[ $# -gt 0 && "$1" != "--" ]]; then wait_s="$1"; shift; fi
    [[ "${1:-}" == "--" ]] && shift
    acquire
    do_build "" >/tmp/cj-shot-build.txt || { cat /tmp/cj-shot-build.txt; exit 1; }
    udid=$(boot_sim)
    app="$DD/Build/Products/Debug-iphonesimulator/CycleJames.app"
    xcrun simctl install "$udid" "$app" || exit 1
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1
    xcrun simctl launch "$udid" "$BUNDLE_ID" "$@" >/dev/null || exit 1
    sleep "$wait_s"
    xcrun simctl io "$udid" screenshot "$out" >/dev/null 2>&1 && echo "saved $out"
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1
    exit 0 ;;
  shutdown)
    acquire
    udid=$(sim_udid); [[ -n "$udid" ]] && xcrun simctl shutdown "$udid" 2>/dev/null
    exit 0 ;;
  run)
    [[ $# -gt 0 ]] || { echo "usage: $0 run <command> [args...]" >&2; exit 64; }
    acquire
    cd "$REPO" || exit 1
    "$@"
    exit $? ;;
  *)
    echo "usage: $0 build [filter] | test [TestClass] | shot <out.png> [wait] [-- args] | shutdown | run <cmd>" >&2; exit 64 ;;
esac
