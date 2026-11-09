import Foundation
import NexusCore

// nexus dump-filter (owner, 2026-11-09, docs/dump-url-rewrite.md). nexusd puts it between the
// reader of a WordPress dump and the client of the database. A separate program keeps a crash out of
// nexusd. NexusCLI.main runs it before the parser, so it is not in nexus --help.
//
//     nexus dump-filter --plan <json> [--report <file>] [--no-output]
//
// The plan is a SQLDumpFilter.Plan. The report is a SQLDumpFilter.Report, written at the end.
// --no-output reads the dump only for the report, for the check of a new dump file.
enum DumpFilterRun {
    static let name = "dump-filter"
    static let usageError: Int32 = 64
    static let failure: Int32 = 74

    static func run(_ arguments: [String]) -> Int32 {
        guard let options = Options(arguments) else {
            fail("Usage: nexus dump-filter --plan <json> [--report <file>] [--no-output]")
            return usageError
        }

        let filter = SQLDumpFilter(plan: options.plan)
        let output = Output(writes: options.writes)
        let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 1)
        defer { chunk.deallocate() }

        while true {
            let count = read(STDIN_FILENO, chunk.baseAddress, chunk.count)

            if count < 0, errno == EINTR {
                continue
            }

            guard count >= 0 else {
                fail("The dump cannot be read: \(String(cString: strerror(errno))).")
                return failure
            }

            if count == 0 {
                break
            }

            filter.feed(UnsafeRawBufferPointer(rebasing: chunk[0..<count]), write: output.write)

            if let problem = output.problem {
                fail(problem)
                return failure
            }
        }

        filter.finish(write: output.write)
        output.flush()

        if let problem = output.problem {
            fail(problem)
            return failure
        }

        if let reportFile = options.reportFile {
            do {
                try JSONEncoder().encode(filter.report).write(to: URL(filePath: reportFile), options: .atomic)
            } catch {
                fail("The report cannot be written: \(ErrorText.plain(error))")
                return failure
            }
        }

        return 0
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("nexus dump-filter: \(message)\n".utf8))
    }

    struct Options {
        let plan: SQLDumpFilter.Plan
        let reportFile: String?
        let writes: Bool

        init?(_ arguments: [String]) {
            var plan: SQLDumpFilter.Plan?
            var reportFile: String?
            var writes = true
            var index = 0

            while index < arguments.count {
                switch arguments[index] {
                case "--plan" where index + 1 < arguments.count:
                    plan = try? JSONDecoder().decode(SQLDumpFilter.Plan.self, from: Data(arguments[index + 1].utf8))
                    index += 2
                case "--report" where index + 1 < arguments.count:
                    reportFile = arguments[index + 1]
                    index += 2
                case "--no-output":
                    writes = false
                    index += 1
                default:
                    return nil
                }
            }

            guard let plan else {
                return nil
            }

            self.plan = plan
            self.reportFile = reportFile
            self.writes = writes
        }
    }

    // Collects the output in blocks of 1 MB. A closed pipe, for example after a failure of mysql,
    // ends the filter.
    final class Output {
        private let writes: Bool
        private var buffer: [UInt8] = []
        private(set) var problem: String?

        init(writes: Bool) {
            self.writes = writes
            buffer.reserveCapacity(1 << 20)
        }

        func write(_ bytes: UnsafeRawBufferPointer) {
            guard writes, problem == nil else {
                return
            }

            buffer.append(contentsOf: bytes)

            if buffer.count >= 1 << 20 {
                flush()
            }
        }

        func flush() {
            guard writes, problem == nil, !buffer.isEmpty else {
                return
            }

            buffer.withUnsafeBytes { bytes in
                var offset = 0

                while offset < bytes.count {
                    let written = Foundation.write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)

                    if written < 0, errno == EINTR {
                        continue
                    }

                    guard written > 0 else {
                        problem = "The output cannot be written: \(String(cString: strerror(errno)))."
                        return
                    }

                    offset += written
                }
            }

            buffer.removeAll(keepingCapacity: true)
        }
    }
}
