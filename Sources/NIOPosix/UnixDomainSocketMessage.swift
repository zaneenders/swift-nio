// SPDX-License-Identifier: Apache-2.0
#if !os(WASI)
import NIOConcurrencyHelpers
import NIOCore

#if os(Windows)
import ucrt
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// An owned file descriptor that can be transferred using `SCM_RIGHTS`.
///
/// References share ownership. The descriptor is closed when the last reference is released,
/// unless ownership has been taken. Closing or taking ownership while borrowed throws `EBUSY`.
public final class NIOUnixDomainSocketDescriptor: Sendable {
    private struct State: Sendable {
        var descriptor: CInt
        var borrows = 0
    }

    private let state: NIOLockedValueBox<State>

    /// Takes exclusive ownership of `descriptor`. The caller must not close it separately.
    /// A negative value creates an already-closed wrapper.
    public init(takingOwnershipOf descriptor: CInt) {
        self.state = NIOLockedValueBox(State(descriptor: descriptor))
    }

    deinit { try? self.close() }

    /// Borrows the descriptor for `body`. Do not close it or use it after `body` returns.
    /// Borrowing a closed descriptor throws `IOError` with `EBADF`.
    public func withUnsafeFileDescriptor<T>(_ body: (CInt) throws -> T) throws -> T {
        let fd = try self.beginBorrow()
        defer { self.endBorrow() }
        return try body(fd)
    }

    // A borrow count lets one send contain the same descriptor more than once, while preventing
    // close/take from invalidating any descriptor before sendmsg returns.
    internal func beginBorrow() throws -> CInt {
        try self.state.withLockedValue { state in
            guard state.descriptor >= 0 else { throw IOError(errnoCode: EBADF, reason: "descriptor closed") }
            state.borrows += 1
            return state.descriptor
        }
    }

    internal func endBorrow() {
        self.state.withLockedValue { state in
            assert(state.borrows > 0)
            state.borrows -= 1
        }
    }

    private func take() throws -> CInt {
        try self.state.withLockedValue { state in
            guard state.borrows == 0 else { throw IOError(errnoCode: EBUSY, reason: "descriptor in use") }
            defer { state.descriptor = -1 }
            return state.descriptor
        }
    }

    /// Transfers ownership to the caller, who must close the returned descriptor.
    /// Throws `IOError` with `EBUSY` if borrowed, or `EBADF` if already closed.
    public func takeDescriptorOwnership() throws -> CInt {
        let fd = try self.take()
        guard fd >= 0 else { throw IOError(errnoCode: EBADF, reason: "descriptor closed") }
        return fd
    }

    /// Closes the descriptor. Repeated calls have no effect. Throws `EBUSY` if borrowed.
    /// The wrapper remains closed even if the underlying close reports an error.
    public func close() throws {
        let fd = try self.take()
        if fd >= 0 {
            try Posix.close(descriptor: fd)
        }
    }
}

/// A payload and its associated Unix domain socket file descriptors.
///
/// Linux Unix stream channels receive and write `NIOUnixDomainSocketMessage<ByteBuffer>`.
/// A received value represents one stream read, not a protocol message boundary: application
/// messages may span reads or share a read. The descriptors must be interpreted by the protocol.
///
/// Writes with descriptors must contain at least one readable byte and at most 253 descriptors. Sending does not
/// close or transfer ownership of the sender's descriptors; the peer receives independent
/// descriptors referring to the same underlying resources. Keep the sender's descriptors open
/// until the write completes. Received descriptors are close-on-exec.
public struct NIOUnixDomainSocketMessage<Payload> {
    public var data: Payload
    public var descriptors: [NIOUnixDomainSocketDescriptor]

    public init(data: Payload, descriptors: [NIOUnixDomainSocketDescriptor] = []) {
        self.data = data
        self.descriptors = descriptors
    }
}

extension NIOUnixDomainSocketMessage: Sendable where Payload: Sendable {}

extension ChannelOptions.Types {
    /// Enables delivery of `NIOUnixDomainSocketMessage<ByteBuffer>` instead of `ByteBuffer` on reads.
    ///
    /// Defaults to `false`. Supported only by Linux Unix stream channels, including accepted
    /// channels configured through `ServerBootstrap.childChannelOption`.
    ///
    /// This option only changes the inbound type. Writing `NIOUnixDomainSocketMessage<ByteBuffer>`
    /// explicitly opts that write into descriptor transmission, without requiring the receiving
    /// pipeline to change. Ordinary `ByteBuffer` and `FileRegion` writes remain supported.
    public struct ReceiveFileDescriptors: ChannelOption, Sendable {
        public typealias Value = Bool
        public init() {}
    }
}
#endif  // !os(WASI)
