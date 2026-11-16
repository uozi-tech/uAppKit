"""uctl 公共区的 canonical 版（uAppKit/Tools/uctl）。

各 app 的命令行客户端（utablectl / utermctl / …）把下面 `# BEGIN uctl-core` 到 `# END uctl-core` 之间
的整段**原样 vendor** 进自己的脚本，改公共区只改这里，再用 `sync-core.sh <ctl 文件>` 回写。不在运行时
import：两个 app 都有测试校验 app 包内的 ctl 与仓库副本逐字节一致，客户端也必须是单文件、零依赖。

公共区以 uTerm 的 utermctl 为基准：定位 socket（含非沙盒布局的 `CS_DARWIN_USER_TEMP_DIR`）、读偏好、
`open -gjW … --background --launch-source cli` 按需启动并等 10 秒、逐行协议（空行心跳 / 进度行 /
最终响应）、静默超时、`server_busy` 退避重试、退出码表 0–7。**拿不准结果的请求绝不自动重放**：
只在业务请求送达之前做按需启动，送达之后的失败原样报给调用方。

公共区**之前**必须定义的 app 常量（区里不出现任何 app 专属字符串）：

    APP_NAME = "uTable"                    # 消息里的 app 名
    CTL_NAME = "utablectl"                 # 客户端名；派生 <CTL>_IDLE_TIMEOUT / <CTL>_SLEEP_TRACE 两个自测环境变量
    BUNDLE_ID = "com.uozi.uTable"          # 沙盒容器名、`open -b` 的目标
    APP_DIRECTORY = "uTable"               # <Application Support>/<APP_DIRECTORY>/<SOCKET_FILENAME>
    SOCKET_FILENAME = "control.sock"
    ENV_SOCKET = "UTABLE_CONTROL_SOCKET"   # 显式指定 socket 路径（调试 Debug 构建的 dev.sock）
    CODE_NOT_RUNNING = "utable_not_running"
    CODE_SOCKET_STALE = "utable_socket_stale"
    LAST_VERSION_WITHOUT_SHORT_SOCKET_PATH = "2.0.0"   # 不会改用短 socket 路径的最后一个版本

可选（不定义就用默认值）：

    SANDBOXED = True                       # False：先试非沙盒布局（uGit）
    SETTINGS_PATH = "设置 ▸ 命令行与技能"     # 消息里指给用户的设置位置
    EXIT_CODE_OVERRIDES = {"host_sftp_only": 3, "host_key_*": 5}   # app 专属错误码的退出码，先于通用规则
    EXTRA_PERMANENT_CODES = frozenset(["file_exists", "host_key_*"])  # app 专属的「重试没意义」的错误码
    （这两处的键以 `*` 结尾时按前缀匹配。）

公共区定义的 `SOCKET_CANDIDATES` / `PREFERENCE_CANDIDATES` 是按上面常量算出来的，app 可以在区后重新赋值。
"""

# BEGIN uctl-core 1
# ---------------------------------------------------------------------------
# uctl 公共区：由 uAppKit/Tools/uctl/uctl_core.py 生成，不要在 app 仓库里手改，
# 改 canonical 版后用 uAppKit/Tools/uctl/sync-core.sh 回写。依赖区前定义的 app 常量。
# ---------------------------------------------------------------------------
import array
import json
import os
import plistlib
import socket
import subprocess
import sys
import time
import uuid

UCTL_CORE_VERSION = "1"

ON_DEMAND_KEY = "background.allowOnDemandLaunch"
CONTROL_ENABLED_KEY = "control.enabled"
# sockaddr_un.sun_path 104 字节，要给结尾 NUL 留 1 字节。
MAX_SOCKET_PATH_BYTES = 103
CODE_SOCKET_PATH_TOO_LONG = "socket_path_too_long"

# 服务端槽位满是**排队问题不是错误**，值得更有耐心：退避到 4 秒封顶，前后约 1 分钟才放弃。
# 其余可重试的错误只重试 2 次。只有调用方显式走 `send_with_retry` 时才重试。
RETRY_DELAYS = (0.5, 1.0)
BUSY_RETRY_DELAYS = (0.5, 1.0, 2.0) + (4.0,) * 15
BUSY_CODES = frozenset(["server_busy", "empty_response"])

