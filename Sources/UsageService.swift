import AppKit
import Foundation
import Darwin

struct CodexUsageWindow: Codable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?

    var remainingPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }
}

struct CodexUsageLimit: Codable, Equatable {
    let id: String
    let name: String
    let planType: String?
    let primary: CodexUsageWindow?
    let secondary: CodexUsageWindow?
}

func visibleUsageLimits(_ limits: [CodexUsageLimit], showSparkQuota: Bool) -> [CodexUsageLimit] {
    guard !showSparkQuota else { return limits }
    return limits.filter { limit in
        let id = limit.id.lowercased()
        let name = limit.name.lowercased()
        return id != "spark" && !name.contains("spark")
    }
}

struct CodexUsageSnapshot: Codable, Equatable {
    let limits: [CodexUsageLimit]
    let resetCredits: Int
    let fetchedAt: Date
}

enum CodexUsageStatus: Equatable {
    case idle
    case loading
    case available(CodexUsageSnapshot)
    case unavailable(String)
}

private struct RateLimitsResult: Decodable {
    let rateLimitsByLimitId: [String: RateLimitPayload]?
    let rateLimits: RateLimitPayload?
    let rateLimitResetCredits: ResetCreditsPayload?
}

private struct RateLimitPayload: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: UsageWindowPayload?
    let secondary: UsageWindowPayload?
    let planType: String?
}

private struct UsageWindowPayload: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    var isValid: Bool {
        guard usedPercent.isFinite, usedPercent >= 0 else { return false }
        if let windowDurationMins, windowDurationMins <= 0 { return false }
        if let resetsAt, !resetsAt.isFinite || !(0...253_402_300_799).contains(resetsAt) { return false }
        return true
    }
}

private struct ResetCreditsPayload: Decodable {
    let availableCount: Int
}

func makeUsageSnapshot(from data: Data, fetchedAt: Date = Date()) -> CodexUsageSnapshot? {
    guard data.count <= 1_000_000,
          let result = try? JSONDecoder().decode(RateLimitsResult.self, from: data),
          (result.rateLimitResetCredits?.availableCount ?? 0) >= 0 else { return nil }
    var payloads = result.rateLimitsByLimitId ?? [:]
    if let main = result.rateLimits,
       main.limitId != nil || main.limitName != nil || main.planType != nil || main.primary != nil || main.secondary != nil {
        let mainID = main.limitId ?? "codex"
        if payloads[mainID] == nil {
            payloads[mainID] = main
        }
    }

    guard payloads.count <= 100 else { return nil }
    var byID: [String: CodexUsageLimit] = [:]
    for dictionaryID in payloads.keys.sorted() {
        guard let payload = payloads[dictionaryID] else { return nil }
        guard payload.primary?.isValid != false, payload.secondary?.isValid != false else { return nil }
        let limitID = payload.limitId ?? dictionaryID
        guard !limitID.isEmpty, limitID.count <= 256 else { return nil }
        if byID[limitID] != nil, dictionaryID != limitID { continue }
        byID[limitID] = CodexUsageLimit(
            id: limitID,
            name: payload.limitName ?? (limitID == "codex" ? "Codex" : limitID),
            planType: payload.planType,
            primary: payload.primary.map(makeUsageWindow),
            secondary: payload.secondary.map(makeUsageWindow)
        )
    }
    let limits = byID.values.sorted { left, right in
        if left.id == "codex" { return true }
        if right.id == "codex" { return false }
        let order = left.name.localizedCaseInsensitiveCompare(right.name)
        return order == .orderedSame ? left.id < right.id : order == .orderedAscending
    }

    guard limits.contains(where: { $0.primary != nil || $0.secondary != nil }) else { return nil }
    return CodexUsageSnapshot(
        limits: limits,
        resetCredits: result.rateLimitResetCredits?.availableCount ?? 0,
        fetchedAt: fetchedAt
    )
}

private func makeUsageWindow(_ payload: UsageWindowPayload) -> CodexUsageWindow {
    CodexUsageWindow(
        usedPercent: payload.usedPercent,
        windowDurationMins: payload.windowDurationMins,
        resetsAt: payload.resetsAt.map(Date.init(timeIntervalSince1970:))
    )
}

final class CodexUsageService {
    var onChange: (() -> Void)?
    private(set) var status: CodexUsageStatus = .idle
    private(set) var snapshot: CodexUsageSnapshot?

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputBuffer = Data()
    private var initialized = false
    private var refreshPending = false
    private var nextRequestID = 2
    private var refreshRequestIDs = Set<Int>()
    private var refreshTimer: Timer?
    private var requestTimer: Timer?
    private let requestTimeout: TimeInterval
    private let processFactory: (() -> Process)?

    // The app uses the verified executable path. Tests supply a local fake server.
    init(requestTimeout: TimeInterval = 20, processFactory: (() -> Process)? = nil) {
        self.requestTimeout = requestTimeout
        self.processFactory = processFactory
    }

