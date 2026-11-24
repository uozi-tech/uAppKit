import Foundation
import NIOCore
import XCTest
@testable import USSHCore
import USSHTestServer

/// 路径按字节往返：非 UTF-8 的名字、NFC 与 NFD 两种写法，都能列出来、再原样拿去操作。
final class SFTPPathTests: XCTestCase {
    static let nfc = SFTPPath("caf\u{E9}")            // é 一个码位
    static let nfd = SFTPPath("cafe\u{301}")          // e + 组合重音
    static let invalidA = SFTPPath(bytes: [0x66, 0xFF])   // 两个不同的非法序列，
    static let invalidB = SFTPPath(bytes: [0x66, 0xFE])   // 解成字符串后一模一样

    func testValueSemantics() {
        XCTAssertEqual(Self.nfc.string, Self.nfd.string, "String 相等按规范等价")
        XCTAssertNotEqual(Self.nfc, Self.nfd, "SFTPPath 相等按字节")
        XCTAssertEqual(Set([Self.nfc, Self.nfd, Self.invalidA, Self.invalidB]).count, 4)
        XCTAssertEqual(Self.invalidA.string, Self.invalidB.string)
        XCTAssertNotEqual(Self.invalidA, Self.invalidB)
        XCTAssertTrue(Self.nfd.isLosslessUTF8)
        XCTAssertFalse(Self.invalidA.isLosslessUTF8)
        XCTAssertEqual(SFTPPath(Self.nfd.string), Self.nfd)
        XCTAssertNotEqual(SFTPPath(Self.invalidA.string), Self.invalidA)
        let literal: SFTPPath = "/a b"
        XCTAssertEqual(literal.bytes, Array("/a b".utf8))
        XCTAssertEqual(SFTPPath("/dir").appending("x"), "/dir/x")
        XCTAssertEqual(SFTPPath("/").appending("x"), "/x")
        XCTAssertEqual(SFTPPath("").appending("x"), "x")
        XCTAssertTrue(Self.invalidA.debugDescription.contains("255"))
    }

    /// 测试服务端 + 按字节存名字的内存文件系统：四个「解成字符串会撞车」的名字各是各的文件。
    func testByteExactNamesThroughTestServer() async throws {
        let memory = SFTPMemoryFileSystem()
        let names = [Self.nfc, Self.nfd, Self.invalidA, Self.invalidB]
        for (index, name) in names.enumerated() {
            memory.put(SFTPPath("/").appending(name), [UInt8(index)])
        }
        // 非 UTF-8 名字的目录，下面的文件也要够得着。
        let weirdDirectory = SFTPPath(bytes: Array("dir-".utf8) + Self.invalidA.bytes)
        memory.makeDirectory(SFTPPath("/").appending(weirdDirectory))
        memory.put(SFTPPath("/").appending(weirdDirectory).appending("inner"), [9])

        let pair = try await SFTPLoopbackPair.make(serving: memory)
        defer { Task { await pair.shutdown() } }
        let client = pair.client

        let listed = try await client.listDirectory(SFTPPath("/"))
        XCTAssertEqual(Set(listed.map(\.name)), Set(names + [weirdDirectory]))
        for entry in listed where entry.attributes.isRegularFile {
            let path = SFTPPath("/").appending(entry.name)
            let expected = names.firstIndex(of: entry.name)!
            let attributes = try await client.stat(path)
            XCTAssertEqual(attributes.size, 1)
            let data = try await client.withFile(path, flags: .read) { try await $0.readAll() }
            XCTAssertEqual(Array(data.readableBytesView), [UInt8(expected)], "\(entry.name.debugDescription)")
        }

        let directory = try XCTUnwrap(listed.first { $0.attributes.isDirectory })
        let below = try await client.listDirectory(SFTPPath("/").appending(directory.name))
        XCTAssertEqual(below.map(\.name), ["inner"])
        let inner = try await client.withFile(SFTPPath("/").appending(directory.name).appending("inner"), flags: .read) {
            try await $0.readAll()
        }
        XCTAssertEqual(Array(inner.readableBytesView), [9])

        // 改名 / 删除只动按字节对上的那一个。
        try await client.rename(SFTPPath("/").appending(Self.invalidA), to: SFTPPath("/").appending(SFTPPath(bytes: [0x67, 0xFF])))
        XCTAssertFalse(memory.exists(SFTPPath("/").appending(Self.invalidA)))
        XCTAssertEqual(memory.contents(SFTPPath("/").appending(Self.invalidB)), [3])
        XCTAssertTrue(memory.exists(SFTPPath("/").appending(SFTPPath(bytes: [0x67, 0xFF]))))
        try await client.remove(SFTPPath("/").appending(Self.nfd))
        XCTAssertFalse(memory.exists(SFTPPath("/").appending(Self.nfd)))
        XCTAssertEqual(memory.contents(SFTPPath("/").appending(Self.nfc)), [0])

        // realPath / readLink 的回答也按字节交回来。
        let real = try await client.realPath(SFTPPath("/").appending(Self.invalidB))
        XCTAssertEqual(real, SFTPPath("/").appending(Self.invalidB))
    }

    /// 真的 OpenSSH sftp-server（APFS）：NFD 名字原样列出来、原样拿去操作。
    /// APFS 不收非 UTF-8 的名字（EILSEQ），那一半只能在上面的测试服务端里测；这里核对它作为状态码报回来。
    func testNFDNamesAgainstOpenSSH() async throws {
        let server = try await OpenSSHServer.start()
        defer { Task { await server.stop() } }
        let client = server.client
        let directory = SFTPPath(server.root)
        try Data("nfd".utf8).write(to: URL(fileURLWithPath: server.root + "/" + Self.nfd.string))

        let listed = try await client.listDirectory(directory)
        let entry = try XCTUnwrap(listed.first)
        XCTAssertEqual(entry.name.bytes, Self.nfd.bytes, "APFS 保留创建时的写法，客户端原样交出")
        let path = directory.appending(entry.name)
        let data = try await client.withFile(path, flags: .read) { try await $0.readAll() }
        XCTAssertEqual(String(buffer: data), "nfd")
        let renamedName = SFTPPath(bytes: Array("x-".utf8) + Self.nfd.bytes)
        try await client.rename(path, to: directory.appending(renamedName))
        let after = try await client.listDirectory(directory)
        XCTAssertEqual(after.map(\.name), [renamedName])
        try await client.remove(directory.appending(after[0].name))
        let empty = try await client.listDirectory(directory)
        XCTAssertTrue(empty.isEmpty)

        await XCTAssertSFTPStatus(.failure) {
            _ = try await client.openFile(directory.appending(Self.invalidA), flags: [.write, .create])
        }
    }
}