# 自测专用：指向一个文件时，重试退避只往里记一行秒数、不真的睡。
SLEEP_TRACE = os.environ.get(CTL_NAME.upper() + "_SLEEP_TRACE")

# 等响应时 socket 的**静默**超时（秒）：服务端处理请求期间每 10 秒写一个 `\n` 心跳，
# 连续这么久一个字节都没收到，说明 app 本身卡住了（不是命令慢）。请求自己跑多久由服务端的看门狗管。
# `<CTL>_IDLE_TIMEOUT` 只给自测用。
CLIENT_IDLE_TIMEOUT = float(os.environ.get(CTL_NAME.upper() + "_IDLE_TIMEOUT") or 60)

# code → 退出码。技能文档里的错误码总表与这张表一一对应（app 可以只用 0 / 2 两档，见各自的 main）。
EXIT_OK = 0
EXIT_OTHER = 1
EXIT_LOCAL = 2       # 连不上 app，或客户端自己的前置检查没过
EXIT_GATED = 3       # 门禁：开关没开
EXIT_NOT_FOUND = 4   # 要操作的对象找不到或有歧义
EXIT_REMOTE = 5      # 建连、认证失败
EXIT_TIMEOUT = 6     # 超时
EXIT_PARTIAL = 7     # 批量操作有成有败


def _setting(name, default):
    return globals().get(name, default)


def _code_pattern_match(code, patterns):
    """`patterns` 里的键与 code 相同，或以 `*` 结尾且是 code 的前缀。返回匹配到的键（没有返回 None）。"""
    if code in patterns:
        return code
    for pattern in patterns:
        if pattern.endswith("*") and code.startswith(pattern[:-1]):
            return pattern
    return None


def settings_path():
    return _setting("SETTINGS_PATH", "设置 ▸ 命令行与技能")


def darwin_user_temp_dir():
    """`confstr(_CS_DARWIN_USER_TEMP_DIR)`：不看 `TMPDIR`，与非沙盒 app 用的退路目录逐字一致。"""
    # Python 的 confstr_names 里没有这个名字，按 <unistd.h> 的值 65537 查。
    try:
        path = os.confstr(os.confstr_names.get("CS_DARWIN_USER_TEMP_DIR", 65537))
    except (ValueError, OSError):
        return None
    return path.rstrip("/") if path else None


def default_socket_candidates():
    """与 UControlKit `ControlSocketLocation.clientCandidates` 的规则一一对应：先默认目录，再退路目录。

    沙盒布局：容器的 Application Support，放不进 sun_path 时退到容器的 Data/tmp/。
    非沙盒布局：真实 Application Support，退到 `CS_DARWIN_USER_TEMP_DIR`（绝对路径）。
    两种都列上（同一个 app 的 Debug / Release 可能一个开沙盒一个不开），按 `SANDBOXED` 定先后。
    """
    container = "~/Library/Containers/%s/Data" % BUNDLE_ID
    sandboxed = [
        "%s/Library/Application Support/%s/%s" % (container, APP_DIRECTORY, SOCKET_FILENAME),
        "%s/tmp/%s" % (container, SOCKET_FILENAME),
    ]
    plain = ["~/Library/Application Support/%s/%s" % (APP_DIRECTORY, SOCKET_FILENAME)]
    temp = darwin_user_temp_dir()
    if temp:
        plain.append(os.path.join(temp, SOCKET_FILENAME))
    return sandboxed + plain if _setting("SANDBOXED", True) else plain + sandboxed


SOCKET_CANDIDATES = default_socket_candidates()
PREFERENCE_CANDIDATES = [
    "~/Library/Containers/%s/Data/Library/Preferences/%s.plist" % (BUNDLE_ID, BUNDLE_ID),
    "~/Library/Preferences/%s.plist" % BUNDLE_ID,
]