    func start() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        shutdownProcess()
    }

    func refresh() {
        if process?.isRunning != true {
            shutdownProcess()
            refreshPending = true
            launchProcess()
            return
        }
        guard refreshRequestIDs.isEmpty else { return }
        guard initialized else {
            refreshPending = true
            return
        }

        status = .loading
        onChange?()
        let requestID = nextRequestID
        nextRequestID += 1
        refreshRequestIDs.insert(requestID)
        armRequestTimeout()
        send(["id": requestID, "method": "account/rateLimits/read", "params": [:] as [String: Any]])
    }

    private func launchProcess() {
        let process: Process
        if let processFactory {
            process = processFactory()
        } else {
            guard let executable = findCodexExecutable() else {
                updateStatus(.unavailable("Codex CLI not found"))
                return
            }
            process = Process()
            process.executableURL = executable
            process.arguments = ["app-server", "--stdio"]
        }
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                self.consume(data)
            }
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                self.shutdownProcess()
                self.updateStatus(.unavailable("Codex usage service stopped"))
            }
        }

        do {
            self.process = process
            try process.run()
            nextRequestID = 2
            inputHandle = input.fileHandleForWriting
            outputBuffer.removeAll(keepingCapacity: true)
            initialized = false
            status = .loading
            onChange?()
            armRequestTimeout()
            send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-helper",
                        "title": "Codex Helper",
                        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                    ]
                ]
            ])
        } catch {
            shutdownProcess()
            updateStatus(.unavailable(error.localizedDescription))
        }
    }

    private func consume(_ data: Data) {
        guard data.count <= 1_000_000 - outputBuffer.count else {
            shutdownProcess()
            updateStatus(.unavailable("Codex usage response exceeded size limit"))
            return
        }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        if let id = object["id"] as? Int, id == 1 {
            guard !initialized else { return }
            guard object["result"] != nil else {
                shutdownProcess()
                updateStatus(.unavailable("Codex usage initialization failed"))
                return
            }
            requestTimer?.invalidate()
            requestTimer = nil
            initialized = true
            send(["method": "initialized", "params": [:] as [String: Any]])
            if refreshPending {
                refreshPending = false
                refresh()
            }
            return
        }

        if let id = object["id"] as? Int, refreshRequestIDs.remove(id) != nil {
            requestTimer?.invalidate()
            requestTimer = nil
            guard let result = object["result"],
                  JSONSerialization.isValidJSONObject(result),
                  let data = try? JSONSerialization.data(withJSONObject: result),
                  let snapshot = makeUsageSnapshot(from: data) else {
                let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? "Usage unavailable"
                updateStatus(.unavailable(message))
                return
            }
            updateStatus(.available(snapshot))
            return
        }

        if object["method"] as? String == "account/rateLimits/updated",
           initialized {
            // Rolling notifications are intentionally sparse. Refetch the complete
            // snapshot so missing fields never erase previously observed limits.
            refresh()
        }
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do {
            try inputHandle?.write(contentsOf: data)
        } catch {
            updateStatus(.unavailable(error.localizedDescription))
            shutdownProcess()
        }
    }

    private func updateStatus(_ newStatus: CodexUsageStatus) {
        status = newStatus
        if case let .available(value) = newStatus {
            snapshot = value
        }
        onChange?()
    }

    private func armRequestTimeout() {
        requestTimer?.invalidate()
        let timer = Timer(timeInterval: requestTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.shutdownProcess()
            self.updateStatus(.unavailable("Codex usage request timed out"))
        }
        RunLoop.main.add(timer, forMode: .common)
        requestTimer = timer
    }

    private func shutdownProcess() {
        let current = process
        process = nil
        requestTimer?.invalidate()
        requestTimer = nil
        (current?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (current?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        current?.terminationHandler = nil
        try? inputHandle?.close()
        inputHandle = nil
        outputBuffer.removeAll(keepingCapacity: false)
        initialized = false
        refreshPending = false
        refreshRequestIDs.removeAll()
        if let current, current.isRunning {
            current.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if current.isRunning { kill(current.processIdentifier, SIGKILL) }
            }
        }
    }

    private func findCodexExecutable() -> URL? {
        var bundles: [URL] = []
        if let bundleURL = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first?.bundleURL {
            bundles.append(bundleURL)
        }
        bundles.append(URL(fileURLWithPath: "/Applications/ChatGPT.app"))
        bundles.append(URL(fileURLWithPath: "/Applications/Codex.app"))
        let candidates = bundles.flatMap { bundleURL in
            [
                bundleURL.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
                bundleURL.appendingPathComponent("Contents/Resources/codex")
            ]
        }
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path) && isOfficialCodexExecutable($0)
        }
    }

    private func isOfficialCodexExecutable(_ url: URL) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--verify",
            "--strict",
            "-R=anchor apple generic and identifier \"codex\" and certificate leaf[subject.OU] = \"2DC432GLL2\"",
            url.path
        ]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            _ = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
