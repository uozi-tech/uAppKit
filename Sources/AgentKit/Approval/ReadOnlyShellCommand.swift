import Foundation

/// 确定性的只读命令判定：命中就直接运行，不再请 AI 审查，也不问用户。
///
/// 仍然是一套小文法而不是 shell 解析器。认得的写法：管道和 `&&` / `||` / `;` / 换行串起来的
/// 只读命令；丢到 `/dev/null` 的重定向和 `2>&1`；`$?`；内容同样只读的 `$(…)`；
/// `for` / `while read` / `if` 结构以及循环变量；`sudo` / `time` / `timeout` / `nice` 包装。
/// 其余变量、反引号、写文件的重定向、后台 `&`、环境变量前缀、带路径的可执行文件一律判否。
///
/// 只读也不等于可以随便读：凭据、私钥、环境变量这类敏感目标同样判否；
/// 通配符、变量这种「运行时才知道读哪个文件」的参数只给不吐文件内容的命令；
/// 会一直跑下去的跟随模式（`tail -f`）和会往外发请求的命令（`dig`、`curl`）也不在这里。
enum ReadOnlyShellCommand {
    static func isReadOnly(_ command: String) -> Bool {
        isReadOnly(command, depth: 0)
    }

    private static func isReadOnly(_ command: String, depth: Int) -> Bool {
        guard depth < 3, command.utf8.count <= 4096,
              let parsed = lex(command, boundVariables: loopVariables(in: command)),
              !parsed.segments.isEmpty else { return false }
        guard parsed.substitutions.allSatisfy({ isReadOnly($0, depth: depth + 1) }) else { return false }
        return parsed.segments.allSatisfy(isReadOnlySegment)
    }

    private static func isReadOnlySegment(_ segment: [Word]) -> Bool {
        if segment.contains(where: { isSensitive($0.text) }) { return false }
        var words = segment[...]
        // 控制结构：关键字本身不执行什么，看后面跟的命令。
        while let first = words.first?.text, ["if", "elif", "while", "until", "then", "else", "do"].contains(first) {
            words = words.dropFirst()
        }
        guard let name = words.first?.text else { return true }
        if name == "done" || name == "fi" { return words.count == 1 }
        if name == "for" { return words.count >= 2 && (words.count == 2 || words[words.startIndex + 2].text == "in") }
        if let rest = unwrap(name, Array(words.dropFirst())) {
            return rest.isEmpty ? false : isReadOnlySegment(rest)
        }
        guard name.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil,
              let rule = rules[name] else { return false }
        let args = words.dropFirst()
        guard rule(args.map(\.text)) else { return false }
        // 通配符、变量能绕过敏感路径检查（`cat ~/.s*/id_*`），只留给不吐文件内容的命令。
        return !args.contains(where: \.dynamic) || globSafe.contains(name)
    }

    /// `sudo` / `time` / `timeout` / `nice` 只是包一层，返回被包住的命令；不是包装命令返回 nil。
    private static func unwrap(_ name: String, _ args: [Word]) -> [Word]? {
        var i = 0
        func skipFlags(valued: Set<String>, allowed: Set<String>? = nil) -> Bool {
            while i < args.count, args[i].text.hasPrefix("-") {
                let flag = args[i].text
                if let allowed, !allowed.contains(flag), !valued.contains(flag) { return false }
                i += valued.contains(flag) ? 2 : 1
            }
            return true
        }
        switch name {
        case "sudo":
            // 只认不改身份语义的选项；`-s` / `-i` 会起 shell，`-e` 是编辑文件。
            guard skipFlags(valued: ["-u", "-g"], allowed: ["-n", "-E", "-H", "-k"]) else { return [] }
        case "time":
            guard skipFlags(valued: [], allowed: ["-p"]) else { return [] }
        case "nice":
            guard skipFlags(valued: ["-n"]) else { return [] }
        case "timeout":
            guard skipFlags(valued: ["-s", "-k", "--signal", "--kill-after"]),
                  i < args.count, args[i].text.range(of: "^[0-9.]+[smhd]?$", options: .regularExpression) != nil
            else { return [] }
            i += 1
        default:
            return nil
        }
        return Array(args[min(i, args.count)...])
    }

