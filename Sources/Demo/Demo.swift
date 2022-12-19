import Logging
import SwiftCICore

@main
struct Demo: MainAction {
    static let logLevel = Logger.Level.debug

    func run() async throws -> () {
        logger.debug("Hello!")
        logger.info("Wow!")
        try await action(First())
        try await action(Second())

        let name = "Clay Ellis"
        let output = try context.shell("echo \(name)")
        logger.info("Output: \(output)")
    }
}

struct First: Action {
    func run() async throws {

    }
}

struct Second: Action {
    func run() async throws {
        try await action(Nested())
    }
}

struct Nested: Action {
    func run() async throws {
//        throw ActionError("throwing from second")
    }
}
