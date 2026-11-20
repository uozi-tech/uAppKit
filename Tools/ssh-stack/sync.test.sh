#!/bin/bash
# sync.sh 的离线自测：假上游（本地 git 仓库）+ 假仓库根，不联网、不碰真实 Sources/。
set -euo pipefail
SYNC="$(cd "$(dirname "$0")" && pwd)/sync.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false)
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# 假上游：v1 一个文件；v2 在前面插两行（补丁要能靠上下文挪位）；v3 改掉补丁要改的那行（冲突）。
UP="$T/upstream"; mkdir -p "$UP/Sources/Foo" "$UP/Sources/Other"
"${G[@]}" init -q -b main "$UP"
printf 'line1\nline2\ntarget = old\nline4\n' > "$UP/Sources/Foo/a.swift"
echo keep > "$UP/Sources/Other/x.txt"
"${G[@]}" -C "$UP" add -A; "${G[@]}" -C "$UP" commit -qm v1; V1=$(git -C "$UP" rev-parse HEAD)
printf 'new0\nnew1\nline1\nline2\ntarget = old\nline4\n' > "$UP/Sources/Foo/a.swift"
"${G[@]}" -C "$UP" commit -qam v2; V2=$(git -C "$UP" rev-parse HEAD)
printf 'new0\nnew1\nline1\nline2\ntarget = upstream\nline4\n' > "$UP/Sources/Foo/a.swift"
"${G[@]}" -C "$UP" commit -qam v3; V3=$(git -C "$UP" rev-parse HEAD)

# 假仓库根：UPSTREAM 指 v1，一个把 old 改成 patched 的补丁。
R="$T/root"; mkdir -p "$R/ThirdParty/Foo/patches"
write_upstream() { printf 'URL=%s\nTAG=%s\nREV=%s\nPATHS="Sources/Foo"\n' "$UP" "$1" "$2" > "$R/ThirdParty/Foo/UPSTREAM"; }
write_upstream v1 "$V1"
P="$T/mkpatch"; "${G[@]}" init -q -b main "$P"; mkdir -p "$P/Sources"
git -C "$UP" archive "$V1" Sources/Foo | tar -x -C "$P"
"${G[@]}" -C "$P" add -A; "${G[@]}" -C "$P" commit -qm base
sed -i '' 's/target = old/target = patched/' "$P/Sources/Foo/a.swift"
"${G[@]}" -C "$P" commit -qam "Foo: patch target"
git -C "$P" format-patch -q --zero-commit --no-signature -o "$R/ThirdParty/Foo/patches" HEAD~1..HEAD
export SSH_STACK_ROOT="$R"

"$SYNC" apply >/dev/null
grep -q 'target = patched' "$R/Sources/Foo/a.swift" || fail "apply 没打上补丁"
[ ! -e "$R/Sources/Other" ] || fail "apply 拷了 PATHS 之外的东西"
pass "apply：上游 + 补丁生成 Sources/"

"$SYNC" check >/dev/null || fail "刚 apply 完 check 应该通过"
pass "check：一致时退出 0"

echo 'hand edit' >> "$R/Sources/Foo/a.swift"
if "$SYNC" check >/dev/null 2>&1; then fail "直接改 Sources/ 后 check 应该失败"; fi
pass "check：直接改 Sources/ 被拦下"

write_upstream v2 "$V2"
"$SYNC" apply >/dev/null
[ "$(head -1 "$R/Sources/Foo/a.swift")" = new0 ] || fail "升级到 v2 没拿到上游新内容"
grep -q 'target = patched' "$R/Sources/Foo/a.swift" || fail "升级到 v2 补丁丢了"
grep -q '^@@ -2,5 ' "$R/ThirdParty/Foo/patches/"*.patch || fail "补丁没按新上下文重新导出"
"$SYNC" check >/dev/null || fail "升级到 v2 后 check 应该通过"
pass "apply：升级上游，补丁按新上下文重新导出"

write_upstream v3 "$V3"
before=$(cat "$R/Sources/Foo/a.swift")
if "$SYNC" apply >/dev/null 2>&1; then fail "v3 冲突时 apply 应该失败"; fi
[ "$(cat "$R/Sources/Foo/a.swift")" = "$before" ] || fail "冲突时不该动 Sources/"
pass "apply：补丁冲突时停下、不动 Sources/"

if "$SYNC" finish Foo >/dev/null 2>&1; then fail "am 没打完时 finish 应该拒绝"; fi
WR="$R/.build/ssh-stack/Foo/repo"
printf 'new0\nnew1\nline1\nline2\ntarget = patched\nline4\n' > "$WR/Sources/Foo/a.swift"
"${G[@]}" -C "$WR" add -A; GIT_EDITOR=true "${G[@]}" -C "$WR" am --continue >/dev/null
"$SYNC" finish Foo >/dev/null
grep -q 'target = patched' "$R/Sources/Foo/a.swift" || fail "finish 没把解决后的结果拷回"
"$SYNC" check >/dev/null || fail "finish 后 check 应该通过"
pass "finish：手工解决冲突后收尾"

echo "全部通过"
