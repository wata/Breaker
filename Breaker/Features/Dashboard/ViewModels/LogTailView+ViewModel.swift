import Foundation

extension LogTailView {
    @MainActor
    @Observable
    final class ViewModel {
        enum Content: Equatable {
            case loading
            case missing
            case empty
            case text(String)
            case failure(String)
        }

        private struct Loaded: Equatable {
            let path: String
            let stamp: LogReader.Stamp?
        }

        /**
         ログを開いている間に読み直す間隔。一覧の更新（60秒）を待たずに「今すぐ実行」の出力が届くのを見ていられる短さで、
         変わっていなければ属性を見るだけなので、この間隔で回しても負担にならない
         */
        static let followInterval = Duration.seconds(2)

        private(set) var content = Content.loading

        /// 最後に読めたときのファイルと目印。同じなら中身も同じなので読み直さない
        @ObservationIgnored private var loaded: Loaded?

        /**
         一覧の更新のたびに「読み込み中」に戻すとちらつくので、前の内容を出したまま差し替える。
         目印は読む前に取るので、読んでいる間に書き足されても次の確認で読み直す
         */
        func load(path: String, lineCount: Int) async {
            let current = Loaded(path: path, stamp: LogReader.stamp(of: path))
            guard current != loaded else { return }
            do {
                let text = try await LogReader.tail(of: path, lineCount: lineCount)
                // 出力を切り替えたあとに前のファイルの読み込みが終わっても、新しい方を上書きしない
                guard !Task.isCancelled else { return }
                content = text.map { $0.isEmpty ? .empty : .text($0) } ?? .missing
                loaded = current
            } catch {
                content = .failure(error.localizedDescription)
                loaded = nil
            }
        }

        /// 表示している間 `followInterval` ごとに読み直す。`.task` が取り消されると眠りが例外で終わり、そこで止まる
        func follow(path: String, lineCount: Int) async {
            while (try? await Task.sleep(for: Self.followInterval)) != nil {
                await load(path: path, lineCount: lineCount)
            }
        }
    }
}
