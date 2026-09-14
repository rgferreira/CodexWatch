import Foundation

@main
struct ProjectSelectionStateValidation {
    static func main() {
        verifyInitialSuggestion()
        verifyNoProjectSurvivesNavigationReturn()
        verifyAnotherProjectSurvivesNavigationReturn()
        verifyNoProjectsAvailable()
        verifyLateCatalogSelectsFirstProject()
        verifyExplicitNoProjectBeforeInitialization()
        verifyStableProjectIdentityTravelsWithCommand()
        print("ProjectSelectionState validation passed")
    }

    private static func verifyInitialSuggestion() {
        var state = ProjectSelectionState()
        state.initializeIfNeeded(projectIDs: ["alpha", "beta"])
        precondition(state.selectedProjectID == "alpha")
    }

    private static func verifyNoProjectSurvivesNavigationReturn() {
        var state = ProjectSelectionState()
        state.initializeIfNeeded(projectIDs: ["alpha", "beta"])
        state.select("")
        state.initializeIfNeeded(projectIDs: ["alpha", "beta"])
        precondition(state.selectedProjectID.isEmpty)
    }

    private static func verifyAnotherProjectSurvivesNavigationReturn() {
        var state = ProjectSelectionState()
        state.initializeIfNeeded(projectIDs: ["alpha", "beta"])
        state.select("beta")
        state.initializeIfNeeded(projectIDs: ["alpha", "beta"])
        precondition(state.selectedProjectID == "beta")
    }

    private static func verifyNoProjectsAvailable() {
        var state = ProjectSelectionState()
        state.initializeIfNeeded(projectIDs: [])
        precondition(state.selectedProjectID.isEmpty)
    }

    private static func verifyLateCatalogSelectsFirstProject() {
        var state = ProjectSelectionState()
        state.initializeIfNeeded(projectIDs: [])
        state.initializeIfNeeded(projectIDs: ["platform", "music"])
        precondition(state.selectedProjectID == "platform")
    }

    private static func verifyExplicitNoProjectBeforeInitialization() {
        var state = ProjectSelectionState()
        state.select("")
        state.initializeIfNeeded(projectIDs: ["alpha"])
        precondition(state.selectedProjectID.isEmpty)
    }

    private static func verifyStableProjectIdentityTravelsWithCommand() {
        let command = NewTaskCommand(
            prompt: "Create this once",
            projectID: "music",
            projectPath: "/projects/ScoreIR"
        )
        let data = try! CodexWatchWire.encode(command)
        let decoded = try! CodexWatchWire.decode(NewTaskCommand.self, from: data)
        precondition(decoded.projectID == "music")
        precondition(decoded.projectPath == "/projects/ScoreIR")
    }
}
