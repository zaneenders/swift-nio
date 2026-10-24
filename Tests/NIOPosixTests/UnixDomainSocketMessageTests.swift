// SPDX-License-Identifier: Apache-2.0
#if os(Linux) || canImport(Darwin)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif
import CNIOLinux
import Dispatch
import NIOCore
@testable import NIOPosix
import XCTest

private final class ByteBufferCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<ByteBuffer>

    init(_ promise: EventLoopPromise<ByteBuffer>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.promise.succeed(self.unwrapInboundIn(data))
    }
}

private final class DescriptorAccumulator: ChannelInboundHandler {
    typealias InboundIn = NIOUnixDomainSocketMessage<ByteBuffer>

    let promise: EventLoopPromise<NIOUnixDomainSocketMessage<ByteBuffer>>
    let expectedBytes: Int
    let readManually: Bool
    private var data = ByteBuffer()
    private var descriptors: [NIOUnixDomainSocketDescriptor] = []

    init(
        expectedBytes: Int,
        promise: EventLoopPromise<NIOUnixDomainSocketMessage<ByteBuffer>>,
        readManually: Bool = false
    ) {
        self.expectedBytes = expectedBytes
        self.promise = promise
        self.readManually = readManually
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if self.readManually && self.data.readableBytes < self.expectedBytes { context.read() }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var message = self.unwrapInboundIn(data)
        self.data.writeBuffer(&message.data)
        self.descriptors.append(contentsOf: message.descriptors)
        XCTAssertLessThanOrEqual(self.data.readableBytes, self.expectedBytes)
        if self.data.readableBytes == self.expectedBytes {
            self.promise.succeed(NIOUnixDomainSocketMessage(data: self.data, descriptors: self.descriptors))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.promise.fail(error)
    }
}

final class UnixDomainSocketMessageTests: XCTestCase {
    private func closeChannel(_ channel: any Channel) throws {
        do { try channel.close().wait() } catch ChannelError.alreadyClosed {}
    }

    #if os(Linux)
    func testChannelTransfersMultipleOwnedCloseOnExecDescriptorsWithoutEnablingReception() throws {
        try self.assertTransferWithReceptionDisabled(wasEnabled: false)
    }

    func testDisablingReceptionDoesNotDisableSending() throws {
        try self.assertTransferWithReceptionDisabled(wasEnabled: true)
    }

