import Foundation

/// 确定性的只读命令判定：命中就直接运行，不再请 AI 审查，也不问用户。
///
/// 仍然是一套小文法而不是 shell 解析器：允许管道和 `&&` / `||` / `;` 串起来的只读命令、
/// 丢到 `/dev/null` 的重定向和 `2>&1`；变量、命令替换、写文件的重定向、后台 `&`、
/// 环境变量前缀、带路径的可执行文件一律判否，交回原来的审批流程。
/// 只读也不等于可以随便读：凭据、私钥、环境变量这类敏感目标同样判否。
enum ReadOnlyShellCommand {
    static func isReadOnly(_ command: String) -> Bool {
        guard command.utf8.count <= 4096, let segments = lex(command), !segments.isEmpty else { return false }
        for segment in segments {
            guard let name = segment.first?.text, name.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil,
                  let rule = rules[name] else { return false }
            let args = segment.dropFirst().map(\.text)
            guard rule(args) else { return false }
            // 通配符能绕过下面的敏感路径检查（`cat ~/.s*/id_*`），只留给不吐文件内容的命令。
            if segment.dropFirst().contains(where: \.globbed), !globSafe.contains(name) { return false }
            let lowered = segment.map { $0.text.lowercased() }
            if lowered.contains(where: { word in sensitive.contains { word.contains($0) } }) { return false }
        }
        return true
    }

    // MARK: - 词法

    private struct Word { var text = ""; var globbed = false }

