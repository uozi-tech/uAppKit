#!/bin/sh
# Xcode Run Script「Copy <ctl> CLI and Skills」的模板（uAppKit/Tools/xcode）。各 app vendor 到
# scripts/build-phases/，pbxproj 的 shellScript 只调它：
#
#     /bin/sh "${SRCROOT}/scripts/build-phases/copy-cli-and-skills.sh" utablectl utable
#     /bin/sh "${SRCROOT}/scripts/build-phases/copy-cli-and-skills.sh" utermctl uterm --resources-copy
#
# 参数：CTL（scripts/<CTL> 是客户端脚本）、SLUG（客户端进 Skills/<SLUG>/bin/<CTL>）、
# 可选 --resources-copy（另拷一份到 Contents/Resources/<CTL>，给 ~/.local/bin/<CTL> 链接用）。
# 读 Xcode 给的 SRCROOT / TARGET_BUILD_DIR / UNLOCALIZED_RESOURCES_FOLDER_PATH。
#
# 产物与两个 app 原先内联在 pbxproj 里的脚本逐字节相同：skills/<slug>/ 下全部 *.md 以 644 拷进
# Resources/Skills/<slug>/，客户端以 755 拷进 bin/，仓库里已经删掉的技能和文档从包里删掉。
set -e
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || { [ "$#" -eq 3 ] && [ "$3" != "--resources-copy" ]; }; then
  echo "usage: copy-cli-and-skills.sh CTL SLUG [--resources-copy]" >&2
  exit 64
fi
ctl="$1"
slug="$2"
res="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
# Copy only when content differs, so incremental builds do not re-sign unchanged resources.
put() {
  mkdir -p "$(dirname "$2")"
  cmp -s "$1" "$2" || /bin/cp -f "$1" "$2"
  /bin/chmod "$3" "$2"
}
# ~/.local/bin/<ctl> links here.
if [ "${3:-}" = "--resources-copy" ]; then
  put "${SRCROOT}/scripts/$ctl" "$res/$ctl" 755
fi
# ~/.<tool>/skills/<slug> links straight into Resources/Skills/<slug>: files the sandboxed app writes
# into its container are unreadable to other apps on macOS 27+ (and scripts it writes are quarantined),
# the signed bundle is neither.
for dir in "${SRCROOT}"/skills/*/; do
  for doc in $(cd "$dir" && find . -type f -name '*.md'); do
    put "$dir${doc#./}" "$res/Skills/$(basename "$dir")/${doc#./}" 644
  done
done
put "${SRCROOT}/scripts/$ctl" "$res/Skills/$slug/bin/$ctl" 755
# Drop skills and documents that no longer exist in the repository.
for dir in "$res"/Skills/*/; do
  [ -d "$dir" ] || continue
  src="${SRCROOT}/skills/$(basename "$dir")/"
  [ -d "$src" ] || { rm -rf "$dir"; continue; }
  for doc in $(cd "$dir" && find . -type f -name '*.md'); do
    [ -f "$src${doc#./}" ] || rm -f "$dir${doc#./}"
  done
done
