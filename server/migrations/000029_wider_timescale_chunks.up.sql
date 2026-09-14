-- Weekly chunks create hundreds of tiny relations for multi-year Apple Health
-- histories. Year-sized chunks remain well below the memory-based sizing
-- target while avoiding DDL locks for every week of a history upload.
SELECT set_chunk_time_interval('health_metrics', INTERVAL '365 days');
SELECT set_chunk_time_interval('sleep_stages', INTERVAL '365 days');
SELECT set_chunk_time_interval('workout_heart_rate', INTERVAL '365 days');
SELECT set_chunk_time_interval('workout_routes', INTERVAL '365 days');