    // MARK: - 词法

    private struct Word {
        var text = ""
        /// 运行时才确定的内容：通配符、变量、命令替换。
        var dynamic = false
    }

    private struct Parsed {
        var segments: [[Word]] = []
        /// `$(…)` 里的命令，要求同样只读。
        var substitutions: [String] = []
    }

    /// `for NAME in` / `read [-r] NAME…` 绑定的变量，只有这些能用 `$NAME` 引用。
    private static func loopVariables(in command: String) -> Set<String> {
        var names: Set<String> = []
        let patterns = [#"\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b"#,
                        #"\bread\s+(?:-[a-zA-Z]+\s+)*((?:[A-Za-z_][A-Za-z0-9_]*\s*)+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(command.startIndex..., in: command)
            for match in regex.matches(in: command, range: range) {
                guard let r = Range(match.range(at: 1), in: command) else { continue }
                command[r].split(whereSeparator: \.isWhitespace).forEach { names.insert(String($0)) }
            }
        }
        return names
    }

    /// 切成以 `|` `||` `&&` `;` 换行分隔的命令段；碰到文法外的东西返回 nil。
    private static func lex(_ command: String, boundVariables: Set<String>) -> Parsed? {
        let chars = Array(command)
        var parsed = Parsed()
        var words: [Word] = []
        var word = Word(), started = false, i = 0
        /// 刚过 `|` / `&&` / `||`：后面必须还有命令（`ls |` 不完整）。
        var awaitingCommand = false

        func endWord() {
            if started { words.append(word); awaitingCommand = false }
            word = Word(); started = false
        }
        func endSegment(allowEmpty: Bool = false) -> Bool {
            endWord()
            if words.isEmpty { return allowEmpty }
            parsed.segments.append(words); words = []
            return true
        }
        /// `$` 开头的展开：`$?`、`$(…)`、绑定过的循环变量。返回展开后的位置（指向最后一个字符）。
        func dollar(at index: Int) -> Int? {
            guard index + 1 < chars.count else { return nil }
            let next = chars[index + 1]
            if next == "?" { word.text += "0"; started = true; return index + 1 }
            if next == "(" {
                guard let close = matchingParen(chars, from: index + 1) else { return nil }
                parsed.substitutions.append(String(chars[(index + 2)..<close]))
                word.dynamic = true; started = true
                return close
            }
            var j = index + 1, braced = false
            if next == "{" { braced = true; j += 1 }
            var name = ""
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_", chars[j].isASCII {
                name.append(chars[j]); j += 1
            }
            guard !name.isEmpty, boundVariables.contains(name) else { return nil }
            if braced { guard j < chars.count, chars[j] == "}" else { return nil }; j += 1 }
            word.dynamic = true; started = true
            return j - 1
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t":
                endWord()
            case "\n":
                // 换行等同 `;`，空行允许。
                guard endSegment(allowEmpty: true) else { return nil }
            case "#" where !started:
                // 注释到行尾。
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            case "'":
                guard let close = chars[(i + 1)...].firstIndex(of: "'") else { return nil }
                word.text += String(chars[(i + 1)..<close]); started = true; i = close
            case "\"":
                started = true
                var j = i + 1
                while j < chars.count, chars[j] != "\"" {
                    switch chars[j] {
                    case "$":
                        guard let end = dollar(at: j) else { return nil }
                        j = end
                    case "`", "\\":
                        return nil
                    default:
                        word.text.append(chars[j])
                    }
                    j += 1
                }
                guard j < chars.count else { return nil }
                i = j
            case "$":
                guard let end = dollar(at: i) else { return nil }
                i = end
            case "|", ";":
                if c == "|", i + 1 < chars.count, chars[i + 1] == "|" { i += 1 }
                guard endSegment() else { return nil }
                awaitingCommand = c == "|"
            case "&":
                if i + 1 < chars.count, chars[i + 1] == "&" {
                    i += 1
                    guard endSegment() else { return nil }
                    awaitingCommand = true
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
                    guard i + 3 == chars.count || " |;&\n".contains(chars[i + 3]) else { return nil }
                    i += 2
                } else {
                    var from = i + 1
                    if from < chars.count, chars[from] == ">" { from += 1 }
                    guard let next = redirectTarget(chars, from: from) else { return nil }
                    i = next - 1
                }
            case "*", "?", "[":
                word.text.append(c); word.dynamic = true; started = true
            default:
                guard !"`\\<(){}!".contains(c), !c.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else { return nil }
                word.text.append(c); started = true
            }
            i += 1
        }
        guard endSegment(allowEmpty: !parsed.segments.isEmpty), !awaitingCommand else { return nil }
        return parsed
    }

    /// `$(` 的 `(` 位置 → 配对的 `)`；跳过引号里的括号。
    private static func matchingParen(_ chars: [Character], from open: Int) -> Int? {
        var depth = 0, i = open, quote: Character?
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// 重定向目标只能是 `/dev/null`；返回目标之后的位置。
    private static func redirectTarget(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count, chars[i] == " " { i += 1 }
        let target = Array("/dev/null")
        guard i + target.count <= chars.count, Array(chars[i..<(i + target.count)]) == target else { return nil }
        let end = i + target.count
        guard end == chars.count || " |;&\n".contains(chars[end]) else { return nil }
        return end
    }

    // MARK: - 规则

    private typealias Rule = ([String]) -> Bool

    private static let any: Rule = { _ in true }
    private static let noOperands: Rule = { $0.allSatisfy { $0.hasPrefix("-") } }

    /// 出现这些选项就不再只读（写文件、执行命令、改系统状态、一直跟随下去）。
    /// 短选项按字母查，能抓到 `-no` 这种合写。
    private static func deny(short: String = "", long: [String] = []) -> Rule {
        { args in
            !args.contains { arg in
                if arg.hasPrefix("--") { return long.contains { arg == $0 || arg.hasPrefix($0 + "=") } }
                return arg.hasPrefix("-") && arg.dropFirst().contains { short.contains($0) }
            }
        }
    }

    /// 第一个非选项参数必须是只读子命令。`valueFlags` 是会吃掉下一个参数的前置选项；
    /// `then` 再看子命令之后的参数。
    private static func subcommand(_ allowed: Set<String>, valueFlags: Set<String> = [],
                                   then rest: @escaping (String, [String]) -> Bool = { _, _ in true }) -> Rule {
        { args in
            var i = 0
            while i < args.count, args[i].hasPrefix("-") {
                i += valueFlags.contains(args[i]) ? 2 : 1
            }
            guard i < args.count, allowed.contains(args[i]) else { return false }
            return rest(args[i], Array(args[(i + 1)...]))
        }
    }

    /// `vmstat 1` 这类带间隔不带次数的会一直跑；只给一个数字时判否。
    private static let boundedSampling: Rule = { args in
        args.filter { $0.range(of: "^[0-9]+$", options: .regularExpression) != nil }.count != 1
    }

    private static let rules: [String: Rule] = {
        var rules: [String: Rule] = [:]
        for name in ["pwd", "whoami", "id", "groups", "uname", "uptime", "nproc", "arch", "tty", "who", "w",
                     "lscpu", "lsblk", "lsmem", "lspci", "lsusb", "lsb_release", "sw_vers", "getconf", "locale",
                     "cat", "head", "wc", "stat", "file", "which", "whereis", "type",
                     "basename", "dirname", "realpath", "readlink", "echo", "printf", "true", "false", "test",
                     "cut", "tr", "column", "nl", "tac", "rev", "cmp", "comm", "jq", "read", "sleep",
                     "md5sum", "sha1sum", "sha256sum", "sha512sum", "shasum", "md5", "cksum",
                     "df", "free", "du", "ps", "pgrep", "pidof", "lsof", "ss", "netstat", "getent",
                     "cd", "ls", "last", "lxc-ls", "lxc-info", "dpkg-query"] {
            rules[name] = any
        }
        rules["tail"] = deny(short: "fF", long: ["--follow", "--retry"])
        // 递归 grep / diff 会把整棵目录的内容吐出来。家目录下就是 ~/.ssh，所以递归只给
        // 明确写出的系统目录（/etc、/var、/usr …）；不写路径（当前目录）、`/`、家目录都回到审批。
        rules["grep"] = { args in
            let recursive = !deny(short: "rR", long: ["--recursive", "--dereference-recursive"])(args)
            guard recursive else { return true }
            // 模式不能是什么都匹配的（`""`、`.`），也不能带上下文行（`-A 30` 能把整段私钥带出来）。
            let operands = operands(ofGrep: args)
            guard operands.count >= 2, !["", ".", "^", "$", ".*", "^.*"].contains(operands[0]),
                  !args.contains(where: { $0.range(of: "^-[ABC][0-9]*$|^--context", options: .regularExpression) != nil })
            else { return false }
            return operands.dropFirst().allSatisfy(isSystemPath)
        }
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
        rules["top"] = { args in
            args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("b") }
                && args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("n") }
        }
        for name in ["vmstat", "iostat", "mpstat"] { rules[name] = boundedSampling }
        rules["dmesg"] = deny(short: "cCDEnw", long: ["--clear", "--read-clear", "--console-off",
                                                       "--console-on", "--console-level", "--follow"])
        rules["journalctl"] = deny(short: "f", long: ["--follow", "--vacuum-size", "--vacuum-time", "--vacuum-files",
                                                      "--rotate", "--flush", "--sync", "--relinquish-var",
                                                      "--smart-relinquish-var", "--setup-keys", "--update-catalog"])
        rules["sysctl"] = { args in
            deny(short: "wp", long: ["--write", "--load", "--system"])(args) && !args.contains { $0.contains("=") }
        }
        rules["fuser"] = deny(short: "k", long: ["--kill"])
        rules["command"] = { args in args.count >= 2 && (args[0] == "-v" || args[0] == "-V") }
        rules["crontab"] = { $0 == ["-l"] || ($0.count == 3 && $0[0] == "-l" && $0[1] == "-u") }
        rules["ip"] = { args in
            let objects: Set<String> = ["addr", "address", "a", "route", "r", "link", "l", "neigh", "n", "rule", "maddr"]
            let operands = args.filter { !$0.hasPrefix("-") }
            guard let object = operands.first, objects.contains(object) else { return false }
            return operands.count == 1 || ["show", "list", "ls"].contains(operands[1])
        }
        rules["systemctl"] = subcommand(["status", "show", "cat", "list-units", "list-unit-files", "list-timers",
                                         "list-sockets", "list-dependencies", "is-active", "is-enabled", "is-failed",
                                         "is-system-running", "get-default"])
        rules["service"] = { $0 == ["--status-all"] || ($0.count == 2 && $0[1] == "status") }
        rules["timedatectl"] = { $0.isEmpty || $0 == ["status"] }
        rules["hostnamectl"] = { $0.isEmpty || $0 == ["status"] }
        // inspect / exec / compose config 会带出容器环境变量里的口令，不在这里。
        rules["docker"] = { args in
            let operands = args.filter { !$0.hasPrefix("-") }
            guard let first = operands.first else { return false }
            switch first {
            case "logs": return deny(short: "f", long: ["--follow"])(args)
            case "stats": return args.contains("--no-stream")
            case "ps", "images", "version", "info", "top", "port", "diff", "history": return true
            case "network", "volume", "container", "image", "context":
                return operands.count >= 2 && ["ls", "list"].contains(operands[1])
            case "compose":
                guard operands.count >= 2 else { return false }
                if operands[1] == "logs" { return deny(short: "f", long: ["--follow"])(args) }
                return ["ps", "ls", "images", "top", "version"].contains(operands[1])
            default: return false
            }
        }
        rules["kubectl"] = subcommand(["get", "describe", "logs", "top", "version", "explain", "api-resources",
                                       "api-versions", "cluster-info", "events"],
                                      valueFlags: ["-n", "--namespace", "--context", "--cluster", "-l", "--selector"],
                                      then: { _, rest in !rest.contains { ["-f", "--follow", "-w", "--watch"].contains($0) } })
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
        // 防火墙只认列出规则；改规则的选项一个都不在白名单里。
        let firewallList: Set<String> = ["-L", "-S", "-n", "-v", "-x", "--line-numbers", "--list", "--numeric",
                                         "--verbose", "--exact", "-nL", "-vnL", "-nvL", "-Ln", "-Lnv", "-vL"]
        rules["iptables"] = { args in
            var i = 0
            var listed = false
            while i < args.count {
                let arg = args[i]
                if arg == "-t" || arg == "--table" { i += 2; continue }
                if arg.hasPrefix("-") {
                    guard firewallList.contains(arg) else { return false }
                    if arg.contains("L") || arg.contains("S") || arg == "--list" { listed = true }
                }
                i += 1
            }
            return listed
        }
        rules["ip6tables"] = rules["iptables"]
        rules["nft"] = { args in args.first == "list" || (args.first.map { $0.hasPrefix("-") } == true && args.contains("list")) }
        rules["ufw"] = { $0 == ["status"] || $0 == ["status", "verbose"] || $0 == ["status", "numbered"] }
        rules["update-alternatives"] = { args in
            args.first.map { ["--display", "--query", "--list", "--get-selections"].contains($0) } ?? false
        }
        rules["apt-get"] = { args in
            args.contains { ["-s", "--simulate", "--dry-run", "--just-print", "--no-act", "--recon"].contains($0) }
                || args == ["check"]
        }
        for name in ["fold", "paste", "seq", "expand", "unexpand", "fmt", "strings", "hexdump", "xxd", "od"] {
            rules[name] = any
        }
        // 只问版本：解释器、编译器、包管理器带一个版本选项就什么都不执行。
        for name in ["php", "node", "npm", "npx", "yarn", "pnpm", "python", "python3", "java", "javac", "ruby",
                     "perl", "rustc", "cargo", "gcc", "g++", "clang", "make", "cmake", "go", "openssl", "mysqld",
                     "redis-server", "redis-cli", "caddy", "terraform", "helm", "composer"] {
            rules[name] = { args in
                args.count == 1 && ["--version", "-v", "-V", "version", "-version"].contains(args[0])
            }
        }
        rules["nginx"] = { !$0.isEmpty && $0.allSatisfy { ["-t", "-T", "-v", "-V"].contains($0) } }
        rules["apt"] = subcommand(["list", "show", "policy", "search"])
        rules["apt-cache"] = subcommand(["policy", "show", "search", "depends", "rdepends", "madison", "showpkg"])
        rules["apt-key"] = subcommand(["list"])
        rules["apt-mark"] = subcommand(["showmanual", "showauto", "showhold"])
        rules["dpkg"] = { args in
            guard let first = args.first else { return false }
            return ["-l", "-L", "-s", "-S", "--list", "--listfiles", "--status", "--search"].contains(first)
        }
        rules["rpm"] = { args in args.first.map { $0.hasPrefix("-q") } ?? false }
        rules["brew"] = subcommand(["list", "ls", "info", "outdated", "deps", "leaves", "config", "doctor"])
        for pip in ["pip", "pip3"] { rules[pip] = subcommand(["list", "show", "freeze"]) }
        rules["zfs"] = subcommand(["list", "get", "holds", "userspace", "groupspace", "projectspace", "diff"])
        rules["zpool"] = subcommand(["list", "status", "get", "history", "events"],
                                    then: { sub, rest in sub != "events" || !rest.contains("-f") })
        rules["virsh"] = subcommand(["list", "dominfo", "domstate", "domblklist", "domiflist", "domblkinfo",
                                     "pool-list", "pool-info", "vol-list", "vol-info", "net-list", "net-info",
                                     "nodeinfo", "version", "snapshot-list"],
                                    valueFlags: ["-c", "--connect"])
        rules["mysql"] = sqlClient(sqlFlags: ["-e", "--execute"], forbidden: ["-f", "--force", "--init-command"])
        rules["mariadb"] = rules["mysql"]
        rules["psql"] = sqlClient(sqlFlags: ["-c", "--command"], forbidden: ["-f", "--file", "-o", "--output", "-L"])
        rules["sqlite3"] = { args in
            let operands = args.filter { !$0.hasPrefix("-") }
            guard !args.contains(where: { ["-cmd", "-init"].contains($0) }),
                  operands.count == 2 else { return false }   // 没给 SQL 就是交互式
            return ReadOnlySQL.isReadOnly(operands[1])
        }
        rules["awk"] = awk
        rules["gawk"] = awk; rules["mawk"] = awk
        rules["sed"] = sed
        return rules
    }()

    /// grep 的操作数：去掉选项（以及 -e / -f / -m 等带值选项的值）后剩下的，第一个是模式。
    private static func operands(ofGrep args: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        let valued: Set<String> = ["-e", "-f", "-m", "-A", "-B", "-C", "--include", "--exclude", "--exclude-dir"]
        while i < args.count {
            let arg = args[i]
            if valued.contains(arg) { if arg == "-e" { result.append(args[safe: i + 1] ?? "") }; i += 2; continue }
            if !arg.hasPrefix("-") { result.append(arg) }
            i += 1
        }
        return result
    }

    /// 递归读内容可以放心的系统目录：绝对路径，且不是根、家目录、/tmp，
    /// 也不是 /proc、/sys（进程环境变量在里面）。
    private static func isSystemPath(_ path: String) -> Bool {
        let roots = ["/etc/", "/var/", "/usr/", "/opt/", "/srv/", "/boot/", "/lib/"]
        let normalized = path.hasSuffix("/") ? path : path + "/"
        return roots.contains { normalized.hasPrefix($0) } && !path.contains("..")
            && !normalized.hasPrefix("/var/tmp/")
    }

    /// `mysql -e '…'` / `psql -c '…'`：必须带一条 SQL（否则进交互），且 SQL 只读。
    private static func sqlClient(sqlFlags: Set<String>, forbidden: Set<String>) -> Rule {
        { args in
            var sql: [String] = []
            var i = 0
            while i < args.count {
                let arg = args[i]
                if forbidden.contains(arg) || forbidden.contains(where: { arg.hasPrefix($0 + "=") }) { return false }
                if sqlFlags.contains(arg), i + 1 < args.count {
                    sql.append(args[i + 1]); i += 2; continue
                }
                if let flag = sqlFlags.first(where: { arg.hasPrefix($0 + "=") }) {
                    sql.append(String(arg.dropFirst(flag.count + 1)))
                }
                i += 1
            }
            return !sql.isEmpty && sql.allSatisfy(ReadOnlySQL.isReadOnly)
        }
    }

    /// awk 的写出口只有 `system()`、`getline`、`print > 文件` / `print | 命令`；`-f` 读外部脚本、`-i` 原地改。
    private static let awk: Rule = { args in
        var i = 0
        var program: String?
        while i < args.count {
            let arg = args[i]
            if ["-F", "-v"].contains(arg) { i += 2; continue }
            if arg.hasPrefix("-F") || arg.hasPrefix("-v") { i += 1; continue }
            if arg.hasPrefix("-") { return false }   // -f / -i / -l / -E / --exec …
            program = arg; break
        }
        guard let program else { return false }
        if program.range(of: #"\bsystem\s*\(|\bgetline\b|\bclose\s*\(|\bfflush\b|@load|\bprintf?\b[^;{}]*[>|]"#,
                         options: .regularExpression) != nil { return false }
        return true
    }

    /// sed 只认打印 / 删除行 / 替换（替换标志不含 w、e）这几种脚本，不能 `-i` 原地改、不能 `-f` 读脚本。
    private static let sed: Rule = { args in
        var scripts: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "-e" || arg == "--expression" {
                guard i + 1 < args.count else { return false }
                scripts.append(args[i + 1]); i += 2; continue
            }
            if arg.hasPrefix("--") {
                guard ["--quiet", "--silent", "--regexp-extended", "--posix", "--debug"].contains(arg) else { return false }
            } else if arg.hasPrefix("-") {
                guard arg.dropFirst().allSatisfy({ "nEr".contains($0) }) else { return false }
            } else if scripts.isEmpty {
                scripts.append(arg)
            }
            i += 1
        }
        let address = #"(?:[0-9]+|\$|/[^/]*/)(?:,(?:[0-9]+|\$|/[^/]*/))?!?"#
        let simple = try? NSRegularExpression(pattern: "^(?:\(address))?[pdq=nNPDhHgGx]$")
        return !scripts.isEmpty && scripts.allSatisfy { script in
            script.split(whereSeparator: { $0 == ";" || $0 == "\n" }).allSatisfy { raw in
                let command = raw.trimmingCharacters(in: .whitespaces)
                let range = NSRange(command.startIndex..., in: command)
                if simple?.firstMatch(in: command, range: range) != nil { return true }
                return isPlainSubstitution(command, address: address)
            }
        }
    }

    /// `[地址]s/a/b/[gip数字]`：分隔符按出现的第一个字符算，标志里不许有 w（写文件）、e（执行）。
    private static func isPlainSubstitution(_ command: String, address: String) -> Bool {
        var body = Substring(command)
        if let r = command.range(of: "^\(address)", options: .regularExpression) { body = command[r.upperBound...] }
        guard body.first == "s", body.count >= 4 else { return false }
        let delimiter = body[body.index(after: body.startIndex)]
        guard !delimiter.isLetter, !delimiter.isNumber, delimiter != "\\" else { return false }
        let parts = body.dropFirst(2).split(separator: delimiter, omittingEmptySubsequences: false)
        guard parts.count == 3, !body.contains("\\") else { return false }
        return parts[2].allSatisfy { "gipI0123456789".contains($0) }
    }

    /// 带通配符、变量也不会吐出文件内容的命令。
    private static let globSafe: Set<String> = ["ls", "du", "stat", "file", "wc", "find", "tree", "echo", "printf",
                                                "md5sum", "sha1sum", "sha256sum", "sha512sum", "shasum",
                                                "md5", "cksum", "realpath", "readlink", "basename", "dirname",
                                                "test", "zfs", "zpool", "virsh", "systemctl", "docker", "kubectl",
                                                "dpkg", "dpkg-query", "pgrep", "pidof", "ps", "lsof", "fuser"]

    /// 文本里是否出现凭据、私钥、令牌、进程环境变量、shell 历史这类目标。
    /// `/etc/environment`、`Environment=`（systemd 单元）和公钥 `gpg.key` 不算。
    static func isSensitive(_ text: String) -> Bool {
        let lower = text.lowercased()
            .replacingOccurrences(of: "environment", with: "")
            .replacingOccurrences(of: "gpg.key", with: "")
        return sensitive.contains { lower.contains($0) }
    }

    private static let sensitive = [".ssh", ".aws", ".azure", ".gnupg", ".kube", ".docker/config", ".netrc",
                            ".pgpass", ".my.cnf", ".git-credentials", ".env", "id_rsa", "id_dsa",
                            "id_ecdsa", "id_ed25519", ".pem", ".key", ".p12", ".pfx", ".jks",
                            ".keystore", "shadow", "sudoers", "password", "secret", "credential",
                            "token", "keychain", "environ", ".bash_history", ".zsh_history", "fish_history",
                            ".mysql_history", ".psql_history", ".python_history", ".sqlite_history",
                            ".node_repl_history"]
}

