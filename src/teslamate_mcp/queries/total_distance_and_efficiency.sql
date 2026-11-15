SELECT c.name as car_name,
    COUNT(d.id) as total_drives,
    ROUND(SUM(d.distance)::numeric, 2) as total_distance_km,
    ROUND(AVG(d.distance)::numeric, 2) as avg_distance_per_drive,
    ROUND(AVG(d.outside_temp_avg)::numeric, 1) as avg_outside_temp,
    ROUND(AVG(d.speed_max)::numeric, 1) as avg_max_speed,
    -- Rated range used x the car's efficiency, over the distance of the drives
    -- that have range readings: the consumption get_recap shows.
    ROUND((SUM((d.start_rated_range_km - d.end_rated_range_km) * c.efficiency) * 1000
        / NULLIF(SUM(d.distance) FILTER (
            WHERE d.start_rated_range_km IS NOT NULL AND d.end_rated_range_km IS NOT NULL
        ), 0))::numeric) AS wh_per_km
FROM drives d
    JOIN cars c ON d.car_id = c.id
WHERE d.end_date IS NOT NULL -- a drive still open is not a drive yet
    AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
    AND (%(days)s::int IS NULL OR d.start_date >= (now() AT TIME ZONE 'UTC') - make_interval(days => %(days)s::int))
GROUP BY c.id,
    c.name
ORDER BY total_distance_km DESC;