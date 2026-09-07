"""Quoting the stdio command mcp-proxy runs, per platform.

mcp-proxy spawns with Node's `shell: true`, so the command string is parsed by
/bin/sh on POSIX and cmd.exe on Windows. cmd.exe does not understand single quotes,
which made every stdio MCP on Windows fail to start: the child exited immediately
with "The filename, directory name, or volume label syntax is incorrect".
"""

from __future__ import annotations

from ao_reach.local_mcp_host import _cmd_quote, _posix_quote


def _join(quoter, args: list[str]) -> str:
    return " ".join(quoter(a) for a in args)


def test_cmd_leaves_a_plain_windows_path_alone():
    """Backslashes are safe for cmd.exe, and unquoted paths keep logs readable."""
    assert _cmd_quote(r"C:\Python312\python.exe") == r"C:\Python312\python.exe"


def test_cmd_double_quotes_a_path_with_spaces():
    assert _cmd_quote(r"C:\Program Files\Python\python.exe") == r'"C:\Program Files\Python\python.exe"'


def test_cmd_never_emits_a_single_quote():
    """The actual regression: cmd.exe treats 'C:\\...' as a literal filename."""
    quoted = _join(_cmd_quote, [r"C:\Users\me\AppData\Local\python.exe", "-m", "pkg.module"])

    assert "'" not in quoted
    assert quoted == r"C:\Users\me\AppData\Local\python.exe -m pkg.module"


def test_cmd_doubles_an_embedded_double_quote():
    assert _cmd_quote('say "hi"') == '"say ""hi"""'


def test_cmd_quotes_an_empty_argument():
    assert _cmd_quote("") == '""'


def test_posix_quoting_is_unchanged():
    assert _posix_quote("/usr/bin/python3") == "/usr/bin/python3"
    assert _posix_quote("/opt/my apps/python3") == "'/opt/my apps/python3'"
    assert _posix_quote("") == "''"
    assert _posix_quote("it's") == "'it'\"'\"'s'"


def test_both_shells_survive_a_module_launch():
    posix = _join(_posix_quote, ["/usr/bin/python3", "-m", "ao_reach.demo"])
    windows = _join(_cmd_quote, [r"C:\Py\python.exe", "-m", "ao_reach.demo"])

    assert posix == "/usr/bin/python3 -m ao_reach.demo"
    assert windows == r"C:\Py\python.exe -m ao_reach.demo"
