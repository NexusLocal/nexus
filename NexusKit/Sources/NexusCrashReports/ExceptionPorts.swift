import Darwin

// The Mach exception ports of this process for each kind of exception, also a kind that a later
// version of Sentry catches. Each program that Nexus starts inherits the exception ports of Nexus.
// With the ports of SentryCrash, a crash of MariaDB or PHP arrives at the handler of Nexus. Sentry
// then reports it as a crash of Nexus and turns itself off. A later crash of such a program can
// then hang (Sentry NEXUS-8). So Nexus puts back the ports from before the start of Sentry. A crash
// of Nexus itself still reaches the signal handler of SentryCrash. The value holds a send right for
// each port, and restore() uses them up. So it cannot be copied.
struct ExceptionPorts: ~Copyable {
    // EXC_MASK_ALL of mach/exception_types.h. Swift does not import that macro.
    static let allKinds = exception_mask_t(
        EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_EMULATION | EXC_MASK_SOFTWARE | EXC_MASK_BREAKPOINT
            | EXC_MASK_SYSCALL | EXC_MASK_MACH_SYSCALL | EXC_MASK_RPC_ALERT | EXC_MASK_RESOURCE | EXC_MASK_GUARD | EXC_MASK_MACHINE
    )

    struct Handler {
        let mask: exception_mask_t
        let port: mach_port_t
        let behavior: exception_behavior_t
        let flavor: thread_state_flavor_t
    }

    let handlers: [Handler]

    // No ports when macOS does not give them. Then restore() leaves each kind without a port, as in
    // a process without Sentry.
    static func current() -> ExceptionPorts {
        let capacity = Int(EXC_TYPES_COUNT)
        var masks = [exception_mask_t](repeating: 0, count: capacity)
        var ports = [mach_port_t](repeating: 0, count: capacity)
        var behaviors = [exception_behavior_t](repeating: 0, count: capacity)
        var flavors = [thread_state_flavor_t](repeating: 0, count: capacity)
        var count = mach_msg_type_number_t(capacity)

        guard task_get_exception_ports(mach_task_self_, allKinds, &masks, &count, &ports, &behaviors, &flavors) == KERN_SUCCESS else {
            return ExceptionPorts(handlers: [])
        }

        return ExceptionPorts(handlers: (0..<Int(count)).map { index in
            Handler(mask: masks[index], port: ports[index], behavior: behaviors[index], flavor: flavors[index])
        })
    }

    // A kind without a handler in the saved list gets no port. The task keeps its own right after
    // each set, so the right of the read goes.
    @discardableResult
    consuming func restore() -> Bool {
        var restored = task_set_exception_ports(mach_task_self_, Self.allKinds, mach_port_t(MACH_PORT_NULL), EXCEPTION_DEFAULT, THREAD_STATE_NONE) == KERN_SUCCESS

        for handler in handlers where handler.port != mach_port_t(MACH_PORT_NULL) {
            restored = task_set_exception_ports(mach_task_self_, handler.mask, handler.port, handler.behavior, handler.flavor) == KERN_SUCCESS && restored
            mach_port_deallocate(mach_task_self_, handler.port)
        }

        return restored
    }
}
