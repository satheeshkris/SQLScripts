--	Find avg logins/sec on servers
SELECT	dopc.object_name, dopc.counter_name, dopc.cntr_value, dopc.cntr_type
FROM	sys.dm_os_performance_counters AS dopc
WHERE	dopc.counter_name = 'Logins/sec'