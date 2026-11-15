-- Places drives start or end at, most used first. A place is the geofence
-- when the drive has one there, else the address: one geofence covers the
-- several addresses reverse geocoding gives one spot.
WITH scoped AS (
    SELECT d.id,
        d.duration_min,
        d.start_address_id,
        d.start_geofence_id,
        d.end_address_id,
        d.end_geofence_id
    FROM drives d
        JOIN cars c ON d.car_id = c.id
    WHERE d.end_date IS NOT NULL -- a drive still open is not a drive yet
        AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
        AND (%(days)s::int IS NULL OR d.start_date >= (now() AT TIME ZONE 'UTC') - make_interval(days => %(days)s::int))
),
ends AS (
    SELECT s.duration_min,
        s.start_address_id AS address_id,
        s.start_geofence_id AS geofence_id
    FROM scoped s
    UNION ALL
    -- A drive that starts and ends at one place counts there once.
    SELECT s.duration_min,
        s.end_address_id,
        s.end_geofence_id
    FROM scoped s
    WHERE COALESCE('g' || s.end_geofence_id, 'a' || s.end_address_id)
        IS DISTINCT FROM COALESCE('g' || s.start_geofence_id, 'a' || s.start_address_id)
)
SELECT COALESCE(g.name, a.display_name) as location,
    MODE() WITHIN GROUP (ORDER BY a.city) as city,
    MODE() WITHIN GROUP (ORDER BY a.state) as state,
    COUNT(*) as visit_count,
    SUM(e.duration_min) as total_time_spent_min
FROM ends e
    LEFT JOIN addresses a ON a.id = e.address_id
    LEFT JOIN geofences g ON g.id = e.geofence_id
WHERE COALESCE(g.id, a.id) IS NOT NULL
GROUP BY COALESCE('g' || g.id, 'a' || a.id),
    COALESCE(g.name, a.display_name)
ORDER BY visit_count DESC
LIMIT %(limit)s::int;
