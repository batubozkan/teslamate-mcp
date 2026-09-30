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

from mcp.server.apps import Apps, ResourceCsp
from mcp.types import ToolAnnotations

from .registry import PredefinedTool, make_query_handler

# Basemap for the drive-route view: Esri's light/dark gray canvas base layers
# (no labels, keyless), with the attribution the view draws. CARTO's keyless
# basemaps now answer every request with a "key required" placeholder tile.
# Fetching tiles tells Esri the rough area being viewed; MAP_TILES=false keeps
# the view fully self-contained.
MAP_TILE_HOST = "https://server.arcgisonline.com"
_MAP_TILE_PLACEHOLDER = "__MAP_TILE_HOST__"


@cache
def _load_app_html(filename: str) -> str:
    return files("teslamate_mcp").joinpath("apps", filename).read_text(encoding="utf-8")


def _uses_map_tiles(filename: str) -> bool:
    return _MAP_TILE_PLACEHOLDER in _load_app_html(filename)


@cache
def _render_app_html(filename: str, map_tiles: bool) -> str:
    """The view as served: the basemap host filled in, or "" when tiles are off."""
    host = MAP_TILE_HOST if map_tiles else ""
    return _load_app_html(filename).replace(_MAP_TILE_PLACEHOLDER, host)


@cache
def _html_fingerprint(filename: str, map_tiles: bool) -> str:
    html = _render_app_html(filename, map_tiles)
    return hashlib.sha256(html.encode("utf-8")).hexdigest()[:12]


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

    def uri_for(self, *, map_tiles: bool = True) -> str:
        """The served `ui://` URI, fingerprinted with the view as served.

        Hosts may cache a view by its URI, so an unchanged URI can keep serving
        a stale copy after a server upgrade or a settings change. A hash of the
        served document in the path gives every changed view a new URI and
        leaves unchanged ones cacheable.
        """
        scheme_host, _, name = self.base_uri.rpartition("/")
        return f"{scheme_host}/{_html_fingerprint(self.html_file, map_tiles)}/{name}"

    @property
    def uri(self) -> str:
        """The URI under default settings."""
        return self.uri_for()


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
    AppSpec(
        tool_name="show_trip_route",
        query_name="get_trip_route",
        base_uri="ui://teslamate/trip-route.html",
        html_file="trip_route.html",
        resource_name="trip_route_map",
        resource_title="Trip route map",
        resource_description=(
            "Interactive map of a multi-drive trip with its stops and charging stops."
        ),
        tool_description=(
            "Render an interactive map of a whole trip (several drives with "
            "stops in between), displayed directly in the conversation: the "
            "full GPS track, start/end markers, a marker at every stop with "
            "charging stops highlighted, hover readouts for time, leg, speed, "
            "battery and stop length, and a waypoint table. Returns the same "
            "rows as get_trip_route, so it also works as a plain data tool. "
            "Prefer this over get_trip_route when the user wants to SEE a trip. "
            "Find trip ids with get_trips."
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


def build_apps_extension(
    tools: list[PredefinedTool], *, report_timezone: str, map_tiles: bool = True
) -> Apps:
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
        uri = spec.uri_for(map_tiles=map_tiles)
        tiles = map_tiles and _uses_map_tiles(spec.html_file)
        apps.tool(
            resource_uri=uri,
            meta={LEGACY_RESOURCE_URI_META_KEY: uri},
            name=spec.tool_name,
            description=spec.tool_description,
            annotations=annotations,
        )(handler)
        apps.add_html_resource(
            uri,
            _render_app_html(spec.html_file, map_tiles),
            name=spec.resource_name,
            title=spec.resource_title,
            description=spec.resource_description,
            # Hosts deny all external loads unless declared; only images.
            csp=ResourceCsp(resource_domains=[MAP_TILE_HOST]) if tiles else None,
            prefers_border=True,
        )
    return apps
