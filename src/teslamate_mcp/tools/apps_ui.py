"""MCP Apps extension: interactive charts rendered in-conversation.

Each `AppSpec` binds a bundled query to a self-contained HTML app
(ext-apps spec 2026-01-26) that the host renders in a sandboxed iframe.
Per SEP-2133 every app tool degrades gracefully: it returns the same rows
as its backing `get_*` query tool, so clients that did not negotiate the
Apps extension still get the data.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from functools import cache
from importlib.resources import files

from mcp.server.apps import Apps
from mcp.types import ToolAnnotations

from .registry import PredefinedTool, make_query_handler


@cache
def _load_app_html(filename: str) -> str:
    return files("teslamate_mcp").joinpath("apps", filename).read_text(encoding="utf-8")


@cache
def _html_fingerprint(filename: str) -> str:
    return hashlib.sha256(_load_app_html(filename).encode("utf-8")).hexdigest()[:12]


@dataclass(frozen=True)
class AppSpec:
    """One UI-bound tool: a bundled query rendered by a bundled HTML app."""

    tool_name: str
    query_name: str
    base_uri: str
    html_file: str
    resource_name: str
    resource_title: str
    resource_description: str
    tool_description: str

    @property
    def uri(self) -> str:
        """The served `ui://` URI, fingerprinted with the view's content.

        Hosts cache a view by its URI, so an unchanged URI kept serving a stale
        copy after a server upgrade (claude.ai kept running a view whose
        handshake a later release had fixed). A content hash in the path gives
        every changed view a new URI and leaves unchanged ones cacheable.
        """
        scheme_host, _, name = self.base_uri.rpartition("/")
        return f"{scheme_host}/{_html_fingerprint(self.html_file)}/{name}"


APP_SPECS: tuple[AppSpec, ...] = (
    AppSpec(
        tool_name="show_charging_curve",
        query_name="get_charging_curve",
        base_uri="ui://teslamate/charging-curve.html",
        html_file="charging_curve.html",
        resource_name="charging_curve_chart",
        resource_title="Charging curve chart",
        resource_description=(
            "Interactive battery-level and charging-power chart for one session."
        ),
        tool_description=(
            "Render an interactive charging-curve chart for one charging session, "
            "displayed directly in the conversation (battery level and charging "
            "power over time, with hover readouts and a data table). Returns the "
            "same rows as get_charging_curve, so it also works as a plain data "
            "tool. Prefer this over get_charging_curve when the user wants to SEE "
            "the curve. Find session ids with search_charging_sessions."
        ),
    ),
    AppSpec(
        tool_name="show_battery_degradation",
        query_name="get_battery_degradation_over_time",
        base_uri="ui://teslamate/battery-degradation.html",
        html_file="battery_degradation.html",
        resource_name="battery_degradation_chart",
        resource_title="Battery degradation chart",
        resource_description=("Interactive monthly rated-range trend chart, one line per car."),
        tool_description=(
            "Render an interactive battery-degradation trend chart, displayed "
            "directly in the conversation (monthly average and best rated range "
            "at full charge, one line per car, with hover readouts and a data "
            "table). Returns the same rows as get_battery_degradation_over_time, "
            "so it also works as a plain data tool. Prefer this over "
            "get_battery_degradation_over_time when the user wants to SEE the "
            "trend."
        ),
    ),
    AppSpec(
        tool_name="show_drive_route",
        query_name="get_drive_route",
        base_uri="ui://teslamate/drive-route.html",
        html_file="drive_route.html",
        resource_name="drive_route_map",
        resource_title="Drive route map",
        resource_description=(
            "Interactive GPS route map with speed and battery readouts for one drive."
        ),
        tool_description=(
            "Render an interactive route map for one drive, displayed directly "
            "in the conversation (the GPS track with start/end markers, hover "
            "readouts for time, speed, and battery, and a waypoint table). "
            "Returns the same rows as get_drive_route, so it also works as a "
            "plain data tool. Prefer this over get_drive_route when the user "
            "wants to SEE the route. Find drive ids with search_drives."
        ),
    ),
)

CHARGING_CURVE_APP_URI = APP_SPECS[0].uri

# The ext-apps reference SDK (registerAppTool) stamps both `_meta.ui.resourceUri`
# and this deprecated flat key, because hosts that predate the nested form only
# read the flat one. The Python SDK's Apps.tool() writes only the nested form,
# so add the flat key ourselves to match what hosts are tested against.
LEGACY_RESOURCE_URI_META_KEY = "ui/resourceUri"


# History (0.8.0 → 0.9.1): a ResourceLinkedApps subclass used to prepend a
# result-level `resource_link` block as a second rendering signal. It never
# triggered chart rendering, and newer Claude Desktop builds surface a visible
# "Resource links are not currently supported" notice for the block instead of
# ignoring it — so app tools now rely solely on the spec's tool-level
# `_meta.ui.resourceUri` binding. Do not re-add the result-level link.


def build_apps_extension(tools: list[PredefinedTool], *, report_timezone: str) -> Apps:
    """Build the Apps extension; pass the result to MCPServer(extensions=[...]).

    Each app tool reuses its backing query via make_query_handler, so the
    chart and the plain `get_*` tool can never drift apart (same params,
    same tz injection, same typed output schema).
    """
    by_name = {t.name: t for t in tools}

    apps = Apps()

    annotations = ToolAnnotations(
        read_only_hint=True,
        destructive_hint=False,
        idempotent_hint=True,
        open_world_hint=False,
    )

    for spec in APP_SPECS:
        query = by_name.get(spec.query_name)
        if query is None:  # fail fast, like a missing .toml sidecar
            raise RuntimeError(
                f"MCP Apps: bundled query '{spec.query_name}' not found; "
                f"required by {spec.tool_name} — its .sql/.toml must exist in queries/"
            )
        handler = make_query_handler(query, report_timezone=report_timezone)
        handler.__name__ = spec.tool_name
        handler.__doc__ = spec.tool_description
        apps.tool(
            resource_uri=spec.uri,
            meta={LEGACY_RESOURCE_URI_META_KEY: spec.uri},
            name=spec.tool_name,
            description=spec.tool_description,
            annotations=annotations,
        )(handler)
        apps.add_html_resource(
            spec.uri,
            _load_app_html(spec.html_file),
            name=spec.resource_name,
            title=spec.resource_title,
            description=spec.resource_description,
            prefers_border=True,
        )
    return apps
