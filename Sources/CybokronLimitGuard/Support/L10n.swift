import Foundation
import LimitGuardCore

/// The app's user-facing text, by area: `L10n.App.name`, `L10n.Menu.quit(_:)`.
///
/// Every entry is a key of `Resources/<language>.lproj/Localizable.strings` with its English text,
/// which `en.lproj` repeats (`LocalizationTests` keep the two in step: add a key to both). Texts
/// with values are functions whose parameters fill the placeholders in order: `%@` takes a
/// `String`, `%ld` an `Int`. Counts pick a `.one` or `.other` key.
enum L10n {
    enum App {
        static var name: String { tr("app.name", "Cybokron Limit Guard") }
    }

    enum Menu {
        static func quit(_ appName: String) -> String { tr("menu.quit", "Quit %@", appName) }
    }
}

extension L10n {
    enum Common {
        static var cancel: String { tr("common.cancel", "Cancel") }
        static var ok: String { tr("common.ok", "OK") }
        static var close: String { tr("common.close", "Close") }
        static var done: String { tr("common.done", "Done") }
        static var install: String { tr("common.install", "Install") }
        static var tryAgain: String { tr("common.tryAgain", "Try Again") }
        static var changelog: String { tr("common.changelog", "Changelog") }
        static var links: String { tr("common.links", "Links") }
        static var openReleasesPage: String { tr("common.openReleasesPage", "Open Releases Page") }
        static var checkForUpdates: String { tr("common.checkForUpdates", "Check for Updates…") }
        /// "About Cybokron Limit Guard".
        static func about(_ appName: String) -> String { tr("common.about", "About %@", appName) }
        /// A version as shown next to its number: "v0.1.0".
        static func version(_ version: String) -> String { tr("common.versionShort", "v%@", version) }
        static func installingVersion(_ version: String) -> String {
            tr("common.update.installing", "Installing version %@…", version)
        }
        static func installedRestarting(_ version: String) -> String {
            tr("common.update.restarting", "Installed version %@ — restarting…", version)
        }
    }
}

extension L10n {
    enum Settings {}
}

// MARK: - Settings: updates

extension L10n.Settings {
    static var updatesTab: String { tr("settings.tab.updates", "Updates") }
    static var supportTab: String { tr("settings.support.tab", "Support") }

        enum Updates {
            static var automatic: String { tr("settings.updates.automatic", "Automatically check for updates") }
            static var currentVersion: String { tr("settings.updates.currentVersion", "Current version") }
            static var lastChecked: String { tr("settings.updates.lastChecked", "Last checked") }
            static var checkNow: String { tr("settings.updates.checkNow", "Check Now") }
            static var otherVersions: String { tr("settings.updates.otherVersions", "Other Versions…") }
            static var footer: String {
                tr(
                    "settings.updates.footer",
                    "Checks the project's GitHub releases at launch and every 6 hours; only the app's version number is sent along. A new version is installed only after you choose Download and Install. Other Versions… installs any published release, older or newer; going back skips the newer ones in automatic checks."
                )
            }
            static var viewChangelog: String { tr("settings.updates.viewChangelog", "View Changelog") }
            static var latestPath: String {
                tr("settings.updates.latestPath", "Back on the latest path: every newer release is offered")
            }
            /// The versions, separated by commas.
            static func skippedVersions(_ versions: String) -> String {
                tr("settings.updates.skipped", "Skipped newer versions: %@", versions)
            }
            static var clear: String { tr("settings.updates.clear", "Clear") }
            static var clearHelp: String { tr("settings.updates.clear.help", "Let automatic checks offer these versions again") }
            static var never: String { tr("settings.updates.never", "Never") }
            static var notChecked: String { tr("settings.updates.status.idle", "Not checked since the app started") }
            static var checking: String { tr("settings.updates.status.checking", "Checking…") }
            static func upToDate(_ version: String) -> String {
                tr("settings.updates.status.upToDate", "You're up to date (v%@)", version)
            }
            static func available(_ version: String) -> String {
                tr("settings.updates.status.available", "Version %@ is available", version)
            }
            static var showUpdate: String { tr("settings.updates.showUpdate", "Show Update…") }
        }

