//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CNIOLinux
import NIOCore
import XCTest

@testable import NIOPosix

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// This file constructs POSIX msghdr and UnsafeControlMessageCollection
// throughout, which are unsupported on Windows.
#if !os(Windows)
extension UnsafeControlMessageCollection {
    fileprivate init(controlBytes: UnsafeMutableRawBufferPointer) {
        let msgHdr = msghdr(
            msg_name: nil,
            msg_namelen: 0,
            msg_iov: nil,
            msg_iovlen: 0,
            msg_control: controlBytes.baseAddress,
            msg_controllen: .init(controlBytes.count),
            msg_flags: 0
        )
        self.init(messageHeader: msgHdr)
    }
}

class ControlMessageTests: XCTestCase {
    var encoderBytes: UnsafeMutableRawBufferPointer?
    var encoder: UnsafeOutboundControlBytes!

    override func setUp() {
        self.encoderBytes = UnsafeMutableRawBufferPointer.allocate(
            byteCount: 1000,
            alignment: MemoryLayout<Int>.alignment
        )
        self.encoder = UnsafeOutboundControlBytes(controlBytes: self.encoderBytes!)
    }

    override func tearDown() {
        if let encoderBytes = self.encoderBytes {
            self.encoderBytes = nil
            encoderBytes.deallocate()
        }
    }

    func testEmptyEncode() {
        XCTAssertEqual(self.encoder.validControlBytes.count, 0)
    }

    struct DecodedMessage: Equatable {
        var level: CInt
        var type: CInt
        var payload: CInt
    }

    func testEncodeDecode1() {
        self.encoder.appendControlMessage(level: 1, type: 2, payload: 3)
        let expected = [DecodedMessage(level: 1, type: 2, payload: 3)]
        let encodedBytes = self.encoder.validControlBytes

        let decoder = UnsafeControlMessageCollection(controlBytes: encodedBytes)
        XCTAssertEqual(decoder.count, 1)
        var decoded: [DecodedMessage] = []
        for cmsg in decoder {
            XCTAssertEqual(cmsg.data!.count, MemoryLayout<CInt>.size)
            let payload = ControlMessageParser._readCInt(data: cmsg.data!)
            decoded.append(DecodedMessage(level: cmsg.level, type: cmsg.type, payload: payload))
        }
        XCTAssertEqual(expected, decoded)
    }

    func testEncodeDecode2() {
        self.encoder.appendControlMessage(level: 1, type: 2, payload: 3)
        self.encoder.appendControlMessage(level: 4, type: 5, payload: 6)
        let expected = [
            DecodedMessage(level: 1, type: 2, payload: 3),
            DecodedMessage(level: 4, type: 5, payload: 6),
        ]
        let encodedBytes = self.encoder.validControlBytes

        let decoder = UnsafeControlMessageCollection(controlBytes: encodedBytes)
        XCTAssertEqual(decoder.count, 2)
        var decoded: [DecodedMessage] = []
        for cmsg in decoder {
            XCTAssertEqual(cmsg.data!.count, MemoryLayout<CInt>.size)
            let payload = ControlMessageParser._readCInt(data: cmsg.data!)
            decoded.append(DecodedMessage(level: cmsg.level, type: cmsg.type, payload: payload))
        }
        XCTAssertEqual(expected, decoded)
    }

