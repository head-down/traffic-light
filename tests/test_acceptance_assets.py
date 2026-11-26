"""T08 验收资产契约测试：手工验收清单与只读验收脚本。

seam 是三个对外接口，而不是脚本内部实现：
  - `tests/manual/acceptance.ps1 -StateDir <空目录>`：只读盘点必须正常退出，
    并对任务/锚/绑定/状态四类各报一行 EMPTY；
  - `probe.ps1 -Verdict`：只输出一行 `hwnd=<十进制> class=<类名> size=<w>x<h> verdict=go|no-go`；
  - `docs/acceptance/per-window-lamp.md`：A/B/C/D 四条手工验收与失败排查路径。

脚本只在 Windows 上执行；文档契约在任何平台都可断言。
"""
import os
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
PWSH = "powershell.exe"
requires_windows = pytest.mark.skipif(os.name != "nt", reason="PowerShell 验收脚本仅 Windows 可执行")


def _run_ps(script, *args):
    cmd = [PWSH, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)]
    cmd.extend(str(a) for a in args)
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=180,
    )


@requires_windows
def test_acceptance_on_empty_state_dir_reports_empty_and_exits_zero(tmp_path):
    script = REPO / "tests" / "manual" / "acceptance.ps1"
    assert script.is_file(), "缺少只读验收脚本"

    result = _run_ps(
        script,
        "-StateDir", tmp_path / "no-such-state-dir",
        "-TasksFile", tmp_path / "no-tasks.json",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    out = result.stdout
    for kind in ("task", "anchor", "bind", "state"):
        assert re.search(rf"^{kind}\s+.*\bEMPTY\b", out, re.M | re.I), (
            "%s 一类在空目录下应报 EMPTY：\n%s" % (kind, out)
        )


@requires_windows
def test_probe_verdict_prints_exactly_one_parseable_line():
    script = REPO / "probe.ps1"
    result = _run_ps(script, "-Verdict")

    assert result.returncode == 0, result.stdout + result.stderr
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    assert len(lines) == 1, "probe -Verdict 只应输出一行：\n%s" % result.stdout
    assert re.fullmatch(
        r"hwnd=\d+ class=\S+ size=\d+x\d+ verdict=(go|no-go)", lines[0]
    ), lines[0]


def test_acceptance_doc_covers_the_four_checks():
    doc = REPO / "docs" / "acceptance" / "per-window-lamp.md"
    assert doc.is_file(), "缺少手工验收清单"

    text = doc.read_text(encoding="utf-8")
    for needle in ("验收 A", "验收 B", "验收 C", "验收 D",
                   "probe.ps1 -Verdict", "acceptance.ps1",
                   "taskkill /F", "/clear"):
        assert needle in text, "验收文档缺少：%s" % needle