        enum OtherVersions {
            static var title: String { tr("settings.otherVersions.title", "Other Versions") }
            static func intro(_ appName: String) -> String {
                tr(
                    "settings.otherVersions.intro",
                    "Install any published release of %@, older or newer. The app quits and reopens as the version you pick.",
                    appName
                )
            }
            static var releasesOnGitHub: String { tr("settings.otherVersions.releasesLink", "Open Releases Page on GitHub") }
            static var loading: String { tr("settings.otherVersions.loading", "Loading releases from GitHub…") }
            static var none: String { tr("settings.otherVersions.none", "GitHub lists no published releases.") }
            static var current: String { tr("settings.otherVersions.current", "Current") }
            static var noDownload: String { tr("settings.otherVersions.noDownload", "No download") }
            static func installHelp(_ version: String) -> String {
                tr("settings.otherVersions.install.help", "Install version %@", version)
            }
            static var noDiskImage: String {
                tr("settings.otherVersions.install.noImage", "This release has no disk image to install from.")
            }
            static func confirmTitle(_ version: String) -> String {
                tr("settings.otherVersions.confirm.title", "Install version %@?", version)
            }
            static func confirmQuits(_ appName: String, version: String) -> String {
                tr("settings.otherVersions.confirm.quits", "%1$@ quits and reopens as version %2$@.", appName, version)
            }
            static func confirmCantUpdate(_ version: String) -> String {
                tr(
                    "settings.otherVersions.confirm.cantUpdate",
                    "Version %@ can't update itself: to come back, download a newer version from the releases page.",
                    version
                )
            }
            /// The versions, separated by commas.
            static func confirmSkips(_ versions: String) -> String {
                tr(
                    "settings.otherVersions.confirm.skips",
                    "Automatic checks then skip the newer versions (%@); Check for Updates… still offers them.",
                    versions
                )
            }
            static var confirmOlder: String {
                tr(
                    "settings.otherVersions.confirm.older",
                    "An older version may not know about features added since."
                )
            }
            static var busyTitle: String { tr("settings.otherVersions.busy.title", "An update is under way") }
            static func busyMessage(_ appName: String) -> String {
                tr(
                    "settings.otherVersions.busy.message",
                    "%@ is checking for or installing an update right now. Try again once it's finished.",
                    appName
                )
            }
            static var confirmUpgrade: String {
                tr(
                    "settings.otherVersions.confirm.upgrade",
                    "Skipped versions are cleared, so automatic checks offer every newer release again."
                )
            }
            /// Title of the question before installing a version older than
            /// `ReleaseHistory.minimumSecurityVersion`.
            static var preSafetyTitle: String {
                tr("updates.otherVersions.preSafety.title", "This version lacks security fixes")
            }
            static func preSafetyMessage(_ version: String) -> String {
                tr(
                    "updates.otherVersions.preSafety.message",
                    "Version %@ was released before important security fixes, such as stricter checks of the updates it installs. Install it only if you need it, and update to the latest version again afterwards.",
                    version
                )
            }
            /// Part of the question before installing an older version.
            static var dataCopiesNote: String {
                tr(
                    "settings.otherVersions.dataCopies",
                    "Copies of your data files are kept next to them before it's installed, in case that version can't read the newer ones."
                )
            }
        }
}

// MARK: - Changelog

extension L10n {
    enum Changelog {
        static var tab: String { tr("changelog.tab", "Changelog") }
        /// "Current version: 0.6.0".
        static func currentVersion(_ version: String) -> String {
            tr("changelog.currentVersion", "Current version: %@", version)
        }
        static var refresh: String { tr("changelog.refresh", "Refresh") }
        static var refreshHelp: String { tr("changelog.refresh.help", "Load the latest release notes from GitHub") }
        /// "Last updated 3 minutes ago"; `relativeDate` is the system's relative date, e.g. "3 minutes ago".
        static func lastUpdated(_ relativeDate: String) -> String {
            tr("changelog.lastUpdated", "Last updated %@", relativeDate)
        }
        static var header: String { tr("changelog.header", "Release Notes") }
        static var footer: String {
            tr(
                "changelog.footer",
                "From the project's GitHub releases. A copy stays on this Mac, so the notes show offline too."
            )
        }
        static var latest: String { tr("changelog.latest", "Latest") }
        static var installed: String { tr("changelog.installed", "Installed") }
        static var prerelease: String { tr("changelog.prerelease", "Pre-release") }
        static var noNotes: String { tr("changelog.noNotes", "No release notes for this version.") }
        static var loading: String { tr("changelog.loading", "Loading release notes from GitHub…") }
        static var unavailable: String { tr("changelog.unavailable", "Release notes unavailable") }
        static var showingCachedCopy: String {
            tr("changelog.error.cached", "Could not load release notes — showing cached copy.")
        }
        static var retryHint: String { tr("changelog.retry", "Click Refresh to try again.") }
        static var openRelease: String { tr("changelog.openRelease", "View on GitHub") }
    }

    // MARK: - Update window

