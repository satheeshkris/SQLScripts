/*
----role level permi
SELECT rm.role_principal_id, 'EXEC sp_addrolemember @rolename =' + SPACE(1) + QUOTENAME(USER_NAME(rm.role_principal_id), '')
+ ', @membername =' + SPACE(1) + QUOTENAME(USER_NAME(rm.member_principal_id), '') AS 'Role Memberships'
FROM sys.database_role_members AS rm
ORDER BY rm.role_principal_id


--For Object Level Permissions, use the below T-SQL statements to get script.

SELECT 
CASE WHEN perm.state!='W'
THEN perm.state_desc 
ELSE'GRANT' 
END 
+ SPACE(1)+ perm.permission_name + SPACE(1)+ 'ON '+ QUOTENAME(Schema_NAME(obj.schema_id))+'.' + QUOTENAME(obj.name)
collate Latin1_General_CI_AS_KS_WS +
CASE WHEN cl.column_id IS NULL 
THEN SPACE(0)
ELSE '('+QUOTENAME(cl.name)+')'
END
+ SPACE(1)+'TO'+ SPACE(1)+ QUOTENAME(usr.name)+
CASE WHEN perm.state!='W'THEN SPACE(0)ELSE SPACE(1)+'WITH GRANT OPTION' 
END AS 'Object Level Permissions'
FROM sys.database_permissions AS perm
INNER JOIN sys.objects AS obj ON perm.major_id = obj.[object_id]
INNER JOIN sys.database_principals AS usr ON perm.grantee_principal_id = usr.principal_id
LEFT JOIN sys .columns AS cl ON cl.column_id = perm.minor_id AND cl.[object_id] = perm.major_id
ORDER BY usr.name

--For Database Level Permissions, use the below T-SQL statements to get script.
IF( OBJECT_ID('sys.database_permissions') + OBJECT_ID('sys.database_principals') ) IS NOT NULL
SELECT 
CASE WHEN perm.state='W' 
THEN perm.state_desc 
ELSE 'GRANT'
END
+ SPACE(1) + perm.permission_name + SPACE(1)
+ SPACE(1) + 'TO' + SPACE(1) + QUOTENAME(usr.name) COLLATE database_default
+ CASE WHEN perm.state='W' THEN SPACE(0) ELSE SPACE(1) + 'WITH GRANT OPTION'
END AS 'Database Level Permissions'
FROM sys.database_permissions AS perm
INNER JOIN sys.database_principals AS usr
ON perm.grantee_principal_id = usr.principal_id
WHERE perm.major_id = 0
ORDER BY perm.permission_name ASC, perm.state_desc ASC

--Script to get the schemas owned by roles

SELECT 'ALTER AUTHORIZATION ON SCHEMA::[' + s.name +'] TO ['+ dp.name +']'
     FROM sys.schemas 
     AS s INNER JOIN sys.database_principals AS dp 
     ON dp.principal_id = s.principal_id
     where 
     dp.type IN ('A','R')
and dp.is_fixed_role <> 1


--Run the following command:
select * from sys.database_principal_aliases

--If you find any output of step 12, run and store the output of following:

select 'sp_dropalias ''' + suser_sname(sid) + '''' from sys.database_principal_aliases where suser_sname(sid) is not null

select 'sp_addalias ''' + suser_sname(sid) + ''', ''' + user_name(alias_principal_id) + '''' from sys.database_principal_aliases where suser_sname(sid) is not null




*/
--EXEC sp_msforEachDB 'SELECT ''?'' AS DB'

PRINT	'
--	====================================================================================================================
--	Script for Role Level Permissions
--	===================================================================================================================='
EXEC sp_msforEachDB
'	
	SET NOCOUNT ON;
	USE [?]
	
	SELECT	''USE [?]
