SELECT c.name as car_name,
    COUNT(*) as total_charging_sessions,
    SUM(cp.charge_energy_added) as total_energy_added_kwh,
    AVG(cp.charge_energy_added) as avg_energy_per_session,
    SUM(cp.duration_min) as total_charging_time_min,
    AVG(cp.duration_min) as avg_charging_time_min,
    -- Null when no session has a recorded cost: unknown, not free.
    SUM(cp.cost) as total_charging_cost,
    COUNT(*) FILTER (WHERE cp.cost IS NULL) as sessions_without_cost
FROM charging_processes cp
    JOIN cars c ON cp.car_id = c.id
WHERE cp.end_date IS NOT NULL -- a session is a finished charge that added energy
    AND cp.charge_energy_added > 0
    AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
    AND (%(days)s::int IS NULL OR cp.start_date >= (now() AT TIME ZONE 'UTC') - make_interval(days => %(days)s::int))
GROUP BY c.id,
    c.name
ORDER BY total_energy_added_kwh DESC;
