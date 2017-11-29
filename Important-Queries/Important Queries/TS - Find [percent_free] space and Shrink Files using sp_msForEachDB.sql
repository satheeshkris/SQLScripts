--	Created By:	Ajay Dwivedi
--	Purpose:	Script to Find [percent_free] space and Shrink Files using sp_msForEachDB
--	Inputs:		2 (Mount Point & Threshold)			[CTRL][SHIFT][M]

SET NOCOUNT ON;

DECLARE @Path VARCHAR(50) = 'C:\' -- Input 01: Mount Point with \ in last
		,@FreeSpaceThresholdInPercent FLOAT = 20.0 -- Input 02: Threshold in %

DECLARE @volume_mount_point VARCHAR(256), 
		@MountPoint_SizeInGB FLOAT, 
		@MountPoint_FreeSpaceInGB FLOAT, 
		@MountPoint_PercentFreeSpace FLOAT, 
		@MountPoint_SizeInMB FLOAT, 
		@MountPoint_FreeSpaceInMB FLOAT

--	Create table for storing free space
IF OBJECT_ID('tempdb..#FileSpace') IS NOT NULL
	DROP TABLE #FileSpace;
CREATE TABLE #FileSpace 
(
	databaseName sysname, name sysname, physical_name varchar(max), isLogFile tinyint, File_SizeInMB float,  
	File_FreeSpaceInMB float, volume_mount_point varchar(256), MountPoint_SizeInMB float, MountPoint_FreeSpaceInMB float, 
	MountPoint_SizeInGB float, MountPoint_FreeSpaceInGB float, [MountPoint_PercentFreeSpace] as ((MountPoint_FreeSpaceInMB/MountPoint_SizeInMB)*100)
);

--	Find free space for files
INSERT INTO #FileSpace
	(databaseName, name, physical_name, isLogFile, File_SizeInMB, File_FreeSpaceInMB, volume_mount_point, 
		MountPoint_SizeInMB, MountPoint_FreeSpaceInMB, MountPoint_SizeInGB, MountPoint_FreeSpaceInGB)
EXEC sp_MSforeachdb '
USE [?];
select	''?'' as databaseName, f.name, f.physical_name, FILEPROPERTY(name,''IsLogFile'') as isLogFile, f.size/128.0 as File_SizeInMB, f.size/128.0 - CAST(FILEPROPERTY(f.name, ''SpaceUsed'') AS int)/128.0 AS File_FreeSpaceInMB
		,s.volume_mount_point, s.total_bytes/1024.0/1024.0 as MountPoint_SizeInMB, s.available_bytes/1024.0/1024.0 AS MountPoint_FreeSpaceInMB
		,s.total_bytes/1024.0/1024.0/1024.0 as MountPoint_SizeInGB, s.available_bytes/1024.0/1024.0/1024.0 AS MountPoint_FreeSpaceInGB
from	sys.database_files f
cross apply
		sys.dm_os_volume_stats(DB_ID(''?''), f.file_id) s
';

SELECT	@volume_mount_point=s.volume_mount_point, @MountPoint_SizeInGB=s.MountPoint_SizeInGB, @MountPoint_FreeSpaceInGB=s.MountPoint_FreeSpaceInGB, 
		@MountPoint_PercentFreeSpace=s.MountPoint_PercentFreeSpace, @MountPoint_SizeInMB=S.MountPoint_SizeInMB, @MountPoint_FreeSpaceInMB=S.MountPoint_FreeSpaceInMB
FROM	#FileSpace s
WHERE	s.volume_mount_point LIKE @Path+'%'
GROUP BY s.volume_mount_point, s.MountPoint_SizeInGB, s.MountPoint_FreeSpaceInGB, s.MountPoint_PercentFreeSpace
		,S.MountPoint_SizeInMB, S.MountPoint_FreeSpaceInMB

PRINT	'/*	**************** Analyzing Mount Point for path '''+@Path+''' **************************
	Total Size = '+cast(@MountPoint_SizeInMB as varchar(20))+ ' MB = '+cast(@MountPoint_SizeInGB as varchar(20))+ ' GB
	Available Space = '+cast(@MountPoint_FreeSpaceInMB as varchar(20))+ ' MB = '+cast(@MountPoint_FreeSpaceInGB as varchar(20))+ ' GB
	% Free Space = '+cast(@MountPoint_PercentFreeSpace as varchar(20))+ '
	Space to Add ('+cast(@FreeSpaceThresholdInPercent as varchar(10))+'% threshold) = '+ IIF( ((@FreeSpaceThresholdInPercent*@MountPoint_SizeInMB)/100)>@MountPoint_FreeSpaceInMB,cast(((@FreeSpaceThresholdInPercent*@MountPoint_SizeInMB)/100)-@MountPoint_FreeSpaceInMB as varchar(20))+' MB','_____Mount Point has sufficient space_____')+'

NOTE: Files would not shrink below initial size. So below values are only estimation. Please re-run the script to refresh this result each time
*/
';

--	Display Shrink command
SELECT '
USE ['+databaseName+']
GO
DBCC SHRINKFILE (N'''+name+''' , '+cast(convert(numeric,(File_SizeInMB-File_FreeSpaceInMB+1) ) as varchar(50))+')
GO
--	Space freed on ['+databaseName+'] = '+cast(File_FreeSpaceInMB-1 as varchar(50))+' MB
--	Total Space freed = '+CAST( (SUM(File_FreeSpaceInMB-1) OVER( ORDER BY File_FreeSpaceInMB DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS VARCHAR(20))+' MB
'	
FROM #FileSpace s 
WHERE s.volume_mount_point LIKE @Path+'%'
AND	File_FreeSpaceInMB > 1
ORDER BY File_FreeSpaceInMB DESC;
GO