    enum UpdateWindow {
        static var title: String { tr("updateWindow.title", "Software Update") }
        static var checking: String { tr("updateWindow.checking", "Checking for updates…") }
        static var upToDateTitle: String { tr("updateWindow.upToDate.title", "You're up to date!") }
        static func upToDateMessage(_ appName: String, version: String) -> String {
            tr("updateWindow.upToDate.message", "%1$@ %2$@ is the newest version available.", appName, version)
        }
        static func availableTitle(_ appName: String) -> String {
            tr("updateWindow.available.title", "A new version of %@ is available!", appName)
        }
        static func availableMessage(_ version: String, current: String) -> String {
            tr("updateWindow.available.message", "Version %1$@ is available — you have %2$@.", version, current)
        }
        static var availableNoDiskImage: String {
            tr(
                "updateWindow.available.noImage",
                "This release has no disk image for automatic installation; download it from its release page."
            )
        }
        static var availableQuestion: String { tr("updateWindow.available.question", "Would you like to download and install it now?") }
        static var skipVersion: String { tr("updateWindow.skip", "Skip This Version") }
        static var remindLater: String { tr("updateWindow.remindLater", "Remind Me Later") }
        static var openReleasePage: String { tr("updateWindow.openReleasePage", "Open Release Page") }
        static var downloadAndInstall: String { tr("updateWindow.downloadAndInstall", "Download and Install") }
        static func downloading(_ version: String) -> String { tr("updateWindow.downloading", "Downloading version %@…", version) }
        static func restartsWhenDone(_ appName: String) -> String {
            tr("updateWindow.restartsWhenDone", "%@ restarts when it's done.", appName)
        }
        static func reopening(_ appName: String) -> String { tr("updateWindow.reopening", "%@ is reopening.", appName) }
        static var dryRunTitle: String { tr("updateWindow.dryRun.title", "Dry run finished") }
        static func dryRunMessage(_ version: String, path: String) -> String {
            tr(
                "updateWindow.dryRun.message",
                "Version %1$@ was downloaded, verified and copied to %2$@. Nothing was replaced.",
                version, path
            )
        }
        static var checkFailed: String { tr("updateWindow.checkFailed", "Couldn't check for updates") }
        static func installFailed(_ version: String) -> String {
            tr("updateWindow.installFailed", "Version %@ couldn't be installed", version)
        }
        static var releasesLink: String { tr("updateWindow.link.releases", "Releases") }
        static var releasePageLink: String { tr("updateWindow.link.releasePage", "Release Page") }
        static var releaseNotes: String { tr("updateWindow.releaseNotes", "Release Notes") }
        static var noReleaseNotes: String { tr("updateWindow.releaseNotes.none", "This release has no notes.") }
        static func relaunchFailed(_ version: String) -> String {
            tr(
                "updateWindow.relaunchFailed",
                "Version %@ is installed, but the app couldn't restart itself. Quit it and open it again.",
                version
            )
        }
    }

    // MARK: - About

    enum About {
        static var findMeOnline: String { tr("about.section.findMe", "Find Me Online") }
        static var supportProject: String { tr("about.section.support", "Support This Project") }
        static var books: String { tr("about.section.books", "My Books") }
        static var openSource: String { tr("about.section.software", "My Open Source Software") }
        static var fullList: String { tr("about.fullList", "Full list at github.com/ercanatay") }
        static var blogs: String { tr("about.section.blogs", "Medium Blogs") }
        static func iconAccessibility(_ appName: String) -> String { tr("about.icon.accessibility", "%@ icon", appName) }
        static func version(_ version: String) -> String {
            tr("about.version", "Version %@ · open source, MIT License", version)
        }
        static var website: String { tr("about.website", "Website") }
        static var sourceCode: String { tr("about.sourceCode", "Source Code") }
        static var license: String { tr("about.license", "License") }
        static var reportBug: String { tr("about.reportBug", "Found a bug? Open an issue") }
        /// What the projects in My Open Source Software are.
        enum Project {
            static var limitGuard: String { tr("about.project.limitGuard", "This app · Codex usage limits in the macOS menu bar") }
            static var dockGroups: String { tr("about.project.dockGroups", "Dock groups for macOS") }
            static var intelComputerUse: String {
                tr("about.project.intelComputerUse", "Native macOS desktop automation for Intel Macs via MCP.")
            }
            static var exchangeRate: String {
                tr(
                    "about.project.exchangeRate",
                    "PHP/MySQL exchange rate & portfolio tracker with live scrape + GitHub release updates."
                )
            }
            static var backlinkChecker: String {
                tr("about.project.backlinkChecker", "Check anchors, dofollow/nofollow and HTTP statuses of backlinks.")
            }
            static var consentManager: String {
                tr("about.project.consentManager", "YOOtheme Pro 5 Consent Manager translations plugin (WordPress.org).")
            }
            static var antigravityUpdater: String {
                tr("about.project.antigravityUpdater", "Lightweight macOS updater for Antigravity Tools, 21 languages.")
            }
            static var widgetVisibility: String {
                tr("about.project.widgetVisibility", "Jetpack-free WP plugin for widget visibility with descendant support.")
            }
            static var forbiddenContent: String {
                tr(
                    "about.project.forbiddenContent",
                    "Detects forbidden keywords (e.g. 'Casino') in post titles — like a WP audit checker."
                )
            }
        }
    }
}

// MARK: - Lookup

/// `L10n`'s lookups; the key and English text must be literals (`LocalizationTests` read them).
private func tr(_ key: String, _ english: String) -> String {
    Localization.string(key, english)
}

private func tr(_ key: String, _ english: String, _ arguments: any CVarArg...) -> String {
    Localization.format(key, english, arguments: arguments)
}
