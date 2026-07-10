# ClipFlow 2.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Deliver ClipFlow 2.0 as a keyboard-first, privacy-aware macOS clipboard manager with a fast menu-bar panel, a full history window, reliable SQLite persistence, bounded AI integrations, automated tests, and a repeatable validated DMG pipeline.

**Architecture:** Keep the AppKit menu-bar lifecycle, but replace shared mutable singletons with a MainActor ClipboardStore and actor-isolated persistence/AI services. Build the UI as two SwiftUI surfaces backed by the same store: a focused quick panel for retrieval/copy and a resizable library window for management, detail, and AI.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, Combine, Swift Concurrency, SQLite3, CryptoKit, Security/Keychain, Carbon hotkeys, XCTest/XCUITest, XcodeGen 2.45.4, Xcode 26.6, macOS 13.0+.

## Global Constraints

- Preserve PRODUCT_BUNDLE_IDENTIFIER as com.clipflow.v12 so existing UserDefaults remain visible.
- Set MARKETING_VERSION to 2.0.0 and CURRENT_PROJECT_VERSION to 200.
- Keep the deployment target at macOS 13.0 and do not use Observation APIs that require macOS 14.
- ClipFlow 2.0 supports text clips only; image, file, rich text, cloud sync, accounts, and Mac App Store distribution are out of scope.
- Production intentionally remains an LSUIElement/accessory menu-bar app with no Dock icon; opening Library activates its window. Only `--ui-testing` switches to `.regular` activation for XCUITest stability.
- Use system-adaptive colors/materials and native source-list selection; no hard-coded light background or card-styled sidebar rows.
- Default retention is 15 days; valid values are 1...365 days or forever.
- Default maximum captured text is 1 MiB.
- AI disabled means zero network requests and zero process launches.
- Local Ollama accepts only localhost, 127.0.0.1, or ::1. Remote AI requires HTTPS plus consent tied to normalized scheme/host/port.
- Never auto-launch Ollama and never store clip text, prompts, or AI results in diagnostics.
- Database directory permissions are 0700; database, WAL, and SHM permissions are 0600; the directory is excluded from backup.
- Single-item deletion is soft for 8 seconds and undoable.
- Repository page size is 100; the quick panel reads at most 50 records.
- All persistent UI changes occur only after repository success. Pasteboard copy remains successful if only its metadata refresh fails.
- Release output is universal arm64+x86_64 and uses Hardened Runtime.
- No source warning is accepted in Debug, Release, Analyze, or strict-concurrency verification.
- Existing unrelated working-tree changes must not be reset, stashed, deleted, or silently included in a task commit.
- After creating, deleting, or renaming any Swift file, run `xcodegen generate` before the next build/test and stage the regenerated `ClipFlow.xcodeproj/project.pbxproj` in that task.
- Every commit uses an exact path allowlist. Before committing, compare `git diff --cached --name-only` with that task's Files list and stop if any unrelated path appears; never use directory-wide `git add` or `git add -A` in this dirty checkout.

## Execution Prerequisite: Dirty Worktree

The current checkout intentionally contains uncommitted source work. Before Task 1, inspect it with:

~~~bash
git status --short
git diff -- ClipFlow ClipFlow.xcodeproj project.yml script
~~~

Re-read every listed diff at execution time; this snapshot is not blanket permission to include later changes. Create one checkpoint commit containing only the in-scope current source baseline below; do not stage README.md, CHANGELOG.md, ClipFlow.dmg, README_CN.md, doex.md, or any other path:

~~~bash
git add ClipFlow.xcodeproj/project.pbxproj \
  ClipFlow/Models/ClipboardItem.swift \
  ClipFlow/Services/OllamaService.swift \
  ClipFlow/Services/TinyLocalAIService.swift \
  ClipFlow/Views/Components/AIGeneratingView.swift \
  ClipFlow/Views/DetailView.swift \
  ClipFlow/Views/SettingsView.swift \
  script/check_bugfixes.sh \
  script/check_tiny_ai.swift
git diff --cached --check
test "$(git diff --cached --name-only | LC_ALL=C sort)" = "$(printf '%s\n' \
  ClipFlow.xcodeproj/project.pbxproj \
  ClipFlow/Models/ClipboardItem.swift \
  ClipFlow/Services/OllamaService.swift \
  ClipFlow/Services/TinyLocalAIService.swift \
  ClipFlow/Views/Components/AIGeneratingView.swift \
  ClipFlow/Views/DetailView.swift \
  ClipFlow/Views/SettingsView.swift \
  script/check_bugfixes.sh \
  script/check_tiny_ai.swift | LC_ALL=C sort)"
git commit -m "chore: checkpoint current ClipFlow source"
~~~

Expected: the commit includes only the listed paths. If the staged diff contains another path, unstage that path before committing.

## Planned File Structure

Create:

- ClipFlow/Models/ClipQuery.swift — per-surface filters, pagination, retention, and raw/classified capture values.
- ClipFlow/Models/CustomCategory.swift — persisted custom-category value.
- ClipFlow/Models/AIModels.swift — provider, operation, request/result/usage values.
- ClipFlow/Persistence/DatabaseError.swift — typed database and migration errors.
- ClipFlow/Persistence/SQLiteDatabase.swift — actor-owned SQLite wrapper.
- ClipFlow/Persistence/DatabaseMigrator.swift — schema creation, migration, backup, permissions.
- ClipFlow/Persistence/MigrationBackupManager.swift — bounded migration-backup lifecycle and deletion.
- ClipFlow/Persistence/ClipboardRepositoryProtocol.swift — exact persistence contract.
- ClipFlow/Persistence/ClipboardRepository.swift — actor-isolated persistence implementation.
- ClipFlow/Persistence/RepositoryStartup.swift — read-write versus read-only-recovery startup state.
- ClipFlow/Privacy/PrivacyGuard.swift — excluded-app, size, and sensitive-text decisions.
- ClipFlow/Privacy/SensitiveContentDetector.swift — deterministic high-confidence rules.
- ClipFlow/Services/PasteboardClient.swift — injectable NSPasteboard boundary.
- ClipFlow/Services/ClipboardCaptureService.swift — idempotent monitoring and writing.
- ClipFlow/Services/CapturePipeline.swift — actor-isolated privacy → classification → persistence pipeline.
- ClipFlow/Services/HTTPClient.swift — injectable URLSession boundary.
- ClipFlow/Services/AIEndpointValidator.swift — local/remote endpoint and consent checks.
- ClipFlow/Services/AIService.swift — actor-isolated AI requests.
- ClipFlow/Services/KeychainCredentialStore.swift — remote credential storage.
- ClipFlow/Services/CarbonHotKeyRegistrar.swift — injectable Carbon registration boundary.
- ClipFlow/Services/LaunchAtLoginService.swift — transactional SMAppService boundary.
- ClipFlow/Services/SleepProvider.swift — injectable undo/cleanup timing boundary.
- ClipFlow/Services/TextClassifier.swift — precompiled deterministic text classification.
- ClipFlow/Stores/AppSettingsStore.swift — MainActor preferences and consent.
- ClipFlow/Stores/ClipboardStore.swift — single UI source of truth.
- ClipFlow/Stores/AIJobCoordinator.swift — item-bound cancellable AI state.
- ClipFlow/Stores/AIActionCoordinator.swift — scene-owned provider/consent orchestration.
- ClipFlow/App/AppCoordinator.swift — status item, popover, library/settings windows.
- ClipFlow/App/RecoveryActionHandler.swift — executable retry/settings/reveal routes.
- ClipFlow/Views/QuickPanel/QuickPanelView.swift
- ClipFlow/Views/QuickPanel/QuickClipRow.swift
- ClipFlow/Views/QuickPanel/QuickPanelKeyboardBridge.swift
- ClipFlow/Views/Library/LibraryView.swift
- ClipFlow/Views/Library/LibrarySidebar.swift
- ClipFlow/Views/Library/ClipListView.swift
- ClipFlow/Views/Library/ClipDetailView.swift
- ClipFlow/Views/Library/AIResultView.swift
- ClipFlow/Views/Library/RemoteConsentSheetPresenter.swift
- ClipFlow/Views/Settings/SettingsRootView.swift
- ClipFlow/Views/Settings/GeneralSettingsView.swift
- ClipFlow/Views/Settings/HotkeySettingsView.swift
- ClipFlow/Views/Settings/PrivacySettingsView.swift
- ClipFlow/Views/Settings/CategorySettingsView.swift
- ClipFlow/Views/Settings/AISettingsView.swift
- ClipFlow/Views/Settings/DiagnosticsSettingsView.swift
- ClipFlow/Views/Shared/ErrorBanner.swift
- ClipFlow/Views/Shared/MonitoringStatusView.swift
- ClipFlow/Diagnostics/AppErrorCode.swift — stable cross-layer error codes.
- ClipFlow/Diagnostics/AppLogger.swift — privacy-marked Logger and content-free diagnostic events.
- ClipFlowTests/... — unit, repository, concurrency, and store tests.
- ClipFlowUITests/... — quick-panel and library keyboard/UI tests.
- script/test.sh
- script/build_release.sh
- script/package_dmg.sh
- script/build_and_run.sh
- .codex/environments/environment.toml
- docs/qa/2026-07-10-clipflow-2-acceptance.md

Replace or remove after consumers migrate:

- ClipFlow/Services/DatabaseService.swift
- ClipFlow/Services/ClipboardMonitor.swift
- ClipFlow/Services/OllamaService.swift
- ClipFlow/Services/TinyLocalAIService.swift
- ClipFlow/Views/ContentView.swift
- ClipFlow/Views/ClipboardListView.swift
- ClipFlow/Views/DetailView.swift
- ClipFlow/Views/SettingsView.swift
- ClipFlow/Views/Components/AIGeneratingView.swift
- ClipFlow/Views/Components/ClipboardItemRow.swift

---

## Specification Coverage Map

| Approved specification | Implementation tasks | Primary evidence |
| --- | --- | --- |
| Goals, principles, scope, and text-only boundary (Sections 1–4) | Tasks 1, 2, 12, 13 | version/model tests, legacy-reference scan, README/release gate |
| Quick panel and window behavior (Sections 5.1, 5.4) | Tasks 8, 9, 12 | command tests, XCUITests, recorded manual acceptance |
| Library and item-bound detail (Section 5.2) | Tasks 6, 7, 10, 12 | store/AI regression tests, library XCUITests, resize acceptance |
| Settings and diagnostics (Section 5.3) | Tasks 6, 8, 11, 12 | settings/service tests, redacted diagnostic test, accessibility acceptance |
| Visual/accessibility contract (Section 5.5) | Tasks 9–12 | identifiers, XCUITests, VoiceOver/contrast/size checklist |
| Component responsibilities (Section 6) | Tasks 3–11 | protocol tests, strict concurrency build, forbidden-singleton scan |
| Data model and migration (Section 7) | Tasks 2–4 | migration, rollback, recovery, NUL, duplicate, paging, permission tests |
| Capture/copy/AI/delete flows (Section 8) | Tasks 5–7, 9–11 | service/store/concurrency tests and XCUITests |
| Error and diagnostic policy (Section 9) | Tasks 3, 4, 6, 7, 11 | typed-error tests, read-only recovery, content-free diagnostic types |
| Test strategy and quality gates (Sections 10–11) | Tasks 1, 12, 13 | unit/UI/performance suites, warnings-as-errors, build/analyze gates |
| Release and completion definition (Sections 12–13) | Tasks 12–13 | universal architecture, signing/notary branch, DMG validation, final audit |

---

### Task 1: Establish the Xcode test target and 2.0 version contract

**Files:**
- Modify: project.yml
- Modify: ClipFlow/Info.plist
- Create: ClipFlowTests/SmokeTests.swift
- Regenerate: ClipFlow.xcodeproj/project.pbxproj

**Interfaces:**
- Consumes: existing ClipFlow app target and XcodeGen configuration.
- Produces: a ClipFlowTests unit-test target included in the ClipFlow scheme; version values available through Bundle.

- [ ] **Step 1: Prove the current scheme has no test action**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/TestDerivedData \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: exit 66 with “Scheme ClipFlow is not currently configured for the test action.”

- [ ] **Step 2: Add the test target and version build settings**

Use this target and scheme shape in project.yml while preserving the existing app bundle ID and source path:

~~~yaml
targets:
  ClipFlow:
    type: application
    platform: macOS
    sources:
      - path: ClipFlow
        excludes:
          - "**/.DS_Store"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.clipflow.v12
        PRODUCT_NAME: ClipFlow
        MARKETING_VERSION: 2.0.0
        CURRENT_PROJECT_VERSION: 200
        SWIFT_VERSION: "5.9"
        MACOSX_DEPLOYMENT_TARGET: "13.0"
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: ""
        INFOPLIST_FILE: ClipFlow/Info.plist
        COMBINE_HIDPI_IMAGES: YES
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks"
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGNING_ALLOWED: YES

  ClipFlowTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: ClipFlowTests
    dependencies:
      - target: ClipFlow
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.clipflow.v12.tests
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGNING_ALLOWED: NO

schemes:
  ClipFlow:
    build:
      targets:
        ClipFlow: all
        ClipFlowTests: [test]
    test:
      gatherCoverageData: true
      targets:
        - name: ClipFlowTests
~~~

Change Info.plist values to:

~~~xml
<key>CFBundleShortVersionString</key>
<string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key>
<string>$(CURRENT_PROJECT_VERSION)</string>
~~~

- [ ] **Step 3: Add a bundle-version smoke test**

Create ClipFlowTests/SmokeTests.swift:

~~~swift
import XCTest
@testable import ClipFlow

final class SmokeTests: XCTestCase {
    func testVersionContract() {
        let info = Bundle(for: AppDelegate.self).infoDictionary
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, "2.0.0")
        XCTAssertEqual(info?["CFBundleVersion"] as? String, "200")
    }
}
~~~

- [ ] **Step 4: Regenerate and run the test target**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/TestDerivedData \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: TEST SUCCEEDED and 1 test passes.

- [ ] **Step 5: Commit**

~~~bash
git add project.yml ClipFlow/Info.plist ClipFlowTests/SmokeTests.swift ClipFlow.xcodeproj/project.pbxproj
git commit -m "test: add ClipFlow unit test target"
~~~

### Task 2: Introduce Sendable domain models without breaking the current UI

**Files:**
- Modify: ClipFlow/Models/ClipboardItem.swift
- Create: ClipFlow/Models/ClipQuery.swift
- Create: ClipFlow/Models/CustomCategory.swift
- Create: ClipFlow/Models/AIModels.swift
- Create: ClipFlowTests/Models/ClipboardItemModelTests.swift
- Create: ClipFlowTests/Models/ClipQueryTests.swift
- Create: ClipFlowTests/Support/TestFixtures.swift

**Interfaces:**
- Consumes: existing category classification and current initializers.
- Produces:
  - ClipboardItem with customCategoryID, createdAt, lastCopiedAt, copyCount, deletedAt.
  - ClipQuery, ClipScope, ClipPage, RetentionPolicy, RawClipboardCapture, CapturedText.
  - PersistedCustomCategory and AI request/result value types.

- [ ] **Step 1: Write failing compatibility and query tests**

Create ClipFlowTests/Models/ClipboardItemModelTests.swift:

~~~swift
import XCTest
@testable import ClipFlow

final class ClipboardItemModelTests: XCTestCase {
    func testLegacyTimestampMapsToCreatedAndLastCopiedAt() {
        let date = Date(timeIntervalSince1970: 123)
        let item = ClipboardItem(content: "hello", timestamp: date)

        XCTAssertEqual(item.createdAt, date)
        XCTAssertEqual(item.lastCopiedAt, date)
        XCTAssertEqual(item.timestamp, date)
        XCTAssertEqual(item.copyCount, 1)
        XCTAssertNil(item.deletedAt)
    }

    func testDisplayCategoryPrefersResolvedCustomName() {
        var item = ClipboardItem(content: "roadmap", category: .english)
        item.customCategoryID = UUID()
        item.customCategory = "工作"
        XCTAssertEqual(item.displayCategory, "工作")
    }
}
~~~

Create ClipFlowTests/Models/ClipQueryTests.swift:

~~~swift
import XCTest
@testable import ClipFlow

final class ClipQueryTests: XCTestCase {
    func testQuickPanelQueryIsBounded() {
        let query = ClipQuery.quickPanel(searchText: "api", favoritesOnly: true)
        XCTAssertEqual(query.limit, 50)
        XCTAssertEqual(query.offset, 0)
        XCTAssertEqual(query.scope, .favorites)
    }

    func testRetentionPolicyValidatesRange() throws {
        XCTAssertEqual(try RetentionPolicy.validatedDays(15).dayCount, 15)
        XCTAssertThrowsError(try RetentionPolicy.validatedDays(0))
        XCTAssertThrowsError(try RetentionPolicy.validatedDays(366))
        XCTAssertNil(RetentionPolicy.forever.dayCount)
    }
}
~~~

- [ ] **Step 2: Run the model tests and confirm the missing APIs**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClipFlowTests/ClipboardItemModelTests \
  -only-testing:ClipFlowTests/ClipQueryTests \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: compilation fails because createdAt, lastCopiedAt, copyCount, deletedAt, ClipQuery, and RetentionPolicy do not exist.

- [ ] **Step 3: Add the exact model contracts**

Keep ContentType and Category temporarily so the current views compile. Make ClipboardItem, ContentType, and Category conform to Sendable and add:

~~~swift
struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var content: String
    var contentType: ContentType
    var category: Category
    var customCategoryID: UUID?
    var customCategory: String?
    var createdAt: Date
    var lastCopiedAt: Date
    var copyCount: Int
    var isFavorite: Bool
    var aiSummary: String?
    var deletedAt: Date?

    var timestamp: Date {
        get { lastCopiedAt }
        set { lastCopiedAt = newValue }
    }
}
~~~

The compatibility initializer must accept the existing timestamp label and initialize both dates:

~~~swift
init(
    id: UUID = UUID(),
    content: String,
    contentType: ContentType = .text,
    category: Category = .other,
    customCategoryID: UUID? = nil,
    customCategory: String? = nil,
    timestamp: Date = Date(),
    createdAt: Date? = nil,
    copyCount: Int = 1,
    isFavorite: Bool = false,
    aiSummary: String? = nil,
    deletedAt: Date? = nil
) {
    self.id = id
    self.content = content
    self.contentType = contentType
    self.category = category
    self.customCategoryID = customCategoryID
    self.customCategory = customCategory
    self.createdAt = createdAt ?? timestamp
    self.lastCopiedAt = timestamp
    self.copyCount = copyCount
    self.isFavorite = isFavorite
    self.aiSummary = aiSummary
    self.deletedAt = deletedAt
}
~~~

Create ClipFlow/Models/ClipQuery.swift with these public contracts:

~~~swift
import Foundation

enum ClipScope: Equatable, Sendable {
    case all
    case favorites
    case today
    case builtIn(ClipboardItem.Category)
    case custom(UUID)
}

struct ClipQuery: Equatable, Sendable {
    var searchText: String
    var scope: ClipScope
    var limit: Int
    var offset: Int

    static func quickPanel(searchText: String, favoritesOnly: Bool) -> Self {
        .init(
            searchText: searchText,
            scope: favoritesOnly ? .favorites : .all,
            limit: 50,
            offset: 0
        )
    }
}

struct ClipPage: Equatable, Sendable {
    var items: [ClipboardItem]
    var nextOffset: Int?
    var totalCount: Int
}

struct DeletedClipTombstone: Equatable, Sendable {
    let itemID: UUID
    let deletedAt: Date
}

enum RetentionPolicy: Equatable, Sendable {
    case days(Int)
    case forever

