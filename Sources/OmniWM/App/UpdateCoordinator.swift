// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
protocol AppUpdateCoordinating: AnyObject {
    func startAutomaticChecks()
    func checkForUpdatesManually()
}

protocol GitHubReleaseFetching: Sendable {
    func fetchLatestRelease() async throws -> GitHubRelease
}

@MainActor
protocol UpdateWindowControlling: AnyObject {
    var onWindowClosedWithoutAction: (() -> Void)? { get set }
    func show(configuration: UpdatePopupConfiguration)
    func close(markingActionHandled: Bool)
}

struct UpdatePopupConfiguration {
    let releaseTitle: String
    let currentVersion: String
    let latestVersion: String
    let publishedDateText: String?
    let releaseNotes: String
    let openReleasePage: () -> Void
    let copyCommand: () -> Void
    let skipThisVersion: () -> Void
    let notNow: () -> Void
}

struct ReleaseVersion: Comparable, Equatable {
    let components: [Int]
    let normalizedString: String

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withoutPrefix: String
        if let first = trimmed.first, first == "v" || first == "V" {
            withoutPrefix = String(trimmed.dropFirst())
        } else {
            withoutPrefix = trimmed
        }

        guard !withoutPrefix.contains("-"), !withoutPrefix.contains("+") else {
            return nil
        }

        let rawComponents = withoutPrefix.split(separator: ".")
        guard !rawComponents.isEmpty else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(rawComponents.count)

        for component in rawComponents {
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let value = Int(component)
            else {
                return nil
            }
            parsed.append(value)
        }

        while parsed.count > 1, parsed.last == 0 {
            parsed.removeLast()
        }

        components = parsed
        normalizedString = parsed.map(String.init).joined(separator: ".")
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0 ..< count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

struct GitHubRelease: Equatable {
    let tagName: String
    let name: String?
    let body: String
    let releasePageURL: URL
    let publishedAt: Date?

    var version: ReleaseVersion? {
        ReleaseVersion(tagName)
    }

    var releaseTitle: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }
        return tagName
    }
}

struct GitHubReleaseService: GitHubReleaseFetching, Sendable {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/BarutSRB/OmniWM/releases/latest")!

    var session: URLSession = .shared
    var latestReleaseURL: URL = Self.latestReleaseURL
    var userAgent: String = "OmniWM"

    func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCoordinatorError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw UpdateCoordinatorError.badStatus(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(GitHubLatestReleasePayload.self, from: data)
        return GitHubRelease(
            tagName: payload.tagName,
            name: payload.name,
            body: payload.body ?? "",
            releasePageURL: payload.htmlURL,
            publishedAt: payload.publishedAt
        )
    }
}

@MainActor
final class UpdateCoordinator: AppUpdateCoordinating {
    private enum AutomaticCheckSource {
        case automatic
        case manual
    }

    static let homebrewUpdateCommand = "brew upgrade omniwm"
    static let releasesPageURL = URL(string: "https://github.com/BarutSRB/OmniWM/releases")!

    private let settings: SettingsStore
    private let runtimeState: RuntimeStateStore
    private let releaseService: any GitHubReleaseFetching
    private let currentVersionProvider: () -> ReleaseVersion?
    private let currentVersionStringProvider: () -> String
    private let nowProvider: () -> Date
    private let windowController: any UpdateWindowControlling
    private let infoAlertPresenter: (String, String) -> Void
    private let openURL: (URL) -> Void
    private let copyCommandToPasteboard: (String) -> Void

    private var automaticChecksStarted = false
    private var knownAvailableRelease: GitHubRelease?

