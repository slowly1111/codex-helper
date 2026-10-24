import AppKit
import CryptoKit
import Foundation
import UserNotifications

enum ResetDates {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func recentDays(now: Date = Date()) -> [String] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: now).map(day) }
    }

    static func parse(_ value: String?) -> Date? {
        guard let value, value.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    static func validDay(_ day: String) -> Bool {
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = parse(day + "T00:00:00+08:00") else { return false }
        return self.day(date) == day
    }
}

func resetDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func safeResetOriginalURL(_ value: String?) -> URL? {
    guard let value, value.count < 512, let url = URL(string: value),
          url.scheme == "https", let host = url.host?.lowercased(),
          ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host),
          url.user == nil, url.password == nil, url.port == nil,
          url.query == nil, url.fragment == nil,
          url.path.range(of: #"^/(?:i|[A-Za-z0-9_]+)/status/[0-9]+$"#, options: .regularExpression) != nil else { return nil }
    return url
}

enum ResetNoticeStatus: String, Codable {
    case announced, confirmed, likely_completed, expired_unconfirmed, in_progress, unverified

    func label(chinese: Bool) -> String {
        switch self {
        case .announced: return chinese ? "已预告，等待生效" : "Announced; pending"
        case .confirmed: return chinese ? "来源称已确认" : "Source reports confirmation"
        case .likely_completed: return chinese ? "预计已生效，尚未确认" : "Estimated; unconfirmed"
        case .expired_unconfirmed: return chinese ? "预计时间已过，等待确认" : "Overdue; unconfirmed"
        case .in_progress: return chinese ? "来源称正在发放" : "Source reports rollout"
        case .unverified: return chinese ? "状态待核实" : "Unverified"
        }
    }
}

struct ResetNotice: Codable, Equatable, Identifiable {
    let id: String
    let day: String
    let kind: String
    let title: String
    let status: ResetNoticeStatus
    let scope: String
    let window: String?
    let confirmationTime: String?
    let revisionDate: Date
    let originalURL: String?
    let sourceRevision: String

    var sourceURL: URL {
        guard ResetDates.validDay(day) else { return URL(string: "https://aihot.news/codex-reset")! }
        return URL(string: "https://aihot.news/codex-reset/history/" + day)!
    }

    var originalLink: URL? { safeResetOriginalURL(originalURL) }

    var presentationFingerprint: String {
        let values = [id, day, kind, title, status.rawValue, scope, window ?? "", confirmationTime ?? ""]
        return resetDigest(String(data: (try? JSONEncoder().encode(values)) ?? Data(), encoding: .utf8) ?? "")
    }

    func timeDescription(chinese: Bool) -> String {
        if let window { return window + (chinese ? "（北京时间）" : " (Beijing time)") }
        if let confirmationTime {
            return chinese ? "来源确认帖：\(confirmationTime)（北京时间）" : "Source confirmation: \(confirmationTime) (Beijing time)"
        }
        return chinese ? "具体时间尚未公布" : "Exact time not announced"
    }

