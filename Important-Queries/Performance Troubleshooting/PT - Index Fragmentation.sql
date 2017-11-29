--Query to check index fragmentation history
;WITH T_TableCounts AS
(
	select t.name TableName, i.rows Records
	from sysobjects t, sysindexes i
	where t.xtype = 'U' and i.id = t.id and i.indid in (0,1)
)
,T_Indexes AS
(
	SELECT OBJECT_NAME(ind.OBJECT_ID) AS TableName, 
	ind.name AS IndexName, indexstats.index_type_desc AS IndexType, 
	indexstats.avg_fragmentation_in_percent 
	FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, NULL) indexstats 
	INNER JOIN sys.indexes ind  
	ON ind.object_id = indexstats.object_id 
	AND ind.index_id = indexstats.index_id 
	WHERE indexstats.avg_fragmentation_in_percent > 30
)
SELECT	i.*, c.Records
FROM	T_Indexes as i
LEFT JOIN
		T_TableCounts AS c
	ON	c.TableName = i.TableName
ORDER BY avg_fragmentation_in_percent DESC;