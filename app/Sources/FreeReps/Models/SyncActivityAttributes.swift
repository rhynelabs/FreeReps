import ActivityKit
import Foundation

struct SyncActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String          // e.g. "Activity", "Vitals"
        var operation: String      // current operation text
        var recordsInserted: Int   // rows the server inserted so far in this run (SyncState.newRecordsThisRun)
        var isFullSync: Bool
    }
}
