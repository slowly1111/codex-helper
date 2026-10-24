import Foundation

func check(_ condition: Bool, _ label: String) {
    guard condition else {
        print("SAFETY_CHECK_FAILED: \(label)")
        exit(1)
    }
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-helper-safety-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let session = directory.appendingPathComponent("session.jsonl")
func cancelled(_ path: URL?, _ offset: UInt64 = 0) -> Bool {
    do { return try sessionActivityRequiresCancellation(at: path, since: offset) }
    catch { return true }
}
check(cancelled(nil), "no baseline must cancel")
check(cancelled(session), "missing session must cancel")
check(cancelled(directory), "unreadable session must cancel")
try Data([0xff, 0xfe]).write(to: session)
check(cancelled(session), "invalid text must cancel")
try Data("old".utf8).write(to: session)
check(cancelled(session, 100), "truncated session must cancel")
check(!cancelled(session, 3), "unchanged session may continue")
try Data("old{\"type\":\"user_message\"}\n".utf8).write(to: session)
check(cancelled(session, 3), "new user message must cancel")
try Data("old{\"type\": \"task_started\"}\n".utf8).write(to: session)
check(cancelled(session, 3), "new task must cancel")
try Data("old{\"type\":\"token_count\"}\n".utf8).write(to: session)
check(!cancelled(session, 3), "irrelevant event may continue")
func snapshot(_ text: String) -> CodexUsageSnapshot? { makeUsageSnapshot(from: Data(text.utf8)) }
check(snapshot(#"{"rateLimits":{"primary":{"usedPercent":12,"resetsAt":1e300}}}"#) == nil, "extreme timestamp rejected before countdown conversion")
check(snapshot(#"{"rateLimits":{"primary":{"usedPercent":-1}}}"#) == nil, "negative usage rejected")
check(snapshot(#"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":-1}}}"#) == nil, "negative duration rejected")
check(snapshot(#"{"rateLimits":{"primary":{"usedPercent":12}},"rateLimitResetCredits":{"availableCount":-1}}"#) == nil, "negative reset credits rejected")
check(snapshot(#"{"rateLimitsByLimitId":{"codex":{}}}"#) == nil, "empty quota windows are unavailable")
let duplicate = snapshot(#"{"rateLimitsByLimitId":{"alias":{"limitId":"codex","primary":{"usedPercent":99}},"codex":{"limitId":"codex","primary":{"usedPercent":12}}}}"#)
check(duplicate?.limits.count == 1 && duplicate?.limits.first?.primary?.usedPercent == 12, "quota IDs are unique and canonical bucket wins")
check(snapshot(#"{"rateLimits":{"primary":{"usedPercent":120}}}"#)?.limits.first?.primary?.remainingPercent == 0, "over-limit usage never becomes available credit")
check(formatQuotaPercent(.infinity) == "—" && formatQuotaPercent(.nan) == "—", "non-finite percentages never reach Int conversion")
check(formatQuotaPercent(1e300) == "—", "extreme percentages are unavailable")
let extremeDate = Date(timeIntervalSince1970: 1e300)
check(formatResetCountdown(until: extremeDate, isChinese: true) == "—", "extreme countdown cannot trap")
check(formatCompactResetDistance(until: extremeDate, isChinese: true) == "—", "extreme compact countdown cannot trap")
check(formatMenuBarResetLabel(until: extremeDate, isChinese: true) == "—", "extreme menu countdown cannot trap")
check(formatResetCountdown(until: Date(timeIntervalSince1970: -1e300), isChinese: true) == "00:00:00", "extreme expired date clamps before conversion")
let invalidWidget = WidgetQuotaSnapshot(windows: [WidgetQuotaWindow(id: "a", name: "a", planType: nil, remainingPercent: 1e300, windowDurationMins: nil, resetsAt: nil)], resetCredits: 0, fetchedAt: Date())
check(!invalidWidget.isValid, "widget rejects unsafe numeric cache")
check(WidgetSnapshotStore.decode(Data(repeating: 0, count: 128_001)) == nil, "oversized widget cache rejected")
check(quotaLevel(for: .infinity) == .unavailable, "invalid quota cannot appear healthy")
@discardableResult
func pump(_ done: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    return done()
}
let serverScript = directory.appendingPathComponent("fake-server.py")
try #"""
import sys, json, signal, time
mode, counter = sys.argv[1:]
if mode == "hang-init":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True: time.sleep(1)
for line in sys.stdin:
    request = json.loads(line)
    if request.get("method") == "initialize":
        print(json.dumps({"id": 1, "result": {}}), flush=True)
    elif request.get("method") == "account/rateLimits/read":
        with open(counter, "a") as log: log.write("request\n")
        if mode == "flood": print("x" * 1000001, flush=True)
        elif mode == "valid":
            print(json.dumps({"id": request["id"], "result": {"rateLimits": {"primary": {"usedPercent": 25}}}}), flush=True)
"""#.write(to: serverScript, atomically: true, encoding: .utf8)
func fakeService(_ mode: String, timeout: TimeInterval) -> (CodexUsageService, Process, URL) {
    let counter = directory.appendingPathComponent(UUID().uuidString)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", serverScript.path, mode, counter.path]
    return (CodexUsageService(requestTimeout: timeout, processFactory: { process }), process, counter)
}
func unavailable(_ service: CodexUsageService, contains text: String) -> Bool {
    if case let .unavailable(message) = service.status { return message.contains(text) }
    return false
}
let (hangingInit, unresponsiveProcess, _) = fakeService("hang-init", timeout: 0.05)
hangingInit.refresh()
check(pump { unavailable(hangingInit, contains: "timed out") }, "initialization timeout ends loading")
check(pump { !unresponsiveProcess.isRunning }, "unresponsive child is reaped after termination grace")
hangingInit.stop()
let (hangingRead, _, counter) = fakeService("hang-read", timeout: 0.3)
hangingRead.refresh()
check(pump { FileManager.default.fileExists(atPath: counter.path) }, "fake quota request arrives")
for _ in 0..<20 { hangingRead.refresh() }
check(pump { unavailable(hangingRead, contains: "timed out") }, "quota request timeout ends loading")
check((try String(contentsOf: counter)).split(separator: "\n").count == 1, "concurrent quota reads coalesce")
hangingRead.stop()
let (flooding, _, _) = fakeService("flood", timeout: 1)
flooding.refresh()
check(pump { unavailable(flooding, contains: "size limit") }, "unterminated oversized stdout is bounded")
flooding.stop()
let (valid, validProcess, _) = fakeService("valid", timeout: 1)
valid.refresh()
check(pump { valid.snapshot != nil }, "normal fake server yields quota")
validProcess.terminate()
check(pump { unavailable(valid, contains: "stopped") }, "server exit marks cached quota stale")
check(valid.snapshot?.limits.first?.primary?.remainingPercent == 75, "server exit preserves last valid snapshot")
valid.stop()
let (stopped, _, _) = fakeService("hang-read", timeout: 0.05)
var changes = 0
stopped.onChange = { changes += 1 }
stopped.refresh()
stopped.stop()
let changesAfterStop = changes
_ = pump({ false }, timeout: 0.1)
check(changes == changesAfterStop, "stopped watchdog and pipe callbacks cannot update state")
print("SAFETY_CHECKS_OK cases=35")
