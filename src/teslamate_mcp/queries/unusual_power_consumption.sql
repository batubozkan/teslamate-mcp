-- Drives that used far more rated range than the distance they covered.
-- Under a few km the range figures are rounding noise (a 1 km drive that
-- drops the range by 3 km reads as 300 %%), so short drives are left out.
SELECT c.name as car_name,
    d.start_date,
    d.distance,
    (d.start_rated_range_km - d.end_rated_range_km) as range_used,
    ROUND(
        (
            (d.start_rated_range_km - d.end_rated_range_km) / NULLIF(d.distance, 0) * 100
        )::numeric,
        2
    ) as consumption_pct,
    d.outside_temp_avg,
    COALESCE(start_fence.name, start_addr.display_name) as start_location,
    COALESCE(end_fence.name, end_addr.display_name) as end_location
FROM drives d
    JOIN cars c ON d.car_id = c.id
    LEFT JOIN addresses start_addr ON d.start_address_id = start_addr.id
    LEFT JOIN addresses end_addr ON d.end_address_id = end_addr.id
    LEFT JOIN geofences start_fence ON d.start_geofence_id = start_fence.id
    LEFT JOIN geofences end_fence ON d.end_geofence_id = end_fence.id
WHERE d.end_date IS NOT NULL
    AND d.distance > 0
    AND d.distance >= %(min_distance_km)s::float8
    AND d.start_rated_range_km > d.end_rated_range_km
    AND (
        (d.start_rated_range_km - d.end_rated_range_km) / d.distance * 100
    ) > %(threshold_pct)s::float8 -- consumption above threshold_pct
    AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
    AND (%(days)s::int IS NULL OR d.start_date >= (now() AT TIME ZONE 'UTC') - make_interval(days => %(days)s::int))
ORDER BY consumption_pct DESC
LIMIT %(limit)s::int;
