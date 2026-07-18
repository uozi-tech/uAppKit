import SwiftUI

/// # UIcon 字形表
///
/// 每个字形都是从设计稿 `uTable.dc.html` 里**原样抄录**的 SVG 元素（保留其
/// viewBox、stroke 宽度、linecap / linejoin）。路线 C：只收录设计独有 / 品牌型 /
/// SF 缺失的图标；通用控件（`plus` `trash` `chevron.*` `magnifyingglass` `xmark`
/// `arrow.clockwise` `play.fill` `arrow.right` 等）仍用 SF Symbol。
public extension UIconGlyph {

    // MARK: 导航栏（56px rail · design ── Nav rail ──）

    static let navWorkspace = UIconGlyph(18, [
        .rect(2.5, 2.5, 13, 13, r: 2, sw: 1.3),
        .path("M2.5 6.5h13M7 6.5v9", w: 1.1),
    ])
    static let navMigration = UIconGlyph(18, [
        .path("M3 5.5h7M7.5 3L10 5.5 7.5 8", w: 1.3, cap: .round, join: .round),
        .path("M15 12.5H8M10.5 10L8 12.5l2.5 2.5", w: 1.3, cap: .round, join: .round),
    ])
    static let navStorage = UIconGlyph(18, [
        .ellipse(9, 4, 5.5, 2.2, sw: 1.3),
        .path("M3.5 4v9.8c0 1.2 2.5 2.2 5.5 2.2s5.5-1 5.5-2.2V4M3.5 9c0 1.2 2.5 2.2 5.5 2.2s5.5-1 5.5-2.2", w: 1.3),
    ])
    static let navPerms = UIconGlyph(18, [
        .path("M9 1.8l5.7 2.1v4.3c0 3.5-2.3 6.1-5.7 7.6-3.4-1.5-5.7-4.1-5.7-7.6V3.9L9 1.8z", w: 1.3, join: .round),
        .path("M6.7 8.9l1.7 1.7 3-3.4", w: 1.3, cap: .round, join: .round),
    ])
    /// 设计：箭头**向下**入托盘（导出 = 下载语义）。
    static let navExport = UIconGlyph(18, [
        .path("M9 2.5v6.5M6 6l3 3 3-3", w: 1.3, cap: .round, join: .round),
        .path("M3.5 12v1.5a1 1 0 001 1h9a1 1 0 001-1V12", w: 1.3, cap: .round),
    ])
    /// 设计：箭头**向上**入托盘（导入 = 上传语义）。
    static let navImport = UIconGlyph(18, [
        .path("M9 9V2.5M6 5.5l3-3 3 3", w: 1.3, cap: .round, join: .round),
        .path("M3.5 12v1.5a1 1 0 001 1h9a1 1 0 001-1V12", w: 1.3, cap: .round),
    ])
    static let navSettings = UIconGlyph(20, [
        .circle(10, 10, 2.6, sw: 1.3),
        .path("M10 1.8v2.1M10 16.1v2.1M18.2 10h-2.1M3.9 10H1.8M15.8 4.2l-1.5 1.5M5.7 14.3l-1.5 1.5M15.8 15.8l-1.5-1.5M5.7 5.7L4.2 4.2", w: 1.3, cap: .round),
    ])

    // MARK: 对象类型（schema tree · tabs · 新建菜单）

    static let objTable = UIconGlyph(14, [
        .rect(1.5, 2, 11, 10, r: 1.4, sw: 1.2),
        .path("M1.5 5h11M5 5v7", w: 1),
    ])
    static let objView = UIconGlyph(14, [
        .path("M1 7s2.2-3.8 6-3.8S13 7 13 7s-2.2 3.8-6 3.8S1 7 1 7z", w: 1.1),
        .circle(7, 7, 1.6, sw: 1.1),
    ])
    static let objFunc = UIconGlyph(14, [
        .path("M8.5 2.5h-1a2 2 0 00-2 2v5a2 2 0 01-2 2M4 7h5", w: 1.2, cap: .round),
    ])
    /// TimescaleDB 超表：方块 + 时钟。
    static let objHyper = UIconGlyph(14, [
        .rect(1.3, 1.5, 7.7, 7.7, r: 1.3, sw: 1.1),
        .circle(9.6, 9.6, 3.2, sw: 1.1),
        .path("M9.6 8.1v1.6l1 .6", w: 1, cap: .round),
    ])
    /// 连续聚合：柱状图。
    static let objCagg = UIconGlyph(14, [
        .path("M2.5 11.5v-2.5M6 11.5v-6M9.5 11.5v-4M13 11.5V3", w: 1.4, cap: .round),
    ])

