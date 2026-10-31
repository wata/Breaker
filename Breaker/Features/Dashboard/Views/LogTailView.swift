import SwiftUI

/**
 ジョブのログの末尾。Form の Section として置く。`refreshDate` が変わるたびと、表示している間は `ViewModel.followInterval` ごとに読み直す。
 標準出力と標準エラーが別のファイルなら見出しの切り替えで選ぶ。パスは見出しに並べず、「Finder で表示」のツールチップで見せる。
 どの出力もまだ無いときは置かない（ジョブの節の「ログ」の行で伝える）
 */
struct LogTailView: View {
    static let lineCount = 200

    let logs: [MonitoredItem.LogFile]
    let refreshDate: Date?
    let isLocked: Bool
    let perform: (ItemAction) -> Void

    @State private var selection: MonitoredItem.LogFile
    @State private var viewModel = ViewModel()

    init(
        logs: [MonitoredItem.LogFile],
        selection: MonitoredItem.LogFile,
        refreshDate: Date?,
        isLocked: Bool,
        perform: @escaping (ItemAction) -> Void
    ) {
        self.logs = logs
        self.refreshDate = refreshDate
        self.isLocked = isLocked
        self.perform = perform
        _selection = State(initialValue: selection)
    }

    var body: some View {
        // 空のファイルに出力が届いたときも描き直されるよう、読み込んだ内容は出力の有無によらず必ず参照する
        let loaded = viewModel.content
        let content = selection.hasOutput() ? loaded : .empty
        Section {
            Group {
                switch content {
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)

                case .missing, .empty:
                    Text("No Output")
                        .foregroundStyle(.secondary)

                case .text(let text):
                    LogText(text: text)

                case .failure(let message):
                    Text(message)
                        .foregroundStyle(Color.Status.failure)
                }
            }
            .task(id: LoadKey(path: selection.path, refreshDate: refreshDate)) {
                await viewModel.load(path: selection.path, lineCount: Self.lineCount)
                await viewModel.follow(path: selection.path, lineCount: Self.lineCount)
            }
        } header: {
            HStack(spacing: Spacing.tight) {
                Text("Log")

                Spacer(minLength: Spacing.standard)

                if logs.count > 1 {
                    Picker("Output", selection: $selection) {
                        ForEach(logs, id: \.self) { log in
                            Text(log.title)
                                .tag(log)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()
                }

                ItemDetailView.RevealButton(
                    url: URL(filePath: selection.path),
                    isLocked: isLocked,
                    help: selection.path.abbreviatingHome,
                    perform: perform
                )
            }
        }
    }
}

extension LogTailView {
    struct LoadKey: Hashable {
        let path: String
        let refreshDate: Date?
    }

    /**
     末尾から読み始めるよう、最初から下端にスクロールしておく。Form の行がすでに地と角丸を持つので、枠は重ねない。
     短いログで上が空いた板にならないよう、高さは中身に合わせて縮め、`Layout.logMaxHeight` を超えたときだけスクロールさせる。
     失敗の原因を探しやすいよう、詳細の概要の原因と同じ判定でエラーらしい行に薄い失敗の色を敷く。
     ログの塊が概要の状態より目立たないよう本文は薄くし、エラーらしい行だけ本文の色に戻して拾いやすくする。
     文字まで赤くすると概要の原因と競うので赤くはしない。
     読み直して行が増えたとき、下端にいれば下端に付いていき、上に戻って読んでいるときは位置を動かさない
     */
    struct LogText: View {
        /// 下端とみなす余裕。端数のずれで下端にいないと判定されないようにする
        private static let bottomTolerance = Spacing.micro

        let text: String

        @State private var position = ScrollPosition()

        var body: some View {
            let lines = Self.lines(of: text)

            ScrollView {
                // 選んでまとめてコピーできるよう本文は1つの Text のまま描き、行の地だけを後ろに並べる
                Text(Self.highlighted(lines))
                    .font(.Mono.regular)
                    .foregroundStyle(.secondary)
                    .lineSpacing(Spacing.hairline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(alignment: .top) {
                        ErrorBands(lines: lines)
                    }
            }
            .scrollPosition($position)
            // 大きさが変わったときの位置合わせは下の判定で行う。下端を基準に残すと、上で読んでいる行まで押し流されるので最初の位置だけに使う
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Extent.self) { geometry in
                Extent(contentHeight: geometry.contentSize.height, visibleMaxY: geometry.visibleRect.maxY)
            } action: { old, new in
                guard
                    new.contentHeight != old.contentHeight,
                    old.visibleMaxY >= old.contentHeight - Self.bottomTolerance
                else {
                    return
                }
                position.scrollTo(edge: .bottom)
            }
            .scrollBounceBehavior(.basedOnSize)
            // 高さを決めずに測らせて中身の高さを受け取り、上限で切る
            .frame(maxHeight: Layout.logMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }

        static func lines(of text: String) -> [Line] {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return zip(lines, LogErrorLine.flags(of: lines)).enumerated().map { index, element in
                Line(id: index, text: String(element.0), isError: element.1)
            }
        }

        static func highlighted(_ lines: [Line]) -> AttributedString {
            lines.reduce(into: AttributedString()) { result, line in
                if line.id > 0 {
                    result.append(AttributedString("\n"))
                }
                var part = AttributedString(line.text)
                if line.isError {
                    part.foregroundColor = Color.primary
                }
                result.append(part)
            }
        }
    }

    /// 下端に付いていくかを決めるための、中身の高さと見えている範囲の下端
    struct Extent: Equatable {
        let contentHeight: CGFloat
        let visibleMaxY: CGFloat
    }

    struct Line: Identifiable {
        /// 行番号。同じ本文の中では変わらない
        let id: Int
        let text: String
        let isError: Bool
    }

    /**
     エラーらしい行の地を、文字の幅ではなく行の幅いっぱいに敷く。本文と同じ字形・行間で見えない文字を並べ、
     折り返した行も本文と同じ高さになるようにする（空の行は高さが無くなるので空白を入れる）
     */
    struct ErrorBands: View {
        let lines: [Line]

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.Mono.regular)
                        .lineSpacing(Spacing.hairline)
                        .hidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.isError ? Color.logErrorLine : .clear)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// 読み込みは非同期で静的なプレビューには間に合わないので、表示部分だけをサンプルの文字列で確かめる
#Preview("Log Text") {
    Form {
        Section("Log") {
            LogTailView.LogText(text: MonitoredItem.sampleLogText)
        }
    }
    .formStyle(.grouped)
    .frame(width: Layout.detailMinWidth + Layout.sidebarIdealWidth)
}
