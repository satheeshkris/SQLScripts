/*	****	Powershell method to import Blitz Scripts	*****
Import-Module "C:\Users\ADwived8\Desktop\Ajay\Study\Powershell Exercises\Assignments\SQL-Server-First-Responder-Kit-dev\FirstResponderKit.ps1" -Force
Apply-FirstResponderKit -ServerName instanceName
Remove-FirstResponderKit -ServerName instanceName
*/

EXEC tempdb..sp_WhoIsActive @get_plans=1, @get_full_inner_text=1, @get_transaction_info=1, @get_task_info=2, @get_locks=1, @get_avg_time=1, @get_additional_info=1,@find_block_leaders=1

/*
--	RESOURCE_SEMAPHORE
	--	https://www.mssqltips.com/sqlservertip/2827/troubleshooting-sql-server-resourcesemaphore-waittype-memory-issues/
	--	http://www.sqltuners.net/blog/13-05-16/Measuring_Disk_IO_performance_for_SQL_Servers.aspx
	--	https://blogs.msdn.microsoft.com/askjay/2011/07/08/troubleshooting-slow-disk-io-in-sql-server/
	--	https://www.brentozar.com/archive/2013/08/query-plans-what-happens-when-row-estimates-get-high/
	--	SQL Server  Wait Type Table.xlsx

*/
--	Query to find what's is running on server
	SELECT s.session_id
	,DB_NAME(r.database_id) as DBName
    ,r.STATUS
	,r.percent_complete
	,CAST(((DATEDIFF(s,start_time,GetDate()))/3600) as varchar) + ' hour(s), '
        + CAST((DATEDIFF(s,start_time,GetDate())%3600)/60 as varchar) + 'min, '
        + CAST((DATEDIFF(s,start_time,GetDate())%60) as varchar) + ' sec'  as running_time
	,CAST((estimated_completion_time/3600000) as varchar) + ' hour(s), '
                  + CAST((estimated_completion_time %3600000)/60000  as varchar) + 'min, '
                  + CAST((estimated_completion_time %60000)/1000  as varchar) + ' sec'  as est_time_to_go
	,dateadd(second,estimated_completion_time/1000, getdate())  as est_completion_time 
    ,r.blocking_session_id 'blocked by'
    ,r.wait_type
    ,wait_resource
    ,r.wait_time / (1000.0) 'Wait Time (in Sec)'
    ,r.cpu_time
    ,r.logical_reads
    --,r.reads
    ,r.writes
    ,r.total_elapsed_time / (1000.0) 'Elapsed Time (in Sec)'
    ,Substring(st.TEXT, (r.statement_start_offset / 2) + 1, (
            (
                CASE r.statement_end_offset
                    WHEN - 1
                        THEN Datalength(st.TEXT)
                    ELSE r.statement_end_offset
                    END - r.statement_start_offset
                ) / 2
            ) + 1) AS statement_text
	,r.sql_handle
	,st.text as Batch_Text
	,r.plan_handle
    ,s.login_name
    ,s.host_name
    ,s.program_name
    ,s.host_process_id
    --,s.last_request_end_time
    --,s.login_time
    ,r.open_transaction_count
	,r.query_hash, r.query_plan_hash
	,qp.query_plan
FROM sys.dm_exec_sessions AS s
INNER JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) AS qp
WHERE r.session_id != @@SPID
	--AND r.session_id > 50
ORDER BY DBName, r.cpu_time DESC
    ,r.STATUS
    ,r.blocking_session_id
    ,s.session_id


select r.session_id
, percent_complete
, estimated_completion_time = dateadd(millisecond, estimated_completion_time, getdate())
, r.blocking_session_id
, t.text
from sys.dm_exec_requests r
outer apply sys.dm_exec_sql_text(r.sql_handle) t
where percent_complete <> 0

--select * from sys.dm_exec_requests r where r.blocking_session_id = 71


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

;WITH RingBuffer AS 
(
		SELECT CAST(dorb.record AS XML) AS xRecord, dorb.timestamp
		FROM sys.dm_os_ring_buffers AS dorb
		WHERE dorb.ring_buffer_type = 'RING_BUFFER_RESOURCE_MONITOR'
)
SELECT	xr.value('(ResourceMonitor/Notification)[1]', 'varchar(75)') AS RmNotification,
		xr.value('(ResourceMonitor/IndicatorsProcess)[1]','tinyint') AS IndicatorsProcess,
		xr.value('(ResourceMonitor/IndicatorsSystem)[1]','tinyint') AS IndicatorsSystem,
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

/*	Info on sp_kill
	http://helpdesk.uhg.com/knowledge-center/personal-hardware-software/general-applications/sql-server/148476

*/

