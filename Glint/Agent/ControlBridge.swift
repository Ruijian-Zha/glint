import Foundation
import Darwin
import AppKit

/// Outbound-action sibling of `AgentBridge`. Where `AgentBridge` is
/// inbound-only (CLI agents report *status* to Glint), this is the one channel
/// that takes a *command*: a trusted local process — the orchestrator agent
/// running in a pane — asks Glint to spawn a worker. One JSON request line in,
/// one JSON reply line out, on a per-user Unix domain socket:
///
///     {"op":"spawn_worker","name":"pai-next-w1-foo","cwd":"/abs/worktree",
///      "input":"cd '/abs/worktree' && claude --resume 'pai-next-orchestrator-main' \
///               --fork-session -n 'pai-next-w1-foo' \"Read ./TASK.md and begin.\"\n"}
///     → {"ok":true,"workspace_id":"<uuid>","pane_id":0}
///
/// Two guardrails are non-negotiable and enforced *here in code*, not in any
/// agent prompt (a looping orchestrator must not be able to fork without
/// bound, per the repo principle that unbounded-harm constraints live in code):
///   1. Every spawn shows a modal human-approval gate before acting.
///   2. A hard `maxWorkers` ceiling rejects further spawns.
/// Socket hardening (0600 inside a 0700 `~/.glint/run`) mirrors `AgentBridge`.
final class ControlBridge {
    static let shared = ControlBridge()

    /// Hard ceiling on concurrently live worker workspaces.
    private let maxWorkers = 3
    /// Worker workspaces are named with this prefix (see worker-spawn.sh). Used
    /// both to count live workers and — later — to refuse worker-spawns-worker.
    private let workerPrefix = "pai-next-w"

    private(set) var socketPath: String = ""
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "glint.control.bridge", qos: .utility)

    private init() {}

    /// Bind + listen on `~/.glint/run/control.sock` (debug build: a separate
    /// filename so a dev and a prod Glint don't fight over the path — same
    /// rationale as `AgentBridge`).
    func start() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let runDir = home
            .appendingPathComponent(".glint", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: runDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            NSLog("[glint] control run dir create failed: \(error)")
            return
        }
        chmod(runDir.path, 0o700)

        #if DEBUG
        let path = runDir.appendingPathComponent("control-debug.sock").path
        #else
        let path = runDir.appendingPathComponent("control.sock").path
        #endif
        socketPath = path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[glint] control socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                let dstPtr = dst.baseAddress!.assumingMemoryBound(to: CChar.self)
                _ = strlcpy(dstPtr, src, dst.count)
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, addrLen)
            }
        }
        guard bindRC == 0 else {
            NSLog("[glint] control bind(\(path)) failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        chmod(path, 0o600)

        guard listen(fd, 8) == 0 else {
            NSLog("[glint] control listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        acceptSource = src
        NSLog("[glint] control bridge listening on \(path)")
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        // The read itself is quick; the human-approval wait happens after, gated
        // by its own semaphore timeout (not this socket option).
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve(fd: client) }
    }

    private struct Request: Decodable {
        let op: String
        let name: String?
        let cwd: String?
        let input: String?
    }

    /// Read one JSON request line, act (count → approve → spawn) on the main
    /// actor, write one JSON reply line. Runs off the accept queue.
    private func serve(fd: Int32) {
        defer { close(fd) }

        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while !buf.contains(0x0A) {
            let n = tmp.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.read(fd, bp.baseAddress, bp.count)
            }
            if n <= 0 { break }
            buf.append(tmp, count: n)
            if buf.count > (1 << 20) { break }   // sanity cap
        }
        let line = buf.firstIndex(of: 0x0A).map { buf.subdata(in: buf.startIndex..<$0) } ?? buf

        guard let req = try? JSONDecoder().decode(Request.self, from: line) else {
            reply(fd, ["ok": false, "error": "bad_request"]); return
        }
        guard req.op == "spawn_worker",
              let name = req.name, let cwd = req.cwd, let input = req.input,
              !name.isEmpty, !cwd.isEmpty, !input.isEmpty else {
            reply(fd, ["ok": false, "error": "unsupported_op"]); return
        }

        // Hop to the main actor to touch the store + show the alert. Bridge the
        // async result back to this serve thread with a semaphore so the reply
        // is written on the same connection the orchestrator is blocked reading.
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = ["ok": false, "error": "internal"]
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let store = WorkspaceStore.current else {
                    result = ["ok": false, "error": "no_store"]; sem.signal(); return
                }
                let live = store.workspaces.filter { $0.name.hasPrefix(self.workerPrefix) }.count
                if live >= self.maxWorkers {
                    result = ["ok": false, "error": "max_workers", "max": self.maxWorkers]
                    sem.signal(); return
                }
                if !self.confirmSpawn(name: name, cwd: cwd) {
                    result = ["ok": false, "error": "declined"]; sem.signal(); return
                }
                let (wsID, paneID) = store.spawnWorker(name: name, cwd: cwd, initialInput: input)
                result = ["ok": true,
                          "workspace_id": wsID.uuidString,
                          "pane_id": Int(paneID.value)]
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 120)   // a human has up to 2 min to approve
        reply(fd, result)
    }

    /// The non-negotiable human-in-the-loop gate. Modal so the orchestrator
    /// cannot spawn anything the user did not explicitly approve.
    @MainActor private func confirmSpawn(name: String, cwd: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Spawn worker agent?"
        alert.informativeText = """
        An orchestrator is requesting a new worker:

        \(name)
        at \(cwd)

        A new workspace will open and run a forked claude session.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Decline")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func reply(_ fd: Int32, _ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            _ = Darwin.write(fd, raw.baseAddress, raw.count)
        }
    }
}
