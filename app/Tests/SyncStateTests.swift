import Foundation

@main
struct SyncStateTests {
    @MainActor
    static func main() throws {
        let suite = "freereps-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let category = CategorySyncState(
            id: "test", displayName: "Test", systemImage: "heart", status: .idle,
            recordCount: 0, lastSyncDate: nil, currentProgress: 0, totalEstimated: 1
        )
        let state = SyncState(defaults: defaults)
        state.categories = [category]
        state.updateCategory("test", status: .failed("Network request failed [NSURLErrorDomain:-1009]"),
                             recordCount: 12, lastSyncDate: Date(timeIntervalSince1970: 100))
        state.backfillCursors["test"] = Date(timeIntervalSince1970: 90)
        state.persist()
        let restored = SyncState(defaults: defaults)
        restored.categories = [category]
        restored.restore()
        precondition(restored.categories[0].status == state.categories[0].status)
        precondition(restored.categories[0].recordCount == 12)
        precondition(restored.backfillCursors == state.backfillCursors)

        // Existing installations have no failureMessage field.
        let legacy = Data("{\"id\":\"test\",\"recordCount\":3,\"completed\":true}".utf8)
        let decoded = try JSONDecoder().decode(PersistedCategory.self, from: legacy)
        precondition(decoded.failureMessage == nil && decoded.completed)

        state.updateCategory("test", status: .completed)
        state.persist()
        let succeeded = SyncState(defaults: defaults)
        succeeded.categories = [category]
        succeeded.restore()
        precondition(succeeded.categories[0].status == .completed)
        defaults.set("keep-server-config", forKey: "freerepsConfig_v1")
        state.categories[0].latestHealthKitDate = Date()
        state.overallProgress = 1
        state.resetAllLocalState()
        precondition(state.overallProgress == 0 && state.backfillCursors.isEmpty)
        precondition(state.categories[0].latestHealthKitDate == nil)
        precondition(state.categories[0].recordCount == 0 && state.categories[0].lastSyncDate == nil)
        precondition(defaults.string(forKey: "freerepsConfig_v1") == "keep-server-config")
        restored.restore()
        precondition(restored.categories[0].recordCount == 0 && restored.backfillCursors.isEmpty)
        print("Sync state tests passed: failure persistence, progress, legacy decoding, recovery")
    }
}
