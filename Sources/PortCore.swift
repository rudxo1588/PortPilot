import Foundation
import Darwin

struct ProcessIdentity: Hashable {
    var pid: Int32
    var uid: UInt32
    var owner: String
    var name: String
    var executable: String
    var startedSeconds: UInt64
    var startedMicroseconds: UInt64
    var effectiveUID: UInt32 = 0
    var savedUID: UInt32 = 0
    var pidVersion: UInt32 = 0
    var uniqueID: UInt64 = 0
    var isSystem: Bool = false
}

struct Listener: Hashable {
    var identity: ProcessIdentity?
    var pid: Int32
    var processName: String
    var owner: String
    var port: Int
    var address: String
    var javaApp: String?
    var blockedReason: String?
    var socketKey: String = ""
    var id: String { "\(pid):\(identity?.pidVersion ?? 0):\(socketKey.isEmpty ? address + ":" + String(port) : socketKey)" }
    var isJava: Bool {
        let executableName = identity.map { URL(fileURLWithPath: $0.executable).lastPathComponent.lowercased() } ?? processName.lowercased()
        return executableName == "java" || executableName == "javaw"
    }
    var isDevelopment: Bool {
        if isJava { return true }
        let executableName = identity.map { URL(fileURLWithPath: $0.executable).lastPathComponent.lowercased() } ?? processName.lowercased()
        let names = ["node", "nodejs", "python", "python3", "ruby", "php", "dotnet", "redis-server", "mongod", "postgres", "mysqld", "deno", "bun", "go", "cargo", "uvicorn", "gunicorn"]
        return names.contains(executableName) || executableName.range(of: #"^python3\.[0-9]+$"#, options: .regularExpression) != nil
    }
}

struct Snapshot {
    let scanBeganAt: Date
    let scanEndedAt: Date
    var listeners: [Listener]
    var warning: String?
}

struct ProcessLocation {
    let directory: String
    let projectName: String?

    var detail: String {
        projectName == nil ? "작업 폴더\n\(directory)" : "프로젝트 경로\n\(directory)"
    }

    func displayName(for process: String) -> String {
        if let projectName { return "\(process) · \(projectName)" }
        // Standalone Node scripts may have no package manifest. Show their working folder.
        if ["node", "nodejs", "bun", "deno"].contains(process.lowercased()),
           directory != "/", directory != FileManager.default.homeDirectoryForCurrentUser.path {
            return "\(process) · \((directory as NSString).lastPathComponent)"
        }
        return process
    }

    static func lookup(workingDirectory: String) -> ProcessLocation {
        let cwd = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
        let fallback = ProcessLocation(directory: cwd.path, projectName: nil)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let components = cwd.pathComponents
        guard !components.contains(where: { $0.hasSuffix(".app") }) else { return fallback }

        var candidate = cwd
        if let index = components.firstIndex(where: { ["node_modules", ".venv", ".git"].contains($0) }) {
            candidate = URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(index))), isDirectory: true)
        }
        let markers = [".git", "pyproject.toml", "Cargo.toml", "go.mod", "pom.xml", "settings.gradle",
                       "settings.gradle.kts", "build.gradle", "build.gradle.kts", "Package.swift"]
        while candidate.path != "/" && candidate.path != home.path {
            let manifest = candidate.appendingPathComponent("package.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                return ProcessLocation(directory: candidate.path, projectName: packageName(manifest) ?? candidate.lastPathComponent)
            }
            if markers.contains(where: { FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0).path) }) {
                return ProcessLocation(directory: candidate.path, projectName: candidate.lastPathComponent)
            }
            candidate.deleteLastPathComponent()
        }
        return fallback
    }

    private static func packageName(_ url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let limit = 1024 * 1024
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size > 0, metadata.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return PortService.displaySafe(name)
    }
}

struct ProcessUsage {
    let pid: Int32
    let name: String
    let cpuPercent: Double
    let residentBytes: Int64
    let startedAt: Date?
    var location: ProcessLocation? = nil

    var cpuText: String { String(format: "%.1f%%", cpuPercent) }
    var memoryText: String { ByteCountFormatter.string(fromByteCount: residentBytes, countStyle: .memory) }
}

