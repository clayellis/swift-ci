import SwiftCICore

public struct TestXcodeProject: Action {
    public let name = "Test Xcode Project"

    var xcodeProject: String?
    var scheme: String?
    var destination: XcodeBuild.Destination?
    var withoutBuilding: Bool
    let xcbeautify: Bool

    public init(
        xcodeProject: String? = nil,
        scheme: String? = nil,
        destination: XcodeBuild.Destination? = nil,
        withoutBuilding: Bool = false,
        xcbeautify: Bool = false
    ) {
        self.xcodeProject = xcodeProject
        self.scheme = scheme
        self.destination = destination
        self.withoutBuilding = withoutBuilding
        self.xcbeautify = xcbeautify
    }

    public func run() async throws -> String {
        var test = ShellCommand("xcodebuild \(withoutBuilding ? "test-without-building" : "test")")
        test.append("-project", ifLet: xcodeProject)
        test.append("-scheme", ifLet: scheme)
        test.append("-destination", ifLet: destination?.value)

        if xcbeautify {
            return try await xcbeautify(test)
        } else {
            return try context.shell(test)
        }
    }
}

public extension Action {
    @discardableResult
    func testXcodeProject(
        _ xcodeProject: String? = nil,
        scheme: String? = nil,
        destination: XcodeBuild.Destination? = nil,
        withoutBuilding: Bool = false,
        xcbeautify: Bool = false
    ) async throws -> String {
        try await action(TestXcodeProject(
            xcodeProject: xcodeProject,
            scheme: scheme,
            destination: destination,
            withoutBuilding: withoutBuilding,
            xcbeautify: xcbeautify
        ))
    }
}