    // MARK: 编辑器标签 & 拆分

    static let tabSql = UIconGlyph(16, [
        .rect(1.5, 2.5, 13, 11, r: 2, sw: 1.2),
        .path("M4 6l2 1.8L4 9.6M7.6 10h4", w: 1.2, cap: .round, join: .round),
    ])
    static let tabStructure = UIconGlyph(16, [
        .rect(2, 2.5, 12, 11, r: 1.5, sw: 1.2),
        .path("M2 6h12M6 6v7.5", w: 1.1),
    ])
    static let tabSplitRight = UIconGlyph(16, [
        .rect(2, 2.5, 12, 11, r: 1.5, sw: 1.2),
        .path("M8 2.5v11", w: 1.2),
    ])

    // MARK: 数据工具栏（设计独有造型）

    /// 保存 = 软盘（SF 无对应；且原 `square.and.arrow.down` 与导出箭头撞车）。
    static let toolSave = UIconGlyph(12, [
        .path("M2.5 1.5h6L10.5 3.5v7h-9z", w: 1.1, join: .round),
        .path("M4 1.5v3h3.5v-3M4 10.5V7.5h4v3", w: 1.1, join: .round),
    ])
    /// 收藏书签（design 保存查询 / 已保存查询行；SF `bookmark` 比例与设计稿不符）。
    static let bookmark = UIconGlyph(14, [
        .path("M3.5 1.5h7a1 1 0 011 1v10l-4.5-3-4.5 3v-10a1 1 0 011-1z", w: 1.2, join: .round),
    ])
    static let toolUndo = UIconGlyph(12, [
        .path("M3.5 4.5H8a2.5 2.5 0 010 5H4.5M3.5 4.5l2-2M3.5 4.5l2 2", w: 1.1, cap: .round, join: .round),
    ])
    /// 筛选 = 漏斗。
    static let toolFilter = UIconGlyph(12, [
        .path("M1.5 2.5h9L7 6.5v3.5l-2-1V6.5z", w: 1.1, join: .round),
    ])
    static let toolTrash = UIconGlyph(12, [
        .path("M2.5 3.5h7M4.2 3.5V2.4h3.6v1.1M3.3 3.5l.4 6h4.6l.4-6", w: 1.1, cap: .round, join: .round),
    ])

    // MARK: SQL 编辑器

    // 注：AI 助手 / Agent 图标按用户要求保留 SF `sparkles`，故不自绘星形。

    /// 只读挂锁（描边，替换各处 `lock.fill`）。
    static let lockOutline = UIconGlyph(14, [
        .rect(3, 6.2, 8, 5.3, r: 1.3, sw: 1.2),
        .path("M4.8 6.2V4.5a2.2 2.2 0 014.4 0v1.7", w: 1.2),
    ])

    // MARK: 行右键菜单 / 编辑弹窗

    static let editPencil = UIconGlyph(14, [
        .path("M9.5 2.5l2 2L5 11l-2.5.5L3 9l6.5-6.5z", w: 1.2, join: .round),
    ])
    static let copyRow = UIconGlyph(14, [
        .rect(3, 3, 8, 8, r: 1.4, sw: 1.2),
        .path("M5 3V2a1 1 0 011-1h6a1 1 0 011 1v6a1 1 0 01-1 1h-1", w: 1.2),
    ])
    static let copyJson = UIconGlyph(14, [
        .path("M5.6 2C4.2 2 4.4 3.4 4.4 4.6c0 1.1-.5 2.4-1.9 2.4 1.4 0 1.9 1.3 1.9 2.4 0 1.2-.2 2.6 1.2 2.6M8.4 2c1.4 0 1.2 1.4 1.2 2.6 0 1.1.5 2.4 1.9 2.4-1.4 0-1.9 1.3-1.9 2.4 0 1.2.2 2.6-1.2 2.6", w: 1.1, cap: .round, join: .round),
    ])
    static let deleteRow = UIconGlyph(14, [
        .path("M3 4h8M5.2 4V2.8h3.6V4M4 4l.5 7h5L10 4", w: 1.2, cap: .round),
    ])

