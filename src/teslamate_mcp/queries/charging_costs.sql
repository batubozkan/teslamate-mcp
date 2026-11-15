SELECT CASE %(group_by)s::text
        WHEN 'month' THEN TO_CHAR(
            DATE_TRUNC('month', (cp.start_date AT TIME ZONE 'UTC') AT TIME ZONE %(tz)s::text),
            'YYYY-MM'
        )
        WHEN 'location' THEN COALESCE(g.name, a.display_name, 'Unknown')
        WHEN 'car' THEN c.name
    END AS group_key,
    COUNT(*) AS sessions,
    COUNT(*) FILTER (WHERE cp.cost IS NULL) AS sessions_without_cost,
    ROUND(SUM(cp.charge_energy_added)::numeric, 2) AS total_energy_kwh,
    -- Null when no session in the group has a recorded cost: unknown, not free.
    ROUND(SUM(cp.cost)::numeric, 2) AS total_cost,
    -- Over costed sessions only: a session with no cost is unknown, not free,
    -- and counting its kWh would drag the average down. Over billed energy
    -- (the larger of kWh drawn from the charger and kWh added to the battery):
    -- the charger bills what it delivers, and AC charging loses 5-10 %% of
    -- that on the way in, so cost over kWh added overstates the price.
    ROUND(
        (SUM(cp.cost) / NULLIF(SUM(GREATEST(cp.charge_energy_used, cp.charge_energy_added))
            FILTER (WHERE cp.cost IS NOT NULL), 0))::numeric,
        4
    ) AS avg_cost_per_kwh
FROM charging_processes cp
    JOIN cars c ON cp.car_id = c.id
    LEFT JOIN addresses a ON cp.address_id = a.id
    LEFT JOIN geofences g ON cp.geofence_id = g.id
WHERE cp.end_date IS NOT NULL -- a session is a finished charge that added energy
    AND cp.charge_energy_added > 0
    AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
    AND (%(start_date)s::date IS NULL
        OR ((cp.start_date AT TIME ZONE 'UTC') AT TIME ZONE %(tz)s::text)::date >= %(start_date)s::date)
    AND (%(end_date)s::date IS NULL
        OR ((cp.start_date AT TIME ZONE 'UTC') AT TIME ZONE %(tz)s::text)::date <= %(end_date)s::date)
GROUP BY 1
ORDER BY 1;
