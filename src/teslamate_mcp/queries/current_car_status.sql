-- Newest position per car, in two steps, because `positions` has no index
-- that finds a car's newest row directly (only BRIN indexes and a b-tree on
-- car_id; the plain ORDER BY date DESC LIMIT 1 took over a second per car):
-- `pr` is the newest polled row, found through TeslaMate's partial
-- (car_id, date) index on rows with an ideal range, and `sr` is the newest
-- row logged after it. The search for `sr` stops 7 days after `pr`: the BRIN
-- index narrows a bounded date range, but an open-ended one reads every row
-- any car logged since (0.3 s for a car that last logged months ago).
-- Streamed rows without a polled one in between do not go on for days.
--
-- Rows streamed while driving or online carry position, speed, odometer and
-- battery level, but no range, outside temperature or climate state:
-- TeslaMate fills those on polled rows only. So range, outside temperature
-- and climate on/off come from the newest polled row (range_at says when
-- that was), and everything else from the newest row of either kind.
--
-- Cabin climate and tire values come from their own latest non-null rows,
-- searched no further than 7 days before the latest row, so a car that never
-- reports tires does not scan its whole history. The ideal-range test keeps
-- both lookups on the partial index; without it the plan cost passes
-- jit_above_cost, and JIT adds about 400 ms.
SELECT c.name as car_name,
    p.battery_level,
    pr.rated_battery_range_km,
    pr.date AS range_at,
    p.odometer,
    pr.outside_temp,
    pr.is_climate_on,
    cl.inside_temp,
    cl.driver_temp_setting,
    cl.passenger_temp_setting,
    cl.fan_status,
    cl.is_front_defroster_on,
    cl.is_rear_defroster_on,
    cl.date AS climate_at,
    tp.tpms_pressure_fl,
    tp.tpms_pressure_fr,
    tp.tpms_pressure_rl,
    tp.tpms_pressure_rr,
    tp.date AS tpms_at,
    p.latitude,
    p.longitude,
    a.display_name as location,
    a.city,
    a.state,
    p.date as last_update,
    CASE
        WHEN st.state = 'online' AND drv.start_date IS NOT NULL THEN 'driving'
        WHEN st.state = 'online' AND chg.start_date IS NOT NULL THEN 'charging'
        ELSE st.state
    END AS car_state,
    CASE
        WHEN st.state = 'online' AND drv.start_date IS NOT NULL THEN drv.start_date
        WHEN st.state = 'online' AND chg.start_date IS NOT NULL THEN chg.start_date
        ELSE st.start_date
    END AS car_state_since
FROM cars c
    LEFT JOIN LATERAL (
        SELECT pp.date,
            pp.battery_level,
            pp.rated_battery_range_km,
            pp.odometer,
            pp.outside_temp,
            pp.is_climate_on,
            pp.latitude,
            pp.longitude,
            pp.drive_id
        FROM positions pp
        WHERE pp.car_id = c.id
            AND pp.ideal_battery_range_km IS NOT NULL
        ORDER BY pp.date DESC
        LIMIT 1
    ) pr ON true
    LEFT JOIN LATERAL (
        SELECT ps.date,
            ps.battery_level,
            ps.odometer,
            ps.latitude,
            ps.longitude,
            ps.drive_id
        FROM positions ps
        WHERE ps.car_id = c.id
            AND ps.date > COALESCE(pr.date, '-infinity')
            AND ps.date <= COALESCE(pr.date + interval '7 days', 'infinity')
        ORDER BY ps.date DESC
        LIMIT 1
    ) sr ON true
    CROSS JOIN LATERAL (
        SELECT COALESCE(sr.date, pr.date) AS date,
            COALESCE(sr.battery_level, pr.battery_level) AS battery_level,
            COALESCE(sr.odometer, pr.odometer) AS odometer,
            COALESCE(sr.latitude, pr.latitude) AS latitude,
            COALESCE(sr.longitude, pr.longitude) AS longitude,
            CASE WHEN sr.date IS NOT NULL THEN sr.drive_id ELSE pr.drive_id END AS drive_id
    ) p
    LEFT JOIN LATERAL (
        SELECT pc.date,
            pc.inside_temp,
            pc.driver_temp_setting,
            pc.passenger_temp_setting,
            pc.fan_status,
            pc.is_front_defroster_on,
            pc.is_rear_defroster_on
        FROM positions pc
        WHERE pc.car_id = c.id
            AND pc.ideal_battery_range_km IS NOT NULL
            AND pc.inside_temp IS NOT NULL
            AND pc.date >= p.date - interval '7 days'
        ORDER BY pc.date DESC
        LIMIT 1
    ) cl ON true
    LEFT JOIN LATERAL (
        SELECT pt.date,
            pt.tpms_pressure_fl,
            pt.tpms_pressure_fr,
            pt.tpms_pressure_rl,
            pt.tpms_pressure_rr
        FROM positions pt
        WHERE pt.car_id = c.id
            AND pt.ideal_battery_range_km IS NOT NULL
            AND COALESCE(
                pt.tpms_pressure_fl, pt.tpms_pressure_fr,
                pt.tpms_pressure_rl, pt.tpms_pressure_rr
            ) IS NOT NULL
            AND pt.date >= p.date - interval '7 days'
        ORDER BY pt.date DESC
        LIMIT 1
    ) tp ON true
    LEFT JOIN LATERAL (
        SELECT *
        FROM addresses a
        ORDER BY (
                (p.latitude - a.latitude) ^ 2 + (p.longitude - a.longitude) ^ 2
            )
        LIMIT 1
    ) a ON true
    LEFT JOIN LATERAL (
        SELECT s.state::text AS state,
            s.start_date
        FROM states s
        WHERE s.car_id = c.id
            AND s.end_date IS NULL
        ORDER BY s.start_date DESC
        LIMIT 1
    ) st ON true
    -- Driving: the latest position belongs to a drive that has not ended, and
    -- is recent. TeslaMate leaves drives open when it restarts mid-drive, so
    -- an open drive alone does not mean the car is moving.
    LEFT JOIN LATERAL (
        SELECT d.start_date
        FROM drives d
        WHERE d.id = p.drive_id
            AND d.end_date IS NULL
            AND p.date >= (now() AT TIME ZONE 'UTC') - interval '30 minutes'
    ) drv ON true
    LEFT JOIN LATERAL (
        SELECT cp.start_date
        FROM charging_processes cp
        WHERE cp.car_id = c.id
            AND cp.end_date IS NULL
            AND cp.start_date >= st.start_date
        ORDER BY cp.start_date DESC
        LIMIT 1
    ) chg ON true
WHERE p.date IS NOT NULL -- a car with no positions has no status
    AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%');
