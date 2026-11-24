//===----------------------------------------------------------------------===//
//
// This file is part of uAppKit's patches to the SwiftNIO SSH project.
//
// Copyright (c) 2026 the uAppKit authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

// Key re-exchange on demand and after a traffic limit (RFC 4253 §9: "It is RECOMMENDED that the keys be changed
// after each gigabyte of transmitted data or after each hour of connection time"). Packet sequence numbers are
// 32 bits and feed the MAC of `hmac-*` and `*-etm` transports: without a rekey they wrap under the same key.

/// Encrypted traffic in one direction since the last key exchange.
struct SSHTrafficCounter: Equatable {
    var packets: UInt64 = 0
    var bytes: UInt64 = 0

    mutating func record(bytes: Int) {
        self.packets &+= 1
        self.bytes &+= UInt64(bytes)
    }
}

/// When to start a key re-exchange automatically.
public struct NIOSSHRekeyLimits: Hashable, Sendable {
    /// Rekey once either direction has carried this many packets under the current keys; `nil`: no packet limit.
    public var packets: UInt64?

    /// Rekey once either direction has carried this many bytes under the current keys; `nil`: no byte limit.
    public var bytes: UInt64?

    public init(packets: UInt64?, bytes: UInt64?) {
        self.packets = packets
        self.bytes = bytes
    }

    /// 2^31 packets or 1 GiB, whichever comes first: half the sequence number space, and OpenSSH's data limit for
    /// ciphers with small blocks.
    public static let `default` = NIOSSHRekeyLimits(packets: 1 << 31, bytes: 1 << 30)

    /// Never rekey automatically (NIOSSH's behaviour before this option existed).
    public static let disabled = NIOSSHRekeyLimits(packets: nil, bytes: nil)

    func isReached(by traffic: SSHTrafficCounter) -> Bool {
        if let packets = self.packets, traffic.packets >= packets {
            return true
        }
        if let bytes = self.bytes, traffic.bytes >= bytes {
            return true
        }
        return false
    }
}

extension SSHConnectionRole {
    internal var rekeyLimits: NIOSSHRekeyLimits {
        switch self {
        case .client(let configuration):
            return configuration.rekeyLimits
        case .server(let configuration):
            return configuration.rekeyLimits
        }
    }
}
