#!/usr/bin/env python3
"""Exercise actual terminal key input, using only Python's standard library."""
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
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
                    os.write(master, actions[stage])
                    handled.add(stage)
            if process.poll() is None:
                process.kill()
                raise AssertionError("Terminal test timed out; stages: " + repr(handled))
            result_file = Path(directory, "result")
            result = result_file.read_text().strip() if result_file.exists() else "No terminal test result"
            assert process.returncode == 0 and result.startswith("PASS"), result + "\n" + output.decode(errors="replace")[-3000:]
            print(result)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            os.close(master)


if __name__ == "__main__":
    run_case("tui")
    if shutil.which("sk"):
        run_case("skim_tui")
    else:
        print("SKIP skim terminal integration (sk not installed)")
