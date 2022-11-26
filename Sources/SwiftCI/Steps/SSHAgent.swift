import Crypto
import Foundation

// Reference: https://github.com/webfactory/ssh-agent/blob/209e2d72ff4a448964d26610aceaaf1b3f8764c6/index.js

public struct SSHAgent: Step {
    var sshPrivateKeys: [Secret]
    var sshAuthSocket: String?
    var shouldLogPublicKey: Bool = true

    @StepState var createdFiles = [String]()
    @StepState var previousSSHConfig: String?
    @StepState var previousGitConfig: (path: URL, contents: Data)?

    var ssh: String {
        context.fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ssh").path
    }

    var knownHosts: String {
        ssh/"known_hosts"
    }

    var sshConfig: String {
        ssh/"config"
    }

    public init(sshPrivateKeys: [Secret], sshAuthSocket: String? = nil, shouldLogPublicKey: Bool = true) {
        self.sshPrivateKeys = sshPrivateKeys
        self.sshAuthSocket = sshAuthSocket
        self.shouldLogPublicKey = shouldLogPublicKey
    }

    public func run() async throws {
        logger.info("adding GitHub.com keys to \(ssh)/known_hosts")

        try context.fileManager.createDirectory(atPath: ssh, withIntermediateDirectories: true)

        try await updateFile(knownHosts) { $0 += """
            github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
            github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
            github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==

            """
        }

        logger.info("Starting ssh-agent")

        // TODO: Do we need to start the ssh-agent in the background first before adding values?
        var sshAgent = Command("ssh-agent")
        sshAgent.add("-a", ifLet: sshAuthSocket)
        let sshAgentOutput = try context.shell(sshAgent)

        for line in sshAgentOutput.components(separatedBy: "\n") {
            let key: String
            let value: String
//            if #available(macOS 13.0, *) {
//                guard let match = line.wholeMatch(of: #/^(SSH_AUTH_SOCK|SSH_AGENT_PID)=(.*); export \1/#) else {
//                    continue
//                }
//
//                key = String(match.output.1)
//                value = String(match.output.2)
//            } else {
                guard
                    let equals = line.firstIndex(of: "="),
                    let semicolon = line.firstIndex(of: ";"),
                    line.contains("; export ")
                else {
                    continue
                }

                key = String(line[line.startIndex..<equals])
                value = String(line[line.index(after: equals)..<semicolon])

                guard key == "SSH_AUTH_SOCK" || key == "SSH_AGENT_PID" else {
                    continue
                }
//            }

            setenv(key, value)
            logger.info("\(key)=\(value)")
        }

        logger.info("Adding private key(s) to agent")

        for sshPrivateKey in sshPrivateKeys {
            let key: String = try loadSecret(sshPrivateKey)
            try context.shell("ssh-add", key)
        }

        let keys = try context.shell("ssh-add", "-l", quiet: true)
        logger.info("Key(s) added:\n\(keys)")

        logger.info("Configuring deployment key(s)")

        guard var sshConfigContents = context.fileManager.contents(atPath: sshConfig).map({ String(decoding: $0, as: UTF8.self) }) else {
            throw StepError("Failed to get contents of \(sshConfig)")
        }

        previousSSHConfig = sshConfigContents


        guard let globalGitConfig = try context.shell("git", "config", "--global", "--list", "--show-origin")
            .components(separatedBy: "\n")
            .first
            .flatMap(URL.init(string:))
        else {
            throw StepError("Failed to locate global git config file")
        }

        guard let globalGitConfigContents = context.fileManager.contents(atPath: globalGitConfig.path) else {
            throw StepError("Failed to get global git config file contents")
        }

        previousGitConfig = (path: globalGitConfig, contents: globalGitConfigContents)

        let publicKeys = try context.shell("ssh-add", "-L", quiet: true).components(separatedBy: "\n")
        for publicKey in publicKeys {
            var ownerAndRepo: String?
            if #available(macOS 13.0, *) {
                let match = publicKey.lowercased().firstMatch(of: #/\bgithub\.com[:/]([_.a-z0-9-]+\/[_.a-z0-9-]+)/#)
                ownerAndRepo = match.map { String($0.output.1) }
            } else {
                if let githubSlash = publicKey.lowercased().range(of: "github.com/"),
                   publicKey.rangeOfCharacter(from: CharacterSet(charactersIn: "/"), range: githubSlash.upperBound..<publicKey.endIndex) != nil {
                    ownerAndRepo = String(publicKey[publicKey.index(after: githubSlash.upperBound)...])
                }
            }

            guard var ownerAndRepo else {
                if shouldLogPublicKey {
                    logger.info("Comment for (public) key \(publicKey) does not match GitHub URL pattern. Not treating it as a GitHub deploy key.")
                }
                continue
            }

            ownerAndRepo = ownerAndRepo.replacingOccurrences(of: ".git", with: "")

            let sha256 = CryptoKit.SHA256.hash(data: Data(publicKey.utf8))
            let keyFilePath = ssh/"key-\(sha256.description)"
            let keyFileContents = Data((sha256.description + "\n").utf8)

            guard context.fileManager.createFile(atPath: keyFilePath, contents: keyFileContents, attributes: [.posixPermissions: 600]) else {
                throw StepError("Failed to create ssh key file \(keyFilePath)")
            }

            createdFiles?.append(keyFilePath)

            try context.shell("git", "config", "--global", "--replace-all", "url.\"git@key-\(sha256.description).github.com:\(ownerAndRepo)\".insteadOf", "https://github.com/\(ownerAndRepo)")
            try context.shell("git", "config", "--global", "--add", "url.\"git@key-\(sha256.description).github.com:\(ownerAndRepo)\".insteadOf", "git@github.com:\(ownerAndRepo)")
            try context.shell("git", "config", "--global", "--add", "url.\"git@key-\(sha256.description).github.com:\(ownerAndRepo)\".insteadOf", "ssh://github.com/\(ownerAndRepo)")

            sshConfigContents += """

                Host key-\(sha256.description).github.com
                    HostName github.com
                    IdentityFile \(keyFilePath)
                    IdentitiesOnly yes

                """

            guard context.fileManager.createFile(atPath: sshConfig, contents: Data(sshConfigContents.utf8)) else {
                throw StepError("Failed to update \(sshConfig)")
            }

            logger.info("Added deploy-key mapping: Use identity \(keyFilePath) for GitHub repository \(ownerAndRepo)")
        }
    }