    var dayCount: Int? {
        switch self {
        case .days(let value): return value
        case .forever: return nil
        }
    }

    static func validatedDays(_ value: Int) throws -> Self {
        guard (1...365).contains(value) else {
            throw ValidationError.invalidRetentionDays(value)
        }
        return .days(value)
    }
}

enum ValidationError: Error, Equatable, Sendable {
    case invalidRetentionDays(Int)
}

struct RawClipboardCapture: Equatable, Sendable {
    var content: String
    var capturedAt: Date
    var sourceBundleID: String?
}

struct CapturedText: Equatable, Sendable {
    var content: String
    var category: ClipboardItem.Category
    var capturedAt: Date
    var sourceBundleID: String?
}
~~~

Create PersistedCustomCategory and the AI value types exactly as referenced by later tasks:

~~~swift
struct PersistedCustomCategory: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var name: String
    var prompt: String
    var sortOrder: Int
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
}

enum AIOperation: String, Codable, Sendable {
    case summarize
    case categorize
    case rewrite
}

struct AIJobKey: Hashable, Sendable {
    let itemID: UUID
    let operation: AIOperation
}

struct AIRequest: Equatable, Sendable {
    let itemID: UUID
    let operation: AIOperation
    let text: String
    let allowedCategories: [PersistedCustomCategory]
}

struct AIResult: Equatable, Sendable {
    let itemID: UUID
    let operation: AIOperation
    let text: String
    let providerLabel: String
}

enum AIProviderKind: String, Codable, Sendable {
    case disabled
    case localOllama
    case remoteHTTPS
}

struct AIUsageRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let operation: AIOperation
    let timestamp: Date
    let provider: String
    let model: String
    let durationMilliseconds: Int
    let succeeded: Bool
    let errorCode: String?
}
~~~

Create ClipFlowTests/Support/TestFixtures.swift after the production types exist:

~~~swift
import Foundation
@testable import ClipFlow

extension RawClipboardCapture {
    static func fixture(
        _ content: String,
        at timestamp: TimeInterval = 0,
        sourceBundleID: String? = nil
    ) -> Self {
        .init(
            content: content,
            capturedAt: Date(timeIntervalSince1970: timestamp),
            sourceBundleID: sourceBundleID
        )
    }
}

extension CapturedText {
    static func fixture(
        _ content: String,
        at timestamp: TimeInterval = 0,
        sourceBundleID: String? = nil,
        category: ClipboardItem.Category = .english
    ) -> Self {
        .init(
            content: content,
            category: category,
            capturedAt: Date(timeIntervalSince1970: timestamp),
            sourceBundleID: sourceBundleID
        )
    }
}

extension ClipboardItem {
    static func fixture(
        content: String = "fixture",
        at timestamp: TimeInterval = 0,
        customCategoryID: UUID? = nil
    ) -> Self {
        .init(
            content: content,
            category: .english,
            customCategoryID: customCategoryID,
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }
}

extension AIRequest {
    static func fixture(itemID: UUID = UUID()) -> Self {
        .init(
            itemID: itemID,
            operation: .summarize,
            text: "fixture",
            allowedCategories: []
        )
    }
}

extension PersistedCustomCategory {
    static func fixture(name: String, sortOrder: Int) -> Self {
        let now = Date(timeIntervalSince1970: 0)
        return .init(
            id: UUID(),
            name: name,
            prompt: "",
            sortOrder: sortOrder,
            isEnabled: true,
            createdAt: now,
            updatedAt: now
        )
    }
}
~~~

- [ ] **Step 4: Run the model tests**

Run the command from Step 2.

Expected: both test classes pass and the existing app target still compiles.

- [ ] **Step 5: Commit**

~~~bash
git add ClipFlow/Models/ClipboardItem.swift ClipFlow/Models/ClipQuery.swift \
  ClipFlow/Models/CustomCategory.swift ClipFlow/Models/AIModels.swift \
  ClipFlowTests/Models/ClipboardItemModelTests.swift \
  ClipFlowTests/Models/ClipQueryTests.swift ClipFlowTests/Support/TestFixtures.swift \
  ClipFlow.xcodeproj/project.pbxproj
git commit -m "refactor: add ClipFlow 2 domain models"
~~~

### Task 3: Build the SQLite migration and permission foundation

**Files:**
- Create: ClipFlow/Persistence/DatabaseError.swift
- Create: ClipFlow/Persistence/SQLiteDatabase.swift
- Create: ClipFlow/Persistence/DatabaseMigrator.swift
- Create: ClipFlow/Persistence/MigrationBackupManager.swift
- Create: ClipFlowTests/Persistence/DatabaseMigratorTests.swift
- Create: ClipFlowTests/Persistence/MigrationBackupManagerTests.swift
- Create: ClipFlowTests/Support/DatabaseFixture.swift

**Interfaces:**
- Consumes: ClipboardItem, PersistedCustomCategory, legacy clipboard_items schema.
- Produces:
  - SQLiteDatabase.execute, prepare, withTransaction, columnNames.
  - DatabaseMigrator.prepare(databaseURL:legacyCategories:).
  - DatabasePreparation with searchMode and recovered categories.

~~~swift
enum SearchMode: Equatable, Sendable {
    case fts5
    case parameterizedContains
}

struct LegacyCustomCategoryV1: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var prompt: String
}

struct LegacySettingsSnapshot: Equatable, Sendable {
    var categories: [LegacyCustomCategoryV1]
    var hadAIEnabled: Bool
    var hadOllamaURL: Bool
    var hadAPIUsageRecords: Bool

    func migratedCategories(now: Date) -> [PersistedCustomCategory]
}

struct DatabasePreparation: Equatable, Sendable {
    var schemaVersion: Int
    var searchMode: SearchMode
    var recoveredCategories: [PersistedCustomCategory]
    var backupURL: URL?
}

protocol MigrationBackupManaging: Sendable {
    func backupURLs() async throws -> [URL]
    func purgeExpired(now: Date) async throws -> Int
    func deleteAll() async throws
}

protocol MigrationBackupFileSystem: Sendable {
    func matchingBackupURLs(in directory: URL) async throws -> [URL]
    func modificationDate(at url: URL) async throws -> Date
    func removeItem(at url: URL) async throws
}

actor LocalMigrationBackupFileSystem: MigrationBackupFileSystem {}

actor MigrationBackupManager: MigrationBackupManaging {
    static let maximumAge: TimeInterval = 24 * 60 * 60
    init(
        databaseDirectory: URL,
        fileSystem: any MigrationBackupFileSystem = LocalMigrationBackupFileSystem()
    )
}
~~~

- [ ] **Step 1: Write migration, permission, and rollback tests**

Create ClipFlowTests/Persistence/DatabaseMigratorTests.swift with:

~~~swift
import SQLite3
import XCTest
@testable import ClipFlow

final class DatabaseMigratorTests: XCTestCase {
    func testCreatesFreshV2DatabaseAndPrepareIsIdempotent() throws {
        let fixture = try DatabaseFixture()
        let first = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )
        let second = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )

        XCTAssertEqual(first.schemaVersion, 2)
        XCTAssertEqual(second.schemaVersion, 2)
        XCTAssertTrue(fixture.columnNames("clipboard_items").contains("content_hash"))
        XCTAssertEqual(fixture.scalarInt("SELECT COUNT(*) FROM clipboard_items"), 0)
    }

    func testMigratesLegacyRowsAndBackfillsV2Columns() throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        try fixture.insertLegacyClip(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            content: "hello\u{0}world",
            category: "english",
            customCategory: "Recovered",
            timestamp: 100
        )

        let category = PersistedCustomCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Work",
            prompt: "project",
            sortOrder: 0,
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let preparation = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: [category]
        )

        XCTAssertEqual(preparation.schemaVersion, 2)
        XCTAssertTrue(fixture.columnNames("clipboard_items").contains("content_hash"))
        XCTAssertTrue(fixture.columnNames("clipboard_items").contains("builtin_category"))
        XCTAssertTrue(fixture.columnNames("clipboard_items").contains("last_copied_at"))
        XCTAssertTrue(fixture.columnNames("clipboard_items").contains("deleted_at"))
        XCTAssertEqual(fixture.scalarInt("SELECT copy_count FROM clipboard_items"), 1)
        XCTAssertEqual(fixture.scalarText("SELECT content FROM clipboard_items"), "hello\u{0}world")
        XCTAssertTrue(preparation.recoveredCategories.contains { $0.name == "Recovered" })
    }

    func testMigrationFailureRollsBackLegacySchema() throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        fixture.failNextStatement(containing: "ALTER TABLE")

        XCTAssertThrowsError(
            try DatabaseMigrator.prepare(
                database: fixture.database,
                databaseURL: fixture.url,
                legacyCategories: []
            )
        )
        XCTAssertFalse(fixture.columnNames("clipboard_items").contains("content_hash"))
    }

    func testAppliesPrivateFilePermissions() throws {
        let fixture = try DatabaseFixture()
        _ = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )
        let mode = try fixture.posixMode(at: fixture.url)
        XCTAssertEqual(mode & 0o777, 0o600)
        XCTAssertEqual(try fixture.posixMode(at: fixture.url.deletingLastPathComponent()) & 0o777, 0o700)
        XCTAssertTrue(try fixture.isExcludedFromBackup(fixture.url.deletingLastPathComponent()))
    }
}
~~~

Add `testOnlineBackupIncludesCommittedWALRows` that enables WAL, inserts and commits `"wal\u{0}row"` while the WAL exists, migrates, opens `preparation.backupURL` read-only, runs `PRAGMA integrity_check`, and asserts the row, legacy schema, NUL text, and `0600` mode. Add `testProductionBinderRoundTripsEmptyNULAndEmoji` that writes `""`, `"a\u{0}b"`, and `"👍🏽"` through SQLiteDatabase and reads them through its production column API. Add real filesystem fixtures for: a valid v1 DB chmod `0400` (readable recovery, every mutation rejected), a main file containing non-SQLite bytes (typed blocking error; SHA-256/size unchanged; no replacement DB), and a damaged WAL/SHM pair (either verified recovery or typed blocking with original files unchanged). Also assert every existing database, `-wal`, and `-shm` file is `0600`. DatabaseFixture is a test-only helper that owns the same SQLiteDatabase passed into DatabaseMigrator, exposes scalar reads/resource values, and injects a statement failure through SQLiteDatabase.statementInterceptorForTesting. Its scalarText implementation uses sqlite3_column_bytes plus String(decoding:as:), never String(cString:). Put it at ClipFlowTests/Support/DatabaseFixture.swift.

MigrationBackupManagerTests create sentinel backups matching only `clipflow.sqlite3.backup-*`, prove files younger than 24 hours remain, files at/over 24 hours are removed, unrelated files are untouched, and deleteAll removes every managed backup. Inject a failing MigrationBackupFileSystem and assert deletion throws rather than reporting success.

- [ ] **Step 2: Run the migration tests and confirm failure**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClipFlowTests/DatabaseMigratorTests \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: compilation fails because DatabaseMigrator and SQLiteDatabase do not exist.

- [ ] **Step 3: Implement the SQLite wrapper and schema migration**

DatabaseError must be explicit:

~~~swift
enum DatabaseError: LocalizedError, Equatable, Sendable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case migrationFailed(message: String, databaseURL: URL, backupURL: URL?)
    case itemNotFound(UUID)
    case readOnlyRecovery(databaseURL: URL, backupURL: URL?)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "无法打开剪贴板数据库：\(message)"
        case .prepareFailed(let message): return "无法准备数据库操作：\(message)"
        case .stepFailed(let message): return "无法写入剪贴板数据库：\(message)"
        case .migrationFailed(let message, _, _): return "数据库升级失败：\(message)"
        case .itemNotFound: return "剪贴板记录已不存在"
        case .readOnlyRecovery: return "数据库已进入只读恢复模式"
        }
    }
}
~~~

SQLiteDatabase owns the OpaquePointer and always binds String values with explicit byte length:

~~~swift
func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) throws {
    let bytes = value.utf8CString
    let result = bytes.withUnsafeBufferPointer { buffer in
        sqlite3_bind_text(
            statement,
            index,
            buffer.baseAddress,
            Int32(bytes.count - 1),
            sqliteTransient
        )
    }
    guard result == SQLITE_OK else {
        throw DatabaseError.stepFailed(lastError)
    }
}
~~~

Its columnString method reads sqlite3_column_bytes and constructs String(decoding: bytes, as: UTF8.self), preserving embedded U+0000. withTransaction reapplies 0600 to the database, WAL, and SHM after commit so files created after startup cannot retain a broader umask-derived mode.

DatabaseMigrator must:

1. Create the parent directory, set it to 0700, and exclude it from backup.
2. Open the database and create a timestamped, `0600` consistent backup before changing an existing schema. Use the SQLite online backup API, then open the backup read-only and require `PRAGMA integrity_check = 'ok'`; never copy only the main file of a WAL database.
3. Run all DDL/backfill operations in one transaction. For a real v1 table, rename it to `clipboard_items_v1`, create the canonical v2 table, copy/transcode every row, validate row counts/hashes, then drop the v1 table before commit.
4. Create custom_categories (including unique normalized_name) and ai_usage.
5. During the v1→v2 copy, map category → builtin_category, custom category name → stable ID, and timestamp → both created_at and last_copied_at; set copy_count to 1.
6. Compute SHA-256 in Swift from the complete UTF-8 content before inserting each canonical row.
7. Import known legacy categories by stable UUID and a trimmed/case-folded normalized_name.
8. Turn unknown custom_category strings into disabled recovered categories; reuse an existing normalized name instead of creating duplicates.
9. Set PRAGMA user_version = 2.
10. Set the database, -wal, and -shm modes to 0600 whenever those files exist.

Expose two prepare entrypoints:

~~~swift
static func prepare(
    databaseURL: URL,
    legacyCategories: [PersistedCustomCategory]
) throws -> DatabasePreparation

static func prepare(
    database: SQLiteDatabase,
    databaseURL: URL,
    legacyCategories: [PersistedCustomCategory]
) throws -> DatabasePreparation
~~~

The first is production API and opens SQLiteDatabase. The second is internal/test API and makes failure injection exercise the real transaction and rollback path.

For a directory with no `clipboard_items`, create the canonical v2 table directly. If the table exists with `user_version == 0`, treat it as legacy and use the additive migration path. Both paths finish at `user_version = 2`; running prepare twice is a no-op. Use these schema statements:

~~~sql
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS clipboard_items (
    id TEXT PRIMARY KEY NOT NULL,
    content TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    builtin_category TEXT NOT NULL,
    custom_category_id TEXT REFERENCES custom_categories(id) ON DELETE SET NULL,
    created_at REAL NOT NULL,
    last_copied_at REAL NOT NULL,
    copy_count INTEGER NOT NULL DEFAULT 1 CHECK(copy_count >= 1),
    is_favorite INTEGER NOT NULL DEFAULT 0 CHECK(is_favorite IN (0, 1)),
    ai_summary TEXT,
    deleted_at REAL
);

