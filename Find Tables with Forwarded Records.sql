/*	Created By:		AJAY DWIVEDI
	Purpose:		Find tables with forwarded records
*/
IF OBJECT_ID('tempdb..##HeapTablesWithForwarededRecords') IS NOT NULL
	TRUNCATE TABLE ##HeapTablesWithForwarededRecords
CREATE TABLE ##HeapTablesWithForwarededRecords
(	DbName SYSNAME,TableName SYSNAME,index_id SMALLINT, index_type_desc VARCHAR(100), 
	avg_fragmentation_in_percent SMALLINT,page_count INT, record_count INT, forwarded_record_count INT
)

INSERT ##HeapTablesWithForwarededRecords
exec sp_msforeachtable '
SELECT	DB_NAME() as DbName,OBJECT_NAME(object_id) as TableName,index_id, index_type_desc, avg_fragmentation_in_percent,page_count, record_count, forwarded_record_count
FROM	sys.dm_db_index_physical_stats
(
	DB_ID(''dbirtc'')
	,OBJECT_ID(''?'')
	,NULL
	,NULL
	,''DETAILED''
)
';

;with t1 as (select distinct tablename from ##HeapTablesWithForwarededRecords where index_type_desc = 'HEAP' and forwarded_record_count > 0)
select tableName from ##HeapTablesWithForwarededRecords where tablename in (select tablename from t1) and forwarded_record_count is not null ;