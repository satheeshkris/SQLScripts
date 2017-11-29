IF OBJECT_ID('tempdb..#MyTempTable') IS NOT NULL
	DROP TABLE #MyTempTable;
SELECT * INTO #MyTempTable 
FROM OPENROWSET('Microsoft.ACE.OLEDB.12.0',
						'Excel 12.0 Xml;HDR=YES;Database=E:\NEON_UPLOAD_Docs\DBUploadFiles\myexcel.xlsx',
						'SELECT * FROM [RAN In Progress Future$]');

select * into tempdb..mytable from #MyTempTable

--  ====================================================================================================================
SELECT * FROM
OPENROWSET ('SQLOLEDB','Server=(local);Trusted_Connection=yes','SET FMTONLY OFF EXEC msdb.dbo.sp_help_job_with_results')

--xp_dirtree 'e:\everyone\prince\DTRA',1,1