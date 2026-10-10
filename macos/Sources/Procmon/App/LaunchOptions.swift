// Command-line options, for scripting and debugging.

import Foundation

struct LaunchOptions {
    static let usage = """
        Usage: procmon [OPTIONS]

        Options:
          --page <name>    Open on a page: overview, memory, activity, graphics, storage, recovery or devices
          --scan <path>    Open Storage and start scanning <path>
          --inspect <pid>  Open the details panel for a process
          -h, --help       Print this help
        """

    var page: Page?
    var scan: String?
    var inspect: PID?

    /// Parses `arguments` (without the program name). Prints help and exits
    /// for `--help`; reports and skips anything it does not understand.
    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            // Launch Services and Xcode pass their own flags, e.g. `-NSDocumentRevisionsDebugMode YES`.
            if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
                _ = remaining.popFirst()
                continue
            }
            if argument.hasPrefix("-psn_") { continue }
            switch argument {
            case "-h", "--help":
                print(usage)
                exit(0)
            case "--page":
                guard let name = remaining.popFirst() else { break }
                if let page = Page(rawValue: name.lowercased()) {
                    options.page = page
                } else {
                    warn("unknown page `\(name)`, expected one of: \(Page.allCases.map(\.rawValue).joined(separator: ", "))")
                }
            case "--scan":
                if let path = remaining.popFirst() {
                    options.scan = (path as NSString).expandingTildeInPath
                }
            case "--inspect":
                guard let raw = remaining.popFirst() else { break }
                if let pid = Int32(raw) {
                    options.inspect = PID(pid)
                } else {
                    warn("`\(raw)` is not a process id")
                }
            default:
                warn("ignoring unexpected argument `\(argument)`\n\n\(usage)")
            }
        }
        return options
    }

    var initialPage: Page {
        page ?? (scan != nil ? .storage : inspect != nil ? .activity : .overview)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("procmon: \(message)\n".utf8))
    }
}
