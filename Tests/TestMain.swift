import Foundation
import Darwin

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

private final class Fixture {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let pid: Int32
    let ports: [Int]

    init(binary: String, mode: String = "normal", count: Int = 1, port: Int = 0,
         address: String = "127.0.0.1") throws {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [mode, String(count), String(port), address]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        var line = Data()
        while true {
            guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
                throw CheckFailure(description: "Test listener did not report readiness")
            }
            if byte[0] == 10 { break }
            line.append(byte)
            if line.count > 1024 { throw CheckFailure(description: "Invalid readiness record") }
        }
        guard let record = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let fixturePID = record["pid"] as? Int,
              let fixturePorts = record["ports"] as? [Int] else {
            throw CheckFailure(description: "Invalid readiness record")
        }
        pid = Int32(fixturePID)
        ports = fixturePorts
        try require(pid == process.processIdentifier, "Fixture PID differs from child Process PID")
    }

    func command(_ command: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }

    func waitForExit(seconds: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        return !process.isRunning
    }

    func finish() {
        try? input.fileHandleForWriting.close()
        _ = waitForExit()
        try? output.fileHandleForReading.close()
    }

    deinit { finish() }
}

private func replacementIdentity(_ identity: ProcessIdentity, pid: Int32? = nil,
                                 uid: UInt32? = nil, effectiveUID: UInt32? = nil,
                                 savedUID: UInt32? = nil, pidVersion: UInt32? = nil,
                                 startedSeconds: UInt64? = nil, name: String? = nil) -> ProcessIdentity {
    var changed = identity
    changed.pid = pid ?? identity.pid
    changed.uid = uid ?? identity.uid
    changed.effectiveUID = effectiveUID ?? identity.effectiveUID
    changed.savedUID = savedUID ?? identity.savedUID
    changed.pidVersion = pidVersion ?? identity.pidVersion
    changed.startedSeconds = startedSeconds ?? identity.startedSeconds
    changed.name = name ?? identity.name
    return changed
}

private func replacementTarget(_ target: Target, _ identity: ProcessIdentity) -> Target {
    Target(identity: identity, listeners: target.listeners.map {
        var listener = $0
        listener.identity = identity
        listener.pid = identity.pid
        listener.processName = identity.name
        listener.owner = identity.owner
        return listener
    })
}

