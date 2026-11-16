import Darwin

// nexusd holds a listener for each stopped workspace server and two sockets for each connection
// of a start (plan item 3e). launchd gives a new job a soft limit of 256 descriptors. A child of
// Process gets a higher soft limit from a higher limit of nexusd.
public enum DescriptorLimit {
    public static let wanted = rlim_t(OPEN_MAX)

    // The new soft limit, or nil when the limit stays.
    public static func raised(_ current: rlimit) -> rlim_t? {
        let target = min(current.rlim_max, wanted)
        return current.rlim_cur < target ? target : nil
    }

    public static func raise() {
        var limit = rlimit()

        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, let soft = raised(limit) else {
            return
        }

        limit.rlim_cur = soft
        setrlimit(RLIMIT_NOFILE, &limit)
    }
}
