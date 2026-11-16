#if os(macOS)

import Foundation
import UControlKit

/// 测试用的最小动作集：覆盖三种门禁与两种槽位。
enum TestAction: String, Codable, CaseIterable, ControlActionKind {
    case ping
    case hosts
    case run
    case sftpGet = "sftp-get"
    case terminalWait = "terminal-wait"
    case terminalSend = "terminal-send"

    var gate: ControlGate {
        switch self {
        case .ping: .always
        case .hosts, .sftpGet, .terminalWait: .enabled
        case .run, .terminalSend: .mutation
        }
    }

    var occupancy: ControlOccupancy {
        switch self {
        case .sftpGet, .terminalWait: .longLived
        case .ping, .hosts, .run, .terminalSend: .short
        }
    }
}

struct TestRequest: ControlRequestEnvelope, Codable, Equatable {
    var id: String?
    var action: TestAction
    var path: String?
    var text: String?

    init(id: String? = nil, action: TestAction, path: String? = nil, text: String? = nil) {
        self.id = id
        self.action = action
        self.path = path
        self.text = text
    }
}

struct TestResponse: ControlResponseEnvelope, Codable, Equatable {
    var id: String?
    var ok: Bool
    var code: String
    var message: String

    static func success(id: String?, message: String) -> TestResponse {
        TestResponse(id: id, ok: true, code: "ok", message: message)
    }

    static func controlFailure(id: String?, code: String, message: String) -> TestResponse {
        TestResponse(id: id, ok: false, code: code, message: message)
    }
}

typealias TestServer = ControlSocketServer<TestRequest, TestResponse>
typealias TestDispatcher = ControlDispatcher<TestRequest, TestResponse>

#endif
