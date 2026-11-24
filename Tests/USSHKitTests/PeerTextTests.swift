import Foundation
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 对端给的文字进文案 / 日志之前先消毒：控制字符、双向覆盖、不可见字符去掉，换行变空格，超长截断。
final class PeerTextTests: XCTestCase {

    /// 没有控制字符、没有格式字符——成对的 FSI / PDI（`SSHPeerText.isolated` 加的）除外。
    private func assertClean(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let opens = text.unicodeScalars.filter { $0.value == 0x2068 }.count
        XCTAssertEqual(opens, text.unicodeScalars.filter { $0.value == 0x2069 }.count, "FSI / PDI 不成对", file: file, line: line)
        for scalar in text.unicodeScalars where scalar.value != 0x2068 && scalar.value != 0x2069 {
            XCTAssertFalse(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value),
                           "控制字符 U+\(String(scalar.value, radix: 16)) 漏了：\(text.debugDescription)", file: file, line: line)
            XCTAssertNotEqual(scalar.properties.generalCategory, .format,
                              "格式字符 U+\(String(scalar.value, radix: 16)) 漏了", file: file, line: line)
        }
    }

    func testEscapeAndOSCSequencesLoseTheirEscape() {
        let text = "\u{1B}[31mred\u{1B}[0m \u{1B}]0;pwned\u{07} \u{9B}2J done"
        let clean = SSHPeerText.sanitize(text)
        assertClean(clean)
        XCTAssertEqual(clean, "[31mred[0m ]0;pwned 2J done")
    }

    func testNewlinesAndRunsOfWhitespaceBecomeOneSpace() {
        XCTAssertEqual(SSHPeerText.sanitize("  line1\r\nfake log line\n\n\tx\u{2028}y  "), "line1 fake log line x y")
    }

    func testBidiOverridesIsolatesAndInvisibleFormatCharactersAreRemoved() {
        let text = "ssh-\u{202E}asr\u{202C}-key \u{2066}a\u{2069} \u{200B}zero\u{200D}width \u{FEFF}bom \u{061C}\u{200E}\u{200F}x\u{00AD}y"
        let clean = SSHPeerText.sanitize(text)
        assertClean(clean)
        XCTAssertEqual(clean, "ssh-asr-key a zerowidth bom xy")
    }

    func testVeryLongInputIsTruncatedWithAnEllipsis() {
        let huge = String(repeating: "数据", count: 2_000_000)                 // 400 万个字符
        let start = ContinuousClock.now
        let clean = SSHPeerText.sanitize(huge)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(200), "不该整份过一遍")
        XCTAssertEqual(clean.count, SSHPeerText.maximumLength + 1)
        XCTAssertTrue(clean.hasSuffix("…"))
        XCTAssertEqual(SSHPeerText.sanitize(String(repeating: "a", count: SSHPeerText.maximumLength)).count,
                       SSHPeerText.maximumLength, "正好到上限的不截断")
        // 全是要去掉的字符、后面才是正文：照样截断（不会先走完几兆字节的控制字符）。
        let padded = String(repeating: "\u{0}", count: 1_000_000) + "tail"
        XCTAssertEqual(SSHPeerText.sanitize(padded), "…")
    }

    func testInvalidUTF8AndOrdinaryTextSurvive() {
        let decoded = String(decoding: [0x6F, 0x6B, 0xFF, 0xC3, 0x28, 0x21], as: UTF8.self)
        let clean = SSHPeerText.sanitize(decoded)
        assertClean(clean)
        XCTAssertEqual(clean, "ok\u{FFFD}\u{FFFD}(!")
        XCTAssertEqual(SSHPeerText.sanitize("权限不足：/srv/e\u{301}té 日本語 한국어"), "权限不足：/srv/e\u{301}té 日本語 한국어")
    }

    // MARK: 用到的地方

    func testSFTPStatusMessageIsSanitized() {
        let message = "\u{1B}]52;c;Y3VybCBldmlsLnNoIHwgc2g=\u{07}nope\n" + String(repeating: "x", count: 10_000)
        let text = SFTPError.status(code: .failure, message: message, languageTag: "").errorDescription ?? ""
        assertClean(text)
        XCTAssertLessThan(text.count, SSHPeerText.maximumLength + 40)
    }

    func testChannelOpenFailureDescriptionIsSanitized() {
        let failure = SSHChannelOpenFailure(reasonCode: 99, description: "go away\u{1B}[2J\r\n\u{202E}evil")
        let text = SSHErrorText.describe(failure)
        assertClean(text)
        XCTAssertTrue(text.hasSuffix(SSHPeerText.isolated("go away[2J evil")), text)
        let forwarding = SSHForwardingChannelFailure(classifying: SSHChannelError.openRejected(failure))
        assertClean(forwarding.detail)
        assertClean(forwarding.userMessage(targetHost: "h", targetPort: 1))
    }

    func testServerOfferIsSanitized() {
        let failure = SSHAlgorithmNegotiationFailure(
            category: .hostKey, clientOffer: [],
            serverOffer: ["ssh-\u{202E}asr", "x\u{1B}[1m"] + Array(repeating: "filler-algorithm-name", count: 1000))
        let text = SSHErrorText.describe(failure)
        assertClean(text)
        XCTAssertLessThan(text.count, SSHPeerText.maximumLength + 120)
    }

    func testUnknownErrorDescriptionsAndSignalNamesAreSanitized() {
        struct Weird: Error, CustomStringConvertible { var description: String { "bad\u{1B}[0m\nline" } }
        assertClean(SSHErrorText.describe(Weird()))
        assertClean(SSHCommandError.nonZeroExit(.signaled(.init(name: "KILL\u{1B}[2J\n", coreDumped: false, message: "")), output: .init()).errorDescription ?? "")
    }

    func testKeyFileLabelsAreSanitized() {
        let error = PrivateKeyImportError.unsupportedFormat(label: "OpenSSH \u{1B}]0;x\u{07}\u{202E}rsa")
        assertClean(error.errorDescription ?? "")
        assertClean(error.failureReason ?? "")
    }

    // MARK: 第三轮审查补上的

    func testOutOfRangeLengthsDoNotTrap() {
        XCTAssertEqual(SSHPeerText.sanitize("abc", maximumLength: -5), "…")
        XCTAssertEqual(SSHPeerText.sanitize("", maximumLength: -5), "")
        XCTAssertEqual(SSHPeerText.sanitize("abc", maximumLength: .max), "abc")
        XCTAssertEqual(SSHPeerText.sanitize("abc", maximumLength: 0), "…")
    }

    /// 插进本地化句子时包在 FSI … PDI 里：从右往左的文字不会搅乱外面那句话。
    func testIsolatedWrapsInFirstStrongIsolates() {
        let hebrew = "שלום\u{202E}"
        XCTAssertEqual(SSHPeerText.isolated(hebrew), "\u{2068}שלום\u{2069}")
        let message = SFTPError.status(code: .failure, message: "אין הרשאה", languageTag: "he").errorDescription ?? ""
        XCTAssertTrue(message.contains("\u{2068}אין הרשאה\u{2069}"), message)
    }

    func testRunsOfCombiningMarksAreCapped() {
        let zalgo = "a" + String(repeating: "\u{0301}", count: 200) + "b"
        let clean = SSHPeerText.sanitize(zalgo)
        XCTAssertEqual(clean.unicodeScalars.filter { $0.value == 0x0301 }.count, SSHPeerText.maximumMarksPerCharacter)
        XCTAssertTrue(clean.hasSuffix("b"))
        XCTAssertEqual(SSHPeerText.sanitize("e\u{301}te\u{301}"), "e\u{301}te\u{301}", "正常的组合字符不动")
        // 变体选择符同样算。
        let selectors = "x" + String(repeating: "\u{FE0F}", count: 50)
        XCTAssertEqual(SSHPeerText.sanitize(selectors).unicodeScalars.count, 1 + SSHPeerText.maximumMarksPerCharacter)
    }

    func testPrivateUseAndInvisibleFillersAreDropped() {
        XCTAssertEqual(SSHPeerText.sanitize("a\u{E000}b\u{F8FF}c\u{115F}d\u{1160}e\u{3164}f\u{FFA0}g\u{100000}h"), "abcdefgh")
    }

    /// U+200D 只在两个 emoji 之间保留：家庭、职业之类的 emoji 序列完好，夹在普通文字里的零宽连接符去掉。
    func testZeroWidthJoinerOnlyBetweenEmoji() {
        let family = "👨\u{200D}👩\u{200D}👧"
        XCTAssertEqual(SSHPeerText.sanitize(family), family)
        let technologist = "🧑🏽\u{200D}💻"
        XCTAssertEqual(SSHPeerText.sanitize(technologist), technologist)
        XCTAssertEqual(SSHPeerText.sanitize("ab\u{200D}cd"), "abcd")
        XCTAssertEqual(SSHPeerText.sanitize("1\u{200D}2"), "12", "ASCII 数字虽然也算 Emoji，不保留")
    }

    func testTransferErrorPathsAreIsolated() {
        let error = SSHFileTransferError.uploadOutcomeUnknown(
            temporaryPath: "/srv/\u{1B}]0;x\u{07}a.tmp", destination: "/srv/\u{202E}evil", reason: "r")
        let text = error.errorDescription ?? ""
        assertClean(text)
        XCTAssertTrue(text.contains(SSHPeerText.isolated("/srv/evil")), text)
        assertClean(SSHFileTransferError.localFileUnavailable("/tmp/\u{1B}[2Jx").errorDescription ?? "")
    }
}
