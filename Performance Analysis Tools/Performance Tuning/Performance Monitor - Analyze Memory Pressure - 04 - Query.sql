USE tempdb
GO

-- one page = 8kb = 8192 bytes = Around 8000 Bytes for data
CREATE TABLE dbo.mymessages (ID INT IDENTITY(1,1), mymessage CHAR(4000));

-- Insert 200 records, means 100 data pages
INSERT INTO dbo.mymessages
(mymessage)
VALUES (REPLICATE('AAAA',1000))
GO 200

-- Verify Data
SELECT * FROM dbo.mymessages

-- Check space used by object
EXEC sp_spaceused @objname = 'dbo.mymessages';

-- Verify the no of data pages (PageType=10)
DBCC IND(tempdb,'mymessages',1)

-- Clean Buffer cache
SET NOCOUNT ON;
DBCC DROPCLEANBUFFERS;
DBCC FREEPROCCACHE;

-- one page = 8kb = 8192 bytes = Around 8000 Bytes for data
CREATE TABLE dbo.mymessages_2 (ID INT, mymessage CHAR(4000));

INSERT INTO dbo.mymessages_2
SELECT * FROM dbo.mymessages --200 Records = 100 data pages

SELECT (60000+100)/5.138