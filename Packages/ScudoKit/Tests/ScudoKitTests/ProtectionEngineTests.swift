import Foundation
import os
import Testing
@testable import ScudoKit
import ScudoShared

/// Fake filter server: serves every catalog URL with an ETag and answers
/// `304` to matching `If-None-Match` requests.
final class MockFilterServer: Sendable {
    struct State {
        var bodies: [URL: String] = [:]
        var failing: Set<URL> = []
        var cancelled: Set<URL> = []
        var requests: [URLRequest] = []
    }

    static let current = OSAllocatedUnfairLock<MockFilterServer?>(initialState: nil)
    let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        state.withLock { state in
            for list in FilterCatalog.all {
                state.bodies[list.url] = "! Title: List \(list.id)\n! Version: 1\n||ads\(list.id).example^\n##.ad-\(list.id)\n"
            }
        }
    }

    func setBody(_ body: String, for id: Int) {
        state.withLock { $0.bodies[FilterCatalog.list(id: id)!.url] = body }
    }

    func setFailing(_ failing: Bool, id: Int) {
        let url = FilterCatalog.list(id: id)!.url
        state.withLock { state in
            if failing {
                state.failing.insert(url)
            } else {
                state.failing.remove(url)
            }
        }
    }

    func setCancelled(_ cancelled: Bool, id: Int) {
        let url = FilterCatalog.list(id: id)!.url
        state.withLock { state in
            if cancelled {
                state.cancelled.insert(url)
            } else {
                state.cancelled.remove(url)
            }
        }
    }

    func isCancelled(_ url: URL) -> Bool {
        state.withLock { $0.cancelled.contains(url) }
    }

    var requestCount: Int { state.withLock { $0.requests.count } }

    func respond(to request: URLRequest) -> (status: Int, headers: [String: String], body: Data) {
        state.withLock { state in
            state.requests.append(request)
            guard let url = request.url, !state.failing.contains(url) else {
                return (500, [:], Data())
            }
            guard let body = state.bodies[url] else { return (404, [:], Data()) }
            let etag = "\"\(ProtectionEngine.sha256(Data(body.utf8)).prefix(16))\""
            if request.value(forHTTPHeaderField: "If-None-Match") == etag {
                return (304, ["ETag": etag], Data())
            }
            return (200, ["ETag": etag, "Content-Type": "text/plain"], Data(body.utf8))
        }
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = MockFilterServer.current.withLock({ $0 }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if server.isCancelled(url) {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let reply = server.respond(to: request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Records reload requests and answers with a configurable outcome.
final class ReloadRecorder: Sendable {
    enum Mode: Sendable { case succeed, fail, disabled }
    private let state = OSAllocatedUnfairLock(initialState: (mode: Mode.succeed, calls: [BlockerKind]()))

    var mode: Mode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue } }
    }

    var calls: [BlockerKind] { state.withLock { $0.calls } }

    func reset() { state.withLock { $0.calls = [] } }

    var reloader: BlockerReloader {
        { [self] kind in
            let mode = state.withLock { state -> Mode in
                state.calls.append(kind)
                return state.mode
            }
            switch mode {
            case .succeed: return .reloaded
            case .disabled: return .extensionDisabled
            case .fail: throw URLError(.cannotLoadFromNetwork)
            }
        }
    }
}

@Suite("Protection engine", .serialized)
struct ProtectionEngineTests {
    let server: MockFilterServer
    let recorder = ReloadRecorder()
    let store: ScudoStore
    let engine: ProtectionEngine

    init() throws {
        let server = MockFilterServer()
        self.server = server
        MockFilterServer.current.withLock { $0 = server }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let root = FileManager.default.temporaryDirectory.appending(path: "ScudoTests-\(UUID().uuidString)")
        store = ScudoStore(root: root)
        engine = ProtectionEngine(store: store, session: URLSession(configuration: configuration), reloader: recorder.reloader)
    }

    private func rulesJSON(_ kind: BlockerKind) throws -> String {
        String(decoding: try Data(contentsOf: store.rulesURL(for: kind)), as: UTF8.self)
    }

    @Test func firstUpdateDownloadsConvertsAndReloadsEverything() async throws {
        let summary = await engine.update()
        let enabled = FilterCatalog.defaultEnabledIDs

        #expect(!summary.hasErrors)
        #expect(Set(summary.changedFilterIDs) == enabled)
        #expect(summary.rebuiltBlockers == BlockerKind.allCases)
        #expect(Set(recorder.calls) == Set(BlockerKind.allCases))

        let state = store.loadState()
        #expect(state.lastUpdateAt != nil)
        for kind in BlockerKind.allCases {
            let record = state[blocker: kind]
            #expect(!record.needsReload)
            // One block rule per list, plus one rule grouping all the generic
            // `##.ad-N` selectors (the converter merges them).
            #expect(record.safariRuleCount == ScudoSettings.defaults.enabledLists(for: kind).count + 1)
            let json = try rulesJSON(kind)
            for list in ScudoSettings.defaults.enabledLists(for: kind) {
                #expect(json.contains("ads\(list.id)"))
            }
        }
        // Disabled lists are neither downloaded nor included.
        #expect(!(try rulesJSON(.ads)).contains("ads101"))
        #expect(state[filter: 2].title == "List 2")
    }

    @Test func unchangedListsAreRevalidatedButNotRebuilt() async throws {
        _ = await engine.update()
        recorder.reset()
        let before = server.requestCount

        let summary = await engine.update()

        #expect(server.requestCount - before == FilterCatalog.defaultEnabledIDs.count)
        #expect(summary.changedFilterIDs.isEmpty)
        #expect(summary.rebuiltBlockers.isEmpty)
        #expect(recorder.calls.isEmpty)
    }

    @Test func onlyTheBlockerOfAChangedListIsRebuilt() async throws {
        _ = await engine.update()
        recorder.reset()
        server.setBody("! Title: List 26\n||nuovo-annuncio.example^\n", for: 26)

        let summary = await engine.update()

        #expect(summary.changedFilterIDs == [26])
        #expect(summary.rebuiltBlockers == [.ads])
        #expect(recorder.calls == [.ads])
        #expect(try rulesJSON(.ads).contains("nuovo-annuncio"))
    }

    @Test func allowlistChangesReuseTheConvertedRules() async throws {
        _ = await engine.update()
        let convertedAt = store.loadState()[blocker: .privacy].convertedAt
        recorder.reset()
        let before = server.requestCount

        var settings = await engine.settings()
        settings.allowlist = ["example.it"]
        try await engine.save(settings)
        let summary = await engine.update(skipDownload: true)

        #expect(server.requestCount == before)
        #expect(summary.rebuiltBlockers == BlockerKind.allCases)
        #expect(Set(recorder.calls) == Set(BlockerKind.allCases))
        let state = store.loadState()
        #expect(state[blocker: .privacy].convertedAt == convertedAt)
        for kind in BlockerKind.allCases {
            let json = try rulesJSON(kind)
            #expect(json.contains("example.it"))
            #expect(json.contains("ignore-previous-rules"))
            #expect(state[blocker: kind].safariRuleCount == state[blocker: kind].baseSafariRuleCount + 1)
        }
    }

    @Test func customRulesReachTheRightBlockers() async throws {
        var settings = await engine.settings()
        settings.customRules = "||mio-tracker.example^\n@@||cdn-utile.example^"
        try await engine.save(settings)
        _ = await engine.update()

        #expect(try rulesJSON(.security).contains("mio-tracker"))
        #expect(!(try rulesJSON(.ads)).contains("mio-tracker"))
        for kind in BlockerKind.allCases {
            #expect(try rulesJSON(kind).contains("cdn-utile"))
        }
    }

    @Test func failedDownloadKeepsTheCachedCopy() async throws {
        _ = await engine.update()
        server.setBody("! Title: List 3\n||cambiato.example^\n", for: 3)
        server.setFailing(true, id: 3)

        let summary = await engine.update()

        #expect(summary.failedFilters.keys.sorted() == [3])
        #expect(summary.rebuiltBlockers.isEmpty)
        #expect(try rulesJSON(.privacy).contains("ads3"))
        #expect(store.loadState()[filter: 3].lastError != nil)
    }

    @Test func neverDownloadedListIsReportedAsMissing() async throws {
        // EasyList Italy (109) is one of the default lists of the Ads blocker.
        server.setFailing(true, id: 109)
        let summary = await engine.update()

        #expect(summary.failedFilters.keys.sorted() == [109])
        let record = store.loadState()[blocker: .ads]
        #expect(record.missingFilterIDs == [109])
        #expect(record.includedFilterIDs == [2, 11, 26])

        server.setFailing(false, id: 109)
        let retry = await engine.update()
        #expect(retry.rebuiltBlockers == [.ads])
        #expect(store.loadState()[blocker: .ads].missingFilterIDs.isEmpty)
    }

    @Test func failedReloadIsRetriedLater() async throws {
        recorder.mode = .fail
        let summary = await engine.update()
        #expect(Set(summary.blockerErrors.keys) == Set(BlockerKind.allCases))
        #expect(store.loadState()[blocker: .ads].needsReload)

        recorder.mode = .succeed
        recorder.reset()
        _ = await engine.reloadPending()
        #expect(Set(recorder.calls) == Set(BlockerKind.allCases))
        #expect(!store.loadState()[blocker: .ads].needsReload)
        #expect(store.loadState()[blocker: .ads].reloadError == nil)
    }

    @Test func switchedOffExtensionsAreNotRetriedButCanBeReloadedOnDemand() async throws {
        recorder.mode = .disabled
        let summary = await engine.update()
        #expect(!summary.hasErrors)
        #expect(!store.loadState()[blocker: .ads].needsReload)

        // Nothing pending: coming back to the app does not reload again…
        recorder.reset()
        _ = await engine.reloadPending()
        #expect(recorder.calls.isEmpty)

        // …until the app sees the user switch an extension on.
        recorder.mode = .succeed
        _ = await engine.reload([.ads, .privacy])
        #expect(recorder.calls == [.ads, .privacy])
        #expect(store.loadState()[blocker: .ads].reloadedAt != nil)
    }

    @Test func cancelledUpdateRecordsNoErrors() async throws {
        _ = await engine.update()
        recorder.reset()
        server.setBody("! Title: List 2\n||cambiato.example^\n", for: 2)

        // As when iOS ends a background task.
        let engine = self.engine
        let task = Task { await engine.update() }
        task.cancel()
        let summary = await task.value

        #expect(summary.wasCancelled)
        #expect(summary.failedFilters.isEmpty)
        #expect(summary.rebuiltBlockers.isEmpty)
        #expect(recorder.calls.isEmpty)
        #expect(store.loadState()[filter: 2].lastError == nil)
        #expect(!(try rulesJSON(.ads)).contains("cambiato"))

        // The next update completes the work.
        let next = await engine.update()
        #expect(!next.wasCancelled)
        #expect(try rulesJSON(.ads).contains("cambiato"))
    }

    @Test func cancelledRequestWithoutCancelledTaskIsAnOrdinaryError() async throws {
        server.setCancelled(true, id: 2)
        let summary = await engine.update()

        #expect(!summary.wasCancelled)
        #expect(summary.failedFilters.keys.sorted() == [2])
        #expect(summary.rebuiltBlockers == BlockerKind.allCases)
        #expect(store.loadState()[blocker: .ads].missingFilterIDs == [2])
    }

    @Test func missingListsAreTrackedEvenWithoutRebuild() async throws {
        _ = await engine.update()

        // A newly enabled list that cannot be downloaded: reported as missing.
        server.setFailing(true, id: 101)
        var settings = await engine.settings()
        settings.enabledFilterIDs.insert(101)
        try await engine.save(settings)
        let summary = await engine.update()
        #expect(summary.rebuiltBlockers.isEmpty)
        #expect(store.loadState()[blocker: .ads].missingFilterIDs == [101])

        // Switching it off clears the warning.
        settings.enabledFilterIDs.remove(101)
        try await engine.save(settings)
        _ = await engine.update()
        #expect(store.loadState()[blocker: .ads].missingFilterIDs.isEmpty)
    }

    @Test func concurrentUpdatesAreSerialized() async throws {
        async let first = engine.update()
        async let second = engine.update()
        let summaries = await [first, second]
        // One of the two did the work, the other found everything up to date.
        #expect(summaries.map(\.rebuiltBlockers.count).sorted() == [0, BlockerKind.allCases.count])
    }
}
