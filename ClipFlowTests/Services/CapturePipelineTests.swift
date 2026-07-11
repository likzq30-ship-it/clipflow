import XCTest
@testable import ClipFlow

final class CapturePipelineTests: XCTestCase {
    func testSensitiveCaptureNeverReachesClassifierOrRepository() async throws {
        let repository = InMemoryRepository()
        let classifier = SpyTextClassifier(result: .english)
        let pipeline = makePipeline(
            repository: repository,
            classifier: classifier,
            configuration: .standard
        )

        let event = await pipeline.process(
            .fixture("-----BEGIN PRIVATE KEY-----\nsecret")
        )
        let classifierCallCount = await classifier.callCount
        let repositoryItemCount = try await itemCount(in: repository)

        XCTAssertEqual(event, .skipped(.sensitive(.privateKey)))
        XCTAssertEqual(classifierCallCount, 0)
        XCTAssertEqual(repositoryItemCount, 0)
    }

    func testExcludedApplicationNeverReachesClassifierOrRepository() async throws {
        let repository = InMemoryRepository()
        let classifier = SpyTextClassifier(result: .english)
        let pipeline = makePipeline(
            repository: repository,
            classifier: classifier,
            configuration: PrivacyConfiguration(
                excludedBundleIDs: ["com.password.manager"],
                maxUTF8Bytes: 1,
                detectsSensitiveContent: true
            )
        )

        let event = await pipeline.process(
            .fixture(
                "-----BEGIN PRIVATE KEY-----\nsecret",
                sourceBundleID: "com.password.manager"
            )
        )
        let classifierCallCount = await classifier.callCount
        let repositoryItemCount = try await itemCount(in: repository)

        XCTAssertEqual(event, .skipped(.excludedApplication))
        XCTAssertEqual(classifierCallCount, 0)
        XCTAssertEqual(repositoryItemCount, 0)
    }

    func testOversizeCaptureNeverReachesClassifierOrRepository() async throws {
        let repository = InMemoryRepository()
        let classifier = SpyTextClassifier(result: .english)
        let pipeline = makePipeline(
            repository: repository,
            classifier: classifier,
            configuration: PrivacyConfiguration(
                excludedBundleIDs: [],
                maxUTF8Bytes: 3,
                detectsSensitiveContent: true
            )
        )

        let event = await pipeline.process(.fixture("你好"))
        let classifierCallCount = await classifier.callCount
        let repositoryItemCount = try await itemCount(in: repository)

        XCTAssertEqual(
            event,
            .skipped(.exceedsSizeLimit(actualBytes: 6, limitBytes: 3))
        )
        XCTAssertEqual(classifierCallCount, 0)
        XCTAssertEqual(repositoryItemCount, 0)
    }

    func testAllowedCaptureIsClassifiedBeforeRepositoryCommit() async throws {
        let repository = InMemoryRepository()
        let classifier = SpyTextClassifier(result: .code)
        let pipeline = makePipeline(
            repository: repository,
            classifier: classifier,
            configuration: .standard
        )
        let raw = RawClipboardCapture.fixture(
            "ordinary allowed text",
            at: 42,
            sourceBundleID: "com.example.editor"
        )

        let event = await pipeline.process(raw)

        guard case .persisted(let item) = event else {
            return XCTFail("expected persisted event")
        }
        XCTAssertEqual(item.content, raw.content)
        XCTAssertEqual(item.category, .code)
        XCTAssertEqual(item.createdAt, raw.capturedAt)
        XCTAssertEqual(item.lastCopiedAt, raw.capturedAt)
        let classifierCallCount = await classifier.callCount
        let classifierReceivedTexts = await classifier.receivedTexts
        XCTAssertEqual(classifierCallCount, 1)
        XCTAssertEqual(classifierReceivedTexts, [raw.content])

        let page = try await repository.fetchPage(
            .init(searchText: "", scope: .all, limit: 100, offset: 0)
        )
        XCTAssertEqual(page.items, [item])
        XCTAssertEqual(page.items.first?.category, .code)
    }

