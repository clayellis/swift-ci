import Foundation

public struct UploadToAppStoreConnect: Step {
    /// Path to .ipa file.
    let ipa: String

    /// The xcode project the .ipa file was exported from.
    var xcodeProject: String?

    /// The package type,
    var type: PackageType

    /// Required with --notarize-app and --notarization-history when a user account is associated with multiple providers and using username/password authentication.
    /// You can use the --list-providers command to retrieve the providers associated with your accounts. You may instead use --asc-provider or --asc-public-id.
    var ascPublicID: String?

    /// The Apple ID of the app to be uploaded.
    var appAppleID: String?

    /// The CFBundleVersion of the app to be uploaded.
    var bundleVersion: String?

    /// The CFBundleShortVersionString of the app to be uploaded.
    var bundleShortVersion: String?

    /// The CFBundleIdentifier of the app to be uploaded.
    var bundleID: String?

    /// The type of authentication to use.
    let appStoreConnectKey: AppStoreConnect.Key

    public struct Output {
        public let buildNumber: String
    }

    public enum PackageType: Argument {
        case macOS
        case iOS
        case tvOS

        public var argument: String {
            switch self {
            case .macOS: return "macos"
            case .iOS: return "ios"
            case .tvOS: return "appletvos"
            }
        }
    }

    public init(
        ipa: String,
        xcodeProject: String? = nil,
        type: PackageType = .iOS,
        ascPublicID: String? = nil,
        appAppleID: String? = nil,
        bundleVersion: String? = nil,
        bundleShortVersion: String? = nil,
        bundleID: String? = nil,
        appStoreConnectKey: AppStoreConnect.Key
    ) {
        self.ipa = ipa
        self.xcodeProject = xcodeProject
        self.type = type
        self.ascPublicID = ascPublicID
        self.appAppleID = appAppleID
        self.bundleVersion = bundleVersion
        self.bundleShortVersion = bundleShortVersion
        self.bundleID = bundleID
        self.appStoreConnectKey = appStoreConnectKey
    }

    private func newALToolCommand() -> Command {
        let keysDirectory = appStoreConnectKey.path.removingLastPathComponent
        return Command("env", "API_PRIVATE_KEYS_DIR=\(keysDirectory)", "xcrun", "altool", "--apiKey", appStoreConnectKey.id, "--apiIssuer", appStoreConnectKey.issuerID)
    }

    private func upload(ipa: String, type: PackageType, appAppleID: String, bundleVersion: String, bundleShortVersion: String, bundleID: String) async throws {
        var uploadPackage = newALToolCommand()
        uploadPackage.add(
            "--upload-package", ipa,
            "--type", type,
            "--apple-id", appAppleID,
            "--bundle-version", bundleVersion,
            "--bundle-short-version-string", bundleShortVersion,
            "--bundle-id", bundleID
        )

        logger.info("""
            Uploading \(ipa.lastPathComponent ?? ipa) to App Store Connect:
             - App ID: \(appAppleID)
             - Bundle ID: \(bundleID)
             - Version: \(bundleShortVersion)
             - Build: \(bundleVersion)
            """
        )

        try context.shell(uploadPackage)
    }

    public func run() async throws -> Output {

        // TODO: Allow for the build version to be specified by an environment variable. (This could be useful on a system like Bitrise that has its own build numbers.)
        // Then a build number could be specified from the outside. It would always win out over what's detected internally.

        guard ipa.hasSuffix(".ipa") else {
            throw StepError("Expected ipa to be the path to an .ipa, but got \(ipa) instead.")
        }

        var appAppleID = self.appAppleID
        var bundleVersion = self.bundleVersion
        var bundleShortVersion = self.bundleShortVersion
        var bundleID = self.bundleID

        versions: if bundleShortVersion == nil || bundleVersion == nil {
            guard let project = xcodeProject ?? context.xcodeProject else {
                logger.debug("Couldn't detect bundle short version or bundle version because xcode project wasn't specified explicitly or contextually.")
                break versions
            }

            guard let buildSettings = try? getBuildSettings(fromXcodeProject: project) else {
                logger.debug("Couldn't detect bundle short version or bundle version because couldn't get build settings from Xcode project.")
                break versions
            }

            if bundleShortVersion == nil {
                if let projectBundleShortVersion = buildSettings.version {
                    bundleShortVersion = projectBundleShortVersion
                    logger.debug("Detected bundle short version from xcode project")
                } else {
                    logger.debug("Couldn't detect bundle short version from Xcode project build settings.")
                }
            }

            if bundleVersion == nil {
                if let projectBundleVersion = buildSettings.build {
                    bundleVersion = projectBundleVersion
                    logger.debug("Detected bundle version from xcode project")
                } else {
                    logger.debug("Couldn't detect bundle version from Xcode project build settings.")
                }
            }

            if bundleID == nil {
                if let projectBundleID = buildSettings.bundleIdentifier {
                    bundleID = projectBundleID
                    logger.debug("Detected bundle id from xcode project")
                } else {
                    logger.debug("Couldn't detect bundle version from Xcode project build settings.")
                }
            }
        }

        guard var bundleVersion else { throw StepError("Missing bundleVersion") }
        guard let bundleShortVersion else { throw StepError("Missing bundleShortVersion") }
        guard let bundleID else { throw StepError("Missing bundleID") }

        let apps = try await context.appStoreConnect.getApps(key: appStoreConnectKey)
        guard let app = apps.first(where: { $0.attributes.bundleId == bundleID }) else {
            throw StepError("No app with bundle id \(bundleID) found on App Store Connect. Either the bundle id isn't correct or the app hasn't been created on App Store Connect yet.")
        }

        if appAppleID == nil {
            appAppleID = app.id
            logger.debug("Detected app Apple ID from App Store Connect.")
        }

        guard let appAppleID else { throw StepError("Missing appAppleID") }

        if let latestBuild = try await context.appStoreConnect.getLatestBuild(appID: appAppleID, key: appStoreConnectKey) {
            if let bundleVersionNumber = Int(bundleVersion), let latestBuildNumber = Int(latestBuild.attributes.version) {
                if bundleVersionNumber <= latestBuildNumber {
                    bundleVersion = String(latestBuildNumber + 1)
                    logger.info("Automatically incremented bundle version from (project version: \(bundleVersionNumber), latest version: \(latestBuildNumber)) to \(bundleVersion)")
                }
            } else {
                logger.debug("Latest build version is not a number, cannot automatically check for build number greater than previous build.")
            }
        } else {
            logger.debug("Couldn't get latest build from App Store Connect. Continuing with given values.")
        }

        try await upload(
            ipa: ipa,
            type: type,
            appAppleID: appAppleID,
            bundleVersion: bundleVersion,
            bundleShortVersion: bundleShortVersion,
            bundleID: bundleID
        )

        return Output(buildNumber: bundleVersion)
    }
}