CREATE TABLE IF NOT EXISTS custom_categories (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    normalized_name TEXT NOT NULL UNIQUE,
    prompt TEXT NOT NULL,
    sort_order INTEGER NOT NULL,
    is_enabled INTEGER NOT NULL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS ai_usage (
    id TEXT PRIMARY KEY,
    operation TEXT NOT NULL,
    timestamp REAL NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    duration_ms INTEGER NOT NULL,
    succeeded INTEGER NOT NULL,
    error_code TEXT
);

CREATE INDEX IF NOT EXISTS idx_clips_last_copied
ON clipboard_items(deleted_at, last_copied_at DESC);

CREATE INDEX IF NOT EXISTS idx_clips_hash
ON clipboard_items(content_hash, deleted_at);

CREATE INDEX IF NOT EXISTS idx_clips_category
ON clipboard_items(deleted_at, builtin_category, custom_category_id);
~~~

The committed v2 table contains only the canonical columns above; legacy `content_type`, `category`, `custom_category`, and `timestamp` remain only in the verified backup. Transaction rollback restores the original v1 table if any rename/copy/validation/drop step fails. If migration throws, attach the original database URL and backup URL to `DatabaseError.migrationFailed`; never delete, rename over, or recreate that database in the failure path.

Add `testRealV1MigrationSupportsAllV2MutationsAndReopen`: create the exact current v1 schema (including NOT NULL `content_type` and `timestamp` without defaults), migrate, then run upsert, markCopied, setCustomCategory, soft-delete/restore, close, reopen, and assert all values. Also assert the committed v2 table no longer contains legacy columns. This is the release-blocking regression for upgraded users.

DatabaseMigrator also owns FTS capability detection and schema creation so `DatabasePreparation.searchMode` has one owner. Probe a temporary FTS5 table, then create `clip_search` and its insert/update/delete triggers only when absent; otherwise return `.parameterizedContains`. Repeated prepare must not recreate existing FTS objects or triggers.

~~~sql
CREATE VIRTUAL TABLE temp.clipflow_fts_probe USING fts5(content);
DROP TABLE temp.clipflow_fts_probe;
CREATE VIRTUAL TABLE IF NOT EXISTS clip_search
USING fts5(content, content='clipboard_items', content_rowid='rowid');
CREATE TRIGGER IF NOT EXISTS clips_fts_insert AFTER INSERT ON clipboard_items BEGIN
  INSERT INTO clip_search(rowid, content) VALUES (new.rowid, new.content);
END;
CREATE TRIGGER IF NOT EXISTS clips_fts_delete AFTER DELETE ON clipboard_items BEGIN
  INSERT INTO clip_search(clip_search, rowid, content)
  VALUES ('delete', old.rowid, old.content);
END;
CREATE TRIGGER IF NOT EXISTS clips_fts_update AFTER UPDATE OF content ON clipboard_items BEGIN
  INSERT INTO clip_search(clip_search, rowid, content)
  VALUES ('delete', old.rowid, old.content);
  INSERT INTO clip_search(rowid, content) VALUES (new.rowid, new.content);
END;
INSERT INTO clip_search(clip_search) VALUES ('rebuild');
~~~

Run the rebuild only when the FTS table is first created; on later prepare calls verify the objects exist and skip it.

- [ ] **Step 4: Run migration tests and the full unit suite**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: TEST SUCCEEDED; NUL text, rollback, recovered category, and permission assertions pass.

- [ ] **Step 5: Commit**

~~~bash
git add ClipFlow/Persistence/DatabaseError.swift ClipFlow/Persistence/SQLiteDatabase.swift \
  ClipFlow/Persistence/DatabaseMigrator.swift ClipFlow/Persistence/MigrationBackupManager.swift \
  ClipFlowTests/Persistence/DatabaseMigratorTests.swift \
  ClipFlowTests/Persistence/MigrationBackupManagerTests.swift \
  ClipFlowTests/Support/DatabaseFixture.swift ClipFlow.xcodeproj/project.pbxproj
git commit -m "feat: add safe ClipFlow database migration"
~~~

### Task 4: Implement actor-isolated repository behavior

**Files:**
- Create: ClipFlow/Persistence/ClipboardRepositoryProtocol.swift
- Create: ClipFlow/Persistence/ClipboardRepository.swift
- Create: ClipFlowTests/Persistence/ClipboardRepositoryTests.swift
- Create: ClipFlowTests/Support/InMemoryRepository.swift
- Create: ClipFlowTests/Support/TestRepositoryFactory.swift

**Interfaces:**
- Consumes: SQLiteDatabase, DatabaseMigrator, ClipQuery, CapturedText, RetentionPolicy.
- Produces the persistence contract used by every later store and service:

~~~swift
enum RepositoryStartup: Equatable, Sendable {
    case readWrite(DatabasePreparation)
    case readOnlyRecovery(databaseURL: URL, backupURL: URL?, errorCode: String)

    var isReadOnly: Bool {
        if case .readOnlyRecovery = self { return true }
        return false
    }
}

actor ClipboardRepository {
    init(databaseURL: URL)
    func prepare(legacyCategories: [PersistedCustomCategory]) throws -> RepositoryStartup
    func startupState() -> RepositoryStartup?
}
~~~

~~~swift
protocol ClipboardRepositoryProtocol: Sendable {
    func fetchPage(_ query: ClipQuery) async throws -> ClipPage
    func item(id: UUID) async throws -> ClipboardItem?
    func upsertCapturedText(_ capture: CapturedText) async throws -> ClipboardItem
    func markCopied(id: UUID, at: Date) async throws -> ClipboardItem
    func setFavorite(id: UUID, isFavorite: Bool) async throws -> ClipboardItem
    func setSummary(id: UUID, summary: String?) async throws -> ClipboardItem
    func setCustomCategory(id: UUID, categoryID: UUID?) async throws -> ClipboardItem
    func activateAIJob(_ key: AIJobKey, generation: UUID) async
    func cancelAIJob(_ key: AIJobKey, generation: UUID) async
    func setSummaryIfCurrent(
        id: UUID,
        summary: String?,
        key: AIJobKey,
        generation: UUID
    ) async throws -> ClipboardItem?
    func setCustomCategoryIfCurrent(
        id: UUID,
        categoryID: UUID?,
        key: AIJobKey,
        generation: UUID
    ) async throws -> ClipboardItem?
    func softDelete(id: UUID, at: Date) async throws
    func deletedTombstones(since: Date) async throws -> [DeletedClipTombstone]
    func restore(id: UUID) async throws
    func purgeDeleted(id: UUID) async throws
    func purgeDeleted(before: Date) async throws -> Int
    func countForCleanup(retention: RetentionPolicy, now: Date) async throws -> Int
    func cleanup(retention: RetentionPolicy, now: Date) async throws -> Int
    func countAllClips() async throws -> Int
    func deleteAllClipboardData() async throws -> Int
    func fetchCategories() async throws -> [PersistedCustomCategory]
    func saveCategory(_ category: PersistedCustomCategory) async throws
    func reorderCategories(ids: [UUID]) async throws
    func deleteCategory(id: UUID, migrateTo replacementID: UUID?) async throws
    func addAIUsage(_ record: AIUsageRecord) async throws
    func fetchAIUsage(limit: Int) async throws -> [AIUsageRecord]
    func clearAIUsage() async throws
}
~~~

- [ ] **Step 1: Write repository behavior tests**

Create tests for all public mutations. The core regression tests must contain:

~~~swift
func testDuplicateCaptureRefreshesExistingRowAndPreservesMetadata() async throws {
    let repository = try await makeRepository()
    let first = try await repository.upsertCapturedText(
        CapturedText(
            content: "same",
            category: .english,
            capturedAt: Date(timeIntervalSince1970: 10),
            sourceBundleID: "com.example.one"
        )
    )
    _ = try await repository.setFavorite(id: first.id, isFavorite: true)
    _ = try await repository.setSummary(id: first.id, summary: "summary")

    let second = try await repository.upsertCapturedText(
        CapturedText(
            content: "same",
            category: .english,
            capturedAt: Date(timeIntervalSince1970: 20),
            sourceBundleID: "com.example.two"
        )
    )

    XCTAssertEqual(second.id, first.id)
    XCTAssertEqual(second.lastCopiedAt, Date(timeIntervalSince1970: 20))
    XCTAssertEqual(second.copyCount, 2)
    XCTAssertTrue(second.isFavorite)
    XCTAssertEqual(second.aiSummary, "summary")
}

func testSoftDeleteCanRestoreWithinUndoWindow() async throws {
    let repository = try await makeRepository()
    let item = try await repository.upsertCapturedText(.fixture("undo"))

    try await repository.softDelete(id: item.id, at: Date(timeIntervalSince1970: 30))
    let deleted = try await repository.item(id: item.id)
    XCTAssertNil(deleted)

    try await repository.restore(id: item.id)
    let restored = try await repository.item(id: item.id)
    XCTAssertEqual(restored?.content, "undo")
}

func testCleanupUsesLastCopiedAtAndKeepsFavorites() async throws {
    let repository = try await makeRepository()
    let old = try await repository.upsertCapturedText(.fixture("old", at: 0))
    let favorite = try await repository.upsertCapturedText(.fixture("favorite", at: 0))
    _ = try await repository.setFavorite(id: favorite.id, isFavorite: true)

    let removed = try await repository.cleanup(
        retention: .days(15),
        now: Date(timeIntervalSince1970: 20 * 86_400)
    )

    XCTAssertEqual(removed, 1)
    let removedItem = try await repository.item(id: old.id)
    let keptFavorite = try await repository.item(id: favorite.id)
    XCTAssertNil(removedItem)
    XCTAssertNotNil(keptFavorite)
}

func testSearchIsBoundAndParameterised() async throws {
    let repository = try await makeRepository()
    _ = try await repository.upsertCapturedText(.fixture("100%_literal"))
    let page = try await repository.fetchPage(
        .init(searchText: "%_", scope: .all, limit: 100, offset: 0)
    )
    XCTAssertEqual(page.items.map(\.content), ["100%_literal"])
}
~~~

Also test today, built-in/custom scopes, stable pagination with equal timestamps, category clear/migration/reorder transactions, delete-all, AI usage capped at 200, clear-AI-usage, and `DatabaseError.itemNotFound` for every missing-ID mutation.

Add a recovery regression that prepares a legacy database through an injected failing SQLiteDatabase, then asserts:

~~~swift
func testMigrationFailureReopensLegacyDatabaseReadOnly() async throws {
    let fixture = try DatabaseFixture()
    try fixture.createLegacySchema()
    let legacyID = UUID()
    try fixture.insertLegacyClip(
        id: legacyID,
        content: "recover me",
        category: "english",
        customCategory: nil,
        timestamp: 10
    )
    fixture.failNextStatement(containing: "ALTER TABLE")
    let repository = ClipboardRepository(
        database: fixture.database,
        databaseURL: fixture.url
    )

    let startup = try await repository.prepare(legacyCategories: [])
    XCTAssertTrue(startup.isReadOnly)
    let page = try await repository.fetchPage(
        .init(searchText: "", scope: .all, limit: 100, offset: 0)
    )
    XCTAssertEqual(page.items.map(\.id), [legacyID])

    do {
        _ = try await repository.setFavorite(id: legacyID, isFavorite: true)
        XCTFail("read-only recovery must reject mutations")
    } catch let error as DatabaseError {
        guard case .readOnlyRecovery = error else {
            return XCTFail("unexpected \(error)")
        }
    }
}
~~~

Use an internal `ClipboardRepository(database:databaseURL:)` initializer only in this test. The recovery reader inspects legacy columns and maps absent 2.0 values to safe defaults; it must preserve complete NUL-containing text. A corrupt database that cannot be read even in read-only mode remains a typed blocking startup error rather than causing an empty database to be created.

Create ClipFlowTests/Support/TestRepositoryFactory.swift with the repository constructor used by repository and performance tests:

~~~swift
func makeRepository() async throws -> ClipboardRepository {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent("clipflow.sqlite3")
    let repository = ClipboardRepository(databaseURL: url)
    let startup = try await repository.prepare(legacyCategories: [])
    guard case .readWrite = startup else {
        throw DatabaseError.readOnlyRecovery(databaseURL: url, backupURL: nil)
    }
    return repository
}
~~~

- [ ] **Step 2: Run tests and verify they fail because the repository is absent**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClipFlowTests/ClipboardRepositoryTests \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: compilation fails on ClipboardRepositoryProtocol and ClipboardRepository.

- [ ] **Step 3: Implement repository SQL and search fallback**

ClipboardRepository is an actor. It calls DatabaseMigrator during prepare and keeps SQLiteDatabase actor-owned. On a migration failure after rollback, it reopens the untouched original with `SQLITE_OPEN_READONLY`, stores `.readOnlyRecovery`, and keeps fetchPage/item/fetchCategories available through a legacy-column projection. Every mutation first checks startup state and throws `DatabaseError.readOnlyRecovery`. If even read-only open or schema inspection fails, prepare throws and AppCoordinator shows the blocking startup surface.

For upsert:

1. Compute SHA-256 from complete UTF-8 Data.
2. Query candidates by content_hash and deleted_at IS NULL.
3. Compare complete Swift String values to rule out collisions.
4. Update last_copied_at and copy_count on a match.
5. Insert a new row otherwise.

Consume the `searchMode` produced by DatabaseMigrator. For FTS5, encode each whitespace-delimited search token as a quoted FTS literal and bind the final MATCH expression. If FTS parsing still fails for a user query, fall back to parameterized LIKE for that query rather than surfacing a database syntax error.

For `.parameterizedContains`, escape backslash, `%`, and `_` in Swift, wrap the escaped value in `%...%`, and bind it to:

~~~sql
SELECT i.*, c.name
FROM clipboard_items i
LEFT JOIN custom_categories c ON c.id = i.custom_category_id
WHERE i.deleted_at IS NULL
  AND (? = '' OR lower(i.content) LIKE lower(?) ESCAPE '\')
ORDER BY i.last_copied_at DESC, i.id DESC
LIMIT ? OFFSET ?;
~~~

The parameterized-LIKE fallback is the expected path on the current toolchain. It must use bound parameters, LIMIT, and OFFSET. Every repository ordering adds `i.id DESC` after `last_copied_at DESC` so pages are stable when timestamps are equal.

InMemoryRepository must implement the same protocol and include explicit error injection:

~~~swift
actor InMemoryRepository: ClipboardRepositoryProtocol {
    enum InjectedFailure: Error { case requested }
    var items: [UUID: ClipboardItem] = [:]
    var categories: [UUID: PersistedCustomCategory] = [:]
    var usage: [AIUsageRecord] = []
    var failNextMutation = false

    private func consumeFailure() throws {
        if failNextMutation {
            failNextMutation = false
            throw InjectedFailure.requested
        }
    }

    func setFailNextMutation(_ value: Bool) {
        failNextMutation = value
    }

    @discardableResult
    func seed(_ item: ClipboardItem) -> ClipboardItem {
        items[item.id] = item
        return item
    }

    func seedCategory(name: String) -> PersistedCustomCategory {
        let now = Date(timeIntervalSince1970: 0)
        let category = PersistedCustomCategory(
            id: UUID(),
            name: name,
            prompt: "",
            sortOrder: 0,
            isEnabled: true,
            createdAt: now,
            updatedAt: now
        )
        categories[category.id] = category
        return category
    }
}
~~~

`saveCategory` enforces the same trimmed/case-folded normalized-name uniqueness as SQLite, so AI name-to-ID resolution is unambiguous. `countAllClips` includes active and soft-deleted rows. `deleteCategory`, `reorderCategories`, cleanup, and `deleteAllClipboardData` each use one transaction. `deleteAllClipboardData` deletes all clipboard rows (including favorites/soft-deleted rows) and all `ai_usage` rows atomically, but preserves categories. A nil category replacement clears `custom_category_id`; a non-nil replacement must exist and cannot equal the deleted ID. `addAIUsage` deletes rows outside the newest 200 in the same transaction. No repository error message or usage row includes clip content.

ClipboardRepository also owns an in-memory `[AIJobKey: UUID]` generation ledger. `activateAIJob`/`cancelAIJob` linearize generation changes on the repository actor. Conditional AI mutations check the generation inside that same actor immediately before a synchronous SQLite transaction and do not suspend between check and commit; nil means stale/cancelled. Tests inject a gate *inside the repository method before the generation check*, cancel/replace while the actor is reentrant, release the gate, and prove the stale write never commits. Cancellation that returns after a transaction's check/commit linearization point cannot retroactively undo that already-completed commit; UI cancellation awaits repository invalidation before reporting cancelled.

- [ ] **Step 4: Run repository tests and full tests**

Run the repository-only command, then the full Task 3 test command.

Expected: all repository tests and the full unit suite pass.

- [ ] **Step 5: Commit**

~~~bash
git add ClipFlow/Persistence/RepositoryStartup.swift \
  ClipFlow/Persistence/ClipboardRepositoryProtocol.swift \
  ClipFlow/Persistence/ClipboardRepository.swift \
  ClipFlowTests/Persistence/ClipboardRepositoryTests.swift \
  ClipFlowTests/Support/InMemoryRepository.swift \
  ClipFlowTests/Support/TestRepositoryFactory.swift \
  ClipFlow.xcodeproj/project.pbxproj
git commit -m "feat: add reliable clipboard repository"
~~~

### Task 5: Add privacy decisions and idempotent pasteboard capture

**Files:**
- Create: ClipFlow/Privacy/PrivacyGuard.swift
- Create: ClipFlow/Privacy/SensitiveContentDetector.swift
- Create: ClipFlow/Services/PasteboardClient.swift
- Create: ClipFlow/Services/ClipboardCaptureService.swift
- Create: ClipFlow/Services/CapturePipeline.swift
- Create: ClipFlow/Services/TextClassifier.swift
- Create: ClipFlow/Diagnostics/AppErrorCode.swift
- Create: ClipFlowTests/Privacy/PrivacyGuardTests.swift
- Create: ClipFlowTests/Services/ClipboardCaptureServiceTests.swift
- Create: ClipFlowTests/Services/CapturePipelineTests.swift
- Create: ClipFlowTests/Services/TextClassifierTests.swift
- Create: ClipFlowTests/Support/FakePasteboardClient.swift
- Create: ClipFlowTests/Support/SpyTextClassifier.swift

**Interfaces:**
- Consumes: CapturedText and the repository capture path.
- Produces:

~~~swift
enum AppErrorCode: String, Codable, Equatable, Sendable {
    case databaseOpen = "database.open"
    case databaseWrite = "database.write"
    case databaseCopyMetadata = "database.copyMetadata"
    case databaseReadOnly = "database.readOnly"
    case migrationFailed = "migration.failed"
    case migrationBackupDelete = "migration.backupDelete"
    case clipboardRead = "clipboard.read"
    case clipboardWrite = "clipboard.write"
    case hotkeyRegistration = "hotkey.registration"
    case privacyExcluded = "privacy.excluded"
    case privacySize = "privacy.size"
    case privacySensitive = "privacy.sensitive"
    case aiEndpoint = "ai.endpoint"
    case aiConsent = "ai.consent"
    case aiRequest = "ai.request"
    case releaseConfiguration = "release.configuration"
}

struct PrivacyConfiguration: Equatable, Sendable {
    var excludedBundleIDs: Set<String>
    var maxUTF8Bytes: Int
    var detectsSensitiveContent: Bool

    static let standard = PrivacyConfiguration(
        excludedBundleIDs: [],
        maxUTF8Bytes: 1_048_576,
        detectsSensitiveContent: true
    )
}

enum PrivacyDecision: Equatable, Sendable {
    case allow
    case skip(PrivacySkipReason)
}

enum PrivacySkipReason: Equatable, Sendable {
    case excludedApplication
    case exceedsSizeLimit(actualBytes: Int, limitBytes: Int)
    case sensitive(SensitiveContentKind)
}

enum SensitiveContentKind: Equatable, Sendable {
    case privateKey
    case apiToken
    case paymentCard
}

enum MonitoringPause: Equatable, Sendable {
    case active
    case until(Date)
    case indefinitely
}

struct SensitiveContentDetector: Sendable {
    func detect(in text: String) -> SensitiveContentKind?
}

struct PrivacyGuard: Sendable {
    let detector: SensitiveContentDetector
    func evaluate(
        _ capture: RawClipboardCapture,
        configuration: PrivacyConfiguration
    ) -> PrivacyDecision
}

protocol TextClassifying: Sendable {
    func classify(_ text: String) async -> ClipboardItem.Category
}

actor TextClassifier: TextClassifying {
    func classify(_ text: String) -> ClipboardItem.Category
}

enum CapturePipelineEvent: Equatable, Sendable {
    case persisted(ClipboardItem)
    case skipped(PrivacySkipReason)
    case failed(code: AppErrorCode)
}

actor CapturePipeline {
    init(
        privacyGuard: PrivacyGuard,
        classifier: any TextClassifying,
        repository: any ClipboardRepositoryProtocol,
        configuration: PrivacyConfiguration
    )
    func updateConfiguration(_ configuration: PrivacyConfiguration)
    func process(_ raw: RawClipboardCapture) async -> CapturePipelineEvent
}

@MainActor
protocol ClipboardCaptureServiceProtocol: AnyObject {
    var pauseState: MonitoringPause { get }
    func start(handler: @escaping @MainActor (RawClipboardCapture) -> Void)
    func stop()
    func pause(_ state: MonitoringPause)
    func resume()
    @discardableResult func write(_ text: String) -> Bool
}
~~~

- [ ] **Step 1: Write sensitive-content and exclusion tests**

Create ClipFlowTests/Privacy/PrivacyGuardTests.swift:

~~~swift
import XCTest
@testable import ClipFlow

final class PrivacyGuardTests: XCTestCase {
    private let guardrail = PrivacyGuard(detector: SensitiveContentDetector())

    func testSkipsExcludedApplicationWithoutInspectingContent() {
        let capture = RawClipboardCapture(
            content: "ordinary",
            capturedAt: Date(),
            sourceBundleID: "com.password.manager"
        )
        let configuration = PrivacyConfiguration(
            excludedBundleIDs: ["com.password.manager"],
            maxUTF8Bytes: 1_048_576,
            detectsSensitiveContent: true
        )
        XCTAssertEqual(
            guardrail.evaluate(capture, configuration: configuration),
            .skip(.excludedApplication)
        )
    }

    func testSkipsPrivateKeyAndKnownTokenPrefixes() {
        let values: [(String, SensitiveContentKind)] = [
            ("-----BEGIN PRIVATE KEY-----\nabc", .privateKey),
            ("sk-abcdefghijklmnopqrstuvwxyz012345", .apiToken),
            ("ghp_abcdefghijklmnopqrstuvwxyz012345", .apiToken),
            ("AKIA1234567890ABCDEF", .apiToken)
        ]

        for (text, kind) in values {
            let capture = RawClipboardCapture.fixture(text)
            XCTAssertEqual(
                guardrail.evaluate(capture, configuration: .standard),
                .skip(.sensitive(kind))
            )
        }
    }

    func testDoesNotTreatShortPrefixAsToken() {
        XCTAssertEqual(
            guardrail.evaluate(RawClipboardCapture.fixture("sk-short"), configuration: .standard),
            .allow
        )
    }

    func testUsesUTF8ByteLimit() {
        let capture = RawClipboardCapture.fixture(String(repeating: "你", count: 4))
        let configuration = PrivacyConfiguration(
            excludedBundleIDs: [],
            maxUTF8Bytes: 11,
            detectsSensitiveContent: false
        )
        XCTAssertEqual(
            guardrail.evaluate(capture, configuration: configuration),
            .skip(.exceedsSizeLimit(actualBytes: 12, limitBytes: 11))
        )
    }
}
~~~

Add table-driven positive tests for every approved prefix (`sk-`, `ghp_`, `github_pat_`, `xoxb-`, `xoxp-`, `xoxa-`, `xoxr-`, `xoxs-`, and `AKIA`), plus 19-character and illegal-character negatives. Use `4111 1111 1111 1111` as the Luhn-positive case and `4111 1111 1111 1112` as the same-length negative.

- [ ] **Step 2: Write idempotent monitoring and self-copy tests**

Create ClipFlowTests/Services/ClipboardCaptureServiceTests.swift:

~~~swift
@MainActor
final class ClipboardCaptureServiceTests: XCTestCase {
    func testStartIsIdempotent() {
        let pasteboard = FakePasteboardClient()
        let service = ClipboardCaptureService(
            pasteboard: pasteboard,
            sourceBundleID: { "com.example.source" }
        )

        service.start { _ in }
        service.start { _ in }

        XCTAssertEqual(service.activeTimerCountForTesting, 1)
    }

    func testWritingThroughServiceDoesNotRecaptureText() {
        let pasteboard = FakePasteboardClient()
        let service = ClipboardCaptureService(
            pasteboard: pasteboard,
            sourceBundleID: { nil }
        )
        var captures: [RawClipboardCapture] = []
        service.start { captures.append($0) }

        XCTAssertTrue(service.write("copied by ClipFlow"))
        service.checkNowForTesting()

        XCTAssertTrue(captures.isEmpty)
    }

    func testPauseUntilAutomaticallyResumes() {
        let now = Date(timeIntervalSince1970: 100)
        let service = ClipboardCaptureService(
            pasteboard: FakePasteboardClient(),
            sourceBundleID: { nil },
            now: { now }
        )
        service.pause(.until(Date(timeIntervalSince1970: 99)))
        service.checkNowForTesting()
        XCTAssertEqual(service.pauseState, .active)
    }
}
~~~

Add tests for pause 5-minute/1-hour/indefinite state, stop/restart idempotency, and source bundle capture at the exact change-detection poll (changing the closure afterward must not rewrite the emitted RawClipboardCapture).

Create CapturePipelineTests with a SpyTextClassifier and InMemoryRepository. The core rejection test is:

~~~swift
func testRejectedCaptureNeverReachesClassifierOrRepository() async throws {
    let repository = InMemoryRepository()
    let classifier = SpyTextClassifier(result: .english)
    let pipeline = CapturePipeline(
        privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
        classifier: classifier,
        repository: repository,
        configuration: .standard
    )

    let event = await pipeline.process(.fixture("-----BEGIN PRIVATE KEY-----\nsecret"))

    XCTAssertEqual(event, .skipped(.sensitive(.privateKey)))
    let classifierCallCount = await classifier.callCount
    let page = try await repository.fetchPage(
        .init(searchText: "", scope: .all, limit: 100, offset: 0)
    )
    XCTAssertEqual(classifierCallCount, 0)
    XCTAssertEqual(page.totalCount, 0)
}
~~~

Add equivalent excluded-app and oversize cases, plus an allowed case proving the order is guard → actor classifier → repository and that Store receives only CapturePipelineEvent, never RawClipboardCapture. TextClassifierTests include the existing Chinese/English/category cases and the `"API"` versus `"capital expenditure"` word-boundary regression.

- [ ] **Step 3: Run the tests and confirm missing types**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClipFlowTests/PrivacyGuardTests \
  -only-testing:ClipFlowTests/ClipboardCaptureServiceTests \
  -only-testing:ClipFlowTests/CapturePipelineTests \
  -only-testing:ClipFlowTests/TextClassifierTests \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: compilation fails because privacy and capture types are absent.

- [ ] **Step 4: Implement deterministic privacy rules**

SensitiveContentDetector must implement:

- PEM marker detection for BEGIN PRIVATE KEY variants.
- Token prefix plus at least 20 characters from [A-Za-z0-9_-].
- AWS AKIA followed by exactly 16 uppercase alphanumeric characters.
- Card candidates containing 13...19 digits after removing spaces/hyphens, accepted only after Luhn validation.

Return only SensitiveContentKind; never return or log the matching substring.

PrivacyGuard.evaluate follows this exact order: excluded app, byte limit, sensitive detector, allow. This prevents unnecessary inspection of excluded-app text.

- [ ] **Step 5: Implement the pasteboard boundary and service**

Use an AppKit boundary:

~~~swift
@MainActor
protocol PasteboardClient: AnyObject {
    var changeCount: Int { get }
    func string() -> String?
    @discardableResult func write(_ text: String) -> Bool
}

@MainActor
final class SystemPasteboardClient: PasteboardClient {
    private let pasteboard = NSPasteboard.general
    var changeCount: Int { pasteboard.changeCount }
    func string() -> String? { pasteboard.string(forType: .string) }
    func write(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
~~~

ClipboardCaptureService is MainActor isolated, owns exactly one 0.5-second Timer, supports active/until/indefinitely, and exposes start, stop, pause, resume, and write. It captures the frontmost bundle ID at change detection and calls its handler with a RawClipboardCapture value. It never classifies, logs, persists, or sends the body to Store. AppKit pasteboard access stays on MainActor.

Its initializer is:

~~~swift
init(
    pasteboard: any PasteboardClient,
    sourceBundleID: @escaping () -> String?,
    now: @escaping () -> Date = Date.init
)
~~~

FakePasteboardClient stores text and changeCount in memory; write increments changeCount exactly once. ClipboardCaptureService conforms to ClipboardCaptureServiceProtocol so ClipboardStore never depends on the concrete AppKit implementation.

CapturePipeline is the only ingestion path. It evaluates PrivacyGuard before calling its actor-isolated classifier, then awaits Repository. It emits `.persisted(item)` only after commit and content-free `.skipped`/`.failed` events otherwise. AppEnvironment wires CaptureService directly to this pipeline; ClipboardStore applies only those result events on MainActor. A normal `Task` on MainActor must not be used as the classification implementation.

- [ ] **Step 6: Run privacy/capture tests and full tests**

Run the Task 5 command, then the full unit suite.

Expected: all tests pass, start is idempotent, and self-copy is not captured.

- [ ] **Step 7: Commit**

~~~bash
git add ClipFlow/Privacy/PrivacyGuard.swift ClipFlow/Privacy/SensitiveContentDetector.swift \
  ClipFlow/Services/PasteboardClient.swift ClipFlow/Services/ClipboardCaptureService.swift \
  ClipFlow/Services/CapturePipeline.swift ClipFlow/Services/TextClassifier.swift \
  ClipFlow/Diagnostics/AppErrorCode.swift \
  ClipFlowTests/Privacy/PrivacyGuardTests.swift \
  ClipFlowTests/Services/ClipboardCaptureServiceTests.swift \
  ClipFlowTests/Services/CapturePipelineTests.swift \
  ClipFlowTests/Services/TextClassifierTests.swift \
  ClipFlowTests/Support/FakePasteboardClient.swift \
  ClipFlowTests/Support/SpyTextClassifier.swift ClipFlow.xcodeproj/project.pbxproj
git commit -m "feat: add privacy-aware clipboard capture"
~~~

### Task 6: Create settings and the single-source ClipboardStore

**Files:**
- Modify: ClipFlow/Models/AIModels.swift
- Create: ClipFlow/Stores/AppSettingsStore.swift
- Create: ClipFlow/Stores/ClipboardStore.swift
- Create: ClipFlow/Models/AppErrorPresentation.swift
- Create: ClipFlow/Diagnostics/AppLogger.swift
- Create: ClipFlow/Services/SleepProvider.swift
- Create: ClipFlowTests/Stores/AppSettingsStoreTests.swift
- Create: ClipFlowTests/Stores/ClipboardStoreTests.swift
- Create: ClipFlowTests/Diagnostics/AppLoggerTests.swift
- Create: ClipFlowTests/Support/FakePasteboardWriter.swift
- Create: ClipFlowTests/Support/ManualSleeper.swift
- Create: ClipFlowTests/Support/InMemoryAppLogger.swift
- Create: ClipFlowTests/Support/InMemoryMigrationBackupManager.swift
- Create: ClipFlowTests/Support/StoreFixture.swift

**Interfaces:**
- Consumes: ClipboardRepositoryProtocol, PrivacyConfiguration, ClipboardCaptureService.
- Produces a MainActor store used by all SwiftUI surfaces:

~~~swift
@MainActor
final class AppSettingsStore: ObservableObject {
    @Published private(set) var retentionPolicy: RetentionPolicy
    @Published private(set) var maxCaptureBytes: Int
    @Published private(set) var excludedBundleIDs: Set<String>
    @Published private(set) var sensitiveContentProtectionEnabled: Bool
    @Published private(set) var shortcut: ShortcutMapping
    @Published private(set) var aiProviderKind: AIProviderKind
    @Published private(set) var aiEndpoint: URL?
    @Published private(set) var aiModel: String
    @Published private(set) var aiConsentOrigin: AIConsentOrigin?

    var privacyConfiguration: PrivacyConfiguration { get }
    init(userDefaults: UserDefaults)
    func setRetentionDays(_ days: Int) throws
    func setRetentionPolicy(_ policy: RetentionPolicy)
    func setMaxCaptureBytes(_ bytes: Int) throws
    func setExcludedBundleIDs(_ ids: Set<String>)
    func setSensitiveContentProtectionEnabled(_ enabled: Bool)
    func commitShortcut(_ shortcut: ShortcutMapping)
    func setAIProvider(_ provider: AIProviderKind)
    func setAIEndpoint(_ url: URL?)
    func setAIModel(_ model: String)
    func requestRemoteConsent() throws -> AIConsentOrigin
    func grantConsent(for origin: AIConsentOrigin) throws
    func revokeConsent()
    func consumeLegacySettingsAfterSuccessfulMigration(_ snapshot: LegacySettingsSnapshot)
}
~~~

~~~swift
enum ClipSurface: Hashable, Sendable {
    case quickPanel
    case library
}

struct ClipQuerySession: Equatable, Sendable {
    var query: ClipQuery
    var items: [ClipboardItem]
    var selectedItemID: UUID?
    var totalCount: Int
    var nextOffset: Int?
    var isLoading: Bool
}

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var sessions: [ClipSurface: ClipQuerySession]
    @Published private(set) var itemCache: [UUID: ClipboardItem] = [:]
    @Published private(set) var repositoryStartup: RepositoryStartup
    @Published private(set) var monitoringPause: MonitoringPause = .active
    @Published private(set) var banner: AppErrorPresentation?
    @Published private(set) var pendingDeletes: [UUID: PendingDelete] = [:]

    var isReadOnlyRecovery: Bool { repositoryStartup.isReadOnly }

    init(
        repository: any ClipboardRepositoryProtocol,
        captureService: any ClipboardCaptureServiceProtocol,
        capturePipeline: CapturePipeline,
        backupManager: any MigrationBackupManaging,
        settings: AppSettingsStore,
        startup: RepositoryStartup,
        logger: any AppLogging,
        now: @escaping () -> Date = Date.init,
        sleeper: any SleepProviding = ContinuousSleeper()
    )
}
~~~

AppErrorPresentation and PendingDelete are value-only UI state:

~~~swift
enum AppBannerSeverity: Equatable, Sendable {
    case information
    case warning
    case error
}

enum RecoveryAction: Equatable, Sendable {
    case retry(surface: ClipSurface)
    case openSettings
    case revealBackup(URL)
    case deleteMigrationBackups
}

struct AppErrorPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let code: AppErrorCode
    let message: String
    let severity: AppBannerSeverity
    let recoveryTitle: String?
    let recoveryAction: RecoveryAction?
}

struct PendingDelete: Equatable, Sendable {
    let itemID: UUID
    let deletedAt: Date
    let expiresAt: Date
}

enum AIResultApplication: Equatable, Sendable {
    case applied(ClipboardItem)
    case staleGeneration
    case targetMissing
    case failed(AppErrorCode)
}

enum ClearClipboardDataOutcome: Equatable, Sendable {
    case complete(removedClipCount: Int)
    case partial(removedClipCount: Int, code: AppErrorCode)
    case failed(AppErrorCode)
}

enum CopyOutcome: Equatable, Sendable {
    case copied
    case copiedWithMetadataWarning
    case clipboardWriteFailed
}

struct DiagnosticEvent: Equatable, Sendable {
    let code: AppErrorCode
    let timestamp: Date
}

protocol AppLogging: Sendable {
    func record(_ event: DiagnosticEvent) async
    func recentEvents(limit: Int) async -> [DiagnosticEvent]
}

protocol SleepProviding: Sendable {
    func sleep(for duration: Duration) async throws
}
~~~

Required methods:

~~~swift
func start() async
func stop()
func session(for surface: ClipSurface) -> ClipQuerySession
func selectedItem(for surface: ClipSurface) -> ClipboardItem?
func setSelection(_ id: UUID?, for surface: ClipSurface)
func updateQuery(_ query: ClipQuery, for surface: ClipSurface) async
func reload(_ surface: ClipSurface, resetOffset: Bool = true) async
func loadNextPage(_ surface: ClipSurface) async
func loadItem(id: UUID) async
func applyCaptureEvent(_ event: CapturePipelineEvent) async
func updatePrivacyConfiguration(_ configuration: PrivacyConfiguration) async
func pauseMonitoring(_ state: MonitoringPause)
func resumeMonitoring()
func copy(id: UUID) async -> CopyOutcome
func toggleFavorite(id: UUID) async
func delete(id: UUID) async
func undoDelete(id: UUID) async
func finalizePendingDelete(id: UUID) async
func countForRetention(_ policy: RetentionPolicy, now: Date) async -> Int?
func updateRetention(_ policy: RetentionPolicy, now: Date) async
func activateAIJob(_ key: AIJobKey, generation: UUID) async
func cancelAIJob(_ key: AIJobKey, generation: UUID) async
func applyAISummary(
    itemID: UUID,
    summary: String?,
    key: AIJobKey,
    generation: UUID
) async -> AIResultApplication
func applyAICategory(
    itemID: UUID,
    categoryID: UUID?,
    key: AIJobKey,
    generation: UUID
) async -> AIResultApplication
func addAIUsage(_ record: AIUsageRecord) async
func saveCategory(_ category: PersistedCustomCategory) async
func reorderCategories(ids: [UUID]) async
func deleteCategory(id: UUID, migrateTo replacementID: UUID?) async
func countAllClips() async -> Int?
func deleteAllClipboardDataConfirmed() async -> ClearClipboardDataOutcome
func deleteMigrationBackups() async -> Bool
func clearAIUsage() async
~~~

- [ ] **Step 1: Write store consistency and failure tests**

Create ClipFlowTests/Stores/ClipboardStoreTests.swift:

~~~swift
@MainActor
final class ClipboardStoreTests: XCTestCase {
    func testSelectedItemIsDerivedFromItems() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "selected"))
        let store = makeStore(repository: repository)

        await store.start()
        store.setSelection(item.id, for: .library)
        await store.toggleFavorite(id: item.id)

        XCTAssertTrue(store.selectedItem(for: .library)?.isFavorite == true)
    }

    func testFailedFavoriteWriteDoesNotMutateUI() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "stable"))
        let store = makeStore(repository: repository)
        await store.start()
        await repository.setFailNextMutation(true)

        await store.toggleFavorite(id: item.id)

        XCTAssertFalse(store.session(for: .library).items.first?.isFavorite == true)
        XCTAssertEqual(store.banner?.code, .databaseWrite)
    }

    func testCleanupRefreshesItemsAndSelectionAtomically() async {
        let repository = InMemoryRepository()
        let old = await repository.seed(.fixture(content: "old", at: 0))
        let store = makeStore(repository: repository)
        await store.start()
        store.setSelection(old.id, for: .library)

        await store.updateRetention(.days(15), now: Date(timeIntervalSince1970: 20 * 86_400))

        XCTAssertTrue(store.session(for: .library).items.isEmpty)
        XCTAssertNil(store.session(for: .library).selectedItemID)
    }

    func testMetadataFailureDoesNotUndoSuccessfulPasteboardCopy() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "copy"))
        let pasteboard = FakePasteboardWriter(result: true)
        let store = makeStore(repository: repository, pasteboard: pasteboard)
        await store.start()
        await repository.setFailNextMutation(true)

        let outcome = await store.copy(id: item.id)
        XCTAssertEqual(outcome, .copiedWithMetadataWarning)
        XCTAssertEqual(pasteboard.writtenText, "copy")
        XCTAssertEqual(store.banner?.code, .databaseCopyMetadata)
    }
}
~~~

