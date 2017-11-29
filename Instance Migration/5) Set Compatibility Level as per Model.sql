/*	Created By:		AJAY DWIVEDI
	Created Date:	NOV 23, 2014
	Purpose:		Set DB Compatibility as per model database
*/
DECLARE @db_name NVARCHAR(100)
		,@log_file NVARCHAR(150)
		,@Model_Compatibility TINYINT
		,@SQLString NVARCHAR(max);

SET @Model_Compatibility = (SELECT compatibility_level FROM sys.databases WHERE name = 'Model');

DECLARE database_cursor CURSOR FOR 
		SELECT	DB.name
		FROM	sys.databases	AS DB	
		WHERE	DB.name NOT IN ('master','tempdb','model','msdb')
		AND		db.state_desc = 'ONLINE'
		AND		DB.compatibility_level <> @Model_Compatibility;
		
OPEN database_cursor
FETCH NEXT FROM database_cursor INTO @DB_Name;

WHILE @@FETCH_STATUS = 0 
BEGIN 
     SET @SQLString = '		
ALTER DATABASE [' + @DB_Name + '] SET COMPATIBILITY_LEVEL = ' + CAST(@Model_Compatibility AS VARCHAR(3)) + '
GO';

PRINT	@SQLString;

     FETCH NEXT FROM database_cursor INTO @DB_Name;
END 

CLOSE database_cursor 
DEALLOCATE database_cursor 