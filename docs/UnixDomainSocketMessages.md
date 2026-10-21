# Unix stream FD messages — Linux prototype

Related: [apple/swift-nio#3316](https://github.com/apple/swift-nio/pull/3316).
This fork implements the `SCM_RIGHTS` subset needed by a Swift Wayland client;
it does not expose arbitrary `cmsghdr` payloads and is not an upstream-ready,
cross-platform API proposal.

```swift
ClientBootstrap(group: group)
    .channelOption(ChannelOptions.Types.ReceiveFileDescriptors(), value: true)
    .connect(unixDomainSocketPath: path)

NIOUnixDomainSocketMessage(
    data: bytes,                                      // ByteBuffer
    descriptors: [ownedDescriptor]                    // [NIOUnixDomainSocketDescriptor]
)
```

```text
Outbound NIOUnixDomainSocketMessage
  → PendingStreamWrite { IOData, descriptors, promise }
    → sendmsg(msghdr)
      └─ cmsghdr { SOL_SOCKET, SCM_RIGHTS, [CInt] }
          EAGAIN / zero bytes → keep descriptor queue
          first written byte → drop queued descriptor references
          remaining bytes    → ordinary write / writev

Inbound recvmsg(MSG_CMSG_CLOEXEC)
  → bytes + zero/more SCM_RIGHTS descriptors
    → NIOUnixDomainSocketMessage
      → protocol ByteBuffer decoder
```

## Ownership and boundaries

```swift
NIOUnixDomainSocketDescriptor: Sendable
    // Shared identity; Mutex<CInt> protects close / take / synchronous access.

try descriptor.withUnsafeFileDescriptor { fd in /* synchronous borrow */ }
let fd = try descriptor.takeDescriptorOwnership()      // caller now closes fd
try descriptor.close()                                // idempotent
// Last reference disappearing also closes an untaken descriptor.
```

- A stream read is not a protocol-message boundary. Protocols must keep byte and
  FD queues independently ordered; descriptors can accompany only part of a message.
- `ByteBuffer` contains wire bytes, not a serialized `cmsghdr` or FD integer.
  The kernel transfers descriptors out-of-band through `sendmsg` / `recvmsg`.
- Enabling the channel option changes inbound values from `ByteBuffer` to
  `NIOUnixDomainSocketMessage`, including reads with no FDs. Enable it before reading.
  The prototype also requires it for outbound FD messages.
- A descriptor-bearing outbound value requires at least one byte. `writev` cannot
  cross a queued ancillary-data boundary. Partial-write retries must not resend FDs.
- Copies of a descriptor wrapper share ownership. Keep it open until the write
  completes; closing a queued descriptor causes the write to fail. The syscall
  temporarily duplicates descriptors to prevent close/reuse races during `sendmsg`.
- Receive rejects truncated ancillary data and closes received descriptors on failure.
  The scratch/control limit is 256 descriptors; kernel limits can be smaller.

## Difference from a generic cmsghdr API

```text
cmsghdr                         // native ABI mechanism: level + type + payload
  ├─ SCM_RIGHTS                 // this prototype
  ├─ credentials               // not implemented here
  ├─ timestamps                // not implemented here
  └─ other platform messages   // not implemented here
```

The earlier PR introduced stream `AddressedEnvelope<ByteBuffer>` writes and FD
metadata. This implementation instead uses a dedicated Unix stream message:
no destination address, multiple owned FDs, receive support, and partial-write
bookkeeping. Both approaches use `cmsghdr` at the syscall boundary.

Before upstreaming: agree the stream/control-message envelope API with maintainers,
reuse NIO's existing control-message infrastructure where possible, preserve NIO's
supported platform/deployment/compiler matrix, extend beyond Linux, and expand
failure/truncation/close-race tests. The prototype adds a `Synchronization.Mutex`
based descriptor owner and has only been validated with Swift 6.4.1 on Linux.

## Checks

```sh
swift test --filter 'UnixDomainSocketMessageTests|ChannelTests.testDescriptorWrites|ChannelTests.testPendingWrites'
```

The companion `shape-tree/packages/swift-wayland` suite additionally exercises
fragmented/coalesced Wayland bytes, independent FD ordering, write backpressure,
server-created IDs, EOF cleanup, and cancellable registry/configure startup.
