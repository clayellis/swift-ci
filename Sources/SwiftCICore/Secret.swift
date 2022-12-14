import Foundation

public protocol Secret {
    func get() async throws -> Data
}

public struct EnvironmentSecret: Secret {
    public let key: String
    public var processValue: (inout Data) async throws -> Void

    public static func value(_ key: String) -> EnvironmentSecret {
        self.init(key: key, processValue: { _ in })
    }

    public static func base64EncodedValue(_ key: String) -> EnvironmentSecret {
        self.init(key: key, processValue: {
            guard let data = Data(base64Encoded: $0, options: .ignoreUnknownCharacters) else {
                throw ActionError("Failed to base64-decode secret")
            }

            $0 = data
        })
    }

    public init(key: String, processValue: @escaping (inout Data) async throws -> Void) {
        self.key = key
        self.processValue = processValue
    }

    public struct MissingEnvironmentSecretError: Error {
        public let key: String
    }

    public func get() async throws -> Data {
        guard let value = ProcessInfo.processInfo.environment[key] else {
            throw MissingEnvironmentSecretError(key: key)
        }

        var data = value.data
        try await processValue(&data)
        return data
    }
}

public extension Secret where Self == EnvironmentSecret {
    static func environmentValue(_ key: String) -> EnvironmentSecret {
        .value(key)
    }

    static func base64EncodedEnvironmentValue(_ key: String) -> EnvironmentSecret {
        .base64EncodedValue(key)
    }
}
