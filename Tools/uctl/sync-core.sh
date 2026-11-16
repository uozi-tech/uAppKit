#!/bin/sh
# 把 canonical 的 uctl 公共区（同目录 uctl_core.py 里 `# BEGIN uctl-core <ver>` 到 `# END uctl-core`
# 那一段）原样回写进一个 app 的命令行客户端：
#
#     <workspace>/uAppKit/Tools/uctl/sync-core.sh scripts/utablectl
#     <workspace>/uAppKit/Tools/uctl/sync-core.sh --check scripts/utablectl   # 只核不写，不一致退出 1
#
# 目标文件里必须恰好有一对标记（第一次接入时手工放一对空标记）；区外的内容一个字节都不动，
# 文件权限保持不变。回写后记得跑 app 自己的客户端自测与「包内 ctl 与仓库逐字节一致」的测试。
set -eu
check=no
if [ "${1:-}" = "--check" ]; then
  check=yes
  shift
fi
if [ "$#" -ne 1 ]; then
  echo "usage: sync-core.sh [--check] CTL_FILE" >&2
  exit 64
fi
core="$(cd "$(dirname "$0")" && pwd)/uctl_core.py"
exec /usr/bin/python3 -I - "$core" "$1" "$check" <<'PY'
import os
import sys

core_path, target_path, check = sys.argv[1], sys.argv[2], sys.argv[3] == "yes"
BEGIN, END = "# BEGIN uctl-core", "# END uctl-core"


def region(lines, path):
    begins = [i for i, line in enumerate(lines) if line.startswith(BEGIN)]
    ends = [i for i, line in enumerate(lines) if line.rstrip("\n") == END]
    if len(begins) != 1 or len(ends) != 1 or ends[0] < begins[0]:
        sys.exit("%s: 需要恰好一对 `%s <ver>` / `%s` 标记（找到 %d 个开始、%d 个结束）"
                 % (path, BEGIN, END, len(begins), len(ends)))
    return begins[0], ends[0]


with open(core_path, encoding="utf-8") as handle:
    core = handle.readlines()
start, stop = region(core, core_path)
block = core[start:stop + 1]

with open(target_path, encoding="utf-8") as handle:
    target = handle.readlines()
start, stop = region(target, target_path)
updated = target[:start] + block + target[stop + 1:]

if updated == target:
    print("%s: 公共区已是最新（%s）" % (target_path, block[0].strip()))
    sys.exit(0)
if check:
    print("%s: 公共区与 uctl_core.py 不一致，运行 sync-core.sh 回写" % target_path)
    sys.exit(1)
mode = os.stat(target_path).st_mode
with open(target_path, "w", encoding="utf-8") as handle:
    handle.writelines(updated)
os.chmod(target_path, mode)
print("%s: 公共区已更新为 %s" % (target_path, block[0].strip()))
PY
