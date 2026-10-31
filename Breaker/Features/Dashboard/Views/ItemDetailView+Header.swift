import SwiftUI

extension ItemDetailView {
    /**
     項目名はウインドウのタイトルに出すので、ここでは状態・原因と、状態から戻す操作、説明を出す。
     失敗の通知から来たときに何が起きたかを最初に読めるよう、状態を最上段に置き、説明はその下に回す
     */
    struct Header: View {
        let item: MonitoredItem
        let isActing: Bool
        let isLocked: Bool
        let note: String?
        let refreshDate: Date?
        let saveNote: (String) -> Void
        let perform: (ItemAction) -> Void

        /// 失敗・警告のときに原因の1行を拾うためのログ。下のログの節とは別に読む（選んでいる出力に左右されないよう、常に標準エラーを読む）
        @State private var errorLogViewModel = LogTailView.ViewModel()

        var body: some View {
            let errorLog = item.status.isAbnormal ? item.errorLog : nil

            Section {
                VStack(alignment: .leading, spacing: Spacing.micro) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                        // 色はシンボルだけに持たせ、見出しは本文の色で落ち着かせる
                        Image(systemName: item.statusSystemImage)
                            .foregroundStyle(item.status.color)
                            .accessibilityLabel(item.status.title)

                        Text(item.statusSummary)
                            .textSelection(.enabled)

                        Spacer()

                        // 操作の結果は状態に出るので、くるくるも状態の隣に置く
                        if isActing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .font(.Title.semiBold)

                    if let statusNote = item.statusNote {
                        Text(statusNote)
                            .font(.Body.regular)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    /**
                     補足があればそれが原因を言っている（ログのエラーなら補足がその行）ので、同じことを二度出さない。
                     正常なジョブの標準エラーには直す前の失敗が残っていることがあるので、それを原因のように見せないよう失敗のときだけ出す
                     */
                    if
                        item.status.isFailed,
                        item.status.note == nil,
                        case .text(let text) = errorLogViewModel.content,
                        let cause = LogErrorLine.last(in: text)
                    {
                        Text(cause)
                            .font(.Body.regular)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }

                    if let summary = item.runSummary(now: .now, lastRunStyle: .absolute) {
                        Text(summary)
                            .font(.Body.regular)
                            .foregroundStyle(.secondary)
                    }

                    // ツールバーの操作が無効になっている理由を、概要を読んだだけで分かるようにする
                    if item.isViewOnly {
                        Label("View only: changing this job requires administrator privileges", systemImage: "lock")
                            .font(.Body.regular)
                            .foregroundStyle(.secondary)
                    }

                    // 何が起きたかを読んだ流れで押せるよう、原因と日時の後に置く
                    if let recovery = item.recoveryAction {
                        Button(recovery.title) {
                            perform(recovery)
                        }
                        .disabled(isLocked || !recovery.isEnabled)
                        .padding(.top, Spacing.micro)
                    }

                    NoteEditor(note: note, autoDescription: item.autoDescription, saveNote: saveNote)
                        .padding(.top, Spacing.tight)
                }
                .task(id: errorLog.map { LogTailView.LoadKey(path: $0.path, refreshDate: refreshDate) }) {
                    guard let errorLog else { return }
                    await errorLogViewModel.load(path: errorLog.path, lineCount: LogTailView.lineCount)
                }
            }
        }
    }

    /**
     開いただけで入力欄にキャレットが立つと、うっかり打った文字でメモを書き換えてしまうので、ふだんはただの文字として見せ、
     クリックしたときだけ入力欄に切り替える。打つたびに保存せず、確定したとき（Enter・フォーカスが外れた・ビューが消えた）だけ
     `saveNote` に渡す。Esc は打った分を捨てて戻す。項目を切り替えたら作り直されて読み込み直す
     */
    struct NoteEditor: View {
        let autoDescription: String?
        let saveNote: (String) -> Void

        @State private var draft: String
        /// 最後に保存した内容。Enter で確定した後にフォーカスが外れたときなど、同じ内容を何度も保存しないよう比べる
        @State private var saved: String
        @State private var isEditing = false
        @FocusState private var isFocused: Bool

        init(note: String?, autoDescription: String?, saveNote: @escaping (String) -> Void) {
            self.autoDescription = autoDescription
            self.saveNote = saveNote
            _draft = State(initialValue: note ?? "")
            _saved = State(initialValue: note ?? "")
        }

        var body: some View {
            Group {
                if isEditing {
                    TextField("Description", text: $draft, prompt: Text("Add Description"))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .focused($isFocused)
                        .onAppear {
                            isFocused = true
                        }
                        .onSubmit(finish)
                        .onExitCommand {
                            draft = saved
                            isEditing = false
                        }
                        .onChange(of: isFocused) { _, isFocused in
                            if !isFocused {
                                finish()
                            }
                        }
                        // 入力中に別の項目を選ぶと、フォーカスが外れる前にこのビューが消えることがある
                        .onDisappear(perform: commit)
                } else {
                    /**
                     メモ → 自動で取った説明 → 書き足す案内の順に、どれか1つだけを同じ位置に出す。
                     自動の説明は補助なので薄くし、1行の入力欄に収まらず切れないよう、ここでは折り返して全文を出す
                     */
                    Button {
                        isEditing = true
                    } label: {
                        Group {
                            switch (draft.isEmpty, autoDescription) {
                            case (false, _):
                                Text(draft)

                            case (true, let autoDescription?):
                                Text(autoDescription)
                                    .foregroundStyle(.secondary)

                            case (true, nil):
                                Text("Add Description")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Click to edit")
                }
            }
            .font(.Body.regular)
        }

        private func finish() {
            commit()
            isEditing = false
        }

        private func commit() {
            guard draft != saved else { return }
            saveNote(draft)
            saved = draft
        }
    }
}

extension MonitoredItem {
    /**
     詳細の概要の状態の1文。動いているジョブは、Activity Monitor などで探せるよう PID を添える。
     Breaker が理由に添えた補足（`ItemStatus` の `note`。パス・日時・ログの行）は、大きな見出しが2〜3行に折り返さないよう、
     見出しには入れず `statusNote` で副行に回す。どの状態でも「短い見出し＋副行」の形にそろえる
     */
    var statusSummary: String {
        if
            case (.running, .launchdJob(let job)) = (status, detail),
            let pid = job.service?.pid
        {
            String(localized: "\(status.summary) (PID \(pid))", comment: "Status of a running launchd job followed by its process ID")
        } else {
            status.summary
        }
    }

    /// 見出しから外した補足。概要で状態の下に薄く出す。無効にしたジョブは、定義ファイルの名前からは分からない止め方だけを出す
    var statusNote: String? {
        if
            case (.inactive, .launchdJob(let job)) = (status, detail),
            job.isDisabled
        {
            // `.plist.disabled` は定義ファイルの行に出ているので言わない
            job.isDisabledLabel && !job.isDisabledFile ? String(localized: "Via launchctl disable", comment: "Shown under the Disabled status of a launchd job that was turned off with launchctl disable") : nil
        } else {
            status.note
        }
    }

    /// `/Library` の launchd ジョブ。操作と書き換えには管理者権限が要るので、Breaker では状態を見るだけにする
    var isViewOnly: Bool {
        if case .launchdJob(let job) = detail {
            !job.origin.isManageable
        } else {
            false
        }
    }
}
