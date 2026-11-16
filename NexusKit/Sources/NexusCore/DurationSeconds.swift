import Foundation

extension Duration {
    // The seconds of the duration for the APIs that take a TimeInterval, with the part below one
    // second.
    package var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
