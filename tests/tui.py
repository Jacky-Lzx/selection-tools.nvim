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
        configured = case in {"undo_tui", "delta_preview_tui", "workflows_tui", "labels_tui", "preview_scroll_tui", "opening_tui", "mouse_tui", "mouse_interaction_tui"} and env.get("SELECTION_TOOLS_CONFIGURED") == "1"
        if configured:
            env.update(NVIM_SMOKE_TEST="1", XDG_STATE_HOME=directory + "/state", XDG_CACHE_HOME=directory + "/cache")
        init = [] if configured else ["-u", "NONE"]
        process = subprocess.Popen(
            [shutil.which("nvim") or "nvim", *init, "-n", "-i", "NONE", "-c", "lua dofile('tests/" + case + ".lua')"],
            cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
        )
        os.close(slave)
        actions = {"type_long": b"x" * 200, "type": b"\x15bta", "move": b"\x0e", "confirm": b"\r", "cancel": b"\x1b"}
        if case == "labels_tui":
            actions.update(type=b"beta")
        if case == "skim_tui":
            actions.update(prefix=b"b", suffix=b"ta", select=b"\t")
        if case == "image_tools_tui":
            actions.update(expand=b"\x1bOR", type_text=b"text", clear_text=b"\x15", move_again=b"\x0e", pdf=b"\x0e")
        if case == "workflows_tui":
            actions.update(hidden=b"\x1bh", ignored=b"\x1bi", open_files=b" sf", regex=b"\x1br", literal=b"\x1br", scope=b"\x1bf",
                           scope_value=b"\x15" + (directory + "/sub").encode() + b"\r", export=b"\x11", expand=b"\x1bOR", collapse=b"\x1bOR", details=b"\x1bOQ", details_close=b"q", split=b"\x16")
        if case == "grep_columns_tui":
            actions.update(type=b"needle", resize_narrow=b"", resize_tiny=b"", resize_wide=b"")
        if case == "components_tui":
            actions.update(type=b"needle", select=b"\t", resize_narrow=b"", resize_tiny=b"", resize_wide=b"")
        if case == "grep_tui":
            actions.update(type=b"hel")
        if case == "live_tui":
            actions.update(type=b"a", type_again=b"b", type_last=b"c", type_empty=b"x")
        if case == "match_tui":
            actions.update(type=b"png")
        if case == "item_icons_tui":
            actions.update(select=b"\t", unselect=b"\x0e\t", reselect=b"\x0e\t", copy=b"\x19")
        if case == "lazy_tui":
            actions.update(type_again=b"bta", close_warm=b"\x1b")
        if case == "preview_tui":
            actions.update(move_again=b"\x0e")
        if case == "preview_scroll_tui":
            direction = b"\x10" if configured else b"\x0e"
            actions.update(scroll_down=b"\x04", scroll_bottom=b"\x04" * 30, scroll_up=b"\x15",
                           expand=b"\x1bOR", collapse=b"\x1bOR", resize_narrow=b"", resize_wide=b"",
                           native_top=b"\x07", short=direction, delta=direction, delta_scroll=b"\x04")
        if case == "undo_tui":
            direction = b"\x10" if env.get("SELECTION_TOOLS_CONFIGURED") == "1" else b"\x0e"
            clear = b"\x1bOH" + b"\x1b[3~" * len("no-such-undo-version")
            replace_saved = b"\x1bOH" + b"\x1b[3~" * len("saved")
            actions.update(open=b" su", reopen=b" su", filter=b"saved", zero=replace_saved + b"no-such-undo-version", clear=clear,
                           move=direction, move_again=direction, move_final=direction,
                           compare_current=b"\x1bOS", compare_parent=b"\x1bOS",
                           resize_narrow=b"", resize_tiny=b"", resize_wide=b"")
        if case == "delta_preview_tui":
            direction = b"\x10" if configured else b"\x0e"
            actions.update(move=direction, move_again=direction, move_latest=direction, resize_narrow=b"")
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
                    if case in {"components_tui", "grep_columns_tui", "undo_tui", "delta_preview_tui", "preview_scroll_tui"} and stage.startswith("resize_"):
                        columns = {"resize_narrow": 48, "resize_tiny": 16, "resize_wide": 120}[stage]
                        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, columns, 0, 0))
                        os.kill(process.pid, signal.SIGWINCH)
                    else:
                        os.write(master, actions[stage])
                    handled.add(stage)
                elif case == "mouse_interaction_tui" and stage.startswith("mouse_") and stage not in handled:
                    os.write(master, Path(directory, "mouse_input").read_bytes())
                    handled.add(stage)
                elif case == "mouse_tui" and stage.startswith("click_") and stage not in handled:
                    col, row = map(int, Path(directory, "mouse").read_text().split())
                    os.write(master, (f"\x1b[<0;{col};{row}M\x1b[<0;{col};{row}m").encode())
                    handled.add(stage)
                elif case == "preview_scroll_tui" and stage in {"scroll_mouse", "scroll_mouse_delta"} and stage not in handled:
                    col, row = map(int, Path(directory, "mouse").read_text().split())
                    os.write(master, (f"\x1b[<65;{col};{row}M").encode())
                    handled.add(stage)
            if process.poll() is None:
                process.kill()
                raise AssertionError("Terminal test timed out; stages: " + repr(handled) + "\n" + output.decode(errors="replace")[-3000:])
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
    run_case("components_tui")
    run_case("opening_tui")
    run_case("tui")
    run_case("mouse_tui")
    run_case("mouse_interaction_tui")
    run_case("preview_tui")
    run_case("preview_scroll_tui")
    run_case("lazy_tui")
    run_case("item_icons_tui")
    run_case("match_tui")
    run_case("grep_tui")
    run_case("live_tui")
    run_case("grep_columns_tui")
    run_case("workflows_tui")
    run_case("labels_tui")
    run_case("syntax_tui")
    git_tools = os.environ.get("GIT_TOOLS_DIR", str(Path(__file__).resolve().parents[2] / "git-tools.nvim"))
    if shutil.which("delta") and Path(git_tools, "lua/git_tools/diff/init.lua").exists():
        run_case("undo_tui")
        run_case("delta_preview_tui")
    else:
        print("SKIP undo delta terminal integration (install delta and set GIT_TOOLS_DIR)")
    if os.environ.get("IMAGE_TOOLS_ROOT"):
        run_case("image_tools_tui")
    else:
        print("SKIP image-tools terminal integration (set IMAGE_TOOLS_ROOT)")
    if shutil.which("sk"):
        run_case("skim_tui")
    else:
        print("SKIP skim terminal integration (sk not installed)")
