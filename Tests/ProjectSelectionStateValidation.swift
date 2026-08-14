import Foundation

@main
struct ProjectSelectionStateValidation {
    static func main() {
        verifyInitialSuggestion()
        verifyNoProjectSurvivesNavigationReturn()
        verifyAnotherProjectSurvivesNavigationReturn()
        verifyNoProjectsAvailable()
        verifyExplicitNoProjectBeforeInitialization()
        print("ProjectSelectionState validation passed")
    }

    private static func verifyInitialSuggestion() {
        var state = ProjectSelectionState()
        state.initializeIfNeeded(projectPaths: ["/projects/Alpha", "/projects/Beta"])
        precondition(state.selectedPath == "/projects/Alpha")
    }

    private static func verifyNoProjectSurvivesNavigationReturn() {
        var state = ProjectSelectionState()
        state.initializeIfNeeded(projectPaths: ["/projects/Alpha", "/projects/Beta"])
        state.select("")
        state.initializeIfNeeded(projectPaths: ["/projects/Alpha", "/projects/Beta"])
        precondition(state.selectedPath.isEmpty)
    }

    private static func verifyAnotherProjectSurvivesNavigationReturn() {
        var state = ProjectSelectionState()
        state.initializeIfNeeded(projectPaths: ["/projects/Alpha", "/projects/Beta"])
        state.select("/projects/Beta")
        state.initializeIfNeeded(projectPaths: ["/projects/Alpha", "/projects/Beta"])
        precondition(state.selectedPath == "/projects/Beta")
    }

    private static func verifyNoProjectsAvailable() {
        var state = ProjectSelectionState()
        state.initializeIfNeeded(projectPaths: [])
        precondition(state.selectedPath.isEmpty)
    }

    private static func verifyExplicitNoProjectBeforeInitialization() {
        var state = ProjectSelectionState()
        state.select("")
        state.initializeIfNeeded(projectPaths: ["/projects/Alpha"])
        precondition(state.selectedPath.isEmpty)
    }
}
