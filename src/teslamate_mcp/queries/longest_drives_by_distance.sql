SELECT c.name as car_name,
    d.start_date,
    d.distance as distance_km,
    d.duration_min,
    d.speed_max,
    COALESCE(start_fence.name, start_addr.display_name) as start_location,
    COALESCE(end_fence.name, end_addr.display_name) as end_location,
    d.outside_temp_avg
FROM drives d
    JOIN cars c ON d.car_id = c.id
    LEFT JOIN addresses start_addr ON d.start_address_id = start_addr.id
    LEFT JOIN addresses end_addr ON d.end_address_id = end_addr.id
    LEFT JOIN geofences start_fence ON d.start_geofence_id = start_fence.id
    LEFT JOIN geofences end_fence ON d.end_geofence_id = end_fence.id
WHERE d.end_date IS NOT NULL
    AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
    AND (%(days)s::int IS NULL OR d.start_date >= (now() AT TIME ZONE 'UTC') - make_interval(days => %(days)s::int))
    AND (%(min_distance_km)s::float8 IS NULL OR d.distance >= %(min_distance_km)s)
ORDER BY d.distance DESC NULLS LAST
LIMIT %(limit)s::int;