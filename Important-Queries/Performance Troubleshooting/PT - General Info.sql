/*	Find Statistics Update Date – Update Statistics
		http://blog.sqlauthority.com/2010/01/25/sql-server-find-statistics-update-date-update-statistics/
*/

USE StackOverflow
GO

--	01
SELECT	name AS index_name,	STATS_DATE(OBJECT_ID, index_id) AS StatsUpdated
FROM	sys.indexes
WHERE	OBJECT_ID = OBJECT_ID('dbo.Users')
GO

--	02
SELECT	OBJECT_NAME(object_id) AS [ObjectName]
		,[name] AS [StatisticName]
		,STATS_DATE([object_id], [stats_id]) AS [StatisticUpdateDate]
FROM	sys.stats
WHERE	OBJECT_ID = OBJECT_ID('dbo.Users');

--	03
DBCC SHOW_STATISTICS('dbo.Users'
                     ,PK_Users_Id)

/*	Fragmentation – Detect Fragmentation and Eliminate Fragmentation
		http://blog.sqlauthority.com/2010/01/12/sql-server-fragmentation-detect-fragmentation-and-eliminate-fragmentation/
*/
USE StackOverflow
GO

--	01
SELECT	DB_NAME(database_id) as DBName, OBJECT_NAME(OBJECT_ID) as TableName, i.name as IndexName, index_type_desc, index_level, alloc_unit_type_desc,
		avg_fragmentation_in_percent, avg_page_space_used_in_percent, page_count, record_count, ghost_record_count, forwarded_record_count
FROM	sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL, NULL , 'SAMPLED') as indexstats
CROSS APPLY
	(	SELECT ind.name FROM sys.indexes ind WHERE ind.object_id = indexstats.object_id AND ind.index_id = indexstats.index_id		
	) AS i
WHERE	object_id = OBJECT_ID('dbo.Users')
ORDER BY avg_fragmentation_in_percent DESC


-- How much memory is used by each database in SQL Server?
--	https://www.mssqltips.com/sqlservertip/2393/determine-sql-server-memory-use-by-database-and-object/
SELECT
    CASE WHEN database_id = 32767 THEN 'Resource DB' ELSE DB_NAME (database_id) END AS 'DBName',
    COUNT (1) AS 'Page Count',
    (COUNT (1) * 8)/1024 AS 'Memory Used in MB' ,   
   CASE WHEN is_modified = 1 THEN 'Dirty Page' ELSE 'Clean Page' END AS 'Page State'
FROM sys.dm_os_buffer_descriptors
   GROUP BY [database_id], [is_modified]
   ORDER BY   db_name(database_id)
GO

-- Note: querying sys.dm_os_buffer_descriptors
-- requires the VIEW_SERVER_STATE permission.

DECLARE @total_buffer INT;

SELECT @total_buffer = cntr_value
FROM sys.dm_os_performance_counters 
WHERE RTRIM([object_name]) LIKE '%Buffer Manager'
AND counter_name = 'Database Pages';

;WITH src AS
(
SELECT 
database_id, db_buffer_pages = COUNT_BIG(*)
FROM sys.dm_os_buffer_descriptors
--WHERE database_id BETWEEN 5 AND 32766
GROUP BY database_id
)
SELECT
[db_name] = CASE [database_id] WHEN 32767 
THEN 'Resource DB' 
ELSE DB_NAME([database_id]) END,
db_buffer_pages,
db_buffer_MB = db_buffer_pages / 128,
db_buffer_percent = CONVERT(DECIMAL(6,3), 
db_buffer_pages * 100.0 / @total_buffer)
FROM src
ORDER BY db_buffer_MB DESC;

