// SPDX-License-Identifier: Apache-2.0
#if os(Linux)
import Glibc
import NIOCore
import NIOPosix
import XCTest

private final class FDCollector: ChannelInboundHandler {
    typealias InboundIn = NIOUnixDomainSocketMessage
    let promise: EventLoopPromise<NIOUnixDomainSocketMessage>
    init(_ promise: EventLoopPromise<NIOUnixDomainSocketMessage>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.promise.succeed(self.unwrapInboundIn(data))
    }
}

final class UnixDomainSocketMessageTests: XCTestCase {
    private func closeChannel(_ channel: any Channel) throws {
        do { try channel.close().wait() } catch ChannelError.alreadyClosed {}
    }

    func testChannelTransfersMultipleOwnedCloseOnExecDescriptors() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0, &sockets), 0)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
        let received = group.next().makePromise(of: NIOUnixDomainSocketMessage.self)
        let server = try ClientBootstrap(group: group)
            .channelOption(ChannelOptions.Types.ReceiveFileDescriptors(), value: true)
            .channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(FDCollector(received))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.withConnectedSocket(sockets[0]).wait()
        defer { XCTAssertNoThrow(try self.closeChannel(server)) }
        let client = try ClientBootstrap(group: group)
            .channelOption(ChannelOptions.Types.ReceiveFileDescriptors(), value: true)
            .withConnectedSocket(sockets[1]).wait()
        defer { XCTAssertNoThrow(try self.closeChannel(client)) }
        let first = open("/dev/null", O_RDONLY | O_CLOEXEC)
        let second = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertGreaterThanOrEqual(second, 0)
        let descriptors = [first, second].map { NIOUnixDomainSocketDescriptor(takingOwnershipOf: $0) }
        var buffer = client.allocator.buffer(capacity: 4)
        buffer.writeString("test")
        try client.writeAndFlush(NIOUnixDomainSocketMessage(data: buffer, descriptors: descriptors)).wait()
        let message = try received.futureResult.wait()
        XCTAssertEqual(message.data.getString(at: message.data.readerIndex, length: 4), "test")
        XCTAssertEqual(message.descriptors.count, 2)
        for fd in message.descriptors {
            XCTAssertTrue(try fd.withUnsafeFileDescriptor { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 })
            try fd.close()
        }
        for fd in descriptors { try fd.close() }
    }

    func testDroppedDescriptorClosesAndTakeTransfersOwnership() throws {
        let raw = open("/dev/null", O_RDONLY | O_CLOEXEC)
        do {
            let descriptor = NIOUnixDomainSocketDescriptor(takingOwnershipOf: raw)
            _ = descriptor
        }
        XCTAssertEqual(fcntl(raw, F_GETFD), -1)
        let second = open("/dev/null", O_RDONLY | O_CLOEXEC)
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
