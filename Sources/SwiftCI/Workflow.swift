import Arguments
import Foundation
import Logging

// TODO: Would it be possible to make swift-ci run as a subcommand of swift?
//  - So instead of: swift run name-of-executable
//  - It would be: swift ci

// TODO: Should a workflow have an Outcome (success, failure, etc.) kind of like how a step has an output?

public protocol Workflow {
    static var name: String { get }
    static var logLevel: Logger.Level { get }
    init()
    func run() async throws
}

public extension Workflow {
    static var name: String {
        "\(self)"
    }

    static var logLevel: Logger.Level {
        .info
    }
}

public extension Workflow {
    static var context: ContextValues { .shared }
    var context: ContextValues { .shared }

    func workflow<W: Workflow>(_ workflow: W) async throws {
        // Parents are restored to their current directory after a child workflow runs
        let currentDirectory = context.fileManager.currentDirectoryPath
        defer { try? context.fileManager.changeCurrentDirectory(currentDirectory) }

        // TODO: Configurable logging format?
        // Should the child workflow inherit the logging level of the parent?
        logger.info("Workflow: \(W.name)")
        try await workflow.run()
    }

    func workflow(_ workflow: () -> some Workflow) async throws {
        try await self.workflow(workflow())
    }

    @discardableResult
    func step<S: Step>(name: String? = nil, _ step: S) async throws -> S.Output {
        context.currentStep = step
        defer { context.currentStep = nil }
        // TODO: Configurable format?
        logger.info("Step: \(name ?? step.name)")
        return try await step.run()
    }

    @discardableResult
    func step<S: Step>(name: String? = nil, _ step: () -> S) async throws -> S.Output {
        try await self.step(name: name, step())
    }
}

public extension Workflow {
    static func main() async {
        context.logger.logLevel = Self.logLevel
        logger.info("Starting Workflow: \(Self.name)")

        let workflow = self.init()

        do {
            try setUpWorkspace()
            try await workflow.run()
            exit(0)
        } catch {

            // TODO: We could call a method on workflow to clean up after the error (send messages, notifications, etc.)
            // workflow.tearDown(after: error)

            let errorLocalizedDescription = error.localizedDescription
            let interpolatedError = "\(error)"
            var errorMessage = "Exiting on error:\n"
            if errorLocalizedDescription != interpolatedError {
                errorMessage += """
                \(errorLocalizedDescription)
                \(interpolatedError)
                """
            } else {
                errorMessage += errorLocalizedDescription
            }

            logger.error("\(errorMessage)")
            exit(1)
        }
    }

    private static func setUpWorkspace() throws {
        let workspace: String
        if context.environment.github.isCI {
            workspace = try context.environment.github.$workspace.require()
        } else {
            var arguments = Arguments(usage: Usage(
                overview: nil,
                seeAlso: nil,
                commands: [
                    "your-swift-ci-command", .option("workspace", required: true, description: "The root directory of the package.")
                ]
            ))
            workspace = try arguments.consumeOption(named: "--workspace")
        }

        logger.debug("Setting current directory: \(workspace)")
        guard context.fileManager.changeCurrentDirectoryPath(workspace) else {
            throw InternalWorkflowError(message: "Failed to set current directory")
        }
    }
}

struct InternalWorkflowError: LocalizedError {
    let message: String
    private let file: StaticString
    private let line: UInt
    private let function: StaticString

    var errorDescription: String? {
        """
        Internal Workflow Error: \(message)
        (file: \(file), line: \(line), function: \(function))
        """
    }

    init(message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        self.message = message
        self.file = file
        self.line = line
        self.function = function
    }
}
