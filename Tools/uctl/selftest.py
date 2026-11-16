#!/usr/bin/env python3
"""uctl 公共区的离线自测：`python3 Tools/uctl/selftest.py`。

不连任何 app：在临时目录里起 AF_UNIX 服务端模拟心跳 / 进度 / 静默 / 断开，核逐行协议、静默超时、
退出码表、退避重试、socket 候选路径、`socket_path_too_long` 判定、「结果不明不重放」，以及
`sync-core.sh` 的回写与 `--check`。
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.join(HERE, "uctl_core.py")
failures = []


def check(condition, label):
    print(("ok   " if condition else "FAIL ") + label)
    if not condition:
        failures.append(label)


def load_core(**overrides):
    """像 vendor 进 ctl 那样：先定义 app 常量，再执行公共区。"""
    namespace = {
        "__name__": "uctl_under_test",
        "__file__": os.path.join(tempfile.gettempdir(), "democtl"),
        "APP_NAME": "Demo",
        "CTL_NAME": "democtl",
        "BUNDLE_ID": "com.example.Demo",
        "APP_DIRECTORY": "Demo",
        "SOCKET_FILENAME": "control.sock",
        "ENV_SOCKET": "DEMO_CONTROL_SOCKET",
        "CODE_NOT_RUNNING": "demo_not_running",
        "CODE_SOCKET_STALE": "demo_socket_stale",
        "LAST_VERSION_WITHOUT_SHORT_SOCKET_PATH": "1.0.0",
    }
    namespace.update(overrides)
    with open(CORE, encoding="utf-8") as handle:
        source = handle.read()
    exec(compile(source, CORE, "exec"), namespace)
    return namespace


class Server(object):
    """一次性 AF_UNIX 服务端：每个连接读完请求后按 `script` 回话。"""

    def __init__(self, path, script):
        self.path = path
        self.script = script
        self.requests = []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(4)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while True:
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            data = b""
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
            self.requests.append(json.loads(data.decode("utf-8")))
            try:
                self.script(conn)
            finally:
                conn.close()

    def close(self):
        self.listener.close()


workdir = tempfile.mkdtemp(prefix="uctl-selftest-")
try:
    core = load_core()

    # ---- 逐行协议：心跳空行、进度行、最终响应 ----
    path = os.path.join(workdir, "a.sock")

    def heartbeat_then_reply(conn):
        conn.sendall(b"\n")
        conn.sendall(b'{"event":"progress","bytes":5}\n')
        conn.sendall(b"\n")
        conn.sendall(b'{"id":"1","ok":true,"pong":true}\n')

    server = Server(path, heartbeat_then_reply)
    progress = []
    response = core["exchange"](path, {"id": "1", "action": "ping"}, on_progress=progress.append)
    check(response == {"id": "1", "ok": True, "pong": True}, "心跳与进度行之后读到最终响应")
    check(progress == [{"event": "progress", "bytes": 5}], "进度行交给 on_progress")
    server.close()

    # ---- 多行格式的响应兜底 ----
    path = os.path.join(workdir, "b.sock")
    server = Server(path, lambda conn: conn.sendall(b'{\n  "id": "2",\n  "ok": false,\n  "code": "x"\n}'))
    response = core["exchange"](path, {"id": "2", "action": "ping"})
    check(response.get("code") == "x", "多行 JSON 响应拼回来再解")
    server.close()

    # ---- 静默超时：连心跳都没有 → client_timeout，且只发了一次 ----
    os.environ["DEMOCTL_IDLE_TIMEOUT"] = "0.3"
    quiet = load_core()
    os.environ.pop("DEMOCTL_IDLE_TIMEOUT")
    path = os.path.join(workdir, "c.sock")
    server = Server(path, lambda conn: time.sleep(1.0))
    response = quiet["exchange"](path, {"id": "3", "action": "run"})
    check(response.get("code") == "client_timeout", "静默超过 idle timeout → client_timeout")
    check(quiet["exit_code_for"](response) == quiet["EXIT_TIMEOUT"], "client_timeout 退出码 6")
    server.close()

    # ---- 心跳会重置静默计时 ----
    os.environ["DEMOCTL_IDLE_TIMEOUT"] = "0.4"
    patient = load_core()
    os.environ.pop("DEMOCTL_IDLE_TIMEOUT")
    path = os.path.join(workdir, "d.sock")

    def slow_with_heartbeats(conn):
        for _ in range(4):
            time.sleep(0.2)
            conn.sendall(b"\n")
        conn.sendall(b'{"id":"4","ok":true}\n')

    server = Server(path, slow_with_heartbeats)
    response = patient["exchange"](path, {"id": "4", "action": "run"})
    check(response.get("ok") is True, "总耗时超过 idle timeout，但心跳不断就不算卡住")
    server.close()

    # ---- 结果不明不重放：送达后连接被拆 → empty_response，服务端只收到一次 ----
    path = os.path.join(workdir, "e.sock")
    server = Server(path, lambda conn: None)
    os.environ[core["ENV_SOCKET"]] = path
    response = core["send_request"]({"id": "5", "action": "exec"})
    check(response.get("code") == "empty_response", "送达后无回应 → empty_response")
    time.sleep(0.1)
    check(len(server.requests) == 1, "结果不明的请求没有被重放")
    os.environ.pop(core["ENV_SOCKET"])
    server.close()

    # ---- 残留 socket（文件在、没人听）+ 偏好关着 → stale，带按需启动失败原因 ----
    stale_path = os.path.join(workdir, "stale.sock")
    leftover = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    leftover.bind(stale_path)
    leftover.close()
    prefs = os.path.join(workdir, "prefs.plist")
    with open(prefs, "wb") as handle:
        import plistlib
        plistlib.dump({"background.allowOnDemandLaunch": False}, handle)
    offline = load_core()
    offline["PREFERENCE_CANDIDATES"] = [prefs]
    os.environ[offline["ENV_SOCKET"]] = stale_path
    response = offline["send_request"]({"id": "6", "action": "ping"})
    check(response.get("code") == "demo_socket_stale", "残留 socket → <app>_socket_stale")
    check("按需启动没成功" in response.get("message", ""), "残留时也带上按需启动没成功的原因")
    os.environ[offline["ENV_SOCKET"]] = os.path.join(workdir, "missing.sock")
    response = offline["send_request"]({"id": "7", "action": "ping"})
    check(response.get("code") == "demo_not_running", "没有 socket 且不允许按需启动 → <app>_not_running")
    check(offline["exit_code_for"](response) == 2, "not_running 退出码 2")
    os.environ.pop(offline["ENV_SOCKET"])

    # ---- 偏好读不到（EPERM）当未知，不当关 ----
    unreadable = os.path.join(workdir, "unreadable.plist")
    shutil.copy(prefs, unreadable)
    os.chmod(unreadable, 0)
    offline["PREFERENCE_CANDIDATES"] = [unreadable]
    if os.geteuid() != 0:
        check(offline["preference_value"]("background.allowOnDemandLaunch") is None, "偏好读不到 → None（交给 app 把关）")
    os.chmod(unreadable, 0o600)
    offline["PREFERENCE_CANDIDATES"] = [os.path.join(workdir, "absent.plist")]
    check(offline["preference_value"]("control.enabled") is False, "偏好文件不存在 → False")

    # ---- 退出码表 ----
    code = core["exit_code_for"]
    table = [
        ({"ok": True}, 0),
        ({"ok": False, "code": "server_busy"}, 2),
        ({"ok": False, "code": "socket_error"}, 2),
        ({"ok": False, "code": "socket_path_too_long"}, 2),
        ({"ok": False, "code": "control_disabled"}, 3),
        ({"ok": False, "code": "writes_disabled"}, 3),
        ({"ok": False, "code": "mutations_disabled"}, 3),
        ({"ok": False, "code": "connection_not_found"}, 4),
        ({"ok": False, "code": "connection_ambiguous"}, 4),
        ({"ok": False, "code": "connect_failed"}, 5),
        ({"ok": False, "code": "write_sql_refused"}, 5),
        ({"ok": False, "code": "handler_timeout"}, 6),
        ({"ok": False, "code": "operation_failed"}, 1),
    ]
    for response, expected in table:
        check(code(response) == expected, "退出码 %s → %d" % (response.get("code", "ok"), expected))
    custom = load_core(EXIT_CODE_OVERRIDES={"host_sftp_only": 3, "run_partial_failure": 7, "host_key_*": 5},
                       EXTRA_PERMANENT_CODES=frozenset(["file_exists", "host_key_*"]))
    check(custom["exit_code_for"]({"ok": False, "code": "host_key_mismatch"}) == 5, "EXIT_CODE_OVERRIDES 的 `*` 按前缀匹配")
    check(not custom["is_retryable"]("host_key_unknown") and not custom["is_retryable"]("file_exists")
          and custom["is_retryable"]("server_busy"), "EXTRA_PERMANENT_CODES（含前缀）不重试")
    check(custom["exit_code_for"]({"ok": False, "code": "host_sftp_only"}) == 3, "EXIT_CODE_OVERRIDES 先于通用规则")
    check(custom["exit_code_for"]({"ok": False, "code": "run_partial_failure"}) == 7, "app 专属码可映射到 7")

    # ---- 退避重试：busy 更耐心，永久错误不重试 ----
    trace = os.path.join(workdir, "sleep-trace")
    os.environ["DEMOCTL_SLEEP_TRACE"] = trace
    retrying = load_core()
    os.environ.pop("DEMOCTL_SLEEP_TRACE")
    attempts = []

    def busy_twice(previous):
        attempts.append(previous)
        return {"ok": len(attempts) > 2, "code": "server_busy"}

    response = retrying["send_with_retry"](busy_twice)
    with open(trace) as handle:
        slept = [float(line) for line in handle]
    check(response.get("ok") and len(attempts) == 3, "server_busy 退避后重试成功")
    check(slept == [0.5, 1.0], "busy 退避 0.5 / 1.0 s")
    attempts[:] = []
    retrying["send_with_retry"](lambda previous: attempts.append(previous) or {"ok": False, "code": "control_disabled"})
    check(len(attempts) == 1, "门禁类错误不重试")
    attempts[:] = []
    retrying["send_with_retry"](lambda previous: attempts.append(previous) or {"ok": False, "code": "server_busy"})
    check(len(attempts) == 1 + len(retrying["BUSY_RETRY_DELAYS"]), "busy 最多退避 %d 次" % len(retrying["BUSY_RETRY_DELAYS"]))

    # ---- socket 候选路径 ----
    candidates = core["SOCKET_CANDIDATES"]
    check(candidates[0] == "~/Library/Containers/com.example.Demo/Data/Library/Application Support/Demo/control.sock",
          "沙盒：先容器的 Application Support")
    check(candidates[1] == "~/Library/Containers/com.example.Demo/Data/tmp/control.sock", "沙盒：再容器的 Data/tmp")
    check(candidates[2] == "~/Library/Application Support/Demo/control.sock", "非沙盒：真实 Application Support")
    temp = core["darwin_user_temp_dir"]()
    check(temp is not None and candidates[3] == os.path.join(temp, "control.sock"),
          "非沙盒退路用 CS_DARWIN_USER_TEMP_DIR，不看 TMPDIR")
    plain = load_core(SANDBOXED=False)["SOCKET_CANDIDATES"]
    check(plain[0] == "~/Library/Application Support/Demo/control.sock" and plain[2] == candidates[0],
          "SANDBOXED = False 时先试非沙盒布局")
    os.environ["DEMO_CONTROL_SOCKET"] = "~/x.sock"
    check(core["socket_paths"]() == [os.path.expanduser("~/x.sock")], "环境变量覆盖全部候选")
    os.environ.pop("DEMO_CONTROL_SOCKET")

    # ---- socket_path_too_long ----
    def paths_for(user):
        return [p.replace("~", "/Users/" + user, 1) for p in candidates]

    too_long = core["socket_path_too_long_response"]
    request = {"id": "long"}
    short_user = "u" * 4
    check(too_long(request, paths_for(short_user), None) is None, "默认路径放得下 → 不是这个原因")
    long_user = "u" * 20
    response = too_long(request, paths_for(long_user), core["LAUNCH_NOT_READY_MESSAGE"])
    check(response and response["code"] == "socket_path_too_long" and "1.0.0" in response["message"],
          "默认路径超长 + 接口没就绪 → 让用户更新（带最后一个旧版本号）")
    check(too_long(request, paths_for(long_user), "被开关拒绝") is None, "被开关拒绝时照旧报开关原因")
    check(too_long(request, paths_for("u" * 60), "被开关拒绝")["code"] == "socket_path_too_long",
          "短路径也放不下 → 不管开关")

    # ---- launch_command ----
    check(core["launch_command"]()[-4:] == ["--args", "--background", "--launch-source", "cli"]
          and core["launch_command"]()[:2] == ["/usr/bin/open", "-gjW"], "按需启动走 open -gjW … --background --launch-source cli")
    check(core["launch_command"]()[2:4] == ["-b", "com.example.Demo"], "不在 app 包里时按 bundle id 打开")

    # ---- sync-core.sh ----
    ctl = os.path.join(workdir, "democtl")
    with open(ctl, "w") as handle:
        handle.write("#!/usr/bin/env python3\nAPP_NAME = 'Demo'\n# BEGIN uctl-core 0\nold = 1\n# END uctl-core\n\ndef main():\n    pass\n")
    os.chmod(ctl, 0o755)
    sync = os.path.join(HERE, "sync-core.sh")
    stale = subprocess.run([sync, "--check", ctl], capture_output=True, text=True)
    check(stale.returncode == 1, "--check 发现公共区过期")
    done = subprocess.run([sync, ctl], capture_output=True, text=True)
    with open(ctl) as handle:
        synced = handle.read()
    with open(CORE) as handle:
        canonical = handle.read()
    region = canonical[canonical.index("\n# BEGIN uctl-core") + 1:canonical.index("\n# END uctl-core") + len("\n# END uctl-core\n")]
    check(done.returncode == 0 and region in synced and "old = 1" not in synced, "回写替换整段公共区")
    check(synced.startswith("#!/usr/bin/env python3\nAPP_NAME = 'Demo'\n") and synced.endswith("\ndef main():\n    pass\n"),
          "区外内容一个字节不动")
    check(os.stat(ctl).st_mode & 0o777 == 0o755, "保留文件权限")
    check(subprocess.run([sync, "--check", ctl], capture_output=True).returncode == 0, "回写后 --check 通过")
    with open(ctl, "a") as handle:
        handle.write("# END uctl-core\n")
    check(subprocess.run([sync, ctl], capture_output=True).returncode != 0, "标记不成对时拒绝回写")
finally:
    shutil.rmtree(workdir, ignore_errors=True)

if failures:
    print("%d 项失败" % len(failures))
    sys.exit(1)
print("uctl 公共区自测全部通过")
