"""The README keeps up with the server: every tool is documented, counts match.

The README once said 30 report tools and 3 charts long after both had grown;
these checks turn that drift into a CI failure.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from teslamate_mcp.config import Settings
from teslamate_mcp.server import create_server
from teslamate_mcp.tools.apps_ui import APP_SPECS
from teslamate_mcp.tools.registry import discover_predefined_tools

_README = (Path(__file__).resolve().parents[1] / "README.md").read_text(encoding="utf-8")
_DUMMY_DB_URL = "postgresql://teslamate:secret@example.test/teslamate"


@pytest.mark.asyncio
async def test_readme_documents_every_tool_and_prompt() -> None:
    mcp = create_server(Settings(database_url=_DUMMY_DB_URL, enable_charging_writes=True))  # type: ignore[call-arg]
    names = {t.name for t in await mcp.list_tools()} | {p.name for p in await mcp.list_prompts()}
    missing = sorted(n for n in names if f"`{n}`" not in _README)
    assert not missing, f"not in README.md: {missing}"


@pytest.mark.asyncio
async def test_readme_counts_match() -> None:
    mcp = create_server(Settings(database_url=_DUMMY_DB_URL))  # type: ignore[call-arg]
    tools, prompts = await mcp.list_tools(), await mcp.list_prompts()
    intro = re.search(r"(\d+) tools, (\d+) prompts", _README)
    assert intro, "README intro lost its tool and prompt counts"
    assert (int(intro.group(1)), int(intro.group(2))) == (len(tools), len(prompts))
    reports = re.search(r"\*\*(\d+) SQL report tools\.\*\*", _README)
    assert reports and int(reports.group(1)) == len(discover_predefined_tools())
    charts = re.search(r"\*\*(\d+) interactive charts", _README)
    assert charts and int(charts.group(1)) == len(APP_SPECS)
    section = re.search(r"### Charts \((\d+)\)", _README)
    assert section and int(section.group(1)) == len(APP_SPECS)


@pytest.mark.asyncio
async def test_unraid_docs_counts_match() -> None:
    """The Unraid guide said 25, 26, and 27 tools while the server had 78."""
    unraid = Path(__file__).resolve().parents[1] / "deploy" / "unraid"
    mcp = create_server(Settings(database_url=_DUMMY_DB_URL))  # type: ignore[call-arg]
    tools, prompts = len(await mcp.list_tools()), len(await mcp.list_prompts())

    template = (unraid / "teslamate-mcp.xml").read_text(encoding="utf-8")
    overview = re.search(
        r"(\d+) tools \((\d+) predefined[^)]*?(\d+) interactive[^)]*\), (\d+) prompts",
        template,
        re.DOTALL,
    )
    assert overview, "Unraid template overview lost its counts"
    assert tuple(map(int, overview.groups())) == (
        tools,
        len(discover_predefined_tools()),
        len(APP_SPECS),
        prompts,
    )

    guide = (unraid / "UNRAID_CLOUDFLARE_DEPLOYMENT.md").read_text(encoding="utf-8")
    counts = {int(n) for n in re.findall(r"(\d+) tools", guide)}
    # The write tool is opt-in, so the guide names both totals.
    assert counts == {tools, tools + 1}, sorted(counts)
    listed = re.search(r"(\d+) prompts", guide)
    assert listed and int(listed.group(1)) == prompts
