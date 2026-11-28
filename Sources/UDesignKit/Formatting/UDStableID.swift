import Foundation

/// 由字符串键确定性地派生 `UUID`，以及给可能重名的列表项排出稳定的 `ForEach` 键。
///
/// 为什么：`UDMenuItem` / `UDFooterItem` 这类展示数据由调用方在 `body` 里现造，原先 `id = UUID()`
/// 每次求值都是新值——`ForEach` 每次都当成全新的行：行内 hover 态被清掉、按住到一半的点击丢了、
/// `scrollTo` 的目标也跟着变。键相同就得到同一个 UUID（跨进程也一样，不用 `Hasher` 的随机种子）。
nonisolated enum UDStableID {
    /// 键 → UUID（两路 64 位 FNV-1a 拼成 128 位，再打上 v5 风格的版本 / 变体位）。
    static func uuid(_ key: String) -> UUID {
        let bytes = Array(key.utf8)
        let a = fnv1a(bytes, seed: 0xcbf2_9ce4_8422_2325)
        let b = fnv1a(bytes, seed: 0x8422_2325_cbf2_9ce4 ^ UInt64(bytes.count))
        var raw = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            raw[i] = UInt8(truncatingIfNeeded: a >> (UInt64(i) * 8))
            raw[8 + i] = UInt8(truncatingIfNeeded: b >> (UInt64(i) * 8))
        }
        raw[6] = (raw[6] & 0x0F) | 0x50
        raw[8] = (raw[8] & 0x3F) | 0x80
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                           raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }

    /// 给一列项排 `ForEach` 键：同一 id 第 n 次出现记作 `id#n`。
    /// 分隔线、同名项共用一个派生 id 时，行键仍然各不相同、且只随位置里的重名次序变。
    static func keyed<Item, ID: Hashable>(_ items: [Item], id: (Item) -> ID) -> [(key: String, item: Item)] {
        var seen: [ID: Int] = [:]
        return items.map { item in
            let itemID = id(item)
            let n = seen[itemID, default: 0]
            seen[itemID] = n + 1
            return (key: "\(itemID)#\(n)", item: item)
        }
    }

    private static func fnv1a(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
