/*	Analyze queries doing lot of work in TempDB
https://www.mssqltips.com/sqlservertip/4356/track-sql-server-tempdb-space-usage/

*/

USE StackOverflow
GO

DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
DBCC FREEPROCCACHE WITH NO_INFOMSGS;

DECLARE @d datetime2 = getdate()
		,@x int;

SELECT	@x = u.Id
FROM	dbo.Users as u
WHERE	u.Id <= 877135 -- Return 500000 rows

PRINT 'Query Took '+RTRIM(DATEDIFF(MILLISECOND,@d,GETDATE()))+' milli seconds';
GO
--	Query Took 237 milli seconds



USE StackOverflow
GO

DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
DBCC FREEPROCCACHE WITH NO_INFOMSGS;

DECLARE @d datetime2 = getdate();
DECLARE @Id int
		,@x int;

DECLARE C CURSOR LOCAL FAST_FORWARD
FOR
	SELECT	u.Id
	FROM	dbo.Users as u
	WHERE	u.Id <= 877135 -- Return 500000 rows

OPEN C; FETCH C INTO @Id;

WHILE @@FETCH_STATUS = 0
BEGIN
	SET @x = @Id
	FETCH C INTO @Id;
END
CLOSE C; DEALLOCATE C;

PRINT 'Query Took '+RTRIM(DATEDIFF(MILLISECOND,@d,GETDATE()))+' milli seconds';
GO
--	Query Took 3910 milli seconds


USE StackOverflow
GO

DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
DBCC FREEPROCCACHE WITH NO_INFOMSGS;

DECLARE @d datetime2 = getdate();
DECLARE @Id int = 1
		,@x int; 

WHILE @Id <= 877135 -- Return 500000 rows
BEGIN
	SELECT	@x = u.Id
	FROM	dbo.Users as u
	WHERE	u.Id = @Id 
END

PRINT 'Query Took '+RTRIM(DATEDIFF(MILLISECOND,@d,GETDATE()))+' milli seconds';
GO
--	Query Took 6917 milli seconds