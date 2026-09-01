import SwiftUI

/// Design tokens for uTable's SwiftUI surface. The whole UI layer should pull
/// padding, opacity, corner-radius and border-width values from here instead of
/// inlining magic numbers, so that visual rhythm stays consistent across modules.
public enum DesignTokens {
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 8
        public static let l: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 24
    }

    public enum Opacity {
        public static let subtle: Double = 0.07
        public static let pressed: Double = 0.12
        public static let selectedTint: Double = 0.18
        public static let dropTarget: Double = 0.28
        public static let muted: Double = 0.55
        public static let disabled: Double = 0.4
    }

    public enum Radius {
        public static let chip: CGFloat = 5
        public static let field: CGFloat = 6
        public static let card: CGFloat = 8
        public static let bubble: CGFloat = 10
    }

    public enum Sidebar {
        public static let itemHeight: CGFloat = 26
        public static let itemFontSize: CGFloat = 12
        public static let itemSpacing: CGFloat = 1
        public static let itemRadius: CGFloat = 8
        public static let listHorizontalMargin: CGFloat = 4
        public static let rowHorizontalPadding: CGFloat = 6
        public static let disclosureWidth: CGFloat = 10
        public static let iconWidth: CGFloat = 18
        public static let iconSpacing: CGFloat = 6
    }

    public enum Border {
        public static let hairline: CGFloat = 0.5
        public static let field: CGFloat = 0.7
        public static let strong: CGFloat = 1.0
    }

    public enum AnimationDuration {
        public static let interaction: Double = 0.12
    }
}

public extension Animation {
    /// Standard hover / press / selection animation. 0.12s easeInOut.
    static let interaction: Animation = .easeInOut(duration: DesignTokens.AnimationDuration.interaction)
}
