#!/usr/bin/env bash
# Builds and launches the agent Testing app (DiskUnbloatTesting) and the AgentDevKit
# CLI, then prints the session. Usage:
#   Tools/agent-testing.sh [--fixture sample-home|dense-map|permission-wait|duplicate-review] [--real-home] [--no-build]
# Afterwards drive it with: "$ADK" --session com.diskunbloat.app.testing <command> --json
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
adk_dir="${AGENTDEVKIT_PATH:-$(cd "$repo/../.." && pwd)/AgentDevKit}"
derived="$repo/.build/agent-testing"
app="$derived/Build/Products/Debug/DiskUnbloatTesting.app"
adk="$adk_dir/.build/debug/agentdevctl"
fixture=""; real_home=""; build=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture) fixture="$2"; shift 2 ;;
    --real-home) real_home="--diskunbloat-real-home"; shift ;;
    --no-build) build=0; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ $build -eq 1 ]]; then
  mkdir -p "$derived"
  swift build --package-path "$adk_dir" --product agentdevctl >/dev/null
  xcodebuild -project "$repo/DiskUnbloat.xcodeproj" -scheme DiskUnbloatTesting -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$derived" build >"$derived.log" 2>&1 \
    || { echo "Testing build failed; see $derived.log" >&2; exit 1; }
fi

# One instance at a time keeps --session <bundle id> unambiguous.
pkill -x DiskUnbloatTesting 2>/dev/null || true
sleep 0.5
args=(--enable-agentdevkit --allow-agentdevkit-mutations)
[[ -n "$fixture" ]] && args+=(--agentdevkit-fixture "$fixture")
[[ -n "$real_home" ]] && args+=("$real_home")
open -n "$app" --args "${args[@]}"

for _ in $(seq 1 50); do
  if "$adk" --session com.diskunbloat.app.testing session ping --json >/dev/null 2>&1; then break; fi
  sleep 0.2
done
"$adk" session list --json
echo "ADK=$adk"
