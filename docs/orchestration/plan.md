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

## Follow-up recovery and validation

Restore the unintegrated, reviewed layout and gesture changes against published checkpoint `f4077b8`. Restored changes must be reviewed and executed again; an old parsing result is not a new test result. The following narrower ownership supersedes the original implementation assignments until the integrator explicitly assigns the next fix.

| Recovery task | Owned files | Acceptance |
| --- | --- | --- |
| library | Features/LibraryView.swift, its dedicated library-layout helper, and focused library-layout tests | Preserve navigation/action separation and download safeguards; restore full-width accessibility category labels, distinct count styling, and adaptive outer rows |
| guide | Guide/ProgramGuideGrid.swift, Guide/ProgramGuideProgramList.swift, GuideUsabilityRegressionTests.swift | Keep station identity visible after current-row navigation; keep the now marker out of program text, including translucent cards |
| player | Player/PlayerStage.swift, Player/PlayerChromeModel.swift, PlayerGestureContinuityTests.swift | Real touch receipt refreshes only visible chrome; cancelled old hide tasks cannot disable a pending gesture's plane |
| integrator | All other files, snapshot hosting, project generation and shared recovery API changes | Restore the corrected snapshot constraints, inspect actual pixels, execute integrated tests, and verify remote main |

Only the integrator manages Git worktrees, heavy builds, Simulator, integration and pushes. Use separate recovery commits and checkpoint recovered source on a remote work branch before long validation; publish tested batches to main without a PR or force push. Never publish private instructions, runtime ledgers, raw service captures or internal operational identifiers.

The independent follow-up also identified remaining notice-restart safety, driver cancellation/callback ownership, and embedded guide recovery-routing paths. Assign those files explicitly after recovery. Preserve failing evidence and use production-connected regression tests. Static rendering and callback-driven tests do not establish physical touch delivery or real-device PiP behavior.

## Continuation — 2026-09-09

The baseline is `bc1b98d74df2225a68d089eedb7986bc97a1808d`, not the older recovery checkpoints above. The hour-long fullscreen-clock regression is already published and its main CI succeeded. Preserve it; do not reapply the recovered diagnostic or change production layout without a new reproduction.

### Current ownership (supersedes previous task assignments)

Paths below are relative to `TVerClient/`; named tests are relative to `TVerClientTests/`. Existing shared interfaces remain compatible. Exactly one implementer owns each team's source; three read-only specialists per team independently examine user journeys, boundary/test coverage, and regressions. No deeper delegation. Findings are candidates until independently verified.

