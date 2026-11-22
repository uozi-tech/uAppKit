import Foundation

/// 「AI 代批」档的硬规则：命中的命令不管 AI 怎么说都交给人。
///
/// 这是黑名单，挡的是一旦做错就收不回来的几类：销毁数据、关机、改安全配置与账户、
/// 碰凭据、把数据往外发、执行远程脚本。没命中的才交给独立 AI 审查——它是第二道关。
///
/// 两种视图各管一类：危险词按「去掉引号和反斜杠」后的文本整词匹配，`r''m`、`\rm` 这类
/// 拆写也逃不掉（`echo "rm"` 这种误伤只是多问一次）；管道、命令位置、选项这类结构
/// 按「引号里的内容抹成空格」后的文本匹配，免得 `grep 'a|python3'` 里的 `|` 被当成管道。
enum ManualOnlyCommand {
    static func reason(for command: String) -> String? {
        guard command.utf8.count <= 4096 else { return String(localized: "命令过长，请人工确认", bundle: ModuleBundle.bundle) }
        let unquoted = command.filter { $0 != "'" && $0 != "\"" && $0 != "\\" }
        let flat = unquoted.lowercased()
        let bare = blankingQuotes(command)
        if flat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "空命令", bundle: ModuleBundle.bundle) }
        let words = Set(flat.split(whereSeparator: { " \t\n;|&()<>{}`$=".contains($0) }).map(String.init))
        func has(_ pattern: String) -> Bool { flat.range(of: pattern, options: .regularExpression) != nil }
        /// 结构匹配：引号内容已抹掉、保留大小写。
        func shape(_ pattern: String) -> Bool { bare.range(of: pattern, options: .regularExpression) != nil }
        let commandStart = #"(^|[;&|\n(]\s*)"#

        if command.contains("`") { return String(localized: "反引号命令替换需要人工确认", bundle: ModuleBundle.bundle) }
        if ReadOnlyShellCommand.isSensitive(flat) {
            return String(localized: "涉及凭据、私钥或敏感文件，请人工确认", bundle: ModuleBundle.bundle)
        }
        if !words.isDisjoint(with: ["dd", "fdisk", "sfdisk", "parted", "wipefs", "shred", "mkswap", "blkdiscard",
                                    "truncate", "lvremove", "vgremove", "pvremove"])
            || words.contains(where: { $0.hasPrefix("mkfs") })
            || has(#"\bz(fs|pool)\s+(destroy|rollback|labelclear)\b"#) {
            return String(localized: "可能销毁磁盘或数据集上的数据，请人工确认", bundle: ModuleBundle.bundle)
        }
        if let reason = removalReason(flat) { return reason }
        if has(#"\bdocker\s+(system\s+prune|volume\s+(rm|prune)|rm\b|container\s+(rm|prune))"#)
            || has(#"\bkubectl\s+delete\b"#)
            || has(#"\bgit\s+(push\s+.*(-f\b|--force)|reset\s+--hard|clean\s+-[a-z]*f)"#) {
            return String(localized: "删除容器、资源或改写版本历史，请人工确认", bundle: ModuleBundle.bundle)
        }
        if !words.isDisjoint(with: ["reboot", "shutdown", "poweroff", "halt"])
            || has(#"\binit\s+[06]\b"#) || has(#"\bsystemctl\s+(reboot|poweroff|halt|kexec)\b"#)
            || has(#"\bkill\s+(-[a-z0-9]+\s+)*-?1\b"#) {
            return String(localized: "关机、重启或结束系统进程，请人工确认", bundle: ModuleBundle.bundle)
        }
        // 防火墙只拦改规则的写法，`iptables -L`、`ufw status` 这种查看交给后面。
        if shape(#"\bip6?tables(-legacy|-nft)?\b[^;&|\n]*\s(-[AIDFXPRNZE]\b|--(append|insert|delete|flush|delete-chain|policy|replace|new-chain|zero|rename-chain)\b)"#)
            || shape(#"\bnft\s+(-f\b|add|delete|flush|replace|create|insert|destroy)\b"#)
            || shape(#"\bufw\s+(allow|deny|reject|limit|delete|disable|enable|reset|default|insert|route)\b"#)
            || shape(#"\bfirewall-cmd\b.*--(add|remove|set|reload|complete-reload|permanent|runtime-to-permanent|change|panic)"#)
            || !words.isDisjoint(with: ["useradd", "userdel", "usermod", "groupadd", "groupdel", "passwd",
                                        "chpasswd", "visudo", "setfacl"])
            || has(#"\bch(mod|own|grp)\s+(-[a-z]*r|--recursive)"#) || has(#"\bchmod\s+[0-7]?777\b"#)
            || has(#"authorized_keys|/etc/ssh/|sshd_config|/etc/passwd|/etc/group\b|/etc/pam\.d"#)
            || has(#"\bsystemctl\s+(stop|disable|mask)\s+(ssh|sshd|networking|network-manager|systemd-networkd)\b"#)
            || has(#"\bcrontab\s+-[a-z]*[er]"#) {
            return String(localized: "改防火墙、账户、权限或登录配置，请人工确认", bundle: ModuleBundle.bundle)
        }
        // 内联脚本（`bash -c '…'`、`python3 -c '…'`）本身交给 AI 看；
        // 这里只拦看不见内容的执行：管道喂给解释器、source 外部文件、eval / exec、解码后执行。
        // 管道喂给解释器只在解释器从 stdin 读代码时危险（`| bash`、`| bash -s`、`| python3 -`）；
        // `| python3 -c '…'` 是把数据喂给看得见的代码，交给 AI。
        let interpreter = #"\|\s*(sudo\s+(-\S+\s+)*)?(sh|bash|zsh|dash|ksh|python3?|perl|ruby|node|php)"#
        let readsCode = #"(\s+-s?(\s|$)|\s*$|\s*[;&|)\n])"#
        let sourced = bare.replacingOccurrences(of: #"(source|\.)\s+/etc/(os|lsb)-release\b"#, with: ":",
                                                options: .regularExpression)
        if shape(interpreter + readsCode)
            || has(#"\b(curl|wget)\b[^;&]*\|\s*(sudo\s+)?(sh|bash|zsh|dash|python3?|perl|ruby|node)(\s+-s?(\s|$)|\s*$|\s*[;&|)])"#)
            || sourced.range(of: commandStart + #"(source|\.|eval|exec)\s+\S"#, options: .regularExpression) != nil
            || has(#"base64\s+(-d|--decode)"#) {
            return String(localized: "执行看不到内容的脚本，请人工确认", bundle: ModuleBundle.bundle)
        }
        if has(#"\b(shutil\.rmtree|os\.remove|os\.unlink|os\.rmdir|os\.system|subprocess|child_process|fs\.rm|unlinksync|rmsync)"#) {
            return String(localized: "内联脚本里有删除文件或执行命令的调用，请人工确认", bundle: ModuleBundle.bundle)
        }
        // curl 的选项分大小写（`-f` 是 --fail，`-F` 才是表单上传），这条按原样匹配。
        if unquoted.range(of: #"\bcurl\b.*\s(-[a-zA-Z]*[dFT]|--data[a-z-]*|--form[a-z-]*|--upload-file|-X\s*(POST|PUT|DELETE|PATCH))\b"#,
                          options: .regularExpression) != nil
            || has(#"\bwget\b.*--(post|body)-(data|file)"#)
            || !words.isDisjoint(with: ["scp", "sftp", "ftp", "nc", "ncat", "socat", "telnet"])
            || has(#"\brsync\b.*\S+:"#) {
            return String(localized: "可能把本机数据发到外部，请人工确认", bundle: ModuleBundle.bundle)
        }
        if has(#"\bdrop\s+(table|database|schema|user|role|index|view)\b"#) || has(#"\btruncate\s+table\b"#)
            || has(#"\bdelete\s+from\b"#) || has(#"\b(alter\s+user|grant|revoke)\s"#)
            || !words.isDisjoint(with: ["flushall", "flushdb"]) {
            return String(localized: "删除数据库对象或改数据库权限，请人工确认", bundle: ModuleBundle.bundle)
        }
        return nil
    }

    /// 引号里的内容抹成空格，其余原样（保留大小写）。
    private static func blankingQuotes(_ command: String) -> String {
        var out = ""
        var quote: Character?
        for c in command {
            if let q = quote {
                if c == q { quote = nil; out.append(" ") } else { out.append(c == "\n" ? "\n" : " ") }
            } else if c == "'" || c == "\"" {
                quote = c; out.append(" ")
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// `rm` 只放过临时目录下的单个文件：带递归 / 强制选项，或路径不在 /tmp、/var/tmp 下的都交给人。
    private static func removalReason(_ flat: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(^|[\s;&|(])(rm|rmdir|unlink)\s+([^;&|\n]*)"#)
        else { return nil }
        let range = NSRange(flat.startIndex..., in: flat)
        for match in regex.matches(in: flat, range: range) {
            guard let r = Range(match.range(at: 3), in: flat) else { continue }
            let args = flat[r].split(whereSeparator: \.isWhitespace).map(String.init)
            let flags = args.filter { $0.hasPrefix("-") }
            let paths = args.filter { !$0.hasPrefix("-") && !$0.hasPrefix("2>") }
            let recursive = flags.contains { $0 == "--recursive" || (!$0.hasPrefix("--") && $0.contains("r")) }
            let tempOnly = !paths.isEmpty && paths.allSatisfy {
                ($0.hasPrefix("/tmp/") || $0.hasPrefix("/var/tmp/")) && !$0.contains("..") && !$0.contains("*")
            }
            if recursive || !tempOnly { return String(localized: "删除文件需要人工确认", bundle: ModuleBundle.bundle) }
        }
        return nil
    }
}