    init(
        settings: SettingsStore,
        runtimeState: RuntimeStateStore? = nil,
        releaseService: any GitHubReleaseFetching = GitHubReleaseService(
            userAgent: "OmniWM/\(Bundle.main.appVersion ?? "unknown")"
        ),
        currentVersionProvider: @escaping () -> ReleaseVersion? = { Bundle.main.releaseVersion },
        currentVersionStringProvider: @escaping () -> String = { Bundle.main.appVersion ?? "Unknown" },
        nowProvider: @escaping () -> Date = Date.init,
        windowController: any UpdateWindowControlling? = nil,
        infoAlertPresenter: @escaping (String, String) -> Void = { title, message in
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = alert.runModal()
        },
        openURL: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        },
        copyCommandToPasteboard: @escaping (String) -> Void = { command in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
        }
    ) {
        self.settings = settings
        self.runtimeState = runtimeState ?? RuntimeStateStore()
        self.releaseService = releaseService
        self.currentVersionProvider = currentVersionProvider
        self.currentVersionStringProvider = currentVersionStringProvider
        self.nowProvider = nowProvider
        self.windowController = windowController ?? UpdateWindowController.shared
        self.infoAlertPresenter = infoAlertPresenter
        self.openURL = openURL
        self.copyCommandToPasteboard = copyCommandToPasteboard
    }

    func startAutomaticChecks() {
        guard !automaticChecksStarted else { return }
        automaticChecksStarted = true

        Task { @MainActor [weak self] in
            await self?.performCheck(source: .automatic)
        }
    }

    func checkForUpdatesManually() {
        if let knownRelease = currentKnownAvailableRelease() {
            showUpdatePopup(for: knownRelease, source: .manual)
            return
        }

        Task { @MainActor [weak self] in
            await self?.performCheck(source: .manual)
        }
    }

    private func performCheck(source: AutomaticCheckSource) async {
        if source == .automatic {
            guard settings.updateChecksEnabled, shouldPerformAutomaticCheck() else { return }
        }

        guard let currentVersion = currentVersionProvider() else {
            if source == .manual {
                infoAlertPresenter(
                    "Could Not Check for Updates",
                    "OmniWM could not determine its current version."
                )
            }
            return
        }

        let checkStartedAt = nowProvider()
        do {
            let release = try await releaseService.fetchLatestRelease()
            if source == .automatic {
                runtimeState.updaterLastCheckedAt = checkStartedAt
            }
            handleFetchedRelease(release, currentVersion: currentVersion, source: source)
        } catch {
            if source == .automatic {
                runtimeState.updaterLastCheckedAt = checkStartedAt
                return
            }

            infoAlertPresenter(
                "Could Not Check for Updates",
                error.localizedDescription
            )
        }
    }

    private func handleFetchedRelease(
        _ release: GitHubRelease,
        currentVersion: ReleaseVersion,
        source: AutomaticCheckSource
    ) {
        guard let latestVersion = release.version else {
            if source == .manual {
                infoAlertPresenter(
                    "Could Not Check for Updates",
                    "GitHub returned an update tag OmniWM could not parse."
                )
            }
            return
        }

        if latestVersion <= currentVersion {
            knownAvailableRelease = nil
            if source == .manual {
                infoAlertPresenter(
                    "You're Up to Date",
                    "OmniWM \(currentVersionStringProvider()) is already the latest available release."
                )
            }
            return
        }

        knownAvailableRelease = release

        if source == .automatic,
           skippedReleaseTag == latestVersion.normalizedString
        {
            return
        }

        showUpdatePopup(for: release, source: source)
    }

    private func showUpdatePopup(
        for release: GitHubRelease,
        source: AutomaticCheckSource
    ) {
        let currentVersion = currentVersionStringProvider()
        let latestVersion = release.version?.normalizedString ?? release.tagName
        let publishedDateText = release.publishedAt.map(Self.formattedDate)
        let releaseNotes = release.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No release notes were provided for this release."
            : release.body

        windowController.onWindowClosedWithoutAction = { [weak self] in
            self?.handleNotNow(for: release, source: source)
        }
        windowController.show(
            configuration: UpdatePopupConfiguration(
                releaseTitle: release.releaseTitle,
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                publishedDateText: publishedDateText,
                releaseNotes: releaseNotes,
                openReleasePage: { [weak self] in
                    self?.handleOpenReleasePage(for: release)
                },
                copyCommand: { [weak self] in
                    self?.copyCommandToPasteboard(Self.homebrewUpdateCommand)
                },
                skipThisVersion: { [weak self] in
                    self?.handleSkipThisVersion(for: release)
                },
                notNow: { [weak self] in
                    self?.handleNotNowAndClose(for: release, source: source)
                }
            )
        )
    }

    private func handleOpenReleasePage(for release: GitHubRelease) {
        openURL(validatedReleasePageURL(for: release))
        windowController.close(markingActionHandled: true)
    }

    private func handleSkipThisVersion(for release: GitHubRelease) {
        if let version = release.version {
            runtimeState.updaterSkippedReleaseTag = version.normalizedString
        }
        windowController.close(markingActionHandled: true)
    }

    private func handleNotNowAndClose(
        for release: GitHubRelease,
        source: AutomaticCheckSource
    ) {
        handleNotNow(for: release, source: source)
        windowController.close(markingActionHandled: true)
    }

    private func handleNotNow(
        for release: GitHubRelease,
        source: AutomaticCheckSource
    ) {
        guard source == .automatic, let version = release.version else { return }
        runtimeState.updaterSkippedReleaseTag = version.normalizedString
    }

    private func shouldPerformAutomaticCheck() -> Bool {
        guard let lastCheckedAt = runtimeState.updaterLastCheckedAt else {
            return true
        }
        return nowProvider().timeIntervalSince(lastCheckedAt) >= 86_400
    }

    private func currentKnownAvailableRelease() -> GitHubRelease? {
        guard let release = knownAvailableRelease,
              let currentVersion = currentVersionProvider(),
              let latestVersion = release.version,
              latestVersion > currentVersion
        else {
            knownAvailableRelease = nil
            return nil
        }
        return release
    }

    private var skippedReleaseTag: String? {
        runtimeState.updaterSkippedReleaseTag
    }

    private func validatedReleasePageURL(for release: GitHubRelease) -> URL {
        let url = release.releasePageURL
        guard let host = url.host,
              host.caseInsensitiveCompare("github.com") == .orderedSame,
              url.path.hasPrefix("/BarutSRB/OmniWM/releases")
        else {
            return Self.releasesPageURL
        }
        return url
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

enum UpdateCoordinatorError: LocalizedError {
    case invalidResponse
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case let .badStatus(statusCode):
            return "GitHub returned HTTP \(statusCode) while checking for updates."
        }
    }
}

private struct GitHubLatestReleasePayload: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}
