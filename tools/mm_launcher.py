"""Shared helpers to start Material Maker headlessly (used by mm.py and mm_mcp.py).

Finding the program, in order:
  MM_EXE    path of an exported Material Maker executable (runs `<exe> --cli ...`)
  MM_GODOT  path of a Godot 4.7 binary, run against this source tree (godot --path <repo> ...)
  GODOT     same as MM_GODOT
  godot / godot4 found on PATH

Headless runs still need a window for the GPU, so on Windows they are started on a private, invisible desktop:
nothing appears on screen, in the taskbar or in the tray, and no focus is stolen. Set MM_SHOW_WINDOW=1 to disable that
(useful for debugging). On other systems the process is simply started in the background.
"""
import atexit
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULT_MARKER = "@@MM_RESULT@@ "
READY_MARKER = "@@MM_READY@@ "


class LauncherError(RuntimeError):
    pass


def _console_variant(path):
    """On Windows the GUI-subsystem Godot exe does not reliably write to pipes."""
    base, ext = os.path.splitext(path)
    if sys.platform == "win32" and ext.lower() == ".exe" and not base.lower().endswith("_console"):
        candidate = base + "_console" + ext
        if os.path.exists(candidate):
            return candidate
    return path


def command_prefix():
    """argv that precedes the `--cli ...` arguments."""
    exe = os.environ.get("MM_EXE")
    if exe:
        return [exe]
    godot = os.environ.get("MM_GODOT") or os.environ.get("GODOT")
    if not godot:
        for name in ("godot", "godot4", "Godot"):
            godot = shutil.which(name)
            if godot:
                break
    if not godot:
        raise LauncherError(
            "Cannot find Godot. Set MM_GODOT to a Godot 4.7 binary (or MM_EXE to an exported "
            "Material Maker), or put godot on PATH.")
    godot = _console_variant(godot)
    # --no-window: rendering still works (GPU needed) but no window is shown
    return [godot, "--path", REPO, "--no-window", "--"]


def _env(cwd):
    env = dict(os.environ)
    env["MM_CWD"] = (cwd or os.getcwd()).replace("\\", "/")
    return env


# --- starting processes without any visible window -------------------------------------------------

_desktop = None


def _hidden_desktop():
    """(name, handle) of a private desktop (Windows), created once per process; None if unavailable."""
    global _desktop
    if _desktop is None:
        import ctypes
        import ctypes.wintypes as wt
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        user32.CreateDesktopW.restype = wt.HANDLE
        user32.CreateDesktopW.argtypes = [wt.LPCWSTR, wt.LPCWSTR, ctypes.c_void_p, wt.DWORD, wt.DWORD, ctypes.c_void_p]
        name = "mm_hidden_%d" % os.getpid()
        handle = user32.CreateDesktopW(name, None, None, 0, 0x10000000, None)   # GENERIC_ALL
        _desktop = (name, handle) if handle else False
        if handle:
            atexit.register(lambda: user32.CloseDesktop(handle))
    return _desktop or None


_job = None


def _kill_on_exit_job():
    """A job object that kills its processes when this launcher exits (even if it crashes), so a Material Maker running on
    the invisible desktop can never be left behind unnoticed."""
    global _job
    if _job is None:
        import ctypes
        import ctypes.wintypes as wt
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)

        class BASIC(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64), ("LimitFlags", wt.DWORD),
                        ("MinimumWorkingSetSize", ctypes.c_size_t), ("MaximumWorkingSetSize", ctypes.c_size_t),
                        ("ActiveProcessLimit", wt.DWORD), ("Affinity", ctypes.c_size_t), ("PriorityClass", wt.DWORD),
                        ("SchedulingClass", wt.DWORD)]

        class EXTENDED(ctypes.Structure):
            _fields_ = [("Basic", BASIC), ("IoInfo", ctypes.c_uint64 * 6), ("ProcessMemoryLimit", ctypes.c_size_t),
                        ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
                        ("PeakJobMemoryUsed", ctypes.c_size_t)]

        k32.CreateJobObjectW.restype = wt.HANDLE
        k32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wt.LPCWSTR]
        k32.SetInformationJobObject.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD]
        job = k32.CreateJobObjectW(None, None)
        info = EXTENDED()
        info.Basic.LimitFlags = 0x2000   # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        ok = job and k32.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info))
        _job = job if ok else False
    return _job or None


class _HiddenProc:
    """Popen-like handle (poll / wait / kill / pid) for a process created on the hidden desktop."""

    def __init__(self, handle, pid):
        import ctypes
        self._k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._handle = handle
        self.pid = pid

    def poll(self):
        import ctypes
        import ctypes.wintypes as wt
        code = wt.DWORD()
        self._k32.GetExitCodeProcess(self._handle, ctypes.byref(code))
        return None if code.value == 259 else code.value   # 259 = STILL_ACTIVE

    def wait(self, timeout=None):
        status = self._k32.WaitForSingleObject(self._handle, 0xFFFFFFFF if timeout is None else int(timeout * 1000))
        if status == 258:   # WAIT_TIMEOUT
            raise subprocess.TimeoutExpired("material-maker", timeout)
        return self.poll()

    def kill(self):
        self._k32.TerminateProcess(self._handle, 1)


