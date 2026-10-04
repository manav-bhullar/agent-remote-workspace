// mac-listener: the Mac-side "doorbell".
// Listens on TCP 4455. When the server connects (network came back), it runs
// auto-mount-smb.sh --wakeup so the share is remounted immediately.
//
// Build:  swiftc -O mac-listener.swift -o ~/.scripts/mac-listener
import Foundation

let port: UInt16 = 4455
let script = NSHomeDirectory() + "/.scripts/auto-mount-smb.sh"

// On any setup failure: log and exit so launchd (KeepAlive) restarts us,
// instead of spinning on a dead socket.
func fail(_ what: String) -> Never {
    let msg = "mac-listener: \(what) failed: \(String(cString: strerror(errno)))\n"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(1)
}

let sockfd = socket(AF_INET, SOCK_STREAM, 0)
if sockfd < 0 { fail("socket") }

var opt: Int32 = 1
setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_in()
addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = in_port_t(port.bigEndian)
addr.sin_addr.s_addr = INADDR_ANY

let bound = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        bind(sockfd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
if bound != 0 { fail("bind") }
if listen(sockfd, 5) != 0 { fail("listen") }

// Only react to our own devices: Tailscale addresses are 100.64.0.0/10
func isTailscale(_ a: in_addr) -> Bool {
    let ip = UInt32(bigEndian: a.s_addr)
    return ip & 0xFFC0_0000 == 0x6440_0000
}

while true {
    var peer = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let client = withUnsafeMutablePointer(to: &peer) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            accept(sockfd, sockaddrPtr, &len)
        }
    }
    if client < 0 {
        if errno == EINTR || errno == ECONNABORTED { continue }
        fail("accept")
    }
    close(client)
    guard isTailscale(peer.sin_addr) else { continue }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [script, "--wakeup"]
    try? task.run()
}
