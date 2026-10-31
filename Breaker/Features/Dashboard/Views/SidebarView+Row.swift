import SwiftUI

extension SidebarView {
    /**
     行は名前と、その下の1行だけにそろえ、行の高さを一定にして上から目で追えるようにする（2行目の選び方は `rowDetail`）。
     理由は補足（パスや日時・ログの行）を除いた短い本文だけにして、行の幅で意味が読めるようにする。補足を含めた全文はツールチップで見せる
     */
    struct Row: View {
        let item: MonitoredItem
        /// 要確認の節では種類が混ざるので、2行目の理由の前に種類を添える
        var showsKind = false

        @Environment(\.sidebarRowSize) private var rowSize

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                StatusSymbol(item: item)

                VStack(alignment: .leading) {
                    // 大きさは指定せず、システム設定のサイドバーの大きさに従わせる
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let detail = item.rowDetail(now: .now, showsKind: showsKind) {
                        Text(detail)
                            .font(.SidebarDetail.regular(for: rowSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .help(item.rowHelp)
        }
    }
}

extension MonitoredItem {
    /**
     サイドバーの行の2行目。理由のある状態（異常・停止・未確認）は理由、正常・実行中は次回、次回が無ければ前回を出す。
     前回と次回を並べるのは詳細の概要に任せる。予定で動かない種類の正常（フォルダアクション・SwiftBar・起動中のアプリ）は、
     状態の記号のほかに言うことが無いので2行目を出さない
     */
    func rowDetail(now: Date, showsKind: Bool, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        if let reason = status.reason {
            return showsKind ? Self.joined(kind.shortTitle, reason, locale: locale) : reason
        }
        guard let dates = runDates(now: now) else {
            return nil
        }
        return dates.next.map { Self.nextRunText($0, now: now, calendar: calendar, locale: locale) }
            ?? dates.last.map { Self.lastRunText($0, style: .relative, now: now, calendar: calendar, locale: locale) }
    }

    /**
     サイドバーの行のツールチップ。理由がなければ状態名を出す。
     launchd ジョブは、ユーザーとシステムの両方に同じラベルのジョブがあると行の見た目では見分けられないので、種類を前に添える
     */
    var rowHelp: String {
        let text = status.fullReason ?? status.title
        if case .launchdJob(let job) = detail {
            return Self.joined(job.origin.title, text)
        } else {
            return text
        }
    }

    /// サイドバーで、種類と状態・理由をつなぐ
    private static func joined(_ kind: String, _ text: String, locale: Locale = .current) -> String {
        String(
            localized: LocalizedStringResource(
                "\(kind) · \(text)",
                comment: "Sidebar: the kind of item, then its status or reason, e.g. User Agent · Exit code 1 (tooltip) or launchd · Exit code 1 (Needs Attention section)"
            ),
            language: locale
        )
    }
}

#Preview("Medium") { rowPreview(.medium) }
#Preview("Small") { rowPreview(.small) }
#Preview("Large") { rowPreview(.large) }

/// システム設定の「サイドバーのアイコンのサイズ」の小・中・大を切り替えて見比べる
@MainActor private func rowPreview(_ rowSize: SidebarRowSize) -> some View {
    List(MonitoredItem.samples) { item in
        SidebarView.Row(item: item)
    }
    .listStyle(.sidebar)
    .environment(\.sidebarRowSize, rowSize)
    .frame(width: Layout.sidebarIdealWidth)
}

