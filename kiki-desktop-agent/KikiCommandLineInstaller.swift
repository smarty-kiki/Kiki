//
//  KikiCommandLineInstaller.swift
//  kiki-desktop-agent
//

import Foundation

/// The one symlink that turns the `kiki` this app carries into a command a terminal can find.
///
/// `/usr/local/bin` is on the default PATH and owned by root, so the link costs one authorisation
/// prompt, where `~/.local/bin` and `~/bin` are on no default PATH — a command never found. A
/// symlink into the app never goes stale: a new version replaces `Kiki.app` whole and it follows.
enum KikiCommandLineInstaller {

    /// The same path the README and the release notes hand out.
    nonisolated static let pathWhereTheCommandIsInstalled = "/usr/local/bin/kiki"

    /// The copy of the tool inside this bundle, or nil for a build that carries none.
    nonisolated static var toolInsideTheRunningApp: URL? {
        guard let resourcesURL = Bundle.main.resourceURL else { return nil }
        let toolURL = resourcesURL.appendingPathComponent("kiki")
        return FileManager.default.isExecutableFile(atPath: toolURL.path) ? toolURL : nil
    }

    /// Whether the command in PATH is this app's own tool — both sides resolved, so the answer is
    /// about the file, not the spelling.
    nonisolated static var isInstalled: Bool {
        guard let tool = toolInsideTheRunningApp,
              let destination = try? FileManager.default.destinationOfSymbolicLink(
                  atPath: pathWhereTheCommandIsInstalled
              )
        else { return false }

        return URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
            == tool.resolvingSymlinksInPath().path
    }

    /// Makes the link, directly when the directory allows it and behind an authorisation prompt when
    /// it does not. The prompt blocks, so it runs on a queue of its own.
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

    /// The direct way. What stands at the path is removed first: installing over a stale link or one
    /// made by hand from the README is part of installing, not a conflict.
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

    /// The same link as an administrator, through the system's authorisation dialog. `mkdir -p`
    /// because `/usr/local` may have no `bin`; `ln -sf` because what stands there may be a stale link.
    /// The command travels as an argument to `osascript`, so its paths are quoted once for the shell.
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

        // The link itself rather than the exit code: a refused prompt and a failed install are the
        // same outcome.
        return isInstalled
    }

    /// Derived, so it cannot drift from the path the link goes to.
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