    var fingerprint: String {
        let values = [id, day, kind, title, status.rawValue, scope, window ?? "", confirmationTime ?? "", originalURL ?? "", sourceRevision]
        let encoded = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
}

struct ResetVersionResponse: Decodable {
    let version: String
    let checkedAt: String
    let today: String
}

private struct ResetAPIWindow: Decodable {
    let from: String?
    let through: String?
    let basis: String?
}

private struct ResetAPIPresentation: Decodable {
    let status: String?
    let scopeKnown: Bool?
    let audienceZh: String?
    let scopeLabel: String?
}

private struct ResetAPIPost: Decodable {
    let id: String
    let url: String?
    let text: String?
}

private struct ResetAPIEvent: Decodable {
    let id: String
    let type: String
    let status: String
    let displayLabel: String?
    let createdAt: String?
    let updatedAt: String?
    let confirmedAt: String?
    let presentation: ResetAPIPresentation?
    let estimate: ResetAPIWindow?
    let schedule: ResetAPIWindow?
    let posts: [ResetAPIPost]?
}

private struct ResetDayResponse: Decodable {
    let date: String
    let version: String
    let events: [ResetAPIEvent]
}

enum ResetSyncError: Error {
    case invalidData
}

func parseResetDay(_ data: Data, expectedDay: String, expectedVersion: String) throws -> [ResetNotice] {
    guard data.count <= 1_000_000, ResetDates.validDay(expectedDay) else { throw ResetSyncError.invalidData }
    let response = try JSONDecoder().decode(ResetDayResponse.self, from: data)
    guard response.date == expectedDay, response.version == expectedVersion,
          response.events.count <= 100 else { throw ResetSyncError.invalidData }
    var identifiers = Set<String>()
    return try response.events.compactMap { event in
        guard ["direct_reset", "reset_credit"].contains(event.type) else { return nil }
        guard !event.id.isEmpty, event.id.count <= 256, identifiers.insert(event.id).inserted, (event.posts?.count ?? 0) <= 100,
              let revision = ResetDates.parse(event.updatedAt) ?? ResetDates.parse(event.confirmedAt) ?? ResetDates.parse(event.createdAt) else {
            throw ResetSyncError.invalidData
        }
        let status = ResetNoticeStatus(rawValue: event.presentation?.status ?? event.status) ?? .unverified
        let title = event.type == "reset_credit" ? "重置卡发放" : String((event.displayLabel ?? "额度重置消息").prefix(80))
        let scope: String
        if event.presentation?.scopeKnown == true {
            scope = String((event.presentation?.audienceZh ?? event.presentation?.scopeLabel ?? "适用范围未明确").prefix(160))
        } else {
            scope = "适用范围未明确"
        }
        let window = event.estimate ?? event.schedule
        var windowText: String?
        if status != .confirmed, let start = ResetDates.parse(window?.from) {
            let end = ResetDates.parse(window?.through)
            if let end, end < start { throw ResetSyncError.invalidData }
            let prefix = event.estimate != nil ? "网站推算：" : "预计："
            windowText = prefix + ResetDates.time(start)
            if let end, end != start { windowText! += " 至 " + ResetDates.time(end) }
        }
        let originalURL = event.posts?.compactMap { safeResetOriginalURL($0.url)?.absoluteString }.sorted().first
        let postContent = (event.posts ?? []).map { [$0.id, String(($0.text ?? "").prefix(1000))] }
            .sorted { $0.lexicographicallyPrecedes($1) }
        let revisionData = (try? JSONEncoder().encode(postContent)) ?? Data()
        let sourceRevision = SHA256.hash(data: revisionData).map { String(format: "%02x", $0) }.joined()
        return ResetNotice(
            id: event.id, day: expectedDay, kind: event.type, title: title, status: status,
            scope: scope, window: windowText,
            confirmationTime: ResetDates.parse(event.confirmedAt).map(ResetDates.time),
            revisionDate: revision, originalURL: originalURL, sourceRevision: sourceRevision
        )
    }
}

func mergeResetNotices(_ values: [ResetNotice], days: [String]) -> [ResetNotice] {
    var merged: [String: ResetNotice] = [:]
    for notice in values where days.contains(notice.day) {
        if let previous = merged[notice.id] {
            if previous.revisionDate > notice.revisionDate { continue }
            if previous.revisionDate == notice.revisionDate, previous.fingerprint >= notice.fingerprint { continue }
        }
        merged[notice.id] = notice
    }
    return merged.values.sorted {
        if $0.revisionDate != $1.revisionDate { return $0.revisionDate > $1.revisionDate }
        return $0.id < $1.id
    }
}

func changedResetNotices(_ notices: [ResetNotice], previous: [String: String]?, today: String, legacyNotices: [ResetNotice]? = nil) -> [ResetNotice] {
    guard let previous else { return Array(notices.filter { $0.day == today }.prefix(1)) }
    if let legacyNotices {
        var old: [String: String] = [:]
        for notice in legacyNotices { old[notice.id] = notice.presentationFingerprint }
        return notices.filter { old[$0.id] != $0.presentationFingerprint }
    }
    return notices.filter { previous[$0.id] != $0.fingerprint }
}

private struct ResetSnapshot: Codable {
    var version: String
    var days: [String]
    var fetchedAt: Date
    var checkedAt: Date
    var notices: [ResetNotice]
}

private struct ResetCache: Codable {
    // Optional for old cache files. Canonical post ordering starts at version 2.
    var fingerprintVersion: Int?
    var snapshot: ResetSnapshot?
    var fingerprints: [String: String] = [:]
    var unreadIDs: Set<String> = []
    var pendingIDs: Set<String> = []
    var notifiedKeys: Set<String> = []
}

// Delegate callbacks run on the main queue, as do the service's state changes.
// Apply the limit while receiving bytes, including chunked/decompressed bodies.
final class ResetHTTPClient: NSObject, URLSessionDataDelegate {
    static let maximumBytes = 1_000_000
    private struct Pending {
        var data = Data()
        let completion: (Result<Data, Error>) -> Void
    }
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var pending: [Int: Pending] = [:]

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.configuration.urlCache = nil
        self.configuration.httpCookieStorage = nil
        self.configuration.urlCredentialStorage = nil
        self.configuration.httpShouldSetCookies = false
        self.configuration.timeoutIntervalForRequest = 20
        self.configuration.timeoutIntervalForResource = 30
    }

