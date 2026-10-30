#!/usr/bin/env python3
"""Exercise actual terminal key input, using only Python's standard library."""
import errno
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import shutil
import struct
import subprocess
import tempfile
import termios
import time


def run_case(case):
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="selection-tools-", dir="/private/tmp" if Path("/private/tmp").exists() else None) as directory:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        env = dict(
            os.environ,
            TERM="xterm-256color",
            SELECTION_TOOLS_TEST_DIR=directory,
            NVIM_LOG_FILE=str(Path(directory, "nvim.log")),
        )
        process = subprocess.Popen(
            [shutil.which("nvim") or "nvim", "-u", "NONE", "-n", "-i", "NONE", "-c", "lua dofile('tests/" + case + ".lua')"],
            cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
        )
        os.close(slave)
        actions = {"type_long": b"x" * 200, "type": b"\x15bta", "move": b"\x0e", "confirm": b"\r", "cancel": b"\x1b"}
        if case == "skim_tui":
            actions.update(prefix=b"b", suffix=b"ta", select=b"\t")
        if case == "git_tui":
            actions.update(git_query=b"history")
        if case == "workflows_tui":
            actions.update(regex=b"\x1br", literal=b"\x1br", scope=b"\x1bf",
                           scope_value=b"\x15" + (directory + "/sub").encode() + b"\r", export=b"\x11", expand=b"\x1bOR", collapse=b"\x1bOR", details=b"\x1bOQ", details_close=b"q", split=b"\x16")
        if case == "grep_columns_tui":
            actions.update(type=b"needle", resize_narrow=b"", resize_tiny=b"", resize_wide=b"")
        if case == "grep_tui":
            actions.update(type=b"hel")
        if case == "match_tui":
            actions.update(type=b"png")
        if case == "item_icons_tui":
            actions.update(select=b"\t", copy=b"\x19")
        if case == "lazy_tui":
            actions.update(type_again=b"bta", close_warm=b"\x1b")
        if case == "preview_tui":
            actions.update(move_again=b"\x0e")
        handled = set()
        output = bytearray()
        deadline = time.monotonic() + 15
        try:
            while process.poll() is None and time.monotonic() < deadline:
                if select.select([master], [], [], 0.03)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                stage_file = Path(directory, "stage")
                stage = stage_file.read_text().strip() if stage_file.exists() else ""
                if stage in actions and stage not in handled:
                    if case == "grep_columns_tui" and stage.startswith("resize_"):
                        columns = {"resize_narrow": 48, "resize_tiny": 16, "resize_wide": 120}[stage]
                        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, columns, 0, 0))
                        os.kill(process.pid, signal.SIGWINCH)
                    else:
                        os.write(master, actions[stage])
                    handled.add(stage)
            if process.poll() is None:
                process.kill()
                raise AssertionError("Terminal test timed out; stages: " + repr(handled))
            result_file = Path(directory, "result")
            result = result_file.read_text().strip() if result_file.exists() else "No terminal test result"
            assert process.returncode == 0 and result.startswith("PASS"), result + "\n" + output.decode(errors="replace")[-3000:]
            if case == "item_icons_tui":
                assert re.search(rb"\x1b\[[0-9;]*38;2;18;52;86(?:;[0-9;]*)?m", output), "Lua icon RGB color was not sent to the terminal"
                assert re.search(rb"\x1b\[[0-9;]*38;2;207;52;103(?:;[0-9;]*)?m", output), "Python icon RGB color was not sent to the terminal"
            print(result)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            os.close(master)


if __name__ == "__main__":
    run_case("tui")
    run_case("preview_tui")
    run_case("lazy_tui")
    run_case("item_icons_tui")
    run_case("match_tui")
    run_case("grep_tui")
    run_case("grep_columns_tui")
    run_case("workflows_tui")
    run_case("syntax_tui")
    if shutil.which("git"):
        run_case("git_tui")
    if shutil.which("chafa") and shutil.which("rsvg-convert"):
        run_case("images_tui")
    else:
        print("SKIP image terminal integration (chafa/rsvg-convert not installed)")
    if shutil.which("sk"):
        run_case("skim_tui")
    else:
        print("SKIP skim terminal integration (sk not installed)")