Also test soft delete, multiple concurrent 8-second undo entries, restart purging expired tombstones, pagination without duplicates, content-free capture skip errors, read-only view/copy/write rejection, production mutation failure without UI drift, independent quick/library queries and selections, delete-all failure atomicity, category CRUD/reorder/migrate, AI usage clearing, lifecycle start/start/stop/restart, the 24-hour cleanup tick, cleanup-success/reload-failure recovery, atomic privacy-setting barriers, and shared pause/resume countdown state.

Create the shared internal (not private) helper in `ClipFlowTests/Support/StoreFixture.swift` so later AI/view tests use the same production Store wiring:

~~~swift
@MainActor
func makeStore(
    repository: InMemoryRepository,
    pasteboard: FakePasteboardWriter = FakePasteboardWriter(result: true)
) -> ClipboardStore {
    ClipboardStore(
        repository: repository,
        captureService: pasteboard,
        capturePipeline: CapturePipeline(
            privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
            classifier: TextClassifier(),
            repository: repository,
            configuration: .standard
        ),
        backupManager: InMemoryMigrationBackupManager(),
        settings: AppSettingsStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!),
        startup: .readWrite(DatabasePreparation(
            schemaVersion: 2,
            searchMode: .parameterizedContains,
            recoveredCategories: [],
            backupURL: nil
        )),
        logger: InMemoryAppLogger(),
        now: { Date(timeIntervalSince1970: 100) }
    )
}
~~~

FakePasteboardWriter conforms to ClipboardCaptureServiceProtocol. Its monitoring methods are no-ops, its pauseState is .active, and write stores writtenText before returning the configured result.

- [ ] **Step 2: Write settings defaults and validation tests**

Use an isolated UserDefaults suite and assert:

~~~swift
func testDefaultsMatchSpecification() {
    XCTAssertEqual(store.retentionPolicy, .days(15))
    XCTAssertEqual(store.maxCaptureBytes, 1_048_576)
    XCTAssertEqual(store.aiProviderKind, .disabled)
    XCTAssertTrue(store.sensitiveContentProtectionEnabled)
}

func testRetentionRejectsOutOfRangeDays() {
    XCTAssertThrowsError(try store.setRetentionDays(0))
    XCTAssertThrowsError(try store.setRetentionDays(366))
}
~~~

- [ ] **Step 3: Run the store tests and verify missing APIs**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClipFlowTests/ClipboardStoreTests \
  -only-testing:ClipFlowTests/AppSettingsStoreTests \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: compilation fails on ClipboardStore and AppSettingsStore.

- [ ] **Step 4: Implement AppSettingsStore**

AppSettingsStore is MainActor isolated and owns all UserDefaults keys. It publishes retentionPolicy, maxCaptureBytes, excludedBundleIDs, sensitiveContentProtectionEnabled, shortcut, AI provider kind, endpoint, model, and consent origin. Add AIConsentOrigin to AIModels.swift.

Do not use @AppStorage in child views. Views bind to this one injected store.

Consent origin is normalized as:

~~~swift
struct AIConsentOrigin: Codable, Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}
~~~

Changing endpoint clears stored consent unless the normalized origin remains identical.

`requestRemoteConsent()` validates that the selected provider is remote and returns the current normalized origin without granting it. The first actual send calls this method and presents confirmation. Only `grantConsent(for:)` persists consent, and it succeeds only when the supplied origin still equals the current endpoint. Reject/cancel performs no request. Provider, scheme, host, or port change revokes the old grant. Tests cover reject → zero HTTP requests, grant → one request, and endpoint-origin change → consent required again.

