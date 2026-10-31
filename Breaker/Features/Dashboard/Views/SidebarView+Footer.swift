import SwiftUI

extension SidebarView {
    /**
     下端の帯に「◯分前に更新」と更新のボタンを並べ、いつ取得したかを見たその場で取り直せるようにする。
     異常の件数はウインドウの副題に出す（下端は目が最後に届く場所なので置かない）。
     経過時間の表示は分ごとに描き直すため、サイドバー本体の描き直しが及ばないよう TimelineView はここに閉じ込める
     */
    struct Footer: View {
        let lastRefreshDate: Date?
        let isRefreshing: Bool
        let refreshAction: () -> Void

        var body: some View {
            // 表示したまま時間が経っても「5分前」が古くならないよう、分が変わるたびにこの文字だけ描き直す
            TimelineView(.everyMinute) { context in
                let status = isRefreshing ? String(localized: "Refreshing…") : lastRefreshDate.map { Self.lastRefreshText($0, now: context.date) }

                HStack(spacing: Spacing.micro) {
                    if let status {
                        Text(status)
                            .font(.Small.regular.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    RefreshButton(isRefreshing: isRefreshing, action: refreshAction)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Spacing.tight)
            .padding(.vertical, Spacing.tight)
        }

        /**
         メールと同じく、今日の更新は「たった今」「5分前」のように経過で示し、それより前は日時を出す（直近なので年は省く）。
         Date.RelativeFormatStyle の ja は「5 分前」と数字の後に空白が入るため、分と時間の数だけ求めて文言を組む
         */
        static func lastRefreshText(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
            guard calendar.isDate(date, inSameDayAs: now) else {
                var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute().locale(locale)
                style.timeZone = calendar.timeZone
                return String(localized: "Updated \(date.formatted(style))", language: locale)
            }

            let elapsed = calendar.dateComponents([.hour, .minute], from: date, to: now)
            // 時計が戻って未来の日時になった場合も「たった今」に含める
            switch (elapsed.hour ?? 0, elapsed.minute ?? 0) {
            case (...0, ...0):
                return String(localized: "Updated just now", language: locale)

            case let (...0, minutes):
                return String(localized: "Updated \(minutes) min ago", language: locale)

            case let (hours, _):
                return String(localized: "Updated \(hours) hr ago", language: locale)
            }
        }
    }

    /**
     取得中は標準のスピナーに差し替える。ボタンごと差し替えると幅が変わって隣の文字がずれるため、中身だけ差し替える。
     ⌘R はメニューバーの「表示 > 更新」が受け持つので、ここには付けない（二重に付けるとどちらが効くか決まらない）
     */
    struct RefreshButton: View {
        let isRefreshing: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isRefreshing)
            .help(isRefreshing ? "Refreshing…" : "Refresh all items (⌘R)")
        }
    }
}

#Preview("Footer") {
    VStack(spacing: Spacing.standard) {
        SidebarView.Footer(lastRefreshDate: .now.addingTimeInterval(-29 * 60), isRefreshing: false, refreshAction: {})

        SidebarView.Footer(lastRefreshDate: .now, isRefreshing: true, refreshAction: {})
    }
    .frame(width: Layout.sidebarIdealWidth)
}
