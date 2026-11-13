import AkiCore
import Foundation
#if os(Linux)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor func procChecks() async throws {
    // MARK: Processes on Linux (/proc, read from a folder laid out like it)

    print("proc")
    let proc = temp.appending(path: "proc")
    func fakeProcess(_ pid: Int32, comm: String, parent: Int32, startTicks: Int = 0) throws {
        let folder = proc.appending(path: "\(pid)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("\(pid) (\(comm)) S \(parent) 1 1 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 \(startTicks) 1000 100\n".utf8)
            .write(to: folder.appending(path: "stat"))
    }
    try fakeProcess(4242, comm: "node", parent: 77)
    try fakeProcess(4243, comm: "tmux: a) (b", parent: 4242)
    let procFS = ProcFS(root: proc)
    check(procFS.parent(of: 4242) == 77, "a process's parent")
    check(procFS.parent(of: 4243) == 4242, "a name with spaces and parentheses doesn't shift the fields")
    check(procFS.parent(of: 9999) == nil, "no parent for a process that's gone")
    try Data("cpu  1 2 3\nbtime 1794527844\nprocesses 9\n".utf8).write(to: proc.appending(path: "stat"))
    try fakeProcess(4244, comm: "claude", parent: 1, startTicks: 94_203)
    check(ProcFS(root: proc, ticksPerSecond: 100).started(4244).map { abs($0.timeIntervalSince1970 - 1_794_528_786.03) < 0.001 } == true,
          "when a process started: boot time plus its start in clock ticks")
    check(procFS.started(9999) == nil, "no start for a process that's gone")
    try FileManager.default.createSymbolicLink(atPath: proc.appending(path: "4242/cwd").path, withDestinationPath: "/repo/wt")
    check(procFS.cwd(of: 4242) == "/repo/wt", "a process's folder")
    check(procFS.cwd(of: 4243) == nil, "none when it can't be read")
    try Data("PATH=/bin\0ORCA_TERMINAL_HANDLE=term_1\0QUERY=a=b\0".utf8).write(to: proc.appending(path: "4242/environ"))
    check(procFS.environment(of: 4242)?["ORCA_TERMINAL_HANDLE"] == "term_1", "a process's environment")
    check(procFS.environment(of: 4242)?["QUERY"] == "a=b", "a value keeps its own =")
    check(procFS.environment(of: 4243) == nil, "none when it can't be read")
    try fakeProcess(4245, comm: "deleted folder", parent: 1)
    try FileManager.default.createSymbolicLink(atPath: proc.appending(path: "4245/cwd").path, withDestinationPath: "/repo/wt (deleted)")
    check(procFS.cwd(of: 4245) == "/repo/wt", "a deleted working folder keeps its original path")
    try FileManager.default.removeItem(at: proc.appending(path: "4245/cwd"))
    try FileManager.default.createSymbolicLink(atPath: proc.appending(path: "4245/cwd").path, withDestinationPath: "/repo/deleted files/wt")
    check(procFS.cwd(of: 4245) == "/repo/deleted files/wt", "deleted within a legitimate folder name stays intact")
    let existingDeletedFolder = temp.appending(path: "wt (deleted)")
    try FileManager.default.createDirectory(at: existingDeletedFolder, withIntermediateDirectories: true)
    try fakeProcess(4246, comm: "existing folder", parent: 1)
    try FileManager.default.createSymbolicLink(atPath: proc.appending(path: "4246/cwd").path, withDestinationPath: existingDeletedFolder.path)
    check(procFS.cwd(of: 4246) == existingDeletedFolder.path, "an existing working folder preserves its literal deleted suffix")
    try Data("KEY=first\0KEY=second\0EMPTY=\0".utf8).write(to: proc.appending(path: "4245/environ"))
    check(procFS.environment(of: 4245)?["KEY"] == "first", "the first duplicate environment key wins, as on macOS")
    check(procFS.environment(of: 4245)?["EMPTY"] == "", "an empty environment value is preserved")
    check(AgentSessions.terminalHandle(inEnvironment: ["ORCA_TERMINAL_HANDLE": "term_linux"]) == "term_linux", "Linux Orca identity uses the injected environment")
    check(AgentSessions.terminalHandle(inEnvironment: ["ORCA_TERMINAL_HANDLE": ""]) == nil, "an empty Linux Orca handle is absent")
    check(AgentSessions.terminalHandle(inEnvironment: [:]) == nil, "a missing Linux Orca handle is absent")
    // Listening sockets and descriptors from a proc fixture, without invoking lsof.
    let net = proc.appending(path: "net")
    try FileManager.default.createDirectory(at: net, withIntermediateDirectories: true)
    try Data("  sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n 0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 800 1\n 1: 00000000:1F91 00000000:0000 0A 0 0 0 1000 0 801\n 2: 0100007F:1F92 00000000:0000 01 0 0 0 1000 0 802\n 3: 0100007F:1F93 00000000:0000 0A 0 0 0 1001 0 803\n".utf8).write(to: net.appending(path: "tcp"))
    try Data("  sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n 0: 00000000000000000000000001000000:1F94 0 0A 0 0 0 1000 0 804\n 1: 00000000000000000000000000000000:1F95 0 0A 0 0 0 1000 0 805\n".utf8).write(to: net.appending(path: "tcp6"))
    let descriptors = proc.appending(path: "4242/fd")
    try FileManager.default.createDirectory(at: descriptors, withIntermediateDirectories: true)
    for inode in [800, 801, 802, 804, 805] {
        try FileManager.default.createSymbolicLink(atPath: descriptors.appending(path: "\(inode)").path, withDestinationPath: "socket:[\(inode)]")
    }
    try FileManager.default.createSymbolicLink(atPath: descriptors.appending(path: "9").path, withDestinationPath: "/logs/rollout-fixture.jsonl")
    let fixturePorts = Worktree.listeningPorts(lsof: procFS.listeningSockets(), host: "localhost")
    check(fixturePorts[8080] == 4242 && fixturePorts[8081] == 4242 && fixturePorts[8084] == 4242 && fixturePorts[8085] == 4242,
          "procfs discovers IPv4/IPv6 loopback and wildcard listeners")
    check(fixturePorts[8082] == nil && fixturePorts[8083] == nil, "non-listening sockets and unreadable owners stay out")
    check(procFS.openFiles(of: 4242).contains("/logs/rollout-fixture.jsonl"), "procfs reads open file links")
    check(procFS.openFiles(of: 9999).isEmpty, "unreadable descriptor directories are empty")
    // CPU snapshots use the same stat fixture as parent/start-time discovery.
    let cpuProc = ProcFS(root: proc, ticksPerSecond: 100)
    let cpuBefore = cpuProc.cpuSample(of: 4244, at: 10)!
    var cpuStat = try String(contentsOf: proc.appending(path: "4244/stat"), encoding: .utf8)
    cpuStat = cpuStat.replacingOccurrences(of: "0 0 0 0 0 0 0 0 20", with: "0 0 0 0 20 5 0 0 20")
    try Data(cpuStat.utf8).write(to: proc.appending(path: "4244/stat"))
    let cpuAfter = cpuProc.cpuSample(of: 4244, at: 10.25)!
    #if os(Linux)
    var cpuTracker = AgentSessions.CPUTracker()
    check(AgentSessions.readsCPU("codex") && AgentSessions.readsCPU("claude") &&
          AgentSessions.readsCPU("/Application Support/Claude/claude-code/1/MacOS/claude --input-format stream-json"),
          "CPU sampling includes interactive agents and Claude app sessions")
    check(!AgentSessions.readsCPU("sleep 1") && !AgentSessions.readsCPU("aki wait") && !AgentSessions.readsCPU("codex exec"),
          "CPU sampling excludes non-agents, wait listeners and headless commands")
    check(cpuTracker.needsBaseline([4244: cpuBefore]), "first readable agent needs a baseline")
    check(!cpuTracker.needsBaseline([:]), "unreadable agents do not trigger a sampling delay")
    _ = cpuTracker.update([4244: cpuBefore], using: cpuProc)
    check(!cpuTracker.needsBaseline([4244: cpuAfter]), "existing agent samples need no extra interval when unrelated processes appear")
    check(cpuTracker.update([4244: cpuAfter], using: cpuProc)[4244] == 100, "first pair of samples reports a working agent")
    let cpuIdle = cpuProc.cpuSample(of: 4244, at: 10.5)!
    check(cpuTracker.update([4244: cpuIdle], using: cpuProc)[4244] == 0, "each scan renews the sample even when an agent is idle")
    check(cpuTracker.update([4244: cpuIdle], using: cpuProc)[4244] == 0, "zero elapsed time stays idle")
    let cpuResumedStat = cpuStat.replacingOccurrences(of: "0 0 0 0 20 5 0 0 20", with: "0 0 0 0 45 5 0 0 20")
    try Data(cpuResumedStat.utf8).write(to: proc.appending(path: "4244/stat"))
    let cpuResumed = cpuProc.cpuSample(of: 4244, at: 10.75)!
    check(cpuTracker.update([4244: cpuResumed], using: cpuProc)[4244] == 100, "a resumed agent uses the latest idle sample, not a long-term average")
    try Data(cpuStat.utf8).write(to: proc.appending(path: "4244/stat"))
    _ = cpuTracker.update([:], using: cpuProc)
    check(cpuTracker.needsBaseline([4244: cpuIdle]), "vanished agents are removed from the sampling cache")
    _ = cpuTracker.update([4244: cpuIdle], using: cpuProc)
    #endif
    check(cpuProc.cpuPercent(from: cpuBefore, to: cpuAfter) == 100, "recent CPU counts user and system ticks, even for a long-lived process")
    check(cpuProc.cpuPercent(from: cpuAfter, to: cpuProc.cpuSample(of: 4244, at: 10.5)!) == 0, "a previous CPU burst becomes idle when ticks stop")
    try fakeProcess(4244, comm: "replacement", parent: 1, startTicks: 95_000)
    check(cpuProc.cpuPercent(from: cpuBefore, to: cpuProc.cpuSample(of: 4244, at: 11)!) == nil, "a reused PID never inherits CPU")
    #if os(Linux)
    let cpuReplacement = cpuProc.cpuSample(of: 4244, at: 11)!
    check(cpuTracker.needsBaseline([4244: cpuReplacement]), "reused agent PID needs a new baseline")
    check(cpuTracker.update([4244: cpuReplacement], using: cpuProc)[4244] == 0, "reused PID cannot inherit the previous agent's CPU")
    #endif
    check(cpuProc.cpuPercent(from: cpuBefore, to: cpuBefore) == nil, "zero sample interval has no CPU percentage")
    check(cpuProc.cpuSample(of: 9999, at: 12) == nil, "a vanished process has no CPU sample")
    #if os(Linux)
    check(ProcFS().parent(of: getpid()) == getppid(), "this process's parent, from the real /proc")
    check(ProcFS().cwd(of: getpid()) == FileManager.default.currentDirectoryPath, "and its folder")
    check(ProcFS().environment(of: getpid())?["PATH"] == ProcessInfo.processInfo.environment["PATH"], "and its environment")
    #endif

}