Decode legacy defaults through `LegacyCustomCategoryV1`, assign deterministic sort order and timestamps, and import them only during successful repository startup. After the database commit, delete the legacy `custom_categories` and `api_usage_records` keys. Old `ai_integration_enabled` and `ollama_base_url` are never trusted: 2.0 always starts `.disabled` with nil consent, then removes those legacy keys.

- [ ] **Step 5: Implement ClipboardStore mutation ordering**

For each persistent mutation:

1. Read the current value.
2. Await repository mutation.
3. Put the returned item in itemCache, then reconcile both active query sessions.
4. On repository error, leave cache/sessions unchanged and publish a typed banner.

`reconcileAfterMutation` re-fetches the loaded extent of each surface using that surface's unchanged query, preserves its own selection only if the ID remains visible, and atomically replaces items/totalCount/nextOffset. This guarantees Favorites removal, custom-category movement, and lastCopiedAt/duplicate recency ordering in both windows. If repository mutation committed but a session refresh fails, clear that affected session and show Retry instead of displaying known-stale membership. Tests cover favorite removal from Quick Favorites, category movement between Library scopes, copy/duplicate moving to Recent top, and simultaneous Quick/Library reconciliation.

CaptureService is wired directly to CapturePipeline; Store never receives RawClipboardCapture. `applyCaptureEvent` reconciles the repository-returned item into both sessions, or shows a content-free skip/error. QuickPanel and Settings call Store for privacy/monitoring changes. `updatePrivacyConfiguration` first awaits the actor pipeline update (a barrier after any already-started capture), then commits AppSettingsStore's visible/persisted values; the next capture cannot see the old configuration. pause/resume update CaptureService and the single published monitoringPause/remaining-time source read by both surfaces. Child views never mutate AppSettingsStore directly.

The only exception is copy: write the pasteboard first, then refresh repository metadata. Return `.copied`, `.copiedWithMetadataWarning`, or `.clipboardWriteFailed`; metadata failure never reverses a successful pasteboard write, and no feedback contains clip text.

Delete writes deleted_at, removes the item from both sessions/cache, and starts an independent 8-second task keyed by ID. Undo cancels only that ID, restores the repository row, and reloads affected sessions. Finalization calls repository.purgeDeleted(id:) for only that ID. On start, first purge tombstones with `deleted_at <= now - 8 seconds`, then fetch newer tombstones and recreate PendingDelete plus a timer for each exact remaining duration `deletedAt + 8s - now`; this preserves Undo and eventual purge across a quick restart. ManualSleeper makes the boundary deterministic. Tests cover delete at t=0, stop/restart at t=2, visible Undo through t<8, and automatic purge at t=8.

In read-write mode, start loads quick-panel and library sessions independently, wires ClipboardCaptureService to CapturePipeline, performs the initial retention cleanup, purges migration backups at/over 24 hours, and owns exactly one 24-hour cleanup Task for both retention and backup expiry. Calling start twice must not create a second capture timer or cleanup Task. stop cancels capture, all undo tasks, and cleanup; restart creates exactly one of each service loop. In `.readOnlyRecovery`, start skips database mutations and automatic backup expiry so it preserves the recovery artifact, while still allowing explicit reveal/delete-backup actions. All other repository mutations are disabled, while reads and pasteboard copy remain available; metadata refresh failure after copy is a warning. The persistent recovery banner exposes the backup URL through `.revealBackup` and cannot be dismissed.

updateRetention first commits cleanup, then persists the new retention setting and reloads both sessions; managed migration backups can retain older text for at most 24 hours, and the confirmation discloses that recovery window plus a Delete Backups Now action. If cleanup succeeds but reload fails, clear affected cached items conservatively, clear invalid selection, keep the committed setting, and show a persistent retry banner; never continue showing rows known to have been deleted.

deleteAllClipboardDataConfirmed deletes every clip including favorites plus AI usage metadata, then deletes every app-managed migration backup, cancels pending undo, and clears both sessions/cache/selection after the database transaction succeeds. It preserves categories, preferences, remote consent, and Keychain credentials. If database deletion fails, return `.failed` and leave UI unchanged. If database succeeds but backup deletion fails, current rows are cleared but return `.partial`, keep a persistent warning with retry Delete Backups, and never show a complete-success toast. Sentinel tests verify both the main database and every managed backup no longer contain the clip after `.complete`.

AppLogger stores only DiagnosticEvent(code,timestamp) in a bounded in-memory ring and forwards the same code/time to `Logger` with privacy-safe static messages. Its API has no String payload, making clip text, prompts, endpoints, tokens, and model output unrepresentable. Test with sentinel clipboard/token values at the calling boundary and assert only code/time reaches the spy.

- [ ] **Step 6: Run store tests and full tests**

Run the Task 6 command, then the full suite.

Expected: store, settings, and all prior tests pass.

- [ ] **Step 7: Commit**

~~~bash
git add ClipFlow/Stores/AppSettingsStore.swift ClipFlow/Stores/ClipboardStore.swift \
  ClipFlow/Models/AIModels.swift ClipFlow/Models/AppErrorPresentation.swift \
  ClipFlow/Diagnostics/AppLogger.swift ClipFlow/Services/SleepProvider.swift \
  ClipFlowTests/Stores/AppSettingsStoreTests.swift \
  ClipFlowTests/Stores/ClipboardStoreTests.swift ClipFlowTests/Diagnostics/AppLoggerTests.swift \
  ClipFlowTests/Support/FakePasteboardWriter.swift ClipFlowTests/Support/ManualSleeper.swift \
  ClipFlowTests/Support/InMemoryAppLogger.swift \
  ClipFlowTests/Support/InMemoryMigrationBackupManager.swift \
  ClipFlowTests/Support/StoreFixture.swift \
  ClipFlow.xcodeproj/project.pbxproj
git commit -m "feat: add single-source clipboard store"
~~~

### Task 7: Replace OllamaService with bounded, item-bound AI jobs

**Files:**
- Modify: ClipFlow/Models/AIModels.swift
- Modify: ClipFlow/Stores/AppSettingsStore.swift
- Create: ClipFlow/Services/HTTPClient.swift
- Create: ClipFlow/Services/AIEndpointValidator.swift
- Create: ClipFlow/Services/AIService.swift
- Create: ClipFlow/Services/KeychainCredentialStore.swift
- Create: ClipFlow/Services/SecurityItemClient.swift
- Create: ClipFlow/Services/LocalRulesService.swift
- Create: ClipFlow/Stores/AIJobCoordinator.swift
- Create: ClipFlowTests/Services/AIEndpointValidatorTests.swift
- Create: ClipFlowTests/Services/AIServiceTests.swift
- Create: ClipFlowTests/Services/URLSessionHTTPClientTests.swift
- Create: ClipFlowTests/Stores/AIJobCoordinatorTests.swift
- Create: ClipFlowTests/Support/MockHTTPClient.swift
- Create: ClipFlowTests/Support/ControllableAIService.swift
- Create: ClipFlowTests/Support/InMemoryKeychainCredentialStore.swift
- Create: ClipFlowTests/Support/FakeSecurityItemClient.swift
- Create: ClipFlowTests/Support/StreamingURLProtocol.swift

**Interfaces:**
- Consumes: AIRequest, ClipboardRepositoryProtocol, AppSettingsStore consent.
- Produces:

~~~swift
enum AIProviderConfiguration: Equatable, Sendable {
    case disabled
    case localOllama(baseURL: URL, model: String)
    case remoteHTTPS(baseURL: URL, model: String, consent: AIConsentOrigin)
}

extension AppSettingsStore {
    func validatedAIProviderConfiguration() throws -> AIProviderConfiguration
}

protocol AIServiceProtocol: Sendable {
    func perform(
        _ request: AIRequest,
        provider: AIProviderConfiguration
    ) async throws -> AIResult
    func checkAvailability(
        provider: AIProviderConfiguration
    ) async -> AIAvailability
}

protocol HTTPClient: Sendable {
    func data(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse)
}

actor URLSessionHTTPClient: HTTPClient {
    init(configuration: URLSessionConfiguration = .ephemeral)
}

enum AIAvailability: Equatable, Sendable {
    case disabled
    case available
    case unavailable(code: AppErrorCode)
}

enum AIEndpointValidator {
    static func validateLocal(_ url: URL) throws -> URL
    static func validateRemote(
        _ url: URL,
        consent: AIConsentOrigin?
    ) throws -> AIConsentOrigin
}

protocol KeychainCredentialStoring: Sendable {
    func credential(for origin: AIConsentOrigin) async throws -> String?
    func setCredential(_ credential: String, for origin: AIConsentOrigin) async throws
    func deleteCredential(for origin: AIConsentOrigin) async throws
}

enum SecurityItemOperation: Equatable, Sendable {
    case read
    case add(Data)
    case update(Data)
    case delete
}

struct SecurityItemRequest: Equatable, Sendable {
    let service: String
    let account: String
    let accessibleWhenUnlocked: Bool
    let synchronizable: Bool
    let operation: SecurityItemOperation
}

protocol SecurityItemClient: Sendable {
    func execute(_ request: SecurityItemRequest) async -> (OSStatus, Data?)
}

enum CredentialError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidEncoding
}

enum AIError: Error, Equatable, Sendable {
    case disabled
    case invalidEndpoint
    case missingConsent
    case httpStatus(Int)
    case responseTooLarge
    case invalidResponse
    case emptyResponse
    case invalidCategory
    case redirectRejected
    case timedOut
    case cancelled
}

actor AIService: AIServiceProtocol {
    init(
        http: any HTTPClient,
        keychain: any KeychainCredentialStoring,
        localRules: LocalRulesService
    )
}

enum AIJobState: Equatable, Sendable {
    case running
    case success(AIResult)
    case failure(code: String, message: String)
}

@MainActor
final class AIJobCoordinator: ObservableObject {
    @Published var visibleItemID: UUID?
    @Published private(set) var states: [AIJobKey: AIJobState]

    init(
        ai: any AIServiceProtocol,
        store: ClipboardStore,
        now: @escaping () -> Date = Date.init
    )

    func start(
        _ request: AIRequest,
        provider: AIProviderConfiguration
    ) async
    func cancel(itemID: UUID, operation: AIOperation) async
    func cancelAll(itemID: UUID) async
    func cancelAll() async
    func clearTransientResults(itemID: UUID)
    func clearAllTransientResults()
    func waitForIdle() async
}
~~~

- [ ] **Step 1: Write endpoint and disabled-provider tests**

Create assertions for:

~~~swift
func testLocalProviderRejectsNonLoopbackHost() {
    XCTAssertThrowsError(
        try AIEndpointValidator.validateLocal(URL(string: "http://192.168.1.5:11434")!)
    )
}

func testLocalProviderAcceptsEveryLoopbackForm() {
    let values = [
        URL(string: "http://localhost:11434")!,
        URL(string: "http://127.0.0.1:11434")!,
        URL(string: "http://[::1]:11434")!
    ]
    for value in values {
        XCTAssertNoThrow(try AIEndpointValidator.validateLocal(value))
    }
}

func testRemoteProviderRequiresHTTPSAndMatchingConsent() {
    let url = URL(string: "https://ai.example.com:8443")!
    XCTAssertThrowsError(
        try AIEndpointValidator.validateRemote(url, consent: nil)
    )
    XCTAssertNoThrow(
        try AIEndpointValidator.validateRemote(
            url,
            consent: AIConsentOrigin(url: url)
        )
    )
}

func testDisabledProviderMakesNoHTTPCall() async {
    let http = MockHTTPClient()
    let keychain = InMemoryKeychainCredentialStore()
    let service = AIService(http: http, keychain: keychain, localRules: LocalRulesService())
    do {
        _ = try await service.perform(.fixture(), provider: .disabled)
        XCTFail("disabled provider must reject work")
    } catch {
        XCTAssertEqual(error as? AIError, .disabled)
    }
    let requestCount = await http.requestCount
    let keychainReadCount = await keychain.readCount
    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(keychainReadCount, 0)
}
~~~

Add the same zero-request/zero-Keychain assertion for `checkAvailability(provider: .disabled)`. No new AI source file may import or instantiate Process; Task 12 enforces this with a source scan.

Endpoint tests also reject `file://localhost`, `localhost.evil`, username/password, non-root path, query, and fragment; verify default-port normalization and IPv6 origin equality. Local accepts only HTTP or HTTPS plus the exact three loopback host forms. Remote accepts HTTPS only. Validator returns an origin-only URL and provider code appends fixed paths itself.

- [ ] **Step 2: Write response-boundary and item-target tests**

Required cases:

- non-2xx response returns AIError.httpStatus.
- response larger than 1 MiB returns AIError.responseTooLarge.
- a categorize response not in allowedCategories returns AIError.invalidCategory.
- timeout and Task cancellation are surfaced separately.
- a 307/308 redirect is rejected before replaying body or Authorization, including HTTPS→HTTP and scheme/host/port changes.
- a chunked response is cancelled as soon as byte 1,048,577 arrives, before buffering the remainder.
- Authorization is absent for disabled/local, and remote reads it inside AIService from Keychain only after endpoint+consent validation.
- Keychain read/write/delete is scoped to the normalized origin and never uses UserDefaults.

The item-target regression test:

~~~swift
@MainActor
func testResultWritesBackToRequestItemAfterSelectionChanges() async throws {
    let repository = InMemoryRepository()
    let first = await repository.seed(.fixture(content: "first"))
    let second = await repository.seed(.fixture(content: "second"))
    let store = makeStore(repository: repository)
    await store.start()
    let ai = ControllableAIService()
    let coordinator = AIJobCoordinator(ai: ai, store: store)

    await coordinator.start(
        AIRequest(itemID: first.id, operation: .summarize, text: first.content, allowedCategories: []),
        provider: .localOllama(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "fixture"
        )
    )
    coordinator.visibleItemID = second.id
    await ai.complete(with: AIResult(
        itemID: first.id,
        operation: .summarize,
        text: "first summary",
        providerLabel: "fixture"
    ))
    await coordinator.waitForIdle()

    let persistedFirst = try await repository.item(id: first.id)
    let persistedSecond = try await repository.item(id: second.id)
    XCTAssertEqual(persistedFirst?.aiSummary, "first summary")
    XCTAssertNil(persistedSecond?.aiSummary)
    XCTAssertEqual(store.itemCache[first.id]?.aiSummary, "first summary")
    XCTAssertNil(store.itemCache[second.id]?.aiSummary)
}
~~~

MockHTTPClient is an actor with requestCount, queued Result<(Data, HTTPURLResponse), Error> responses, and the last URLRequest. ControllableAIService is an actor conforming to AIServiceProtocol; perform suspends with a checked continuation and complete(with:) resumes it. InMemoryKeychainCredentialStore is an actor keyed by Hashable AIConsentOrigin and records async read/write/delete calls. These exact helpers live in the Support files listed above.

URLSessionHTTPClientTests exercise the production client, not MockHTTPClient. Inject an ephemeral URLSessionConfiguration whose `protocolClasses` contains StreamingURLProtocol. The protocol emits observable chunks and redirect responses: assert the client cancels after consuming exactly 1,048,577 bytes and no later chunk; assert 307/308 to HTTP, another host, or another port produces `.redirectRejected`, the redirect destination receives zero requests, and Authorization/body are never replayed. A same-origin redirect is also rejected because production policy rejects all redirects.

Add coordinator tests with a controllable service and a ManualPersistenceGate: cancelled result never reaches Store, two same-key generations permit only the newest token to apply, `cancelAll(itemID:)` models closing detail, deleted target records only code/time metadata, and repository failure leaves Store/cache unchanged. The A/B regression must assert both production Store state and repository state, not only the fake.

- [ ] **Step 3: Run AI tests and confirm failure**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClipFlowTests/AIEndpointValidatorTests \
  -only-testing:ClipFlowTests/AIServiceTests \
  -only-testing:ClipFlowTests/URLSessionHTTPClientTests \
  -only-testing:ClipFlowTests/AIJobCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: compilation fails because the new AI boundaries do not exist.

- [ ] **Step 4: Implement endpoint, HTTP, Keychain, and response rules**

URLSessionHTTPClient uses URLSessionConfiguration.ephemeral with request and resource timeout 30 seconds and no URL cache. It consumes `URLSession.bytes(for:)` incrementally, cancels at `maximumResponseBytes + 1`, and never accumulates more than the limit. Its URLSessionTaskDelegate rejects every HTTP redirect; provider requests never replay a body or Authorization to a redirect target. Availability probes call the same bounded client with a 3-second URLRequest timeout and `/api/tags`.

AIService:

- Returns disabled without touching HTTPClient.
- Uses fixed /api/generate and /api/tags paths.
- Passes the 1 MiB bound to HTTPClient; also rejects a declared Content-Length above the bound.
- Accepts only 2xx responses.
- Decodes a typed OllamaResponse.
- Trims output and rejects empty text.
- Validates category output against exact category names.
- Calls Task.checkCancellation before returning.
- Returns typed AIError values; the coordinator measures elapsed duration and maps the error case to a stable code for content-free AIUsageRecord metadata.

AIService owns `any KeychainCredentialStoring`; callers never pass credential strings. It reads Keychain only for a fully validated `.remoteHTTPS` origin whose consent matches. KeychainCredentialStore is an actor using generic-password items with service `com.clipflow.v12.ai`, normalized origin account, `kSecAttrAccessibleWhenUnlocked`, `kSecAttrSynchronizable = false`, and no authentication UI for background reads. Set is an idempotent add-or-update; delete treats item-not-found as success; other OSStatus values map to CredentialError. Inject SecurityItemClient so tests inspect SecItem query dictionaries and verify a canary secret never reaches UserDefaults, Repository, AppLogger, or diagnostics.

- [ ] **Step 5: Port and correct local rules**

Move the useful behavior from TinyLocalAIService into LocalRulesService. Replace substring token matching with:

- Unicode-aware word boundaries for Latin tokens.
- Direct substring matching only for CJK tokens of two or more characters.
- Stable tie-breaking by custom category sortOrder.

Keep rewrite and custom-category rules local. Do not claim a local summary capability.

- [ ] **Step 6: Implement AIJobCoordinator cancellation and write-back**

AIJobCoordinator is MainActor isolated and stores `(generation: UUID, task: Task)` by AIJobKey(itemID, operation). `start` first cancels the old Task, awaits `ClipboardStore.activateAIJob`, then launches the new request. `cancel`/`cancelAll` cancel Tasks and await `ClipboardStore.cancelAIJob` before publishing cancelled. After AI returns it still checks local generation/cancellation, then passes key+generation into Store; Store uses the repository's actor-atomic conditional mutation, so a cancellation/replacement linearized before the repository check cannot commit. AIJobCoordinator never holds ClipboardRepository directly. Rewrite success/failure lives only in transient state; `clearTransientResults(itemID:)` removes rewrite state while leaving persisted summary/category intact, and Library window close calls `clearAllTransientResults()` after awaiting cancellation. A missing/deleted target drops the result and records only a stable diagnostic/usage code. Selection changes alone do not retarget or cancel the item-bound job. Every terminal outcome attempts to append an AIUsageRecord containing only operation, provider, model, duration, success, and error code; usage-write failure is logged by stable code but never rolls back a successfully persisted summary/category or exposes content.

- [ ] **Step 7: Run AI tests, strict concurrency, and full tests**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete
~~~

Expected: all tests pass and the previous non-Sendable OllamaService warnings are absent from new AI files.

- [ ] **Step 8: Commit**