def socket_paths():
    override = os.environ.get(ENV_SOCKET)
    if override:
        return [os.path.expanduser(override)]
    return [os.path.expanduser(p) for p in SOCKET_CANDIDATES]


def socket_path_too_long_response(request, paths, launch_error):
    """路径长度才是真正原因时给出 `socket_path_too_long`，否则返回 None。

    用户名稍长时默认位置放不进 sun_path，app 改用退路目录（第二条候选）：
    - 第二条也放不下：接口一定起不来，不管开关怎么设。
    - 第二条放得下却连不上，而 app 确实被拉起来了（没被开关拒绝，只是接口没就绪）：
      装的是不会改用短路径的旧版本，接口在这台机器上起不来。
    被开关拒绝时照旧报开关的原因。显式指定了 socket 环境变量时不判。
    """
    if os.environ.get(ENV_SOCKET) or len(paths) < 2:
        return None
    primary, fallback = paths[0], paths[1]
    primary_bytes = len(primary.encode("utf-8"))
    if primary_bytes <= MAX_SOCKET_PATH_BYTES:
        return None
    if len(fallback.encode("utf-8")) > MAX_SOCKET_PATH_BYTES:
        message = ("macOS 用户名过长，%s 的 socket 路径连备用的短路径都超过系统上限 %d 字节（%s），"
                   "命令行接口无法启动。" % (APP_NAME, MAX_SOCKET_PATH_BYTES, fallback))
    elif launch_error in (None, LAUNCH_NOT_READY_MESSAGE):
        message = ("macOS 用户名过长，%s 默认的 socket 路径（%d 字节）超过系统上限 %d 字节：%s。"
                   "%s %s 及更早的版本在这样的账户上无法启动命令行接口，"
                   "请把 %s 更新到最新版本（新版本会自动改用更短的路径）。"
                   % (APP_NAME, primary_bytes, MAX_SOCKET_PATH_BYTES, primary,
                      APP_NAME, LAST_VERSION_WITHOUT_SHORT_SOCKET_PATH, APP_NAME))
    else:
        return None
    return {"id": request.get("id"), "ok": False, "code": CODE_SOCKET_PATH_TOO_LONG, "message": message}


def preference_value(key):
    """读 app 的一个布尔设置：True / False；读不到时返回 None（未知）。

    macOS 27 起，没给完全磁盘访问权限的进程读不了沙盒容器里的偏好 plist（EPERM）。
    这时不能当成「关」—— 交给 app 自己按设置把关（见 start_background_and_wait）。
    """
    unreadable = False
    for candidate in PREFERENCE_CANDIDATES:
        try:
            with open(os.path.expanduser(candidate), "rb") as stream:
                value = plistlib.load(stream).get(key)
        except PermissionError:
            unreadable = True
            continue
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
        if value is not None:
            return bool(value)
    return None if unreadable else False


def on_demand_launch_allowed():
    return preference_value(ON_DEMAND_KEY)


def owning_app_bundle():
    path = os.path.realpath(__file__)
    while path and path != os.path.dirname(path):
        if path.endswith(".app"):
            return path
        path = os.path.dirname(path)
    return None


def launch_command():
    bundle = owning_app_bundle()
    target = ["-a", bundle] if bundle else ["-b", BUNDLE_ID]
    # -W：等 app 进程退出才返回。app 按设置拒绝按需启动时会立刻退出，靠它区分
    # 「被拒绝」与「还在起」；接口就绪后这个等待进程直接结束掉，不影响 app。
    return (["/usr/bin/open", "-gjW"] + target
            + ["--args", "--background", "--launch-source", "cli"])


LAUNCH_NOT_READY_MESSAGE = ("已请求后台启动 %s，但接口在 10 秒内没有就绪。若 %s 本来就在运行，"
                            "确认%s 里已打开「启用命令行接口」。" % (APP_NAME, APP_NAME, settings_path()))


