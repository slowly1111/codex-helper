import SwiftUI

struct ResetNoticesView: View {
    let model: DashboardModel
    let dispatcher: DashboardActionDispatcher
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack {
                Label(model.isChinese ? "Codex 重置消息" : "Codex Reset Notices", systemImage: "bell.badge")
                    .font(compact ? .callout.bold() : .headline)
                if model.resetUnreadCount > 0 {
                    Text(model.isChinese ? "新消息 \(model.resetUnreadCount)" : "\(model.resetUnreadCount) new")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if compact {
                    Button(model.isChinese ? "查看" : "View") { dispatcher.send(dispatcher.actions.showDashboard) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if compact {
                if let latest = model.resetNotices.first {
                    Text("\(latest.day) · \(latest.title)")
                        .font(.caption)
                        .lineLimit(1)
                    Text(latest.status.label(chinese: model.isChinese))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(latest.timeDescription(chinese: model.isChinese))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(model.resetStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(model.isChinese ? "来源：AIHOT（第三方）" : "Source: AIHOT (third party)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(model.isChinese ? "AIHOT 第三方整理 · 最近 7 天 · 北京时间" : "AIHOT third-party reports · Past 7 days · Beijing time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.resetStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(model.isChinese ? "同步重置消息" : "Sync Notices") {
                        dispatcher.send(dispatcher.actions.refreshResetNotices)
                    }
                    .disabled(model.resetIsRefreshing)
                    if model.resetUnreadCount > 0 {
                        Button(model.isChinese ? "标为已读" : "Mark Read") {
                            dispatcher.send(dispatcher.actions.markResetNoticesRead)
                        }
                    }
                    Button(model.isChinese ? "通知设置…" : "Notifications…") {
                        dispatcher.send(dispatcher.actions.configureResetNotifications)
                    }
                    Text(model.resetNotificationsAllowed
                        ? (model.isChinese ? "系统通知已开启" : "System notifications on")
                        : (model.isChinese ? "系统通知未开启" : "System notifications off"))
                        .font(.caption)
                        .foregroundStyle(model.resetNotificationsAllowed ? Color.green : Color.orange)
                }
                .buttonStyle(.bordered)
                if let error = model.resetNotificationError {
                    Text((model.isChinese ? "通知暂不可用：" : "Notification unavailable: ") + error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if model.resetNotices.isEmpty {
                    Text(model.isChinese ? "最近 7 天暂无已同步的重置或发卡消息。" : "No synced reset or reset-credit notices in the past 7 days.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(model.resetNotices.prefix(6))) { notice in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(notice.day).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(notice.title).font(.callout.bold())
                            Spacer(minLength: 8)
                            Text(notice.status.label(chinese: model.isChinese))
                                .font(.caption)
                                .foregroundStyle(notice.status == .confirmed ? Color.teal : Color.orange)
                        }
                        if let window = notice.window {
                            Text(window).font(.caption).foregroundStyle(.secondary)
                        }
                        if let confirmedAt = notice.confirmationTime {
                            Text(model.isChinese ? "来源确认帖：\(confirmedAt)，不代表个人到账时间" : "Source confirmation: \(confirmedAt); individual receipt may differ")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 14) {
                            Text(notice.scope).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            if let original = notice.originalLink {
                                Button(model.isChinese ? "原帖" : "Original") { dispatcher.open(original) }
                            }
                            Button(model.isChinese ? "AIHOT 记录" : "AIHOT Record") { dispatcher.open(notice.sourceURL) }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    }
                    .padding(12)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }
                Text(model.isChinese
                    ? "预告和网站推算仅供参考；重置卡发放不代表额度已恢复，个人额度以上方官方查询为准。"
                    : "Announcements and estimates are informational. Reset-credit issuance does not confirm restored quota; use the official account balance above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 12 : 0)
        .background {
            if compact { RoundedRectangle(cornerRadius: 14).fill(.primary.opacity(0.035)) }
        }
    }
}