@main
private struct TestMain {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw CheckFailure(description: "Usage: core_tests test_listener report.json")
        }
        let binary = CommandLine.arguments[1]
        let report = CommandLine.arguments[2]
        let service = PortService()
        var fixtures: [Fixture] = []
        var checks: [[String: Any]] = []

        func fixture(_ mode: String = "normal", _ count: Int = 1, port: Int = 0,
                     address: String = "127.0.0.1") throws -> Fixture {
            let child = try Fixture(binary: binary, mode: mode, count: count, port: port, address: address)
            fixtures.append(child)
            return child
        }

        func target(_ fixture: Fixture) throws -> Target {
            let rows = try service.snapshot().listeners.filter { $0.pid == fixture.pid }
            try require(Set(rows.map(\.port)) == Set(fixture.ports), "Snapshot missed a fixture listening port")
            let targets = service.targets(from: rows)
            try require(targets.count == 1, "Fixture did not produce one PID target")
            return targets[0]
        }

        func run(_ name: String, _ body: () throws -> String) {
            do {
                let evidence = try body()
                checks.append(["name": name, "passed": true, "evidence": evidence])
                print("PASS \(name): \(evidence)")
            } catch {
                checks.append(["name": name, "passed": false, "evidence": String(describing: error)])
                print("FAIL \(name): \(error)")
            }
        }

        run("normal_sigterm_and_port_release") {
            let child = try fixture()
            let selected = try target(child)
            let results = service.terminate([selected], timeout: 1)
            try require(results.count == 1, "Expected one result")
            try require(!results[0].needsForce, "Normal listener incorrectly requested force")
            try require(child.waitForExit(), "SIGTERM did not stop test listener")
            try require(results[0].portsReleased == true, "Terminated listener ports were not reported released")
            try require(try service.snapshot().listeners.allSatisfy { $0.pid != child.pid }, "Listener remains in snapshot")
            return "SIGTERM stopped owned listener and listening port was rechecked as released"
        }

        run("multiple_ports_one_pid_deduplicated") {
            let child = try fixture("normal", 2)
            let selected = try target(child)
            let firstRow = try service.snapshot().listeners.first { $0.pid == child.pid }
            try require(firstRow != nil, "Expected fixture row")
            let grouped = service.targets(from: [firstRow!, firstRow!, selected.listeners.last!])
            try require(grouped.count == 1, "Duplicate rows produced multiple PID targets")
            try require(Set(grouped[0].listeners.map(\.port)).count == 2, "Grouped target lost a listening port")
            let results = service.terminate([grouped[0], grouped[0]], timeout: 1)
            try require(results.count == 1 && child.waitForExit(), "Deduplicated termination did not finish once")
            try require(results[0].portsReleased == true, "Both listening ports were not released")
            return "Repeated selection and two ports produced one termination result and both ports released"
        }

        run("ignored_sigterm_requires_explicit_force") {
            let child = try fixture("ignore-term")
            let selected = try target(child)
            let graceful = service.terminate([selected], timeout: 0.25)
            try require(graceful.count == 1 && graceful[0].needsForce, "Ignored TERM did not request explicit force")
            try require(child.process.isRunning, "Timeout automatically killed listener")
            try require(graceful[0].portsReleased == false, "Ignored TERM listener lost its port unexpectedly")
            let forced = service.force([selected, selected]) // Explicit test decision, only this owned fixture.
            try require(forced.count == 1 && !forced[0].needsForce, "Explicit force result invalid")
            try require(child.waitForExit(), "Explicit SIGKILL did not terminate fixture")
            try require(forced[0].portsReleased == true, "Forced listener port was not rechecked as released")
            return "Listener survived TERM timeout; explicit force ended it and released port"
        }

        run("already_exited_target") {
            let child = try fixture()
            let selected = try target(child)
            try child.command("x")
            try require(child.waitForExit(), "Fixture did not exit through its control channel")
            let result = service.terminate([selected], timeout: 0.1)
            try require(result.count == 1 && !result[0].needsForce, "Exited process was incorrectly force eligible")
            try require(result[0].portsReleased == true, "Already exited listener port was not reported released")
            return "Stale row for an already exited fixture returned a non-force result with port released"
        }

        run("changed_listening_ports_block_term") {
            let child = try fixture("normal", 2)
            let selected = try target(child)
            try child.command("c")
            let deadline = Date().addingTimeInterval(1)
            var changed = false
            while Date() < deadline {
                let current = try service.snapshot().listeners.filter { $0.pid == child.pid }
                if !current.contains(where: { $0.port == child.ports[0] }) { changed = true; break }
                Thread.sleep(forTimeInterval: 0.025)
            }
            try require(changed, "Fixture first port did not close")
            let result = service.terminate([selected], timeout: 0.1)
            try require(result.count == 1 && !result[0].needsForce, "Changed row became force eligible")
            try require(child.process.isRunning, "Changed port set still allowed SIGTERM")
            return "Closing a previously selected port blocked termination while fixture kept running"
        }

        run("changed_ports_block_force") {
            let child = try fixture("ignore-term", 2)
            let selected = try target(child)
            let graceful = service.terminate([selected], timeout: 0.2)
            try require(graceful.first?.needsForce == true, "Expected test force candidate")
            try child.command("c")
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                if try service.snapshot().listeners.filter({ $0.pid == child.pid }).count == 1 { break }
                Thread.sleep(forTimeInterval: 0.025)
            }
            let forced = service.force([selected])
            try require(forced.count == 1 && !forced[0].needsForce, "Stale forced target remains force eligible")
            try require(child.process.isRunning, "Changed port set still allowed SIGKILL")
            return "Force path revalidated stale port selection and left changed fixture running"
        }

        run("new_listening_port_blocks_term") {
            let child = try fixture()
            let selected = try target(child)
            try child.command("a")
            let deadline = Date().addingTimeInterval(1)
            var changed = false
            while Date() < deadline {
                if try service.snapshot().listeners.filter({ $0.pid == child.pid }).count == 2 { changed = true; break }
                Thread.sleep(forTimeInterval: 0.025)
            }
            try require(changed, "Fixture did not add another listening port")
            let result = service.terminate([selected], timeout: 0.1)
            try require(result.count == 1 && !result[0].needsForce && child.process.isRunning, "Additional listener did not block stale termination")
            return "A new port after selection invalidated the complete saved port set before TERM"
        }

        run("conflicting_duplicate_targets_block_term") {
            let child = try fixture()
            let selected = try target(child)
            let changed = replacementIdentity(selected.identity, startedSeconds: selected.identity.startedSeconds + 1)
            let result = service.terminate([selected, replacementTarget(selected, changed)], timeout: 0.1)
            try require(result.count == 1 && !result[0].needsForce && child.process.isRunning, "Conflicting representations of same PID were signaled")
            return "Conflicting saved identities for one PID yielded one blocked result and no signal"
        }

        run("port_recheck_detects_other_test_listener") {
            let child = try fixture()
            let other = try fixture(port: child.ports[0], address: "::1")
            let selected = try target(child)
            let result = service.terminate([selected], timeout: 1)
            try require(result.count == 1 && child.waitForExit(), "First test listener did not terminate")
            try require(other.process.isRunning, "Independent test listener was signaled")
            try require(result[0].portsReleased == false, "Port was reported free while other test listener still bound it")
            return "Terminated only selected IPv4 fixture; same numbered port on IPv6 loopback remained busy"
        }

        run("start_time_identity_change_blocked") {
            let child = try fixture()
            let selected = try target(child)
            let changed = replacementIdentity(selected.identity, startedSeconds: selected.identity.startedSeconds + 1)
            let result = service.terminate([replacementTarget(selected, changed)], timeout: 0.1)
            try require(result.count == 1 && !result[0].needsForce && child.process.isRunning, "Changed process start time was signaled")
            return "Synthetic changed start time blocked signaling of live owned listener"
        }

        run("pid_generation_change_blocked") {
            let child = try fixture()
            let selected = try target(child)
            let changed = replacementIdentity(selected.identity, pidVersion: selected.identity.pidVersion &+ 1)
            let result = service.terminate([replacementTarget(selected, changed)], timeout: 0.1)
            try require(result.count == 1 && !result[0].needsForce && child.process.isRunning, "Changed PID generation was signaled")
            return "Synthetic PID generation mismatch blocked signaling, covering PID reuse guard"
        }

        run("native_bridge_identity_recheck") {
            let child = try fixture()
            var identity = PPIdentity()
            try require(pp_read_identity(child.pid, &identity) == 0, "Native bridge could not read owned fixture identity")
            var staleGeneration = identity
            staleGeneration.pid_version &+= 1
            let generationResult = pp_signal_identity(&staleGeneration, SIGTERM)
            try require(generationResult == ESTALE && child.process.isRunning, "Native bridge signaled changed PID generation")
            var staleStart = identity
            staleStart.started_seconds &+= 1
            let startResult = pp_signal_identity(&staleStart, SIGTERM)
            try require(startResult == ESTALE && child.process.isRunning, "Native bridge signaled changed start time")
            var staleUniqueID = identity
            staleUniqueID.unique_id &+= 1
            let uniqueResult = pp_signal_identity(&staleUniqueID, SIGTERM)
            try require(uniqueResult == ESTALE && child.process.isRunning, "Native bridge signaled changed unique process ID")
            return "Native signal bridge independently rejected three stale identities before any signal"
        }

        run("native_bridge_already_exited_failure") {
            let child = try fixture()
            var identity = PPIdentity()
            try require(pp_read_identity(child.pid, &identity) == 0, "Native bridge could not read owned fixture identity")
            try child.command("x")
            try require(child.waitForExit(), "Fixture did not exit through its control channel")
            let result = pp_signal_identity(&identity, SIGTERM)
            try require(result == ESRCH, "Native bridge did not return no-such-process failure")
            return "Native signal path reported ESRCH for exited owned listener without fallback signaling"
        }

        run("other_owner_protected") {
            let child = try fixture()
            let selected = try target(child)
            let changed = replacementIdentity(selected.identity, uid: selected.identity.uid + 1,
                                              effectiveUID: selected.identity.uid + 1, savedUID: selected.identity.uid + 1)
            let result = service.terminate([replacementTarget(selected, changed)], timeout: 0.1)
            try require(result.count == 1 && !result[0].needsForce && child.process.isRunning, "Other-owner target was signaled")
            return "Synthetic different owner blocked termination without requesting elevated privilege"
        }

        run("system_process_protected") {
            let child = try fixture()
            let selected = try target(child)
            let changed = replacementIdentity(selected.identity, pid: 1, uid: 0, effectiveUID: 0, savedUID: 0, name: "launchd")
            let result = service.terminate([replacementTarget(selected, changed)], timeout: 0.1)
            try require(result.count == 1 && !result[0].needsForce && child.process.isRunning, "System PID guard failed")
            return "Synthetic root-owned PID 1 target was refused before any signal"
        }

        run("own_app_process_protected") {
            let child = try fixture()
            let selected = try target(child)
            let changed = replacementIdentity(selected.identity, pid: getpid())
            let result = service.terminate([replacementTarget(selected, changed)], timeout: 0.1)
            try require(result.count == 1 && !result[0].needsForce && child.process.isRunning, "Self PID guard failed")
            return "Synthetic current app PID target was refused and test runner survived"
        }

        fixtures.forEach { $0.finish() }
        let failed = checks.filter { ($0["passed"] as? Bool) != true }.count
        let document: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "platform": "macOS native Swift and C, no new dependencies",
            "scope": "Only test-owned loopback listeners were signaled. No user server or IDE was terminated.",
            "passed": checks.count - failed,
            "failed": failed,
            "checks": checks,
            "limitations": ["Real PID reuse and privileged/other-user processes are modeled with altered saved identities; no privileged process was signaled.", "Kernel EPERM signal failure is not induced because privilege changes are outside test scope.", "UI flow is checked separately by the application builder."]
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: report))
        print("RESULT \(checks.count - failed)/\(checks.count) passed; report: \(report)")
        exit(failed == 0 ? 0 : 1)
    }
}
