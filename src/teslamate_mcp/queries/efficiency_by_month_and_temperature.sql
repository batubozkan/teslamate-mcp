WITH monthly_stats AS (
    SELECT c.name as car_name,
        DATE_TRUNC('month', (d.start_date AT TIME ZONE 'UTC') AT TIME ZONE %(tz)s::text) as month,
        ROUND(AVG(d.outside_temp_avg)::numeric, 1) as avg_temp,
        SUM(d.distance) as total_distance,
        COUNT(d.id) as drive_count,
        -- Rated range used x the car's efficiency, over the distance of the
        -- drives that have range readings: the consumption get_recap shows.
        SUM((d.start_rated_range_km - d.end_rated_range_km) * c.efficiency) * 1000
            / NULLIF(SUM(d.distance) FILTER (
                WHERE d.start_rated_range_km IS NOT NULL AND d.end_rated_range_km IS NOT NULL
            ), 0) AS wh_per_km
    FROM drives d
        JOIN cars c ON d.car_id = c.id
    WHERE d.end_date IS NOT NULL -- a drive still open is not a drive yet
        AND d.start_date >= (date_trunc('month', (now() - make_interval(days => %(days)s::int)) AT TIME ZONE %(tz)s::text)
            AT TIME ZONE %(tz)s::text) AT TIME ZONE 'UTC'
        AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
    GROUP BY c.id,
        c.name,
        DATE_TRUNC('month', (d.start_date AT TIME ZONE 'UTC') AT TIME ZONE %(tz)s::text)
)
SELECT car_name,
    month,
    avg_temp,
    ROUND(total_distance::numeric, 2) as total_distance_km,
    drive_count,
    ROUND((total_distance / drive_count)::numeric, 2) as avg_distance_per_drive,
    ROUND(wh_per_km::numeric) AS wh_per_km
FROM monthly_stats
ORDER BY car_name,
    month DESC;