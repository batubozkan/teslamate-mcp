SELECT cp.id AS charging_process_id,
    c.name AS car_name,
    cp.start_date,
    cp.end_date,
    cp.charge_energy_added AS energy_added_kwh,
    cp.duration_min,
    cp.cost,
    COALESCE(g.name, a.display_name) AS location,
    a.city
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
    AND (%(location)s::text IS NULL
        OR g.name ILIKE '%%' || %(location)s || '%%'
        OR a.display_name ILIKE '%%' || %(location)s || '%%'
        OR a.city ILIKE '%%' || %(location)s || '%%')
    AND (%(min_energy_kwh)s::float8 IS NULL OR cp.charge_energy_added >= %(min_energy_kwh)s)
ORDER BY cp.start_date DESC
LIMIT %(limit)s::int;