    func testUpdatedConfigurationAppliesToSubsequentCaptures() async throws {
        let repository = InMemoryRepository()
        let classifier = SpyTextClassifier(result: .english)
        let pipeline = makePipeline(
            repository: repository,
            classifier: classifier,
            configuration: PrivacyConfiguration(
                excludedBundleIDs: [],
                maxUTF8Bytes: 1_048_576,
                detectsSensitiveContent: false
            )
        )
        let raw = RawClipboardCapture.fixture("-----BEGIN PRIVATE KEY-----\nsecret")

        let first = await pipeline.process(raw)
        guard case .persisted = first else {
            return XCTFail("disabled detection should persist")
        }

        await pipeline.updateConfiguration(.standard)
        let second = await pipeline.process(raw)
        let classifierCallCount = await classifier.callCount
        let repositoryItemCount = try await itemCount(in: repository)

        XCTAssertEqual(second, .skipped(.sensitive(.privateKey)))
        XCTAssertEqual(classifierCallCount, 1)
        XCTAssertEqual(repositoryItemCount, 1)
    }

    func testConfigurationUpdateWaitsBehindStartedCaptureAndPrecedesLaterCapture() async throws {
        let repository = InMemoryRepository()
        let classifier = SuspendingTextClassifier(result: .english)
        let pipeline = CapturePipeline(
            privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
            classifier: classifier,
            repository: repository,
            configuration: PrivacyConfiguration(
                excludedBundleIDs: [],
                maxUTF8Bytes: 1_048_576,
                detectsSensitiveContent: false
            )
        )
        let firstText = "capture before configuration update"
        let firstTask = Task.detached {
            await pipeline.process(.fixture(firstText, at: 1))
        }
        await classifier.waitUntilStarted(firstText)

        let updateAttempted = AsyncTestSignal()
        let updateFinished = AsyncTestSignal()
        let updatedConfiguration = PrivacyConfiguration(
            excludedBundleIDs: ["com.example.excluded"],
            maxUTF8Bytes: 1_048_576,
            detectsSensitiveContent: true
        )
        let updateTask = Task.detached {
            await updateAttempted.signal()
            await pipeline.updateConfiguration(updatedConfiguration)
            await updateFinished.signal()
        }
        await updateAttempted.wait()
        await yieldExecutor()

        let secondFinished = AsyncTestSignal()
        let secondTask = Task.detached {
            let event = await pipeline.process(
                .fixture(
                    "capture after configuration update",
                    at: 2,
                    sourceBundleID: "com.example.excluded"
                )
            )
            await secondFinished.signal()
            return event
        }
        await yieldExecutor()

        let updateCompletedEarly = await updateFinished.isSignalled
        let secondCompletedEarly = await secondFinished.isSignalled
        XCTAssertFalse(updateCompletedEarly)
        XCTAssertFalse(secondCompletedEarly)

        await classifier.release(firstText)
        let firstEvent = await firstTask.value
        await updateTask.value
        let secondEvent = await secondTask.value
        let classifiedTexts = await classifier.startedTexts
        let repositoryItemCount = try await itemCount(in: repository)

        guard case .persisted(let firstItem) = firstEvent else {
            return XCTFail("first capture should persist before the update")
        }
        XCTAssertEqual(firstItem.content, firstText)
        XCTAssertEqual(secondEvent, .skipped(.excludedApplication))
        XCTAssertEqual(classifiedTexts, [firstText])
        XCTAssertEqual(repositoryItemCount, 1)
    }

