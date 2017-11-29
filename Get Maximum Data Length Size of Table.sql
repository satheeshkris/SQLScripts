USE master
GO

--	Proc to return length of maximum value of each character column of table
ALTER PROCEDURE dbo.sp_GetMaximumDataSizeInTable @SchematableName sysname
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE	@SchemaName sysname = REPLACE(REPLACE(IIF(CHARINDEX('.',@SchematableName,0)<>0,LEFT(@SchematableName,CHARINDEX('.',@SchematableName,0)-1),'dbo'),'[',''),']','')
	DECLARE @TableName sysname = REPLACE(REPLACE(RIGHT(@SchematableName,LEN(@SchematableName)-CHARINDEX('.',@SchematableName,0)),'[',''),']','')

	DECLARE	@MyColumns VARCHAR(MAX) = NULL
			,@Query VARCHAR(MAX);
	
	DECLARE @InformationColumns VARCHAR(max)
			,@InformationQuery VARCHAR(MAX);

	DECLARE @DisplayColumns VARCHAR(MAX);

	SELECT	@InformationColumns = COALESCE(@InformationColumns+' ,'+CAST(C.CHARACTER_MAXIMUM_LENGTH AS VARCHAR)+' AS ['+ C.COLUMN_NAME+ '_SCHM]',CAST(C.CHARACTER_MAXIMUM_LENGTH AS VARCHAR)+' AS ['+C.COLUMN_NAME+'_SCHM]')
	FROM	INFORMATION_SCHEMA.COLUMNS AS C
	WHERE	C.TABLE_NAME = @TableName
		AND	C.TABLE_SCHEMA = @SchemaName
		AND	C.DATA_TYPE LIKE '%char%';

	SET @InformationQuery = 'SELECT '+@InformationColumns;


	SELECT	@MyColumns = COALESCE(@MyColumns+' ,MAX(LEN(['+C.COLUMN_NAME+'])) AS ['+C.COLUMN_NAME+']','MAX(LEN(['+C.COLUMN_NAME+'])) AS ['+C.COLUMN_NAME+']')
	FROM	INFORMATION_SCHEMA.COLUMNS AS C
	WHERE	C.TABLE_NAME = @TableName
		AND	C.TABLE_SCHEMA = @SchemaName
		AND	C.DATA_TYPE LIKE '%char%'

	SELECT	@DisplayColumns = COALESCE(@DisplayColumns+' ,'+'['+C.COLUMN_NAME+'],['+C.COLUMN_NAME+'_SCHM]','['+C.COLUMN_NAME+'],['+C.COLUMN_NAME+'_SCHM]')
	FROM	INFORMATION_SCHEMA.COLUMNS AS C
	WHERE	C.TABLE_NAME = @TableName
		AND	C.TABLE_SCHEMA = @SchemaName
		AND	C.DATA_TYPE LIKE '%char%';

	SET @Query = '
	SELECT	'+@DisplayColumns+'
	FROM	(
				SELECT '+@MyColumns + '
				FROM '+@SchematableName+'
			) AS t
	CROSS JOIN
		(
			'+@InformationQuery+'
		) as i';

	IF (@Query IS NOT NULL)
		EXECUTE (@Query)
	ELSE
		SELECT	'Error' AS Status, DB_NAME() AS [Context Database], 'Object '+@SchematableName+' is not found in ['+DB_NAME()+ '] database.' AS [Message];
END
GO

--	Mark the proc as system object to execute under every user database context
EXEC sys.sp_MS_marksystemobject sp_GetMaximumDataSizeInTable
GO

USE AdventureWorks
EXEC dbo.sp_GetMaximumDataSizeInTable @SchematableName = 'Production.Product'

SELECT *FROM INFORMATION_SCHEMA.TABLES

--	Method 01
Upload_exceldump_DTRA_R2_WP_VOLUME_REPORT

--	Method 02
'dbo.Upload_exceldump_DTRA_R2_WP_VOLUME_REPORT'

--	Method 03
'dbo.Upload_exceldump_DTRA_R2_WP_VOLUME_REPORT'

/*
DECLARE @@SchematableName sysname = 'Upload_exceldump_DTRA_R2_WP_VOLUME_REPORT'
DECLARE	@SchemaName sysname = REPLACE(REPLACE(IIF(CHARINDEX('.',@@SchematableName,0)<>0,LEFT(@@SchematableName,CHARINDEX('.',@@SchematableName,0)-1),'dbo'),'[',''),']','')
DECLARE @TableName sysname = REPLACE(REPLACE(RIGHT(@@SchematableName,LEN(@@SchematableName)-CHARINDEX('.',@@SchematableName,0)),'[',''),']','')
SELECT @SchemaName ,@TableName

DECLARE	@MyColumns VARCHAR(MAX) = NULL
DECLARE @Query VARCHAR(MAX)

SELECT	@MyColumns = COALESCE(@MyColumns+' ,MAX(LEN(['+C.COLUMN_NAME+'])) AS ['+C.COLUMN_NAME+']','MAX(LEN(['+C.COLUMN_NAME+'])) AS ['+C.COLUMN_NAME+']')
FROM	INFORMATION_SCHEMA.COLUMNS AS C
WHERE	C.TABLE_NAME = @TableName
	AND	C.TABLE_SCHEMA = @SchemaName
	AND	C.DATA_TYPE LIKE '%char%'

SET @Query = 'SELECT '+@MyColumns + '
FROM '+@@SchematableName

EXECUTE (@Query);

--	====================================================================================================================
--	====================================================================================================================

SELECT	',MAX(LEN(['+C.COLUMN_NAME+'])) AS ['+C.COLUMN_NAME+']'
FROM	INFORMATION_SCHEMA.COLUMNS AS C
WHERE	C.TABLE_NAME LIKE '%Upload_exceldump_DTRA_R2_WP_VOLUME_REPORT%'
	AND	C.DATA_TYPE LIKE '%char%'

SELECT	MAX(LEN([GSC])) AS [GSC]
		,MAX(LEN([SPM])) AS [SPM]
		,MAX(LEN([CPM])) AS [CPM]
		,MAX(LEN([Region])) AS [Region]
		,MAX(LEN([Country])) AS [Country]
		,MAX(LEN([Project Name])) AS [Project Name]
		,MAX(LEN([WPG GUID])) AS [WPG GUID]
		,MAX(LEN([WP GUID])) AS [WP GUID]
		,MAX(LEN([WP Generic ID])) AS [WP Generic ID]
		,MAX(LEN([WP Status])) AS [WP Status]
		,MAX(LEN([WP Generic Name])) AS [WP Generic Name]
		,MAX(LEN([WP Competence Subdomain])) AS [WP Competence Subdomain]
		,MAX(LEN([WP Service Area])) AS [WP Service Area]
		,MAX(LEN([WP Category])) AS [WP Category]
		,MAX(LEN([Delivered Date])) AS [Delivered Date]
		,MAX(LEN([Customer Name])) AS [Customer Name]
		,MAX(LEN([Project Status])) AS [Project Status]
		,MAX(LEN([WP Status Code])) AS [WP Status Code]
		,MAX(LEN([WP Completed Date])) AS [WP Completed Date]
FROM	[dbo].[Upload_exceldump_DTRA_R2_WP_VOLUME_REPORT]
*/