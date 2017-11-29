/* Created By: Ajay DWivedi */

DECLARE @db_name NVARCHAR(100)
		,@log_file NVARCHAR(150)
		,@SQLString NVARCHAR(max);

DECLARE database_cursor CURSOR FOR 
		SELECT	DB.name, FLS.name
		FROM	sys.databases	AS DB
		INNER JOIN
				sys.master_files AS FLS
		ON		FLS.database_id = DB.database_id		
		WHERE	DB.recovery_model_desc = 'SIMPLE'
		AND		db.state_desc = 'ONLINE'
		AND		FLS.type = 1 --LOG
		AND		DB.name NOT IN ('master','tempdb','model','msdb');
		
OPEN database_cursor
FETCH NEXT FROM database_cursor INTO @DB_Name, @log_file;

WHILE @@FETCH_STATUS = 0 
BEGIN 
     SET @SQLString = '
USE	[' + @DB_Name + ']
GO		
DBCC SHRINKFILE (N''' + @log_file + ''' , 0, TRUNCATEONLY)
GO';

PRINT	@SQLString;

     FETCH NEXT FROM database_cursor INTO @DB_Name, @log_file;
END 

CLOSE database_cursor 
DEALLOCATE database_cursor 