    func load(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        guard url.scheme == "https", url.host == "aihot.news", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              url.path == "/api/site/codex-reset/version" ||
                (url.path.hasPrefix("/api/site/codex-reset/days/") && ResetDates.validDay(String(url.path.dropFirst("/api/site/codex-reset/days/".count)))) else {
            completion(.failure(ResetSyncError.invalidData))
            return
        }
        if session == nil { session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Helper-Reset-Monitor/0.8.5", forHTTPHeaderField: "User-Agent")
        guard let task = session?.dataTask(with: request) else { return }
        pending[task.taskIdentifier] = Pending(completion: completion)
        task.resume()
    }

    func cancel() {
        let completions = pending.values.map(\.completion)
        pending.removeAll()
        let previous = session
        session = nil
        previous?.invalidateAndCancel()
        completions.forEach { $0(.failure(URLError(.cancelled))) }
    }

    private func finish(_ task: URLSessionTask, _ result: Result<Data, Error>) {
        pending.removeValue(forKey: task.taskIdentifier)?.completion(result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard session === self.session, pending[dataTask.taskIdentifier] != nil else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == dataTask.originalRequest?.url,
              response.expectedContentLength <= Int64(Self.maximumBytes) else {
            completionHandler(.cancel)
            finish(dataTask, .failure(ResetSyncError.invalidData))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session, let currentBytes = pending[dataTask.taskIdentifier]?.data.count else { return }
        guard data.count <= Self.maximumBytes - currentBytes else {
            dataTask.cancel()
            finish(dataTask, .failure(ResetSyncError.invalidData))
            return
        }
        pending[dataTask.taskIdentifier]?.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session, let current = pending[task.taskIdentifier] else { return }
        finish(task, error.map { .failure($0) } ?? .success(current.data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // API endpoints are fixed; do not follow a redirect to a different resource.
        completionHandler(nil)
        guard session === self.session else { return }
        task.cancel()
        finish(task, .failure(ResetSyncError.invalidData))
    }
}

final class ResetNoticeService: NSObject, UNUserNotificationCenterDelegate {
    var onChange: (() -> Void)?
    var onOpen: (() -> Void)?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var notificationsAllowed = false
    private(set) var lastNotificationError: String?
    private let cacheURL: URL
    private let center: UNUserNotificationCenter?
    private var cache = ResetCache()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var sendingNotification = false
    private let httpClient: ResetHTTPClient
    private let now: () -> Date
    private var generation = 0
    private var stopped = false

    init(cacheURL: URL, enableSystemNotifications: Bool = true, configuration: URLSessionConfiguration = .ephemeral, now: @escaping () -> Date = Date.init) {
        self.cacheURL = cacheURL
        self.httpClient = ResetHTTPClient(configuration: configuration)
        self.now = now
        center = enableSystemNotifications ? UNUserNotificationCenter.current() : nil
        super.init()
        if let file = try? FileHandle(forReadingFrom: cacheURL) {
            defer { try? file.close() }
            if let data = try? file.read(upToCount: 2_000_000), data.count < 2_000_000,
               let saved = try? JSONDecoder().decode(ResetCache.self, from: data) { cache = saved }
        }
        center?.delegate = self
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        httpClient.cancel()
    }

    var notices: [ResetNotice] {
        mergeResetNotices(cache.snapshot?.notices ?? [], days: ResetDates.recentDays(now: now()))
    }

    var unreadCount: Int { notices.filter { cache.unreadIDs.contains($0.id) }.count }
    var fetchedAt: Date? { cache.snapshot?.fetchedAt }

    func statusText(chinese: Bool) -> String {
        if isRefreshing { return chinese ? "正在同步重置消息…" : "Syncing reset notices…" }
        if lastError != nil {
            return chinese ? "暂时无法同步，保留已同步消息；稍后自动重试。" : "Sync unavailable; keeping cached notices."
        }
        guard let snapshot = cache.snapshot else { return chinese ? "等待首次同步" : "Waiting for first sync" }
        let stale = now().timeIntervalSince(snapshot.checkedAt) > 30 * 60
        let suffix = stale ? (chinese ? " · 源站检查已超过 30 分钟" : " · Source check is over 30 minutes old") : ""
        return (chinese ? "每 10 分钟同步 · 更新于 " : "Checks every 10 minutes · Updated ") + ResetDates.time(snapshot.fetchedAt) + suffix
    }

    func start() {
        guard timer == nil else { return }
        stopped = false
        refreshNotificationPermission(requestIfNeeded: true)
        let timer = Timer(timeInterval: 10 * 60, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        stopped = true
        sendingNotification = false
        generation += 1
        isRefreshing = false
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        httpClient.cancel()
    }

    func markRead() {
        cache.unreadIDs.removeAll()
        _ = saveCache()
        onChange?()
    }

    func configureNotifications() {
        center?.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                if settings.authorizationStatus == .notDetermined {
                    self.refreshNotificationPermission(requestIfNeeded: true)
                } else {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    self.refreshNotificationPermission(requestIfNeeded: false)
                }
            }
        }
    }

    func refreshNotificationPermission(requestIfNeeded: Bool = false) {
        let cycle = generation
        center?.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.generation == cycle else { return }
                if requestIfNeeded, settings.authorizationStatus == .notDetermined {
                    self.center?.requestAuthorization(options: [.alert]) { [weak self] _, error in
                        DispatchQueue.main.async {
                            guard let self, !self.stopped, self.generation == cycle else { return }
                            self.lastNotificationError = error?.localizedDescription
                            self.refreshNotificationPermission()
                        }
                    }
                    return
                }
                self.notificationsAllowed = [.authorized, .provisional].contains(settings.authorizationStatus)
                self.onChange?()
                self.deliverPendingNotifications()
            }
        }
    }

    func refresh() {
        guard !stopped, !isRefreshing else { return }
        let cycle = generation
        let syncDate = now()
        let syncDay = ResetDates.day(syncDate)
        isRefreshing = true
        lastError = nil
        onChange?()
        refreshNotificationPermission()
        load(path: "version") { [weak self] result in
            guard let self, !self.stopped, self.generation == cycle else { return }
            do {
                let version = try JSONDecoder().decode(ResetVersionResponse.self, from: result.get())
                guard !version.version.isEmpty, version.version.count <= 128,
                      version.today == syncDay,
                      let checkedAt = ResetDates.parse(version.checkedAt),
                      checkedAt <= syncDate.addingTimeInterval(15 * 60),
                      ResetDates.day(self.now()) == syncDay else { throw ResetSyncError.invalidData }
                if let previous = self.cache.snapshot, checkedAt < previous.checkedAt.addingTimeInterval(-60) {
                    throw ResetSyncError.invalidData
                }
                let days = ResetDates.recentDays(now: syncDate)
                if self.cache.fingerprintVersion == 2, var previous = self.cache.snapshot, previous.version == version.version, previous.days == days {
                    previous.checkedAt = checkedAt
                    previous.fetchedAt = self.now()
                    self.cache.snapshot = previous
                    self.finish()
                    return
                }
                self.loadDays(days, version: version.version, checkedAt: checkedAt, cycle: cycle)
            } catch { self.finish(error: error) }
        }
    }

    private func loadDays(_ days: [String], version: String, checkedAt: Date, cycle: Int) {
        var remaining = days.count
        var collected: [ResetNotice] = []
        var failure: Error?
        for day in days {
            load(path: "days/" + day) { [weak self] result in
                guard let self, !self.stopped, self.generation == cycle else { return }
                do { collected.append(contentsOf: try parseResetDay(result.get(), expectedDay: day, expectedVersion: version)) }
                catch { failure = error }
                remaining -= 1
                guard remaining == 0 else { return }
                if let failure { self.finish(error: failure); return }
                guard ResetDates.day(self.now()) == days.first else { self.finish(error: ResetSyncError.invalidData); return }
                let notices = mergeResetNotices(collected, days: days)
                let previous = self.cache.snapshot == nil ? nil : self.cache.fingerprints
                let legacy = self.cache.fingerprintVersion == 2 ? nil : self.cache.snapshot?.notices
                let changed = changedResetNotices(notices, previous: previous, today: days[0], legacyNotices: legacy)
                if let legacy {
                    let notifiedPresentations = Set(legacy.filter { self.cache.notifiedKeys.contains($0.fingerprint) }.map(\.presentationFingerprint))
                    for notice in notices where notifiedPresentations.contains(notice.presentationFingerprint) {
                        self.cache.notifiedKeys.insert(notice.fingerprint)
                    }
                }
                self.cache.fingerprintVersion = 2
                let currentIDs = Set(notices.map(\.id))
                self.cache.unreadIDs.formIntersection(currentIDs)
                self.cache.pendingIDs.formIntersection(currentIDs)
                self.cache.unreadIDs.formUnion(changed.map(\.id))
                self.cache.pendingIDs.formUnion(changed.map(\.id))
                self.cache.fingerprints = Dictionary(uniqueKeysWithValues: notices.map { ($0.id, $0.fingerprint) })
                self.cache.snapshot = ResetSnapshot(version: version, days: days, fetchedAt: self.now(), checkedAt: checkedAt, notices: notices)
                self.finish()
            }
        }
    }

    private func load(path: String, completion: @escaping (Result<Data, Error>) -> Void) {
        let url = URL(string: "https://aihot.news/api/site/codex-reset/" + path)!
        httpClient.load(url, completion: completion)
    }

    private func finish(error: Error? = nil) {
        isRefreshing = false
        lastError = error.map { String(describing: $0) }
        if error == nil, !saveCache() { lastError = "Could not save reset notice cache" }
        onChange?()
        if lastError == nil { deliverPendingNotifications() }
    }

    @discardableResult
    private func saveCache() -> Bool {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
            return true
        } catch { return false }
    }

    private func deliverPendingNotifications() {
        guard !stopped, notificationsAllowed, !sendingNotification, lastError == nil, let center,
              saveCache() else { return }
        let pending = notices.filter { cache.pendingIDs.contains($0.id) && !cache.notifiedKeys.contains($0.fingerprint) }
        guard let latest = pending.first else { return }
        let content = UNMutableNotificationContent()
        content.title = "Codex 重置消息更新 · AIHOT"
        content.subtitle = latest.status.label(chinese: true)
        content.body = "\(latest.day) · \(latest.title)\n\(latest.timeDescription(chinese: true))\n\(latest.scope) · 第三方消息，实际额度以 Codex 为准。"
        if pending.count > 1 { content.body += "另有 \(pending.count - 1) 条更新。" }
        content.threadIdentifier = "codex-reset-notices"
        let key = resetDigest(pending.map(\.fingerprint).sorted().joined(separator: ":"))
        let request = UNNotificationRequest(identifier: "codex-reset-" + key, content: content, trigger: nil)
        sendingNotification = true
        let cycle = generation
        center.add(request) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.generation == cycle else { return }
                self.sendingNotification = false
                self.lastNotificationError = error?.localizedDescription
                if error == nil {
                    for notice in pending {
                        self.cache.notifiedKeys.insert(notice.fingerprint)
                        if self.cache.fingerprints[notice.id] == notice.fingerprint { self.cache.pendingIDs.remove(notice.id) }
                    }
                    self.cache.notifiedKeys = Set(self.cache.notifiedKeys.sorted().suffix(512))
                    if !self.saveCache() { self.lastNotificationError = "Could not save notification state" }
                }
                self.onChange?()
                if error == nil { self.deliverPendingNotifications() }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           response.notification.request.identifier.hasPrefix("codex-reset-") {
            DispatchQueue.main.async { [weak self] in self?.onOpen?() }
        }
        completionHandler()
    }
}