    // MARK: AI 面板 / 标题栏 / 状态栏

    static let insight = UIconGlyph(14, [
        .path("M7 1v2M7 11v2M1 7h2M11 7h2M2.8 2.8l1.4 1.4M9.8 9.8l1.4 1.4M11.2 2.8L9.8 4.2M4.2 9.8l-1.4 1.4", w: 1.1, cap: .round),
        .circle(7, 7, 2.3, sw: 1.1),
    ])
    static let sendArrow = UIconGlyph(14, [
        .path("M2 7h9M7 3l4 4-4 4", w: 1.6, cap: .round, join: .round),
    ])
    /// 数据库柱体（替换 `cylinder.split.1x2`）。
    static let database = UIconGlyph(12, [
        .ellipse(6, 3, 4, 1.6, sw: 1),
        .path("M2 3v6c0 .9 1.8 1.6 4 1.6s4-.7 4-1.6V3", w: 1),
    ])
    static let power = UIconGlyph(14, [
        .path("M7 1.6v5.2M4 3.2a5 5 0 106 0", w: 1.4, cap: .round),
    ])
    /// SSH 跳板隧道拱门（替换 `arrow.triangle.branch`）。
    static let jumpTunnel = UIconGlyph(12, [
        .path("M2 9V5.5a4 4 0 018 0V9M2 9h8M3.5 9v1.5M8.5 9v1.5", w: 1, cap: .round),
    ])

    // MARK: 设置分类图标（design uTable-Settings CATS，8 枚成套）

    static let setGeneral = UIconGlyph(18, [
        .rect(2.5, 2.5, 13, 13, r: 3, sw: 1.3),
        .path("M6 6.5h6M6 9h6M6 11.5h3.5", w: 1.3, cap: .round),
    ])
    static let setAppearance = UIconGlyph(18, [
        .circle(9, 9, 6.5, sw: 1.3),
        .path("M9 2.5A6.5 6.5 0 019 15.5z", filled: true),
    ])
    static let setEditor = UIconGlyph(18, [
        .rect(2.5, 3, 13, 12, r: 2.5, sw: 1.3),
        .path("M5.5 7l1.8 1.6L5.5 10.2M8.8 10.5h4", w: 1.3, cap: .round, join: .round),
    ])
    static let setQuery = UIconGlyph(18, [
        .path("M4 9l3.2 3.2L14 5.5", w: 1.5, cap: .round, join: .round),
    ])
    static let setAgent = UIconGlyph(18, [
        .rect(3.5, 5, 11, 9, r: 2.5, sw: 1.3),
        .path("M9 5V2.5M6.5 9v1.5M11.5 9v1.5", w: 1.3, cap: .round),
    ])
    static let setSecurity = UIconGlyph(18, [
        .path("M9 2l5 1.8v4c0 3.2-2.1 5.6-5 6.9-2.9-1.3-5-3.7-5-6.9v-4L9 2z", w: 1.3, join: .round),
    ])
    static let setPlugins = UIconGlyph(18, [
        .path("M6 2.5v3M12 2.5v3M4.5 5.5h9v2.2a4.5 4.5 0 01-4.5 4.5 4.5 4.5 0 01-4.5-4.5V5.5zM9 12.2v3.3", w: 1.3, cap: .round, join: .round),
    ])
    static let setShortcuts = UIconGlyph(18, [
        .rect(2, 4.5, 14, 9, r: 2, sw: 1.3),
        .path("M5 7.5h.01M8 7.5h.01M11 7.5h.01M5.5 10.5h7", w: 1.3, cap: .round),
    ])
    static let setAbout = UIconGlyph(18, [
        .circle(9, 9, 6.5, sw: 1.3),
        .path("M9 8.2v4M9 5.6v.01", w: 1.5, cap: .round),
    ])
}
