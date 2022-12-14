import Foundation
import SwiftCICore

// Reference: https://github.com/stefanzweifel/git-auto-commit-action/blob/master/entrypoint.sh

public struct GitCommit: Action {
    public let name = "Git Commit"

    let flags: [String]
    let message: String
    var author: String?
    var userName: String?
    var userEmail: String?
    let pushChanges: Bool

    public init(flags: [String], message: String, author: String? = nil, userName: String? = nil, userEmail: String? = nil, pushChanges: Bool = true) {
        self.message = message
        self.flags = flags.filter { $0 != "m" }
        self.author = author
        self.userName = userName
        self.userEmail = userEmail
        self.pushChanges = pushChanges
    }

    public struct Output {
        public var commitSHA: String?

        public var hadChanges: Bool {
            commitSHA != nil
        }
    }

    public func run() async throws -> Output {
        guard try !context.shell("git status -s").isEmpty else {
            return Output(commitSHA: nil)
        }

        // FIXME: Get the headRef in a platform-agnostic way
        let branch = try context.environment.github.$headRef.require()
        try context.shell("git fetch --depth=1")
        // TODO: If the branch already exists, just check it out, don't create it (-B)
        try context.shell("git checkout \(branch)")

        let actor = try context.environment.github.$actor.require()
        let userName = userName ?? "github-actions[bot]"
        // This is the default value is the email address of the GitHub actions bot.
        // Reference: https://github.com/orgs/community/discussions/26560#discussioncomment-3252339
        let userEmail = userEmail ?? "41898282+github-actions[bot]@users.noreply.github.com"
        let author = author ?? "\(actor) <\(actor)@users.noreply.github.com>"

        var commit = ShellCommand("""
            git \
            -c user.name=\(userName) \
            -c user.email=\(userEmail) \
            commit \
            -m \(message, escapingWith: .doubleQuotes) \
            --author=\(author)
            """
        )

        if !flags.isEmpty {
            commit.append("-\(flags.joined())")
        }

        // FIXME: Make platform-agnostic
        commit.append("--dry-run", if: !context.environment.github.isCI)

        try context.shell(commit)

        let sha = try context.shell("git rev-parse HEAD")

        if pushChanges {
            var push = ShellCommand("git push --set-upstream origin HEAD:\(branch) --atomic")
            push.append("--dry-run", if: !context.environment.github.isCI)
            try context.shell(push)
        }

        return Output(commitSHA: sha)
    }
}

extension GitCommit {
    struct File {
        let path: String
        let status: Set<FileStatus>

        init(path: String, status: Set<FileStatus>) {
            self.path = path
            self.status = status
        }

        init?(line: String) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let delimeter = line.firstIndex(of: " ") else {
                return nil
            }

            let prefix = line[..<delimeter]
            var _status = Set<FileStatus>()
            for status in FileStatus.allCases {
                if prefix.contains(status.prefix) {
                    _status.insert(status)
                }
            }

            guard !_status.isEmpty else {
                return nil
            }
            self.status = _status
            let path = line[delimeter...].trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\"")))
            self.path = path
        }
    }

    enum FileStatus: CaseIterable {
        case added
        case deleted
        case modified
        case untracked

        var prefix: String {
            switch self {
            case .added: return "A"
            case .modified: return "M"
            case .deleted: return "D"
            case .untracked: return "??"
            }
        }
    }
}

public extension Action {
    @discardableResult
    func commit(flags: [String] = [], message: String) async throws -> GitCommit.Output {
        try await action(GitCommit(flags: flags, message: message))
    }

    @discardableResult
    func commitTrackedChanges(message: String, flags: [String] = []) async throws -> GitCommit.Output {
        try await action(GitCommit(flags: ["a"] + flags, message: message))
    }

    @discardableResult
    func commitAllChanges(message: String, flags: [String] = []) async throws -> GitCommit.Output {
        try context.shell("git add -A")
        return try await commit(flags: flags, message: message)
    }

    @discardableResult
    func commit(files: String..., message: String, flags: [String] = []) async throws -> GitCommit.Output {
        for file in files {
            try context.shell("git add \(file)")
        }

        return try await commit(flags: flags, message: message)
    }

    @discardableResult
    func commit(message: String, flags: [String] = [], filesMatching predicate: @escaping (String) -> Bool) async throws -> GitCommit.Output {
        try await context.withLogGroup(named: "Step: Commit Files Matching Predicate") {
            context.logger.info("Committing files matching predicate.")

            let status = try context.shell("git status --short")
            let files = status
                .components(separatedBy: "\n")
                .compactMap(GitCommit.File.init(line:))

            let filesToCommit = files.filter { predicate($0.path) }

            context.logger.debug("Files with changes:\n\(files)")
            context.logger.debug("Files to commit:\n\(filesToCommit)")

            guard !filesToCommit.isEmpty else {
                context.logger.info("No files to commit.")
                return .init(commitSHA: nil)
            }

            for file in filesToCommit {
                if file.status.contains(.deleted) {
                    try context.shell("git rm --cached \(file.path)")
                } else {
                    try context.shell("git add \(file.path)")
                }
            }

            return try await commit(flags: flags, message: message)
        }
    }

    @discardableResult
    func commitLocalizedFiles(message: String) async throws -> GitCommit.Output {
        try await commit(message: message, filesMatching: { file in
            [".strings", ".xliff", ".xcloc", ".lproj"].contains { file.hasSuffix($0) }
        })
    }
}
