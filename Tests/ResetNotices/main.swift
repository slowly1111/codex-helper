import Foundation

var checks = 0
func check(_ condition: Bool, _ label: String) {
    guard condition else { print("RESET_TEST_FAILED: \(label)"); exit(1) }
    checks += 1
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/ResetNotices")
let today = "2026-10-23"
let version = "2b50cc98c4864768"
let bytes = try Data(contentsOf: root.appendingPathComponent(today + ".json"))
let baseline = try parseResetDay(bytes, expectedDay: today, expectedVersion: version)
check(baseline.count == 2, "actual day has two notices")
check(baseline.contains { $0.status == .announced }, "announcement remains pending")
check(baseline.contains { $0.status == .confirmed }, "confirmation is separate")
check(baseline.allSatisfy { $0.scope == "适用范围未明确" }, "unknown audience never becomes everyone")
check(baseline.first { $0.status == .announced }?.window?.hasPrefix("网站推算：") == true, "estimate is explicitly labeled")
check(baseline.first { $0.status == .confirmed }?.window == nil, "confirmed notice does not show predicted window")
check(baseline.allSatisfy { $0.originalLink != nil }, "actual original links accepted")
check(safeResetOriginalURL("https://x.com/thsottiaux/status/123") != nil, "valid source URL accepted")
for url in ["javascript:alert(1)", "https://x.com.evil.test/a/status/1", "https://x.com@evil.test/a/status/1", "https://evil@x.com/a/status/1", "file:///etc/passwd", "https://x.com/a/status/1?q=secret", "https://x.com:8443/a/status/1"] {
    check(safeResetOriginalURL(url) == nil, "unsafe URL rejected: " + url)
}
let now = ResetDates.parse("2026-10-23T22:00:00+08:00")!
let days = ResetDates.recentDays(now: now)
check(days.count == 7 && days.first == today && days.last == "2026-10-17", "rolling seven-day window")
check(ResetDates.recentDays(now: ResetDates.parse("2026-10-23T18:00:00Z")!).first == "2026-10-24", "Beijing midnight conversion")
check(!ResetDates.validDay("2026-02-30"), "invalid calendar day rejected")
var all: [ResetNotice] = []
for day in days {
    all += try parseResetDay(Data(contentsOf: root.appendingPathComponent(day + ".json")), expectedDay: day, expectedVersion: version)
}
let merged = mergeResetNotices(all + all, days: days)
check(merged.count == 4, "seven-day history and duplicate IDs")
check(changedResetNotices(merged, previous: nil, today: today).count == 1, "initial sync alerts once for today, not historical flood")
check(changedResetNotices(merged, previous: nil, today: "2030-01-01").isEmpty, "no stale initial notification")
let fingerprints = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0.fingerprint) })
check(changedResetNotices(merged, previous: fingerprints, today: today).isEmpty, "identical refresh does not notify")
var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
func encoded(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
func rejects(_ data: Data, day: String = today, token: String = version) -> Bool {
    do { _ = try parseResetDay(data, expectedDay: day, expectedVersion: token); return false }
    catch { return true }
}
check(rejects(bytes, day: "2026-10-22"), "day mismatch rejected")
check(rejects(bytes, token: "different-version"), "mixed snapshot rejected")
check(rejects(Data("not-json".utf8)), "non-JSON rejected")
check(rejects(Data(repeating: 0, count: 1_000_001)), "oversize response rejected")
var events = object["events"] as! [[String: Any]]
events[0]["updatedAt"] = "2026-10-23T22:00:00+08:00"
object["events"] = events
let timestampOnly = try parseResetDay(encoded(object), expectedDay: today, expectedVersion: version)
check(timestampOnly[0].fingerprint == baseline[0].fingerprint, "timestamp-only edits do not notify")
var presentation = events[0]["presentation"] as! [String: Any]
presentation["status"] = "confirmed"
events[0]["presentation"] = presentation
events[0]["status"] = "confirmed"
object["events"] = events
let confirmed = try parseResetDay(encoded(object), expectedDay: today, expectedVersion: version)
check(changedResetNotices(confirmed, previous: fingerprints, today: today).count == 1, "pending-to-confirmed notifies once")
presentation["status"] = "unknown-future-status"
events[0]["presentation"] = presentation
object["events"] = events
let unknown = try parseResetDay(encoded(object), expectedDay: today, expectedVersion: version)
check(unknown[0].status == .unverified, "unknown status never promoted")
events[0]["type"] = "reset_credit"
object["events"] = events
let credit = try parseResetDay(encoded(object), expectedDay: today, expectedVersion: version)
check(credit[0].title == "重置卡发放" && credit[0].kind == "reset_credit", "credit issuance stays separate")
events[0]["type"] = "unrelated_news"
object["events"] = events
check(try parseResetDay(encoded(object), expectedDay: today, expectedVersion: version).count == 1, "unrelated events excluded")

let defaults = AgentConfig()
check(!defaults.autoRetryEnabled && !defaults.automaticUpdates, "fresh install disables retry and software updates")
let missingConfig = try JSONDecoder().decode(AgentConfig.self, from: Data("{}".utf8))
check(!missingConfig.autoRetryEnabled && !missingConfig.automaticUpdates, "legacy missing flags use safe defaults")
check(ResetDates.time(ResetDates.parse("2026-10-23T07:00:00Z")!) == "10/23 15:00", "notice time is Beijing time")
check(baseline.first { $0.status == .announced }?.window == "网站推算：10/23 15:00 至 10/24 01:00", "estimate retains precise cross-day window")

let confirmedNotice = baseline.first { $0.status == .confirmed }!
check(confirmedNotice.timeDescription(chinese: true).contains(confirmedNotice.confirmationTime!), "native notice includes confirmation time")
check(confirmedNotice.timeDescription(chinese: true).contains("北京时间"), "notification names its time zone")
check(baseline.first { $0.status == .announced }!.timeDescription(chinese: true).contains("网站推算"), "estimated timing remains qualified")
var reordered = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
var reorderedEvents = reordered["events"] as! [[String: Any]]
var posts = reorderedEvents[0]["posts"] as! [[String: Any]]
posts.append(["id": "99999999999999", "url": "https://x.com/thsottiaux/status/99999999999999", "text": "Second public source"])
reorderedEvents[0]["posts"] = posts
reordered["events"] = reorderedEvents
let beforeOrderChange = try parseResetDay(encoded(reordered), expectedDay: today, expectedVersion: version)
reorderedEvents[0]["posts"] = Array(posts.reversed())
reordered["events"] = reorderedEvents
let orderedNotices = try parseResetDay(encoded(reordered), expectedDay: today, expectedVersion: version)
check(orderedNotices[0].fingerprint == beforeOrderChange[0].fingerprint, "source post order does not trigger duplicate alerts")
reorderedEvents.append(reorderedEvents[0])
reordered["events"] = reorderedEvents
check(rejects(try encoded(reordered)), "conflicting duplicate IDs reject the day snapshot")
let tied = mergeResetNotices(baseline + confirmed, days: days)
check(tied == mergeResetNotices(Array((baseline + confirmed).reversed()), days: days), "equal revision timestamps merge deterministically")

let oldFingerprints = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, "legacy-" + $0.fingerprint) })
check(changedResetNotices(baseline, previous: oldFingerprints, today: today, legacyNotices: baseline).isEmpty, "legacy fingerprint migration does not notify unchanged messages")
check(changedResetNotices(confirmed, previous: oldFingerprints, today: today, legacyNotices: baseline).count == 1, "legacy migration still alerts real pending-to-confirmed transition")
print("RESET_TESTS_OK cases=\(checks)")
