public protocol Step<Output> {
    associatedtype Output
    var name: String { get }
    func run() async throws -> Output
}

public extension Step {
    static var name: String {
        "\(self)"
    }
}

public extension Step {
    var context: ContextValues { .shared }
}
