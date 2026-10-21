// SPDX-License-Identifier: Apache-2.0
import Synchronization

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// An owned SCM_RIGHTS descriptor. Copies share ownership; close/take are exactly-once.
public final class NIOUnixDomainSocketDescriptor: Sendable {
    private let descriptor: Mutex<CInt>

    public init(takingOwnershipOf descriptor: CInt) {
        self.descriptor = Mutex(descriptor)
    }

    deinit { try? self.close() }

    public func withUnsafeFileDescriptor<T>(_ body: (CInt) throws -> T) throws -> T {
        try self.descriptor.withLock { fd in
            guard fd >= 0 else { throw IOError(errnoCode: EBADF, reason: "descriptor closed") }
            return try body(fd)
        }
    }

    public func takeDescriptorOwnership() throws -> CInt {
        try self.descriptor.withLock { fd in
            guard fd >= 0 else { throw IOError(errnoCode: EBADF, reason: "descriptor closed") }
            let result = fd
            fd = -1
            return result
        }
    }

    public func close() throws {
        let fd = self.descriptor.withLock { fd in
            let value = fd
            fd = -1
            return value
        }
        if fd >= 0 {
            #if canImport(Glibc)
            _ = Glibc.close(fd)
            #elseif canImport(Darwin)
            _ = Darwin.close(fd)
            #endif
        }
    }
}

/// Bytes and ancillary FDs from one stream I/O operation. This is not a protocol message boundary.
public struct NIOUnixDomainSocketMessage: Sendable {
    public var data: ByteBuffer
    public var descriptors: [NIOUnixDomainSocketDescriptor]

    public init(data: ByteBuffer, descriptors: [NIOUnixDomainSocketDescriptor] = []) {
        self.data = data
        self.descriptors = descriptors
    }
}

extension ChannelOptions.Types {
    /// Linux Unix stream channels deliver NIOUnixDomainSocketMessage instead of ByteBuffer when enabled.
    public struct ReceiveFileDescriptors: ChannelOption, Sendable {
        public typealias Value = Bool
        public init() {}
    }
}
