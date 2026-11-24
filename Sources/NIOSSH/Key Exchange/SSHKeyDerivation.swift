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

import Crypto
import NIOCore

extension HashFunction {
    /// Derives one session key as in RFC 4253 §7.2. `self` must already hold `K || H` (K as an mpint).
    ///
    ///     K1 = HASH(K || H || X || session_id)
    ///     K2 = HASH(K || H || K1)
    ///     K3 = HASH(K || H || K1 || K2)
    ///     ...
    ///     key = K1 || K2 || K3 || ...   (truncated to `length`)
    ///
    /// The extension matters whenever a transport protection needs more key material than one hash output, e.g.
    /// a 64-byte `hmac-sha2-512` key from a SHA-256 based key exchange.
    func sshDerivedKey(discriminatorByte: UInt8, sessionID: ByteBuffer, length: Int) -> [UInt8] {
        var first = self
        first.update(data: [discriminatorByte])
        first.update(data: sessionID.readableBytesView)
        var key = Array(first.finalize())
        while key.count < length {
            var next = self
            next.update(data: key)
            key.append(contentsOf: next.finalize())
        }
        return Array(key.prefix(length))
    }
}
