import Arguments
import Foundation
import Logging

// TODO: Should a workflow have an Outcome (success, failure, etc.) kind of like how a step has an output?
// TODO: Would it be possible to make swift-ci run as a subcommand of swift?
//  - So instead of: swift run name-of-executable
//  - It would be: swift ci

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

enum CurrentWorkflowKey: ContextKey {
    static let defaultValue: (any Workflow)? = nil
}

public extension ContextValues {
    internal(set) var currentWorkflow: (any Workflow)? {
        get { self[CurrentWorkflowKey.self] }
        set { self[CurrentWorkflowKey.self] = newValue }
    }
}

struct WorkflowStack {
    private var steps = [any Step]()

    mutating func push(_ step: any Step) {
        steps.append(step)
    }

    mutating func pop() -> (any Step)? {
        guard !steps.isEmpty else {
            return nil
        }

        return steps.removeLast()
    }
}

extension WorkflowStack: ContextKey {
    static let defaultValue = WorkflowStack()
}

private extension ContextValues {
    var stack: WorkflowStack {
        get { self[WorkflowStack.self] }
        set { self[WorkflowStack.self] = newValue }
    }
}

public extension Workflow {
    static var context: ContextValues { .shared }
    var context: ContextValues { .shared }

    func workflow<W: Workflow>(_ workflow: W) async throws {
        // Parents are restored to their current directory after a child workflow runs
        let currentDirectory = context.fileManager.currentDirectoryPath
        defer {
            do {
                try context.fileManager.changeCurrentDirectory(currentDirectory)
            } catch {
                logger.error("Failed to restore current directory to \(currentDirectory) after running workflow \(W.name).")
            }
        }

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
        context.stack.push(step)
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
        context.currentWorkflow = workflow
        defer { context.currentWorkflow = nil }

        do {
            try setUpWorkspace()
            try await workflow.run()
            await cleanUp(error: nil)
            exit(0)
        } catch {
            await cleanUp(error: error)

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

    private static func cleanUp(error: Error?) async {
        while let step = context.stack.pop() {
            logger.info("Cleaning up after step: \(step.name)")
            do {
                try await step.cleanUp(error: error)
            } catch {
                logger.error("Failed to clean up after \(step.name): \(error)")
            }
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
