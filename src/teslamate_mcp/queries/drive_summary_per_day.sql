SELECT DATE((start_date AT TIME ZONE 'UTC') AT TIME ZONE %(tz)s::text) AS drive_day,
    COUNT(*) AS drive_count,
    SUM(distance) AS total_km,
    SUM(duration_min) AS total_minutes
FROM drives
    JOIN cars c ON drives.car_id = c.id
WHERE drives.end_date IS NOT NULL -- a drive still open is not a drive yet
    AND (%(car_name)s::text IS NULL OR c.name ILIKE '%%' || %(car_name)s || '%%')
    AND (%(days)s::int IS NULL OR start_date >= (date_trunc('day', (now() - make_interval(days => %(days)s::int)) AT TIME ZONE %(tz)s::text)
            AT TIME ZONE %(tz)s::text) AT TIME ZONE 'UTC')
GROUP BY DATE((start_date AT TIME ZONE 'UTC') AT TIME ZONE %(tz)s::text)
ORDER BY DATE((start_date AT TIME ZONE 'UTC') AT TIME ZONE %(tz)s::text) DESC
LIMIT %(limit)s::int;