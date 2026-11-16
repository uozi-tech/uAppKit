#!/bin/sh
# build phase 模板的离线自测：`sh Tools/xcode/build-phases.test.sh`。造一个假 SRCROOT 与假产物目录，
# 核拷贝、权限、cmp 后不重拷、删掉仓库里没了的技能与文档、--resources-copy、embed-login-item。
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
check() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }

src="$work/src"
mkdir -p "$src/scripts" "$src/skills/demo/references"
printf '#!/bin/sh\necho demo\n' > "$src/scripts/democtl"
printf -- '---\nname: demo\n---\n' > "$src/skills/demo/SKILL.md"
printf 'ref\n' > "$src/skills/demo/references/a.md"
build="$work/build"
mkdir -p "$build/Res/Skills/gone/" "$build/Res/Skills/demo/references"
printf 'x\n' > "$build/Res/Skills/gone/SKILL.md"
printf 'x\n' > "$build/Res/Skills/demo/references/removed.md"

run() { env SRCROOT="$src" TARGET_BUILD_DIR="$build" UNLOCALIZED_RESOURCES_FOLDER_PATH=Res /bin/sh "$here/copy-cli-and-skills.sh" "$@"; }
run democtl demo
res="$build/Res"
check 'cmp -s "$src/skills/demo/SKILL.md" "$res/Skills/demo/SKILL.md"' "SKILL.md 拷进包"
check 'cmp -s "$src/skills/demo/references/a.md" "$res/Skills/demo/references/a.md"' "references 递归拷"
check '[ "$(stat -f %Lp "$res/Skills/demo/SKILL.md")" = 644 ]' "文档 644"
check '[ "$(stat -f %Lp "$res/Skills/demo/bin/democtl")" = 755 ] && cmp -s "$src/scripts/democtl" "$res/Skills/demo/bin/democtl"' "客户端 755 进 bin/"
check '[ ! -e "$res/democtl" ]' "不带 --resources-copy 时不拷 Resources/<ctl>"
check '[ ! -e "$res/Skills/gone" ]' "仓库里没了的技能从包里删掉"
check '[ ! -e "$res/Skills/demo/references/removed.md" ]' "仓库里没了的文档从包里删掉"
touch -t 200001010000 "$res/Skills/demo/SKILL.md"
before="$(stat -f %m "$res/Skills/demo/SKILL.md")"
run democtl demo --resources-copy
check '[ "$(stat -f %m "$res/Skills/demo/SKILL.md")" = "$before" ]' "内容没变不重拷（不动 mtime，免得重签）"
check '[ "$(stat -f %Lp "$res/democtl")" = 755 ]' "--resources-copy 拷到 Resources/<ctl>"
check '! run democtl 2>/dev/null' "缺参数时报用法"
check '! run democtl demo --bogus 2>/dev/null' "未知选项时报用法"

mkdir -p "$work/products/DemoLauncher.app/Contents/MacOS"
printf 'bin\n' > "$work/products/DemoLauncher.app/Contents/MacOS/DemoLauncher"
env BUILT_PRODUCTS_DIR="$work/products" TARGET_BUILD_DIR="$work/target" CONTENTS_FOLDER_PATH=Demo.app/Contents \
  /bin/sh "$here/embed-login-item.sh" DemoLauncher
check 'cmp -s "$work/products/DemoLauncher.app/Contents/MacOS/DemoLauncher" "$work/target/Demo.app/Contents/Library/LoginItems/DemoLauncher.app/Contents/MacOS/DemoLauncher"' "launcher 进 Contents/Library/LoginItems/"

[ "$fail" = 0 ] && echo "build phase 模板自测全部通过"
exit "$fail"
