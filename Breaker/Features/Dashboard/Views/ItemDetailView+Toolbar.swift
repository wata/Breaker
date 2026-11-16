import SwiftUI

extension ItemDetailView {
    /**
     よく使う状態を変える操作はアイコンのボタンで並べ、それ以外（読み込み直すとファイルを開く操作）は1つのメニューにまとめる。
     ボタンの組は状態で変えず、できないものは無効にする。ツールバーのボタンは文字を出さないので、何をするかはツールチップで伝える
     */
    struct Toolbar: ToolbarContent {
        let itemID: MonitoredItem.ID
        let controls: [ItemAction]
        let promptAction: ItemAction?
        let secondaryControls: [ItemAction]
        let files: [ItemAction]
        /// ネットワーク項目のときだけ。計測は `ItemActionPerformer` ではなくスケジューラが受け持つので、操作の組とは別に渡す
        let measure: MeasureButton.Model?
        let isLocked: Bool
        let perform: (ItemAction) -> Void

        var body: some ToolbarContent {
            ToolbarItemGroup {
                if let measure {
                    MeasureButton(model: measure)
                }

                ForEach(controls) { action in
                    Button(action.title, systemImage: action.systemImage) {
                        perform(action)
                    }
                    .help(action.title)
                    .disabled(isLocked || !action.isEnabled)
                }

                if let promptAction {
                    CopyButton(action: promptAction, isLocked: isLocked, perform: perform)
                        // 詳細ペインは項目を切り替えても作り直されないので、前の項目のチェックマークを持ち越さない
                        .id(itemID)
                }

                if !secondaryControls.isEmpty || !files.isEmpty {
                    Menu("More", systemImage: "ellipsis.circle") {
                        ItemActionMenuItems(actions: secondaryControls, perform: perform)

                        if !secondaryControls.isEmpty && !files.isEmpty {
                            Divider()
                        }

                        ItemActionMenuItems(actions: files, perform: perform)
                    }
                    .help("More")
                    .disabled(isLocked)
                }
            }
        }
    }

    /**
     ネットワークの「今すぐ計測」。ほかの項目の「今すぐ実行」と同じくツールバーのアイコンにする。
     計測中・オフラインでは押せず、押せない理由と通信量はツールチップで伝える。約10秒かかるので、計測中は進み具合の印に替える
     */
    struct MeasureButton: View {
        struct Model {
            let scheduler: SpeedTestScheduler
            /// スケジューラが自動の計測を見送るのと同じ基準（揺れ止め前の接続の失敗も含む）
            let isOnline: Bool
        }

        let model: Model

        var body: some View {
            Button {
                Task {
                    await model.scheduler.measureNow()
                }
            } label: {
                if model.scheduler.isMeasuring {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Measure Now", systemImage: "speedometer")
                }
            }
            .help(help)
            .disabled(model.scheduler.isMeasuring || !model.isOnline)
        }

        private var help: String {
            let title = String(localized: "Measure Now", comment: "Button that runs a speed test now")
            let detail = if model.scheduler.isMeasuring {
                String(localized: "Measuring…", comment: "Shown while a speed test is running")
            } else if model.isOnline {
                String(localized: "Measures with networkQuality. Each speed test sends and receives about 300 MB.", comment: "Help tag of the Measure Now button in the network detail")
            } else {
                String(localized: "Connect to a network to measure.", comment: "Help tag of the Measure Now button while offline")
            }
            return "\(title)\n\(detail)"
        }
    }

    /**
     押してもクリップボードに入るだけで画面は何も変わらないので、しばらくチェックマークに変えてコピーできたことを伝える。
     チェックマークを出している間も押し直せる（ログが伸びていれば中身が変わる）
     */
    struct CopyButton: View {
        let action: ItemAction
        let isLocked: Bool
        let perform: (ItemAction) -> Void

        @State private var isCopied = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button(action.title, systemImage: isCopied ? "checkmark" : action.systemImage) {
                perform(action)
                isCopied = true
                // チェックマークは見えないと伝わらないので、VoiceOver には読み上げで伝える
                AccessibilityNotification.Announcement(String(localized: "Copied", comment: "VoiceOver announcement after the prompt for AI is copied to the clipboard")).post()
            }
            .help(help)
            .disabled(isLocked || !action.isEnabled)
            /**
             contentTransition はアニメーションの中でしか効かないので、チェックマークに変える時と戻す時の両方を isCopied で拾う。
             SF Symbols の効果が「視差効果を減らす」に自動で従うとはドキュメントに書かれていないので、オンなら切り替えるだけにする
             */
            .contentTransition(.symbolEffect(.replace))
            .animation(reduceMotion ? nil : .smooth, value: isCopied)
            // ボタンが消えたら（ほかの項目を選んだら）待つのもやめる
            .task(id: isCopied) {
                guard isCopied else { return }
                try? await Task.sleep(for: .seconds(2))
                isCopied = false
            }
        }

        /**
         正常な項目では無効のまま理由が分からないので、押せないときはいつ使えるかを添える。
         ほかのボタンと同じく名前も出さないと何のボタンか分からないので、条件で置き換えず次の行に足す
         */
        private var help: String {
            if action.isEnabled {
                return action.title
            } else {
                let condition = String(localized: "Available when the item has failed or needs attention", comment: "Tooltip line explaining when the Copy Prompt for AI button can be used")
                return "\(action.title)\n\(condition)"
            }
        }
    }
}
