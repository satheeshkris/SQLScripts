/*	Top 10 SQL Server Counters for Monitoring SQL Server Performance
		http://www.databasejournal.com/features/mssql/article.php/3932406/Top-10-SQL-Server-Counters-for-Monitoring-SQL-Server-Performance.htm
	What does cntr_type mean?
		https://troubleshootingsql.com/2011/03/03/what-does-cntr_type-mean/
	Memory Grants Pending 
		https://social.msdn.microsoft.com/Forums/sqlserver/en-US/9ff24502-18f9-4b49-9cfa-a584f23b0a45/memory-grants-pending?forum=sqldatabaseengine
	Understanding SQL server memory grant
		https://blogs.msdn.microsoft.com/sqlqueryprocessing/2010/02/16/understanding-sql-server-memory-grant/
	Plan Cache Internals
		https://msdn.microsoft.com/en-us/library/cc293624.aspx
	Measuring Disk Latency with Windows Performance Monitor (Perfmon)
		https://blogs.technet.microsoft.com/askcore/2012/02/07/measuring-disk-latency-with-windows-performance-monitor-perfmon/
*/

select 
       --Total Percent of Memory Used on the Server. On a properly configured SQL instance memory usage should always be 90-95%
       [MemoryUsagePercent]  = convert(decimal(12,2),((total_physical_memory_kb - available_physical_memory_kb) / convert(float,total_physical_memory_kb )) * 100.0 )
       --Total amount of RAM configured to the Server
       , PhysicalMemoryMB  = total_physical_memory_kb / ( 1024 )
       --Total amount of RAM available to the Server
       , AvailableMemoryMB = available_physical_memory_kb / ( 1024 )
       --Total amount of RAM used by the OS
       , SystemCacheUsedMemoryMB = system_cache_kb / ( 1024 )
       --Integer value of memory_state_desc
       , MemorySignalState = CASE WHEN system_high_memory_signal_state = 1 Then 1 WHEN system_low_memory_signal_state = 1 THEN 2 ELSE 0 END
       --Description of memory state
       , system_memory_state_desc
from master.sys.dm_os_sys_memory 

SELECT	GETDATE() AS SnapshotTime, *
		,CASE	cntr_type 
				WHEN 65792 THEN 'Absolute Meaning' 
				WHEN 65536 THEN 'Absolute Meaning' 
				WHEN 272696576 THEN 'Per Second counter and is Cumulative in Nature'
				WHEN 1073874176 THEN 'Bulk Counter. To get correct value, this value needs to be divided by Base Counter value'
				WHEN 537003264 THEN 'Bulk Counter. To get correct value, this value needs to be divided by Base Counter value' 
				END AS counter_comments
FROM	sys.dm_os_performance_counters AS dopc
WHERE	( dopc.object_name = 'SQLServer:Buffer Manager' AND dopc.counter_name = 'Buffer cache hit ratio' )
	OR	( dopc.object_name = 'SQLServer:Buffer Manager' AND dopc.counter_name = 'Page life expectancy' )
	OR	( dopc.object_name = 'SQLServer:Buffer Manager' AND dopc.counter_name = 'Checkpoint pages/sec' )
	--
	OR	( dopc.object_name = 'SQLServer:SQL Statistics' AND dopc.counter_name = 'SQL Compilations/Sec'	)
	OR	( dopc.object_name = 'SQLServer:SQL Statistics' AND dopc.counter_name = 'SQL Re-Compilations/Sec' )
	OR	( dopc.object_name = 'SQLServer:SQL Statistics' AND dopc.counter_name = 'Batch Requests/sec' )
	--
	OR	( dopc.object_name = 'SQLServer:Locks' AND dopc.counter_name = 'Lock Waits/sec'	AND dopc.instance_name = '_Total')
	OR	( dopc.object_name = 'SQLServer:Locks' AND counter_name = 'Number of Deadlocks/sec' AND instance_name = '_Total' )
	OR	( dopc.object_name = 'SQLServer:Access Methods' AND dopc.counter_name = 'Page Splits/sec' )
	--
	OR	( dopc.object_name = 'SQLServer:General Statistics' AND dopc.counter_name = 'User Connections' )
	OR	( dopc.object_name = 'SQLServer:General Statistics' AND dopc.counter_name = 'Processes blocked' )
	--
	OR	( dopc.object_name = 'SQLServer:Memory Manager' AND counter_name = 'Target Server Memory (KB)' )
	OR	( dopc.object_name = 'SQLServer:Memory Manager' AND counter_name = 'Total Server Memory (KB)' )
	OR	( dopc.object_name = 'SQLServer:Memory Manager' AND counter_name = 'Memory Grants Pending' )
	OR	( dopc.object_name = 'SQLServer:Memory Manager' AND counter_name = 'Memory Grants Outstanding' )
OPTION(RECOMPILE);


--SELECT * FROM SYS.configurations c where c.name like '%quer%'