    #if os(Linux)
    func testFileDescriptorEncodingSharesControlMessageLayout() {
        self.encoder.appendControlMessage(level: CInt(IPPROTO_IP), type: IP_TOS, payload: 2)
        let descriptors: [CInt] = [10, 11, 12]
        self.encoder.appendFileDescriptors(descriptors)
        let messages = Array(UnsafeControlMessageCollection(controlBytes: self.encoder.validControlBytes))
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1].level, SOL_SOCKET)
        XCTAssertEqual(messages[1].type, CInt(SCM_RIGHTS))
        let payload = messages[1].data!
        XCTAssertEqual(payload.count, descriptors.count * MemoryLayout<CInt>.size)
        for index in descriptors.indices {
            XCTAssertEqual(
                payload.loadUnaligned(fromByteOffset: index * MemoryLayout<CInt>.size, as: CInt.self),
                descriptors[index]
            )
        }
    }

    func testEmptyFileDescriptorsDoNotAppendControlMessage() {
        self.encoder.appendFileDescriptors([])
        XCTAssertEqual(self.encoder.validControlBytes.count, 0)
    }

    func testTakeFileDescriptorsCombinesHeadersAndOnlyTakesOnce() throws {
        let first = open("/dev/null", O_RDONLY | O_CLOEXEC)
        let second = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertGreaterThanOrEqual(second, 0)
        self.encoder.appendFileDescriptors([first])
        self.encoder.appendControlMessage(level: CInt(IPPROTO_IP), type: IP_TOS, payload: 2)
        self.encoder.appendFileDescriptors([second])
        var received = UnsafeReceivedControlBytes(controlBytesBuffer: self.encoderBytes!)
        received.receivedControlMessages = UnsafeControlMessageCollection(controlBytes: self.encoder.validControlBytes)
        let descriptors = try received.takeFileDescriptors()
        defer { for descriptor in descriptors { try? descriptor.close() } }
        XCTAssertEqual(try descriptors.map { try $0.withUnsafeFileDescriptor { $0 } }, [first, second])
        XCTAssertTrue(try received.takeFileDescriptors().isEmpty)
    }

    func testIgnoredPIDFDIsClosedWithAndWithoutTruncation() throws {
        for flags in [CInt(0), CInt(MSG_CTRUNC)] {
            self.encoder = UnsafeOutboundControlBytes(controlBytes: self.encoderBytes!)
            let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0)
            self.encoder.appendControlMessage(level: SOL_SOCKET, type: 4, payload: fd)  // SCM_PIDFD
            var received = UnsafeReceivedControlBytes(controlBytesBuffer: self.encoderBytes!)
            received.receivedControlMessages = UnsafeControlMessageCollection(
                controlBytes: self.encoder.validControlBytes
            )
            received.receivedMessageFlags = flags
            if flags == 0 {
                XCTAssertTrue(try received.takeFileDescriptors().isEmpty)
            } else {
                XCTAssertThrowsError(try received.takeFileDescriptors())
            }
            XCTAssertEqual(fcntl(fd, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }

    func testTruncatedControlMessageClosesReceivedDescriptors() throws {
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        self.encoder.appendFileDescriptors([fd])
        var received = UnsafeReceivedControlBytes(controlBytesBuffer: self.encoderBytes!)
        received.receivedControlMessages = UnsafeControlMessageCollection(controlBytes: self.encoder.validControlBytes)
        received.receivedMessageFlags = CInt(MSG_CTRUNC)
        XCTAssertThrowsError(try received.takeFileDescriptors()) { error in
            XCTAssertEqual((error as? IOError)?.errnoCode, EMSGSIZE)
        }
        XCTAssertEqual(fcntl(fd, F_GETFD), -1)
        XCTAssertNil(received.receivedControlMessages)
    }
    #endif

    private func assertBuffersNonOverlapping(
        _ b1: UnsafeMutableRawBufferPointer,
        _ b2: UnsafeMutableRawBufferPointer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssert(
            (b1.baseAddress! < b2.baseAddress! && (b1.baseAddress! + b1.count) <= b2.baseAddress!)
                || (b2.baseAddress! < b1.baseAddress! && (b2.baseAddress! + b2.count) <= b1.baseAddress!),
            file: (file),
            line: line
        )
    }

    func testStorageIndexing() {
        var storage = UnsafeControlMessageStorage.allocate(msghdrCount: 3)
        defer {
            storage.deallocate()
        }
        // Check size
        XCTAssertEqual(storage.count, 3)
        // Buffers issued should not overlap.
        assertBuffersNonOverlapping(storage[0], storage[1])
        assertBuffersNonOverlapping(storage[0], storage[2])
        assertBuffersNonOverlapping(storage[1], storage[2])
        // Buffers should have a suitable size.
        XCTAssertGreaterThan(storage[0].count, MemoryLayout<cmsghdr>.stride)
        XCTAssertGreaterThan(storage[1].count, MemoryLayout<cmsghdr>.stride)
        XCTAssertGreaterThan(storage[2].count, MemoryLayout<cmsghdr>.stride)
    }
}
#endif