struct ResourceSnapshot {
    let byCPU: [ProcessUsage]
    let byMemory: [ProcessUsage]
    let byPID: [Int32: ProcessUsage]
    let sampledAt: Date

    func usage(for listener: Listener, in ports: Snapshot) -> ProcessUsage? {
        guard let process = byPID[listener.pid], let start = process.startedAt else { return nil }
        if let identity = listener.identity {
            return start.timeIntervalSince1970 == Double(identity.startedSeconds) ? process : nil
        }
        // With no verified identity, the sampled process must span the whole port scan.
        // ps reports start times to the second.
        guard start.addingTimeInterval(1) <= ports.scanBeganAt, sampledAt >= ports.scanEndedAt else { return nil }
        return process
    }
}

struct SystemCapacity {
    let coreCount: Int
    let busyFraction: Double?
    let totalMemory: Int64
    let usedMemory: Int64?
    let sampledAt: Date
}

// Accessed exclusively on the resource sampling queue.
struct SystemCapacitySampler {
    private var previousCPU: (ticks: host_cpu_load_info_data_t, uptime: TimeInterval, cores: Int)?

    mutating func sample() -> SystemCapacity {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let system = ProcessInfo.processInfo
        let cores = system.activeProcessorCount
        let total = Int64(system.physicalMemory)
        let busy = sampleCPU(host: host, cores: cores, uptime: system.systemUptime)
        return SystemCapacity(coreCount: cores, busyFraction: busy, totalMemory: total,
                              usedMemory: usedMemory(host: host, total: total), sampledAt: Date())
    }

    private mutating func sampleCPU(host: host_t, cores: Int, uptime: TimeInterval) -> Double? {
        var info = host_cpu_load_info_data_t()
        let words = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(words)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: words) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS, count == words else {
            previousCPU = nil
            return nil
        }
        let previous = previousCPU
        previousCPU = (info, uptime, cores)
        guard let previous, cores == previous.cores, uptime - previous.uptime <= 15 else { return nil }

        // Mach counters wrap individually. CPU_STATE order is user, system, idle, nice.
        let now = info.cpu_ticks
        let old = previous.ticks.cpu_ticks
        let busy = UInt64(now.0 &- old.0) + UInt64(now.1 &- old.1) + UInt64(now.3 &- old.3)
        let total = busy + UInt64(now.2 &- old.2)
        return total > 0 ? Double(busy) / Double(total) : nil
    }

    private func usedMemory(host: host_t, total: Int64) -> Int64? {
        var info = vm_statistics64_data_t()
        let words = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(words)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: words) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard status == KERN_SUCCESS, count == words,
              host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0, total > 0 else { return nil }
        // Anonymous pages still needed by apps, wired RAM, and the compressor's physical pages.
        let appPages = max(0, Int64(info.internal_page_count) - Int64(info.purgeable_count))
        let usedPages = appPages + Int64(info.wire_count) + Int64(info.compressor_page_count)
        return min(total, usedPages * Int64(pageSize))
    }
}

struct Target {
    var identity: ProcessIdentity
    var listeners: [Listener]
}

struct TerminationResult {
    var target: Target
    var status: String
    var detail: String
    var needsForce: Bool
    var portsReleased: Bool?
}

enum PortError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

private struct RawListener {
    var pid: Int32
    var processName: String
    var uid: UInt32
    var owner: String
    var port: Int
    var address: String
    var socketKey: String
}

final class PortService {
    // Every signal re-reads all security properties. This protected cache only
    // expands a selected PID to every port; it never authorizes a signal.
    private var displayedListeners: [Listener] = []
    private let snapshotLock = NSLock()

    func snapshot() throws -> Snapshot {
        let snapshot = try readSnapshot()
        snapshotLock.lock()
        displayedListeners = snapshot.listeners
        snapshotLock.unlock()
        return snapshot
    }

