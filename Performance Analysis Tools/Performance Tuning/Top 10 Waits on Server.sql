SELECT	TOP (10) dows.*
FROM	sys.dm_os_wait_stats AS dows
ORDER BY dows.wait_time_ms DESC				