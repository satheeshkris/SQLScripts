exec sp_HealthCheck 2

--Total amount
SELECT cntr_value AS Number_of_deadlocks
  FROM sys.dm_os_performance_counters
 WHERE object_name = 'SQLServer:Locks'
   AND counter_name = 'Number of Deadlocks/sec'
   AND instance_name = '_Total'

/*		Find M/r Usage 
Mail:	SQL Memory Healthcheck script.msg
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
OPTION (RECOMPILE);


       --Total amount of RAM consumed by database data (Buffer Pool). This should be the highest usage of Memory on the server.
Select SQLBufferPoolUsedMemoryMB = (Select SUM(pages_kb)/1024 AS [SPA Mem, Mb] FROM sys.dm_os_memory_clerks WITH (NOLOCK) Where type = 'MEMORYCLERK_SQLBUFFERPOOL')
       --Total amount of RAM used by SQL Server memory clerks (includes Buffer Pool)
       , SQLAllMemoryClerksUsedMemoryMB = (Select SUM(pages_kb)/1024 AS [SPA Mem, Mb] FROM sys.dm_os_memory_clerks WITH (NOLOCK))
       --How long in seconds since data was removed from the Buffer Pool, to be replaced with data from disk. (Key indicator of memory pressure when below 300 consistently)
       ,[PageLifeExpectancy] = (SELECT cntr_value FROM sys.dm_os_performance_counters WITH (NOLOCK) WHERE [object_name] LIKE N'%Buffer Manager%' AND counter_name = N'Page life expectancy' )
       --How many memory operations are Pending (should always be 0, anything above 0 for extended periods of time is a very high sign of memory pressure)
       ,[MemoryGrantsPending] = (SELECT cntr_value FROM sys.dm_os_performance_counters WITH (NOLOCK) WHERE [object_name] LIKE N'%Memory Manager%' AND counter_name = N'Memory Grants Pending' )
       --How many memory operations are Outstanding (should always be 0, anything above 0 for extended periods of time is a very high sign of memory pressure)
       ,[MemoryGrantsOutstanding] = (SELECT cntr_value FROM sys.dm_os_performance_counters WITH (NOLOCK) WHERE [object_name] LIKE N'%Memory Manager%' AND counter_name = N'Memory Grants Outstanding' );
/*
;WITH RingBuffer AS 
(
		SELECT CAST(dorb.record AS XML) AS xRecord, dorb.timestamp
		FROM sys.dm_os_ring_buffers AS dorb
		WHERE dorb.ring_buffer_type = 'RING_BUFFER_RESOURCE_MONITOR'
)
SELECT	xr.value('(ResourceMonitor/Notification)[1]', 'varchar(75)') AS RmNotification,
		xr.value('(ResourceMonitor/IndicatorsProcess)[1]','int') AS IndicatorsProcess,
		xr.value('(ResourceMonitor/IndicatorsSystem)[1]','int') AS IndicatorsSystem,
		DATEADD(ms, -1 * dosi.ms_ticks - rb.timestamp, GETDATE()) AS RmDateTime,
		xr.value('(MemoryNode/TargetMemory)[1]','bigint') AS TargetMemory,
		xr.value('(MemoryNode/ReserveMemory)[1]','bigint') AS ReserveMemory,
		xr.value('(MemoryNode/CommittedMemory)[1]','bigint') AS CommitedMemory,
		xr.value('(MemoryNode/SharedMemory)[1]','bigint') AS SharedMemory,
		xr.value('(MemoryNode/PagesMemory)[1]','bigint') AS PagesMemory,
		xr.value('(MemoryRecord/MemoryUtilization)[1]','bigint') AS MemoryUtilization,
		xr.value('(MemoryRecord/TotalPhysicalMemory)[1]','bigint') AS TotalPhysicalMemory,
		xr.value('(MemoryRecord/AvailablePhysicalMemory)[1]','bigint') AS AvailablePhysicalMemory,
		xr.value('(MemoryRecord/TotalPageFile)[1]','bigint') AS TotalPageFile,
		xr.value('(MemoryRecord/AvailablePageFile)[1]','bigint') AS AvailablePageFile,
		xr.value('(MemoryRecord/TotalVirtualAddressSpace)[1]','bigint') AS TotalVirtualAddressSpace,
		xr.value('(MemoryRecord/AvailableVirtualAddressSpace)[1]','bigint') AS AvailableVirtualAddressSpace,
		xr.value('(MemoryRecord/AvailableExtendedVirtualAddressSpace)[1]','bigint') AS AvailableExtendedVirtualAddressSpace
FROM RingBuffer AS rb
CROSS APPLY rb.xRecord.nodes('Record') record (xr)
CROSS JOIN sys.dm_os_sys_info AS dosi
ORDER BY RmDateTime DESC;
*/