-- Latest position with range data per car via a LATERAL top-1.
--
-- Rows streamed while driving carry no range or usable battery level, so the
-- plain latest row often read null in every range column (and for a car whose
-- last logged row was a streamed one, always). TeslaMate fills them on polled
-- rows only; the ideal-range test picks those and lets the lookup use its
-- partial (car_id, date) index.
--
-- The previous form filtered with
--   WHERE p.date = (SELECT MAX(date) FROM positions p2 WHERE p2.car_id = p.car_id)
-- which re-scanned the whole positions table once per candidate row. On a
-- 3M-row table the planner costed that at ~2.6e11 and it never completed.
-- Driving from `cars` also lets the car_name filter cut the set before any
-- positions lookup happens.
SELECT c.name as car_name,
    p.battery_level,
    p.usable_battery_level,
    p.rated_battery_range_km,
    p.ideal_battery_range_km,
    p.est_battery_range_km,
    -- Range at 100 %% now against the best the car has shown. The rated to
    -- ideal range ratio this column used to hold is a constant of the car
    -- model (100 on every car seen), so it said nothing about the battery.
    ROUND(LEAST(100 * full_range.range_at_100_km / NULLIF(best_range.best_range_at_100_km, 0),
        100)::numeric, 1) as battery_health_pct,
    full_range.range_at_100_km,
    best_range.best_range_at_100_km,
    cap.capacity_kwh AS est_capacity_kwh,
    cap.sessions AS capacity_sessions,
    ROUND(totals.ac_kwh::numeric, 1) AS ac_energy_added_kwh,
    ROUND(totals.dc_kwh::numeric, 1) AS dc_energy_added_kwh,
    ROUND(((totals.ac_kwh + totals.dc_kwh) / NULLIF(cap.capacity_kwh, 0))::numeric, 1)
        AS charge_cycles
FROM cars c
    -- LEFT: a car with no such row still gets its charging-based columns.
    LEFT JOIN LATERAL (
        SELECT *
        FROM positions p
        WHERE p.car_id = c.id
            AND p.ideal_battery_range_km IS NOT NULL
        ORDER BY p.date DESC
        LIMIT 1
    ) p ON true
    -- Range at 100 %% from the newest charges that ended at 50 %% or more:
    -- scaling a low battery level up to 100 %% magnifies its rounding.
    CROSS JOIN LATERAL (
        SELECT ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
                ORDER BY cp.end_rated_range_km * 100 / cp.end_battery_level)::numeric, 1)
                AS range_at_100_km
        FROM (
            SELECT end_rated_range_km, end_battery_level
            FROM charging_processes
            WHERE car_id = c.id
                AND end_date IS NOT NULL
                AND end_battery_level >= 50
                AND end_rated_range_km > 0
            ORDER BY end_date DESC
            LIMIT 5
        ) cp
    ) full_range
    -- The best range at 100 %%: the 95th percentile of the same readings over
    -- the car's whole history, so one lucky rounding does not set the bar.
    CROSS JOIN LATERAL (
        SELECT ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (
                ORDER BY cp.end_rated_range_km * 100 / cp.end_battery_level)::numeric, 1)
                AS best_range_at_100_km
        FROM charging_processes cp
        WHERE cp.car_id = c.id
            AND cp.end_date IS NOT NULL
            AND cp.end_battery_level >= 50
            AND cp.end_rated_range_km > 0
    ) best_range
    -- Usable capacity: the median energy added per battery percent over the
    -- newest ten charges that gained 40 points or more. The same energy per
    -- percent that get_battery_capacity_trend averages per month, with a
    -- stricter gain and a median.
    CROSS JOIN LATERAL (
        SELECT ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
                ORDER BY cp.charge_energy_added * 100
                    / (cp.end_battery_level - cp.start_battery_level))::numeric, 1)
                AS capacity_kwh,
            COUNT(*) AS sessions
        FROM (
            SELECT charge_energy_added, start_battery_level, end_battery_level
            FROM charging_processes
            WHERE car_id = c.id
                AND end_date IS NOT NULL
                AND charge_energy_added > 0
                AND end_battery_level - start_battery_level >= 40
            ORDER BY end_date DESC
            LIMIT 10
        ) cp
    ) cap
    -- A session is DC when a charge sample came from a fast charger, as in
    -- get_charging_efficiency.
    CROSS JOIN LATERAL (
        SELECT COALESCE(SUM(cp.charge_energy_added) FILTER (WHERE NOT k.is_dc), 0) AS ac_kwh,
            COALESCE(SUM(cp.charge_energy_added) FILTER (WHERE k.is_dc), 0) AS dc_kwh
        FROM charging_processes cp
            CROSS JOIN LATERAL (
                SELECT EXISTS (
                    SELECT 1
                    FROM charges ch
                    WHERE ch.charging_process_id = cp.id
                        AND (ch.fast_charger_present
                            OR (ch.charger_phases IS NULL AND ch.charger_power > 0))
                ) AS is_dc
            ) k
        WHERE cp.car_id = c.id
            AND cp.charge_energy_added > 0
    ) totals
WHERE (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%');
