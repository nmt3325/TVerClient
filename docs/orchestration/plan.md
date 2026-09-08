# UI usability improvement plan — 2026-09-08

## Goal
Read the existing SwiftUI implementation, fix user-visible defects, and make browsing, saving, and playback clearer without replacing the native iOS interaction model. Preserve iOS 16 support, offline data, explicit official-player fallbacks, and PiP/audio continuity. Integrate and verify small batches on main; no pull request.

## Shared contract
- Keep existing public model/service and view initializer signatures source-compatible. Shared Contracts/, DesignSystem/, App/, project.yml and generated project are owned by the integrator.
- Use native NavigationStack, List/Section, Button/Menu/Picker and SF Symbols. No tappable gestures in place of accessible controls; no nested buttons/NavigationLinks. Clear Japanese labels and visible primary actions. Prefer readable text and adaptive layouts over shrinking to fit.
- Minimum ordinary touch targets: 44 pt. Support narrow phones, iPad, Dynamic Type, VoiceOver, light/dark and reduced motion. Keep muted states readable; never use color alone.
- Minimize stacked banners and toolbar clutter. Show stale/error status with a recovery action, retain existing data on refresh failure, and never claim cached information is fresh.
- Do not silently turn on downloads, autoplay unrelated content, erase user records, change credentials, bypass access controls, or add dependencies. Do not commit fetched payloads, runtime paths, credentials or operational logs.
- Existing shared APIs may receive additive/defaulted improvements by the integrator. Ask before any cross-boundary edit.

## Ownership and acceptance
| Task | Branch suffix | Owned source paths | Owned regression tests | Acceptance |
| --- | --- | --- | --- | --- |
| catchup | catchup | Features/ScheduleView.swift; Features/ProgramSearchViewModel.swift; Services/ProgramSearchIndex.swift | ScheduleUsabilityRegressionTests.swift; ProgramSearchUsabilityRegressionTests.swift | Search is discoverable; filtering/sorting/empty-state copy is accurate; no duplicate dominant shelves; downloads have visible feedback; no navigation or debounce regressions |
| guide | guide | Features/ProgramGuideView.swift; Guide/ProgramGuideGrid.swift; Guide/ProgramGuideLayout.swift; Guide/ProgramGuideMetrics.swift; Guide/ProgramGuideProgramList.swift | GuideUsabilityRegressionTests.swift | Useful content is visible on a phone; current-time/day navigation and layout/filter controls are clear; grid/list retain scroll correctness and availability routing |
| library | library | Features/LibraryView.swift; Downloads/DownloadButton.swift; Downloads/DownloadConfirmation.swift; Downloads/DownloadStorageBar.swift | LibraryUsabilityRegressionTests.swift | Saved/favorites/history/transfers can be found without scanning one long list; selection/delete semantics are safe; empty and interrupted states have truthful actions |
| player | player | Features/PlaybackView.swift; Features/FullScreenPlaybackView.swift; Features/PlaybackSupportViews.swift; Player/ | PlayerUsabilityRegressionTests.swift | Transport fits narrow/landscape layouts; navigation/actions are unambiguous; metadata adapts; seeking/PiP/full-screen state is preserved; playback failures have recovery |
| integrator | main | All other files, especially RootTabView, LiveView, DesignSystem, Contracts, App, scripts, docs and project generation | Other tests | Active-tab routing, shared typography/layout, live copy/state, baseline + integrated builds/tests + independent review + visual inspection |

All source paths above are relative to TVerClient/. Tests are relative to TVerClientTests/. Implementers may create a small helper inside their owned directory, or their named test files; they must not edit shared files or other tasks' tests.

## Execution and validation
- The integrator creates worktrees from this contract commit. Implementers commit only their own task branches. Only the integrator pushes.
- Each task first reads its implementation and tests, records concrete findings, implements a cohesive first batch and reports within roughly 25 minutes; do not wait to polish everything before handing back a safe batch.
- Cheap child gates: `git diff --check`, `bash scripts/lint.sh`, and `xcrun swiftc -frontend -parse <each changed Swift file>`. Add meaningful XCTest cases for extracted logic or regressions. Report exactly what ran; parsing is not typechecking.
- Heavy Xcode builds, test runs and Simulator operations are serialized by the integrator. Children do not launch them without an explicit slot. DerivedData and results stay task-specific and outside the source tree.
- Integrator gate after each merge: regenerate project as needed, lint/parse, compile, targeted tests. Final gate: full simulator XCTest suite, simulator UI inspection with deterministic data, release device build where feasible, independent read-only review, and clean remote main verification.
- Test failures must be preserved and investigated; do not weaken assertions merely to obtain green status.
- Runtime environment ownership, command/session IDs, cursors and log paths are recorded outside the repository. Each task alone writes its own JSON report with status, base/head SHA, commits, changed files, checks/exit codes/logs, findings, known limits and contract-change requests.
