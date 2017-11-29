/* Created By:	AJAY DWIVEDI
   Inputs:	1
*/

SET NOCOUNT ON;
DECLARE
       @BasePath varchar(1000)
      ,@Path varchar(1000)
      ,@FullPath varchar(2000)
      ,@Id int
	  ,@Counter int
	  ,@BackupFile VARCHAR(2000);

--1) Provide backup folder location
SET @BasePath = '\\DC\Backups\SQL-A.Contso.com\MSSQLSERVER';

DECLARE @DirectoryTree TABLE(
       id int IDENTITY(1,1)
      ,fullpath varchar(2000)
      ,subdirectory nvarchar(512)
      ,depth int);

DECLARE @BackupFileList TABLE(
       id int IDENTITY(1,1)
      ,fullpath varchar(2000)
      ,subdirectory nvarchar(512)
      ,depth int
	  ,isFile int
	  ,isLatestOnDate int default 0
	  ,BackupDate DATETIME2);

CREATE TABLE #headers
( BackupName varchar(256), BackupDescription varchar(256), BackupType varchar(256), 
ExpirationDate varchar(256), Compressed varchar(256), Position varchar(256), DeviceType varchar(256), 
UserName varchar(256), ServerName varchar(256), DatabaseName varchar(256), DatabaseVersion varchar(256), 
DatabaseCreationDate varchar(256), BackupSize varchar(256), FirstLSN varchar(256), LastLSN varchar(256), 
CheckpointLSN varchar(256), DatabaseBackupLSN varchar(256), BackupStartDate varchar(256), BackupFinishDate datetime2, 
SortOrder varchar(256), CodePage varchar(256), UnicodeLocaleId varchar(256), UnicodeComparisonStyle varchar(256), 
CompatibilityLevel varchar(256), SoftwareVendorId varchar(256), SoftwareVersionMajor varchar(256), 
SoftwareVersionMinor varchar(256), SoftwareVersionBuild varchar(256), MachineName varchar(256), Flags varchar(256), 
BindingID varchar(256), RecoveryForkID varchar(256), Collation varchar(256), FamilyGUID varchar(256), 
HasBulkLoggedData varchar(256), IsSnapshot varchar(256), IsReadOnly varchar(256), IsSingleUser varchar(256), 
HasBackupChecksums varchar(256), IsDamaged varchar(256), BeginsLogChain varchar(256), HasIncompleteMetaData varchar(256), 
IsForceOffline varchar(256), IsCopyOnly varchar(256), FirstRecoveryForkID varchar(256), ForkPointLSN varchar(256), 
RecoveryModel varchar(256), DifferentialBaseLSN varchar(256), DifferentialBaseGUID varchar(256), 
BackupTypeDescription varchar(256), BackupSetGUID varchar(256), CompressedBackupSize varchar(256), 
Containment varchar(256) ); 

-- Drop Containment column from #headers for SQL Server 2008 R2
IF (SELECT CONVERT(VARCHAR(50),SERVERPROPERTY('productversion'))) LIKE '10.50.%'
BEGIN
	ALTER TABLE #headers
		DROP COLUMN Containment;
END

--Populate the table using the initial base path.
INSERT @DirectoryTree (subdirectory,depth) EXEC master.sys.xp_dirtree @BasePath,1,0;
UPDATE @DirectoryTree SET fullpath = @BasePath + '\' + subdirectory;

--SELECT * FROM @DirectoryTree

--Loop through the table as long as there are still folders to process.
WHILE EXISTS (SELECT id FROM @DirectoryTree)
BEGIN

	SELECT TOP (1) @Id = id, @BasePath = fullpath FROM @DirectoryTree;
	
	INSERT @BackupFileList (subdirectory,depth, isFile) EXEC master.sys.xp_dirtree @BasePath,1,1;	
	UPDATE @BackupFileList SET fullpath = @BasePath + '\' + subdirectory;
	
	PRINT '
-- Backup files 
';
	
--*****************************************************************************************
--BEGIN:	Loop through each Backup File to get BackupDates
--*****************************************************************************************
	DECLARE BackupFile_cursor CURSOR FOR 
		SELECT fullpath FROM @BackupFileList ORDER BY fullpath;

	OPEN BackupFile_cursor
	FETCH NEXT FROM BackupFile_cursor INTO @BackupFile;

	SET	@Counter = 1;
	WHILE (@Counter <= (SELECT COUNT(fullpath) FROM @BackupFileList))
	BEGIN
		
		INSERT INTO #headers
		EXEC ('restore headeronly from disk = '''+ @BackupFile + '''');
		
		UPDATE @BackupFileList
		SET	BackupDate = (SELECT TOP (1) BackupFinishDate FROM #headers)		
		WHERE fullpath = @BackupFile;

		DELETE FROM #headers;
		SET	@Counter = @Counter + 1;
	FETCH NEXT FROM BackupFile_cursor INTO @BackupFile;
	END

	CLOSE BackupFile_cursor 
	DEALLOCATE BackupFile_cursor 
--*****************************************************************************************
--END:	Loop through each Backup File to get BackupDates
--*****************************************************************************************

--SELECT * from @BackupFileList

--*****************************************************************************************
--BEGIN:	Update IsLatest for backupset
--*****************************************************************************************
	;WITH T1 AS (
		SELECT * from @BackupFileList
	)
	,T2 AS (
		SELECT MAX(BackupDate) as BackupDate_Max FROM T1 GROUP BY CAST(BackupDate AS Date)
	)
	,T3 AS (
		SELECT FullPath FROM T1 WHERE BackupDate IN (SELECT BackupDate_Max FROM T2)
	)
	UPDATE	@BackupFileList
	SET	isLatestOnDate = 1
	WHERE	fullpath IN (SELECT FullPath FROM T3);

	SELECT '
EXECUTE master.dbo.xp_delete_file 0,N'''+fullpath+'''
GO
' FROM @BackupFileList WHERE isLatestOnDate = 0;

--*****************************************************************************************
--END:	Update IsLatest for backupset
--*****************************************************************************************
	--EXECUTE master.dbo.xp_delete_file 0,N'F:\Backups\DemoSuspect\DemoSuspect_backup_2014_11_21_132124_9368405.bak'
    DELETE FROM @DirectoryTree WHERE id = @Id;
	DELETE FROM @BackupFileList;
END;

DROP TABLE #headers;