    static func resourceSnapshot(listenerPIDs: Set<Int32> = []) throws -> ResourceSnapshot {
        // A private temporary file lets ps finish even if its output exceeds a pipe buffer.
        guard let output = tmpfile() else { throw PortError.message("프로세스 사용량을 수집할 수 없습니다.") }
        defer { fclose(output) }
        let handle = FileHandle(fileDescriptor: fileno(output), closeOnDealloc: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aww", "-o", "pid=", "-o", "pcpu=", "-o", "rss=", "-o", "lstart=", "-o", "comm="]
        process.environment = ["LC_ALL": "C", "TZ": "UTC0"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        let sampledAt = Date()
        try process.run()
        guard done.wait(timeout: .now() + 5) == .success else {
            if process.isRunning { process.terminate() }
            throw PortError.message("프로세스 사용량 조회 시간이 초과되었습니다.")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw PortError.message("프로세스 사용량을 읽을 수 없습니다.")
        }

        let byteCount = try handle.seekToEnd()
        guard byteCount <= 16 * 1024 * 1024 else { throw PortError.message("프로세스 목록이 너무 큽니다.") }
        try handle.seek(toOffset: 0)
        let data = try handle.readToEnd() ?? Data()
        let startFormat = DateFormatter()
        startFormat.locale = Locale(identifier: "en_US_POSIX")
        startFormat.timeZone = TimeZone(secondsFromGMT: 0)
        startFormat.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let rows = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line -> ProcessUsage? in
            let fields = line.split(maxSplits: 8, whereSeparator: \.isWhitespace)
            guard fields.count == 9,
                  let pid = Int32(fields[0]), pid >= 0, pid != process.processIdentifier,
                  let cpu = Double(fields[1]), cpu.isFinite, cpu >= 0,
                  let rss = Int64(fields[2]), rss >= 0, rss <= Int64.max / 1024 else { return nil }
            let startedAt = startFormat.date(from: fields[3...7].joined(separator: " "))
            let executable = fields[8].trimmingCharacters(in: .whitespaces)
            let name = (executable as NSString).lastPathComponent
            guard !name.isEmpty else { return nil }
            return ProcessUsage(pid: pid, name: name, cpuPercent: cpu, residentBytes: rss * 1024, startedAt: startedAt)
        }
        guard !rows.isEmpty else { throw PortError.message("조회 가능한 프로세스 사용량이 없습니다.") }
        let byCPU = rows.sorted {
            $0.cpuPercent == $1.cpuPercent ? $0.pid < $1.pid : $0.cpuPercent > $1.cpuPercent
        }
        let byMemory = rows.sorted {
            $0.residentBytes == $1.residentBytes ? $0.pid < $1.pid : $0.residentBytes > $1.residentBytes
        }
        let cpuLeaders = byCPU.prefix(3).map(\.pid)
        let memoryLeaders = byMemory.prefix(3).map(\.pid)
        var byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var locations: [String: ProcessLocation] = [:]
        for pid in listenerPIDs.union(cpuLeaders).union(memoryLeaders) {
            guard let start = byPID[pid]?.startedAt, start.timeIntervalSince1970 > 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard pp_working_directory(pid, UInt64(start.timeIntervalSince1970), &buffer, buffer.count) == 0,
                  let cwd = String(validatingUTF8: buffer) else { continue }
            let location = locations[cwd] ?? ProcessLocation.lookup(workingDirectory: cwd)
            locations[cwd] = location
            byPID[pid]?.location = location
        }
        return ResourceSnapshot(byCPU: cpuLeaders.compactMap { byPID[$0] }, byMemory: memoryLeaders.compactMap { byPID[$0] },
                                byPID: byPID, sampledAt: sampledAt)
    }

    func targets(from selected: [Listener]) -> [Target] {
        snapshotLock.lock()
        let displayedListeners = self.displayedListeners
        snapshotLock.unlock()
        let eligible = selected.filter { $0.blockedReason == nil && $0.identity != nil }
        let grouped = Dictionary(grouping: eligible, by: { $0.pid })
        return grouped.keys.sorted().compactMap { pid in
            guard let chosen = grouped[pid]?.first, let identity = chosen.identity,
                  grouped[pid]?.allSatisfy({ $0.identity == identity }) == true else { return nil }
            let all = displayedListeners.filter { $0.pid == pid }
            guard !all.isEmpty, all.allSatisfy({ $0.identity == identity && $0.blockedReason == nil }),
                  eligible.filter({ $0.pid == pid }).allSatisfy({ all.contains($0) }) else { return nil }
            return Target(identity: identity, listeners: all)
        }
    }

    func terminate(_ targets: [Target], timeout: TimeInterval = 4) -> [TerminationResult] {
        signalTargets(targets, signal: SIGTERM, timeout: max(0, min(timeout, 30)))
    }

    func force(_ targets: [Target]) -> [TerminationResult] {
        signalTargets(targets, signal: SIGKILL, timeout: 2)
    }

    private func signalTargets(_ targets: [Target], signal: Int32, timeout: TimeInterval) -> [TerminationResult] {
        let targets = deduplicated(targets)
        var results: [Int32: TerminationResult] = [:]
        var signaled: [Target] = []
        for target in targets {
            do {
                if let blocked = protectionReason(target.identity) {
                    results[target.identity.pid] = result(target, "종료 차단", blocked)
                    continue
                }
                // Identity bracket around fresh lsof protects snapshot labels
                // from PID/exec reuse. Then C checks identity immediately again.
                let current = try readSnapshot()
                guard current.warning == nil else {
                    results[target.identity.pid] = result(target, "종료 차단", "포트 조회가 완전하지 않아 안전하게 종료할 수 없습니다.")
                    continue
                }
                let observed = current.listeners.filter { $0.pid == target.identity.pid }
                let live = try readIdentity(target.identity.pid)
                guard live == target.identity else {
                    results[target.identity.pid] = result(target, "목록 변경", "시작 정보·소유자·실행 파일 변경 · 새로고침 후 재선택", portsReleased: releasedPorts(target, snapshot: current))
                    continue
                }
                guard !target.listeners.isEmpty,
                      target.listeners.allSatisfy({ $0.pid == live.pid && $0.identity == live && $0.blockedReason == nil }),
                      observed.allSatisfy({ $0.identity == live && $0.blockedReason == nil }),
                      listenerKeys(observed) == listenerKeys(target.listeners) else {
                    results[target.identity.pid] = result(target, "목록 변경", "LISTEN 포트 변경 · 새로고침 후 재선택", portsReleased: releasedPorts(target, snapshot: current))
                    continue
                }
                var raw = bridgeIdentity(live)
                let code = pp_signal_identity(&raw, signal)
                if code == 0 {
                    signaled.append(target)
                } else if code == ESRCH {
                    results[target.identity.pid] = result(target, "이미 종료됨", "신호 전송 전에 프로세스가 종료되었거나 실행 세대가 바뀌었습니다.")
                } else if code == ESTALE {
                    results[target.identity.pid] = result(target, "목록 변경", "종료 직전 프로세스 정보가 바뀌어 신호를 보내지 않았습니다.")
                } else {
                    results[target.identity.pid] = result(target, "종료 실패", safeError(code))
                }
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ESRCH) {
                results[target.identity.pid] = result(target, "이미 종료됨", "프로세스가 이미 종료되었습니다.")
            } catch {
                results[target.identity.pid] = result(target, "종료 차단", "종료 전 프로세스·포트 확인 실패 · 새로고침 후 재시도")
            }
        }
        // Only this app's helpers are ever spawned here. No shell, sudo, pkill,
        // process-group signal, or plain kill(pid) fallback exists.
        let deadline = Date().addingTimeInterval(timeout)
        var waiting = signaled
        while !waiting.isEmpty && Date() < deadline {
            waiting = waiting.filter {
                let observation = observeIdentity($0.identity)
                return observation == .same || observation == .unavailable
            }
            if !waiting.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }
        let finalSnapshot = try? readSnapshot()
        for target in signaled {
            let observation = observeIdentity(target.identity)
            let portState = finalSnapshot.flatMap { $0.warning == nil ? releasedPorts(target, snapshot: $0) : nil }
            if observation == .gone {
                let detail = portState == true ? "프로세스가 종료되었고 포트 해제를 확인했습니다." : portState == false ? "프로세스가 종료되었습니다. 같은 포트에 다른 LISTEN 항목이 있어 포트가 모두 비어 있지는 않습니다." : "프로세스가 종료되었습니다. 포트 해제 재확인은 실패했습니다."
                results[target.identity.pid] = result(target, signal == SIGKILL ? "강제 종료됨" : "종료됨", detail, portsReleased: portState)
            } else if observation == .different {
                results[target.identity.pid] = result(target, "프로세스 변경됨", "시작 정보·소유자·실행 파일 또는 실행 세대가 바뀌었습니다. 변경된 프로세스에는 추가 신호를 보내지 않습니다.", portsReleased: portState)
            } else if observation == .unavailable {
                results[target.identity.pid] = result(target, "종료 상태 확인 불가", "신호 전송 완료 · 시작 정보·소유자 확인 불가 · 새로고침 필요", portsReleased: portState)
            } else if portState == true {
                results[target.identity.pid] = result(target, "포트 해제됨", "포트는 해제됐지만 프로세스는 계속 실행 중입니다.", portsReleased: true)
            } else if let current = finalSnapshot, current.warning == nil,
                      listenerKeys(current.listeners.filter { $0.pid == target.identity.pid }) == listenerKeys(target.listeners),
                      current.listeners.filter({ $0.pid == target.identity.pid }).allSatisfy({ $0.identity == target.identity && $0.blockedReason == nil }) {
                results[target.identity.pid] = result(target, signal == SIGKILL ? "강제 종료 대기/실패" : "일반 종료 시간 초과", signal == SIGKILL ? "프로세스 실행 중 · 새로고침 필요" : "SIGTERM 후에도 실행 중 · 이 대상만 별도 확인 후 강제 종료 가능", needsForce: signal == SIGTERM, portsReleased: portState)
            } else {
                results[target.identity.pid] = result(target, "포트 목록 변경", "포트 상태 변경 또는 확인 실패 · 새로고침 후 남은 대상 재선택", portsReleased: portState)
            }
        }
        // Recheck ports for failures/already-exited targets as well.
        if let current = finalSnapshot, current.warning == nil {
            for target in targets where results[target.identity.pid]?.portsReleased == nil {
                results[target.identity.pid]?.portsReleased = releasedPorts(target, snapshot: current)
            }
        }
        return targets.compactMap { results[$0.identity.pid] }
    }

    private func result(_ target: Target, _ status: String, _ detail: String,
                        needsForce: Bool = false, portsReleased: Bool? = nil) -> TerminationResult {
        TerminationResult(target: target, status: status, detail: detail, needsForce: needsForce, portsReleased: portsReleased)
    }

    private enum IdentityObservation { case same, different, gone, unavailable }
    private func observeIdentity(_ expected: ProcessIdentity) -> IdentityObservation {
        do { return try readIdentity(expected.pid) == expected ? .same : .different }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ESRCH) { return .gone }
        catch { return .unavailable }
    }