def _spawn_hidden_windows(argv, env, cwd, log_file):
    import ctypes
    import ctypes.wintypes as wt
    import msvcrt
    desktop = _hidden_desktop()
    if desktop is None:
        return None

    class STARTUPINFOW(ctypes.Structure):
        _fields_ = [("cb", wt.DWORD), ("lpReserved", wt.LPWSTR), ("lpDesktop", wt.LPWSTR), ("lpTitle", wt.LPWSTR),
                    ("dwX", wt.DWORD), ("dwY", wt.DWORD), ("dwXSize", wt.DWORD), ("dwYSize", wt.DWORD),
                    ("dwXCountChars", wt.DWORD), ("dwYCountChars", wt.DWORD), ("dwFillAttribute", wt.DWORD),
                    ("dwFlags", wt.DWORD), ("wShowWindow", wt.WORD), ("cbReserved2", wt.WORD), ("lpReserved2", ctypes.c_void_p),
                    ("hStdInput", wt.HANDLE), ("hStdOutput", wt.HANDLE), ("hStdError", wt.HANDLE)]

    class PROCESS_INFORMATION(ctypes.Structure):
        _fields_ = [("hProcess", wt.HANDLE), ("hThread", wt.HANDLE), ("dwProcessId", wt.DWORD), ("dwThreadId", wt.DWORD)]

    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateProcessW.argtypes = [wt.LPCWSTR, wt.LPWSTR, ctypes.c_void_p, ctypes.c_void_p, wt.BOOL, wt.DWORD, ctypes.c_void_p,
                                   wt.LPCWSTR, ctypes.POINTER(STARTUPINFOW), ctypes.POINTER(PROCESS_INFORMATION)]
    nul = open(os.devnull, "rb")
    handles = [msvcrt.get_osfhandle(nul.fileno()), msvcrt.get_osfhandle(log_file.fileno())]
    for h in handles:
        os.set_handle_inheritable(h, True)
    si = STARTUPINFOW()
    si.cb = ctypes.sizeof(si)
    si.lpDesktop = desktop[0]
    si.dwFlags = 0x100   # STARTF_USESTDHANDLES
    si.hStdInput, si.hStdOutput, si.hStdError = handles[0], handles[1], handles[1]
    pi = PROCESS_INFORMATION()
    cmd = subprocess.list2cmdline(argv)
    block = ctypes.create_unicode_buffer("".join("%s=%s\0" % kv for kv in env.items()) + "\0")
    ok = k32.CreateProcessW(None, ctypes.create_unicode_buffer(cmd), None, None, True, 0x400, ctypes.cast(block, ctypes.c_void_p),
                            cwd, ctypes.byref(si), ctypes.byref(pi))
    nul.close()
    if not ok:
        return None
    k32.CloseHandle(pi.hThread)
    job = _kill_on_exit_job()
    if job:
        k32.AssignProcessToJobObject.argtypes = [wt.HANDLE, wt.HANDLE]
        k32.AssignProcessToJobObject(job, pi.hProcess)
    return _HiddenProc(pi.hProcess, pi.dwProcessId)


