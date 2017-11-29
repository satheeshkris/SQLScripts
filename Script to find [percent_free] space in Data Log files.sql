--	Created By:	Ajay Dwivedi
--	Purpose:	Script to find [percent_free] space in Data/Log files
--	Inputs:		2

SET NOCOUNT ON;
IF OBJECT_ID('tempdb..#FileSpace') IS NOT NULL
	DROP TABLE #FileSpace
GO
--	Create table for storing free space
CREATE TABLE #FileSpace 
(
	databaseName sysname, name sysname, physical_name varchar(max), isLogFile tinyint, size float,  free float
);

--	Find free space for files
INSERT INTO #FileSpace
	(databaseName, name, physical_name, isLogFile, size, free)
EXEC sp_MSforeachdb '
USE [?];
SELECT ''?'' as databaseName, name, physical_name, FILEPROPERTY(name,''IsLogFile'') as isLogFile, size, FILEPROPERTY(name, ''SpaceUsed'') as free FROM sys.database_files as f where DB_ID() not in (1,2,3,4) 
';

/*
select * 
		,ROW_NUMBER()OVER(ORDER BY free DESC) as ID
		,Total_Freed_Till_Now = SUM(free) OVER( ORDER BY free DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)/1024
From #FileSpace s 
ORDER BY free DESC
*/
--	Display Shrink command
SELECT '
USE ['+databaseName+']
GO
DBCC SHRINKFILE (N'''+name+''' , '+cast(convert(numeric,(size-free+1) ) as varchar(50))+')
GO
--	Space freed = '+CAST( (SUM(free) OVER( ORDER BY free DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))/1024.0 AS VARCHAR(20))+' MB
'	
FROM #FileSpace s 
WHERE 
	s.physical_name LIKE 'C:\%' --INPUT 01: Provide file path here
	AND s.isLogFile = 0 --INPUT 02: Consider Data FIles only
ORDER BY free DESC;