    private func deduplicated(_ targets: [Target]) -> [Target] {
        // Conflicting representations of the same PID fail validation; never
        // pick one arbitrary target and signal it twice.
        Dictionary(grouping: targets, by: { $0.identity.pid }).keys.sorted().compactMap { pid in
            let samePID = targets.filter { $0.identity.pid == pid }
            guard let first = samePID.first else { return nil }
            if samePID.allSatisfy({ $0.identity == first.identity && listenerKeys($0.listeners) == listenerKeys(first.listeners) }) { return first }
            return Target(identity: first.identity, listeners: [])
        }
    }

    private func listenerKeys(_ listeners: [Listener]) -> Set<String> { Set(listeners.map { $0.id }) }
    private func releasedPorts(_ target: Target, snapshot: Snapshot) -> Bool {
        guard !target.listeners.isEmpty else { return false }
        return Set(target.listeners.map { $0.port }).isDisjoint(with: Set(snapshot.listeners.map { $0.port }))
    }

    private func readSnapshot() throws -> Snapshot {
        let scanBeganAt = Date()
        let (first, firstWarning) = try runLsof()
        let firstRows = try parseRows(first)
        var before: [Int32: ProcessIdentity] = [:]
        for pid in Set(firstRows.map { $0.pid }) {
            if let identity = try? readIdentity(pid) { before[pid] = identity }
        }
        let (second, secondWarning) = try runLsof()
        let rows = try parseRows(second)
        var after: [Int32: ProcessIdentity] = [:]
        var java: [Int32: String] = [:]
        for pid in Set(rows.map { $0.pid }) {
            if let identity = before[pid], URL(fileURLWithPath: identity.executable).lastPathComponent == "java" {
                var buffer = [CChar](repeating: 0, count: 128)
                if pp_java_app_identifier(pid, &buffer, buffer.count) == 0 {
                    java[pid] = String(cString: buffer)
                }
            }
            if let identity = try? readIdentity(pid), identity == before[pid] { after[pid] = identity }
        }
        let warning = firstWarning ?? secondWarning
        let listeners = rows.map { row -> Listener in
            let identity = after[row.pid]
            let blocked: String?
            if warning != nil { blocked = "포트 목록 불완전 · 새로고침 필요" }
            else if let identity {
                if row.uid != identity.uid && row.uid != identity.effectiveUID { blocked = "조회 중 소유자 정보가 변경되었습니다." }
                else { blocked = protectionReason(identity) }
            } else { blocked = "시작 정보·소유자를 안전하게 확인할 수 없습니다. 조회 중 변경 또는 접근 제한일 수 있습니다." }
            return Listener(identity: identity, pid: row.pid,
                            processName: Self.displaySafe(identity?.name ?? row.processName),
                            owner: Self.displaySafe(identity?.owner ?? row.owner), port: row.port,
                            address: row.address, javaApp: identity == nil ? nil : java[row.pid],
                            blockedReason: blocked, socketKey: row.socketKey)
        }.sorted { ($0.port, $0.pid, $0.address, $0.socketKey) < ($1.port, $1.pid, $1.address, $1.socketKey) }
        return Snapshot(scanBeganAt: scanBeganAt, scanEndedAt: Date(), listeners: listeners, warning: warning)
    }

