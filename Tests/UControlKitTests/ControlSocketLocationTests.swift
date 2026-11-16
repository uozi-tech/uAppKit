#if os(macOS)

import Foundation
import XCTest
@testable import UControlKit

/// socket 路径的 `sun_path` 矩阵。合并自 uTable 与 uTerm 各自的 `ControlProtocolTests`：
/// 两个 app 的容器名、目录名差 2 字节，第一个放不下的用户名长度也就差 2。
///
/// 不用跑测试这台机器的真实路径：开发机用户名短，长用户名的情况永远测不到
/// （uTerm 2026-11-16 的反馈就是这么漏掉的）。
final class ControlSocketLocationTests: XCTestCase {
    private struct Case {
        let identity: ControlAppIdentity
        let filename: String
        /// 默认目录第一个放不下的用户名长度。
        let firstTooLong: Int
        /// 退路目录还放得下的最长用户名。
        let longestFitting: Int
    }

    private static let uTable = ControlAppIdentity(
        appName: "uTable", bundleIdentifier: "com.uozi.uTable", directoryName: "uTable",
        ctlName: "utablectl", isSandboxed: true)
    private static let uTerm = ControlAppIdentity(
        appName: "uTerm", bundleIdentifier: "com.uozi.uTerm", directoryName: "uTerm",
        ctlName: "utermctl", isSandboxed: true)

    /// 实测值（已随两个 app 的测试发版）：
    /// - uTable：`control.sock` 9 个字符起放不下（8 个正好 103 字节），`dev.sock` 13 起；退路到 39。
    /// - uTerm：`control.sock` 11 起（反馈的 `exampleuser` 正好 104 字节），`dev.sock` 15 起；退路到 40（`dev.sock` 各多 4）。
    private let cases: [Case] = [
        Case(identity: uTable, filename: "control.sock", firstTooLong: 9, longestFitting: 39),
        Case(identity: uTable, filename: "dev.sock", firstTooLong: 13, longestFitting: 43),
        Case(identity: uTerm, filename: "control.sock", firstTooLong: 11, longestFitting: 40),
        Case(identity: uTerm, filename: "dev.sock", firstTooLong: 15, longestFitting: 44),
    ]

    private func container(_ identity: ControlAppIdentity, user: String) -> (applicationSupport: URL, temporary: URL) {
        let data = URL(fileURLWithPath: "/Users/\(user)/Library/Containers/\(identity.bundleIdentifier)/Data", isDirectory: true)
        return (
            data.appending(path: "Library/Application Support/\(identity.directoryName)", directoryHint: .isDirectory),
            data.appending(path: "tmp", directoryHint: .isDirectory)
        )
    }

    private func socketURL(_ item: Case, user: String) -> URL {
        let dirs = container(item.identity, user: user)
        return ControlSocketLocation(identity: item.identity, filename: item.filename)
            .socketURL(applicationSupport: dirs.applicationSupport, temporaryDirectory: dirs.temporary)
    }

    func testShortUserNameKeepsApplicationSupportPath() {
        for item in cases {
            for count in [5, item.firstTooLong - 1] {
                let user = String(repeating: "u", count: count)
                let url = socketURL(item, user: user)
                XCTAssertEqual(
                    url.deletingLastPathComponent(),
                    container(item.identity, user: user).applicationSupport.standardizedFileURL,
                    "\(item.identity.appName)/\(item.filename) 用户名 \(count)")
                XCTAssertTrue(ControlSocketLocation.fitsInSunPath(url), url.path)
            }
        }
    }

    func testLongUserNameFallsBackToContainerTemporaryDirectory() {
        for item in cases {
            for count in [item.firstTooLong, 32, item.longestFitting] {
                let user = String(repeating: "u", count: count)
                let url = socketURL(item, user: user)
                XCTAssertEqual(
                    url.deletingLastPathComponent(),
                    container(item.identity, user: user).temporary.standardizedFileURL,
                    "\(item.identity.appName)/\(item.filename) 用户名 \(count)")
                XCTAssertEqual(url.lastPathComponent, item.filename)
                XCTAssertTrue(ControlSocketLocation.fitsInSunPath(url), "\(url.path.utf8.count) 字节：\(url.path)")
            }
        }
    }

