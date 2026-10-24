import Foundation

var checks = 0
func check(_ condition: Bool, _ label: String) {
    guard condition else { print("NETWORK_TEST_FAILED: \(label)"); exit(1) }
    checks += 1
}
@discardableResult
func pump(_ done: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    return done()
}

struct Reply {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    var delay: TimeInterval = 0
    var redirect: URL?
}

// Intercepts every request in the test session. No real network or user data.
final class StubProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: (URLRequest) -> Reply = { _ in Reply() }
    static var requests: [URLRequest] = []
    static var chunkCount = 0
    private let stateLock = NSLock()
    private var stopped = false

    static func configure(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        requests = []
        chunkCount = 0
    }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    static var deliveredChunks: Int { lock.lock(); defer { lock.unlock() }; return chunkCount }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.handler(request)
        Self.lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + reply.delay) { [weak self] in
            guard let self, self.active else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            if let url = reply.redirect {
                self.client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.deliver(reply.chunks, index: 0)
        }
    }
    private var active: Bool { stateLock.lock(); defer { stateLock.unlock() }; return !stopped }
    private func deliver(_ chunks: [Data], index: Int) {
        guard active else { return }
        guard index < chunks.count else { client?.urlProtocolDidFinishLoading(self); return }
        Self.lock.lock(); Self.chunkCount += 1; Self.lock.unlock()
        client?.urlProtocol(self, didLoad: chunks[index])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in self?.deliver(chunks, index: index + 1) }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [StubProtocol.self]
let client = ResetHTTPClient(configuration: configuration)
let endpoint = URL(string: "https://aihot.news/api/site/codex-reset/version")!
func request(_ reply: Reply, url: URL? = nil) -> Result<Data, Error> {
    StubProtocol.configure { _ in reply }
    var result: Result<Data, Error>?
    var calls = 0
    client.load(url ?? endpoint) { result = $0; calls += 1 }
    check(pump { result != nil }, "request completes status=\(reply.status) chunks=\(reply.chunks.count) requests=\(StubProtocol.count) delivered=\(StubProtocol.deliveredChunks)")
    _ = pump({ false }, timeout: 0.02)
    check(calls == 1, "each request completes exactly once")
    return result!
}
func failed(_ result: Result<Data, Error>) -> Bool { if case .failure = result { return true }; return false }

check((try? request(Reply(chunks: [Data("{}".utf8)])).get()) == Data("{}".utf8), "valid response accepted")
check(failed(request(Reply(headers: ["Content-Length": "1000001"]))), "oversized declared response rejected")
check(failed(request(Reply(chunks: Array(repeating: Data(repeating: 1, count: 60_000), count: 50)))), "chunked oversized body rejected")
check(StubProtocol.deliveredChunks < 50, "oversized stream stops before the entire body downloads")
check(failed(request(Reply(status: 503))), "HTTP error rejected")
check(failed(request(Reply(status: 302, headers: ["Location": "https://evil.invalid/"], redirect: URL(string: "https://evil.invalid/")!))), "redirect rejected")
check(StubProtocol.count == 1, "redirect never reaches another host")
check(failed(request(Reply(), url: URL(string: "https://aihot.news.evil.invalid/api/site/codex-reset/version")!)), "lookalike host rejected")
check(StubProtocol.count == 0, "invalid endpoint never opens a request")

StubProtocol.configure { _ in Reply(chunks: [Data("{}".utf8)], delay: 0.1) }
var cancelled = 0
client.load(endpoint) { if failed($0) { cancelled += 1 } }
client.cancel()
check(cancelled == 1, "cancel completes outstanding request once")
check((try? request(Reply(chunks: [Data("restart".utf8)])).get()) == Data("restart".utf8), "client can restart after cancel")
_ = pump({ false }, timeout: 0.15)
check(cancelled == 1, "old session completion cannot fire again")
client.cancel()

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("codex-helper-network-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/ResetNotices")
let versionData = Data(#"{"version":"2b50cc98c4864768","today":"2026-10-23","checkedAt":"2026-10-23T22:00:00+08:00"}"#.utf8)
var clock = ResetDates.parse("2026-10-23T22:00:00+08:00")!
func configureFixtureServer(delay: TimeInterval = 0) {
    StubProtocol.configure { request in
        let data = request.url?.lastPathComponent == "version" ? versionData : try! Data(contentsOf: fixtures.appendingPathComponent(request.url!.lastPathComponent + ".json"))
        return Reply(chunks: [data], delay: delay)
    }
}

configureFixtureServer(delay: 0.05)
let cancelledCache = temporary.appendingPathComponent("cancelled.json")
let service = ResetNoticeService(cacheURL: cancelledCache, enableSystemNotifications: false, configuration: configuration, now: { clock })
service.refresh()
service.stop()
_ = pump({ false }, timeout: 0.1)
check(!service.isRefreshing && service.notices.isEmpty, "late response cannot resurrect stopped service")
check(!FileManager.default.fileExists(atPath: cancelledCache.path), "stop prevents late cache writes")

configureFixtureServer()
service.start()
service.refresh()
check(pump { service.fetchedAt != nil && !service.isRefreshing }, "stopped service restarts with a fresh session")
check(service.notices.count == 4 && service.unreadCount == 1, "restart yields history and one initial alert")
check(StubProtocol.count == 8, "overlapping refreshes coalesce into one version request and seven days")
service.stop()

// Simulate a pre-canonicalization cache with an already delivered alert.
var legacyCache = try JSONSerialization.jsonObject(with: Data(contentsOf: cancelledCache)) as! [String: Any]
legacyCache.removeValue(forKey: "fingerprintVersion")
legacyCache["unreadIDs"] = [String]()
legacyCache["pendingIDs"] = [String]()
try JSONSerialization.data(withJSONObject: legacyCache).write(to: cancelledCache)
configureFixtureServer()
let migrated = ResetNoticeService(cacheURL: cancelledCache, enableSystemNotifications: false, configuration: configuration, now: { clock })
migrated.refresh()
check(pump { !migrated.isRefreshing }, "legacy cache migrates")
check(migrated.unreadCount == 0 && migrated.notices.count == 4, "upgrade never re-announces cached historical notices")
check(StubProtocol.count == 8, "migration revalidates unchanged API version once")
migrated.stop()

StubProtocol.configure { _ in Reply(status: 503) }
let offline = ResetNoticeService(cacheURL: cancelledCache, enableSystemNotifications: false, configuration: configuration, now: { clock })
offline.refresh()
check(pump { !offline.isRefreshing }, "offline refresh ends")
check(offline.lastError != nil && offline.notices.count == 4, "network failure preserves cached notices")
offline.stop()

configureFixtureServer(delay: 0.04)
let crossingCache = temporary.appendingPathComponent("midnight.json")
let crossing = ResetNoticeService(cacheURL: crossingCache, enableSystemNotifications: false, configuration: configuration, now: { clock })
crossing.refresh()
check(pump { StubProtocol.count == 8 }, "midnight test starts all day requests")
clock = ResetDates.parse("2026-10-24T00:00:01+08:00")!
check(pump { !crossing.isRefreshing }, "midnight refresh ends")
check(crossing.lastError != nil && !FileManager.default.fileExists(atPath: crossingCache.path), "cross-day snapshot cannot commit stale initial alerts")
crossing.stop()
print("NETWORK_TESTS_OK cases=\(checks)")