    /// 切成以 `|` `||` `&&` `;` 分隔的命令段；碰到文法外的东西返回 nil。
    private static func lex(_ command: String) -> [[Word]]? {
        let chars = Array(command)
        var segments: [[Word]] = [], words: [Word] = []
        var word = Word(), started = false, i = 0

        func endWord() { if started { words.append(word) }; word = Word(); started = false }
        func endSegment() -> Bool {
            endWord()
            guard !words.isEmpty else { return false }
            segments.append(words); words = []
            return true
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t":
                endWord()
            case "'":
                guard let close = chars[(i + 1)...].firstIndex(of: "'") else { return nil }
                word.text += String(chars[(i + 1)..<close]); started = true; i = close
            case "\"":
                guard let close = chars[(i + 1)...].firstIndex(of: "\"") else { return nil }
                let body = chars[(i + 1)..<close]
                guard !body.contains(where: { "$`\\".contains($0) }) else { return nil }
                word.text += String(body); started = true; i = close
            case "|", ";":
                if c == "|", i + 1 < chars.count, chars[i + 1] == "|" { i += 1 }
                guard endSegment() else { return nil }
            case "&":
                if i + 1 < chars.count, chars[i + 1] == "&" {
                    i += 1
                    guard endSegment() else { return nil }
                } else if i + 1 < chars.count, chars[i + 1] == ">", !started {
                    guard let next = redirectTarget(chars, from: i + 2) else { return nil }
                    i = next - 1
                } else { return nil }   // 后台运行
            case ">":
                // `2>/dev/null`、`>/dev/null`、`2>&1`、`1>&2`；其余写文件的重定向都不行。
                guard !started || word.text == "1" || word.text == "2" else { return nil }
                word = Word(); started = false
                if i + 2 < chars.count, chars[i + 1] == "&", "12".contains(chars[i + 2]) {
                    // `>&1x` 是重定向到名为 1x 的文件。
                    guard i + 3 == chars.count || " |;&".contains(chars[i + 3]) else { return nil }
                    i += 2
                } else {
                    var from = i + 1
                    if from < chars.count, chars[from] == ">" { from += 1 }
                    guard let next = redirectTarget(chars, from: from) else { return nil }
                    i = next - 1
                }
            case "*", "?", "[":
                word.text.append(c); word.globbed = true; started = true
            default:
                guard !"$`\\<(){}!#".contains(c), !c.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else { return nil }
                word.text.append(c); started = true
            }
            i += 1
        }
        return endSegment() ? segments : nil
    }

    /// 重定向目标只能是 `/dev/null`；返回目标之后的位置。
    private static func redirectTarget(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count, chars[i] == " " { i += 1 }
        let target = Array("/dev/null")
        guard i + target.count <= chars.count, Array(chars[i..<(i + target.count)]) == target else { return nil }
        let end = i + target.count
        guard end == chars.count || " |;&".contains(chars[end]) else { return nil }
        return end
    }

    // MARK: - 规则

    private typealias Rule = ([String]) -> Bool

    private static let any: Rule = { _ in true }
    private static let noOperands: Rule = { $0.allSatisfy { $0.hasPrefix("-") } }

    /// 出现这些选项就不再只读（写文件、执行命令、改系统状态）。短选项按字母查，能抓到 `-no` 这种合写。
    private static func deny(short: String = "", long: [String] = []) -> Rule {
        { args in
            !args.contains { arg in
                if arg.hasPrefix("--") { return long.contains { arg == $0 || arg.hasPrefix($0 + "=") } }
                return arg.hasPrefix("-") && arg.dropFirst().contains { short.contains($0) }
            }
        }
    }

    /// 第一个非选项参数必须是只读子命令。`valueFlags` 是会吃掉下一个参数的前置选项。
    private static func subcommand(_ allowed: Set<String>, valueFlags: Set<String> = []) -> Rule {
        { args in
            var i = 0
            while i < args.count, args[i].hasPrefix("-") {
                i += valueFlags.contains(args[i]) ? 2 : 1
            }
            return i < args.count && allowed.contains(args[i])
        }
    }

    private static let rules: [String: Rule] = {
        var rules: [String: Rule] = [:]
        for name in ["pwd", "whoami", "id", "groups", "uname", "uptime", "nproc", "arch", "tty", "who", "w",
                     "lscpu", "lsblk", "lsmem", "lspci", "lsusb", "lsb_release", "sw_vers", "getconf", "locale",
                     "cat", "head", "tail", "wc", "stat", "file", "which", "whereis", "type",
                     "basename", "dirname", "realpath", "readlink", "echo", "printf", "true", "false", "test",
                     "cut", "tr", "column", "nl", "tac", "rev", "cmp", "comm", "jq",
                     "md5sum", "sha1sum", "sha256sum", "sha512sum", "shasum", "md5", "cksum",
                     "df", "free", "du", "vmstat", "iostat", "mpstat", "ps", "pgrep", "pidof", "lsof",
                     "ss", "netstat", "dig", "nslookup", "host", "getent", "cd", "ls", "last"] {
            rules[name] = any
        }
        // 递归 grep / diff 会把整棵目录的内容吐出来（家目录下就是 ~/.ssh），回到审批。
        rules["grep"] = deny(short: "rR", long: ["--recursive", "--dereference-recursive"])
        rules["egrep"] = rules["grep"]; rules["fgrep"] = rules["grep"]
        rules["diff"] = deny(short: "r", long: ["--recursive"])
        rules["sort"] = deny(short: "o", long: ["--output", "--compress-program"])
        rules["uniq"] = { args in args.filter { !$0.hasPrefix("-") }.count <= 1 }
        rules["tree"] = deny(short: "o")
        rules["find"] = { args in
            !args.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir",
                              "-fprint", "-fprint0", "-fprintf", "-fls"].contains($0) }
        }
        rules["date"] = { args in
            deny(short: "sf", long: ["--set", "--file"])(args)
                && args.allSatisfy { $0.hasPrefix("-") || $0.hasPrefix("+") }
        }
        rules["hostname"] = { args in noOperands(args) && deny(short: "bF", long: ["--boot", "--file"])(args) }
        rules["mount"] = { $0.isEmpty }
        rules["ifconfig"] = { $0.isEmpty || $0 == ["-a"] }
        rules["top"] = { args in args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("b") } }
        rules["dmesg"] = deny(short: "cCDEn", long: ["--clear", "--read-clear", "--console-off",
                                                      "--console-on", "--console-level"])
        rules["journalctl"] = deny(long: ["--vacuum-size", "--vacuum-time", "--vacuum-files", "--rotate",
                                          "--flush", "--sync", "--relinquish-var", "--smart-relinquish-var",
                                          "--setup-keys", "--update-catalog"])
        rules["crontab"] = { $0 == ["-l"] || ($0.count == 3 && $0[0] == "-l" && $0[1] == "-u") }
        rules["ip"] = { args in
            let objects: Set<String> = ["addr", "address", "a", "route", "r", "link", "l", "neigh", "n", "rule", "maddr"]
            let operands = args.filter { !$0.hasPrefix("-") }
            guard let object = operands.first, objects.contains(object) else { return false }
            return operands.count == 1 || ["show", "list", "ls"].contains(operands[1])
        }
        rules["systemctl"] = subcommand(["status", "list-units", "list-unit-files", "list-timers", "list-sockets",
                                         "list-dependencies", "is-active", "is-enabled", "is-failed",
                                         "is-system-running", "get-default"])
        rules["service"] = { $0 == ["--status-all"] || ($0.count == 2 && $0[1] == "status") }
        rules["timedatectl"] = { $0.isEmpty || $0 == ["status"] }
        rules["hostnamectl"] = { $0.isEmpty || $0 == ["status"] }
        // inspect / exec / compose config 会带出容器环境变量里的口令，不在这里。
        let dockerList: Set<String> = ["ls", "list"]
        rules["docker"] = { args in
            let operands = args.filter { !$0.hasPrefix("-") }
            guard let first = operands.first else { return false }
            switch first {
            case "ps", "images", "logs", "stats", "version", "info", "top", "port", "diff", "history": return true
            case "network", "volume", "container", "image", "context":
                return operands.count >= 2 && dockerList.contains(operands[1])
            case "compose":
                return operands.count >= 2 && ["ps", "logs", "ls", "images", "top", "version"].contains(operands[1])
            default: return false
            }
        }
        rules["kubectl"] = subcommand(["get", "describe", "logs", "top", "version", "explain", "api-resources",
                                       "api-versions", "cluster-info", "events"],
                                      valueFlags: ["-n", "--namespace", "--context", "--cluster", "-l", "--selector"])
        rules["git"] = { args in
            var rest = args[...]
            while let flag = rest.first, flag.hasPrefix("-") {
                // `-c` 能改 core.fsmonitor 之类、等于执行任意命令。
                if flag == "-C" { rest = rest.dropFirst(2) }
                else if flag == "--no-pager" { rest = rest.dropFirst() }
                else { return false }
            }
            guard let sub = rest.first else { return false }
            let tail = Array(rest.dropFirst())
            let listOnly: Rule = { $0.allSatisfy { ["-a", "-r", "-v", "-vv", "-l", "--list", "--all",
                                                    "--show-current", "--merged", "--no-merged"].contains($0) } }
            switch sub {
            case "status", "blame", "ls-files", "ls-tree", "rev-parse", "describe", "shortlog", "grep":
                return true
            case "log", "diff", "show": return deny(long: ["--output", "--ext-diff"])(tail)
            case "branch", "tag": return listOnly(tail)
            case "remote": return tail.isEmpty || tail == ["-v"]
            case "stash": return tail == ["list"]
            default: return false
            }
        }
        rules["nginx"] = { !$0.isEmpty && $0.allSatisfy { ["-t", "-T", "-v", "-V"].contains($0) } }
        rules["apt"] = subcommand(["list", "show", "policy"])
        rules["apt-cache"] = subcommand(["policy", "show", "search", "depends", "rdepends", "madison"])
        rules["dpkg"] = { args in
            guard let first = args.first else { return false }
            return ["-l", "-L", "-s", "-S", "--list", "--listfiles", "--status", "--search"].contains(first)
        }
        rules["rpm"] = { args in args.first.map { $0.hasPrefix("-q") } ?? false }
        rules["brew"] = subcommand(["list", "ls", "info", "outdated", "deps", "leaves", "config", "doctor"])
        for pip in ["pip", "pip3"] { rules[pip] = subcommand(["list", "show", "freeze"]) }
        return rules
    }()

    /// 带通配符也不会吐出文件内容的命令。
    private static let globSafe: Set<String> = ["ls", "du", "stat", "file", "wc", "find", "tree", "echo",
                                                "md5sum", "sha1sum", "sha256sum", "sha512sum", "shasum",
                                                "md5", "cksum", "realpath", "readlink", "basename", "dirname"]

    /// 出现在任何参数里都判否：凭据、私钥、令牌、环境变量与历史记录。
    private static let sensitive = [".ssh", ".aws", ".azure", ".gnupg", ".kube", ".docker/config", ".netrc",
                                    ".pgpass", ".my.cnf", ".git-credentials", ".env", "id_rsa", "id_dsa",
                                    "id_ecdsa", "id_ed25519", ".pem", ".key", ".p12", ".pfx", ".jks",
                                    ".keystore", "shadow", "sudoers", "password", "secret", "credential",
                                    "token", "keychain", "environ", "history"]
}
