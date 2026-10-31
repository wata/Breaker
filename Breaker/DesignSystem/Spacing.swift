import SwiftUI

/// 4pt grid-based spacing system (値は macOS の標準コントロール間隔に合わせている)
enum Spacing {
    /// 2pt - Hairline spacing (ログ本文の行間)
    static let hairline: CGFloat = 2

    /// 4pt - Micro spacing (状態ドットと名前の間など)
    static let micro: CGFloat = 4

    /// 8pt - Tight spacing (within components)
    static let tight: CGFloat = 8

    /// 12pt - Standard spacing (between related elements)
    static let standard: CGFloat = 12

    /// 16pt - Comfortable spacing (section padding)
    static let comfortable: CGFloat = 16

    /// 24pt - Spacious (between sections)
    static let spacious: CGFloat = 24
}
