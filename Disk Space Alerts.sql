

USE MSDB
GO

ALTER PROC FreeDiskAlerts
AS
	BEGIN
	SET NOCOUNT ON;
    IF OBJECT_ID('tempdb.dbo.FreeHardDiskSpace') IS NULL
	BEGIN
		CREATE TABLE tempdb.[dbo].[FreeHardDiskSpace](
			[Drive] [nvarchar](1) NULL,
			[total_size_mb] [bigint] NULL,
			[free_size_mb] [bigint] NULL,
			[Percentage_Free] [bigint] NULL,
			[Has_Log] [int] NULL,
			[Threshold] [int] NULL
		)
	END
 
	TRUNCATE TABLE tempdb.[dbo].[FreeHardDiskSpace];

	INSERT INTO tempdb.[dbo].[FreeHardDiskSpace]
	SELECT	*
	FROM (
			SELECT	T_OUTER.Drive, T_OUTER.[total_size_mb], T_OUTER.[free_size_mb]
					,[Percentage_Free] = (T_OUTER.[free_size_mb]*100)/T_OUTER.[total_size_mb] 
					,MAX(T_OUTER.Has_Log) as Has_Log
					--Set threshold for data and log files. High threshold for Log drive
					,[Threshold] = CASE WHEN MAX(T_OUTER.Has_Log)=1 THEN 15 ELSE 10 END
			FROM	(
					select	distinct left(s.volume_mount_point,1) as Drive
							,((s.total_bytes/1024)/1024) as [total_size_mb]
							,((s.available_bytes/1024)/1024) as [free_size_mb]
							,CASE WHEN type_desc='LOG' THEN 1 ELSE 0 END as Has_Log
					from sys.master_files as f
					CROSS APPLY 
					sys.dm_os_volume_stats(f.database_id, f.[file_id]) as s
			) AS T_OUTER
			GROUP BY T_OUTER.Drive, T_OUTER.[total_size_mb], T_OUTER.[free_size_mb]
	) as T_FINAL;

	IF ((SELECT COUNT(1) FROM tempdb.[dbo].[FreeHardDiskSpace] WHERE Drive = 'C') = 0)
	BEGIN
		--LOGIC
		IF OBJECT_ID('tempdb..#FreeHardDiskSpace') IS NOT NULL
		DROP TABLE tempdb..#FreeHardDiskSpace

		 CREATE TABLE #FreeHardDiskSpace 
		 (
		  Drive     CHAR(1),
		  FreeMB    INT
		 )    

		INSERT INTO #FreeHardDiskSpace(Drive,FreeMB)
		EXEC MASTER.dbo.xp_fixeddrives

		INSERT INTO tempdb.dbo.[FreeHardDiskSpace] (Drive,free_size_mb,Percentage_Free,Has_Log,Threshold)
		SELECT Drive,FreeMB,(FreeMB/1024),0,(5*1024)
		FROM #FreeHardDiskSpace WHERE Drive = 'C'
	END

	--select * from tempdb.[dbo].[FreeHardDiskSpace] WHERE Percentage_Free <= Threshold;

	IF (SELECT COUNT(1) FROM tempdb.[dbo].[FreeHardDiskSpace] WHERE Percentage_Free <= Threshold ) > 0
	BEGIN
		DECLARE @subject NVARCHAR(500)
				,@body NVARCHAR(2000) = ''

		SELECT @subject = 'Free Space Alert from Server ' + @@SERVERNAME;
		SELECT @body = @body + 'Free space on ' + Drive + ':\ Drive is below threshold value of ' + (CASE WHEN Drive='C' THEN CAST(Threshold AS VARCHAR(15)) + ' GB' ELSE CAST(Threshold AS VARCHAR(15))+ '%' END) +'
'

		FROM tempdb.[dbo].[FreeHardDiskSpace] WHERE Percentage_Free <= Threshold;

		SET @body = @body + '

Kindly take appropriate action on priority basis.


Regards,
SQL Server Disk Alerts
'
		PRINT @body;
		EXEC msdb.dbo.sp_send_dbmail         
		--@recipients = 'manisha.verma@hm.com' ,    
		@recipients = 'ak.dwivedi@ericsson.com' ,    
		@copy_recipients='ajay.dwivedi2007@gmail.com',        
		--@Profile_Name='Disk_Space_Alert',
		@Profile_Name='admin',
		@subject = @subject ,
		@body = @body

	END
  END
GO 

--exec FreeDiskAlerts