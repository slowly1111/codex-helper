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
    return try response.events.compactMap { event in
        guard ["direct_reset", "reset_credit"].contains(event.type) else { return nil }
        guard !event.id.isEmpty, event.id.count <= 256,
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
        let originalURL = event.posts?.compactMap { safeResetOriginalURL($0.url)?.absoluteString }.first
        let postContent = (event.posts ?? []).prefix(10).map { [$0.id, String(($0.text ?? "").prefix(1000))] }
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
        if let previous = merged[notice.id], previous.revisionDate > notice.revisionDate { continue }
        merged[notice.id] = notice
    }
    return merged.values.sorted {
        if $0.revisionDate != $1.revisionDate { return $0.revisionDate > $1.revisionDate }
        return $0.id < $1.id
    }
}

func changedResetNotices(_ notices: [ResetNotice], previous: [String: String]?, today: String) -> [ResetNotice] {
    guard let previous else { return Array(notices.filter { $0.day == today }.prefix(1)) }
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
    var snapshot: ResetSnapshot?
    var fingerprints: [String: String] = [:]
    var unreadIDs: Set<String> = []
    var pendingIDs: Set<String> = []
    var notifiedKeys: Set<String> = []
}

final class ResetNoticeService: NSObject, UNUserNotificationCenterDelegate, URLSessionTaskDelegate {
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
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(cacheURL: URL, enableSystemNotifications: Bool = true) {
        self.cacheURL = cacheURL
        center = enableSystemNotifications ? UNUserNotificationCenter.current() : nil
        super.init()
        if let data = try? Data(contentsOf: cacheURL), data.count < 2_000_000,
           let saved = try? JSONDecoder().decode(ResetCache.self, from: data) { cache = saved }
        center?.delegate = self
    }

    var notices: [ResetNotice] {
        mergeResetNotices(cache.snapshot?.notices ?? [], days: ResetDates.recentDays())
    }

    var unreadCount: Int { notices.filter { cache.unreadIDs.contains($0.id) }.count }
    var fetchedAt: Date? { cache.snapshot?.fetchedAt }

    func statusText(chinese: Bool) -> String {
        if isRefreshing { return chinese ? "正在同步重置消息…" : "Syncing reset notices…" }
        if lastError != nil {
            return chinese ? "暂时无法同步，保留已同步消息；稍后自动重试。" : "Sync unavailable; keeping cached notices."
        }
        guard let snapshot = cache.snapshot else { return chinese ? "等待首次同步" : "Waiting for first sync" }
        let stale = Date().timeIntervalSince(snapshot.checkedAt) > 30 * 60
        let suffix = stale ? (chinese ? " · 源站检查已超过 30 分钟" : " · Source check is over 30 minutes old") : ""
        return (chinese ? "每 10 分钟同步 · 更新于 " : "Checks every 10 minutes · Updated ") + ResetDates.time(snapshot.fetchedAt) + suffix
    }

