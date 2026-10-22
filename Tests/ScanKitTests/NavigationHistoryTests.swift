import Testing
@testable import ScanKit

struct NavigationHistoryTests {
    @Test func goesBackAndForwardThroughVisitedPlaces() {
        var history = NavigationHistory<String>()
        history.visit(from: "a")   // a → b
        history.visit(from: "b")   // b → c

        #expect(history.goBack(from: "c") == "b")
        #expect(history.goBack(from: "b") == "a")
        #expect(history.goBack(from: "a") == nil)
        #expect(history.goForward(from: "a") == "b")
        #expect(history.goForward(from: "b") == "c")
        #expect(history.goForward(from: "c") == nil)
    }

    @Test func visitingSomewhereNewDropsTheForwardPlaces() {
        var history = NavigationHistory<String>()
        history.visit(from: "a")   // a → b
        #expect(history.goBack(from: "b") == "a")
        #expect(history.canGoForward)

        history.visit(from: "a")   // a → x
        #expect(!history.canGoForward)
        #expect(history.goBack(from: "x") == "a")
    }

    @Test func removingPlacesSkipsThemAndTheirDuplicates() {
        var history = NavigationHistory<String>()
        history.visit(from: "a")   // a → gone
        history.visit(from: "gone")   // gone → a
        history.visit(from: "a")   // a → b

        history.removeAll { $0 == "gone" }

        // "a, a" collapsed into one, so Back goes straight to "a".
        #expect(history.goBack(from: "b") == "a")
        #expect(history.goBack(from: "a") == nil)
    }

    @Test func neverGoesBackToWhereItAlreadyIs() {
        var history = NavigationHistory<String>()
        history.visit(from: "a")   // a → b
        history.visit(from: "b")   // b → a, after "b" was trashed and the view moved up
        history.removeAll { $0 == "b" }

        #expect(history.goBack(from: "a") == nil)
        #expect(!history.canGoBack(from: "a"))
    }
}
