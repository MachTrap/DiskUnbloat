# Agent-Native macOS Development & Real-App UI Verification

**Practical architecture, tooling, workflow, and cost-control guide for AI coding agents working on native macOS applications**

**Updated:** 2026-11-03  
**Scope:** Native SwiftUI / AppKit macOS apps, including apps with Metal, SceneKit, SpriteKit, or custom-drawn UI.  
**Audience:** Developers using Codex, Claude Code, Cursor, or other tool-using coding agents.  
**Status:** Recommended engineering practices. Code examples are adaptable patterns, not a drop-in framework.  
**Project adaptation:** DiskUnbloat. The section right after §0 records how these practices map onto this repository, what is intentionally not adopted, and the prioritized plan. The adapted core policy lives in the repository root `AGENTS.md`.

---

## 0. Executive summary

A successful code compilation is **not** proof that an app works. An AI agent should be able to build, launch, operate, inspect, and verify the **real running `.app`**. It should also avoid spending tokens, tool calls, and wall-clock time repeatedly navigating through unrelated screens.

The recommended setup has five cooperating layers:

1. **Build / debug:** Xcode MCP or `xcodebuild`, build errors, diagnostic logs, process lifecycle.
2. **Desktop interaction:** Accessibility tree first; screenshots and computer vision when pixels matter; native keyboard/pointer events when necessary.
3. **Fast navigation:** Debug-only deep links, initial-screen launch arguments, and production-router integration.
4. **Deterministic state:** Named fixtures, isolated databases/accounts, seeded test data, stable settings, and a reset mechanism.
5. **Evidence-based verification:** UI semantics, screenshot evidence, runtime effects, diagnostics, and reproducible regression tests where justified.

> **Key rule:** For a bug within a deep screen, use a direct, deterministic route to that screen and reproduce the bug there. Test the complete user journey separately when the journey itself matters.

### Definition of done

For a UI-affecting change, prefer evidence of all three:

- **Build:** the intended app target successfully builds and runs.
- **Behavior:** the required interaction produces an observed correct state, not merely a successfully dispatched click.
- **Presentation:** the actual UI is inspected at the relevant window size/state, preferably with a targeted screenshot.

If any layer was not tested, state that explicitly in the result.

---

## DiskUnbloat adaptation — current state, gaps, and plan (2026-11-03)

This section records how the generic practices above map onto this repository: what is in place, what is knowingly not adopted, and what is planned. It is updated whenever the gap between this guide and the project changes.

### How the five layers map to DiskUnbloat

| Guide layer | DiskUnbloat reality |
|---|---|
| Build / debug | `python3 Tools/generate-project.py` regenerates the checked-in Xcode 27 JSON project; app target `DiskUnbloat`, core package `Packages/DiskCore`. Verification: `swift test --package-path Packages/DiskCore`, hosted suites (`xcodebuild … test -only-testing:DiskUnbloatTests`, the test host runs unsandboxed so env-gated probes can exercise real scans), universal Release build, localization audit (`Tools/audit-localization.py`). |
| Desktop interaction | External desktop-automation MCPs (Peekaboo, Xcode MCP) are not configured or required here. Real-window verification goes through `DiskUnbloatUITests` (real `XCUIApplication` launches against stable accessibility IDs). |
| Fast navigation | No debug deep links. The route map is `WorkspacePhase` (choosing → scanning → preparing results → exploring), enforced by suites; phase-specific defects are reproduced through model-level probes (`MapAfterSelectionTests`, `WorkspaceRecoveryTests`) rather than repeated UI navigation. |
| Deterministic state | Fixtures are unique generated temporary trees, deleted after the test; the index lives in per-session `Caches/ScanIndexes`, so there is no persistent state to reset between runs. Destructive operations never touch real user data (recording/succeeding cleanup services, intentionally removed fixture copies). |
| Evidence-based verification | Every round is recorded in `Documentation/VALIDATION.md` with honest unverified or environment-blocked gaps; the atomic verification bundle is core + hosted suites + Release build + localization audit. |

### What is not optimal today (comparison against the guide)

1. **Accessibility identifier coverage is partial.** The chooser screen targets, `queueCheckbox`, and failed-screen buttons carry stable IDs, but the map canvas, hover card, queue panel headers, and ExplorerView toolbar largely don't. → *P1: audit custom controls and add semantic IDs where automation or assistive users need them.*
2. **No debug launch arguments / deep links (§3.3–3.4).** The hosted-probe pattern currently replaces them: measuring a deep flow is a suite, not a relaunch. Deep links only pay off once external desktop automation is actually adopted. → *P2: revisit if Peekaboo/Xcode MCP becomes part of the loop.*
3. **macOS 26 TCC consent for other applications' app data.** Fixed 2026-11-03: `ScanPermissionPreflight` now probes `~/Library/Application Support` (the third-party app-data gate, `SystemPolicyAppData` — "would like to access data from other apps") in addition to Apple's protected folders, and the Info.plist carries every usage-description key for the categories the preflight touches, so the consent dialog appears before the scan instead of per-folder denial errors. Denials the user dismisses must keep surfacing honestly as scan issues — the app never promises unrestricted access, and automating consent dialogs is out of scope by design. → *done; keep the honest-denial invariant.*
4. **Structured logs exist only in `AuthorizationStore`.** Scan/cleanup diagnostics deliberately live in domain structures (scan issues, the cleanup audit trail) — those are probe-readable state, which is more valuable than spreading `Logger` calls. → *keep §6.2 as: log where state is not already observable; else expose state in domain structures.*
5. **`DiskUnbloatUITests` holds two real-launch scenarios** (English/Russian location screen, phase-1 layout). → *P1: one scenario per `WorkspacePhase` transition once window scripting needs it.*
6. **Snapshot testing is intentionally not adopted** — the map is a data-driven animated canvas whose accounting is verified exactly through `MapScene` golden tests; pixel snapshots would fight the animation and add flakiness. → *explicit non-goal.*
7. **Mid-scan probe visibility.** Extension of macOS 26 "app data" consent cannot be verified programmatically: it requires a real user click on the system dialog during a real home scan. The hosted/core layer verifies target selection and probing bounds only; the user-visible dialog is an honest unverified-until-real-app item recorded in VALIDATION.

