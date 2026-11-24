import BigInt
import NIOCore
import XCTest

@testable import USSHCore

final class SSHWireFormatTests: XCTestCase {
    /// RFC 4251 §5 给的 mpint 示例，逐字节对照。
    func testRFC4251MPIntExamples() throws {
        let examples: [(BigInt, String)] = [
            (0, "00000000"),
            (BigInt("9a378f9b2e332a7", radix: 16)!, "0000000809a378f9b2e332a7"),
            (0x80, "000000020080"),
            (-0x1234, "00000002edcc"),
            (-BigInt("deadbeef", radix: 16)!, "00000005ff21524111"),
        ]
        for (value, hex) in examples {
            var buffer = ByteBuffer()
            buffer.writeSSHWireMPInt(value)
            XCTAssertEqual(Array(buffer.readableBytesView).hexString, hex, "\(value)")
            XCTAssertEqual(try buffer.readSSHWireMPInt(), value)
            XCTAssertEqual(buffer.readableBytes, 0)
        }
    }

    func testMPIntSignedRoundTripAndMinimality() throws {
        var values: [BigInt] = [0, 1, -1, 127, 128, -128, -129, 255, 256, -255, -256, -257, 0x7FFF, 0x8000, -0x8000, -0x8001]
        for _ in 0..<200 {
            let magnitude = BigUInt.randomInteger(withMaximumWidth: Int.random(in: 1...600))
            values.append(Bool.random() ? BigInt(magnitude) : -BigInt(magnitude))
        }
        for value in values {
            let encoded = ByteBuffer.encodeMPInt(value)
            XCTAssertEqual(try ByteBuffer.decodeMPInt(encoded), value, "\(value)")
            // 最短：首字节不是可省略的 0x00 / 0xFF。
            if encoded.count >= 2 {
                XCTAssertFalse(encoded[0] == 0x00 && encoded[1] & 0x80 == 0, "\(value)")
                XCTAssertFalse(encoded[0] == 0xFF && encoded[1] & 0x80 != 0, "\(value)")
            }
            XCTAssertEqual(value == 0, encoded.isEmpty)
        }
    }

    func testRejectsNonMinimalAndNegativeMPInts() {
        let nonMinimal: [[UInt8]] = [[0x00], [0x00, 0x7F], [0x00, 0x00, 0x80], [0xFF, 0x80], [0xFF, 0xFF, 0x01]]
        for bytes in nonMinimal {
            XCTAssertThrowsError(try ByteBuffer.decodeMPInt(bytes)) {
                XCTAssertEqual($0 as? SSHWireFormatError, .nonMinimalMPInt, bytes.hexString)
            }
        }
        // 合法的边界：单独 0xFF 是 −1；0x00 0x80 是 128。
        XCTAssertEqual(try ByteBuffer.decodeMPInt([0xFF]), -1)
        XCTAssertEqual(try ByteBuffer.decodeMPInt([0x00, 0x80]), 128)

        XCTAssertThrowsError(try ByteBuffer.decodeUnsignedMPInt([0x80])) {
            XCTAssertEqual($0 as? SSHWireFormatError, .negativeMPInt)
        }
        XCTAssertThrowsError(try ByteBuffer.decodeUnsignedMPInt([0x00, 0x01])) {
            XCTAssertEqual($0 as? SSHWireFormatError, .nonMinimalMPInt)
        }
        XCTAssertEqual(try ByteBuffer.decodeUnsignedMPInt([]), [])
        XCTAssertEqual(try ByteBuffer.decodeUnsignedMPInt([0x00, 0x80, 0x01]), [0x80, 0x01])
    }

