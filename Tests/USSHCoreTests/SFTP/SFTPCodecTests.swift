import NIOCore
import NIOEmbedded
import XCTest
@testable import USSHCore

/// 线格式：每种报文的往返、任意切分的字节流、坏输入不 trap。
final class SFTPCodecTests: XCTestCase {

    // MARK: - 样本

    private static func buffer(_ string: String) -> ByteBuffer { ByteBuffer(string: string) }

    private static let fullAttributes = SFTPFileAttributes(
        size: 1 << 40,
        owner: SFTPFileOwner(userID: 501, groupID: 20),
        permissions: 0o100644,
        times: SFTPFileTimes(accessSeconds: 1_700_000_000, modificationSeconds: 1_700_000_123),
        extended: [SFTPExtendedAttribute(name: "user.tag", data: buffer("v")),
                   SFTPExtendedAttribute(name: "empty", data: ByteBuffer())])

    static let requests: [SFTPRequest] = {
        let handle = buffer("h\u{0}1")
        return [
            .initialize(version: 3, extensions: []),
            .initialize(version: 3, extensions: [SFTPWireExtension(name: "a@b", data: "1")]),
            .open(id: 1, path: "/tmp/x", flags: [.read, .write, .create, .exclusive], attributes: fullAttributes),
            .open(id: 2, path: "", flags: [], attributes: .none),
            .close(id: 3, handle: handle),
            .read(id: 4, handle: handle, offset: .max, length: .max),
            .write(id: 5, handle: handle, offset: 7, data: buffer("payload")),
            .write(id: 6, handle: handle, offset: 0, data: ByteBuffer()),
            .lstat(id: 7, path: "/l"),
            .fstat(id: 8, handle: handle),
            .setstat(id: 9, path: "/s", attributes: SFTPFileAttributes(permissions: 0o755)),
            .fsetstat(id: 10, handle: handle, attributes: SFTPFileAttributes(size: 0)),
            .opendir(id: 11, path: "/d"),
            .readdir(id: 12, handle: handle),
            .remove(id: 13, path: "/r"),
            .mkdir(id: 14, path: "/m", attributes: SFTPFileAttributes(permissions: 0o700)),
            .rmdir(id: 15, path: "/m"),
            .realpath(id: 16, path: "."),
            .stat(id: 17, path: "/中文 路径"),
            .rename(id: 18, oldPath: "/a", newPath: "/b"),
            .readlink(id: 19, path: "/link"),
            .symlink(id: 20, linkPath: "/link", targetPath: "/target"),
            .extended(id: 21, request: .posixRename(oldPath: "/a", newPath: "/b")),
            .extended(id: 22, request: .statVFS(path: "/")),
            .extended(id: 23, request: .fstatVFS(handle: handle)),
            .extended(id: 24, request: .hardLink(oldPath: "/a", newPath: "/b")),
            .extended(id: 25, request: .fsync(handle: handle)),
            .extended(id: 26, request: .lsetstat(path: "/l", attributes: fullAttributes)),
            .extended(id: 27, request: .limits),
            .extended(id: 28, request: .other(name: "vendor@example.com", data: buffer("opaque"))),
            .extended(id: .max, request: .other(name: "empty@example.com", data: ByteBuffer())),
        ]
    }()

    static let responses: [SFTPResponse] = {
        var stats = ByteBuffer()
        SFTPFileSystemStats(blockSize: 4096, fragmentSize: 4096, totalBlocks: 100, freeBlocks: 50, availableBlocks: 40,
                            totalInodes: 10, freeInodes: 5, availableInodes: 4, fileSystemID: 99, flags: 1,
                            maximumNameLength: 255).encode(into: &stats)
        return [
            .version(version: 3, extensions: []),
            .version(version: 3, extensions: [SFTPWireExtension(name: SFTPExtensionName.posixRename, data: "1"),
                                              SFTPWireExtension(name: SFTPExtensionName.limits, data: "1")]),
            .status(id: 1, code: .ok, message: "Success", languageTag: "en"),
            .status(id: 2, code: SFTPStatusCode(12345), message: "", languageTag: ""),
            .handle(id: 3, handle: buffer("handle-bytes")),
            .data(id: 4, data: buffer("some data")),
            .data(id: 5, data: ByteBuffer()),
            .name(id: 6, entries: []),
            .name(id: 7, entries: [
                SFTPDirectoryEntry(filename: "a", longname: "-rw-r--r-- 1 u g 0 Jan 1 00:00 a", attributes: fullAttributes),
                SFTPDirectoryEntry(filename: "目录", longname: "", attributes: .none),
            ]),
            .attributes(id: 8, attributes: fullAttributes),
            .attributes(id: 9, attributes: .none),
            .extendedReply(id: 10, data: stats),
            .extendedReply(id: 11, data: ByteBuffer()),
        ]
    }()

