"""One definition per notion across the tools (0.19.0): what a drive and a
session are, what "last N days" means, what a cost of nothing is, and which
name a place gets. Against cars 19 and 20 (conftest._AUDIT_SQL)."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from mcp import Client

from teslamate_mcp.config import Settings
from teslamate_mcp.server import create_server

_CAR = "Auditor"
_SECOND = "Second Audit"


async def _rows(session, tool: str, **args) -> list[dict]:
    result = await session.call_tool(tool, args)
    assert not result.is_error, [getattr(c, "text", c) for c in result.content]
    return result.structured_content["result"]


async def test_status_reads_range_from_the_last_full_reading(mcp_session) -> None:
    async with mcp_session(seeds=["audit"]) as session:
        (row,) = await _rows(session, "get_current_car_status", car_name=_CAR)

    # The newest row is a streamed one: position, odometer and battery level
    # come from it, range, outside temperature and climate from the polled row.
    assert (row["battery_level"], row["odometer"], row["latitude"]) == (54, 5083.0, 40.51)
    assert (row["rated_battery_range_km"], row["outside_temp"], row["is_climate_on"]) == (
        250.0,
        11.0,
        False,
    )
    assert row["range_at"] < row["last_update"]
    assert row["car_state"] is None  # no state rows seeded; the drive is not counted anywhere


async def test_unclosed_session_does_not_hide_later_parking_gaps(mcp_session) -> None:
    async with mcp_session(seeds=["audit"]) as session:
        drain = await _rows(session, "get_vampire_drain", car_name=_CAR)
        checks = {
            r["check_name"]: r for r in await _rows(session, "get_health_checks", car_name=_CAR)
        }
        gaps = await _rows(session, "get_logging_gaps", car_name=_CAR, min_hours=6)

    # The gap between E and F, a day after session 1904 stopped logging.
    assert [(r["range_loss_km"], r["location"]) for r in drain] == [(3.0, "Villa")]
    assert checks["parked_drain"]["value"] is not None
    # 1904 is lost; 1905 started 8 hours ago but is still logging.
    assert checks["open_records"]["value"] == 1
    assert [(r["gap_kind"], r["record_id"]) for r in gaps if r["gap_kind"] == "open_charge"] == [
        ("open_charge", 1904)
    ]


async def test_unusual_consumption_leaves_out_short_drives(mcp_session) -> None:
    async with mcp_session(seeds=["audit"]) as session:
        rows = await _rows(session, "get_unusual_power_consumption", car_name=_CAR)
        with_short = await _rows(
            session, "get_unusual_power_consumption", car_name=_CAR, min_distance_km=0
        )

    assert [(r["distance"], r["consumption_pct"]) for r in rows] == [(40.0, 200.0)]
    assert (rows[0]["start_location"], rows[0]["end_location"]) == ("Villa", "Far Cafe")
    # The 1 km drive that dropped the range 3 km only shows when asked for.
    assert [r["distance"] for r in with_short] == [1.0, 40.0]


async def test_efficiency_tools_report_consumption(mcp_session) -> None:
    async with mcp_session(seeds=["audit"]) as session:
        (total,) = await _rows(session, "get_total_distance_and_efficiency", car_name=_CAR)
        monthly = await _rows(session, "get_efficiency_by_month_and_temperature", car_name=_CAR)

    # 123 km of rated range x 0.15 kWh/km over 81 km driven.
    assert (total["total_drives"], total["total_distance_km"], total["wh_per_km"]) == (5, 81.0, 228)
    assert sum(r["drive_count"] for r in monthly) == 5
    assert all(100 <= r["wh_per_km"] <= 300 for r in monthly)


async def test_battery_health_is_range_now_against_the_best(mcp_session) -> None:
    async with mcp_session(seeds=["audit"]) as session:
        (row,) = await _rows(session, "get_battery_health_summary", car_name=_CAR)

    # Range at 100 %: 330, 300 and 290 km from the three charges that ended at
    # 50 % or more. The median is "now", the 95th percentile the best.
    assert (row["range_at_100_km"], row["best_range_at_100_km"]) == (300.0, 327.0)
    assert row["battery_health_pct"] == 91.7


async def test_visits_merge_a_geofence_into_one_place(mcp_session) -> None:
    async with mcp_session(seeds=["audit"]) as session:
        places = await _rows(session, "get_visited_places", car_name=_CAR)
        most = await _rows(session, "get_most_visited_locations", car_name=_CAR)
        charging = await _rows(session, "get_charging_by_location", car_name=_CAR)

    # Arrivals at Villa Road 1 and Villa Road 3 are one place, at the
    # geofence's center, with both of its sessions.
    assert [
        (r["location"], r["arrivals"], r["latitude"], r["longitude"], r["charging_sessions"])
        for r in places
    ] == [("Villa", 3, 40.0, 30.0, 2), ("Far Cafe", 2, 40.5, 30.5, 1)]
    # The drive inside the Villa counts there once, not as a start and an end.
    assert [(r["location"], r["visit_count"]) for r in most] == [("Villa", 5), ("Far Cafe", 4)]
    assert [(r["location"], r["sessions"], r["city"]) for r in charging] == [
        ("Villa", 2, "Bolu"),
        ("Far Cafe", 1, "Duzce"),
    ]


async def test_named_sessions_are_all_compared(mcp_session) -> None:
    ids = ",".join(str(2000 + n) for n in range(1, 8))
    async with mcp_session(seeds=["audit"]) as session:
        named = await _rows(session, "get_charging_curve_comparison", charging_process_ids=ids)
        picked = await _rows(session, "get_charging_curve_comparison", car_name=_SECOND)

    assert len({r["charging_process_id"] for r in named}) == 7
    assert len({r["charging_process_id"] for r in picked}) == 5  # the default limit


async def test_last_n_days_is_a_rolling_utc_window(seeded_database, mcp_session) -> None:
    async with mcp_session(seeds=["audit"]):
        pass  # seed only
    separator = "&" if "?" in seeded_database else "?"
    tokyo = f"{seeded_database}{separator}options=-c%20timezone%3DAsia%2FTokyo"
    mcp = create_server(Settings(database_url=tokyo))  # type: ignore[call-arg]
    try:
        async with Client(mcp, raise_exceptions=False) as session:
            (total,) = await _rows(
                session, "get_total_distance_and_efficiency", car_name=_SECOND, days=1
            )
            longest = await _rows(
                session, "get_longest_drives_by_distance", car_name=_SECOND, days=1
            )
            per_day = await _rows(session, "get_drive_summary_per_day", car_name=_SECOND, days=2)
    finally:
        await mcp.teslamate_app_context.pool.close()  # type: ignore[attr-defined]

    # One day back reaches the drive 23 hours ago and not the one 25 hours ago,
    # whatever the database session's time zone and the time of day.
    assert (total["total_drives"], total["total_distance_km"]) == (1, 15.0)
    assert [r["distance_km"] for r in longest] == [15.0]
    # The open drive is not a drive; a day tool takes the whole first day.
    assert sum(r["drive_count"] for r in per_day) == 2


async def test_monthly_tools_start_at_the_first_of_the_month(mcp_session) -> None:
    month = (datetime.now(UTC) - timedelta(days=40)).strftime("%Y-%m")
    async with mcp_session(seeds=["audit"]) as session:
        monthly = await _rows(session, "get_monthly_driving_summary", car_name=_SECOND, days=40)
        odometer = await _rows(session, "get_odometer_history", car_name=_SECOND, days=40)

    # The drive at noon on the first of that month is in, though "40 days ago"
    # falls later in the month: the first month is a whole one.
    first = min(monthly, key=lambda r: r["month"])
    assert first["month"].startswith(month)
    assert (first["total_trips"], first["total_distance_km"]) == (1, 9.0)
    assert odometer[0]["month"] == month
    assert odometer[0]["distance_km"] == 9.0


async def test_unknown_cost_is_null_and_counted(mcp_session) -> None:
    async with mcp_session(seeds=["audit"]) as session:
        (summary,) = await _rows(session, "get_all_charging_sessions_summary", car_name=_CAR)
        (uncosted,) = await _rows(session, "get_all_charging_sessions_summary", car_name=_SECOND)
        by_place = {
            r["group_key"]: r
            for r in await _rows(session, "get_charging_costs", car_name=_CAR, group_by="location")
        }
        comparison = {
            r["metric"]: r for r in await _rows(session, "get_period_comparison", car_name=_CAR)
        }
        blank = {
            r["metric"]: r for r in await _rows(session, "get_period_comparison", car_name=_SECOND)
        }

    assert (summary["total_charging_cost"], summary["sessions_without_cost"]) == (9.9, 2)
    # No session of the second car has a cost: unknown, not 0.
    assert (uncosted["total_charging_cost"], uncosted["sessions_without_cost"]) == (None, 7)
    # 9.90 over the 33 kWh the charger delivered, not the 30 kWh that reached the battery.
    assert (by_place["Villa"]["total_cost"], by_place["Villa"]["avg_cost_per_kwh"]) == (9.9, 0.3)
    assert by_place["Villa"]["sessions_without_cost"] == 1
    assert by_place["Far Cafe"]["total_cost"] is None
    assert comparison["charge_cost"]["current_value"] == 9.9
    assert comparison["charge_sessions_without_cost"]["current_value"] == 1
    assert blank["charge_cost"]["current_value"] is None


async def test_a_session_is_a_finished_charge_that_added_energy(mcp_session) -> None:
    async with mcp_session(seeds=["audit"]) as session:
        found = await _rows(session, "search_charging_sessions", car_name=_CAR)
        (summary,) = await _rows(session, "get_all_charging_sessions_summary", car_name=_CAR)
        comparison = {
            r["metric"]: r for r in await _rows(session, "get_period_comparison", car_name=_CAR)
        }
        by_fence = {
            r["geofence"]: r
            for r in await _rows(session, "get_charging_by_geofence", car_name=_CAR)
        }

    # Not the empty 1903, the unclosed 1904, or 1905, which is still running.
    assert [r["charging_process_id"] for r in found] == [1902, 1901, 1900]
    assert summary["total_charging_sessions"] == 3
    assert comparison["charge_sessions"]["current_value"] == 2
    assert comparison["drive_count"]["current_value"] == 5
    assert by_fence["Villa"]["sessions"] == 2


async def test_location_filters_match_and_show_geofence_names(mcp_session) -> None:
    async with mcp_session(seeds=["audit"]) as session:
        sessions = await _rows(session, "search_charging_sessions", location="villa")
        drives = await _rows(session, "search_drives", location="villa")
        longest = await _rows(session, "get_longest_drives_by_distance", car_name=_CAR, limit=1)

    assert [(r["charging_process_id"], r["location"]) for r in sessions] == [
        (1902, "Villa"),
        (1901, "Villa"),
    ]
    assert [r["drive_id"] for r in drives] == [1905, 1904, 1903, 1902, 1901]
    inside = next(r for r in drives if r["drive_id"] == 1902)
    assert (inside["start_location"], inside["end_location"]) == ("Villa", "Villa")
    assert (longest[0]["start_location"], longest[0]["end_location"]) == ("Villa", "Far Cafe")