/*	Adhoc queries against Database */
SELECT usecounts, cacheobjtype, objtype, size_in_bytes/1024 as 'Size(KB)', TEXT, cp.plan_handle, qs.sql_handle, qs.creation_time, qs.total_logical_reads, qs.total_logical_writes, qs.query_hash, qs.query_plan_hash
FROM sys.dm_exec_cached_plans AS cp
JOIN sys.dm_exec_query_stats AS qs
ON qs.plan_handle = cp.plan_handle
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) as st
WHERE objtype = 'Adhoc'
AND DB_NAME(dbid) = 'JIRA_DB'
ORDER BY text;

--	Clear all waits
DBCC SQLPERF (N'sys.dm_os_wait_stats', CLEAR);
GO

--	Get Cumulative Waits on Server
WITH [Waits] AS
    (SELECT
        [wait_type],
        [wait_time_ms] / 1000.0 AS [WaitS],
        ([wait_time_ms] - [signal_wait_time_ms]) / 1000.0 AS [ResourceS],
        [signal_wait_time_ms] / 1000.0 AS [SignalS],
        [waiting_tasks_count] AS [WaitCount],
       100.0 * [wait_time_ms] / SUM ([wait_time_ms]) OVER() AS [Percentage],
        ROW_NUMBER() OVER(ORDER BY [wait_time_ms] DESC) AS [RowNum]
    FROM sys.dm_os_wait_stats
    WHERE [wait_type] NOT IN (
        N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR',
        N'BROKER_TASK_STOP', N'BROKER_TO_FLUSH',
        N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',
        N'CHKPT', N'CLR_AUTO_EVENT',
        N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE',
 
        -- Maybe uncomment these four if you have mirroring issues
        N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE',
        N'DBMIRROR_WORKER_QUEUE', N'DBMIRRORING_CMD',
 
        N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',
        N'EXECSYNC', N'FSAGENT',
        N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',
 
        -- Maybe uncomment these six if you have AG issues
        N'HADR_CLUSAPI_CALL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        N'HADR_LOGCAPTURE_WAIT', N'HADR_NOTIFICATION_DEQUEUE',
        N'HADR_TIMER_TASK', N'HADR_WORK_QUEUE',
 
        N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP',
        N'LOGMGR_QUEUE', N'MEMORY_ALLOCATION_EXT',
        N'ONDEMAND_TASK_QUEUE',
        N'PREEMPTIVE_XE_GETTARGETSTATE',
        N'PWAIT_ALL_COMPONENTS_INITIALIZED',
        N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        N'QDS_SHUTDOWN_QUEUE', N'REDO_THREAD_PENDING_WORK',
        N'REQUEST_FOR_DEADLOCK_SEARCH', N'RESOURCE_QUEUE',
        N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH',
        N'SLEEP_DBSTARTUP', N'SLEEP_DCOMSTARTUP',
        N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY',
        N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP',
        N'SLEEP_SYSTEMTASK', N'SLEEP_TASK',
        N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT',
        N'SP_SERVER_DIAGNOSTICS_SLEEP', N'SQLTRACE_BUFFER_FLUSH',
        N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
        N'SQLTRACE_WAIT_ENTRIES', N'WAIT_FOR_RESULTS',
        N'WAITFOR', N'WAITFOR_TASKSHUTDOWN',
        N'WAIT_XTP_RECOVERY',
        N'WAIT_XTP_HOST_WAIT', N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
        N'WAIT_XTP_CKPT_CLOSE', N'XE_DISPATCHER_JOIN',
        N'XE_DISPATCHER_WAIT', N'XE_TIMER_EVENT')
    AND [waiting_tasks_count] > 0
    )
