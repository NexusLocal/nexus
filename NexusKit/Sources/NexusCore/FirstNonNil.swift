extension Sequence {
    // The first value that the transform gives, with one call for each element. lazy.compactMap
    // calls its transform two times for an element. A transform that reads the disk can then get
    // nil the second time, and the force unwrap of the standard library stops the process.
    public func firstNonNil<Result>(_ transform: (Element) throws -> Result?) rethrows -> Result? {
        for element in self {
            if let result = try transform(element) {
                return result
            }
        }

        return nil
    }
}
