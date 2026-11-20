import Darwin
import Foundation

@main struct InstallMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().path
            if arguments.isEmpty { try installBoxlingService(artifactDirectory: directory) }
            else if arguments.count == 2, arguments[0] == "--package-preflight" {
                try preparePackageInstallation(target: arguments[1], confirmBoxStop: isGraphicalPackageInstall() ? confirmInstallerBoxStop : nil)
            } else if arguments == ["--uninstall-preflight", "/"] {
                try preparePackageInstallation(target: "/", confirmBoxStop: { names in
                    guard isatty(STDIN_FILENO) != 0 else { return false }
                    note("Uninstalling will stop these boxes and interrupt their sites, terminals, and jobs. Their files will be kept.\n\n" + names.joined(separator: "\n"))
                    note("Stop these boxes and uninstall Boxling? Type yes to continue.")
                    return readLine() == "yes"
                })
            } else if arguments.count == 2, arguments[0] == "--package-install" {
                try finishPackageInstallation(target: arguments[1], artifactDirectory: directory)
            } else { throw BoxError("Usage: boxling setup-service") }
        } catch {
            note("Boxling setup: \(error)")
            (error as? PackageUpdateError)?.notifyInstallerUser()
            exit(1)
        }
    }
}
