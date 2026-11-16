import Foundation

extension String {
    /**
     `locale` の言語で訳を引く。Foundation の `String(localized:locale:)` の locale は補間する値の書式にしか使われず、
     訳の言語は選べないので、`LocalizedStringResource` の locale を通す。
     日付や要約を組み立てる関数がテストで日本語の訳も確かめられるよう、locale を受け取る関数の中だけで使う
     */
    init(localized resource: LocalizedStringResource, language locale: Locale) {
        var resource = resource
        resource.locale = locale
        self.init(localized: resource)
    }

    /// `Failed (Exit code 1)` のように括弧の補足を続ける。日本語では全角の括弧にする
    static func parenthesized(_ text: String, _ note: String, locale: Locale = .current) -> String {
        String(
            localized: LocalizedStringResource(
                "\(text) (\(note))",
                comment: "Text followed by a parenthetical, e.g. Failed (Exit code 1) or Folder not found (it may not be mounted)"
            ),
            language: locale
        )
    }
}