    func testUnsignedMPIntEncoding() {
        XCTAssertEqual(ByteBuffer.encodeUnsignedMPInt(magnitude: [UInt8]()), [])
        XCTAssertEqual(ByteBuffer.encodeUnsignedMPInt(magnitude: [0, 0, 0]), [])
        XCTAssertEqual(ByteBuffer.encodeUnsignedMPInt(magnitude: [0, 0x7F]), [0x7F])
        XCTAssertEqual(ByteBuffer.encodeUnsignedMPInt(magnitude: [0, 0, 0x80, 1]), [0, 0x80, 1])
        var buffer = ByteBuffer()
        buffer.writeSSHWireUnsignedMPInt(magnitude: [0xFF, 0x01])
        XCTAssertEqual(Array(buffer.readableBytesView).hexString, "0000000300ff01")
        XCTAssertEqual(try buffer.readSSHWireUnsignedMPInt(), [0xFF, 0x01])
    }

    func testStringLengthValidationNeverOverreads() {
        // 声明 10 字节，只有 3 字节。
        var short = ByteBuffer(bytes: [0, 0, 0, 10, 1, 2, 3])
        XCTAssertThrowsError(try short.readSSHWireString()) {
            XCTAssertEqual($0 as? SSHWireFormatError, .truncated)
        }
        XCTAssertEqual(short.readableBytes, 7, "失败时读指针不动")
        // 声明 4 GiB。
        var huge = ByteBuffer(bytes: [0xFF, 0xFF, 0xFF, 0xFF, 1])
        XCTAssertThrowsError(try huge.readSSHWireString()) {
            guard case .lengthExceedsLimit = $0 as? SSHWireFormatError else {
                return XCTFail("\($0)")
            }
        }
        // 长度前缀本身不完整。
        var partial = ByteBuffer(bytes: [0, 0, 1])
        XCTAssertThrowsError(try partial.readSSHWireString())
        XCTAssertThrowsError(try partial.readSSHWireUInt32())
        // 上限可调。
        var limited = ByteBuffer(bytes: [0, 0, 0, 5, 1, 2, 3, 4, 5])
        XCTAssertThrowsError(try limited.readSSHWireString(maximumLength: 4))
        XCTAssertEqual(try limited.readSSHWireString(maximumLength: 5).readableBytes, 5)
        // mpint 超长。
        var bigMPInt = ByteBuffer()
        bigMPInt.writeSSHWireString([UInt8](repeating: 1, count: SSHWireLimits.maximumMPIntLength + 1))
        XCTAssertThrowsError(try bigMPInt.readSSHWireMPInt())
        XCTAssertEqual(bigMPInt.readerIndex, 0)
    }

    func testNameLists() throws {
        var buffer = ByteBuffer()
        buffer.writeSSHWireNameList(["aes128-ctr", "hmac-sha2-256-etm@openssh.com"])
        XCTAssertEqual(try buffer.readSSHWireNameList(), ["aes128-ctr", "hmac-sha2-256-etm@openssh.com"])

        buffer.writeSSHWireNameList([])
        XCTAssertEqual(try buffer.readSSHWireNameList(), [])

        for bad in ["a,,b", ",a", "a,", "a b", "a\u{7}", "é", String(repeating: "x", count: 65)] {
            var invalid = ByteBuffer()
            invalid.writeSSHWireString(Array(bad.utf8))
            XCTAssertThrowsError(try invalid.readSSHWireNameList(), bad) {
                XCTAssertEqual($0 as? SSHWireFormatError, .invalidNameList)
            }
            XCTAssertEqual(invalid.readerIndex, 0)
        }
        XCTAssertEqual(try ByteBuffer.parseNameList(Array(String(repeating: "x", count: 64).utf8)).count, 1)
    }

    func testIdentifierAndTrailingBytes() throws {
        var buffer = ByteBuffer()
        buffer.writeSSHWireString("ssh-rsa")
        buffer.writeInteger(UInt8(1))
        XCTAssertEqual(try buffer.readSSHWireIdentifier(), "ssh-rsa")
        XCTAssertThrowsError(try buffer.requireFullyConsumed()) {
            XCTAssertEqual($0 as? SSHWireFormatError, .trailingBytes(count: 1))
        }
        var empty = ByteBuffer()
        empty.writeSSHWireString("")
        XCTAssertThrowsError(try empty.readSSHWireIdentifier())
    }
}