    static func displaySafe(_ string: String) -> String {
        String(string.unicodeScalars.prefix(160).map { CharacterSet.controlCharacters.contains($0) ? "�" : String($0) }.joined())
    }

    private func readIdentity(_ pid: Int32) throws -> ProcessIdentity {
        var raw = PPIdentity()
        let code = pp_read_identity(pid, &raw)
        guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        let name = withUnsafePointer(to: &raw.name) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
        let executable = withUnsafePointer(to: &raw.executable) { $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) } }
        let owner = withUnsafePointer(to: &raw.owner) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        return ProcessIdentity(pid: raw.pid, uid: raw.uid, owner: Self.displaySafe(owner), name: Self.displaySafe(name),
                               executable: executable, startedSeconds: raw.started_seconds,
                               startedMicroseconds: raw.started_microseconds,
                               effectiveUID: raw.effective_uid, savedUID: raw.saved_uid,
                               pidVersion: raw.pid_version, uniqueID: raw.unique_id,
                               isSystem: (raw.flags & 1) != 0)
    }

    private func bridgeIdentity(_ identity: ProcessIdentity) -> PPIdentity {
        var raw = PPIdentity()
        raw.pid = identity.pid
        raw.uid = identity.uid
        raw.effective_uid = identity.effectiveUID
        raw.saved_uid = identity.savedUID
        raw.pid_version = identity.pidVersion
        raw.unique_id = identity.uniqueID
        raw.started_seconds = identity.startedSeconds
        raw.started_microseconds = identity.startedMicroseconds
        raw.flags = identity.isSystem ? 1 : 0
        let bytes = Array(identity.executable.utf8.prefix(4095)) + [0]
        withUnsafeMutableBytes(of: &raw.executable) { $0.copyBytes(from: bytes) }
        return raw
    }

    private func protectionReason(_ identity: ProcessIdentity) -> String? {
        if getuid() == 0 || getuid() != geteuid() { return "이 앱은 일반 사용자 권한으로 실행해야 합니다." }
        if identity.pid == getpid() { return "PortPilot · 종료 불가" }
        if identity.pid <= 1 || identity.uid == 0 || identity.effectiveUID == 0 || identity.savedUID == 0 || identity.isSystem { return "시스템 프로세스 · 종료 불가" }
        if identity.uid != getuid() || identity.effectiveUID != getuid() || identity.savedUID != getuid() { return "다른 사용자 또는 권한이 바뀐 프로세스는 종료할 수 없습니다." }
        if ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains(where: { identity.executable.hasPrefix($0) }) { return "시스템 실행 파일 · 종료 불가" }
        return nil
    }

    private func safeError(_ code: Int32) -> String {
        switch code {
        case EPERM, EACCES: return "현재 사용자 권한으로 신호를 보낼 수 없습니다. 관리자 권한은 요청하지 않습니다."
        case ENOTSUP, EINVAL: return "안전한 프로세스 식별 API를 사용할 수 없어 종료를 차단했습니다."
        default: return "신호 전송에 실패했습니다 (오류 \(code))."
        }
    }

    private func runLsof() throws -> (Data, String?) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PortPilot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("out")
        let errorURL = directory.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-F0pcuLftnT"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !process.isRunning else {
            // No plain-PID signal is sent even to this owned read-only helper.
            // A delayed helper can finish naturally; its temp files are unlinked.
            throw PortError.message("포트 조회 시간이 초과되었습니다.")
        }
        process.waitUntilExit()
        let outputData = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        let errorData = try Data(contentsOf: errorURL, options: .mappedIfSafe)
        guard outputData.count <= 16 * 1024 * 1024, errorData.count <= 1024 * 1024 else { throw PortError.message("포트 조회 결과가 너무 큽니다.") }
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 || (process.terminationStatus == 1 && outputData.isEmpty && errorData.isEmpty) else {
            throw PortError.message("포트 조회 실패 · 권한 또는 lsof 상태 확인 필요")
        }
        return (outputData, errorData.isEmpty ? nil : "lsof 조회에 경고가 있어 목록이 불완전할 수 있습니다. 종료는 차단됩니다.")
    }

    private func parseRows(_ data: Data) throws -> [RawListener] {
        guard let output = String(data: data, encoding: .utf8) else { throw PortError.message("포트 조회 결과의 인코딩을 읽을 수 없습니다.") }
        var pid: Int32?
        var processName = ""
        var owner = ""
        var uid: UInt32?
        var descriptor: String?
        var family = ""
        var endpoint: String?
        var listening = false
        var rows: [RawListener] = []
        func finishFile() throws {
            guard descriptor != nil else { return }
            defer { descriptor = nil; family = ""; endpoint = nil; listening = false }
            guard listening, let endpoint else { return }
            guard let pid, let uid, let descriptor, family == "IPv4" || family == "IPv6",
                  let separator = endpoint.lastIndex(of: ":"), let port = Int(endpoint[endpoint.index(after: separator)...]),
                  (1...65535).contains(port), !endpoint.contains("->") else { throw PortError.message("구조화된 LISTEN 결과가 올바르지 않습니다.") }
            let address = String(endpoint[..<separator])
            guard !address.isEmpty, !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw PortError.message("LISTEN 주소를 안전하게 읽을 수 없습니다.") }
            rows.append(RawListener(pid: pid, processName: processName, uid: uid, owner: owner.isEmpty ? String(uid) : owner,
                                    port: port, address: address, socketKey: "\(descriptor)|\(family)|\(endpoint)"))
        }
        for token in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let token = token.drop(while: { $0 == "\n" || $0 == "\r" })
            guard let kind = token.first else { continue }
            let value = String(token.dropFirst())
            switch kind {
            case "p":
                try finishFile()
                guard let parsed = Int32(value), parsed > 0 else { throw PortError.message("올바르지 않은 PID 조회 결과입니다.") }
                pid = parsed; processName = ""; owner = ""; uid = nil
            case "c": processName = value
            case "u": uid = UInt32(value)
            case "L": owner = value
            case "f": try finishFile(); descriptor = value
            case "t": family = value
            case "n": endpoint = value
            case "T": if value == "ST=LISTEN" { listening = true }
            default: break
            }
        }
        try finishFile()
        return rows
    }

    // Synthetic parser seam: permits testing secret suppression without reading
    // a real process's command line. Production only receives sanitized output.
    static func safeJavaIdentifier(_ arguments: [String]) -> String? {
        var pointers: [UnsafePointer<CChar>?] = arguments.map { strdup($0).map { UnsafePointer($0) } }
        defer { for pointer in pointers { if let pointer { free(UnsafeMutablePointer(mutating: pointer)) } } }
        var output = [CChar](repeating: 0, count: 128)
        let code = pp_java_identifier_from_argv(Int32(pointers.count), &pointers, &output, output.count)
        return code == 0 ? String(cString: output) : nil
    }
}