    /// 长到连 `Data/tmp/` 都放不下时返回的路径仍然超长，交给 `ControlSocketServer.start()` 报错。
    func testUserNameTooLongForBothLocations() {
        for item in cases {
            XCTAssertFalse(ControlSocketLocation.fitsInSunPath(socketURL(item, user: String(repeating: "u", count: 60))))
            XCTAssertFalse(ControlSocketLocation.fitsInSunPath(
                socketURL(item, user: String(repeating: "u", count: item.longestFitting + 1))))
        }
    }

    func testFitsInSunPathLeavesRoomForTerminatingNul() {
        let base = "/" + String(repeating: "a", count: ControlSocketLocation.maxSunPathLength - 2)
        XCTAssertTrue(ControlSocketLocation.fitsInSunPath(URL(fileURLWithPath: base)))
        XCTAssertFalse(ControlSocketLocation.fitsInSunPath(URL(fileURLWithPath: base + "a")))
    }

    /// 沙盒的客户端候选路径与两个 ctl 已发版的 `SOCKET_CANDIDATES` 前两条逐字一致。
    func testSandboxedClientCandidates() {
        XCTAssertEqual(
            ControlSocketLocation(identity: Self.uTable, filename: "control.sock").clientCandidates(for: "control.sock"),
            [
                "~/Library/Containers/com.uozi.uTable/Data/Library/Application Support/uTable/control.sock",
                "~/Library/Containers/com.uozi.uTable/Data/tmp/control.sock",
            ])
        XCTAssertEqual(
            ControlSocketLocation(identity: Self.uTerm, filename: "control.sock").clientCandidates(for: "control.sock"),
            [
                "~/Library/Containers/com.uozi.uTerm/Data/Library/Application Support/uTerm/control.sock",
                "~/Library/Containers/com.uozi.uTerm/Data/tmp/control.sock",
            ])
    }

    /// 非沙盒（uGit）：退路是 `_CS_DARWIN_USER_TEMP_DIR`，不受 `TMPDIR` 影响，客户端也算得出来；
    /// 服务端的退路目录与给客户端的第二条候选是同一个目录。
    func testUnsandboxedLayoutUsesDarwinUserTemporaryDirectory() throws {
        let identity = ControlAppIdentity(
            appName: "uGit", bundleIdentifier: "com.uozi.uGit", directoryName: "uGit",
            ctlName: "ugitctl", isSandboxed: false)
        let location = ControlSocketLocation(identity: identity, filename: "control.sock")
        let darwinTemp = try XCTUnwrap(ControlSocketLocation.darwinUserTemporaryDirectory)
        XCTAssertTrue(darwinTemp.path.hasSuffix("/T"), darwinTemp.path)
        XCTAssertEqual(location.temporaryDirectory, darwinTemp)

        let candidates = location.clientCandidates(for: "control.sock")
        XCTAssertEqual(candidates.first, "~/Library/Application Support/uGit/control.sock")
        XCTAssertEqual(candidates.last, darwinTemp.appending(path: "control.sock").path)
        XCTAssertTrue(ControlSocketLocation.fitsInSunPath(darwinTemp.appending(path: "control.sock")))

        // 默认放不下时落到的正是第二条候选。
        let long = URL(fileURLWithPath: "/" + String(repeating: "a", count: 120), isDirectory: true)
        XCTAssertEqual(
            location.socketURL(applicationSupport: long, temporaryDirectory: location.temporaryDirectory).path,
            candidates.last)
    }

    func testApplicationSupportDirectoryUsesDirectoryName() {
        let location = ControlSocketLocation(identity: Self.uTable, filename: "control.sock")
        XCTAssertEqual(location.applicationSupportDirectory.lastPathComponent, "uTable")
        XCTAssertEqual(location.applicationSupportDirectory.deletingLastPathComponent().lastPathComponent, "Application Support")
    }

    func testMissingSocketIsNotServed() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "absent-\(UUID().uuidString.prefix(6)).sock")
        XCTAssertFalse(ControlSocketLocation.isSocketServed(url))
    }
}

#endif
