import Darwin

// The exact arguments of the programs that run now. ps joins the arguments with spaces. So its text
// does not show where a path with a space ends.
public enum ProcessArguments {
    // Each list starts with the program as it was started.
    public static func ofPrograms(named name: String) -> [[String]] {
        runningProcessNumbers().filter { self.name(of: $0) == name }.compactMap(arguments(of:))
    }

    private static func runningProcessNumbers() -> [pid_t] {
        let count = proc_listallpids(nil, 0)

        guard count > 0 else {
            return []
        }

        // A process can start between the two calls.
        var numbers = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&numbers, Int32(numbers.count * MemoryLayout<pid_t>.size))

        return Array(numbers.prefix(Int(max(found, 0))))
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))

        return String(decoding: buffer.prefix(Int(max(length, 0))).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // The data starts with the number of arguments and the path of the program. Zero bytes follow.
    // Then each argument comes with a zero byte at its end.
    static func arguments(of pid: pid_t) -> [String]? {
        var query = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0

        guard sysctl(&query, 3, nil, &size, nil, 0) == 0 else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: size)

        guard sysctl(&query, 3, &bytes, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }

        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var rest = bytes[MemoryLayout<Int32>.size..<size].drop { $0 != 0 }.drop { $0 == 0 }
        var arguments: [String] = []

        for _ in 0..<count where !rest.isEmpty {
            let argument = rest.prefix { $0 != 0 }

            arguments.append(String(decoding: argument, as: UTF8.self))
            rest = rest.dropFirst(argument.count + 1)
        }

        return arguments
    }
}
