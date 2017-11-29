use tempdb
EXEC tempdb..sp_BlitzIndex @DatabaseName = 'VDP' ,@BringThePain = 1 -- Bring only main issues
EXEC tempdb..sp_BlitzIndex @DatabaseName = 'FMO' ,@BringThePain = 1 -- Bring only main issues
EXEC tempdb..sp_BlitzIndex @DatabaseName = 'SRA' ,@BringThePain = 1 -- Bring only main issues
EXEC tempdb..sp_BlitzIndex @DatabaseName = 'Subronow', @SchemaName = 'dbo', @TableName = '0071 - CCDI Data Table'