def spawn(argv, env):
    """Start a headless Material Maker process whose output goes to a log file. Returns (process, log_path).

    The process object has poll(), wait(timeout), kill() and pid."""
    fd, log_path = tempfile.mkstemp(prefix="mm_log_", suffix=".txt")
    log_file = os.fdopen(fd, "wb")
    proc = None
    try:
        if sys.platform == "win32" and not os.environ.get("MM_SHOW_WINDOW"):
            proc = _spawn_hidden_windows(argv, env, REPO, log_file)
        if proc is None:
            proc = subprocess.Popen(argv, stdout=log_file, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
    finally:
        log_file.close()
    return proc, log_path


def read_log(log_path):
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def remove_log(log_path):
    try:
        os.remove(log_path)
    except OSError:
        pass


DEFAULT_LIVE_PORT = 8765


def live_port_in_use(port=DEFAULT_LIVE_PORT):
    """True if a Material Maker editor answers on the live port."""
    try:
        s = Server(live_port=port)
        s.start()
    except LauncherError:
        return False
    try:
        resp = s.call("ping", timeout=10)
        return bool(resp.get("ok") and resp["result"].get("live"))
    except (OSError, ValueError, LauncherError):
        return False
    finally:
        s.stop()


def start_gui(port=DEFAULT_LIVE_PORT, files=()):
    """Launch the editor with the live server enabled. Returns the Popen (the editor keeps running)."""
    argv = command_prefix()
    exe = os.environ.get("MM_EXE")
    if exe:
        argv = [exe]
    else:
        # the full GUI: no --no-window; use the windowed exe, not the console one
        argv = [a for a in argv if a != "--no-window"]
        if sys.platform == "win32":
            argv[0] = argv[0].replace("_console.exe", ".exe")
        argv = [a for a in argv if a != "--"]
    argv = argv + ["--"] + ["--live-server", str(port)] + [os.path.abspath(f) for f in files]
    return subprocess.Popen(argv, env=_env(None), cwd=REPO if not exe else None)


def run_cli(args, cwd=None, timeout=600):
    """Run one `--cli` command. Returns (result_dict, log_text)."""
    argv = command_prefix() + ["--cli"] + list(args)
    proc, log_path = spawn(argv, _env(cwd))
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        remove_log(log_path)
        raise LauncherError("Material Maker timed out after %ds" % timeout)
    log = read_log(log_path)
    remove_log(log_path)
    result = None
    for line in log.splitlines():
        if line.startswith(RESULT_MARKER):
            result = json.loads(line[len(RESULT_MARKER):])
    return result, log


def interesting_log(log, limit=40):
    """Engine log lines worth showing when something failed (drops known teardown noise)."""
    noise = ("process_frame", "data.tree", "Unreferenced static string", "Steam", "ObjectDB",
             "resources still in use", "Thread object", "Semaphore", "at: ", "GDScript backtrace",
             "[0] ", "[1] ", "Godot Engine v", "Vulkan", "Please call", RESULT_MARKER.strip(),
             "Cannot open user://", "Failed to open", "Successfully read library", "Loading...")
    lines = [l for l in log.splitlines() if l.strip() and not any(n in l for n in noise)]
    return "\n".join(lines[-limit:])


class Server:
    """A long-running `--cli serve` process spoken to with JSON lines over localhost TCP."""

    def __init__(self, cwd=None, startup_timeout=120, live_port=None):
        self.cwd = cwd
        self.live_port = live_port  # attach to a running editor (--live-server) instead of starting one
        self.startup_timeout = startup_timeout
        self.proc = None
        self.log_path = None
        self.sock = None
        self.buffer = b""
        self.next_id = 1
        self.lock = threading.Lock()

    def _free_port(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    def _log_text(self):
        return read_log(self.log_path) if self.log_path else ""

    def start(self):
        if self.live_port:
            try:
                self.sock = socket.create_connection(("127.0.0.1", self.live_port), timeout=5)
            except OSError:
                raise LauncherError("No live Material Maker on port %d. Start the editor with: python tools/mm.py gui --port %d"
                                    % (self.live_port, self.live_port))
            self.sock.settimeout(None)
            self.buffer = b""
            return
        port = self._free_port()
        argv = command_prefix() + ["--cli", "serve", "--port", str(port)]
        self.proc, self.log_path = spawn(argv, _env(self.cwd))
        deadline = time.time() + self.startup_timeout
        while READY_MARKER not in self._log_text():
            if self.proc.poll() is not None:
                text = interesting_log(self._log_text())
                self.stop()
                raise LauncherError("Material Maker exited during startup:\n" + text)
            if time.time() > deadline:
                self.stop()
                raise LauncherError("Material Maker did not start within %ds" % self.startup_timeout)
            time.sleep(0.1)
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.sock.settimeout(None)

    def alive(self):
        if self.live_port:
            return self.sock is not None
        return self.proc is not None and self.proc.poll() is None and self.sock is not None

    def call(self, op, args=None, timeout=600):
        """Returns the response dict: {ok, result} or {ok: False, error, details}."""
        with self.lock:
            if not self.alive():
                self.start()
            request = {"id": self.next_id, "op": op, "args": args or {}, "cwd": (self.cwd or os.getcwd()).replace("\\", "/")}
            self.next_id += 1
            self.sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
            self.sock.settimeout(timeout)
            try:
                while b"\n" not in self.buffer:
                    chunk = self.sock.recv(65536)
                    if not chunk:
                        raise LauncherError("Material Maker closed the connection:\n" + interesting_log(self._log_text()))
                    self.buffer += chunk
            except socket.timeout:
                raise LauncherError("Operation '%s' timed out after %ds" % (op, timeout))
            line, self.buffer = self.buffer.split(b"\n", 1)
            return json.loads(line.decode("utf-8"))

    def stop(self):
        if self.live_port:  # never shut down somebody's editor
            if self.sock is not None:
                self.sock.close()
            self.sock = None
            return
        try:
            if self.sock is not None:
                self.sock.sendall(b'{"id":0,"op":"shutdown"}\n')
        except OSError:
            pass
        if self.proc is not None:
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.log_path:
            remove_log(self.log_path)
            self.log_path = None
        if self.sock is not None:
            self.sock.close()
        self.proc = None
        self.sock = None
