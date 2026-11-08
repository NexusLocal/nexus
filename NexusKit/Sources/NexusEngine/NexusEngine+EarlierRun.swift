import Darwin
import Foundation
import NexusCore
import NexusRuntime
import NexusSupervisor

// A crash of nexusd leaves its services without a supervisor. launchd becomes their parent. They
// keep their ports, so the next start of each service fails, and the new nexusd shows them as
// stopped. The real path of their program finds them, because Redis and PostgreSQL write over the
// list of their arguments and their environment. A program of this data folder is never a service
// of another nexusd. Each gets the stop signal of its service, so a database writes its data to disk
// first. The services then start as after a normal stop of nexusd.
extension NexusEngine {
    struct RunningProgram: Equatable {
        let pid: Int32
        let parent: Int32
        let path: String
    }

    private static let leftoverStopTimeout: Duration = .seconds(30)

    func endServicesOfEarlierRun() async {
        var services: [String: (id: String, definition: ServiceDefinition)] = [:]

        for runtime in await serviceRuntimes() {
            guard let id = catalog.serviceID(for: runtime), let definition = try? await serviceDefinition(id) else {
                continue
            }

            services[RealPath.of(definition.executable)] = (id, definition)
        }

        let leftovers = Self.leftovers(in: Self.runningPrograms(), services: services.mapValues(\.id))

        await withTaskGroup(of: Void.self) { group in
            for leftover in leftovers {
                let definition = services.values.first { $0.id == leftover.id }?.definition
                activity?.write("leftover", "nexusd stops \(leftover.id) of an earlier run (process \(leftover.pid))")

                group.addTask {
                    await Self.stop(pid: leftover.pid, signal: definition?.stopSignal ?? SIGTERM, timeout: definition?.stopTimeout ?? Self.leftoverStopTimeout)
                }
            }
        }
    }

    // Only a program whose parent is launchd counts. A service of this nexusd is its child, and a
    // worker of a service, such as a worker of nginx, is the child of that service.
    static func leftovers(in programs: [RunningProgram], services: [String: String]) -> [(pid: Int32, id: String)] {
        programs
            .filter { $0.parent == 1 }
            .compactMap { program in services[program.path].map { (program.pid, $0) } }
    }

    static func runningPrograms() -> [RunningProgram] {
        let count = proc_listallpids(nil, 0)

        guard count > 0 else {
            return []
        }

        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))

        return pids.prefix(Int(max(filled, 0))).compactMap { pid in
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)

            guard pid > 0,
                  proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else {
                return nil
            }

            return RunningProgram(pid: pid, parent: Int32(info.pbi_ppid), path: String(cString: path))
        }
    }

    // A service that does not end in its time gets SIGKILL, so its port is free for the new start.
    static func stop(pid: Int32, signal: Int32, timeout: Duration) async {
        guard kill(pid, signal) == 0 else {
            return
        }

        let deadline = ContinuousClock.now + timeout

        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }
}
