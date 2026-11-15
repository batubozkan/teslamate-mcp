-- start_date is stored as naive UTC. Compared with a bare now(), PostgreSQL
-- reads it in the session time zone and shifts both windows by that offset,
-- so now() is taken in UTC throughout.
--
-- Drives are finished drives and sessions are finished charges that added
-- energy, as in the other tools. A cost is null, not 0, when no session in
-- the window has one recorded.
WITH win AS (
    SELECT (now() AT TIME ZONE 'UTC') - make_interval(days => %(days)s::int) AS cur_start,
        (now() AT TIME ZONE 'UTC') - make_interval(days => 2 * %(days)s::int) AS prev_start
),
drive_stats AS (
    SELECT
        COALESCE(SUM(d.distance) FILTER (WHERE d.start_date >= w.cur_start), 0) AS cur_distance,
        COALESCE(SUM(d.distance) FILTER (WHERE d.start_date < w.cur_start), 0) AS prev_distance,
        COUNT(*) FILTER (WHERE d.start_date >= w.cur_start) AS cur_drives,
        COUNT(*) FILTER (WHERE d.start_date < w.cur_start) AS prev_drives
    FROM drives d
        JOIN cars c ON d.car_id = c.id
        CROSS JOIN win w
    WHERE d.end_date IS NOT NULL
        AND d.start_date >= w.prev_start
        AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
),
charge_stats AS (
    SELECT
        COALESCE(SUM(cp.charge_energy_added) FILTER (WHERE cp.start_date >= w.cur_start), 0)
            AS cur_kwh,
        COALESCE(SUM(cp.charge_energy_added) FILTER (WHERE cp.start_date < w.cur_start), 0)
            AS prev_kwh,
        SUM(cp.cost) FILTER (WHERE cp.start_date >= w.cur_start) AS cur_cost,
        SUM(cp.cost) FILTER (WHERE cp.start_date < w.cur_start) AS prev_cost,
        COUNT(*) FILTER (WHERE cp.start_date >= w.cur_start) AS cur_sessions,
        COUNT(*) FILTER (WHERE cp.start_date < w.cur_start) AS prev_sessions,
        COUNT(*) FILTER (WHERE cp.start_date >= w.cur_start AND cp.cost IS NULL) AS cur_uncosted,
        COUNT(*) FILTER (WHERE cp.start_date < w.cur_start AND cp.cost IS NULL) AS prev_uncosted
    FROM charging_processes cp
        JOIN cars c ON cp.car_id = c.id
        CROSS JOIN win w
    WHERE cp.end_date IS NOT NULL
        AND cp.charge_energy_added > 0
        AND cp.start_date >= w.prev_start
        AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
)
SELECT 'distance_km' AS metric,
    ROUND(ds.cur_distance::numeric, 1) AS current_value,
    ROUND(ds.prev_distance::numeric, 1) AS previous_value,
    ROUND(100 * (ds.cur_distance - ds.prev_distance)::numeric
        / NULLIF(ds.prev_distance::numeric, 0), 1) AS change_pct
FROM drive_stats ds
UNION ALL
SELECT 'drive_count',
    ds.cur_drives::numeric,
    ds.prev_drives::numeric,
    ROUND(100 * (ds.cur_drives - ds.prev_drives)::numeric / NULLIF(ds.prev_drives::numeric, 0), 1)
FROM drive_stats ds
UNION ALL
SELECT 'kwh_added',
    ROUND(cs.cur_kwh::numeric, 1),
    ROUND(cs.prev_kwh::numeric, 1),
    ROUND(100 * (cs.cur_kwh - cs.prev_kwh)::numeric / NULLIF(cs.prev_kwh::numeric, 0), 1)
FROM charge_stats cs
UNION ALL
SELECT 'charge_cost',
    ROUND(cs.cur_cost::numeric, 2),
    ROUND(cs.prev_cost::numeric, 2),
    ROUND(100 * (cs.cur_cost - cs.prev_cost)::numeric / NULLIF(cs.prev_cost::numeric, 0), 1)
FROM charge_stats cs
UNION ALL
SELECT 'charge_sessions',
    cs.cur_sessions::numeric,
    cs.prev_sessions::numeric,
    ROUND(100 * (cs.cur_sessions - cs.prev_sessions)::numeric
        / NULLIF(cs.prev_sessions::numeric, 0), 1)
FROM charge_stats cs
UNION ALL
-- How much of charge_cost is missing: sessions with no recorded cost.
SELECT 'charge_sessions_without_cost',
    cs.cur_uncosted::numeric,
    cs.prev_uncosted::numeric,
    NULL::numeric
FROM charge_stats cs;
