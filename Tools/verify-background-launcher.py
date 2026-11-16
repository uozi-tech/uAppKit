#!/usr/bin/env python3
"""Reject signed distribution apps whose login helper cannot be registered by SMAppService.

uAppKit 模板（Tools/verify-background-launcher.py），各 app vendor 到 scripts/ 下，发版导出后跑：

    python3 scripts/verify-background-launcher.py build/export/uTable.app uTableBackgroundLauncher

核两条：<APP>/Contents/Library/LoginItems/<LAUNCHER>.app 的签名能过 `codesign --verify --strict`；
它带 `com.apple.security.app-sandbox = true`（SMAppService 拒绝注册不带沙盒的 helper，表现是
登录项永远「未找到」）。
"""
import plistlib
import subprocess
import sys
from pathlib import Path


def verify(app_path, launcher_name):
    helper = Path(app_path) / "Contents/Library/LoginItems" / (launcher_name + ".app")
    if not helper.is_dir():
        raise ValueError("Missing background launcher: " + str(helper))
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(helper)], check=True)
    result = subprocess.run(
        ["/usr/bin/codesign", "--display", "--entitlements", ":-", str(helper)],
        check=True, capture_output=True,
    )
    entitlements = plistlib.loads(result.stdout)
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise ValueError("Background launcher must be sandboxed for SMAppService registration: " + str(helper))
    print("Background launcher signature and sandbox entitlement verified: " + str(helper))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: verify-background-launcher.py APP_PATH LAUNCHER_NAME")
    try:
        verify(sys.argv[1], sys.argv[2])
    except (OSError, ValueError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        sys.exit("ERROR: " + str(error))