~~~bash
git add ClipFlow/Models/AIModels.swift ClipFlow/Stores/AppSettingsStore.swift \
  ClipFlow/Services/HTTPClient.swift \
  ClipFlow/Services/AIEndpointValidator.swift ClipFlow/Services/AIService.swift \
  ClipFlow/Services/KeychainCredentialStore.swift ClipFlow/Services/SecurityItemClient.swift \
  ClipFlow/Services/LocalRulesService.swift \
  ClipFlow/Stores/AIJobCoordinator.swift ClipFlowTests/Services \
  ClipFlowTests/Stores/AIJobCoordinatorTests.swift \
  ClipFlowTests/Services/URLSessionHTTPClientTests.swift \
  ClipFlowTests/Support/MockHTTPClient.swift \
  ClipFlowTests/Support/ControllableAIService.swift \
  ClipFlowTests/Support/InMemoryKeychainCredentialStore.swift \
  ClipFlowTests/Support/FakeSecurityItemClient.swift \
  ClipFlowTests/Support/StreamingURLProtocol.swift ClipFlow.xcodeproj/project.pbxproj
git commit -m "feat: add safe item-bound AI processing"
~~~

### Task 8: Make global hotkey updates transactional

**Files:**
- Modify: ClipFlow/Models/ShortcutMapping.swift
- Replace: ClipFlow/Services/HotkeyService.swift
- Create: ClipFlow/Services/CarbonHotKeyRegistrar.swift
- Create: ClipFlowTests/Services/HotkeyServiceTests.swift
- Create: ClipFlowTests/Support/FakeHotKeyRegistrar.swift

**Interfaces:**
- Consumes: ShortcutMapping and the AppSettingsStore shortcut value.
- Produces:

~~~swift
struct HotKeyToken: Hashable, Sendable {
    let rawID: UInt32
}

@MainActor
protocol HotKeyRegistrar: AnyObject {
    func register(
        _ shortcut: ShortcutMapping,
        id: UInt32,
        handler: @escaping @MainActor () -> Void
    ) throws -> HotKeyToken
    func unregister(_ token: HotKeyToken)
}

enum HotkeyError: Error, Equatable, Sendable {
    case invalidShortcut
    case registrationFailed(OSStatus)
}

@MainActor
final class HotkeyService: ObservableObject {
    @Published private(set) var currentShortcut: ShortcutMapping
    @Published private(set) var lastError: HotkeyError?

    init(
        registrar: any HotKeyRegistrar,
        settings: AppSettingsStore,
        onPressed: @escaping @MainActor () -> Void = {}
    )
    func updateShortcut(_ candidate: ShortcutMapping) -> Bool
    func resetToDefault() -> Bool
}
~~~

FakeHotKeyRegistrar exposes activeShortcuts and ordered Event values:

~~~swift
enum FakeHotKeyEvent: Equatable {
    case registered(ShortcutMapping)
    case unregistered(ShortcutMapping)
}
~~~

The test file defines makeService(registrar:) by creating an isolated AppSettingsStore with defaultShortcut and passing it to the initializer above.

- [ ] **Step 1: Write conflict and rollback tests**

~~~swift
@MainActor
final class HotkeyServiceTests: XCTestCase {
    func testFailedCandidateKeepsOldRegistrationAndPreference() {
        let registrar = FakeHotKeyRegistrar()
        let settings = makeSettings(shortcut: .defaultShortcut)
        let service = HotkeyService(registrar: registrar, settings: settings)
        registrar.failNextRegistration = true
        let candidate = ShortcutMapping(keyCode: 0, modifiers: UInt32(cmdKey | optionKey))

        XCTAssertFalse(service.updateShortcut(candidate))
        XCTAssertEqual(service.currentShortcut, .defaultShortcut)
        XCTAssertEqual(settings.shortcut, .defaultShortcut)
        XCTAssertEqual(registrar.activeShortcuts, [.defaultShortcut])
    }

    func testSuccessfulCandidateRegistersBeforeRemovingOldToken() {
        let registrar = FakeHotKeyRegistrar()
        let service = makeService(registrar: registrar)
        let candidate = ShortcutMapping(keyCode: 0, modifiers: UInt32(cmdKey | optionKey))

        XCTAssertTrue(service.updateShortcut(candidate))
        XCTAssertEqual(registrar.events, [.registered(.defaultShortcut), .registered(candidate), .unregistered(.defaultShortcut)])
    }
}
~~~

- [ ] **Step 2: Run tests and confirm the old service cannot satisfy them**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClipFlowTests/HotkeyServiceTests \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: compilation fails on HotKeyRegistrar and transactional APIs.

- [ ] **Step 3: Implement candidate-first registration**

HotkeyService allocates a monotonically increasing UInt32 ID and passes it to CarbonHotKeyRegistrar; the registrar returns the matching token and forwards only that token’s event. HotkeyService registers the candidate first. On success it calls `AppSettingsStore.commitShortcut`, swaps activeToken, then unregisters the old token. On failure it leaves the old token and preference unchanged and publishes HotkeyError.registrationFailed(status).

Validate that the shortcut includes at least one modifier and a known key code before invoking Carbon.

If candidate equals currentShortcut, return true without registering or unregistering anything.

Remove ShortcutAction and the unused clearHistory/toggleFavorite cases from ShortcutMapping. ClipFlow 2.0 has one configurable global shortcut: opening the quick panel.

- [ ] **Step 4: Run hotkey tests and the full suite**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClipFlowTests/HotkeyServiceTests \
  CODE_SIGNING_ALLOWED=NO
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: conflict, rollback, success ordering, reset, and event forwarding tests pass.

- [ ] **Step 5: Commit**

~~~bash
git add ClipFlow/Models/ShortcutMapping.swift ClipFlow/Services/HotkeyService.swift \
  ClipFlow/Services/CarbonHotKeyRegistrar.swift \
  ClipFlowTests/Services/HotkeyServiceTests.swift \
  ClipFlowTests/Support/FakeHotKeyRegistrar.swift ClipFlow.xcodeproj/project.pbxproj
git commit -m "fix: preserve hotkey on registration failure"
~~~

### Task 9: Bootstrap the live environment and build the quick panel

**Files:**
- Create: ClipFlow/App/AppEnvironment.swift
- Create: ClipFlow/App/AppCoordinator.swift
- Modify: ClipFlow/App/AppDelegate.swift
- Modify: ClipFlow/main.swift
- Create: ClipFlow/Views/QuickPanel/QuickPanelView.swift
- Create: ClipFlow/Views/QuickPanel/QuickClipRow.swift
- Create: ClipFlow/Views/QuickPanel/QuickPanelKeyboardBridge.swift
- Create: ClipFlow/Views/Shared/ErrorBanner.swift
- Create: ClipFlow/Views/Shared/MonitoringStatusView.swift
- Create: ClipFlow/App/RecoveryActionHandler.swift
- Create: ClipFlowTests/Views/QuickPanelCommandTests.swift
- Create: ClipFlowTests/App/RecoveryActionHandlerTests.swift
- Create: ClipFlowTests/App/AppCoordinatorAccessibilityTests.swift

**Interfaces:**
- Consumes: ClipboardStore, AppSettingsStore, ClipboardCaptureService, HotkeyService, AIJobCoordinator.
- Produces:
  - AppEnvironment.live() async throws.
  - AppCoordinator.start(), toggleQuickPanel(), openLibrary(selectedID:), openSettings().
  - QuickPanelCommand routing independent of the SwiftUI view.

~~~swift
enum QuickPanelCommand: Equatable {
    case moveUp
    case moveDown
    case copySelection
    case openSelectionInLibrary
    case toggleFavorite
    case deleteSelection
    case focusSearch
    case escape
}

@MainActor
protocol QuickPanelCoordinating: AnyObject {
    func closeQuickPanel()
    func openLibrary(selectedID: UUID?)
    func openSettings()
    func showCopyFeedback(_ outcome: CopyOutcome)
}

@MainActor
protocol FileRevealing: AnyObject {
    func reveal(_ url: URL)
}

@MainActor
final class RecoveryActionHandler {
    init(
        store: ClipboardStore,
        coordinator: any QuickPanelCoordinating,
        fileRevealer: any FileRevealing
    )
    func handle(_ action: RecoveryAction) async
}

@MainActor
final class QuickPanelCommandHandler {
    let store: ClipboardStore
    let coordinator: any QuickPanelCoordinating
    var focusSearch: () -> Void
    var focusList: () -> Void

    func handle(_ command: QuickPanelCommand) async
}

extension AppCoordinator {
    static func performanceFixture() async throws -> AppCoordinator
    /// Test instrumentation: resumes only after production QuickPanelReadyProbe.
    func presentQuickPanelAndWaitUntilReadyForTesting() async
    func closeQuickPanelForTesting()
}
~~~

- [ ] **Step 1: Write command-routing tests**

Create ClipFlowTests/Views/QuickPanelCommandTests.swift:

~~~swift
@MainActor
final class QuickPanelCommandTests: XCTestCase {
    func testReturnCopiesSelectionAndRequestsClose() async {
        let harness = await QuickPanelHarness.make(contents: ["one", "two"])
        harness.store.setSelection(harness.items[1].id, for: .quickPanel)

        await harness.handler.handle(.copySelection)

        XCTAssertEqual(harness.pasteboard.writtenText, "two")
        XCTAssertEqual(harness.coordinator.closeCount, 1)
    }

    func testEscapeClearsSearchBeforeClosing() async {
        let harness = await QuickPanelHarness.make(contents: ["one"])
        await harness.store.updateQuery(
            .quickPanel(searchText: "query", favoritesOnly: false),
            for: .quickPanel
        )

        await harness.handler.handle(.escape)
        XCTAssertEqual(harness.store.session(for: .quickPanel).query.searchText, "")
        XCTAssertEqual(harness.coordinator.closeCount, 0)

        await harness.handler.handle(.escape)
        XCTAssertEqual(harness.coordinator.closeCount, 1)
    }

    func testCommandReturnOpensSelectedItemInLibrary() async {
        let harness = await QuickPanelHarness.make(contents: ["one"])
        harness.store.setSelection(harness.items[0].id, for: .quickPanel)
        await harness.handler.handle(.openSelectionInLibrary)
        XCTAssertEqual(harness.coordinator.openedLibraryID, harness.items[0].id)
    }
}
~~~

Also test move boundaries, favorite, delete, and Command-F focus intent.

Define QuickPanelHarness in the test file. It owns an InMemoryRepository, FakePasteboardWriter, ClipboardStore, RecordingQuickPanelCoordinator, QuickPanelCommandHandler, and seeded items. Its async make(contents:) factory seeds each string, starts the store, and returns the fully connected harness. RecordingQuickPanelCoordinator stores closeCount and openedLibraryID and conforms to QuickPanelCoordinating.

- [ ] **Step 2: Run command tests and confirm failure**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClipFlowTests/QuickPanelCommandTests \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: compilation fails because the quick-panel command handler is absent.

- [ ] **Step 3: Implement asynchronous environment bootstrap**

`@MainActor AppEnvironment.live()` snapshots UserDefaults, then awaits actor-isolated database preparation so SQLite work does not execute on MainActor. It constructs one shared instance of every store/service, including CapturePipeline and MigrationBackupManager for the production database directory, and passes value-only LegacySettingsSnapshot data across actor boundaries.

Production uses the existing URL ~/Library/Application Support/ClipFlow/clipflow.sqlite3. It decodes the actual v1 `custom_categories` JSON as `[LegacyCustomCategoryV1]`, maps it to v2 values, and snapshots the legacy AI/default keys before repository preparation. Only after `.readWrite` migration commits does AppSettingsStore remove the old keys and force AI disabled/no consent. In `--ui-testing` mode it uses CLIPFLOW_TEST_DATABASE and ignores production UserDefaults.

AppCoordinator immediately creates the status item, then starts bootstrap in a Task. Before completion, opening the quick panel shows a small loading/error surface. After completion it injects the same ClipboardStore into quick panel, library, and settings. It passes `RepositoryStartup` into Store: `.readOnlyRecovery` renders an undismissable banner with backup path/reveal action in quick panel and library, and disables favorite/delete/category/summary mutations while keeping browse and copy enabled. If even read-only recovery cannot open, show the blocking startup error and never create a replacement database.

ErrorBanner takes an async `onRecoveryAction` callback wired to one RecoveryActionHandler. `.retry(surface)` awaits Store.reload, `.openSettings` calls AppCoordinator, `.revealBackup(url)` uses the narrow FileRevealing/NSWorkspace boundary, and `.deleteMigrationBackups` awaits Store deletion. Tests invoke each production route once and assert the visible banner is cleared only after successful recovery.

The status menu keeps Open History, Settings, Pause/Resume Monitoring, About, and Quit. Its NSStatusBarButton always exposes accessibility label “ClipFlow”, help “Open ClipFlow clipboard history”, and a content-free value reflecting active/paused/copied/error state. The main app menu owns the single registrations for Settings with key equivalent comma and Quit ClipFlow with key equivalent q, so Command-, and Command-Q work regardless of focused surface; SwiftUI views invoke the same coordinator actions and do not register duplicate shortcuts. Left-click toggles the popover; right-click opens the status menu; the global hotkey toggles the same popover. Add coordinator command/accessibility tests for left click, right-click menu, Settings, and Quit routes.

AppDelegate becomes a thin lifecycle adapter:

~~~swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }
}
~~~

Keep main.swift as the manual NSApplication entry point so the app remains macOS 13 compatible and menu-bar-first.

The AppKit bridge is intentionally narrow: NSStatusItem/NSPopover, the three long-lived NSWindow owners, NSMenu command routing, and first-responder keyboard interception are capabilities the existing manual lifecycle needs. SwiftUI remains the source of truth for selection and business state; views never retain NSWindow/NSView globally. Production stays accessory/no-Dock by design, while opening Library calls `NSApp.activate(ignoringOtherApps: true)`.

- [ ] **Step 4: Implement QuickPanelView**

QuickPanelView is 440 × 520 and contains:

1. Header with the visible product name ClipFlow, MonitoringStatusView, pause menu, and library button.
2. Focused search field using @FocusState.
3. Recent/Favorites picker.
4. List(selection:) limited to 50 rows.
5. Footer with result count, shortcut, and error entry.

The pause menu has exactly Pause 5 Minutes, Pause 1 Hour, and Pause Until Resumed. Both it and Settings call ClipboardStore.pauseMonitoring/resumeMonitoring; MonitoringStatusView reads Store.monitoringPause and continuously shows the shared remaining time.

QuickClipRow shows two lines of content, category text plus icon, relative time, favorite, and copy button. Single click selects; simultaneous double-click copies through the command handler. Every row has a context menu for Copy, Favorite, Open in History, and Delete. A successful soft delete exposes a visible Undo action for that item. Do not rely on hover to reveal critical actions.

QuickPanelKeyboardBridge is a narrow NSViewRepresentable that converts keyDown events to QuickPanelCommand:

~~~swift
struct QuickPanelKeyboardBridge: NSViewRepresentable {
    let onCommand: (QuickPanelCommand) -> Void

    func makeNSView(context: Context) -> KeyboardView {
        KeyboardView(onCommand: onCommand)
    }

    func updateNSView(_ nsView: KeyboardView, context: Context) {
        nsView.onCommand = onCommand
    }
}
~~~

The bridge handles arrows, Return, Command-Return, Command-F, Command-Shift-F, Delete, and Escape. Down/Up from search moves focus to the native List before changing selection; Command-F returns focus to search. Therefore Backspace/Delete edits text while search is first responder and deletes the selected clip only while List is focused. It must not consume ordinary text input.

QuickPanelKeyboardBridge keeps its local event monitor and target-action wiring inside its Coordinator, removes the monitor in `dismantleNSView`, and updates callbacks without creating a second state store.

On `.copied` or `.copiedWithMetadataWarning`, QuickPanelCommandHandler closes the popover and asks AppCoordinator to show content-free copy feedback by briefly changing the status-item symbol/accessibility value for 1.5 seconds; the warning variant also keeps an error-history entry. `.clipboardWriteFailed` keeps the panel open and shows retryable ErrorBanner. Tests cover all three routes, close/no-close behavior, status feedback reset, and absence of copied text in feedback.

On every presentation, set search focus on the next main-run-loop turn; the XCUITest must type without clicking first. Assign stable accessibility identifiers: quick.search, quick.list, quick.monitoring, quick.openLibrary, quick.pauseMenu, quick.row.<UUID>, quick.undo.<UUID>, quick.recoveryBanner, and quick.errorBanner.

QuickPanelView reads only `session(for: .quickPanel)` and writes query changes through `updateQuery(_:for: .quickPanel)`. Library uses a separate session, so simultaneous windows cannot overwrite each other's search/scope/page/selection state. Each presentation validates Quick selection against visible rows and selects the first row or nil; Return can never act on an invisible Library selection. Command-Return passes the visible Quick ID to `openLibrary(selectedID:)`, which sets Library selection explicitly.

`presentQuickPanelAndWaitUntilReadyForTesting()` installs a one-shot continuation and presents the normal NSPopover. QuickPanelReadyProbe resumes only after the popover is shown, one full layout pass completes, `quick.search` is the first responder, and the first loaded `quick.row.<UUID>` is present in the accessibility tree. `onAppear` alone is not ready. `closeQuickPanelForTesting()` closes the same popover. No fake presenter or no-op clock is used for the 200 ms gate.

- [ ] **Step 5: Build and run unit tests**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build -project ClipFlow.xcodeproj -scheme ClipFlow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/QuickPanelDerivedData \
  CODE_SIGNING_ALLOWED=NO

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: BUILD SUCCEEDED and all tests pass.

- [ ] **Step 6: Commit**

~~~bash
git add ClipFlow/App/AppEnvironment.swift ClipFlow/App/AppCoordinator.swift \
  ClipFlow/App/AppDelegate.swift ClipFlow/main.swift \
  ClipFlow/App/RecoveryActionHandler.swift \
  ClipFlow/Views/QuickPanel/QuickPanelView.swift \
  ClipFlow/Views/QuickPanel/QuickClipRow.swift \
  ClipFlow/Views/QuickPanel/QuickPanelKeyboardBridge.swift \
  ClipFlow/Views/Shared/ErrorBanner.swift ClipFlow/Views/Shared/MonitoringStatusView.swift \
  ClipFlowTests/Views/QuickPanelCommandTests.swift \
  ClipFlowTests/App/RecoveryActionHandlerTests.swift \
  ClipFlowTests/App/AppCoordinatorAccessibilityTests.swift \
  ClipFlow.xcodeproj/project.pbxproj
git commit -m "feat: redesign ClipFlow quick panel"
~~~

### Task 10: Build the resizable library and item-bound detail workflow

**Files:**
- Create: ClipFlow/Views/Library/LibraryView.swift
- Create: ClipFlow/Views/Library/LibrarySidebar.swift
- Create: ClipFlow/Views/Library/ClipListView.swift
- Create: ClipFlow/Views/Library/ClipDetailView.swift
- Create: ClipFlow/Views/Library/AIResultView.swift
- Create: ClipFlow/Views/Library/ClipDetailActionAdapter.swift
- Create: ClipFlow/Views/Library/RemoteConsentSheetPresenter.swift
- Create: ClipFlow/Stores/AIActionCoordinator.swift
- Create: ClipFlow/Models/LibrarySection.swift
- Modify: ClipFlow/App/AppCoordinator.swift
- Create: ClipFlowTests/Views/LibrarySectionTests.swift
- Create: ClipFlowTests/Views/ClipDetailActionTests.swift
- Create: ClipFlowTests/Stores/AIActionCoordinatorTests.swift
- Create: ClipFlowTests/Support/RecordingRemoteConsentPresenter.swift

**Interfaces:**
- Consumes: the same ClipboardStore and AIJobCoordinator used by the quick panel.
- Produces: a 1040 × 680 resizable library window with a 760 × 520 minimum and restored frame.

~~~swift
enum LibrarySection: Hashable, Sendable {
    case all
    case favorites
    case today
    case builtIn(ClipboardItem.Category)
    case custom(UUID)

