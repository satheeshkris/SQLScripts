SELECT  OBJECT_NAME(S.[OBJECT_ID]) AS [OBJECT NAME], 
		I.[NAME] AS [INDEX NAME], 
		i.object_id,
		STATS_DATE(I.object_id, I.index_id) AS statistics_update_date,
        USER_SEEKS, 
        USER_SCANS, 
        USER_LOOKUPS, 
        USER_UPDATES 
FROM    SYS.DM_DB_INDEX_USAGE_STATS AS S 
INNER JOIN 
		SYS.INDEXES AS I 
ON		I.[OBJECT_ID] = S.[OBJECT_ID] 
	AND	I.INDEX_ID = S.INDEX_ID
WHERE    OBJECTPROPERTY(S.[OBJECT_ID],'IsUserTable') = 1 
AND		 OBJECT_NAME(S.[OBJECT_ID]) = 'RA_Booked_Resources'


-- Missing Index Script
 -- Original Author: Pinal Dave (C) 2011
 SELECT TOP 25
 dm_mid.database_id AS DatabaseID,
 dm_migs.avg_user_impact*(dm_migs.user_seeks+dm_migs.user_scans) Avg_Estimated_Impact,
 dm_migs.last_user_seek AS Last_User_Seek,
 OBJECT_NAME(dm_mid.OBJECT_ID,dm_mid.database_id) AS [TableName],
 'CREATE INDEX [IX_' + OBJECT_NAME(dm_mid.OBJECT_ID,dm_mid.database_id) + '_'
 + REPLACE(REPLACE(REPLACE(ISNULL(dm_mid.equality_columns,''),', ','_'),'[',''),']','') +
 CASE
 WHEN dm_mid.equality_columns IS NOT NULL AND dm_mid.inequality_columns IS NOT NULL THEN '_'
 ELSE ''
 END
 + REPLACE(REPLACE(REPLACE(ISNULL(dm_mid.inequality_columns,''),', ','_'),'[',''),']','')
 + ']'
 + ' ON ' + dm_mid.statement
 + ' (' + ISNULL (dm_mid.equality_columns,'')
 + CASE WHEN dm_mid.equality_columns IS NOT NULL AND dm_mid.inequality_columns IS NOT NULL THEN ',' ELSE
 '' END
 + ISNULL (dm_mid.inequality_columns, '')
 + ')'
 + ISNULL (' INCLUDE (' + dm_mid.included_columns + ')', '') AS Create_Statement
 FROM sys.dm_db_missing_index_groups dm_mig
 INNER JOIN sys.dm_db_missing_index_group_stats dm_migs
 ON dm_migs.group_handle = dm_mig.index_group_handle
 INNER JOIN sys.dm_db_missing_index_details dm_mid
 ON dm_mig.index_handle = dm_mid.index_handle
 WHERE dm_mid.database_ID = DB_ID()
 AND	 OBJECT_NAME(dm_mid.OBJECT_ID,dm_mid.database_id)  = 'RA_Booked_Resources'
 ORDER BY Avg_Estimated_Impact DESC
 GO