--	Notes for providing SQL Server Logs

--	https://sqlandme.com/2012/01/25/sql-server-reading-errorlog-with-xp_readerrorlog/
--	https://www.mssqltips.com/sqlservertip/1476/reading-the-sql-server-log-files-using-tsql/
--	https://www.mssqltips.com/sqlservertip/1307/simple-way-to-find-errors-in-sql-server-error-log/

EXEC master.dbo.xp_readerrorlog 0, 1, NULL, NULL, '2016-11-17 00:00:00.000', '2016-11-18 00:00:00.000', N'asc' 
Get-EventLog -LogName System -Message "*shutdown*" |Select * | Out-File 'C:\TEmp\serverName.txt'
Select-String -Pattern "Configuration Option" -Path ".\ERRORLOG*"
Get-EventLog -LogName Application -Message "*Configuration Option*"
Get-ChildItem -recurse | Select-String -pattern "dummy" | group path | select name

--SELECT GETDATE()
/*
EXEC xp_ReadErrorLog    <LogNumber>, <LogType>,
                        <SearchTerm1>, <SearchTerm2>,
                        <StartDate>, <EndDate>, <SortOrder>


1.Value of error log file you want to read: 0 = current, 1 = Archive #1, 2 = Archive #2, etc... 
2.Log file type: 1 or NULL = error log, 2 = SQL Agent log 
3.Search string 1: String one you want to search for 
4.Search string 2: String two you want to search for to further refine the results 
5.Search from start time   
6.Search to end time  
7.Sort order for results: N'asc' = ascending, N'desc' = descending
*/

use msdb
go

SELECT object_name(i.object_id) as objectName,
i.[name] as indexName,
sum(a.total_pages) as totalPages,
sum(a.used_pages) as usedPages,
sum(a.data_pages) as dataPages,
(sum(a.total_pages) * 8) / 1024 as totalSpaceMB,
(sum(a.used_pages) * 8) / 1024 as usedSpaceMB,
(sum(a.data_pages) * 8) / 1024 as dataSpaceMB
FROM sys.indexes i
INNER JOIN sys.partitions p
ON i.object_id = p.object_id
AND i.index_id = p.index_id
INNER JOIN sys.allocation_units a
ON p.partition_id = a.container_id
GROUP BY i.object_id, i.index_id, i.[name]
ORDER BY sum(a.total_pages) DESC, object_name(i.object_id)
GO

--	Find Rebuild index job status
use uhtdba

;with dbs as
(	select top 1000 * from sys.databases where database_id > 4 and source_database_id is null order by name )
, lastRunStatus as
(
	select dbName, min(logDTS) as StartTime, max(logDTS) as EndTime from dbo.InfrastructureRunLog c where procName = 'usp_rebuild_indexes_all' and cast(jobStartDTS as date) = '2017-03-12'
	group by dbName
)
, currentRunStatus as
(
	select dbName, min(logDTS) as StartTime, max(logDTS) as EndTime from dbo.InfrastructureRunLog c where procName = 'usp_rebuild_indexes_all' and cast(jobStartDTS as date) = '2017-03-19'
	group by dbName
)
select d.database_id, d.name, DATEDIFF(MINUTE,lr.starttime, lr.endtime) as Last_ExecutionTime_MM, DATEDIFF(MINUTE,cr.starttime, cr.endtime) as Current_ExecutionTime_MM
from dbs as d
left join
	lastRunStatus as lr
on db_id(lr.dbName) = d.database_id
left join
	currentRunStatus as cr
on db_id(cr.dbName) = d.database_id
order by name desc

--	Running jobs
SELECT
    ja.job_id,
    j.name AS job_name,
    ja.start_execution_date, 
	DATEDIFF(HH,ja.start_execution_date,GETDATE()) AS [Time in hrs],    
    ISNULL(last_executed_step_id,0)+1 AS current_executed_step_id,
    Js.step_name
FROM msdb.dbo.sysjobactivity ja 
LEFT JOIN msdb.dbo.sysjobhistory jh 
    ON ja.job_history_id = jh.instance_id
JOIN msdb.dbo.sysjobs j 
ON ja.job_id = j.job_id
JOIN msdb.dbo.sysjobsteps js
    ON ja.job_id = js.job_id
    AND ISNULL(ja.last_executed_step_id,0)+1 = js.step_id
WHERE ja.session_id = (SELECT TOP 1 session_id FROM msdb.dbo.syssessions ORDER BY agent_start_date DESC)
AND start_execution_date is not null
AND stop_execution_date is null;