    static let fixed: [LibrarySection] = [.all, .favorites, .today]
}

@MainActor
protocol ClipDetailActions: AnyObject {
    func copy(itemID: UUID) async
    func toggleFavorite(itemID: UUID) async
    func delete(itemID: UUID) async
    func summarize(itemID: UUID) async
    func categorize(itemID: UUID) async
    func rewrite(itemID: UUID) async
}

@MainActor
protocol RemoteConsentPresenting: AnyObject {
    func confirmFirstSend(to origin: AIConsentOrigin) async -> Bool
}

@MainActor
final class AIActionCoordinator {
    init(
        settings: AppSettingsStore,
        jobs: AIJobCoordinator,
        consentPresenter: any RemoteConsentPresenting
    )
    func start(
        item: ClipboardItem,
        operation: AIOperation,
        allowedCategories: [PersistedCustomCategory]
    ) async
}
~~~

- [ ] **Step 1: Write stable sidebar and target-ID action tests**

~~~swift
func testFixedSidebarSectionsHaveStableOrder() {
    XCTAssertEqual(
        LibrarySection.fixed,
        [.all, .favorites, .today]
    )
}

@MainActor
func testDetailActionUsesRenderedItemIDNotCurrentSelection() async throws {
    let harness = await ClipDetailActionHarness.make()
    let renderedID = UUID()
    let selectionAfterRender = UUID()
    await harness.seed(id: renderedID, content: "rendered")
    harness.store.setSelection(selectionAfterRender, for: .library)

    await harness.adapter.summarize(itemID: renderedID)

    let requestedItemIDs = await harness.ai.requestedItemIDs
    XCTAssertEqual(requestedItemIDs, [renderedID])
}
~~~

ClipDetailActionHarness constructs the production ClipDetailActionAdapter, production AIActionCoordinator, ClipboardStore, a ControllableAIService, and RecordingRemoteConsentPresenter. It loads the rendered item by ID; the adapter never reads current selection to construct AIRequest. Add production-path tests: remote consent reject produces zero AI/HTTP calls, accept produces exactly one item-bound call, and changing scheme/host/port requires the scene presenter again. The consent presenter is owned by the Library scene/window and renders its sheet there; SettingsActionAdapter never presents first-send consent.

- [ ] **Step 2: Run tests and confirm missing library types**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClipFlowTests/LibrarySectionTests \
  -only-testing:ClipFlowTests/ClipDetailActionTests \
  -only-testing:ClipFlowTests/AIActionCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: compilation fails on LibrarySection and the new detail-action interface.

- [ ] **Step 3: Implement the NavigationSplitView hierarchy**

LibraryView owns NavigationSplitViewVisibility and binds:

- sidebar selection to LibrarySection.
- list selection to the `.library` ClipQuerySession selectedItemID.
- search/scope/page to ClipboardStore's `.library` ClipQuerySession.

LibrarySidebar renders fixed sections first, built-in categories in CaseIterable order, and custom categories in sortOrder. It never sorts categories by changing item count. Rows use native `.sidebar` styling with one icon, one title, and at most one secondary line; rich metadata stays in list/detail, and the sidebar keeps the system material/background.

ClipListView uses List(selection:), loads the next page when the final visible row appears, and exposes copy/favorite/delete through toolbar and context menus.

Single click selects a library row; double click copies it. This wording must match the quick panel and README.

ClipDetailView receives ClipboardItem plus explicit ClipDetailActions. It does not read AppDelegate.shared or ClipboardStore.selectedItem inside an async completion. Its content and AI results share one ScrollView; a bottom safe-area inset contains the fixed primary Copy button. At compact width, selecting a row pushes a detail destination with a visible Back action instead of compressing a third column.

Assign stable accessibility identifiers: library.sidebar, library.list, library.detail, library.sidebarToggle, library.copy, library.favorite, library.delete, and library.undo.

- [ ] **Step 4: Implement distinct AI result states**

AIResultView renders:

- summary state persisted on ClipboardItem.
- rewrite state held by AIJobCoordinator and cleared when the item/task is removed.
- category state tied to a requested item ID.

Each state has idle, running, success, and error. Success results have Copy Result. Rewrite never overwrites original content or aiSummary.

ClipDetailView calls `AIJobCoordinator.cancelAll(itemID:)` only when that detail is explicitly dismissed/window closes, not merely when selection changes. Library close then clears transient rewrite states. Tests cover cancel-on-close, cancelled-no-write, selection A→B without retargeting A's running job, and close/reopen showing no rewrite while the persisted summary remains. AIActionCoordinator converts AppSettingsStore into the exact provider configuration for every send; disabled returns without a request, local revalidates loopback, and remote revalidates HTTPS/origin consent immediately before starting the job.

- [ ] **Step 5: Add the library NSWindow path**

AppCoordinator.openLibrary(selectedID:) creates or reuses one NSWindow:

- contentRect 1040 × 680.
- minSize 760 × 520.
- titled, closable, miniaturizable, resizable.
- frame autosave name ClipFlow.LibraryWindow.
- NSHostingController(rootView: LibraryView(store: environment.store, aiActions: libraryAIActionCoordinator, consentPresenter: libraryConsentPresenter)).

If selectedID is non-nil, call `ClipboardStore.loadItem(id:)` first so a record outside the active page/filter enters itemCache, then set Library-session selection before bringing the window forward. Activate the app after showing the window. The window delegate intercepts the first close request, returns false, awaits AI cancellation/repository generation invalidation, clears transient rewrite state, then performs the real close under a reentrancy flag; the menu-bar process remains running.

- [ ] **Step 6: Build, run unit tests, and manually inspect resizing**

Run the full build and test commands from Task 9.

Manual expected behavior:

- Sidebar toggle remains reachable when the sidebar is hidden.
- At minimum width, detail collapses instead of shrinking text below system sizes.
- Long content and AI results scroll; the Copy button remains reachable.
- Quick and Library keep independent selections; Command-Return explicitly transfers the Quick ID into Library without disturbing it on ordinary Quick navigation.
- A selected item outside the current library page opens correctly, and compact detail has a keyboard-reachable Back path.

- [ ] **Step 7: Commit**

~~~bash
git add ClipFlow/Views/Library/LibraryView.swift ClipFlow/Views/Library/LibrarySidebar.swift \
  ClipFlow/Views/Library/ClipListView.swift ClipFlow/Views/Library/ClipDetailView.swift \
  ClipFlow/Views/Library/AIResultView.swift \
  ClipFlow/Views/Library/ClipDetailActionAdapter.swift \
  ClipFlow/Views/Library/RemoteConsentSheetPresenter.swift \
  ClipFlow/Stores/AIActionCoordinator.swift \
  ClipFlow/Models/LibrarySection.swift ClipFlow/App/AppCoordinator.swift \
  ClipFlowTests/Views/LibrarySectionTests.swift \
  ClipFlowTests/Views/ClipDetailActionTests.swift \
  ClipFlowTests/Stores/AIActionCoordinatorTests.swift \
  ClipFlowTests/Support/RecordingRemoteConsentPresenter.swift \
  ClipFlow.xcodeproj/project.pbxproj
git commit -m "feat: add full clipboard library"
~~~

### Task 11: Replace the settings UI and add privacy-safe diagnostics

**Files:**
- Create: ClipFlow/Views/Settings/SettingsRootView.swift
- Create: ClipFlow/Views/Settings/GeneralSettingsView.swift
- Create: ClipFlow/Views/Settings/HotkeySettingsView.swift
- Create: ClipFlow/Views/Settings/PrivacySettingsView.swift
- Create: ClipFlow/Views/Settings/CategorySettingsView.swift
- Create: ClipFlow/Views/Settings/AISettingsView.swift
- Create: ClipFlow/Views/Settings/DiagnosticsSettingsView.swift
- Create: ClipFlow/Services/ApplicationPicker.swift
- Create: ClipFlow/Services/DiagnosticsReportBuilder.swift
- Create: ClipFlow/Services/LaunchAtLoginService.swift
- Create: ClipFlow/Views/Settings/SettingsActionAdapter.swift
- Modify: ClipFlow/App/AppCoordinator.swift
- Create: ClipFlowTests/Services/DiagnosticsReportBuilderTests.swift
- Create: ClipFlowTests/Services/LaunchAtLoginServiceTests.swift
- Create: ClipFlowTests/Stores/CategoryMigrationTests.swift
- Create: ClipFlowTests/Views/SettingsActionAdapterTests.swift
- Create: ClipFlowTests/Support/FakeLoginItemRegistrar.swift

**Interfaces:**
- Consumes: AppSettingsStore, ClipboardStore, HotkeyService, AIEndpointValidator, KeychainCredentialStore.
- Produces: a standard 560 × 460 settings window and redacted diagnostics.

~~~swift
struct DiagnosticsSnapshot: Equatable, Sendable {
    var appVersion: String
    var buildNumber: String
    var macOSVersion: String
    var aiProviderKind: String
    var remoteConfigured: Bool
    var aiAvailable: Bool?
    var sensitiveProtectionEnabled: Bool
    var excludedApplicationCount: Int
    var recentEvents: [DiagnosticEvent]
}

@MainActor
protocol LoginItemRegistering: AnyObject {
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}

enum LaunchAtLoginError: Error, Equatable, Sendable {
    case registrationFailed
    case unregistrationFailed
}

@MainActor
final class LaunchAtLoginService: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var lastError: LaunchAtLoginError?

    init(registrar: any LoginItemRegistering)
    func setEnabled(_ enabled: Bool) -> Bool
}

@MainActor
final class SettingsActionAdapter {
    init(
        settings: AppSettingsStore,
        store: ClipboardStore,
        aiJobs: AIJobCoordinator,
        aiService: any AIServiceProtocol,
        keychain: any KeychainCredentialStoring,
        launchAtLogin: LaunchAtLoginService,
        logger: any AppLogging
    )
    func diagnosticsSnapshot() async -> DiagnosticsSnapshot
    func updatePrivacyConfiguration(_ configuration: PrivacyConfiguration) async
    func pauseMonitoring(_ state: MonitoringPause)
    func resumeMonitoring()
    func clearClipboardDataConfirmed() async -> ClearClipboardDataOutcome
    func deleteMigrationBackups() async -> Bool
}

struct DiagnosticsReportBuilder {
    func render(_ snapshot: DiagnosticsSnapshot) -> String
}
~~~

- [ ] **Step 1: Write redaction and category-deletion tests**

~~~swift
func testDiagnosticsNeverContainsClipOrCredentialText() async {
    let harness = await SettingsDiagnosticsHarness.make(
        clipText: "secret clip",
        credential: "Bearer top-secret",
        remoteURL: URL(string: "https://private-ai.example.com")!
    )
    await harness.logger.record(
        DiagnosticEvent(code: .aiRequest, timestamp: Date(timeIntervalSince1970: 0))
    )
    let snapshot = await harness.adapter.diagnosticsSnapshot()
    let report = DiagnosticsReportBuilder().render(snapshot)

    for canary in ["secret clip", "Bearer top-secret", "private-ai.example.com"] {
        XCTAssertFalse(report.contains(canary))
    }
    XCTAssertTrue(report.contains("ai.request"))
    XCTAssertTrue(report.contains("remoteConfigured=true"))
}

func testDeletingCategoryMigratesItemsBeforeRemovingCategory() async throws {
    let repository = try await makeRepository()
    let source = PersistedCustomCategory.fixture(name: "Old", sortOrder: 0)
    let target = PersistedCustomCategory.fixture(name: "New", sortOrder: 1)
    try await repository.saveCategory(source)
    try await repository.saveCategory(target)
    let item = try await repository.upsertCapturedText(.fixture("categorized"))
    _ = try await repository.setCustomCategory(id: item.id, categoryID: source.id)

    try await repository.deleteCategory(id: source.id, migrateTo: target.id)

    let migratedItem = try await repository.item(id: item.id)
    let categories = try await repository.fetchCategories()
    XCTAssertEqual(migratedItem?.customCategoryID, target.id)
    XCTAssertFalse(categories.contains { $0.id == source.id })
}
~~~

The diagnostic model deliberately has no endpoint, message, clip, prompt, result, or credential String field. In the test, first place every canary in isolated UserDefaults, a fake Keychain, a fake upstream Error, and a seeded clip, then build DiagnosticsSnapshot only through the production SettingsActionAdapter/AppLogger path; assert none appears in output. A constructor-only snapshot test is not sufficient.

LaunchAtLoginServiceTests use FakeLoginItemRegistrar to prove registration success, failure rollback, unregistration success/failure rollback, and same-value no-op. SystemLoginItemRegistrar wraps `SMAppService.mainApp`; “launch behavior” in General means Launch at Login.

- [ ] **Step 2: Run tests and confirm missing settings support**

Run:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClipFlowTests/DiagnosticsReportBuilderTests \
  -only-testing:ClipFlowTests/LaunchAtLoginServiceTests \
  -only-testing:ClipFlowTests/CategoryMigrationTests \
  -only-testing:ClipFlowTests/SettingsActionAdapterTests \
  CODE_SIGNING_ALLOWED=NO
~~~

Expected: compilation fails on DiagnosticsReportBuilder and category test helpers.

- [ ] **Step 3: Implement the standard settings window**

SettingsRootView uses a labeled six-tab TabView (General, Hotkey, Privacy, Categories, AI, Diagnostics) with system icons and macOS settings spacing. It does not draw a second title bar or close button.

Because ClipFlow deliberately retains its manual macOS 13 NSApplication/status-item lifecycle, AppCoordinator.openSettings is the single narrow AppKit equivalent of a SwiftUI Settings scene: it owns one reusable titled/closable NSWindow at 560 × 460, gives it the logical title “ClipFlow Settings”, and wires Command-, in the main application menu. Settings views do not retain the window.

Every Toggle and Slider has a visible or accessibility label. Every icon-only button has accessibilityLabel and help. Critical text uses system font sizes.

- [ ] **Step 4: Implement each settings behavior**

- General: retention 1...365/forever, max capture bytes, Launch at Login, and monitoring. Retention change queries affected count, asks confirmation, then calls ClipboardStore.updateRetention. Launch toggle calls transactional LaunchAtLoginService and rolls back its visual state on SMAppService failure.
- Hotkey: record modifiers/key, validate, call transactional HotkeyService, show lastError without losing old value.
- Privacy: toggle sensitive rules and edit excluded bundle IDs only through SettingsActionAdapter → ClipboardStore.updatePrivacyConfiguration, which establishes the pipeline barrier before visible persistence; use NSOpenPanel restricted to .app, read CFBundleIdentifier, and never store app path as identity. Show that source-app detection is best effort when the foreground app changes before the 0.5-second pasteboard poll.
- Categories: add/edit/reorder through ClipboardStore; normalized names are unique; delete requires “clear” or an explicit replacement ID and executes the production repository transaction.
- AI: disabled/local/remote; local enforces loopback. Saving a remote HTTPS endpoint does not grant consent. SettingsActionAdapter manages configuration, availability, and credentials only; Task 10's scene-scoped AIActionCoordinator/RemoteConsentSheetPresenter owns first-send confirmation in the Library window. Endpoint-origin change revokes consent. Availability uses `checkAvailability` (3 seconds); Remove Credential calls the async Keychain API.
- Privacy: in addition to exclusions/sensitive rules, Clear Clipboard Data first calls `countAllClips`, confirms that all clips/favorites/summaries, AI usage metadata, and every managed migration backup will be removed while settings/categories/credentials remain, awaits `AIJobCoordinator.cancelAll()`, then calls `ClipboardStore.deleteAllClipboardDataConfirmed()`. Database failure leaves both sessions and selection unchanged; backup-file failure produces the explicit partial outcome and retry action described in Task 6.
- Diagnostics: render/copy/export the closed DiagnosticsSnapshot schema only; clear AI metadata through ClipboardStore; reveal database/backup location in Finder without adding paths to exported text.

- [ ] **Step 5: Run tests and manual accessibility checks**

Regenerate and run the full unit suite:

~~~bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
~~~

Manual expected behavior:

- Command-, opens settings from quick panel, library, and status menu.
- Window title is shown once.
- VoiceOver announces each tab, toggle, slider value, and icon button.
- Changing endpoint origin clears consent.
- No generated result or original clip appears in diagnostics.
- Launch-at-login failure leaves the prior system/UI value unchanged.
- Read-only recovery disables all mutating settings actions but keeps reveal-backup and diagnostics available.

- [ ] **Step 6: Commit**

~~~bash
git add ClipFlow/Views/Settings/SettingsRootView.swift \
  ClipFlow/Views/Settings/GeneralSettingsView.swift \
  ClipFlow/Views/Settings/HotkeySettingsView.swift \
  ClipFlow/Views/Settings/PrivacySettingsView.swift \
  ClipFlow/Views/Settings/CategorySettingsView.swift \
  ClipFlow/Views/Settings/AISettingsView.swift \
  ClipFlow/Views/Settings/DiagnosticsSettingsView.swift \
  ClipFlow/Views/Settings/SettingsActionAdapter.swift \
  ClipFlow/Services/ApplicationPicker.swift \
  ClipFlow/Services/DiagnosticsReportBuilder.swift \
  ClipFlow/Services/LaunchAtLoginService.swift ClipFlow/App/AppCoordinator.swift \
  ClipFlowTests/Services/DiagnosticsReportBuilderTests.swift \
  ClipFlowTests/Services/LaunchAtLoginServiceTests.swift \
  ClipFlowTests/Stores/CategoryMigrationTests.swift \
  ClipFlowTests/Views/SettingsActionAdapterTests.swift \
  ClipFlowTests/Support/FakeLoginItemRegistrar.swift \
  ClipFlow.xcodeproj/project.pbxproj
git commit -m "feat: redesign ClipFlow settings"
~~~

### Task 12: Remove legacy services, add UI/performance tests, and close warning gaps

**Files:**
- Delete: ClipFlow/Services/DatabaseService.swift
- Delete: ClipFlow/Services/ClipboardMonitor.swift
- Delete: ClipFlow/Services/OllamaService.swift
- Delete: ClipFlow/Services/TinyLocalAIService.swift
- Delete: ClipFlow/Views/ContentView.swift
- Delete: ClipFlow/Views/ClipboardListView.swift
- Delete: ClipFlow/Views/DetailView.swift
- Delete: ClipFlow/Views/SettingsView.swift
- Delete: ClipFlow/Views/Components/AIGeneratingView.swift
- Delete: ClipFlow/Views/Components/ClipboardItemRow.swift
- Delete: script/check_bugfixes.sh
- Delete: script/check_tiny_ai.swift
- Delete: script/check_categories.py
- Delete: script/build_and_replace.sh
- Modify: ClipFlow/Models/ClipboardItem.swift
- Modify: project.yml
- Create: ClipFlow/App/UITestBootstrap.swift
- Create: ClipFlowTests/Performance/RepositoryPerformanceTests.swift
- Create: ClipFlowTests/Performance/QuickPanelPerformanceTests.swift
- Create: ClipFlowUITests/QuickPanelUITests.swift
- Create: ClipFlowUITests/LibraryUITests.swift
- Create: ClipFlowUITests/Support/UITestLauncher.swift
- Regenerate: ClipFlow.xcodeproj/project.pbxproj
- Create: docs/qa/2026-07-10-clipflow-2-acceptance.md

**Interfaces:**
- Consumes: every new 2.0 component.
- Produces: no production reference to DatabaseService, ClipboardMonitor, OllamaService, APIUsageStore, CustomCategoryStore, or AppDelegate.shared; UI-test launch mode with synthetic non-sensitive data.

- [ ] **Step 1: Add the UI test target**

