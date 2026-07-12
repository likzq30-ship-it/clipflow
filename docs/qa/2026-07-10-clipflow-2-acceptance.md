# ClipFlow 2 Acceptance Record

Date: 2026-07-12

Environment:

- macOS 26.5.1 (25F80)
- Xcode `/Applications/Xcode.app` (`xcodebuild`, AppIntents metadata tool reported Xcode 17F113)
- Workspace: `/Users/likzq/Desktop/项目/ClipFlow`
- Test data: synthetic fixture clips only (`Meeting notes`, `https://example.com`, `Project roadmap`, plus synthetic performance rows)

Results:

| Area | Command / Check | Result |
| --- | --- | --- |
| Strict test build | `xcodebuild build-for-testing ... SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES` | Passed |
| Unit tests | `xcodebuild test ... -only-testing:ClipFlowTests` | Passed, 231 tests |
| UI tests | `xcodebuild test ... -only-testing:ClipFlowUITests` | Passed, 10 tests |
| Performance tests | `xcodebuild test -configuration Performance ... -only-testing:ClipFlowTests/RepositoryPerformanceTests -only-testing:ClipFlowTests/QuickPanelPerformanceTests` | Passed, 2 tests |
| Static analysis | `xcodebuild analyze ... SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES` | Passed |
| Legacy removal scan | `rg 'DatabaseService|ClipboardMonitor|OllamaService|TinyLocalAIService|APIUsageStore|CustomCategoryStore|AppDelegate\.shared' ClipFlow` | No matches |
| Process-launch privacy scan | `rg 'Process\s*\(' ClipFlow/Services/AIService.swift ClipFlow/Stores/AIJobCoordinator.swift` | No matches |

Notes:

- Xcode emitted toolchain/system warnings for AppIntents metadata extraction and XCTest libraries targeting newer macOS versions; these did not fail warning-as-error source builds.
- UI automation needed fixture isolation and frontmost-window cleanup because the desktop test host had unrelated app windows. The UI test helper now uses an isolated database and synthetic current-date data so retention cleanup does not delete the fixture during launch.