    func start() {
        guard timer == nil else { return }
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
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        session.invalidateAndCancel()
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
        center?.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                if requestIfNeeded, settings.authorizationStatus == .notDetermined {
                    self.center?.requestAuthorization(options: [.alert]) { [weak self] _, error in
                        DispatchQueue.main.async {
                            self?.lastNotificationError = error?.localizedDescription
                            self?.refreshNotificationPermission()
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
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        onChange?()
        refreshNotificationPermission()
        load(path: "version") { [weak self] result in
            guard let self else { return }
            do {
                let version = try JSONDecoder().decode(ResetVersionResponse.self, from: result.get())
                guard !version.version.isEmpty, version.version.count <= 128,
                      version.today == ResetDates.day(Date()),
                      let checkedAt = ResetDates.parse(version.checkedAt),
                      checkedAt <= Date().addingTimeInterval(15 * 60) else { throw ResetSyncError.invalidData }
                if let previous = self.cache.snapshot, checkedAt < previous.checkedAt.addingTimeInterval(-60) {
                    throw ResetSyncError.invalidData
                }
                let days = ResetDates.recentDays()
                if var previous = self.cache.snapshot, previous.version == version.version, previous.days == days {
                    previous.checkedAt = checkedAt
                    previous.fetchedAt = Date()
                    self.cache.snapshot = previous
                    self.finish()
                    return
                }
                self.loadDays(days, version: version.version, checkedAt: checkedAt)
            } catch { self.finish(error: error) }
        }
    }

    private func loadDays(_ days: [String], version: String, checkedAt: Date) {
        var remaining = days.count
        var collected: [ResetNotice] = []
        var failure: Error?
        for day in days {
            load(path: "days/" + day) { [weak self] result in
                guard let self else { return }
                do { collected.append(contentsOf: try parseResetDay(result.get(), expectedDay: day, expectedVersion: version)) }
                catch { failure = error }
                remaining -= 1
                guard remaining == 0 else { return }
                if let failure { self.finish(error: failure); return }
                let notices = mergeResetNotices(collected, days: days)
                let previous = self.cache.snapshot == nil ? nil : self.cache.fingerprints
                let changed = changedResetNotices(notices, previous: previous, today: ResetDates.day(Date()))
                let currentIDs = Set(notices.map(\.id))
                self.cache.unreadIDs.formIntersection(currentIDs)
                self.cache.pendingIDs.formIntersection(currentIDs)
                self.cache.unreadIDs.formUnion(changed.map(\.id))
                self.cache.pendingIDs.formUnion(changed.map(\.id))
                self.cache.fingerprints = Dictionary(uniqueKeysWithValues: notices.map { ($0.id, $0.fingerprint) })
                self.cache.snapshot = ResetSnapshot(version: version, days: days, fetchedAt: Date(), checkedAt: checkedAt, notices: notices)
                self.finish()
            }
        }
    }

    private func load(path: String, completion: @escaping (Result<Data, Error>) -> Void) {
        let url = URL(string: "https://aihot.news/api/site/codex-reset/" + path)!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Helper-Reset-Monitor/0.8.5", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.url?.scheme == "https", response.url?.host == "aihot.news",
                      let data, data.count <= 1_000_000,
                      response.expectedContentLength <= 1_000_000 else {
                    completion(.failure(ResetSyncError.invalidData)); return
                }
                completion(.success(data))
            }
        }.resume()
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
        guard notificationsAllowed, !sendingNotification, lastError == nil, let center,
              saveCache() else { return }
        let pending = notices.filter { cache.pendingIDs.contains($0.id) && !cache.notifiedKeys.contains($0.fingerprint) }
        guard let latest = pending.first else { return }
        let content = UNMutableNotificationContent()
        content.title = "Codex 重置消息更新 · AIHOT"
        content.subtitle = latest.status.label(chinese: true)
        content.body = "\(latest.day) · \(latest.title)\n\(latest.window ?? latest.scope)\n第三方消息，实际额度以 Codex 为准。"
        if pending.count > 1 { content.body += "另有 \(pending.count - 1) 条更新。" }
        content.threadIdentifier = "codex-reset-notices"
        let key = resetDigest(pending.map(\.fingerprint).sorted().joined(separator: ":"))
        let request = UNNotificationRequest(identifier: "codex-reset-" + key, content: content, trigger: nil)
        sendingNotification = true
        center.add(request) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sendingNotification = false
                self.lastNotificationError = error?.localizedDescription
                if error == nil {
                    for notice in pending {
                        self.cache.notifiedKeys.insert(notice.fingerprint)
                        if self.cache.fingerprints[notice.id] == notice.fingerprint { self.cache.pendingIDs.remove(notice.id) }
                    }
                    self.cache.notifiedKeys = Set(self.cache.notifiedKeys.sorted().suffix(512))
                    _ = self.saveCache()
                }
                self.onChange?()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && url?.host == "aihot.news" && url?.user == nil && url?.password == nil
            && (url?.port == nil || url?.port == 443) && url?.path.hasPrefix("/api/site/codex-reset/") == true
        completionHandler(allowed ? request : nil)
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
