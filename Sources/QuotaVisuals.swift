import Foundation

enum QuotaLevel: Equatable {
    case healthy
    case attention
    case critical
    case unavailable
}

func quotaLevel(for remainingPercent: Double?) -> QuotaLevel {
    guard let remainingPercent, remainingPercent.isFinite, (0...100).contains(remainingPercent) else { return .unavailable }
    if remainingPercent < 10 { return .critical }
    if remainingPercent < 50 { return .attention }
    return .healthy
}

func formatQuotaPercent(_ value: Double) -> String {
    guard value.isFinite, (0...100).contains(value) else { return "—" }
    return value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
}

func quotaDistanceSeconds(until reset: Date, from now: Date) -> Int? {
    let seconds = reset.timeIntervalSince(now)
    guard seconds.isFinite else { return nil }
    if seconds <= 0 { return 0 }
    guard seconds <= 253_402_300_799 else { return nil }
    return Int(seconds)
}

func formatCompactResetDistance(
    until reset: Date,
    from now: Date = Date(),
    isChinese: Bool
) -> String {
    guard quotaDistanceSeconds(until: reset, from: now) != nil else { return "—" }
    let totalMinutes = Int(ceil(max(reset.timeIntervalSince(now), 0) / 60))
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes % (24 * 60)) / 60
    let minutes = totalMinutes % 60

    if days > 0 {
        return isChinese ? "\(days)天\(hours)时" : "\(days)d \(hours)h"
    }
    if hours > 0 {
        return String(format: "%d:%02d", hours, minutes)
    }
    return isChinese ? "\(minutes)分" : "\(minutes)m"
}

func formatMenuBarResetLabel(
    until reset: Date,
    from now: Date = Date(),
    isChinese: Bool
) -> String {
    guard quotaDistanceSeconds(until: reset, from: now) != nil else { return "—" }
    let totalMinutes = Int(ceil(max(reset.timeIntervalSince(now), 0) / 60))
    let days = totalMinutes / (24 * 60)
    let hours = totalMinutes / 60

    if days > 0 {
        return isChinese ? "\(days)天重置" : "\(days)d reset"
    }
    if hours > 0 {
        return isChinese ? "\(hours)时重置" : "\(hours)h reset"
    }
    return isChinese ? "\(totalMinutes)分重置" : "\(totalMinutes)m reset"
}

func formatResetCountdown(
    until reset: Date,
    from now: Date = Date(),
    isChinese: Bool
) -> String {
    guard let totalSeconds = quotaDistanceSeconds(until: reset, from: now) else { return "—" }
    let days = totalSeconds / (24 * 60 * 60)
    let hours = (totalSeconds % (24 * 60 * 60)) / (60 * 60)
    let minutes = (totalSeconds % (60 * 60)) / 60
    let seconds = totalSeconds % 60

    if days > 0 {
        return isChinese ? "\(days)天 \(hours)小时 \(minutes)分" : "\(days)d \(hours)h \(minutes)m"
    }
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
}
