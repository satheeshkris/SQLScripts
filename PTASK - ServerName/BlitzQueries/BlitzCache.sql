EXEC tempdb..sp_BlitzCache @Help = 1
EXEC tempdb..sp_BlitzCache @ExpertMode = 1, @ExportToExcel = 1

--	https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit#common-sp_blitzcache-parameters
EXEC tempdb..sp_BlitzCache @Top = 200, @SortOrder = 'reads' -- logical reads when PAGEIOLATCH_SH is most prominent wait type
EXEC tempdb..sp_BlitzCache @Top = 200, @SortOrder = 'writes' -- logical reads when PAGEIOLATCH_SH is most prominent wait type
EXEC tempdb..sp_BlitzCache @Top = 50, @SortOrder = 'memory grant' -- logical reads when PAGEIOLATCH_SH is most prominent wait type

--	Analyze using Procedure Name
exec tempdb..sp_BlitzCache @StoredProcName = 'uspGetUsersByAge'

--	Analyze using Query Hash in case SQL Code is not procedure
exec tempdb..sp_BlitzCache @OnlyQueryHashes = '0x998533A642130191'
