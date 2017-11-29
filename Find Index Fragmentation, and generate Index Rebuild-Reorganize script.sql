USE [AdventureWorks2014]
GO

--	Find Index Fragmentation, and generate Index Rebuild/Re-organize script
SELECT	--QUOTENAME(OBJECT_SCHEMA_NAME (OBJECT_ID))+'.'+QUOTENAME(OBJECT_NAME(OBJECT_ID)) as TableName, index_id, idx.name, index_type_desc,index_level,
		--avg_fragmentation_in_percent,avg_page_space_used_in_percent,page_count,
		CASE	WHEN	avg_fragmentation_in_percent BETWEEN 5 AND 30
				THEN	'
ALTER INDEX '+QUOTENAME(idx.name)+' ON '+QUOTENAME(OBJECT_SCHEMA_NAME (OBJECT_ID))+'.'+QUOTENAME(OBJECT_NAME(OBJECT_ID))+'
REORGANIZE ; 
GO
'				ELSE	'
ALTER INDEX '+QUOTENAME(idx.name)+' ON '+QUOTENAME(OBJECT_SCHEMA_NAME (OBJECT_ID))+'.'+QUOTENAME(OBJECT_NAME(OBJECT_ID))+'
REBUILD WITH (SORT_IN_TEMPDB = ON, ONLINE = ON);
GO
'				END	AS [Rebuild/Reorganize]
FROM	sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL, NULL , 'SAMPLED') AS ips
CROSS APPLY
	(	SELECT i.name 
		FROM sys.indexes AS i
		WHERE I.index_id = ips.index_id AND I.object_id = ips.object_id
					
	) as idx
WHERE ips.avg_fragmentation_in_percent > 5
AND	ips.page_count > 3
ORDER BY avg_fragmentation_in_percent DESC
