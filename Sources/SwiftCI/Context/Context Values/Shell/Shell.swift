import ShellOut

public struct Shell {
    @Context(\.fileManager) var fileManager
    @Context(\.logger) var logger

    @discardableResult
    func callAsFunction(_ command: String, _ arguments: [Argument]) throws -> String {
        logger.debug("Shell (at: \(fileManager.currentDirectoryPath)): \(command) \(arguments.map(\.escapedArgument).joined(separator: " "))")
        let output = try shellOut(to: command, arguments: arguments.map(\.escapedArgument), at: fileManager.currentDirectoryPath)
        // TODO: We're just going to print the output for now, but eventually it should be streamed out as it comes in and made available for formatting
        print(output)
        return output
    }

    @discardableResult
    func callAsFunction(_ command: String, _ arguments: Argument...) throws -> String {
        try callAsFunction(command, arguments)
    }
}

extension Shell: ContextKey {
    public static var defaultValue: Shell { Shell() }
}

public extension ContextValues {
    var shell: Shell {
        get { self[Shell.self] }
        set { self[Shell.self] = newValue }
    }
}
