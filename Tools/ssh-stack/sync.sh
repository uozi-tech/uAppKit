#!/bin/bash
# 把 ThirdParty/<组件>/ 记的上游源码 + patches/ 重放成 Sources/ 下的 target。
#
#   sync.sh check  [组件…]   核对 Sources/ == 上游 REV + 补丁（不写任何东西；不一致非零退出）
#   sync.sh apply  [组件…]   按 UPSTREAM 重新生成 Sources/ 下的源码，并把补丁按新上下文重新导出
#   sync.sh finish  组件     apply 中途补丁冲突、在工作区里解决完之后，收尾（拷回源码 + 重新导出补丁）
#
# 不写组件名 = ThirdParty/ 下所有带 UPSTREAM 的组件。工作区在 .build/ssh-stack/<组件>（已被 .gitignore）。
# 环境变量：SSH_STACK_ROOT 改仓库根（自测用）；SSH_STACK_CACHE 指向已有的上游 clone 目录
# （<cache>/<组件>），设了就不联网。
set -euo pipefail

ROOT="${SSH_STACK_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
WORK_ROOT="$ROOT/.build/ssh-stack"
GITQ=(git -c user.name=ssh-stack -c user.email=ssh-stack@localhost -c core.autocrlf=false -c commit.gpgsign=false)

die() { echo "sync.sh: $*" >&2; exit 1; }

components() {
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; return; fi
  for f in "$ROOT"/ThirdParty/*/UPSTREAM; do basename "$(dirname "$f")"; done
}

load() { # 读 UPSTREAM 到 URL / TAG / REV / PATHS
  local file="$ROOT/ThirdParty/$1/UPSTREAM"
  [ -f "$file" ] || die "没有 $file"
  URL= TAG= REV= PATHS=
  # shellcheck disable=SC1090
  . "$file"
  [ -n "$URL" ] && [ -n "$REV" ] && [ -n "$PATHS" ] || die "$file 缺 URL / REV / PATHS"
}

fetch() { # $1 组件 $2 目标目录：放一份上游 REV 的检出
  local name="$1" dest="$2"
  if [ -n "${SSH_STACK_CACHE:-}" ]; then
    git clone -q --no-checkout "$SSH_STACK_CACHE/$name" "$dest"
  else
    # 完整 clone（不用 --filter）：升级时 git am --3way 要从上游历史里找到补丁的原像 blob。
    git clone -q --no-checkout "$URL" "$dest"
  fi
  git -C "$dest" -c advice.detachedHead=false checkout -q "$REV" || die "$name: 上游没有 $REV"
}

# 在 $WORK/repo 里建「基线一笔 + 补丁逐笔」的仓库。成功返回 0，补丁冲突返回 1（留在 am 中途）。
build_work() {
  local name="$1" work="$WORK_ROOT/$1"
  rm -rf "$work"; mkdir -p "$work"
  fetch "$name" "$work/upstream"
  "${GITQ[@]}" init -q -b main "$work/repo"
  # 借上游的对象库：补丁 index 行记的是旧基线的 blob，3-way 合并要靠它们。
  echo "$work/upstream/.git/objects" > "$work/repo/.git/objects/info/alternates"
  local p
  for p in $PATHS; do
    [ -e "$work/upstream/$p" ] || die "$name: 上游 $REV 里没有 $p"
    mkdir -p "$work/repo/$(dirname "$p")"
    cp -R "$work/upstream/$p" "$work/repo/$p"
  done
  "${GITQ[@]}" -C "$work/repo" add -A
  "${GITQ[@]}" -C "$work/repo" commit -q -m "upstream $name ${TAG:-} ($REV)"
  local patches=("$ROOT/ThirdParty/$name/patches/"*.patch)
  [ -e "${patches[0]}" ] || return 0
  "${GITQ[@]}" -C "$work/repo" am -q --3way --keep-cr "${patches[@]}" || return 1
}

export_back() { # 把工作区的结果拷回 Sources/，补丁按新上下文重新导出
  local name="$1" work="$WORK_ROOT/$1" p
  for p in $PATHS; do
    rm -rf "${ROOT:?}/$p"; mkdir -p "$ROOT/$(dirname "$p")"
    cp -R "$work/repo/$p" "$ROOT/$p"
  done
  local out="$ROOT/ThirdParty/$name/patches"
  rm -f "$out"/*.patch; mkdir -p "$out"
  local base; base=$(git -C "$work/repo" rev-list --max-parents=0 HEAD)
  git -C "$work/repo" format-patch -q --zero-commit --no-signature -o "$out" "$base..HEAD"
  echo "$name: Sources/ 已按 ${TAG:-$REV} 重新生成，补丁 $(ls "$out" | wc -l | tr -d ' ') 个"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  check)
    status=0
    while read -r name; do
      load "$name"; ok=1
      if ! build_work "$name" >/dev/null; then
        echo "$name: 补丁在 $REV 上打不上" >&2; status=1; continue
      fi
      for p in $PATHS; do
        if ! diff -r "$WORK_ROOT/$name/repo/$p" "$ROOT/$p" >/dev/null; then
          echo "$name: $p 与「上游 + 补丁」不一致（直接改了 Sources/？改动要写成补丁）：" >&2
          diff -rq "$WORK_ROOT/$name/repo/$p" "$ROOT/$p" | sed "s#$WORK_ROOT/$name/repo/##; s#$ROOT/##" >&2 || true
          status=1; ok=0
        fi
      done
      [ $ok -eq 1 ] && echo "$name: 一致（${TAG:-} $REV + $(ls "$ROOT/ThirdParty/$name/patches" | wc -l | tr -d ' ') 个补丁）"
      rm -rf "${WORK_ROOT:?}/$name"
    done < <(components "$@")
    exit $status
    ;;
  apply)
    while read -r name; do
      load "$name"
      if ! build_work "$name"; then
        cat >&2 <<MSG
$name: 补丁冲突，停在 git am 中途。Sources/ 没动。
  cd "$WORK_ROOT/$name/repo"   # 解决冲突，git add，git am --continue（直到打完）
  然后：Tools/ssh-stack/sync.sh finish $name
MSG
        exit 1
      fi
      export_back "$name"
    done < <(components "$@")
    ;;
  finish)
    [ $# -eq 1 ] || die "用法：sync.sh finish <组件>"
    load "$1"
    [ -d "$WORK_ROOT/$1/repo/.git/rebase-apply" ] && die "$1: git am 还没打完"
    export_back "$1"
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
