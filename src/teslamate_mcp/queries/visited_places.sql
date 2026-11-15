-- Where the car parks: one row per place it arrived at (a drive ending
-- there), with coordinates for a map, the number of arrivals, the time parked
-- there (until the car's next drive), and the charging done there.
--
-- A place is the geofence when the arrival has one, else the address.
-- Reverse geocoding gives one spot several addresses a few meters apart, so
-- by address alone a home showed as up to seven places; a geofence is one.
WITH scope_drives AS (
    SELECT d.car_id,
        d.end_date,
        d.end_address_id,
        d.end_geofence_id,
        LEAD(d.start_date) OVER (PARTITION BY d.car_id ORDER BY d.start_date) AS next_start
    FROM drives d
        JOIN cars c ON c.id = d.car_id
    WHERE d.end_date IS NOT NULL
        AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
),
arrivals AS (
    SELECT COALESCE('g' || sd.end_geofence_id, 'a' || sd.end_address_id) AS place_key,
        MAX(sd.end_geofence_id) AS geofence_id,
        -- One address for a place without a geofence; for a geofence the one
        -- most arrivals got, which names its city.
        MODE() WITHIN GROUP (ORDER BY sd.end_address_id) AS address_id,
        COUNT(*) AS arrivals,
        -- The latest arrival is still parked: count it up to now.
        SUM(EXTRACT(EPOCH FROM (
            COALESCE(sd.next_start, now() AT TIME ZONE 'UTC') - sd.end_date
        ))) / 3600.0 AS parked_hours,
        MAX(sd.end_date) AS last_arrival
    FROM scope_drives sd
    WHERE COALESCE(sd.end_geofence_id, sd.end_address_id) IS NOT NULL
        AND (%(days)s::int IS NULL
            OR sd.end_date >= (now() AT TIME ZONE 'UTC') - make_interval(days => %(days)s::int))
    GROUP BY 1
),
charging AS (
    SELECT COALESCE('g' || cp.geofence_id, 'a' || cp.address_id) AS place_key,
        COUNT(*) AS sessions,
        SUM(cp.charge_energy_added) AS kwh_added
    FROM charging_processes cp
        JOIN cars c ON c.id = cp.car_id
    WHERE cp.end_date IS NOT NULL -- a session is a finished charge that added energy
        AND cp.charge_energy_added > 0
        AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
        AND (%(days)s::int IS NULL
            OR cp.start_date >= (now() AT TIME ZONE 'UTC') - make_interval(days => %(days)s::int))
    GROUP BY 1
)
SELECT COALESCE(g.name, a.display_name) AS location,
    a.city,
    -- A geofence is drawn at its center.
    ROUND(COALESCE(g.latitude, a.latitude)::numeric, 5) AS latitude,
    ROUND(COALESCE(g.longitude, a.longitude)::numeric, 5) AS longitude,
    ar.arrivals,
    ROUND(ar.parked_hours::numeric, 1) AS parked_hours,
    COALESCE(ch.sessions, 0) AS charging_sessions,
    ROUND(COALESCE(ch.kwh_added, 0)::numeric, 1) AS kwh_added,
    ar.last_arrival
FROM arrivals ar
    LEFT JOIN geofences g ON g.id = ar.geofence_id
    LEFT JOIN addresses a ON a.id = ar.address_id
    LEFT JOIN charging ch ON ch.place_key = ar.place_key
WHERE ar.arrivals >= %(min_arrivals)s::int
    AND COALESCE(g.latitude, a.latitude) IS NOT NULL
    AND COALESCE(g.longitude, a.longitude) IS NOT NULL
ORDER BY ar.arrivals DESC,
    ar.parked_hours DESC
LIMIT %(limit)s::int;