def start_background_and_wait():
    """按需启动 app 并等接口就绪（10 秒）。返回 (成功, 失败原因)。"""
    # 读得到设置就先在本地拦下，报得准、也不白起一次进程；读不到（None）照样请求启动，
    # app 收到 `--launch-source cli` 会自己检查这两项，不满足就立刻退出。
    if on_demand_launch_allowed() is False:
        return False, ("%s 未运行，且设置中没有允许 CLI 按需启动。用户在 %s %s 里"
                       "打开「允许 CLI 按需启动」之后，%s 会自己在后台把它起起来。"
                       % (APP_NAME, APP_NAME, settings_path(), CTL_NAME))
    if preference_value(CONTROL_ENABLED_KEY) is False:
        return False, "%s 命令行接口未启用；按需启动设置不会绕过接口门禁。" % APP_NAME
    try:
        launcher = subprocess.Popen(
            launch_command(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    except OSError as error:
        return False, "无法唤起 %s 后台实例：%s" % (APP_NAME, error)

    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            for path in socket_paths():
                if not os.path.exists(path):
                    continue
                try:
                    exchange(path, {"id": str(uuid.uuid4()), "action": "ping"})
                    # 能回话就算就绪；门禁类错误留给真正的业务请求去报。
                    return True, None
                except (ConnectionRefusedError, OSError):
                    pass
            code = launcher.poll()
            if code is not None:
                if code != 0:
                    return False, "无法唤起 %s 后台实例：%s" % (APP_NAME, launcher.stderr.read().strip())
                return False, ("%s 拒绝了按需启动：需要在 %s %s 里同时打开"
                               "「允许 CLI 按需启动」和「启用命令行接口」。"
                               % (APP_NAME, APP_NAME, settings_path()))
            time.sleep(0.1)
        return False, LAUNCH_NOT_READY_MESSAGE
    finally:
        if launcher.poll() is None:
            launcher.terminate()
            try:
                launcher.wait(timeout=1)
            except subprocess.TimeoutExpired:
                launcher.kill()


def fail(message):
    """客户端自己的前置检查没过：stderr 一行文本，退出码 2（没有 JSON）。"""
    sys.stderr.write(message + "\n")
    sys.exit(EXIT_LOCAL)


def send_request(request, fd=None, on_progress=None):
    """发一条请求，返回响应 dict（失败也是 dict，带 `code`）。

    `fd` 给了就随请求经 `SCM_RIGHTS` 交给 app；`on_progress` 收处理期间的进度行。
    """
    paths = socket_paths()
    stale = []
    found_socket = False
    for path in paths:
        if not os.path.exists(path):
            continue
        found_socket = True
        try:
            return exchange(path, request, fd, on_progress)
        except ConnectionRefusedError:
            # 文件在、没人监听 = 上一个实例被强杀（Xcode 重新 Run、崩溃）留下的残留，
            # 它自己没机会 unlink。和「app 没装 / 没开」是两回事，别混成一个错。
            stale.append(path)
        except OSError as error:
            return {
                "id": request.get("id"),
                "ok": False,
                "code": "socket_error",
                "message": "%s: %s" % (path, error),
            }
    # Only launch before the business request has been delivered. Once exchange() accepted
    # bytes, an unknown result is returned as-is and is never replayed automatically.
    launch_error = None
    if not found_socket or stale:
        started, launch_error = start_background_and_wait()
        if started:
            for path in paths:
                if os.path.exists(path):
                    try:
                        return exchange(path, request, fd, on_progress)
                    except (ConnectionRefusedError, OSError):
                        continue
        elif launch_error and not found_socket:
            return (socket_path_too_long_response(request, paths, launch_error)
                    or {"id": request.get("id"), "ok": False,
                        "code": CODE_NOT_RUNNING, "message": launch_error})
    if stale:
        return {
            "id": request.get("id"),
            "ok": False,
            "code": CODE_SOCKET_STALE,
            "message": ("socket 文件还在但没有进程在监听（" + "、".join(stale) + "）。"
                        + "%s 多半正在重启或刚被强制退出 —— 等它起来后重试一次；" % APP_NAME
                        + "若 %s 确实没在运行，这个文件会在下次启动时自动清掉。" % APP_NAME
                        # 残留 socket 时也试过按需启动：没起来的原因别吞掉，否则调用方只会干等。
                        + (" 按需启动没成功：" + launch_error if launch_error else "")),
        }
    too_long = socket_path_too_long_response(request, paths, launch_error)
    if too_long:
        return too_long
    return {
        "id": request.get("id"),
        "ok": False,
        "code": CODE_NOT_RUNNING,
        "message": ("%s 的 IPC socket 不存在（试过 " % APP_NAME + "、".join(paths) + "）。"
                    + "确认 %s 正在运行，且%s 里已打开「启用命令行接口」。" % (APP_NAME, settings_path())),
    }


class ServerSilent(Exception):
    """app 连续 `CLIENT_IDLE_TIMEOUT` 秒一个字节都没发（连心跳都没有）。"""


def read_response(sock, on_progress=None):
    """读到 EOF，一行一行处理：空行是心跳，`{"event":"progress"}` 交给 `on_progress`，
    其余那一行是最终响应。读不到响应返回 None。

    socket 超时是**每次 recv** 的，心跳 / 进度一到就重新计时。
    """
    buffered = b""
    final = [None]
    leftovers = []      # 不是单行 JSON 的行（兜底：多行格式的响应）

    def consume(line):
        line = line.strip()
        if not line:
            return
        try:
            body = json.loads(line.decode("utf-8"))
        except ValueError:
            leftovers.append(line)
            return
        if isinstance(body, dict) and body.get("event") == "progress":
            if on_progress is not None:
                on_progress(body)
        elif isinstance(body, dict):
            final[0] = body

    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buffered += chunk
            while b"\n" in buffered:
                line, buffered = buffered.split(b"\n", 1)
                consume(line)
    except socket.timeout:
        raise ServerSilent()
    except OSError:
        # 对端已经把连接拆了；已经收到的那部分仍然可能是完整的一条响应。
        pass
    consume(buffered)
    if final[0] is None and leftovers:
        # 服务端一行一个 JSON；万一碰上把响应排成多行的实现，把剩下的行拼回去再解一次。
        try:
            body = json.loads(b"\n".join(leftovers).decode("utf-8"))
            if isinstance(body, dict):
                final[0] = body
        except ValueError:
            pass
    return final[0]


def exchange(path, request, fd=None, on_progress=None):
    """一条请求一条响应。连不上抛 `ConnectionRefusedError` / `OSError`（请求没送达，可以按需启动后再发）；
    送达之后的失败一律变成响应 dict 返回（结果不明，不重放）。"""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(CLIENT_IDLE_TIMEOUT)
    try:
        return _exchange(sock, path, request, fd, on_progress)
    except ServerSilent:
        return {
            "id": request.get("id"),
            "ok": False,
            "code": "client_timeout",
            "message": ("%s 连续 %d 秒没有任何回应（处理中每 10 秒一次的心跳也没有），"
                        "多半是 %s 本身卡住了；请求可能已经执行了一部分。"
                        % (APP_NAME, CLIENT_IDLE_TIMEOUT, APP_NAME)),
        }
    finally:
        sock.close()


def _exchange(sock, path, request, fd=None, on_progress=None):
    try:
        sock.connect(path)
        payload = json.dumps(request).encode("utf-8")
        try:
            if fd is None:
                sock.sendall(payload)
            else:
                # fd 挂在第一段数据上（SCM_RIGHTS）；没发完的部分照常补。
                sent = sock.sendmsg(
                    [payload], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))])
                if sent < len(payload):
                    sock.sendall(payload[sent:])
            sock.shutdown(socket.SHUT_WR)
        except (BrokenPipeError, ConnectionResetError):
            # 服务端可能**在我们写完之前**就回了一条响应并关掉连接（请求体超限之类）。
            # AF_UNIX 上已经写回的数据不会因对端 close 而丢，所以先把它读出来：
            # 读到 JSON 就按正常响应处理，读不到才把 EPIPE 报成 socket_error。
            response = read_response(sock, on_progress)
            if response is not None:
                return response
            raise
        response = read_response(sock, on_progress)
    except socket.timeout:
        # connect / send 阶段的超时同样是「app 不回应」。
        raise ServerSilent()
    if response is None:
        return {
            "id": request.get("id"),
            "ok": False,
            "code": "empty_response",
            "message": "%s IPC 返回了空响应或读不懂的内容" % APP_NAME,
        }
    return response


