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
}
