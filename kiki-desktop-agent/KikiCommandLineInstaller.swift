//
//  KikiCommandLineInstaller.swift
//  kiki-desktop-agent
//
//  Puts the copy of `kiki` inside this app into the user's PATH.

import Foundation

/// The one symlink that turns the `kiki` this app carries into a command a terminal can find.
///
/// The embedded copy is the only one a downloaded release has, and a symlink to it never goes
/// stale — a new version replaces `Kiki.app` whole and the command follows it. The link goes in
/// `/usr/local/bin`, which is on the default PATH and belongs to root, so putting it there costs
/// exactly one system authorisation prompt. A directory the user can write without one is not the
/// shortcut it looks like: `~/.local/bin` and `~/bin` are on no default PATH, so an install there
/// would be a command that is never found.
enum KikiCommandLineInstaller {

    /// Where the command goes. The same path the README and the release notes hand out.
    nonisolated static let pathWhereTheCommandIsInstalled = "/usr/local/bin/kiki"

    /// The copy of the tool inside the bundle this app is running from, or nil for a build that
    /// carries none — which is what the panel reads to leave the install row out rather than
    /// offer to install nothing.
    nonisolated static var toolInsideTheRunningApp: URL? {
        guard let resourcesURL = Bundle.main.resourceURL else { return nil }
        let toolURL = resourcesURL.appendingPathComponent("kiki")
        return FileManager.default.isExecutableFile(atPath: toolURL.path) ? toolURL : nil
    }

    /// Whether the command in PATH is this app's own tool — the question the panel's row draws,
    /// not "is something there". Both sides of the comparison are resolved, so the answer is about
    /// the file rather than about how the link was spelled.
    nonisolated static var isInstalled: Bool {
        guard let tool = toolInsideTheRunningApp,
              let destination = try? FileManager.default.destinationOfSymbolicLink(
                  atPath: pathWhereTheCommandIsInstalled
              )
        else { return false }

        return URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
            == tool.resolvingSymlinksInPath().path
    }

    /// Makes the link, the direct way when the directory can be written and behind an
    /// authorisation prompt when it cannot.
    ///
    /// The prompt is a blocking wait of however long a person takes to type a password, so it
    /// runs on a queue of its own rather than on the main actor — the shape
    /// `ScreenshotTextRecognizer` uses to keep a synchronous framework call off it. Nothing comes
    /// back: whether the link landed is read off the disk by the caller afterwards.
    static func install() async {
        guard let tool = toolInsideTheRunningApp else { return }

        await withCheckedContinuation { continuation in
            installationQueue.async {
                if !createTheLinkDirectlyIfTheDirectoryAllowsIt(tool: tool),
                   !createTheLinkBehindAnAuthorisationPrompt(tool: tool) {
                    print("The command line tool could not be installed.")
                }
                continuation.resume()
            }
        }
    }

    /// The direct way. What stands at the path is removed first, because installing over a link of
    /// ours that has gone stale (the app has moved) or one made by hand from the README is part of
    /// installing rather than a conflict with it.
    nonisolated private static func createTheLinkDirectlyIfTheDirectoryAllowsIt(tool: URL) -> Bool {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: pathWhereTheCommandIsInstalled)

        do {
            try fileManager.createSymbolicLink(
                atPath: pathWhereTheCommandIsInstalled,
                withDestinationPath: tool.path
            )
            return true
        } catch {
            return false
        }
    }

    /// The same link as an administrator, through the system's own authorisation dialog — the one
    /// a person already knows from every other tool that installs itself.
    ///
    /// `mkdir -p` because a Mac that has never had anything in `/usr/local` has no `bin` there at
    /// all, and `ln -sf` because what is being replaced may be a link from a Kiki that has since
    /// moved. The command travels as an argument to `osascript` rather than inside the script
    /// text, so the paths in it are quoted once — for the shell — and never for AppleScript too.
    nonisolated private static func createTheLinkBehindAnAuthorisationPrompt(tool: URL) -> Bool {
        let shellCommand = "/bin/mkdir -p \(shellQuoted(directoryOfTheCommand))"
            + " && /bin/ln -sf \(shellQuoted(tool.path)) \(shellQuoted(pathWhereTheCommandIsInstalled))"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run theShellCommand",
            "-e", "do shell script theShellCommand with administrator privileges",
            "-e", "end run",
            shellCommand,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()

        // The link itself rather than the exit code: the code says only how the script ended, and
        // a refused prompt and a failed one are deliberately the same outcome — the row's own
        // state is the whole report, and a person who cancelled knows they cancelled.
        return isInstalled
    }

    /// Derived rather than written down beside the path, so the directory `mkdir -p` makes and
    /// the path the link goes to cannot drift apart.
    nonisolated private static var directoryOfTheCommand: String {
        (pathWhereTheCommandIsInstalled as NSString).deletingLastPathComponent
    }

    /// A path as one word for `/bin/sh`, whatever is in it.
    nonisolated private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Serial, because two installs at once would be two prompts racing to write one link.
    nonisolated private static let installationQueue = DispatchQueue(
        label: "com.smarty.kiki.command-line-installation",
        qos: .userInitiated
    )
}