Add to project.yml:

~~~yaml
  ClipFlowUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: ClipFlowUITests
    dependencies:
      - target: ClipFlow
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.clipflow.v12.uitests
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGNING_ALLOWED: NO
        TEST_TARGET_NAME: ClipFlow
~~~

Add ClipFlowUITests to the ClipFlow scheme test targets.

Do not enable warnings-as-errors on the App or unit-test target yet: the RED UI run must reach the missing fixture, and the known legacy warnings are removed only in Step 6.

- [ ] **Step 2: Write UI tests first and prove the fixture mode is absent**

Create the QuickPanelUITests, LibraryUITests, and shared launcher from Step 4 below, regenerate, and run the UI classes. Expected: tests build, launch the ordinary menu-bar app, and fail because `quick.search` never appears as a regular fixture window. This is the RED result; do not create UITestBootstrap first.

- [ ] **Step 3: Add a deterministic UI-test bootstrap**

When process arguments contain --ui-testing:

- use a temporary database URL from CLIPFLOW_TEST_DATABASE.
- disable real pasteboard monitoring.
- seed only “Project roadmap”, “https://example.com”, and “Meeting notes”.
- open a regular test-host window containing QuickPanelView.
- call `NSApp.setActivationPolicy(.regular)` and `NSApp.activate(ignoringOtherApps: true)` before showing the fixture window.
- never read the user’s pasteboard or production database.

UITestBootstrap is compiled in production but only activates for the explicit argument.

- [ ] **Step 4: Complete keyboard and window UI tests**

QuickPanelUITests must:

~~~swift
func testKeyboardSearchSelectionAndCopy() {
    let app = launchFixtureApp()
    let search = app.textFields["quick.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 2))
    app.typeText("roadmap") // no click: proves automatic first-responder focus
    app.typeKey(.downArrow, modifierFlags: [])
    app.typeKey(.return, modifierFlags: [])
    XCTAssertFalse(search.waitForExistence(timeout: 1))
}

func testEscapeClearsThenCloses() {
    let app = launchFixtureApp()
    let search = app.textFields["quick.search"]
    search.typeText("notes")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertEqual(search.value as? String, "")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(search.exists)
}
~~~

Create ClipFlowUITests/Support/UITestLauncher.swift with this shared launch helper:

~~~swift
func launchFixtureApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment["CLIPFLOW_TEST_DATABASE"] =
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clipflow-\(UUID().uuidString).sqlite3")
    app.launch()
    return app
}
~~~

LibraryUITests contains separate methods for Command-Return opening the selected out-of-page item, sidebar hide/show, favorite, delete/visible undo, detail scrolling/fixed Copy, settings via Command-, read-only mutation disabling, and 760 × 520 minimum sizing. QuickPanelUITests also right-clicks a row and asserts Copy/Favorite/Open/Delete menu items plus `quick.undo.<UUID>`. Each test launches a fresh fixture database and waits on accessibility identifiers rather than sleeping.

- [ ] **Step 5: Add repository and real-popover performance tests**

RepositoryPerformanceTests seeds 10,000 synthetic records outside the measured block, then measures 20 searches:

~~~swift
func testTenThousandClipSearchP95() async throws {
    let repository = try await makeRepository()
    try await repository.seedSyntheticClips(count: 10_000)
    let durations = try await measureDurations(iterations: 20) {
        _ = try await repository.fetchPage(
            .init(searchText: "needle-9999", scope: .all, limit: 100, offset: 0)
        )
    }
    XCTAssertLessThan(percentile95(durations), 0.100)
}
~~~

Define the measurement helpers in the same test file:

~~~swift
func measureDurations(
    iterations: Int,
    operation: () async throws -> Void
) async rethrows -> [TimeInterval] {
    var values: [TimeInterval] = []
    let clock = ContinuousClock()
    for _ in 0..<iterations {
        let start = clock.now
        try await operation()
        let components = start.duration(to: clock.now).components
        values.append(
            TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1e18
        )
    }
    return values
}

func percentile95(_ values: [TimeInterval]) -> TimeInterval {
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
    return sorted[max(0, index)]
}

@MainActor
func measureMainActorDurations(
    iterations: Int,
    operation: @MainActor () async throws -> Void
) async rethrows -> [TimeInterval] {
    var values: [TimeInterval] = []
    let clock = ContinuousClock()
    for _ in 0..<iterations {
        let start = clock.now
        try await operation()
        let components = start.duration(to: clock.now).components
        values.append(
            TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1e18
        )
    }
    return values
}
~~~

seedSyntheticClips(count:) is a test-only ClipboardRepository extension that inserts deterministic text “clip-N needle-N” before timing; it is not compiled into the app.

QuickPanelPerformanceTests uses the production AppCoordinator instrumentation defined in Task 9:

~~~swift
@MainActor
func testWarmQuickPanelPresentationP95() async throws {
    let coordinator = try await AppCoordinator.performanceFixture()
    await coordinator.presentQuickPanelAndWaitUntilReadyForTesting()
    coordinator.closeQuickPanelForTesting()

    let durations = try await measureMainActorDurations(iterations: 20) {
        await coordinator.presentQuickPanelAndWaitUntilReadyForTesting()
        coordinator.closeQuickPanelForTesting()
    }

    XCTAssertLessThan(percentile95(durations), 0.200)
}
~~~

`performanceFixture()` uses synthetic in-memory data, the normal NSHostingController/NSPopover, no pasteboard monitoring, and a fully loaded Store. The measured end point is QuickPanelReadyProbe's shown+layout+first-responder+first-accessible-row condition from Task 9, not `onAppear`, method return, or a fake presenter.

- [ ] **Step 6: Remove compatibility state, legacy files, and superseded scripts**

TextClassifier already lives behind CapturePipeline from Task 5. Remove the remaining static categorizer, APIUsageStore, and CustomCategoryStore from ClipboardItem.swift. Remove ContentType and the contentType property; the legacy database content_type column remains migration-only and is not exposed as a 2.0 capability. Retire the four superseded grep/ad-hoc scripts listed above; XCTest plus the new test/build/package entrypoints become the only supported gates.

Only after those files are deleted, add the `Performance` configuration and strict warnings settings:

~~~yaml
configs:
  Debug: debug
  Performance: release
  Release: release

targets:
  ClipFlow:
    settings:
      base:
        SWIFT_STRICT_CONCURRENCY: complete
        SWIFT_TREAT_WARNINGS_AS_ERRORS: YES
        GCC_TREAT_WARNINGS_AS_ERRORS: YES
      configs:
        Performance:
          ENABLE_TESTABILITY: YES
  ClipFlowTests:
    settings:
      base:
        SWIFT_STRICT_CONCURRENCY: complete
        SWIFT_TREAT_WARNINGS_AS_ERRORS: YES
        GCC_TREAT_WARNINGS_AS_ERRORS: YES
      configs:
        Performance:
          ENABLE_TESTABILITY: YES
  ClipFlowUITests:
    settings:
      base:
        SWIFT_STRICT_CONCURRENCY: complete
        SWIFT_TREAT_WARNINGS_AS_ERRORS: YES
        GCC_TREAT_WARNINGS_AS_ERRORS: YES
~~~

Search for forbidden references:

~~~bash
rg -n 'DatabaseService|ClipboardMonitor|OllamaService|TinyLocalAIService|APIUsageStore|CustomCategoryStore|AppDelegate\.shared' ClipFlow
rg -n 'Process\s*\(' ClipFlow/Services/AIService.swift ClipFlow/Stores/AIJobCoordinator.swift
~~~

Expected: no matches from either command.

- [ ] **Step 7: Regenerate, test, analyze, and enforce warnings**

Run:

~~~bash
xcodegen generate

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/FullTestDerivedData \
  -skip-testing:ClipFlowTests/RepositoryPerformanceTests \
  -skip-testing:ClipFlowTests/QuickPanelPerformanceTests \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild analyze -project ClipFlow.xcodeproj -scheme ClipFlow \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath build/AnalyzeDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project ClipFlow.xcodeproj -scheme ClipFlow \
  -configuration Performance \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/PerformanceDerivedData \
  -only-testing:ClipFlowTests/RepositoryPerformanceTests \
  -only-testing:ClipFlowTests/QuickPanelPerformanceTests \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES
~~~

Expected: TEST SUCCEEDED, UI tests pass, optimized Performance gates pass, ANALYZE SUCCEEDED, and no source warnings.

- [ ] **Step 8: Run and record manual design acceptance**

Use synthetic data only. Verify:

- light and dark mode.
- Increase Contrast and Reduce Transparency.
- full keyboard path in quick panel and library.
- VoiceOver names/values for all controls.
- quick-panel 440 × 520 layout.
- library default/minimum sizes.
- settings 560 × 460 without a duplicate title bar.
- no hidden-sidebar trap.
- pause 5 minutes, 1 hour, and indefinitely.
- VoiceOver announces the menu-bar ClipFlow status item, its active/paused/copied/error value, left-click panel, and right-click menu.
- every icon-only control has a measured hit target of at least 28 × 28 points.
- categories remain understandable without color; critical body text is at least the system small style.
- content regions do not stack translucent material cards.

Write `docs/qa/2026-07-10-clipflow-2-acceptance.md` with machine/macOS/Xcode/build commit, synthetic-data declaration, one pass/fail row for every item above across quick/library/settings, VoiceOver notes, screenshot paths, and an explicit unresolved-items section. Any failure stays unchecked and blocks Task 13.

- [ ] **Step 9: Commit**

~~~bash
git add -- ClipFlow/Services/DatabaseService.swift ClipFlow/Services/ClipboardMonitor.swift \
  ClipFlow/Services/OllamaService.swift ClipFlow/Services/TinyLocalAIService.swift \
  ClipFlow/Views/ContentView.swift ClipFlow/Views/ClipboardListView.swift \
  ClipFlow/Views/DetailView.swift ClipFlow/Views/SettingsView.swift \
  ClipFlow/Views/Components/AIGeneratingView.swift \
  ClipFlow/Views/Components/ClipboardItemRow.swift ClipFlow/Models/ClipboardItem.swift \
  ClipFlow/App/UITestBootstrap.swift ClipFlowTests/Performance/RepositoryPerformanceTests.swift \
  ClipFlowTests/Performance/QuickPanelPerformanceTests.swift \
  ClipFlowUITests/QuickPanelUITests.swift ClipFlowUITests/LibraryUITests.swift \
  ClipFlowUITests/Support/UITestLauncher.swift project.yml \
  ClipFlow.xcodeproj/project.pbxproj script/check_bugfixes.sh \
  script/check_tiny_ai.swift script/check_categories.py script/build_and_replace.sh \
  docs/qa/2026-07-10-clipflow-2-acceptance.md
git commit -m "test: complete ClipFlow 2 integration coverage"
~~~

### Task 13: Add repeatable build/package entrypoints and update release docs

**Files:**
- Create: script/test.sh
- Create: script/build_release.sh
- Create: script/package_dmg.sh
- Create: script/build_and_run.sh
- Create: .codex/environments/environment.toml
- Modify: README.md
- Modify: CHANGELOG.md
- Create or replace: screenshots/menu-bar.png using synthetic data
- Produce: dist/release/ClipFlow-2.0.0-universal.dmg

**Interfaces:**
- Consumes: the passing 2.0 app and tests.
- Produces:
  - one stable test command.
  - one universal Release build command.
  - one local/Developer-ID-aware DMG command.
  - one Codex Run action.

- [ ] **Step 1: Create the stable test script**

script/test.sh:

~~~bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

cd "$ROOT"
xcodegen generate
xcodebuild test \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$ROOT/build/TestDerivedData" \
  -skip-testing:ClipFlowTests/RepositoryPerformanceTests \
  -skip-testing:ClipFlowTests/QuickPanelPerformanceTests \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

xcodebuild test \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -configuration Performance \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$ROOT/build/PerformanceDerivedData" \
  -only-testing:ClipFlowTests/RepositoryPerformanceTests \
  -only-testing:ClipFlowTests/QuickPanelPerformanceTests \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES
~~~

- [ ] **Step 2: Create the universal Release script**

script/build_release.sh:

~~~bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

cd "$ROOT"
xcodegen generate
xcodebuild clean build \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$ROOT/build/ReleaseDerivedData" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

BINARY="$ROOT/build/ReleaseDerivedData/Build/Products/Release/ClipFlow.app/Contents/MacOS/ClipFlow"
lipo -verify_arch arm64 x86_64 "$BINARY"
file "$BINARY"
~~~

Expected file output: Mach-O universal binary with x86_64 and arm64.

- [ ] **Step 3: Create package_dmg.sh**

Create this complete `script/package_dmg.sh`:

~~~bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
VERSION="2.0.0"
PRODUCTS="$ROOT/build/ReleaseDerivedData/Build/Products/Release"
SOURCE_APP="$PRODUCTS/ClipFlow.app"
mkdir -p "$ROOT/build" "$ROOT/dist/release"
WORK_ROOT="$(mktemp -d "$ROOT/build/clipflow-package.XXXXXX")"
STAGE="$WORK_ROOT/ClipFlow-$VERSION"
APP="$STAGE/ClipFlow.app"
MOUNT_POINT="$WORK_ROOT/mount"
DMG="$ROOT/dist/release/ClipFlow-$VERSION-universal.dmg"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT INT TERM

"$ROOT/script/build_release.sh"
rm -f "$DMG"
mkdir -p "$STAGE" "$MOUNT_POINT" "$(dirname "$DMG")"
ditto "$SOURCE_APP" "$APP"
ln -s /Applications "$STAGE/Applications"

SIGNED_WITH_DEVELOPER_ID=0
NOTARIZED=0
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$APP"
  SIGNED_WITH_DEVELOPER_ID=1
else
  codesign --force --options runtime --timestamp=none --sign - "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E 'flags=.*runtime' >/dev/null

hdiutil create \
  -volname "ClipFlow $VERSION" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG"

if [[ "$SIGNED_WITH_DEVELOPER_ID" -eq 1 ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"
fi

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  if [[ "$SIGNED_WITH_DEVELOPER_ID" -ne 1 ]]; then
    echo "NOTARYTOOL_PROFILE requires DEVELOPER_ID_APPLICATION" >&2
    exit 2
  fi
  xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  NOTARIZED=1
fi

hdiutil verify "$DMG"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
MOUNTED=1
test -d "$MOUNT_POINT/ClipFlow.app"
test -L "$MOUNT_POINT/Applications"
test "$(readlink "$MOUNT_POINT/Applications")" = "/Applications"
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/ClipFlow.app"
lipo -verify_arch arm64 x86_64 \
  "$MOUNT_POINT/ClipFlow.app/Contents/MacOS/ClipFlow"

if [[ "$NOTARIZED" -eq 1 ]]; then
  spctl --assess --type execute --verbose=4 "$MOUNT_POINT/ClipFlow.app"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
  echo "DEVELOPER ID BUILD — NOTARIZED AND STAPLED"
elif [[ "$SIGNED_WITH_DEVELOPER_ID" -eq 1 ]]; then
  echo "DEVELOPER ID BUILD — NOT NOTARIZED"
else
  echo "LOCAL TEST BUILD — AD-HOC SIGNED, NOT NOTARIZED"
fi

hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0
shasum -a 256 "$DMG"
~~~

The script is repeatable and fail-safe, but does not claim byte-for-byte deterministic DMGs. Ad-hoc output is never described as public-distribution ready.

- [ ] **Step 4: Create the run entrypoint and Codex action**

The build-macos-apps:build-run-debug skill requires one project-local entrypoint. Create `script/build_and_run.sh`:

~~~bash
#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ClipFlow"
BUNDLE_ID="com.clipflow.v12"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
DERIVED_DATA="$ROOT/build/RunDerivedData"
APP="$DERIVED_DATA/Build/Products/Debug/ClipFlow.app"
BINARY="$APP/Contents/MacOS/ClipFlow"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
cd "$ROOT"
xcodegen generate
xcodebuild build \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

open_app() {
  /usr/bin/open -n "$APP"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact \
      --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact \
      --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..30}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.1
    done
    echo "ClipFlow did not launch within 3 seconds" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
~~~

Create `.codex/environments/environment.toml` with the canonical single Run action (the Run button launches normally; CI/manual verification uses `--verify`):

~~~toml
# THIS IS AUTOGENERATED. DO NOT EDIT MANUALLY
version = 1
name = "ClipFlow"

[setup]
script = ""

[[actions]]
name = "Run"
icon = "run"
command = "./script/build_and_run.sh"
~~~

After writing the files, run:

~~~bash
chmod +x script/test.sh script/build_release.sh script/package_dmg.sh script/build_and_run.sh
./script/build_and_run.sh --verify
~~~

Expected: Debug build succeeds, app launches, and pgrep confirms ClipFlow.

- [ ] **Step 5: Update product documentation**

README must state:

- 2.0 text-only scope.
- single click selects and double click copies.
- quick-panel and full-library shortcuts.
- default 15-day retention and privacy pause/exclusions.
- migration backups are private, retained for at most 24 hours, and removed immediately by Clear Clipboard Data/Delete Backups.
- local AI behavior and explicit remote HTTPS disclosure.
- exact local database path and the fact that app-level E2E encryption is not provided.
- local test DMG versus Developer ID/notarized distribution.

CHANGELOG must add 2.0.0 with the redesigned UI, repository migration, privacy guard, AI boundaries, hotkey rollback, tests, universal build, and known external notarization prerequisite.

Capture screenshots/menu-bar.png from UI-test synthetic data; it must not contain real clipboard text.

- [ ] **Step 6: Run the full release gate**

Run:

~~~bash
./script/test.sh
./script/build_release.sh
rm -rf build
./script/package_dmg.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild analyze -project ClipFlow.xcodeproj -scheme ClipFlow \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/ReleaseAnalyzeDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

git diff --check
~~~

Expected:

- all unit and UI tests pass.
- Debug/Release/Analyze succeed with no source warnings.
- universal architecture is reported.
- codesign strict verification passes.
- hdiutil checksum and mount verification pass.
- SHA-256 is printed.
- Gatekeeper/notarization is reported honestly according to available identity.

- [ ] **Step 7: Commit**

Do not stage doex.md, ClipFlow.dmg, README_CN.md, or unrelated files. Review the pre-existing README/CHANGELOG edits before staging the final integrated versions.

~~~bash
git add script/test.sh script/build_release.sh script/package_dmg.sh \
  script/build_and_run.sh .codex/environments/environment.toml \
  README.md CHANGELOG.md screenshots/menu-bar.png
git diff --cached --check
git commit -m "release: prepare ClipFlow 2.0.0"
~~~

## Final Completion Audit

Before claiming ClipFlow 2.0 complete:

- [ ] Map every section of docs/superpowers/specs/2026-07-10-clipflow-2-redesign.md to a task and test result.
- [ ] Confirm no legacy singleton/service reference remains.
- [ ] Confirm every explicit UI size, shortcut, timeout, retention, privacy, and undo value matches the spec.
- [ ] Confirm disabled AI made zero network/process calls in tests.
- [ ] Confirm the item-ID concurrency regression test passed.
- [ ] Confirm database rollback, NUL text, permissions, duplicate refresh, and cleanup tests passed.
- [ ] Confirm quick panel/library/settings manual accessibility checks were recorded.
- [ ] Confirm 10,000-row search and 20-run quick-panel p95 gates passed.
- [ ] Confirm Debug, Release, Analyze, strict concurrency, unit tests, UI tests, and DMG validation passed.
- [ ] Confirm README, CHANGELOG, screenshot, version, and artifact name match 2.0.0.
- [ ] Confirm Developer ID/notarization status is reported as an external prerequisite if the identity remains unavailable.