/// 命令行里交给数据库客户端的 SQL 是否只读。只认 SELECT / SHOW / DESCRIBE / EXPLAIN（不带 ANALYZE）
/// 和 psql 的 `\d` 系列、sqlite3 的 `.tables` 这类元命令；有副作用的函数、`INTO` 一律判否。
enum ReadOnlySQL {
    static func isReadOnly(_ sql: String) -> Bool {
        let statements = sql.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !statements.isEmpty && statements.allSatisfy(isReadOnlyStatement)
    }

    private static func isReadOnlyStatement(_ statement: String) -> Bool {
        let lower = statement.lowercased()
        if lower.hasPrefix("\\") {
            return lower.range(of: #"^\\(d[a-z]*\+?|l\+?|conninfo)(\s|$)"#, options: .regularExpression) != nil
        }
        if lower.hasPrefix(".") {
            return lower.range(of: #"^\.(tables|schema|indexes|indices|databases|dbinfo)(\s|$)"#,
                               options: .regularExpression) != nil
        }
        guard let first = lower.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first,
              ["select", "show", "describe", "desc", "explain"].contains(first) else { return false }
        if first == "explain", lower.contains("analyze") { return false }
        let effects = [" into ", "for update", "pg_terminate", "pg_cancel", "pg_reload", "pg_rotate", "pg_read",
                       "pg_ls_dir", "pg_write", "lo_import", "lo_export", "nextval", "setval", "set_config",
                       "dblink", "load_file", "sleep(", "benchmark(", "sys_exec", "sys_eval", "copy "]
        return !effects.contains { lower.contains($0) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