    func testConfigurationUpdateCannotPassEarlierAdmittedCapture() async throws {
        let repository = InMemoryRepository()
        let classifier = SuspendingTextClassifier(result: .english)
        let admission = CaptureAdmissionProbe()
        let beforeUpdateSource = "com.example.before-update"
        let afterUpdateSource = "com.example.after-update"
        await admission.blockCapture(sourceBundleID: beforeUpdateSource)
        let pipeline = CapturePipeline(
            privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
            classifier: classifier,
            repository: repository,
            configuration: PrivacyConfiguration(
                excludedBundleIDs: [],
                maxUTF8Bytes: 1_048_576,
                detectsSensitiveContent: false
            ),
            admissionObserver: { operation, ticket in
                await admission.observe(operation, ticket: ticket)
            }
        )
        let holderText = "capture holding the pipeline"
        let beforeUpdateText = "capture admitted before configuration update"
        let afterUpdateText = "capture admitted after configuration update"
        let holderTask = Task.detached(priority: .background) {
            await pipeline.process(
                .fixture(
                    holderText,
                    at: 1,
                    sourceBundleID: "com.example.holder"
                )
            )
        }
        await classifier.waitUntilStarted(holderText)

        let beforeUpdateTask = Task.detached(priority: .background) {
            await pipeline.process(
                .fixture(
                    beforeUpdateText,
                    at: 2,
                    sourceBundleID: beforeUpdateSource
                )
            )
        }
        let beforeUpdateTicket = await admission.waitUntilObserved(
            .capture(sourceBundleID: beforeUpdateSource)
        )

        let updateFinished = AsyncTestSignal()
        let updatedConfiguration = PrivacyConfiguration(
            excludedBundleIDs: [beforeUpdateSource, afterUpdateSource],
            maxUTF8Bytes: 1_048_576,
            detectsSensitiveContent: true
        )
        let updateTask = Task.detached(priority: .userInitiated) {
            await pipeline.updateConfiguration(updatedConfiguration)
            await updateFinished.signal()
        }
        let updateTicket = await admission.waitUntilObserved(.configurationUpdate)

        let afterUpdateTask = Task.detached(priority: .userInitiated) {
            await pipeline.process(
                .fixture(
                    afterUpdateText,
                    at: 3,
                    sourceBundleID: afterUpdateSource
                )
            )
        }
        let afterUpdateTicket = await admission.waitUntilObserved(
            .capture(sourceBundleID: afterUpdateSource)
        )

        XCTAssertLessThan(beforeUpdateTicket, updateTicket)
        XCTAssertLessThan(updateTicket, afterUpdateTicket)

        await classifier.release(holderText)
        _ = await holderTask.value
        await yieldExecutor()

        let updateCompletedBeforePriorCapture = await updateFinished.isSignalled
        let beforeUpdateStartedBeforeAdmissionRelease = await classifier.hasStarted(beforeUpdateText)
        XCTAssertFalse(updateCompletedBeforePriorCapture)
        XCTAssertFalse(beforeUpdateStartedBeforeAdmissionRelease)

        await admission.releaseCaptureAdmission(sourceBundleID: beforeUpdateSource)
        await classifier.waitUntilStarted(beforeUpdateText)
        await classifier.release(beforeUpdateText)

        let beforeUpdateEvent = await beforeUpdateTask.value
        await updateTask.value
        let afterUpdateEvent = await afterUpdateTask.value
        let startedTexts = await classifier.startedTexts
        let repositoryItems = try await repository.fetchPage(
            .init(searchText: "", scope: .all, limit: 100, offset: 0)
        ).items

        guard case .persisted(let beforeUpdateItem) = beforeUpdateEvent else {
            return XCTFail("capture admitted before the update should use the old configuration")
        }
        XCTAssertEqual(beforeUpdateItem.content, beforeUpdateText)
        XCTAssertEqual(afterUpdateEvent, .skipped(.excludedApplication))
        XCTAssertEqual(startedTexts, [holderText, beforeUpdateText])
        XCTAssertEqual(repositoryItems.map(\.content), [beforeUpdateText, holderText])
    }