| Team | Source ownership | Test ownership | Acceptance focus |
| --- | --- | --- | --- |
| t01 | Player/; Features/PlaybackView.swift; Features/FullScreenPlaybackView.swift; Features/PlaybackSupportViews.swift | PlayerFooterLayoutRegressionTests.swift; PlayerGestureContinuityTests.swift; PlayerUsabilityRegressionTests.swift; PlaybackScrubberTests.swift; PlaybackChromeTests.swift; FullScreenPlaybackTests.swift | Accessible controls, active scrub continuity, native bounds and readable clocks |
| t02 | Playback/ | PlaybackControllerTests.swift; PictureInPictureTests.swift; PictureInPictureOwnershipRegressionTests.swift; PausedResolutionRegressionTests.swift; StreamResolverTests.swift | Playback intent, cancellation, PiP ownership and honest recovery |
| t03 | Downloads/AssetDownloadTaskBackend.swift; Downloads/DownloadCenter.swift | AssetDownloadDriverLifecycleTests.swift; DownloadCenterTests.swift; DownloadCellularResumeTests.swift | Native identity, stale callbacks, cancellation and consent-safe restoration |
| t04 | Features/LibraryView.swift; Features/LibraryPresentationLayout.swift; Services/ProgramLibraryStore.swift; Downloads/DownloadButton.swift; Downloads/DownloadConfirmation.swift; Downloads/DownloadStorageBar.swift; Downloads/DownloadNotice.swift; Downloads/SeriesSubscriptionStore.swift | LibraryUsabilityRegressionTests.swift; LibraryAccessibilityLayoutTests.swift; DownloadNoticeRecoveryTests.swift; SeriesSubscriptionStoreTests.swift | Library navigation, trustworthy status, destructive actions and subscriptions |
| t05 | Features/ProgramGuideView.swift; Guide/ except ProgramNotificationListView.swift | ProgramGuideTests.swift; GuideCatchUpRoutingTests.swift; GuideDetailsRegressionTests.swift; GuideLayoutModeTests.swift; GuideUsabilityRegressionTests.swift; GuideZoomMetricsTests.swift; CatchUpAvailabilityStoreTests.swift; CatchUpLookupTests.swift | Date/station navigation, availability, retained content and recovery |
| t06 | Features/ScheduleView.swift; Features/ProgramSearchViewModel.swift; Services/ProgramSearchIndex.swift | ProgramSearchTests.swift; ProgramSearchDebounceRegressionTests.swift; ProgramSearchUsabilityRegressionTests.swift; ScheduleExpiryTests.swift; ScheduleSearchFilterTests.swift; ScheduleUsabilityRegressionTests.swift | Search cancellation, filtering, expiry and actionable empty states |
| t07 | Features/LiveView.swift; Features/LivePresentationText.swift; Area/ | AreaCatalogTests.swift; AreaStoreTests.swift; LiveAreaSelectionTests.swift; LiveOfficialPayloadTests.swift; LivePlaybackSmokeTests.swift; LiveTVTests.swift | Area changes, live identity and explicit fallback behavior |
| t08 | Services/TVerAPIClient.swift; Services/TVerResponseCache.swift; Images/ | TVerAPIClientAreaCacheTests.swift; TVerAPIClientCacheTests.swift; TVerAPIDecodingTests.swift; TVerSeriesAPITests.swift; ProgramImagePipelineTests.swift; ProgramImagePipelineRegressionTests.swift; OfflineCacheTests.swift; OfflineCacheGuideTests.swift | Cache correctness, cancellation, stale responses and image readability |
| t09 | Services/ProgramNotificationScheduler.swift; Guide/ProgramNotificationListView.swift; Features/DiagnosticsView.swift; Services/DiagnosticLogStore.swift; Services/NetworkDiagnosticsService.swift | ProgramNotificationSchedulerTests.swift; ProgramNotificationSlotRegressionTests.swift; DiagnosticLogStoreTests.swift; NetworkDiagnosticsServiceTests.swift | Notification intent, permission handling and truthful diagnostics |
| t10 | DesignSystem/ | DesignSystemTokensTests.swift; AccessibilityCoverageTests.swift | Contrast, semantic text, target sizes and independent UI review |
| integrator | App/; Contracts/; Features/RootTabView.swift; Features/SharedStatusViews.swift; Features/PreviewFixture.swift; all other unassigned paths; project files; scripts; docs | All other tests and integration fixtures | Shared contracts, integration, native validation, visual review and publication |

Each team may change only existing owned files during this batch. A new file or cross-team API change requires an explicit revised assignment. Inspect current tests before adding a regression; do not weaken assertions or hide failures. Preserve iOS 16 compatibility, semantic text sizing, 44-point ordinary controls, native safe-area containment and the 8-point clock gap.

Cheap worker gates are `git diff --check`, `bash scripts/lint.sh`, and `xcrun swiftc -frontend -parse` on changed Swift files. A parse pass is not a typecheck or XCTest pass. Only the integrator runs Xcode, Simulator, native rendering or full tests, one heavy job at a time. Reviewers do not modify source; implementers do not approve their own changes. Report evidence, counterexamples, exact revisions, check results and unverified behavior separately.

Only the integrator merges and pushes; use normal fast-forward-safe main publication, no PR or force push. Leave historical evidence intact. Do not publish runtime/session records, private instructions, raw network captures or credentials. Publish a bounded improvement only after targeted regression, full-suite validation, relevant native-image inspection and independent review; a no-defect outcome is acceptable.
