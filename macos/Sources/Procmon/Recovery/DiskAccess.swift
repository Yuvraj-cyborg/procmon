// Opens a disk for reading, sector by sector.
//
// Physical disks belong to root, so macOS's `authopen` asks for an
// administrator's password and hands back one read-only file descriptor over
// a socket. Procmon itself never runs as root and can never write.

import Darwin
import Foundation
import Security

enum DiskAccessError: Error, Equatable, CustomStringConvertible {
    case cancelled
    case denied
    case failed(String)

    var description: String {
        switch self {
        case .cancelled: "Reading the disk needs an administrator's password."
        case .denied: "macOS didn't allow reading the disk."
        case .failed(let detail): "The disk couldn't be opened: \(detail)"
        }
    }
}

enum DiskAccess {
    /// Opens `path` read-only, asking for a password only if it must.
    /// Blocks while the password dialog is up: never call on the main thread.
    static func open(_ path: String, prompt: String) throws(DiskAccessError) -> RawDevice {
        let direct = Darwin.open(path, O_RDONLY)
        let descriptor: Int32
        if direct >= 0 {
            descriptor = direct
        } else if errno == EACCES || errno == EPERM {
            descriptor = try openAuthorized(path, prompt: prompt)
        } else {
            throw .failed(String(cString: strerror(errno)))
        }
        do {
            return try RawDevice(descriptor: descriptor, path: path)
        } catch {
            throw .failed(error.description)
        }
    }

    private static func openAuthorized(_ path: String, prompt: String) throws(DiskAccessError) -> Int32 {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let authorization = reference else {
            throw .failed("no authorization session")
        }
        defer { AuthorizationFree(authorization, []) }

        // Ask for the right ourselves, so the dialog names Procmon and says why.
        let status = "sys.openfile.readonly.\(path)".withCString { right in
            "prompt".withCString { key in
                prompt.withCString { text in
                    var item = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(name: key, valueLength: strlen(text), value: UnsafeMutableRawPointer(mutating: text), flags: 0)
                    return withUnsafeMutablePointer(to: &item) { items in
                        withUnsafeMutablePointer(to: &promptItem) { environmentItems in
                            var rights = AuthorizationRights(count: 1, items: items)
                            var environment = AuthorizationEnvironment(count: 1, items: environmentItems)
                            return AuthorizationCopyRights(authorization, &rights, &environment, [.interactionAllowed, .extendRights, .preAuthorize], nil)
                        }
                    }
                }
            }
        }
        switch status {
        case errAuthorizationSuccess: break
        case errAuthorizationCanceled: throw .cancelled
        default: throw .denied
        }
        var external = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(authorization, &external) == errAuthorizationSuccess else {
            throw .failed("the authorization couldn't be passed on")
        }

        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw .failed(String(cString: strerror(errno))) }
        defer { close(sockets[0]) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        process.arguments = ["-stdoutpipe", "-extauth", "-o", String(O_RDONLY), path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: false)
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            close(sockets[1])
            throw .failed(error.localizedDescription)
        }
        // The child has its own copy; closing ours lets a failed child read as end of file.
        close(sockets[1])
        let form = withUnsafeBytes(of: &external) { Data($0) }
        try? input.fileHandleForWriting.write(contentsOf: form)
        try? input.fileHandleForWriting.close()
        let descriptor = receiveDescriptor(sockets[0])
        process.waitUntilExit()
        guard let descriptor else {
            throw process.terminationStatus == 0 ? .failed("authopen sent nothing back") : .denied
        }
        return descriptor
    }

    /// Reads one file descriptor sent with `SCM_RIGHTS`.
    static func receiveDescriptor(_ socket: Int32) -> Int32? {
        // `struct cmsghdr` is 12 bytes; the descriptor follows it.
        let controlSize = 64
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: 8)
        defer { control.deallocate() }
        control.initializeMemory(as: UInt8.self, repeating: 0, count: controlSize)
        var byte: UInt8 = 0
        return withUnsafeMutablePointer(to: &byte) { data in
            var vector = iovec(iov_base: UnsafeMutableRawPointer(data), iov_len: 1)
            return withUnsafeMutablePointer(to: &vector) { vectors in
                var message = msghdr(
                    msg_name: nil, msg_namelen: 0, msg_iov: vectors, msg_iovlen: 1,
                    msg_control: control, msg_controllen: socklen_t(controlSize), msg_flags: 0
                )
                var received: Int
                repeat {
                    received = recvmsg(socket, &message, 0)
                } while received < 0 && errno == EINTR
                guard received >= 0, message.msg_controllen >= 16,
                      control.load(as: UInt32.self) >= 16,
                      control.load(fromByteOffset: 4, as: Int32.self) == SOL_SOCKET,
                      control.load(fromByteOffset: 8, as: Int32.self) == SCM_RIGHTS
                else { return nil }
                return control.load(fromByteOffset: 12, as: Int32.self)
            }
        }
    }
}