    public func cleanUp(error: Error?) async throws {
        if let previousGitConfig {
            context.fileManager.createFile(atPath: previousGitConfig.path.path, contents: previousGitConfig.contents)
        }

        if let previousSSHConfig {
            context.fileManager.createFile(atPath: sshConfig, contents: Data(previousSSHConfig.utf8))
        }

        if let createdFiles {
            for file in createdFiles {
                try context.fileManager.removeItem(atPath: file)
            }
        }

        try context.shell("ssh-agent", "-k")
    }

    func setenv(_ key: String, _ value: String) {
        _ = withUnsafePointer(to: Array(key.utf8CString)) { keyPointer in
            withUnsafePointer(to: Array(value.utf8CString)) { valuePointer in
                Darwin.setenv(keyPointer, valuePointer, 1)
            }
        }
    }
}

public extension StepRunner {
    func addSSHKeys(_ sshKeys: [Secret]) async throws {
        try await step(SSHAgent(sshPrivateKeys: sshKeys))
    }
}

/*
 const core = require('@actions/core');
 const child_process = require('child_process');
 const fs = require('fs');
 const crypto = require('crypto');
 const { homePath, sshAgentCmd, sshAddCmd, gitCmd } = require('./paths.js');

 try {
     const privateKey = core.getInput('ssh-private-key');
     const logPublicKey = core.getBooleanInput('log-public-key', {default: true});

     if (!privateKey) {
         core.setFailed("The ssh-private-key argument is empty. Maybe the secret has not been configured, or you are using a wrong secret name in your workflow file.");

         return;
     }

     const homeSsh = homePath + '/.ssh';

     console.log(`Adding GitHub.com keys to ${homeSsh}/known_hosts`);

     fs.mkdirSync(homeSsh, { recursive: true });
     fs.appendFileSync(`${homeSsh}/known_hosts`, '\ngithub.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=\n');
     fs.appendFileSync(`${homeSsh}/known_hosts`, '\ngithub.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n');
     fs.appendFileSync(`${homeSsh}/known_hosts`, '\ngithub.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==\n');

     console.log("Starting ssh-agent");

     const authSock = core.getInput('ssh-auth-sock');
     const sshAgentArgs = (authSock && authSock.length > 0) ? ['-a', authSock] : [];

     // Extract auth socket path and agent pid and set them as job variables
     child_process.execFileSync(sshAgentCmd, sshAgentArgs).toString().split("\n").forEach(function(line) {
         const matches = /^(SSH_AUTH_SOCK|SSH_AGENT_PID)=(.*); export \1/.exec(line);

         if (matches && matches.length > 0) {
             // This will also set process.env accordingly, so changes take effect for this script
             core.exportVariable(matches[1], matches[2])
             console.log(`${matches[1]}=${matches[2]}`);
         }
     });

     console.log("Adding private key(s) to agent");

     privateKey.split(/(?=-----BEGIN)/).forEach(function(key) {
         child_process.execFileSync(sshAddCmd, ['-'], { input: key.trim() + "\n" });
     });

     console.log("Key(s) added:");

     child_process.execFileSync(sshAddCmd, ['-l'], { stdio: 'inherit' });

     console.log('Configuring deployment key(s)');

     child_process.execFileSync(sshAddCmd, ['-L']).toString().trim().split(/\r?\n/).forEach(function(key) {
         const parts = key.match(/\bgithub\.com[:/]([_.a-z0-9-]+\/[_.a-z0-9-]+)/i);

         if (!parts) {
             if (logPublicKey) {
               console.log(`Comment for (public) key '${key}' does not match GitHub URL pattern. Not treating it as a GitHub deploy key.`);
             }
             return;
         }

         const sha256 = crypto.createHash('sha256').update(key).digest('hex');
         const ownerAndRepo = parts[1].replace(/\.git$/, '');

         fs.writeFileSync(`${homeSsh}/key-${sha256}`, key + "\n", { mode: '600' });

         child_process.execSync(`${gitCmd} config --global --replace-all url."git@key-${sha256}.github.com:${ownerAndRepo}".insteadOf "https://github.com/${ownerAndRepo}"`);
         child_process.execSync(`${gitCmd} config --global --add url."git@key-${sha256}.github.com:${ownerAndRepo}".insteadOf "git@github.com:${ownerAndRepo}"`);
         child_process.execSync(`${gitCmd} config --global --add url."git@key-${sha256}.github.com:${ownerAndRepo}".insteadOf "ssh://git@github.com/${ownerAndRepo}"`);

         const sshConfig = `\nHost key-${sha256}.github.com\n`
                               + `    HostName github.com\n`
                               + `    IdentityFile ${homeSsh}/key-${sha256}\n`
                               + `    IdentitiesOnly yes\n`;

         fs.appendFileSync(`${homeSsh}/config`, sshConfig);

         console.log(`Added deploy-key mapping: Use identity '${homeSsh}/key-${sha256}' for GitHub repository ${ownerAndRepo}`);
     });

 } catch (error) {

     if (error.code == 'ENOENT') {
         console.log(`The '${error.path}' executable could not be found. Please make sure it is on your PATH and/or the necessary packages are installed.`);
         console.log(`PATH is set to: ${process.env.PATH}`);
     }

     core.setFailed(error.message);
 }
 */
