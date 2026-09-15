// SwordRenderOperationTests.swift -- Coherent option and native-read transaction coverage

import Foundation
import XCTest
@testable import SwordKit

/** Verifies reader preparation can own one indivisible SWORD option-and-capture boundary. */
final class SwordRenderOperationTests: XCTestCase {
    /**
     Proves a render operation applies its immutable settings before nested reads execute.

     - Side effects: Creates and removes one empty temporary SWORD root and temporarily changes two
       options on its isolated manager.
     - Failure meaning: Reader source capture can observe a different option snapshot than the one
       attached to its immutable request.
     */
    func testRenderOperationAppliesSettingsBeforeNestedManagerReads() throws {
        let fixture = try makeManager()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let observed = fixture.manager.performRenderOperation(settings: [
            .init(.morphology, enabled: true),
            .init(.footnotes, enabled: false),
        ]) {
            (
                fixture.manager.isGlobalOptionEnabled(.morphology),
                fixture.manager.isGlobalOptionEnabled(.footnotes)
            )
        }

        XCTAssertTrue(observed.0)
        XCTAssertFalse(observed.1)
    }

    /**
     Proves a second native caller cannot enter while a render capture owns the runtime lease.

     The second worker signals immediately before requesting the transaction, removing scheduler
     ambiguity from the blocked-entry assertion. The first operation is released only after the
     second has demonstrably attempted entry.

     - Side effects: Creates/removes one empty temporary SWORD root and blocks two test worker queues
       at controlled semaphores for a bounded interval.
     - Failure meaning: Another pane can change global options while the first pane captures source
       content, allowing one request to publish bytes rendered under another pane's configuration.
     */
    func testRenderOperationExcludesCompetingNativeCallUntilCaptureReturns() throws {
        let fixture = try makeManager()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondAttempted = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()

        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            fixture.manager.performRenderOperation(settings: [
                .init(.morphology, enabled: true)
            ]) {
                firstEntered.signal()
                XCTAssertEqual(releaseFirst.wait(timeout: .now() + 2), .success)
                XCTAssertTrue(fixture.manager.isGlobalOptionEnabled(.morphology))
            }
            finished.leave()
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)

        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            secondAttempted.signal()
            fixture.manager.performRenderOperation(settings: [
                .init(.morphology, enabled: false)
            ]) {
                secondEntered.signal()
            }
            finished.leave()
        }
        XCTAssertEqual(secondAttempted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.05), .timedOut)

        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(fixture.manager.isGlobalOptionEnabled(.morphology))
    }

    /** Nested source reads retain their outer lease even when an exclusive writer is queued. */
    func testNestedRenderOperationDoesNotDeadlockBehindQueuedWriter() throws {
        let fixture = try makeManager()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = ModuleStoreMutationCoordinator.shared(forModuleRoot: fixture.root)
        let writerFinished = DispatchSemaphore(value: 0)

        fixture.manager.performRenderOperation(settings: []) {
            DispatchQueue.global(qos: .userInitiated).async {
                defer { writerFinished.signal() }
                _ = try? coordinator.withExclusiveTransaction(
                    kind: .uninstall,
                    prepare: { () },
                    commit: { _ in () }
                )
            }

            let deadline = Date(timeIntervalSinceNow: 2)
            while !coordinator.hasQueuedExclusiveTransaction, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            XCTAssertTrue(coordinator.hasQueuedExclusiveTransaction)

            let nestedValue = fixture.manager.performRenderOperation(settings: []) { "nested" }
            XCTAssertEqual(nestedValue, "nested")
            XCTAssertEqual(writerFinished.wait(timeout: .now() + 0.05), .timedOut)
        }

        XCTAssertEqual(writerFinished.wait(timeout: .now() + 2), .success)
    }

    /** Creates an isolated manager without performing any module reads. */
    private func makeManager() throws -> (root: URL, manager: SwordManager) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwordRenderOperationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let manager = SwordManager(modulePath: root.path) else {
            try? FileManager.default.removeItem(at: root)
            throw SwordRenderOperationTestFailure.managerUnavailable
        }
        return (root, manager)
    }
}

/** Local construction error that keeps fixture failure distinct from behavioral assertions. */
private enum SwordRenderOperationTestFailure: Error {
    case managerUnavailable
}