    private static func encodedStream<T>(_ items: [T], encode: (T, inout ByteBuffer) -> Void) -> ByteBuffer {
        var stream = ByteBuffer()
        for item in items { encode(item, &stream) }
        return stream
    }

    private static func frames(from stream: ByteBuffer, splitAt splits: [Int]) throws -> [ByteBuffer] {
        var decoder = SFTPFrameDecoder(maximumFrameLength: 1 << 20)
        var pending = ByteBuffer()
        var output: [ByteBuffer] = []
        var start = 0
        for end in splits + [stream.readableBytes] {
            var piece = stream.getSlice(at: stream.readerIndex + start, length: end - start)!
            pending.writeBuffer(&piece)
            while let frame = try decoder.decode(buffer: &pending) {
                output.append(frame)
            }
            start = end
        }
        XCTAssertEqual(pending.readableBytes, 0, "bytes left over")
        return output
    }

    // MARK: - 往返

    func testEveryRequestRoundTrips() throws {
        for request in Self.requests {
            var buffer = ByteBuffer()
            request.encode(into: &buffer)
            let declared = buffer.getInteger(at: 0, as: UInt32.self)!
            XCTAssertEqual(Int(declared), buffer.readableBytes - 4, "length field of \(request)")
            var decoder = SFTPFrameDecoder(maximumFrameLength: 1 << 20)
            let frame = try XCTUnwrap(try decoder.decode(buffer: &buffer))
            XCTAssertEqual(try SFTPRequest.decode(frame: frame), request)
            XCTAssertEqual(buffer.readableBytes, 0)
        }
    }

    func testEveryResponseRoundTrips() throws {
        for response in Self.responses {
            var buffer = ByteBuffer()
            response.encode(into: &buffer)
            XCTAssertEqual(Int(buffer.getInteger(at: 0, as: UInt32.self)!), buffer.readableBytes - 4)
            var decoder = SFTPFrameDecoder(maximumFrameLength: 1 << 20)
            let frame = try XCTUnwrap(try decoder.decode(buffer: &buffer))
            XCTAssertEqual(try SFTPResponse.decode(frame: frame), response)
        }
    }

    /// 头部 + 另行写出的数据，与整帧逐字节相同（零拷贝路径不能改变线上的字节）。
    func testSplitHeaderEncodingMatchesFullEncoding() {
        let handle = Self.buffer("hh")
        let write = SFTPRequest.write(id: 9, handle: handle, offset: 1 << 33, data: SFTPTestData.bytes(count: 1000))
        var full = ByteBuffer()
        write.encode(into: &full)
        var header = ByteBuffer()
        var trailing = write.encodeHeader(into: &header)!
        header.writeBuffer(&trailing)
        XCTAssertEqual(header, full)

        let data = SFTPResponse.data(id: 3, data: SFTPTestData.bytes(count: 777))
        var fullResponse = ByteBuffer()
        data.encode(into: &fullResponse)
        var responseHeader = ByteBuffer()
        var responseTrailing = data.encodeHeader(into: &responseHeader)!
        responseHeader.writeBuffer(&responseTrailing)
        XCTAssertEqual(responseHeader, fullResponse)
    }

