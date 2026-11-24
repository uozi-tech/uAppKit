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

// Extension negotiation (RFC 8308), the parts NIOSSH needs:
//
// - a client announces `ext-info-c` in its first KEXINIT;
// - the server may then send SSH_MSG_EXT_INFO as the first message after its first SSH_MSG_NEWKEYS (and again
//   right before SSH_MSG_USERAUTH_SUCCESS);
// - of the extensions, NIOSSH understands `server-sig-algs`: the public key algorithms the server accepts in
//   user authentication. Clients hand it to their `NIOSSHClientUserAuthenticationDelegate`.

extension SSHMessage {
    struct ExtensionInfoMessage: Equatable {
        // SSH_MSG_EXT_INFO
        static let id: UInt8 = 7

        struct Extension: Equatable {
            var name: String
            var value: ByteBuffer
        }

        var extensions: [Extension]

        /// The `server-sig-algs` extension, if present and well formed.
        var serverSignatureAlgorithms: [String]? {
            guard let value = self.extensions.first(where: { $0.name == "server-sig-algs" })?.value,
                let list = value.getString(at: value.readerIndex, length: value.readableBytes)
            else {
                return nil
            }
            return list.split(separator: ",").map { String($0) }
        }
    }
}

extension SSHKeyExchangeStateMachine {
    static let extensionInfoClientMarker: Substring = "ext-info-c"
}

extension ByteBuffer {
    mutating func readExtensionInfoMessage() -> SSHMessage.ExtensionInfoMessage? {
        self.rewindReaderOnNil { `self` in
            guard let count = self.readInteger(as: UInt32.self) else {
                return nil
            }
            // Each extension needs at least two empty strings (8 bytes): do not trust a count the packet cannot
            // possibly hold.
            guard Int(count) <= self.readableBytes / 8 else {
                return nil
            }
            var extensions: [SSHMessage.ExtensionInfoMessage.Extension] = []
            extensions.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let name = self.readSSHStringAsString(), let value = self.readSSHString() else {
                    return nil
                }
                extensions.append(.init(name: name, value: value))
            }
            return SSHMessage.ExtensionInfoMessage(extensions: extensions)
        }
    }

    mutating func writeExtensionInfoMessage(_ message: SSHMessage.ExtensionInfoMessage) -> Int {
        var written = self.writeInteger(UInt32(message.extensions.count))
        for var `extension` in message.extensions {
            written += self.writeSSHString(`extension`.name.utf8)
            written += self.writeSSHString(&`extension`.value)
        }
        return written
    }
}
