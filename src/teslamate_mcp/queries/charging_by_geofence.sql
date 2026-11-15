SELECT COALESCE(g.name, 'Ungeofenced') AS geofence,
    COUNT(*) AS sessions,
    COUNT(*) FILTER (WHERE cp.cost IS NULL) AS sessions_without_cost,
    ROUND(SUM(cp.charge_energy_added)::numeric, 1) AS kwh_added,
    SUM(cp.cost) AS total_cost,
    -- Over costed sessions and billed energy; see charging_costs.sql.
    ROUND(
        SUM(cp.cost)
            / NULLIF(SUM(GREATEST(cp.charge_energy_used, cp.charge_energy_added))
                FILTER (WHERE cp.cost IS NOT NULL)::numeric, 0),
        3
    ) AS avg_cost_per_kwh
FROM charging_processes cp
    JOIN cars c ON cp.car_id = c.id
    LEFT JOIN geofences g ON cp.geofence_id = g.id
WHERE cp.end_date IS NOT NULL -- a session is a finished charge that added energy
    AND cp.charge_energy_added > 0
    AND cp.start_date >= (now() AT TIME ZONE 'UTC') - make_interval(days => %(days)s::int)
    AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
GROUP BY COALESCE(g.name, 'Ungeofenced')
ORDER BY kwh_added DESC;