def exit_code_for(response):
    """响应 → 退出码（0–7）。app 专属的码先查 `EXIT_CODE_OVERRIDES`。"""
    if response.get("ok"):
        return EXIT_OK
    code = response.get("code") or ""
    overrides = _setting("EXIT_CODE_OVERRIDES", {})
    matched = _code_pattern_match(code, overrides)
    if matched is not None:
        return overrides[matched]
    # `server_busy` 与 `empty_response` 是同一件事的两种表现（服务端槽位满，后者是它
    # 直接关连接）；`local_*` 是客户端自己的磁盘 / 本地文件问题 —— 都归「本地」这一档。
    if code in (CODE_NOT_RUNNING, CODE_SOCKET_STALE, CODE_SOCKET_PATH_TOO_LONG,
                "socket_error", "empty_response", "server_busy",
                "local_read_failed", "local_write_failed", "local_failure"):
        return EXIT_LOCAL
    if code in ("control_disabled", "mutations_disabled", "writes_disabled"):
        return EXIT_GATED
    if code.endswith("_not_found") or code.endswith("_ambiguous"):
        return EXIT_NOT_FOUND
    if code in ("connect_failed", "auth_failed") or code.endswith("_refused"):
        return EXIT_REMOTE
    if code in ("handler_timeout", "client_timeout"):
        return EXIT_TIMEOUT
    return EXIT_OTHER


