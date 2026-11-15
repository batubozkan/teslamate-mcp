-- One row per place: the geofence when the session has one, else the address.
-- A geofence covers the several addresses reverse geocoding gives one spot.
SELECT COALESCE(g.name, a.display_name) as location,
    MODE() WITHIN GROUP (ORDER BY a.city) as city,
    COUNT(*) as sessions,
    SUM(cp.charge_energy_added) as total_kwh,
    AVG(cp.charge_energy_added) as avg_kwh_per_session,
    SUM(cp.duration_min) as total_minutes,
    -- Null when no session there has a recorded cost: unknown, not free.
    SUM(cp.cost) as total_cost,
    COUNT(*) FILTER (WHERE cp.cost IS NULL) as sessions_without_cost
FROM charging_processes cp
    JOIN cars c ON cp.car_id = c.id
    LEFT JOIN addresses a ON cp.address_id = a.id
    LEFT JOIN geofences g ON cp.geofence_id = g.id
WHERE cp.end_date IS NOT NULL -- a session is a finished charge that added energy
    AND cp.charge_energy_added > 0
    AND COALESCE(g.id, a.id) IS NOT NULL
    AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
    AND (%(days)s::int IS NULL OR cp.start_date >= (now() AT TIME ZONE 'UTC') - make_interval(days => %(days)s::int))
GROUP BY COALESCE('g' || g.id, 'a' || a.id),
    COALESCE(g.name, a.display_name)
ORDER BY sessions DESC
LIMIT %(limit)s::int;
