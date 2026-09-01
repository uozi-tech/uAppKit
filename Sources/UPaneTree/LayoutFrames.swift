import Foundation
import CoreGraphics

// 摊平几何。目前只有 uTable 用：它的编辑区不递归建视图树，而是一次算出所有
// 矩形、用一个扁平 ZStack + offset 摆放。uTerm 仍走递归的 SplitContainerView。

/// 一个窗格在容器坐标系里的矩形。
public nonisolated struct PaneFrame: Equatable, Sendable {
    public let paneID: UUID
    public let rect: CGRect

    public init(paneID: UUID, rect: CGRect) {
        self.paneID = paneID
        self.rect = rect
    }
}

/// 一条分隔条的位置 + 它所属 `SplitNode` 的比例与可用长度。
public nonisolated struct SplitterFrame: Equatable, Sendable {
    public let splitID: UUID
    public let direction: SplitDirection
    public let rect: CGRect
    public let fraction: Double
    /// 父容器沿分屏轴的总长度 —— 拖动时把像素位移换算成比例。
    public let totalLength: CGFloat

    public init(splitID: UUID, direction: SplitDirection, rect: CGRect,
                fraction: Double, totalLength: CGFloat) {
        self.splitID = splitID
        self.direction = direction
        self.rect = rect
        self.fraction = fraction
        self.totalLength = totalLength
    }
}

/// 整棵树摊平后的几何。
public nonisolated struct LayoutFrames: Equatable, Sendable {
    public var panes: [PaneFrame] = []
    public var splitters: [SplitterFrame] = []

    public init(panes: [PaneFrame] = [], splitters: [SplitterFrame] = []) {
        self.panes = panes
        self.splitters = splitters
    }
}

extension LayoutNode {
    /// 分隔条厚度（与调用方分隔条把手的命中区一致）。
    public nonisolated static let splitterThickness: CGFloat = 6

    /// 把递归树摊平成「每个窗格一个矩形 + 每条分隔条一个矩形」。
    ///
    /// 调用方据此用一个扁平 ZStack 渲染所有窗格，而不是把窗格视图嵌进递归的
    /// 容器视图里：递归嵌套时，分屏/合屏会改变每个窗格在视图树里的路径（且
    /// AnyView 抹掉了具体类型），SwiftUI 只能把整棵子树拆掉重建 —— 大表的
    /// NSTableView 连同数据一起重来，就是「点分屏卡一下、关分屏又卡一下」的
    /// 来源。摊平后窗格的身份只由 paneID 决定，分屏只是改 frame，重排而不重建。
    public nonisolated func frames(in rect: CGRect) -> LayoutFrames {
        var out = LayoutFrames()
        accumulateFrames(into: &out, rect: rect)
        return out
    }

    private nonisolated func accumulateFrames(into out: inout LayoutFrames, rect: CGRect) {
        switch self {
        case .leaf(let paneID):
            out.panes.append(PaneFrame(paneID: paneID, rect: rect))
        case .split(let s):
            let thickness = LayoutNode.splitterThickness
            let total = s.direction == .horizontal ? rect.width : rect.height
            let firstLen = max(0, total * s.fraction)
            let secondLen = max(0, total - firstLen - thickness)
            if s.direction == .horizontal {
                s.first.accumulateFrames(into: &out, rect: CGRect(
                    x: rect.minX, y: rect.minY, width: firstLen, height: rect.height))
                out.splitters.append(SplitterFrame(
                    splitID: s.id, direction: .horizontal,
                    rect: CGRect(x: rect.minX + firstLen, y: rect.minY,
                                 width: thickness, height: rect.height),
                    fraction: s.fraction, totalLength: total))
                s.second.accumulateFrames(into: &out, rect: CGRect(
                    x: rect.minX + firstLen + thickness, y: rect.minY,
                    width: secondLen, height: rect.height))
            } else {
                s.first.accumulateFrames(into: &out, rect: CGRect(
                    x: rect.minX, y: rect.minY, width: rect.width, height: firstLen))
                out.splitters.append(SplitterFrame(
                    splitID: s.id, direction: .vertical,
                    rect: CGRect(x: rect.minX, y: rect.minY + firstLen,
                                 width: rect.width, height: thickness),
                    fraction: s.fraction, totalLength: total))
                s.second.accumulateFrames(into: &out, rect: CGRect(
                    x: rect.minX, y: rect.minY + firstLen + thickness,
                    width: rect.width, height: secondLen))
            }
        }
    }
}
