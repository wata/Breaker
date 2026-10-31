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

        private(set) var content = Content.loading

        /// 一覧の更新のたびに「読み込み中」に戻すとちらつくので、前の内容を出したまま差し替える
        func load(path: String, lineCount: Int) async {
            do {
                let text = try await LogReader.tail(of: path, lineCount: lineCount)
                content = text.map { $0.isEmpty ? .empty : .text($0) } ?? .missing
            } catch {
                content = .failure(error.localizedDescription)
            }
        }
    }
}