### Priority plan applied to this project

- **P0 (done):** documented build/verification path and the adapted UI-verification policy in root `AGENTS.md` (this guide's §12, applied); permission preflight covers `SystemPolicyAppData` and the bundled usage-description keys; deterministic unique fixtures; `WorkspacePhase` invariants tested; inaccessible-scope recovery (bookmark restore, failed screen with refusal detail).
- **P1:** complete accessibility IDs over the map and queue panel; one `DiskUnbloatUITests` scenario per phase transition; routinely note each new probe's fixture + suite name in `VALIDATION.md` so the next agent can reuse it (§7.2 caching rule, project-encoded).
- **P2 / non-goals:** debug deep links unless external desktop automation is adopted; snapshot pixel tests for the animated map; desktop CI workers.

## 1. Which tool should the agent use?

| Tool / method | Best for | Weakness or constraint |
|---|---|---|
| **Xcode MCP** (`xcrun mcpbridge`) | Project-aware Xcode capabilities, builds, diagnostics | Not a replacement for arbitrary desktop-window automation |
| **Peekaboo** (CLI + MCP) | macOS screen capture, Accessibility inspection, UI actions, menus, windows, screenshots | Requires privacy permissions and a suitable graphical session; capabilities/flags evolve |
| **macos-use** (MCP) | Accessibility-first app traversal and clicks/typing | Smaller, different tool surface; evaluate on your app |
| **OpenComputerUse** (MCP) | Cross-platform accessibility-driven desktop control | Feature/behavior varies by platform and version |
| **XCUIAutomation / XCTest** | Repeatable real-app UI tests, assertions, CI regressions | Requires maintaining test code and test environments |
| **AppKit/SwiftUI Accessibility** | Semantic read/write of native controls | Custom-rendered surfaces may expose little useful structure |
| **Screen capture + vision** | Layout defects, custom graphics, clipping, rendering artifacts | Pixel interpretation can be ambiguous and more expensive |
| **AppleScript / System Events** | Some application menus, dialogs, and scriptable workflows | Inconsistent support across apps; not the primary UI-testing interface |
| **Debug deep links / launch arguments** | Immediate access to deeply nested screens/states | Must be built into the app, restricted to test/development contexts |
| **Runtime logs / state inspection** | Confirming persistence, events, failures, data flows | Should complement rather than replace UI observation |

### Preferred default

- Start with **Xcode MCP + Peekaboo MCP** for native macOS development.
- Use **one desktop-automation provider at a time** for a given run, to avoid tool duplication, ambiguous ownership, and stale snapshots.
- Add **XCUIAutomation** when an exploratory agent-discovered scenario becomes a repeatable regression requirement.
- For custom graphics, combine screenshots with app-provided debug state or accessibility representations of important controls.

The official Xcode MCP bridge and Peekaboo are independent integrations. Do not assume connecting Xcode alone gives an agent the ability to click arbitrary macOS windows.

---

## 2. Initial agent tooling setup

### 2.1 Xcode MCP

In Xcode, open **Settings > Intelligence** and enable **Allow external agents to use Xcode tools**. Open the target project/workspace in Xcode before expecting external agents to use its project-aware tools.

For Codex CLI:

```bash
codex mcp add xcode -- xcrun mcpbridge
codex mcp list
```

For Claude Code:

```bash
claude mcp add --transport stdio xcode -- xcrun mcpbridge
claude mcp list
```

**Fallback:** A capable terminal agent can also use `xcodebuild` directly. Keep the build invocation documented and stable; do not make the agent repeatedly rediscover the project/scheme/configuration.

### 2.2 Peekaboo CLI and MCP

Current published Peekaboo releases require **macOS 15+**. Its npm MCP package requires **Node.js 22+**.

```bash
brew install openclaw/tap/peekaboo
peekaboo --version
peekaboo permissions status
```

Grant the required macOS **Accessibility** and **Screen Recording** permissions to the relevant process, as described in Peekaboo's permissions documentation. Input-related capabilities may require an additional permission or explicit opt-in depending on the action and runtime.

For Codex:

```bash
codex mcp add peekaboo -- npx -y @steipete/peekaboo mcp
codex mcp list
```

For Claude Code:

```bash
claude mcp add --transport stdio peekaboo -- npx -y @steipete/peekaboo mcp
claude mcp list
```

The basic MCP server defaults to background-safe actions. Operations that require the shared desktop pointer, foreground input, or global control may require starting the server with an explicit `--allow-foreground` option. Prefer background semantic actions whenever supported; read your installed version's policy and tool help before enabling broader control.

### 2.3 Initial smoke check

```bash
peekaboo window list --app Finder --json
peekaboo see --app Finder --json --path /tmp/finder-ui.png
peekaboo see --app Finder --tree --no-screenshot --json
```

Do not begin a large automated UI run until the target app is observable and the action tools have the necessary permissions. If the application is running in a disconnected/headless/SSH session, ordinary screen capture may not see its real windows; use a proper logged-in GUI session or an officially supported bridge/host setup.

### 2.4 Pin tool versions for repeatability

Record the Xcode version, active macOS version, agent configuration, and Peekaboo version in a local environment note or CI image definition. Periodically recheck official help because CLI flags and MCP action schemas can change.

---

## 3. Prepare the app for agent access

The cheapest agent action is one that does not need to be discovered through trial and error.

### 3.1 Stable Accessibility identifiers

Use semantic, stable IDs for controls and screen landmarks:

```swift
Button("Save Changes") {
    saveChanges()
}
.accessibilityIdentifier("settings.advanced.save")

Toggle("Enable Notifications", isOn: $notificationsEnabled)
    .accessibilityIdentifier("settings.advanced.notifications")

Text("Advanced Settings")
    .accessibilityIdentifier("screen.settings.advanced")
```

Guidelines:

- Prefer IDs to visible labels for programmatic lookup; labels can change with localization or design.
- Prefer semantic Accessibility actions to coordinate clicks.
- Use a consistent naming convention: `screen.*`, `settings.*`, `editor.*`, `dialog.*`, `status.*`.
- Make IDs unique within the relevant active window or interaction scope.
- Avoid position-derived identifiers like `button_3`, random IDs, or array indices.
- Mark controls as enabled/disabled and report meaningful values through Accessibility.
- Expose accessibility for custom controls when practical, including custom AppKit views.
- Preserve accessibility usability for real users; automation should benefit from good accessibility rather than distort it.

Example namespace:

```text
screen.settings.advanced
settings.advanced.theme
settings.advanced.save
settings.advanced.save-status
screen.projects.editor
editor.document.title
editor.export.button
modal.unsaved-changes.confirm
```

### 3.2 Reuse the production navigation architecture

Debug navigation must call the **same app router/coordinator** used by ordinary navigation. It should not create a parallel imitation of the screen.

Recommended navigation contract:

```text
Deep link / launch argument
          -> Parse & validate
          -> Resolve prerequisites & fixture
          -> Production router / coordinator
          -> Real screen / view model / data layer
```

This allows the agent to bypass repetitive navigation without bypassing the actual rendering and behavioral implementation being tested.

### 3.3 Create debug-only deep links

Example route table:

```text
myapp-debug://screen/settings/advanced
myapp-debug://screen/profiles/appearance
myapp-debug://screen/projects/editor
```

Use a **separate Debug app bundle ID / URL scheme**, or register the scheme only in Debug builds. Merely wrapping a URL handler in `#if DEBUG` does not remove a scheme that is still registered in a Release `Info.plist`. Configure URL types per build configuration/target if separation is required.

Example parser:

```swift
#if DEBUG
import Foundation

enum AgentScreen: String {
    case advancedSettings = "settings/advanced"
    case profileAppearance = "profiles/appearance"
    case projectEditor = "projects/editor"
}

enum AgentDeepLink {
    static func screen(from url: URL) -> AgentScreen? {
        guard url.scheme == "myapp-debug",
              url.host == "screen" else {
            return nil
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return AgentScreen(rawValue: path)
    }
}
#endif
```

At the app's SwiftUI root/scene (illustrative adapter to your existing router):

```swift
.onOpenURL { url in
    #if DEBUG
    guard let screen = AgentDeepLink.screen(from: url) else { return }
    // Map `screen` to your real navigation destination.
    // Use your existing router/coordinator; do not render a test-only copy.
    appRouter.navigate(to: screen)
    #endif
}
```

Open the route:

```bash
open 'myapp-debug://screen/settings/advanced'
```

**Important:** `appRouter.navigate(to:)` represents the existing app's router API; adapt the signature and mapping to your project. The sample is an architectural pattern, not a complete compiled app.

Route safeguards:

- Maintain a finite, allowlisted route registry; no arbitrary method execution or file access.
- Do not bypass authorization or permissions that are relevant to the behavior being validated.
- Enforce entitlement/test-account prerequisites rather than faking them silently.
- Avoid exposing secrets, internal data, or arbitrary debug commands through links.
- Prefer stable semantic routes over view-class names or fragile numeric indices.
- Verify after navigation that the intended screen actually became visible.

### 3.4 Support launch arguments for first-screen targeting

Launch arguments are useful before any window appears and for scenarios requiring a fully clean process start.

```bash
# The .app is an example path; change to your built Debug application.
open -a '/absolute/path/MyApp-Debug.app' --args \
  --agent-ui \
  --initial-screen=settings/advanced \
  --fixture=long-profile-name
```

A simple parser:

```swift
#if DEBUG
import Foundation

func debugArgument(named name: String) -> String? {
    let prefix = "--\(name)="
    return ProcessInfo.processInfo.arguments
        .first(where: { $0.hasPrefix(prefix) })?
        .dropFirst(prefix.count)
        .description
}
#endif
```

**Lifecycle caveat:** `open -a ... --args` is appropriate for a new launch. If the app is already running, argument changes may not be applied to the existing process. For restart-dependent tests, terminate the **specific test instance** cleanly first, or use a controlled test launcher. For changing screens in an already running app, prefer debug URLs.

### 3.5 A fixture manager, not a collection of magic flags

Create a small versioned fixture registry:

```text
Fixtures/
  settings-default.json
  settings-long-localized-text.json
  editor-200-objects.json
  editor-corrupted-thumbnail.json
  profile-expired-entitlement.json
```

Example fixture manifest:

```json
{
  "id": "settings-long-localized-text",
  "schemaVersion": 1,
  "seed": 4251,
  "launchScreen": "settings/advanced",
  "locale": "en_US",
  "appearance": "dark",
  "windowSize": { "width": 1100, "height": 720 },
  "data": {
    "profileName": "An intentionally very long profile title used to verify layout",
    "notificationsEnabled": true
  }
}
```

Guidelines:

- Fixtures must be reproducible across runs and resettable by name.
- Seed deterministic IDs and timestamps when they affect the UI.
- Prefer a dedicated local test store, test account, and safe backend environment.
- Use production model/view-model paths where possible; isolate only external dependencies that cannot be controlled reliably.
- Distinguish **mock-only visual checks** from **end-to-end behavior checks with real persistence/network**.
- Log active fixture ID, route, build version, and environment with each run.
- Provide `resetFixture(id)` or equivalent to avoid manually deleting app preferences/databases between attempts.

A fixture should be a **state specification**, not an alternative implementation of the feature.

---

## 4. Minimal, efficient real-app test workflow

### Default agent loop

1. Read the task and determine the target screen, expected behavior, and prerequisites.
2. Search source/configuration for the relevant screen, route, fixture, and accessibility IDs.
3. Choose the **shortest valid path** to the target (reuse a running app, deep link, or clean launch with fixture).
4. Capture a **focused baseline** of the relevant app window (AX or screenshot, depending on the bug).
5. Reproduce the failure once, and record a precise success/failure criterion.
6. Edit code and build only the necessary app target/configuration.
7. Launch the new build, restore the **same fixture**, and open the same screen.
8. Perform the relevant action and **verify actual state**.
9. Capture final evidence; run a broader navigation/flow check **only if it is relevant or required**.
10. Report what was observed and what remains unverified.

### Selection matrix: fastest route without invalidating the test

| Scenario | Preferred entry path | Verification |
|---|---|---|
| Cosmetic bug in nested settings screen | Deep link + fixture | Window screenshot + key AX properties |
| Save button not persisting a value | Deep link + fixture or real seeded store | UI state + stored value after reopen |
| Navigation/back-stack bug | **Actual UI journey** | Transition, history, focus, back navigation |
| Cold-launch restoration bug | Clean process launch + launch arguments | Initial screen, restored data, startup logs |
| Login / permission / onboarding bug | Real flow in isolated test account | System prompts, auth state, success/failure |
| Custom Metal/SpriteKit layout bug | Deep link to host screen + deterministic scene | Screenshot or image diff + debug state |
| Export / import / drag-and-drop | Real system interaction | Generated artifact, destination, logs, UI outcome |
| Regression repeatedly found by users | XCUIAutomation using a deterministic fixture | Assertions and CI artifact |

**Rule:** A deep link can efficiently test a screen's local behavior, but it does **not** establish that the screen can be reached through the normal navigation flow.

### Example: deeply nested Appearance bug

User journey:

```text
Home -> Settings -> Profiles -> Selected Profile -> Advanced -> Appearance
```

Bad loop:

```text
relaunch -> click Home -> click Settings -> click Profiles ->
scroll -> choose profile -> click Advanced -> click Appearance ->
change one line of code -> repeat entire journey
```

Optimized loop:

```text
seed fixture: profile-appearance-overflow
open myapp-debug://screen/profiles/appearance
inspect screen + record baseline
edit -> build -> relaunch if necessary -> reopen deep link
check layout + semantic state
```

Then, **once**, if appropriate, validate the full UI journey and back-stack using the real navigation controls.

---

## 5. How to observe and control a running window

### 5.1 Use Accessibility before vision

For native accessible controls, request a structured tree first:

```bash
peekaboo see --app 'MyApp-Debug' \
  --tree --no-screenshot --json \
  > /tmp/myapp-ax.json
```

For interactive element IDs and a visual baseline:

```bash
peekaboo see --app 'MyApp-Debug' \
  --json --annotate \
  --path /tmp/myapp-screen.png \
  > /tmp/myapp-see.json
```

Extract only what matters, rather than attaching a massive tree to every agent message:

```bash
jq '[.data.ui_elements[] |
     select((.identifier // "") | startswith("settings.advanced.")) |
     {id, identifier, role, label, value, is_enabled}]' \
  /tmp/myapp-see.json
```

If no useful identifiers exist, inspect accessible labels and descriptions and improve the app's accessibility for future runs.

### 5.2 Prefer element actions over pixels

Example:

```bash
# Select a semantic control by text when its meaning is unambiguous.
peekaboo click 'Save Changes' --app 'MyApp-Debug'
```

For higher reliability, use the exact element ID from the latest `see` result with `peekaboo click --on <id>`. Do not hardcode ephemeral Peekaboo element IDs in source files; store stable **app accessibility identifiers** instead. Peekaboo snapshot IDs/element IDs are observation-specific.

### 5.3 Captures should target a single window or region

Prefer the app's relevant window over a screenshot of the entire desktop. For exact-window capture, Peekaboo can also capture an ROI:

```bash
peekaboo window list --app 'MyApp-Debug' --json

# Replace 12345 with an actual window ID retrieved above.
peekaboo see --app 'MyApp-Debug' --window-id 12345 \
  --roi 100,80,500,300 --json \
  --path /tmp/appearance-region.png
```

For pure visual verification where an AX map is unnecessary, use a screenshot-only capture; for the next click/action, create a fresh actionable observation if the tool requires one.

### 5.4 Never infer success from tool dispatch alone

A mouse event can be delivered without the application handling it as expected. An AX tree and screenshot may also be sampled at slightly different moments.

After an uncertain action:

1. **Observe the new state** (fresh AX / tool state verification).
2. Compare the observed target value or screen landmark against expectations.
3. If behavior is correct, continue; if not, investigate.
4. Do **not** blindly repeat a potentially non-idempotent action (Save, Delete, Purchase, Export).

If a tool reports a stale snapshot, reacquire a new snapshot. Do not reuse coordinates or element IDs based on an old window position.

### 5.5 Avoid screenshot-first for every tiny step

Recommended observation priority:

1. Known stable route or app state (no extra UI reconnaissance).
2. Lightweight AX tree / targeted JSON fields.
3. A targeted screenshot for visual or ambiguous states.
4. Full screenshot + vision only when needed.
5. Desktop-wide inspection only when app/window discovery or system UI requires it.

---

## 6. Observability that makes debugging much cheaper

### 6.1 Surface meaningful runtime state

For complex behaviors, expose a **read-only debug state endpoint / command / structured log** in Debug builds. This is complementary to UI testing, not a replacement for it.

Example state object:

```json
{
  "build": "debug-local",
  "fixture": "profile-appearance-overflow",
  "currentRoute": "profiles/appearance",
  "selectedProfileID": "fixture-profile-001",
  "appearance": "dark",
  "saveStatus": "saved",
  "pendingRequests": 0,
  "lastError": null
}
```

This helps answer: Did navigation succeed? Did the data model change? Is the screen still loading? Did a request fail?

If you expose debug state through a local IPC endpoint, socket, or URL handler, restrict access to test/dev context and never allow arbitrary execution, unprotected secrets, or access to production customer data.

### 6.2 Use structured logs with correlation IDs

Recommended fields:

```text
run_id, fixture_id, route, window_id, action_name,
request_id, state_transition, error_code, timestamp, build_id
```

Example trace:

```text
run=agent-204 fixture=profile-appearance-overflow route=profiles/appearance opened
run=agent-204 action=theme.toggle old=light new=dark
run=agent-204 action=save completed persisted=true
```

These should reflect real events and state transitions, not synthetic assertions. Avoid logging credentials, tokens, or sensitive user content.

### 6.3 Record evidence only where it helps

For each investigated UI bug, aim for a small evidence bundle:

```text
artifacts/agent-runs/<run-id>/
  metadata.json
  before.png
  after.png
  accessibility-summary.json
  relevant-log-tail.txt
  verification.md
```

Do not copy megabytes of irrelevant logs and entire accessibility trees into the model context. Keep full artifacts on disk and include concise paths and selective excerpts in agent output.

### 6.4 Stable visual test environment

For meaningful screenshot comparisons, control:

- Window size and position, display scaling, appearance mode, and locale.
- Test fixture and account/data state.
- Font availability and content dynamicity.
- Animations, clock-dependent strings, random visual elements, and network timing.
- Focus/selection state and transient popovers where relevant.

Prefer a deterministic screenshot region over full-desktop pixel equality. Pixel diffs are not automatically semantic failures; use tolerances and inspect the differences.

---

## 7. Model context, tokens, and tool-call optimization

The following policies should be encoded in `AGENTS.md` / `CLAUDE.md` or a project-specific agent skill.

### 7.1 A strict efficiency order

**Prefer, in order:**

1. Existing code knowledge and documented route/fixture.
2. Direct debug route to the target state.
3. Targeted Accessibility query.
4. A narrow, app-window screenshot.
5. Real UI navigation only when necessary.
6. Broad UI exploration when there is no reliable shorter path.

Do not pay the cost of level 5/6 when levels 1–4 fully test the relevant behavior.

### 7.2 Cache stable facts; refresh volatile facts

**Safe to document/cache:** build scheme, bundle ID, route registry, fixture names, accessibility identifier conventions, known test account type, app architecture.

**Do not treat as stable:** current window IDs, PIDs, Peekaboo snapshot IDs, element IDs, element bounds, focus state, menu state, active modal dialogs.

Reacquire volatile facts after relaunch, window resize, layout mutation, or focus/target changes.

### 7.3 Narrow source-code searches

Prefer:

```bash
rg -n 'AdvancedSettings|settings\.advanced|profileAppearance' App Sources Tests
```

Avoid scanning the entire repository or pasting every source file into the prompt. Read the relevant implementation, router and fixture definitions; expand only when dependencies require it.

### 7.4 Minimize repeated builds

- Avoid building after every speculative one-line change; first understand and batch related edits.
- Compile the smallest relevant target/scheme and correct configuration.
- Use a stable DerivedData path for a given workspace when suitable.
- Reuse the running app only when code changes do **not** require a new binary and the scenario permits it.
- Always launch the newly built binary when testing a code fix; a stale running app invalidates the result.
- Run broader regression suites at meaningful checkpoints, not after each screenshot.

Example deterministic build command (adapt project/scheme/path):

```bash
xcodebuild \
  -project MyApp.xcodeproj \
  -scheme MyApp \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/MyApp-AgentDerivedData \
  build > /tmp/MyApp-agent-build.log 2>&1

# Inspect relevant diagnostics instead of flooding the context.
rg -n 'error:|warning:|BUILD (SUCCEEDED|FAILED)' /tmp/MyApp-agent-build.log | tail -80
```

For production repositories, keep a checked-in script or Makefile target with the *actual* scheme, project/workspace, bundle ID and output location; this snippet is an example, not a universal invocation.

### 7.5 Avoid redundant observations

- Capture before + after for the **targeted action**, not after each intermediate route step.
- Use one fresh observation to perform a small number of safe actions, as allowed by the tool's snapshot policy.
- If the action changes the layout or window identity, observe again before the next target-specific action.
- Prefer waiting on a specific state condition over fixed `sleep 5` calls.
- Do not repeatedly ask the LLM to interpret the same unchanged screenshot.
- Use `jq`, `rg`, and structured output to return compact evidence to the model.

### 7.6 Separate investigation cost from regression cost

**During discovery:** Explore naturally; use screenshots and AX tree to identify the problem.  
**Once known:** Encode the route, fixture, action, and assertions.  
**During repetition:** Run the short deterministic scenario.  
**Before release:** Run the important user flows through the actual UI.

### 7.7 Tool-call budgets are heuristics, not proof criteria

For a **local UI-only change**, a useful initial goal is one targeted state setup, one baseline capture, one relevant interaction, and one final verification after rebuild. Exceed that budget when evidence is insufficient, the task involves navigation, or safety/side effects require additional checks.

Do **not** optimize tool counts by skipping the only verification that would establish correctness.

---

## 8. Verification strategy and pass/fail criteria

Every UI fix should begin with a testable hypothesis.

Bad: “The settings page looks better.”

Good: “With fixture `settings-long-localized-text` at 1100×720 in dark mode, the Save button remains fully visible, does not overlap the title, is enabled when changes are pending, and clicking it persists the selected theme.”

### Verification levels

| Level | Evidence | Typical check |
|---|---|---|
| L0 — Build | Compiler/build output | Target built without failure |
| L1 — Screen identity | Router state + AX landmark | Correct screen opened |
| L2 — UI semantics | AX label/ID/value/enabled/hittable | Control is present and actionable |
| L3 — Rendering | Targeted screenshot, snapshot comparison | No clipping/overlap/artifact |
| L4 — Behavior | Data persistence, response, side effect | Save/export/import/etc. actually worked |
| L5 — End-to-end | Real user journey | Navigation/auth/onboarding/back-stack works |

Choose levels based on task risk. For a visual-only issue, L0+L1+L3 may be sufficient. For a saving, navigation, or integration issue, require L4 and/or L5.

**Never claim a visual fix is verified solely from a successful build.**

### Convert important reproductions into XCUIAutomation

Example (assuming the app implements the documented launch arguments and Accessibility ID):

```swift
import XCTest

final class AdvancedSettingsUITests: XCTestCase {
    func testSaveIsAvailableInLongTitleFixture() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--agent-ui",
            "--initial-screen=settings/advanced",
            "--fixture=settings-long-localized-text"
        ]
        app.launch()

        let saveButton = app.buttons["settings.advanced.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertTrue(saveButton.isHittable)
    }
}
```

This is a **real app UI test**, not a unit-test simulation. To verify persistence, extend the test to change a setting, save, reopen the screen, and assert the restored value. The single `isHittable` assertion above is only a minimal example.

Use official Xcode UI-test recording for an initial interaction script, then refactor queries to stable identifiers and add assertions. A recorded interaction sequence without assertions can miss logical failures.

For visual snapshots, evaluate libraries such as [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing), with controlled environment and explicit baseline management.

---

## 9. Custom-drawn UI (Metal, SceneKit, SpriteKit)

For custom-rendered surfaces, the operating system may expose a single canvas-like Accessibility element rather than all interactive objects.

Recommended combination:

1. A debug route that opens the **real rendering scene** with a deterministic fixture.
2. A screenshot of the window or target subregion.
3. A small, read-only structured state export, such as scene ID, selected object ID, camera transform, logical bounds, animation state, asset load failures, draw-call errors.
4. Optional accessible overlays/semantic nodes for buttons and important interactions.
5. Input events for relevant gestures/clicks, followed by state and visual verification.

Avoid making vision infer invisible object IDs, world coordinates, or GPU state when the app can provide them directly. Do not replace a rendering bug with a mocked screenshot scene; the exact renderer, resources, and layout path should be under test.

---

## 10. Reliability, failure handling, and safety

### 10.1 Distinguish a real app failure from automation failure

If an element is not found, investigate:

- Was the correct build launched?
- Did the deep link reach the intended route?
- Is the app in the right window/space/account?
- Is the view still loading or blocked by a sheet?
- Is the Accessibility tree incomplete or truncated?
- Did the element change IDs, become disabled, or move into custom rendering?

Do not immediately treat an automation lookup failure as proof of a UI regression.

### 10.2 Manage side effects safely

- Never run test operations against production customer data or real payment flows.
- Require explicit permission before destructive file operations, account deletion, external messages, payments, or settings changes outside the test environment.
- Never blindly replay non-idempotent actions after timeouts.
- Use isolated app containers/test accounts, deterministic fixtures, and clear data-reset procedures.
- Do not capture secrets in screenshots or log dumps.
- Do not broadly enable foreground/global desktop control unless necessary.

### 10.3 macOS TCC and GUI session considerations

Accessibility and Screen Recording are privacy-controlled permissions (TCC). They apply to the tool/host process and can be affected by signing and execution context. CI and remote sessions must have a real usable GUI environment or supported desktop-automation host; do not assume that an SSH shell alone has screen access.

Since macOS 26, reading another application's app data (for example `~/Library/Application Support/<other app>`) is gated by its own TCC service (`SystemPolicyAppData`, the "would like to access data from other apps" consent) and requires the `NSAppDataUsageDescription` key in the bundle. Apps that touch such paths as part of their normal work should probe them upfront so the single consent appears before work begins, and must degrade honestly — surface per-path denials as issues — when the user declines. Automating TCC consent dialogs from the agent is not a verification technique; a denied-environment run is expected behavior to observe, not a failure to click through.

### 10.4 CI split

Use two test tiers:

- **Fast local agent loop:** directed build, fixture, deep link, AX/visual verification. Interactive, focused, low overhead.
- **CI/regression:** deterministic XCTest/XCUIAutomation tests on prepared macOS runners, with result bundles and screenshots. More complete and reproducible, but costlier.

Keep a few critical end-to-end navigation flows in CI, even when local development uses debug shortcuts.

---

## 11. Recommended repository layout

This is one example; adapt to your existing modular architecture. DiskUnbloat maps it as: feature code under `DiskUnbloat/Features/<Feature>/{Views,ViewModels}` (§11's Features), OS adapters under `DiskUnbloat/Services/<Capability>` (Infrastructure/Diagnostics), the domain core as the `Packages/DiskCore` package, app entry/lifecycle/entitlements in `DiskUnbloat/App`, UI tests in `DiskUnbloatUITests`, and the agent contract in the root `AGENTS.md` plus `Documentation/ARCHITECTURE.md` — no tracked debug-support layer, because the hosted-probe pattern fills the deep-link/fixture role for now (§0 adaptation).

```text
MyApp/
  App/
  Features/
  Infrastructure/
    Navigation/
    Diagnostics/
  DebugSupport/                 # Excluded from release or compiled under DEBUG
    AgentDeepLink.swift
    AgentLaunchConfig.swift
    DebugFixtureLoader.swift
    DebugStateReporter.swift
  TestFixtures/
    settings-default.json
    settings-long-localized-text.json
    profile-appearance-overflow.json
  Tests/
    UnitTests/
    UITests/
  Scripts/
    agent-build.sh
    agent-launch.sh
    agent-reset-fixture.sh
    agent-capture.sh
  docs/
    agent-ui-routes.md
    agent-test-fixtures.md
    agent-test-workflows.md
  AGENTS.md                      # Agent rules and entry points
```

### Route manifest: `docs/agent-ui-routes.md`

Keep each route discoverable without requiring source exploration:

| Route | Required fixture | Screen ID | Useful checks |
|---|---|---|---|
| `settings/advanced` | `settings-long-localized-text` | `screen.settings.advanced` | Save button visible, toggle works |
| `profiles/appearance` | `profile-appearance-overflow` | `screen.profiles.appearance` | Text clipping, layout, theme |
| `projects/editor` | `editor-200-objects` | `screen.projects.editor` | Selection, scroll, renderer |

Document prerequisites, expected evidence, and any reason a direct route is **not** valid for a particular test.

---

## 12. Copy/paste policy for `AGENTS.md` or `CLAUDE.md`

> Adapt bundle IDs, scheme, routes, fixtures, and scripts before using this policy.

```markdown
## Native macOS UI verification policy

The project is a real native macOS application. Build success alone does not
establish correctness for UI changes.

1. Prefer the documented build/launch scripts and existing app architecture.
   Do not rediscover the scheme, bundle ID, or build path on every task.
2. For a deeply nested screen, prefer a debug deep link or launch argument
   with a deterministic fixture. Do not manually click through unrelated
   screens unless testing navigation or when no valid shortcut exists.
3. Debug routes must use the real production router/coordinator and real screen.
   They must not replace the feature with a synthetic UI implementation.
4. Inspect native controls with Accessibility first. Use screenshots/vision
   for layout defects, custom graphics, or ambiguous visual behavior.
5. Prefer stable app accessibility identifiers and semantic actions to
   screenshots and coordinate clicks.
6. Cache route names, fixture IDs and build commands. Never cache PIDs,
   window IDs, snapshot IDs, focus state or element coordinates across runs.
7. Before edits, identify the reproduction steps and expected observable
   outcome. After edits, run the intended newly built .app with the same
   fixture, execute the action and verify actual state.
8. A successfully dispatched UI action is not proof that it worked. If
   outcome is uncertain, observe state before retrying; never blindly repeat
   non-idempotent operations.
9. Query narrow Accessibility subtrees and relevant log excerpts. Capture
   the target app window or region rather than the entire desktop when possible.
10. Avoid redundant screenshots, fixed sleeps, full-repo scans, unnecessary
    rebuilds, and repeated long UI navigation chains.
11. Run real user navigation separately when navigation, authorization,
    back-stack, onboarding or transition behavior matters.
12. Use a test account/local store; never test destructive operations or
    payments in production. Respect macOS privacy permissions.
13. Keep brief evidence: build status, tested route/fixture, action, expected
    vs actual behavior, relevant screenshot/log paths, and remaining risks.
14. Turn important confirmed regressions into deterministic XCUIAutomation
    tests with stable identifiers and assertions.
15. If GUI automation is unavailable, report the limitation instead of
    claiming a runtime UI verification succeeded.
```

---

## 13. Implementation plan by priority

The project-applied version of this plan (what is already done in DiskUnbloat, what is next, and what is a deliberate non-goal) is in the adaptation section after §0. The generic ordering below stays as the baseline:

### P0 — Essential (highest return)

- [ ] Document the correct Debug build and launch command.
- [ ] Install/enable Xcode MCP and one macOS computer-use tool.
- [ ] Verify Accessibility and Screen Recording permissions.
- [ ] Add stable accessibility IDs to key controls and screen landmarks.
- [ ] Add debug-only direct routes for frequently changed deep screens.
- [ ] Add a small fixed set of reliable test fixtures and a reset path.
- [ ] Create `AGENTS.md` with the efficiency and verification policies above.

### P1 — Strong productivity improvement

- [ ] Create a central route manifest.
- [ ] Add launch arguments for clean-start screen and fixture selection.
- [ ] Add lightweight read-only runtime state diagnostics.
- [ ] Add stable app-window screenshot captures and artifact naming.
- [ ] Standardize structured log fields and useful `rg`/`jq` filters.
- [ ] Add an agent script that selects the **newly built** binary reliably.

### P2 — Regression infrastructure

- [ ] Convert recurring defects into XCUIAutomation tests.
- [ ] Introduce snapshot tests for deterministic high-value layouts.
- [ ] Add a short critical-path navigation suite.
- [ ] Run controlled UI tests on a dedicated GUI-capable macOS CI worker.
- [ ] Track flaky tests, ambiguous verification, and time spent per scenario.

---

## 14. Example end-to-end agent assignment

A well-scoped prompt:

> Fix the clipping defect on `profiles/appearance` when the profile title is very long. Use fixture `profile-appearance-overflow` in the Debug app. Reproduce in the real running macOS application, save a targeted before screenshot, implement the fix, rebuild, and verify the same screen and window size with an after screenshot and relevant Accessibility state. Do not navigate via Home/Settings unless required for this defect. Afterwards, perform one normal navigation pass to ensure the screen remains reachable. Report exact evidence and any unverified behavior.

Example concise report format:

```text
Change: Fixed profile title clipping in Appearance settings.
Build: Debug scheme succeeded; launched the newly built app.
Repro: profile-appearance-overflow, 1100x720, dark appearance.
Entry: myapp-debug://screen/profiles/appearance
Before: artifacts/agent-runs/204/before.png
After: artifacts/agent-runs/204/after.png
Behavior: Name no longer clips; Save remains enabled and actionable.
Additional check: Real Settings -> Profiles -> Appearance path succeeded.
Not checked: Other locales and smaller than 900 px window width.
```

---

## 15. Common anti-patterns and replacements

| Anti-pattern | Better approach |
|---|---|
| Build passes, therefore UI is fixed | Run, act, and verify UI + behavior |
| Re-click ten navigation steps after each edit | Debug deep link + deterministic fixture |
| Ask a vision model to find every standard button | AX identifiers and native accessibility actions |
| Capture the entire desktop after each click | Targeted AX read; one app/window screenshot when needed |
| Repeat an action after a timeout | Observe effect first; determine whether retry is safe |
| Store coordinates/PIDs as test state | Store semantic routes/IDs; refresh runtime receipts |
| Use mock views to “verify” a production rendering issue | Open the real view, renderer and data path |
| Use only deep links for navigation QA | Separate real end-to-end user flow tests |
| Dump huge logs into agent context | Query relevant structured log events and save full logs to disk |
| Rebuild every target and rerun all tests on every small edit | Targeted Debug build + focused repro; regressions at checkpoints |
| Hardcode delays for animation/network completion | Wait for specific UI or runtime state |
| Mix several desktop MCP servers in one action chain | Use one primary desktop automation provider per run |

---

## 16. Authoritative references

Documentation and tool surfaces are time-sensitive; verify commands against your installed versions.

### Apple

- [Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode) — Xcode MCP and `xcrun mcpbridge`.
- [SwiftUI `onOpenURL`](https://developer.apple.com/documentation/swiftui/view/onopenurl%28perform%3A%29) — incoming custom URLs.
- [XCTest](https://developer.apple.com/documentation/xctest/) — UI testing and assertions.
- [Recording UI automation for testing](https://developer.apple.com/documentation/xcuiautomation/recording-ui-automation-for-testing) — record and refine real UI scenarios.

### Automation tools

- [Peekaboo project](https://github.com/openclaw/Peekaboo) — native macOS automation.
- [Peekaboo installation](https://peekaboo.sh/install.html).
- [Peekaboo MCP](https://peekaboo.sh/MCP.html).
- [Peekaboo `see` command](https://peekaboo.sh/commands/see.html).
- [Peekaboo `click` command](https://peekaboo.sh/commands/click.html).
- [macos-use](https://github.com/mediar-ai/mcp-server-macos-use) — Accessibility-focused MCP alternative.
- [OpenComputerUse](https://github.com/opensymph/open-computer-use) — cross-platform desktop MCP alternative.
- [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) — optional visual regression support.

---

## Final operating principle

**Make the app observable, addressable, and deterministic.** The AI agent should be spending its effort on identifying and fixing the defect—not repeatedly hunting through the same navigation hierarchy, guessing where to click, or interpreting enormous irrelevant output. Direct routes and fixtures accelerate local verification; genuine app-window interactions and end-to-end flows preserve confidence that the software works for actual users.