    func testCancelledAdmittedCapturesStillReleasePipelineTickets() async throws {
        let repository = InMemoryRepository()
        let classifier = SuspendingTextClassifier(result: .english)
        let admission = CaptureAdmissionProbe()
        let pipeline = CapturePipeline(
            privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
            classifier: classifier,
            repository: repository,
            configuration: .standard,
            admissionObserver: { operation, ticket in
                await admission.observe(operation, ticket: ticket)
            }
        )
        let ownerText = "cancelled owner capture"
        let queuedText = "cancelled queued capture"
        let followerText = "follower after cancellations"
        let ownerSource = "com.example.cancelled-owner"
        let queuedSource = "com.example.cancelled-queued"
        let followerSource = "com.example.cancellation-follower"

        let ownerTask = Task.detached {
            await pipeline.process(.fixture(ownerText, at: 1, sourceBundleID: ownerSource))
        }
        await classifier.waitUntilStarted(ownerText)
        ownerTask.cancel()

        let queuedTask = Task.detached {
            await pipeline.process(.fixture(queuedText, at: 2, sourceBundleID: queuedSource))
        }
        _ = await admission.waitUntilObserved(.capture(sourceBundleID: queuedSource))
        queuedTask.cancel()

        let followerTask = Task.detached {
            await pipeline.process(.fixture(followerText, at: 3, sourceBundleID: followerSource))
        }
        _ = await admission.waitUntilObserved(.capture(sourceBundleID: followerSource))

        let queuedStartedBeforeOwnerRelease = await classifier.hasStarted(queuedText)
        let followerStartedBeforeOwnerRelease = await classifier.hasStarted(followerText)
        XCTAssertFalse(queuedStartedBeforeOwnerRelease)
        XCTAssertFalse(followerStartedBeforeOwnerRelease)

        await classifier.release(ownerText)
        await classifier.waitUntilStarted(queuedText)
        await classifier.release(queuedText)
        await classifier.waitUntilStarted(followerText)
        await classifier.release(followerText)

        guard case .persisted(let ownerItem) = await ownerTask.value else {
            return XCTFail("cancelled owner should keep non-cancellable admitted semantics")
        }
        guard case .persisted(let queuedItem) = await queuedTask.value else {
            return XCTFail("cancelled queued capture should still release its ticket")
        }
        guard case .persisted(let followerItem) = await followerTask.value else {
            return XCTFail("follower should run after cancelled queued capture releases")
        }

        let startedTexts = await classifier.startedTexts
        let maximumOverlap = await classifier.maximumConcurrentCallCount
        XCTAssertEqual(ownerItem.content, ownerText)
        XCTAssertEqual(queuedItem.content, queuedText)
        XCTAssertEqual(followerItem.content, followerText)
        XCTAssertEqual(startedTexts, [ownerText, queuedText, followerText])
        XCTAssertEqual(maximumOverlap, 1)
    }

    func testConcurrentCapturesDoNotOverlapAndPersistInFIFOInvocationOrder() async throws {
        let repository = InMemoryRepository()
        let classifier = SuspendingTextClassifier(result: .english)
        let pipeline = CapturePipeline(
            privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
            classifier: classifier,
            repository: repository,
            configuration: .standard
        )
        let firstText = "first concurrent capture"
        let secondText = "second concurrent capture"
        let firstTask = Task.detached {
            await pipeline.process(.fixture(firstText, at: 1))
        }
        await classifier.waitUntilStarted(firstText)

        let secondAttempted = AsyncTestSignal()
        let secondTask = Task.detached {
            await secondAttempted.signal()
            return await pipeline.process(.fixture(secondText, at: 2))
        }
        await secondAttempted.wait()
        try await Task.sleep(nanoseconds: 50_000_000)

        let secondStartedEarly = await classifier.hasStarted(secondText)
        let earlyMaximumOverlap = await classifier.maximumConcurrentCallCount
        XCTAssertFalse(secondStartedEarly)
        XCTAssertEqual(earlyMaximumOverlap, 1)

        await repository.setFailNextMutation(true)
        await classifier.release(secondText)
        try await Task.sleep(nanoseconds: 20_000_000)
        await classifier.release(firstText)

        let firstEvent = await firstTask.value
        let secondEvent = await secondTask.value
        let startedTexts = await classifier.startedTexts
        let finishedTexts = await classifier.finishedTexts
        let maximumOverlap = await classifier.maximumConcurrentCallCount

        XCTAssertEqual(firstEvent, .failed(code: .databaseWrite))
        guard case .persisted(let secondItem) = secondEvent else {
            return XCTFail("second capture should persist after the first attempted write")
        }
        XCTAssertEqual(secondItem.content, secondText)
        XCTAssertEqual(startedTexts, [firstText, secondText])
        XCTAssertEqual(finishedTexts, [firstText, secondText])
        XCTAssertEqual(maximumOverlap, 1)

        let page = try await repository.fetchPage(
            .init(searchText: "", scope: .all, limit: 100, offset: 0)
        )
        XCTAssertEqual(page.items.map(\.content), [secondText])
    }

    func testRepositoryFailureEmitsContentFreeDatabaseWriteEvent() async throws {
        let sentinel = "never include this clipboard body in failure"
        let repository = InMemoryRepository()
        await repository.setFailNextMutation(true)
        let classifier = SpyTextClassifier(result: .english)
        let pipeline = makePipeline(
            repository: repository,
            classifier: classifier,
            configuration: .standard
        )

        let event = await pipeline.process(.fixture(sentinel))
        let classifierCallCount = await classifier.callCount
        let repositoryItemCount = try await itemCount(in: repository)

        XCTAssertEqual(event, .failed(code: .databaseWrite))
        XCTAssertFalse(String(describing: event).contains(sentinel))
        XCTAssertEqual(classifierCallCount, 1)
        XCTAssertEqual(repositoryItemCount, 0)
    }