    func testSymlinkUsesOpenSSHArgumentOrder() {
        var buffer = ByteBuffer()
        SFTPRequest.symlink(id: 1, linkPath: "LINK", targetPath: "TARGET").encode(into: &buffer)
        // 长度 4 + 类型 1 + 请求号 4，之后第一个字符串是 target。
        buffer.moveReaderIndex(forwardBy: 9)
        XCTAssertEqual(buffer.readSFTPString(), "TARGET")
        XCTAssertEqual(buffer.readSFTPString(), "LINK")
    }

    func testStatVFSAndLimitsPayloadsRoundTrip() {
        let stats = SFTPFileSystemStats(blockSize: 1, fragmentSize: 2, totalBlocks: 3, freeBlocks: 4, availableBlocks: 5,
                                        totalInodes: 6, freeInodes: 7, availableInodes: 8, fileSystemID: 9, flags: 3,
                                        maximumNameLength: 11)
        var buffer = ByteBuffer()
        stats.encode(into: &buffer)
        XCTAssertEqual(buffer.readableBytes, 88)
        XCTAssertEqual(SFTPFileSystemStats.decode(from: &buffer), stats)
        XCTAssertTrue(stats.isReadOnly)

        let limits = SFTPServerLimits(maximumPacketLength: 1, maximumReadLength: 2, maximumWriteLength: 3, maximumOpenHandles: 4)
        limits.encode(into: &buffer)
        XCTAssertEqual(SFTPServerLimits.decode(from: &buffer), limits)
        var short = ByteBuffer(bytes: [0, 0, 0])
        XCTAssertNil(SFTPServerLimits.decode(from: &short))
        XCTAssertNil(SFTPFileSystemStats.decode(from: &short))
    }

    // MARK: - 切分

    /// 整条流在每一个字节边界上切成两段喂进去，结果都和不切一样。
    func testRequestStreamSplitAtEveryBoundary() throws {
        let stream = Self.encodedStream(Self.requests) { $0.encode(into: &$1) }
        for split in 0...stream.readableBytes {
            let frames = try Self.frames(from: stream, splitAt: [split])
            XCTAssertEqual(try frames.map(SFTPRequest.decode(frame:)), Self.requests, "split at \(split)")
        }
    }

    func testResponseStreamSplitAtEveryBoundary() throws {
        let stream = Self.encodedStream(Self.responses) { $0.encode(into: &$1) }
        for split in 0...stream.readableBytes {
            let frames = try Self.frames(from: stream, splitAt: [split])
            XCTAssertEqual(try frames.map(SFTPResponse.decode(frame:)), Self.responses, "split at \(split)")
        }
    }

    /// 一个字节一个字节地喂。
    func testStreamFedOneByteAtATime() throws {
        let stream = Self.encodedStream(Self.responses) { $0.encode(into: &$1) }
        let frames = try Self.frames(from: stream, splitAt: Array(1..<stream.readableBytes))
        XCTAssertEqual(try frames.map(SFTPResponse.decode(frame:)), Self.responses)
    }