    func testDescriptorFreeMessagesPreserveManualFragmentedReads() throws {
        try withTemporaryUnixDomainSocketPathName { path in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let accepted = group.next().makePromise(of: (any Channel).self)
            let server = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    accepted.succeed(channel)
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .bind(unixDomainSocketPath: path).wait()
            defer { XCTAssertNoThrow(try self.closeChannel(server)) }
            let received = group.next().makePromise(of: NIOUnixDomainSocketMessage<ByteBuffer>.self)
            let client = try ClientBootstrap(group: group)
                .channelOption(ChannelOptions.Types.ReceiveFileDescriptors(), value: true)
                .channelOption(.autoRead, value: false)
                .channelOption(.maxMessagesPerRead, value: 1)
                .channelOption(.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 4))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            DescriptorAccumulator(expectedBytes: 12, promise: received, readManually: true)
                        )
                    }
                }
                .connect(unixDomainSocketPath: path).wait()
            defer { XCTAssertNoThrow(try self.closeChannel(client)) }
            let child = try accepted.futureResult.wait()
            defer { XCTAssertNoThrow(try self.closeChannel(child)) }

            try child.writeAndFlush(NIOUnixDomainSocketMessage(data: ByteBuffer())).wait()
            child.write(NIOUnixDomainSocketMessage(data: ByteBuffer(string: "abcdefgh")), promise: nil)
            try child.writeAndFlush(NIOUnixDomainSocketMessage(data: ByteBuffer(string: "ijkl"))).wait()
            client.read()
            let message = try received.futureResult.wait()
            XCTAssertEqual(message.data, ByteBuffer(string: "abcdefghijkl"))
            XCTAssertTrue(message.descriptors.isEmpty)
            XCTAssertFalse(try client.getOption(.autoRead).wait())
        }
    }

    func testDescriptorTransferUnderBackpressurePreservesBytesAndSendsDescriptorsOnce() throws {
        var sockets: [CInt] = [-1, -1]
        try Posix.socketpair(domain: .unix, type: .stream, protocolSubtype: .default, socketVector: &sockets)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
        var payload = ByteBuffer()
        payload.writeRepeatingByte(42, count: 256 * 1024)
        var expected = ByteBuffer(string: "prefix")
        expected.writeImmutableBuffer(payload)
        expected.writeString("suffix")
        let received = group.next().makePromise(of: NIOUnixDomainSocketMessage<ByteBuffer>.self)
        let expectedBytes = expected.readableBytes
        let receiver = try ClientBootstrap(group: group)
            .channelOption(.autoRead, value: false)
            .channelOption(ChannelOptions.Types.ReceiveFileDescriptors(), value: true)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        DescriptorAccumulator(expectedBytes: expectedBytes, promise: received)
                    )
                }
            }
            .withConnectedSocket(sockets[0]).wait()
        defer { XCTAssertNoThrow(try self.closeChannel(receiver)) }
        let sender = try ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_sndbuf), value: 4096)
            .withConnectedSocket(sockets[1]).wait()
        defer { XCTAssertNoThrow(try self.closeChannel(sender)) }
        let raw = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(raw, 0)
        let descriptor = NIOUnixDomainSocketDescriptor(takingOwnershipOf: raw)
        defer { XCTAssertNoThrow(try descriptor.close()) }
        let message = NIOUnixDomainSocketMessage(data: payload, descriptors: [descriptor])
        let sent = sender.eventLoop.makePromise(of: Void.self)
        let buffered = try sender.eventLoop.submit {
            sender.write(ByteBuffer(string: "prefix"), promise: nil)
            sender.write(message, promise: nil)
            sender.writeAndFlush(ByteBuffer(string: "suffix"), promise: sent)
            return try sender.syncOptions!.getOption(.bufferedWritableBytes)
        }.wait()
        XCTAssertGreaterThan(buffered, 0)
        XCTAssertLessThan(buffered, payload.readableBytes)

        try receiver.setOption(ChannelOptions.autoRead, value: true).wait()
        try sent.futureResult.wait()
        let result = try received.futureResult.wait()
        defer { for descriptor in result.descriptors { XCTAssertNoThrow(try descriptor.close()) } }
        XCTAssertEqual(result.data, expected)
        XCTAssertEqual(result.descriptors.count, 1)
        XCTAssertNoThrow(try descriptor.withUnsafeFileDescriptor { $0 })
    }

    func testCompletingWriteReleasesQueuedDescriptors() throws {
        try self.assertQueuedDescriptorReleased(flush: true)
    }

    func testClosingChannelReleasesUnflushedDescriptors() throws {
        try self.assertQueuedDescriptorReleased(flush: false)
    }

    func testFailedWriteReleasesQueuedDescriptors() throws {
        try self.assertQueuedDescriptorReleased(flush: true, failWrite: true)
    }

    private func assertQueuedDescriptorReleased(flush: Bool, failWrite: Bool = false) throws {
        var sockets: [CInt] = [-1, -1]
        try Posix.socketpair(domain: .unix, type: .stream, protocolSubtype: .default, socketVector: &sockets)
        defer { if !failWrite { XCTAssertNoThrow(try Posix.close(descriptor: sockets[1])) } }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
        let channel = try ClientBootstrap(group: group)
            .channelOption(.autoRead, value: false)
            .channelOption(.allowRemoteHalfClosure, value: true)
            .withConnectedSocket(sockets[0]).wait()
        defer { XCTAssertNoThrow(try self.closeChannel(channel)) }
        let raw = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(raw, 0)
        let pending = channel.eventLoop.makePromise(of: Void.self)
        try channel.eventLoop.submit {
            channel.write(
                NIOUnixDomainSocketMessage(
                    data: ByteBuffer(string: "queued"),
                    descriptors: [NIOUnixDomainSocketDescriptor(takingOwnershipOf: raw)]
                ),
                promise: pending
            )
        }.wait()
        XCTAssertGreaterThanOrEqual(fcntl(raw, F_GETFD), 0)
        if failWrite {
            try Posix.close(descriptor: sockets[1])
            channel.flush()
            XCTAssertThrowsError(try pending.futureResult.wait())
        } else if flush {
            channel.flush()
            try pending.futureResult.wait()
        } else {
            try channel.close().wait()
            XCTAssertThrowsError(try pending.futureResult.wait())
        }
        // Promise callbacks run before the write stack releases its last descriptor references.
        try channel.eventLoop.submit {}.wait()
        XCTAssertEqual(fcntl(raw, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    private func assertTransferWithReceptionDisabled(wasEnabled: Bool) throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0, &sockets), 0)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
        let received = group.next().makePromise(of: NIOUnixDomainSocketMessage<ByteBuffer>.self)
        let server = try ClientBootstrap(group: group)
            .channelOption(ChannelOptions.Types.ReceiveFileDescriptors(), value: true)
            .channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        DescriptorAccumulator(expectedBytes: 4, promise: received)
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.withConnectedSocket(sockets[0]).wait()
        defer { XCTAssertNoThrow(try self.closeChannel(server)) }
        let reply = group.next().makePromise(of: ByteBuffer.self)
        let client = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteBufferCollector(reply))
                }
            }
            .withConnectedSocket(sockets[1]).wait()
        defer { XCTAssertNoThrow(try self.closeChannel(client)) }
        if wasEnabled {
            try client.setOption(ChannelOptions.Types.ReceiveFileDescriptors(), value: true).wait()
            try client.setOption(ChannelOptions.Types.ReceiveFileDescriptors(), value: false).wait()
        }
        XCTAssertFalse(try client.getOption(ChannelOptions.Types.ReceiveFileDescriptors()).wait())
        let descriptors = (0..<UnsafeControlMessageStorage.maximumFileDescriptors).map { _ in
            let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0)
            return NIOUnixDomainSocketDescriptor(takingOwnershipOf: fd)
        }
        var buffer = client.allocator.buffer(capacity: 4)
        buffer.writeString("test")
        try client.writeAndFlush(NIOUnixDomainSocketMessage(data: buffer, descriptors: descriptors)).wait()
        let message = try received.futureResult.wait()
        XCTAssertEqual(message.data.getString(at: message.data.readerIndex, length: 4), "test")
        XCTAssertEqual(message.descriptors.count, descriptors.count)
        XCTAssertFalse(try client.getOption(ChannelOptions.Types.ReceiveFileDescriptors()).wait())
        try server.writeAndFlush(buffer).wait()
        XCTAssertEqual(try reply.futureResult.wait(), buffer)
        for fd in message.descriptors {
            XCTAssertTrue(try fd.withUnsafeFileDescriptor { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 })
            try fd.close()
        }
        for fd in descriptors { try fd.close() }
    }

    func testOversizedDescriptorMessagesPreserveChannelAndOtherWrites() throws {
        var sockets: [CInt] = [-1, -1]
        try Posix.socketpair(domain: .unix, type: .stream, protocolSubtype: .default, socketVector: &sockets)
        let receiver = try Socket(socket: sockets[1], setNonBlocking: true)
        defer { XCTAssertNoThrow(try receiver.close()) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
        let channel = try ClientBootstrap(group: group).withConnectedSocket(sockets[0]).wait()
        defer { XCTAssertNoThrow(try self.closeChannel(channel)) }
        let descriptor = NIOUnixDomainSocketDescriptor(takingOwnershipOf: open("/dev/null", O_RDONLY | O_CLOEXEC))
        defer { try? descriptor.close() }
        let bytes = ByteBuffer(string: "test")
        var receivedBytes = [UInt8](repeating: 0, count: bytes.readableBytes)
        for count in [254, 255, 256, 257] {
            let pendingWrite = channel.write(bytes)
            XCTAssertThrowsError(
                try channel.writeAndFlush(
                    NIOUnixDomainSocketMessage(data: bytes, descriptors: Array(repeating: descriptor, count: count))
                ).wait()
            ) { error in
                XCTAssertEqual((error as? IOError)?.errnoCode, EMSGSIZE, "count=\(count)")
            }
            XCTAssertNoThrow(try pendingWrite.wait())
            XCTAssertTrue(channel.isActive)
            XCTAssertEqual(
                try receivedBytes.withUnsafeMutableBytes { try receiver.read(pointer: $0) },
                .processed(bytes.readableBytes)
            )
            XCTAssertEqual(receivedBytes, Array(bytes.readableBytesView))
        }
        try channel.writeAndFlush(bytes).wait()
        XCTAssertEqual(
            try receivedBytes.withUnsafeMutableBytes { try receiver.read(pointer: $0) },
            .processed(bytes.readableBytes)
        )
        XCTAssertEqual(receivedBytes, Array(bytes.readableBytesView))
        XCTAssertNoThrow(try descriptor.withUnsafeFileDescriptor { $0 })
    }

    func testSendingDescriptorPreservesRecordLockAndReleasesBorrowsOnError() throws {
        var sockets: [CInt] = [-1, -1]
        try Posix.socketpair(domain: .unix, type: .stream, protocolSubtype: .default, socketVector: &sockets)
        let sender = try Socket(socket: sockets[0], setNonBlocking: false)
        let receiver = try Socket(socket: sockets[1], setNonBlocking: false)
        defer { XCTAssertNoThrow(try sender.close()) }
        try withTemporaryFile { file, _ in
            let descriptor = NIOUnixDomainSocketDescriptor(
                takingOwnershipOf: try file.withUnsafeFileDescriptor {
                    try Posix.fcntl(descriptor: $0, command: F_DUPFD_CLOEXEC, value: 0)
                }
            )
            defer { XCTAssertNoThrow(try descriptor.close()) }
            try descriptor.withUnsafeFileDescriptor { raw in
                var lock = flock()
                lock.l_type = Int16(F_WRLCK)
                lock.l_whence = Int16(SEEK_SET)
                lock.l_len = 1
                XCTAssertEqual(withUnsafeMutablePointer(to: &lock) { fcntl(raw, F_SETLK, $0) }, 0)
            }
            // F_OFD_GETLK reports conflicting process-associated locks, including our own.
            func assertRecordLockHeld() throws {
                try descriptor.withUnsafeFileDescriptor { raw in
                    var query = flock()
                    query.l_type = Int16(F_WRLCK)
                    query.l_whence = Int16(SEEK_SET)
                    query.l_len = 1
                    XCTAssertEqual(withUnsafeMutablePointer(to: &query) { fcntl(raw, CInt(36), $0) }, 0)
                    XCTAssertEqual(query.l_type, Int16(F_WRLCK))
                }
            }
            try assertRecordLockHeld()
            let closed = NIOUnixDomainSocketDescriptor(takingOwnershipOf: -1)
            XCTAssertThrowsError(
                try [UInt8(42)].withUnsafeBytes {
                    try sender.sendFileDescriptors(pointer: $0, descriptors: [descriptor, closed])
                }
            ) { error in
                XCTAssertEqual((error as? IOError)?.errnoCode, EBADF)
            }
            try descriptor.withUnsafeFileDescriptor { _ in
                XCTAssertEqual(
                    try [UInt8(42)].withUnsafeBytes {
                        try sender.sendFileDescriptors(pointer: $0, descriptors: [descriptor, descriptor])
                    },
                    .processed(1)
                )
            }
            try assertRecordLockHeld()
            try receiver.close()
            XCTAssertThrowsError(
                try [UInt8(42)].withUnsafeBytes {
                    try sender.sendFileDescriptors(pointer: $0, descriptors: [descriptor])
                }
            )
            try assertRecordLockHeld()
        }
    }

    func testReceiveFileDescriptorsUsesCloseOnExecAndRejectsTruncation() throws {
        var sockets: [CInt] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, CInt(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0, &sockets), 0)
        let sender = try Socket(socket: sockets[0], setNonBlocking: false)
        let receiver = try Socket(socket: sockets[1], setNonBlocking: false)
        defer {
            XCTAssertNoThrow(try sender.close())
            XCTAssertNoThrow(try receiver.close())
        }
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let descriptor = NIOUnixDomainSocketDescriptor(takingOwnershipOf: fd)
        defer { try? descriptor.close() }
        var bytes: [UInt8] = [42]
        func send(_ count: Int) throws {
            let result = try bytes.withUnsafeBytes {
                try sender.sendFileDescriptors(
                    pointer: $0,
                    descriptors: Array(repeating: descriptor, count: count)
                )
            }
            XCTAssertEqual(result, .processed(1))
        }
        // The buffer can carry two FDs at most, even though the complete send contains eight.
        let size = NIOBSDSocketControlMessage.space(payloadSize: 2 * MemoryLayout<CInt>.size)
        let controlBytes = UnsafeMutableRawBufferPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<cmsghdr>.alignment
        )
        defer { controlBytes.deallocate() }
        try send(8)
        var address = sockaddr_storage()
        var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var received = UnsafeReceivedControlBytes(
            controlBytesBuffer: controlBytes,
            receiveFlags: CInt(MSG_CMSG_CLOEXEC)
        )
        let result = try bytes.withUnsafeMutableBytes {
            try receiver.recvmsg(pointer: $0, storage: &address, storageLen: &addressLength, controlBytes: &received)
        }
        XCTAssertEqual(result, .processed(1))
        XCTAssertNotEqual(received.receivedMessageFlags & CInt(MSG_CTRUNC), 0)
        var installed: [CInt] = []
        for message in received.receivedControlMessages! where message.type == CInt(SCM_RIGHTS) {
            let payload = message.data!
            for offset in stride(from: 0, to: payload.count, by: MemoryLayout<CInt>.size) {
                let fd = payload.loadUnaligned(fromByteOffset: offset, as: CInt.self)
                XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0)
                installed.append(fd)
            }
        }
        XCTAssertFalse(installed.isEmpty)
        XCTAssertThrowsError(try received.takeFileDescriptors()) { error in
            XCTAssertEqual((error as? IOError)?.errnoCode, EMSGSIZE)
        }
        for fd in installed { XCTAssertEqual(fcntl(fd, F_GETFD), -1) }
        try send(1)
        let (read, descriptors) = try bytes.withUnsafeMutableBytes {
            try receiver.receiveFileDescriptors(pointer: $0)
        }
        defer { for descriptor in descriptors { try? descriptor.close() } }
        XCTAssertEqual(read, .processed(1))
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertTrue(try descriptors[0].withUnsafeFileDescriptor { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 })
    }

    #endif

    func testRejectsUnsupportedSockets() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
        #if os(Linux)
        let families: [NIOBSDSocket.ProtocolFamily] = [.inet]
        #else
        let families: [NIOBSDSocket.ProtocolFamily] = [.inet, .unix]
        #endif
        for family in families {
            let channel = try SocketChannel(eventLoop: group.next() as! SelectableEventLoop, protocolFamily: family)
            defer { XCTAssertNoThrow(try self.closeChannel(channel)) }
            XCTAssertThrowsError(
                try channel.setOption(ChannelOptions.Types.ReceiveFileDescriptors(), value: true).wait()
            ) {
                XCTAssertEqual($0 as? ChannelError, .operationUnsupported)
            }
            XCTAssertThrowsError(try channel.write(NIOUnixDomainSocketMessage(data: ByteBuffer(string: "test"))).wait())
            {
                XCTAssertEqual($0 as? ChannelError, .operationUnsupported)
            }
        }
    }

    private func assertDescriptorInUse(_ descriptor: NIOUnixDomainSocketDescriptor) {
        XCTAssertThrowsError(try descriptor.takeDescriptorOwnership()) { error in
            XCTAssertEqual((error as? IOError)?.errnoCode, EBUSY)
        }
        XCTAssertThrowsError(try descriptor.close()) { error in
            XCTAssertEqual((error as? IOError)?.errnoCode, EBUSY)
        }
    }

    func testBorrowPreventsCloseAndOwnershipTransfer() throws {
        let raw = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(raw, 0)
        let descriptor = NIOUnixDomainSocketDescriptor(takingOwnershipOf: raw)
        defer { XCTAssertNoThrow(try descriptor.close()) }
        let alias = descriptor
        try descriptor.withUnsafeFileDescriptor { fd in
            self.assertDescriptorInUse(alias)
            XCTAssertEqual(fd, raw)
            XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFD), 0)
        }
        XCTAssertEqual(try descriptor.withUnsafeFileDescriptor { $0 }, raw)
    }

    func testConcurrentCloseAndOwnershipTransferThrowBusy() throws {
        let raw = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(raw, 0)
        let descriptor = NIOUnixDomainSocketDescriptor(takingOwnershipOf: raw)
        defer { XCTAssertNoThrow(try descriptor.close()) }
        let borrowed = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                try descriptor.withUnsafeFileDescriptor { _ in
                    borrowed.signal()
                    release.wait()
                }
            } catch {
                XCTFail("Unexpected descriptor access failure: \(error)")
            }
        }
        defer {
            release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        }
        XCTAssertEqual(borrowed.wait(timeout: .now() + 5), .success)
        self.assertDescriptorInUse(descriptor)
        XCTAssertGreaterThanOrEqual(fcntl(raw, F_GETFD), 0)
    }

    func testThrowingDescriptorCallbackRestoresAccess() throws {
        struct CallbackError: Error {}
        let raw = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(raw, 0)
        let descriptor = NIOUnixDomainSocketDescriptor(takingOwnershipOf: raw)
        defer { XCTAssertNoThrow(try descriptor.close()) }
        XCTAssertThrowsError(try descriptor.withUnsafeFileDescriptor { _ in throw CallbackError() }) { error in
            XCTAssertTrue(error is CallbackError)
        }
        XCTAssertEqual(try descriptor.withUnsafeFileDescriptor { $0 }, raw)
        XCTAssertNoThrow(try descriptor.close())
        XCTAssertEqual(fcntl(raw, F_GETFD), -1)
    }

    func testCloseIsIdempotentAndPreventsFurtherAccess() throws {
        let raw = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(raw, 0)
        let descriptor = NIOUnixDomainSocketDescriptor(takingOwnershipOf: raw)
        defer { try? descriptor.close() }
        XCTAssertEqual(try descriptor.withUnsafeFileDescriptor { $0 }, raw)
        try descriptor.close()
        XCTAssertEqual(fcntl(raw, F_GETFD), -1)
        XCTAssertNoThrow(try descriptor.close())
        XCTAssertThrowsError(try descriptor.withUnsafeFileDescriptor { $0 }) { error in
            XCTAssertEqual((error as? IOError)?.errnoCode, EBADF)
        }
        XCTAssertThrowsError(try descriptor.takeDescriptorOwnership())
    }

    func testDroppedDescriptorClosesAndTakeTransfersOwnership() throws {
        let raw = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(raw, 0)
        do {
            let descriptor = NIOUnixDomainSocketDescriptor(takingOwnershipOf: raw)
            _ = descriptor
        }
        XCTAssertEqual(fcntl(raw, F_GETFD), -1)
        let second = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(second, 0)
        do {
            let descriptor = NIOUnixDomainSocketDescriptor(takingOwnershipOf: second)
            XCTAssertEqual(try descriptor.takeDescriptorOwnership(), second)
            XCTAssertThrowsError(try descriptor.takeDescriptorOwnership())
        }
        XCTAssertGreaterThanOrEqual(fcntl(second, F_GETFD), 0)
        _ = close(second)
    }
}
#endif
