import Foundation

@main
struct HealthSyncSelectionTests {
    @MainActor static func main() {
        let suite = "HealthSyncSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("preserved-progress", forKey: "syncState")
        let selection = HealthSyncSelection(defaults: defaults)
        precondition(selection.isEnabled && selection.includes("cat_workouts"))
        selection.setCategory("cat_workouts", enabled: false)
        precondition(!selection.includes("cat_workouts") && selection.includes("cat_category"))
        let revision = selection.revision
        selection.setCategory("cat_workouts", enabled: false)
        precondition(selection.revision == revision)
        selection.setEnabled(false)
        selection.setEnabled(true)
        do {
            try selection.checkRevision(revision)
            fatalError("An old sync must not resume after off/on")
        } catch is CancellationError {} catch { fatalError("Unexpected error: \(error)") }
        do { try selection.checkRevision(selection.revision) } catch { fatalError("Current enabled revision should pass") }
        precondition(!selection.includes("cat_workouts"))
        precondition(selection.revision == revision + 2)
        let restored = HealthSyncSelection(defaults: defaults)
        precondition(restored.isEnabled && !restored.includes("cat_workouts"))
        restored.setCategory("cat_workouts", enabled: true)
        precondition(HealthSyncSelection(defaults: defaults).includes("cat_workouts"))
        restored.setEnabled(false)
        do {
            try restored.checkRevision(restored.revision)
            fatalError("Disabled sync must be blocked")
        } catch is CancellationError {} catch { fatalError("Unexpected error: \(error)") }
        precondition(!HealthSyncSelection(defaults: defaults).isEnabled)
        precondition(defaults.string(forKey: "syncState") == "preserved-progress")
        print("Health selection tests passed: migration, category isolation, pause/resume, persistence, revision, progress preservation")
    }
}