    /// 经真的 `ByteToMessageHandler`（客户端装在 pipeline 里的就是它）一个字节一个字节地喂。
    func testByteToMessageHandlerReassemblesFragments() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPFrameDecoder(maximumFrameLength: 1 << 20)))
        let stream = Self.encodedStream(Self.requests) { $0.encode(into: &$1) }
        for index in 0..<stream.readableBytes {
            try channel.writeInbound(stream.getSlice(at: index, length: 1)!)
        }
        var decoded: [SFTPRequest] = []
        while let frame = try channel.readInbound(as: ByteBuffer.self) {
            decoded.append(try SFTPRequest.decode(frame: frame))
        }
        XCTAssertEqual(decoded, Self.requests)
        XCTAssertTrue(try channel.finish().isClean)
    }

    // MARK: - 坏输入

    func testOversizedLengthIsRejectedBeforeBuffering() {
        var decoder = SFTPFrameDecoder(maximumFrameLength: 1024)
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(1025))
        XCTAssertThrowsError(try decoder.decode(buffer: &buffer)) { error in
            XCTAssertEqual(error as? SFTPWireError, .packetTooLarge(length: 1025, limit: 1024))
        }
        var huge = ByteBuffer()
        huge.writeInteger(UInt32.max)
        XCTAssertThrowsError(try decoder.decode(buffer: &huge))
    }

    func testZeroLengthFrameIsRejected() {
        var decoder = SFTPFrameDecoder(maximumFrameLength: 1024)
        var buffer = ByteBuffer(bytes: [0, 0, 0, 0])
        XCTAssertThrowsError(try decoder.decode(buffer: &buffer)) { error in
            XCTAssertEqual(error as? SFTPWireError, .emptyPacket)
        }
    }

    func testIncompleteFrameWaitsForMoreBytes() throws {
        var decoder = SFTPFrameDecoder(maximumFrameLength: 1024)
        var buffer = ByteBuffer(bytes: [0, 0, 0, 10, 101, 0, 0])
        XCTAssertNil(try decoder.decode(buffer: &buffer))
        XCTAssertEqual(buffer.readableBytes, 7, "nothing consumed")
    }

    /// 每一种报文体在每一个长度上截断：要么抛错，要么解出另一个合法值（允许省略的尾部字段），绝不 trap。
    func testTruncatedBodiesNeverTrap() throws {
        for request in Self.requests {
            let body = Self.body(of: { request.encode(into: &$0) })
            for length in 0..<body.readableBytes {
                let truncated = body.getSlice(at: body.readerIndex, length: length)!
                if let decoded = try? SFTPRequest.decode(frame: truncated) {
                    XCTAssertNotEqual(decoded, request, "truncated \(request) to \(length) decoded as the original")
                }
            }
        }
        for response in Self.responses {
            let body = Self.body(of: { response.encode(into: &$0) })
            for length in 0..<body.readableBytes {
                let truncated = body.getSlice(at: body.readerIndex, length: length)!
                if let decoded = try? SFTPResponse.decode(frame: truncated) {
                    // 老服务端的 STATUS 可以不带文案与语言：文案本来就空的 STATUS 截掉这两项，解出来还是它自己。
                    if case .status(_, _, "", "") = response { continue }
                    XCTAssertNotEqual(decoded, response, "truncated \(response) to \(length) decoded as the original")
                }
            }
        }
    }

    func testTruncatedFixedFieldsThrow() {
        // READ 少了 length 字段。
        var read = ByteBuffer()
        read.writeInteger(SFTPPacketType.read.rawValue)
        read.writeInteger(UInt32(1))
        read.writeSFTPString("h")
        read.writeInteger(UInt64(0))
        XCTAssertThrowsError(try SFTPRequest.decode(frame: read)) { error in
            XCTAssertEqual(error as? SFTPWireError, .truncated(type: SFTPPacketType.read.rawValue))
        }
        // HANDLE 的字符串长度比剩下的字节多。
        var handle = ByteBuffer()
        handle.writeInteger(SFTPPacketType.handle.rawValue)
        handle.writeInteger(UInt32(1))
        handle.writeInteger(UInt32(100))
        handle.writeString("abc")
        XCTAssertThrowsError(try SFTPResponse.decode(frame: handle))
    }

    /// NAME 的计数是 40 亿、后面却没有字节：不能按计数预留内存，也不能 trap。
    func testHugeNameCountWithoutEntriesThrows() {
        var frame = ByteBuffer()
        frame.writeInteger(SFTPPacketType.name.rawValue)
        frame.writeInteger(UInt32(1))
        frame.writeInteger(UInt32.max)
        XCTAssertThrowsError(try SFTPResponse.decode(frame: frame))

        var attributes = ByteBuffer()
        attributes.writeInteger(SFTPPacketType.attributes.rawValue)
        attributes.writeInteger(UInt32(1))
        attributes.writeInteger(SFTPFileAttributes.extendedFlag)
        attributes.writeInteger(UInt32.max)
        XCTAssertThrowsError(try SFTPResponse.decode(frame: attributes))
    }

    func testUnknownPacketTypeCarriesRequestID() {
        var frame = ByteBuffer()
        frame.writeInteger(UInt8(77))
        frame.writeInteger(UInt32(42))
        XCTAssertThrowsError(try SFTPRequest.decode(frame: frame)) { error in
            XCTAssertEqual(error as? SFTPWireError, .unknownPacketType(77, requestID: 42))
        }
        XCTAssertThrowsError(try SFTPResponse.decode(frame: frame)) { error in
            XCTAssertEqual(error as? SFTPWireError, .unknownPacketType(77, requestID: 42))
        }
        XCTAssertThrowsError(try SFTPResponse.decode(frame: ByteBuffer(bytes: [99]))) { error in
            XCTAssertEqual(error as? SFTPWireError, .unknownPacketType(99, requestID: nil))
        }
    }

    func testPacketsInTheWrongDirectionAreRejected() {
        var status = ByteBuffer()
        SFTPResponse.status(id: 1, code: .ok, message: "", languageTag: "").encode(into: &status)
        status.moveReaderIndex(forwardBy: 4)
        XCTAssertThrowsError(try SFTPRequest.decode(frame: status)) { error in
            XCTAssertEqual(error as? SFTPWireError, .unexpectedPacketType(SFTPPacketType.status.rawValue))
        }
        var open = ByteBuffer()
        SFTPRequest.open(id: 1, path: "/", flags: .read, attributes: .none).encode(into: &open)
        open.moveReaderIndex(forwardBy: 4)
        XCTAssertThrowsError(try SFTPResponse.decode(frame: open)) { error in
            XCTAssertEqual(error as? SFTPWireError, .unexpectedPacketType(SFTPPacketType.open.rawValue))
        }
    }

    /// 老服务端的 STATUS 只有状态码，没有文案与语言。
    func testStatusWithoutMessageDecodes() throws {
        var frame = ByteBuffer()
        frame.writeInteger(SFTPPacketType.status.rawValue)
        frame.writeInteger(UInt32(5))
        frame.writeInteger(SFTPStatusCode.noSuchFile.rawValue)
        XCTAssertEqual(try SFTPResponse.decode(frame: frame),
                       .status(id: 5, code: .noSuchFile, message: "", languageTag: ""))
    }

    func testInvalidUTF8IsReplacedNotRejected() throws {
        var frame = ByteBuffer()
        frame.writeInteger(SFTPPacketType.stat.rawValue)
        frame.writeInteger(UInt32(1))
        frame.writeInteger(UInt32(2))
        frame.writeBytes([0xFF, 0xFE])
        guard case .stat(1, let path) = try SFTPRequest.decode(frame: frame) else { return XCTFail("not a stat") }
        XCTAssertEqual(path.unicodeScalars.count, 2)
    }

    // MARK: - 属性

    func testAttributeHelpers() {
        XCTAssertEqual(SFTPFileAttributes(permissions: 0o040755).fileType, .directory)
        XCTAssertTrue(SFTPFileAttributes(permissions: 0o120777).isSymbolicLink)
        XCTAssertTrue(SFTPFileAttributes(permissions: 0o100600).isRegularFile)
        XCTAssertEqual(SFTPFileAttributes(permissions: 0o104755).permissionBits, 0o4755)
        XCTAssertNil(SFTPFileAttributes().fileType)
        for type in [SFTPFileType.regularFile, .directory, .symbolicLink, .characterDevice, .blockDevice, .fifo, .socket] {
            XCTAssertEqual(SFTPFileType(permissions: type.modeBits | 0o644), type)
        }
        let times = SFTPFileTimes(accessDate: Date(timeIntervalSince1970: -5), modificationDate: .distantFuture)
        XCTAssertEqual(times.accessSeconds, 0)
        XCTAssertEqual(times.modificationSeconds, .max)
        XCTAssertEqual(SFTPStatusCode.noSuchFile.description, "SSH_FX_NO_SUCH_FILE")
        XCTAssertEqual(SFTPStatusCode(999).description, "SSH_FX(999)")
    }

    private static func body(of encode: (inout ByteBuffer) -> Void) -> ByteBuffer {
        var buffer = ByteBuffer()
        encode(&buffer)
        buffer.moveReaderIndex(forwardBy: 4)
        return buffer
    }
}
