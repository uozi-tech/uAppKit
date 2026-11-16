#!/bin/sh
# Xcode Run Script「Embed Background Login Item」的模板（uAppKit/Tools/xcode）。各 app vendor 到
# scripts/build-phases/，pbxproj 的 shellScript 只调它：
#
#     /bin/sh "${SRCROOT}/scripts/build-phases/embed-login-item.sh" uTableBackgroundLauncher
#
# 把同一次构建产出的 <LAUNCHER>.app 拷进主 app 的 Contents/Library/LoginItems/（SMAppService.loginItem
# 只认这个位置）。读 Xcode 给的 BUILT_PRODUCTS_DIR / TARGET_BUILD_DIR / CONTENTS_FOLDER_PATH。
# launcher target 要列在主 app 的 Target Dependencies 里，否则这里可能拷到旧的。
set -eu
if [ "$#" -ne 1 ]; then
  echo "usage: embed-login-item.sh LAUNCHER" >&2
  exit 64
fi
source_app="${BUILT_PRODUCTS_DIR}/$1.app"
destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LoginItems/$1.app"
/bin/mkdir -p "$(dirname "$destination")"
/usr/bin/ditto "$source_app" "$destination"
