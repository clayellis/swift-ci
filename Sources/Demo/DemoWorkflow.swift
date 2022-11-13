import SwiftCI

@main
struct Demo: Workflow {
    func run() async throws {
        try await workflow(Build())
        try await workflow(Test())
    }
}

struct Build: Workflow {
    func run() async throws {
        try await step(.swiftBuild)
    }
}

struct Test: Workflow {
    func run() async throws {
        try await step(.swiftTest)
    }
}
