import Foundation
import NexusCore
import NexusIPC

// What nexus dumps --follow knows: its place and the cursor of the store. The first loaded list
// gives the cursor. Each read of newDumps moves it. So the follower needs nothing for each request.
struct DumpFollower {
    let place: DumpPlace?
    private(set) var cursor: DumpCursor?

    init(place: DumpPlace?) {
        self.place = place
    }

    // A list of another epoch starts the follow again with the newest requests. An example is a
    // start of nexusd without its file.
    func startsAgain(at listCursor: DumpCursor) -> Bool {
        cursor?.epoch != listCursor.epoch
    }

    mutating func begin(at listCursor: DumpCursor) {
        cursor = listCursor
    }

    // Only a changed header of the place can bring new dumps. The end of a request changes its
    // header too. The read then gives no dump.
    func reads(after change: DumpChange) -> Bool {
        cursor != nil && change.changed.contains { place.includes($0.place) }
    }

    mutating func move(to batch: DumpBatch) {
        cursor = batch.cursor
    }
}
