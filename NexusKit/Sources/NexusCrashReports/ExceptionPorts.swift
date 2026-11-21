import Darwin

// The Mach exception ports of this process for the kinds of crash that SentryCrash catches. Each
// program that Nexus starts inherits the exception ports of Nexus. With the ports of SentryCrash, a
// crash of MariaDB or PHP arrives at the handler of Nexus. Sentry then reports it as a crash of
// Nexus and turns itself off, and a later crash of such a program can hang (Sentry NEXUS-8). So
// Nexus puts back the ports from before the start of Sentry. A crash of Nexus itself still reaches
// the signal handler of SentryCrash.
struct ExceptionPorts {
    static let crashMask = exception_mask_t(EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_SOFTWARE | EXC_MASK_BREAKPOINT)

    struct Handler {
        let mask: exception_mask_t
        let port: mach_port_t
        let behavior: exception_behavior_t
        let flavor: thread_state_flavor_t
    }

    let handlers: [Handler]

    static func current() -> ExceptionPorts {
        let capacity = Int(EXC_TYPES_COUNT)
        var masks = [exception_mask_t](repeating: 0, count: capacity)
        var ports = [mach_port_t](repeating: 0, count: capacity)
        var behaviors = [exception_behavior_t](repeating: 0, count: capacity)
        var flavors = [thread_state_flavor_t](repeating: 0, count: capacity)
        var count = mach_msg_type_number_t(capacity)

        guard task_get_exception_ports(mach_task_self_, crashMask, &masks, &count, &ports, &behaviors, &flavors) == KERN_SUCCESS else {
            return ExceptionPorts(handlers: [])
        }

        return ExceptionPorts(handlers: (0..<Int(count)).map { index in
            Handler(mask: masks[index], port: ports[index], behavior: behaviors[index], flavor: flavors[index])
        })
    }

    // A kind of crash without a handler in the saved list gets no port. Then macOS handles it as in
    // a process without Sentry.
    func restore() {
        task_set_exception_ports(mach_task_self_, Self.crashMask, mach_port_t(MACH_PORT_NULL), EXCEPTION_DEFAULT, THREAD_STATE_NONE)

        for handler in handlers where handler.port != mach_port_t(MACH_PORT_NULL) {
            task_set_exception_ports(mach_task_self_, handler.mask, handler.port, handler.behavior, handler.flavor)
        }
    }
}
