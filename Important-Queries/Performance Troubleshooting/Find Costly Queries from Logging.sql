use tempdb
/*
--	Step 3: Query the resultset
SELECT TOP 10 * FROM tempdb..WhoIsActive_ResultSets r with (nolock)
	WHERE CAST(r.collection_time AS DATE) = CAST(GETDATE() AS date)
	ORDER BY collection_time DESC;

--	Find size of collected Data
SELECT 
    t.NAME AS TableName,    
    p.rows AS RowCounts,
    CONVERT(DECIMAL,SUM(a.total_pages)) * 8.0 / 1024 / 1024 AS TotalSpaceGB, 
	CONVERT(DECIMAL,SUM(a.total_pages)) * 8.0 / 1024 AS TotalSpaceMB, 
    SUM(a.used_pages)  * 8 / 1024 / 1024 AS UsedSpaceGB , 
    (SUM(a.total_pages) - SUM(a.used_pages)) * 8.0 / 1024 / 1024 AS UnusedSpaceGB,
	(SUM(a.total_pages) - SUM(a.used_pages)) * 8.0 / 1024 AS UnusedSpaceMB
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
    t.NAME = 'WhoIsActive_ResultSets'
    AND t.is_ms_shipped = 0
    AND i.OBJECT_ID > 255 
GROUP BY 
    t.Name, s.Name, p.Rows;
*/
/*
exec sp_healthCheck
exec sp_helpdb 'tempdb'
*/

;WITH T_Queries_Text AS 
(	SELECT [dd hh:mm:ss.mss], [dd hh:mm:ss.mss (avg)], session_id, cast(sql_text as nvarchar(max)) as sql_text, login_name, wait_info, tasks, tran_log_writes, CAST(REPLACE(CPU,',','') AS bigint) AS CPU, tempdb_allocations, tempdb_current, blocking_session_id, blocked_session_count, CAST(REPLACE(reads,',','') AS bigint) AS reads, CAST(REPLACE(writes,',','') AS bigint) AS writes, context_switches, CAST(REPLACE(physical_io,',','') AS bigint) AS physical_io, CAST(REPLACE(physical_reads,',','') AS bigint) AS physical_reads, query_plan, locks, used_memory, status, tran_start_time, open_tran_count, percent_complete, host_name, database_name, program_name, additional_info, start_time, login_time, request_id, collection_time 
	FROM tempdb..WhoIsActive_ResultSets r with (nolock)
)
,T_Queries_Ranks AS (
	SELECT	*
			,DENSE_RANK() OVER (PARTITION BY sql_text, session_id ORDER BY collection_time DESC) as QueryRankID
	FROM	T_Queries_Text
)
SELECT	database_name, [dd hh:mm:ss.mss], session_id, sql_text, login_name, wait_info, tran_log_writes, CPU, tempdb_allocations, blocking_session_id, blocked_session_count, reads, writes, query_plan, locks, used_memory, status, tran_start_time, open_tran_count, host_name, program_name, additional_info, collection_time
FROM	T_Queries_Ranks
WHERE	QueryRankID = 1
AND		reads > 1000
AND		database_name NOT IN ('uhtdba')
ORDER BY reads DESC;