    func testSkippedEventDoesNotContainRejectedBody() async {
        let sentinel = "-----BEGIN PRIVATE KEY-----\nrejected sentinel"
        let pipeline = makePipeline(
            repository: InMemoryRepository(),
            classifier: SpyTextClassifier(result: .english),
            configuration: .standard
        )

        let event = await pipeline.process(.fixture(sentinel))

        XCTAssertEqual(event, .skipped(.sensitive(.privateKey)))
        XCTAssertFalse(String(describing: event).contains(sentinel))
    }

    func testAppErrorCodesHaveStableContentFreeRawValues() {
        let expected: [(AppErrorCode, String)] = [
            (.databaseOpen, "database.open"),
            (.databaseWrite, "database.write"),
            (.databaseCopyMetadata, "database.copyMetadata"),
            (.databaseReadOnly, "database.readOnly"),
            (.migrationFailed, "migration.failed"),
            (.migrationBackupDelete, "migration.backupDelete"),
            (.clipboardRead, "clipboard.read"),
            (.clipboardWrite, "clipboard.write"),
            (.hotkeyRegistration, "hotkey.registration"),
            (.privacyExcluded, "privacy.excluded"),
            (.privacySize, "privacy.size"),
            (.privacySensitive, "privacy.sensitive"),
            (.aiEndpoint, "ai.endpoint"),
            (.aiConsent, "ai.consent"),
            (.aiRequest, "ai.request"),
            (.releaseConfiguration, "release.configuration")
        ]

        XCTAssertEqual(expected.map { $0.0.rawValue }, expected.map { $0.1 })
    }
}

private extension CapturePipelineTests {
    func makePipeline(
        repository: InMemoryRepository,
        classifier: SpyTextClassifier,
        configuration: PrivacyConfiguration
    ) -> CapturePipeline {
        CapturePipeline(
            privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
            classifier: classifier,
            repository: repository,
            configuration: configuration
        )
    }

    func itemCount(in repository: InMemoryRepository) async throws -> Int {
        let page = try await repository.fetchPage(
            .init(searchText: "", scope: .all, limit: 100, offset: 0)
        )
        return page.totalCount
    }

    func yieldExecutor(iterations: Int = 50) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }
}

private actor CaptureAdmissionProbe {
    private var records: [(operation: CapturePipelineAdmissionOperation, ticket: UInt64)] = []
    private var observationWaiters: [CapturePipelineAdmissionOperation: [CheckedContinuation<UInt64, Never>]] = [:]
    private var blockedSourceBundleIDs: Set<String> = []
    private var releaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var releasePermits: Set<String> = []

    func blockCapture(sourceBundleID: String) {
        blockedSourceBundleIDs.insert(sourceBundleID)
    }

    func observe(_ operation: CapturePipelineAdmissionOperation, ticket: UInt64) async {
        records.append((operation, ticket))
        observationWaiters.removeValue(forKey: operation)?.forEach { waiter in
            waiter.resume(returning: ticket)
        }

        guard case .capture(let sourceBundleID?) = operation,
              blockedSourceBundleIDs.contains(sourceBundleID),
              releasePermits.remove(sourceBundleID) == nil
        else {
            return
        }

        await withCheckedContinuation { continuation in
            releaseWaiters[sourceBundleID] = continuation
        }
    }

    func waitUntilObserved(
        _ operation: CapturePipelineAdmissionOperation,
        occurrence: Int = 1
    ) async -> UInt64 {
        let matchingRecords = records.filter { $0.operation == operation }
        if matchingRecords.count >= occurrence {
            return matchingRecords[occurrence - 1].ticket
        }

        return await withCheckedContinuation { continuation in
            observationWaiters[operation, default: []].append(continuation)
        }
    }

    func releaseCaptureAdmission(sourceBundleID: String) {
        if let waiter = releaseWaiters.removeValue(forKey: sourceBundleID) {
            waiter.resume()
        } else {
            releasePermits.insert(sourceBundleID)
        }
    }
}
