CREATE DATABASE [CorruptDB];
GO
USE [CorruptDB];
GO
 
CREATE TABLE [Test] (
    [c1] INT IDENTITY,
    [c2] CHAR (8000) DEFAULT 'a');
GO
 
INSERT INTO [Test] DEFAULT VALUES;
GO 

SELECT * FROM TEST

----------------------------------------------------
DBCC IND (N'CorruptDB', N'Test', -1);
GO

DBCC TRACEON (3604);
DBCC PAGE (16, 1, 291, 3);
DBCC TRACEOFF (3604);
GO
-----------------------------------------------------
ALTER DATABASE [CorruptDB] SET SINGLE_USER;
GO
DBCC WRITEPAGE (N'CorruptDB', 1, 291, 4000, 1, 0x8, 1);
GO
------------------------------------------------------
USE master
GO

DBCC CHECKDB ([CorruptDB])
GO

SELECT * FROM MSDB..SUSPECT_PAGES
---------------------------------------------------
USE master
GO
BACKUP DATABASE [CorruptDB] 
    TO DISK = N'C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\Backup\CorruptDB.bak'
    WITH  CONTINUE_AFTER_ERROR 
GO

---------------------------------------------------
ALTER DATABASE [CorruptDB] SET EMERGENCY;
GO
ALTER DATABASE [CorruptDB] SET SINGLE_USER;
GO
DBCC CHECKDB ([CorruptDB], REPAIR_ALLOW_DATA_LOSS) WITH ESTIMATEONLY;
--DBCC CHECKDB ([CorruptDB], REPAIR_ALLOW_DATA_LOSS);
GO
ALTER DATABASE [CorruptDB] SET ONLINE;
GO