SELECT
    MAX ([W1].[wait_type]) AS [WaitType],
    CAST (MAX ([W1].[WaitS]) AS DECIMAL (16,2)) AS [Wait_S],
    CAST (MAX ([W1].[ResourceS]) AS DECIMAL (16,2)) AS [Resource_S],
    CAST (MAX ([W1].[SignalS]) AS DECIMAL (16,2)) AS [Signal_S],
    MAX ([W1].[WaitCount]) AS [WaitCount],
    CAST (MAX ([W1].[Percentage]) AS DECIMAL (5,2)) AS [Percentage],
    CAST ((MAX ([W1].[WaitS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgWait_S],
    CAST ((MAX ([W1].[ResourceS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgRes_S],
    CAST ((MAX ([W1].[SignalS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgSig_S],
    CAST ('https://www.sqlskills.com/help/waits/' + MAX ([W1].[wait_type]) as XML) AS [Help/Info URL]
FROM [Waits] AS [W1]
INNER JOIN [Waits] AS [W2]
    ON [W2].[RowNum] <= [W1].[RowNum]
GROUP BY [W1].[RowNum]
HAVING SUM ([W2].[Percentage]) - MAX( [W1].[Percentage] ) < 95; -- percentage threshold
GO

--	TempDB Contention Analysis
Select session_id, wait_type, wait_duration_ms, blocking_session_id, resource_Description, Descr.*
From sys.dm_os_waiting_tasks as waits inner join sys.dm_os_buffer_Descriptors as Descr
	on LEFT(waits.resource_description, Charindex(':', waits.resource_description,0)-1) = Descr.database_id
	and SUBSTRING(waits.resource_description, Charindex(':', waits.resource_description)+1,Charindex(':', waits.resource_description,Charindex(':', resource_description)+1)- (Charindex(':', resource_description)+1)) = Descr.[file_id]
	and Right(waits.resource_description, Len(waits.resource_description) - Charindex(':', waits.resource_description, 3)) = Descr.[page_id]
Where wait_type Like 'PAGE%LATCH_%';

With Tasks
As (Select session_id,
       wait_type,
       wait_duration_ms,
       blocking_session_id,
       resource_description,
       PageID = Cast(Right(resource_description, Len(resource_description)
               - Charindex(':', resource_description, 3)) As Int)
   From sys.dm_os_waiting_tasks
   Where wait_type Like 'PAGE%LATCH_%'
   And resource_description Like '2:%')
Select session_id,
       wait_type,
       wait_duration_ms,
       blocking_session_id,
       resource_description,
   ResourceType = Case
       When PageID = 1 Or PageID % 8088 = 0 Then 'Is PFS Page'
       When PageID = 2 Or PageID % 511232 = 0 Then 'Is GAM Page'
       When PageID = 3 Or (PageID - 1) % 511232 = 0 Then 'Is SGAM Page'
       Else 'Is Not PFS, GAM, or SGAM page'
   End
From Tasks;

--	Use below query to find elapsed time, and memory grants for queries
SELECT 
  [table] = SUBSTRING(t.[text], 1, CHARINDEX(N'*/', t.[text])),
  s.last_elapsed_time, 
  s.last_grant_kb, 
  s.max_ideal_grant_kb
FROM sys.dm_exec_query_stats AS s 
CROSS APPLY sys.dm_exec_sql_text(s.sql_handle) AS t
WHERE t.[text] LIKE N'%/*%dbo.'+N'Email_V%' 
ORDER BY s.last_grant_kb;

--	Generate Random Email IDs
SELECT TOP (10000) 
  REPLACE(LEFT(LEFT(c.name, 64) + '@' + LEFT(o.name, 128) + '.com', 254), ' ', '')
FROM sys.all_columns AS c
INNER JOIN sys.all_objects AS o
  ON c.[object_id] = o.[object_id]
INNER JOIN sys.all_columns AS c2
  ON c.[object_id] = c2.[object_id]
ORDER BY NEWID();



--	Find all objects with Size, and record counts
SELECT 
    t.NAME AS TableName,
    s.Name AS SchemaName,
    p.rows AS RowCounts,
    SUM(a.total_pages) * 8 AS TotalSpaceKB, 
    CAST(ROUND(((SUM(a.total_pages) * 8) / 1024.00), 2) AS NUMERIC(36, 2)) AS TotalSpaceMB,
    SUM(a.used_pages) * 8 AS UsedSpaceKB, 
    CAST(ROUND(((SUM(a.used_pages) * 8) / 1024.00), 2) AS NUMERIC(36, 2)) AS UsedSpaceMB, 
    (SUM(a.total_pages) - SUM(a.used_pages)) * 8 AS UnusedSpaceKB,
    CAST(ROUND(((SUM(a.total_pages) - SUM(a.used_pages)) * 8) / 1024.00, 2) AS NUMERIC(36, 2)) AS UnusedSpaceMB
FROM 
    sys.tables t
INNER JOIN      
    sys.indexes i ON t.OBJECT_ID = i.object_id
INNER JOIN 
    sys.partitions p ON i.object_id = p.OBJECT_ID AND i.index_id = p.index_id
INNER JOIN 
    sys.allocation_units a ON p.partition_id = a.container_id
LEFT OUTER JOIN 
    sys.schemas s ON t.schema_id = s.schema_id
WHERE 
    t.NAME NOT LIKE 'dt%' 
    AND t.is_ms_shipped = 0
    AND i.OBJECT_ID > 255 
GROUP BY 
    t.Name, s.Name, p.Rows
ORDER BY 
    UnusedSpaceMB DESC