# 这些码重试没有意义：门禁、参数不对、本地问题、app 没在跑（重试改变不了事实）。
PERMANENT_CODES = frozenset([
    "control_disabled", "mutations_disabled", "writes_disabled",
    "invalid_request", "not_implemented", "permission_denied", "auth_failed", "request_too_large",
    "local_read_failed", "local_write_failed", "local_failure",
    CODE_NOT_RUNNING, CODE_SOCKET_STALE, CODE_SOCKET_PATH_TOO_LONG,
])


def new_request(action, **fields):
    """带 id 的请求体；值为 None 的字段不出现在 JSON 里。"""
    body = {"id": str(uuid.uuid4()), "action": action}
    for key, value in fields.items():
        if value is not None:
            body[key] = value
    return body


def is_retryable(code):
    if code in PERMANENT_CODES or _code_pattern_match(code, _setting("EXTRA_PERMANENT_CODES", frozenset())):
        return False
    if code.endswith("_not_found") or code.endswith("_ambiguous"):
        return False
    return True


def backoff(seconds):
    """退避。`<CTL>_SLEEP_TRACE`（自测专用）指向一个文件时只记账、不真的睡。"""
    if SLEEP_TRACE:
        try:
            with open(SLEEP_TRACE, "a") as handle:
                handle.write("%.3f\n" % seconds)
        except OSError:
            pass
        return
    time.sleep(seconds)


def send_with_retry(attempt):
    """把「一次尝试」按错误码退避重试。只给**幂等**或自己能续上的操作用（读、断点续传）。

    `attempt(previous)` 返回一条响应，`previous` 是上一次的失败响应（第一次是 None）。
    槽位满（`server_busy` / 服务端直接关连接时看到的 `empty_response`）更耐心：
    退避 0.5/1/2 s 后每 4 s 一次，约 1 分钟；其余可重试码 2 次（0.5 / 1 s）。
    """
    response = attempt(None)
    tries = 0
    while not response.get("ok"):
        code = response.get("code") or ""
        if not is_retryable(code):
            break
        delays = BUSY_RETRY_DELAYS if code in BUSY_CODES else RETRY_DELAYS
        if tries >= len(delays):
            break
        backoff(delays[tries])
        tries += 1
        response = attempt(response)
    return response
# END uctl-core