''
	
	IF OBJECT_ID(''sys.database_role_members'') IS NOT NULL
		SELECT	--rm.role_principal_id, 
				''EXEC sp_addrolemember @rolename =''+SPACE(1)+QUOTENAME(USER_NAME(rm.role_principal_id), '''')+'', @membername =''+SPACE(1)+QUOTENAME(USER_NAME(rm.member_principal_id), '''') AS ''--	Role Memberships''
		FROM sys.database_role_members AS rm
		--ORDER BY rm.role_principal_id;
';

PRINT	'
--	====================================================================================================================
--	Script for Object Level Permissions
--	===================================================================================================================='
EXEC sp_msforEachDB
'
	SET NOCOUNT ON;
	USE [?]
	
	SELECT	''USE [?]
''

	 IF( OBJECT_ID(''sys.database_permissions'')+OBJECT_ID(''sys.objects'') + OBJECT_ID(''sys.database_principals'')+OBJECT_ID(''sys.columns'') ) IS NOT NULL
		SELECT CASE
			   WHEN perm.state != ''W'' THEN perm.state_desc
			   ELSE ''GRANT''
			   END+SPACE(1)+perm.permission_name+SPACE(1)+''ON ''+QUOTENAME(SCHEMA_NAME(obj.schema_id))+''.''+QUOTENAME(obj.name) COLLATE Latin1_General_CI_AS_KS_WS+CASE
																																								 WHEN cl.column_id IS NULL THEN SPACE(0)
																																								 ELSE ''(''+QUOTENAME(cl.name)+'')''
																																								 END+SPACE(1)+''TO''+SPACE(1)+QUOTENAME(usr.name)+CASE
																																																				WHEN perm.state != ''W'' THEN SPACE(0)
																																																				ELSE SPACE(1)+''WITH GRANT OPTION''
																																																				END AS ''--  Object Level Permissions''
		FROM sys.database_permissions AS perm
			 INNER JOIN
			 sys.objects AS obj
			 ON perm.major_id = obj.[object_id]
			 INNER JOIN
			 sys.database_principals AS usr
			 ON perm.grantee_principal_id = usr.principal_id
			 LEFT JOIN
			 sys.columns AS cl
			 ON cl.column_id = perm.minor_id AND 
				cl.[object_id] = perm.major_id
		ORDER BY usr.name;
'

PRINT	'
--	====================================================================================================================
--	Script for Database Level Permissions
--	===================================================================================================================='
EXEC sp_msforEachDB
'
	SET NOCOUNT ON;
	USE [?]
	
	SELECT	''USE [?]
''

		IF( OBJECT_ID(''sys.database_permissions'') + OBJECT_ID(''sys.database_principals'') ) IS NOT NULL
			SELECT 
			CASE WHEN perm.state=''W'' 
			THEN perm.state_desc 
			ELSE ''GRANT''
			END
			+ '' '' + perm.permission_name + '' ''
			+ '' '' + ''TO'' + '' '' + QUOTENAME(usr.name) COLLATE database_default
			+ CASE WHEN perm.state=''W'' THEN '' '' ELSE '' '' + ''WITH GRANT OPTION''
			END AS ''--	Database Level Permissions''
			FROM sys.database_permissions AS perm
			INNER JOIN sys.database_principals AS usr
			ON perm.grantee_principal_id = usr.principal_id
			WHERE perm.major_id = 0
			ORDER BY perm.permission_name ASC, perm.state_desc ASC
'

PRINT	'
--	====================================================================================================================
--	Script to get the schemas owned by roles
--	===================================================================================================================='
EXEC sp_msforEachDB
'
	SET NOCOUNT ON;
	USE [?]
	
	SELECT	''USE [?]
''

IF( OBJECT_ID(''sys.schemas'') + OBJECT_ID(''sys.database_principals'') ) IS NOT NULL
	SELECT ''ALTER AUTHORIZATION ON SCHEMA::['' + s.name +''] TO [''+ dp.name +'']'' as [-- Schema Owner Roles]
		 FROM sys.schemas 
		 AS s INNER JOIN sys.database_principals AS dp 
		 ON dp.principal_id = s.principal_id
		 where 
		 dp.type IN (''A'',''R'')
	and dp.is_fixed_role <> 1
';

PRINT	'
--	====================================================================================================================
--	Drop & Recreate Aliases
--	===================================================================================================================='
EXEC sp_msforEachDB
'
	SET NOCOUNT ON;
	USE [?]
	
	SELECT	''USE [?]
''

--Run the following command:
IF( OBJECT_ID(''sys.database_principal_aliases'') ) IS NOT NULL
BEGIN 
	IF (SELECT COUNT(*) FROM sys.database_principal_aliases) > 0
	BEGIN
		select ''sp_dropalias '''''' + suser_sname(sid) + '''''''' from sys.database_principal_aliases where suser_sname(sid) is not null

		select ''sp_addalias '''''' + suser_sname(sid) + '''''', '''''' + user_name(alias_principal_id) + '''''''' from sys.database_principal_aliases where suser_sname(sid) is not null
	END

END
'