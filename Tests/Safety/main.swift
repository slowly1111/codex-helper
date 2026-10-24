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
print("SAFETY_CHECKS_OK cases=9")
