--Script to Reverse Engineer SQL Server Object Role Permissions
--Written By Bradley Morris
--In Query Analyzer be sure to go to
--Query -> Current Connection Options -> Advanced (Tab)
--and set Maximum characters per column
--to a high number, such as 10000, so
--that all the code will be displayed.

begin
declare @dRoleName [sysname]

DECLARE _outer
CURSOR
LOCAL
FORWARD_ONLY
READ_ONLY
FOR
select 'RoleName' = name 
from sysusers where (issqlrole = 1 or isapprole = 1)
AND [name] NOT IN
(
'public',
'INFORMATION_SCHEMA',
'db_owner',
'db_accessadmin',
'db_securityadmin',
'db_ddladmin',
'db_backupoperator',
'db_datareader',
'db_datawriter',
'db_denydatareader',
'db_denydatawriter'
)

OPEN _outer

FETCH
NEXT
FROM _outer
INTO
@dRoleName

WHILE @@FETCH_STATUS = 0
BEGIN


DECLARE @DatabaseRoleName [sysname]
--SET @DatabaseRoleName = '{Database Role Name}'
SET @DatabaseRoleName = @dRoleName

SET NOCOUNT ON
DECLARE
@errStatement [varchar](8000),
@msgStatement [varchar](8000),
@DatabaseRoleID [smallint],
@IsApplicationRole [bit],
@ObjectID [int],
@ObjectName [sysname]

SELECT
@DatabaseRoleID = [uid],
@IsApplicationRole = CAST([isapprole] AS bit)
FROM [dbo].[sysusers]
WHERE
[name] = @DatabaseRoleName
AND
(
[issqlrole] = 1
OR [isapprole] = 1
)
AND [name] NOT IN
(
'public',
'INFORMATION_SCHEMA',
'db_owner',
'db_accessadmin',
'db_securityadmin',
'db_ddladmin',
'db_backupoperator',
'db_datareader',
'db_datawriter',
'db_denydatareader',
'db_denydatawriter'
)

IF @DatabaseRoleID IS NULL
BEGIN
IF @DatabaseRoleName IN 
(
'public',
'INFORMATION_SCHEMA',
'db_owner',
'db_accessadmin',
'db_securityadmin',
'db_ddladmin',
'db_backupoperator',
'db_datareader',
'db_datawriter',
'db_denydatareader',
'db_denydatawriter'
)
SET @errStatement = 'Role ' + @DatabaseRoleName + ' is a fixed database role and cannot be scripted.'
ELSE
SET @errStatement = 'Role ' + @DatabaseRoleName + ' does not exist in ' + DB_NAME() + '.' + CHAR(13) +
'Please provide the name of a current role in ' + DB_NAME() + ' you wish to script.'

RAISERROR(@errStatement, 16, 1)
END
ELSE
BEGIN
SET @msgStatement = '--Security creation script for role ' + @DatabaseRoleName + CHAR(13) +
'--Created At: ' + CONVERT(varchar, GETDATE(), 112) + REPLACE(CONVERT(varchar, GETDATE(), 108), ':', '') + CHAR(13) +
'--Created By: ' + SUSER_NAME() + CHAR(13) +
'--Add Role To Database' + CHAR(13)
IF @IsApplicationRole = 1
SET @msgStatement = @msgStatement + 'EXEC sp_addapprole' + CHAR(13) +
CHAR(9) + '@rolename = ''' + @DatabaseRoleName + '''' + CHAR(13) +
CHAR(9) + '@password = ''{Please provide the password here}''' + CHAR(13)
ELSE
BEGIN
set @msgStatement = ''
SET @msgStatement = @msgStatement + 'EXEC sp_addrole ' + '@rolename =''' + @DatabaseRoleName + '''
go' 
END
SET @msgStatement = @msgStatement  
PRINT @msgStatement
DECLARE _sysobjects
CURSOR
LOCAL
FORWARD_ONLY
READ_ONLY
FOR
SELECT
DISTINCT([sysobjects].[id]),
'[' + USER_NAME([sysobjects].[uid]) + '].[' + [sysobjects].[name] + ']'
FROM [dbo].[sysprotects]
INNER JOIN [dbo].[sysobjects]
ON [sysprotects].[id] = [sysobjects].[id]
WHERE [sysprotects].[uid] = @DatabaseRoleID
OPEN _sysobjects
FETCH
NEXT
FROM _sysobjects
INTO
@ObjectID,
@ObjectName
WHILE @@FETCH_STATUS = 0
BEGIN
SET @msgStatement = ''
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 193 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'SELECT,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 195 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'INSERT,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 197 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'UPDATE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 196 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'DELETE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 224 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'EXECUTE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 26 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'REFERENCES,'
IF LEN(@msgStatement) > 0
BEGIN
IF RIGHT(@msgStatement, 1) = ','
SET @msgStatement = LEFT(@msgStatement, LEN(@msgStatement) - 1)
SET @msgStatement = 'GRANT ' + @msgStatement + ' ON ' + @ObjectName + ' TO ' + @DatabaseRoleName + '
go'
PRINT @msgStatement
END
SET @msgStatement = ''
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 193 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'SELECT,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 195 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'INSERT,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 197 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'UPDATE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 196 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'DELETE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 224 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'EXECUTE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseRoleID AND [action] = 26 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'REFERENCES,'
IF LEN(@msgStatement) > 0
BEGIN
IF RIGHT(@msgStatement, 1) = ','
SET @msgStatement = LEFT(@msgStatement, LEN(@msgStatement) - 1)
SET @msgStatement = 'DENY' + CHAR(13) +
CHAR(9) + @msgStatement + CHAR(13) +
CHAR(9) + 'ON ' + @ObjectName + CHAR(13) +
CHAR(9) + 'TO ' + @DatabaseRoleName
PRINT @msgStatement
END
FETCH
NEXT
FROM _sysobjects
INTO
@ObjectID,
@ObjectName
END
CLOSE _sysobjects
DEALLOCATE _sysobjects
--PRINT 'GO'
END

FETCH
NEXT
FROM _outer
INTO
@dRoleName

end
end


--------------For users
begin
DECLARE @DatabaseUserName [sysname]
declare @UName sysname


SET NOCOUNT ON
DECLARE
--@errStatement [varchar](8000),
--@msgStatement [varchar](8000),
@DatabaseUserID [smallint],
@ServerUserName [sysname],
@RoleName [varchar](8000)
--@ObjectID [int],
--@ObjectName [varchar](261)


DECLARE _dbusers
CURSOR
LOCAL
FORWARD_ONLY
READ_ONLY
FOR
SELECT
[sysusers].name
FROM [dbo].[sysusers]
INNER JOIN [master].[dbo].[syslogins]
ON [sysusers].[sid] = [master].[dbo].[syslogins].[sid]


OPEN _dbusers

FETCH NEXT FROM _dbusers INTO @UName


WHILE @@FETCH_STATUS = 0
begin
--cursor ends for all users
set @DatabaseUserName=@UName
SELECT
@DatabaseUserID = [sysusers].[uid],
@ServerUserName = [master].[dbo].[syslogins].[loginname]
FROM [dbo].[sysusers]
INNER JOIN [master].[dbo].[syslogins]
ON [sysusers].[sid] = [master].[dbo].[syslogins].[sid]
WHERE [sysusers].[name] = @DatabaseUserName
IF @DatabaseUserID IS NULL
BEGIN
SET @errStatement = 'User ' + @DatabaseUserName + ' does not exist in ' + DB_NAME() + CHAR(13) +
'Please provide the name of a current user in ' + DB_NAME() + ' you wish to script.'
RAISERROR(@errStatement, 16, 1)
END
ELSE
BEGIN
SET @msgStatement =''

SET @msgStatement = 
--'--Add User To Database' + CHAR(13) +
'EXEC [sp_grantdbaccess]' + ' @loginame =''' + @ServerUserName + ''',' + ' @name_in_db =''' + @DatabaseUserName + '''
GO' 

PRINT @msgStatement

DECLARE _sysusers
CURSOR
LOCAL
FORWARD_ONLY
READ_ONLY
FOR
SELECT
[name]
FROM [dbo].[sysusers]
WHERE
[uid] IN
(
SELECT
[groupuid]
FROM [dbo].[sysmembers]
WHERE [memberuid] = @DatabaseUserID
)
OPEN _sysusers
FETCH
NEXT
FROM _sysusers
INTO @RoleName
WHILE @@FETCH_STATUS = 0
BEGIN
SET @msgStatement = 'EXEC [sp_addrolemember] ' + '@rolename = ''' + @RoleName + ''',' + ' @membername = ''' + @DatabaseUserName + '''
go'
PRINT @msgStatement
FETCH
NEXT
FROM _sysusers
INTO @RoleName
END
SET @msgStatement = '' + CHAR(13) 

PRINT @msgStatement
DECLARE _sysobjects
CURSOR
LOCAL
FORWARD_ONLY
READ_ONLY
FOR
SELECT
DISTINCT([sysobjects].[id]),
'[' + USER_NAME([sysobjects].[uid]) + '].[' + [sysobjects].[name] + ']'
FROM [dbo].[sysprotects]
INNER JOIN [dbo].[sysobjects]
ON [sysprotects].[id] = [sysobjects].[id]
WHERE [sysprotects].[uid] = @DatabaseUserID
OPEN _sysobjects
FETCH
NEXT
FROM _sysobjects
INTO
@ObjectID,
@ObjectName
WHILE @@FETCH_STATUS = 0
BEGIN
SET @msgStatement = ''
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 193 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'SELECT,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 195 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'INSERT,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 197 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'UPDATE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 196 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'DELETE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 224 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'EXECUTE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 26 AND [protecttype] = 205)
SET @msgStatement = @msgStatement + 'REFERENCES,'
IF LEN(@msgStatement) > 0
BEGIN
IF RIGHT(@msgStatement, 1) = ','
SET @msgStatement = LEFT(@msgStatement, LEN(@msgStatement) - 1)
SET @msgStatement = 'GRANT' + CHAR(13) +
CHAR(9) + @msgStatement + CHAR(13) +
CHAR(9) + 'ON ' + @ObjectName + CHAR(13) +
CHAR(9) + 'TO ' + @DatabaseUserName
PRINT @msgStatement
END
SET @msgStatement = ''
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 193 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'SELECT,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 195 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'INSERT,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 197 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'UPDATE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 196 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'DELETE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 224 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'EXECUTE,'
IF EXISTS(SELECT * FROM [dbo].[sysprotects] WHERE [id] = @ObjectID AND [uid] = @DatabaseUserID AND [action] = 26 AND [protecttype] = 206)
SET @msgStatement = @msgStatement + 'REFERENCES,'
IF LEN(@msgStatement) > 0
BEGIN
IF RIGHT(@msgStatement, 1) = ','
SET @msgStatement = LEFT(@msgStatement, LEN(@msgStatement) - 1)
SET @msgStatement = 'DENY' + CHAR(13) +
CHAR(9) + @msgStatement + CHAR(13) +
CHAR(9) + 'ON ' + @ObjectName + CHAR(13) +
CHAR(9) + 'TO ' + @DatabaseUserName
PRINT @msgStatement
END
FETCH NEXT FROM _sysobjects INTO @ObjectID,@ObjectName
END
CLOSE _sysobjects
DEALLOCATE _sysobjects
end

close _sysusers
deallocate _sysusers

FETCH NEXT FROM _dbusers INTO @UName
END

close _dbusers
deallocate _dbusers
--end
--END
end

--sp_helptext sp_helprolemember


---------------------------------Generating script to add role members --------------------------------

set nocount on

if object_id('tempdb..#t') is not null
drop table #t

select DbRole = g.name, MemberName = u.name, MemberSID = u.sid  into #t
from sysusers u, sysusers g, sysmembers m  
where g.uid = m.groupuid  
and g.issqlrole = 1  
and u.uid = m.memberuid  
and 1=2

insert into #t exec sp_helprolemember

--select * from #t


--sp_addrolemember

declare @dbrole varchar(800)
declare @membername varchar(800)

DECLARE _addrole CURSOR FOR 
SELECT DbRole, MemberName
FROM #t

OPEN _addrole 

FETCH NEXT FROM _addrole 
INTO @dbrole, @membername

WHILE @@FETCH_STATUS = 0
BEGIN

--print @dbrole + @membername

print 'sp_addrolemember @rolename =''' +  @dbrole + ''',  @membername = ''' + @membername + '''
go'


FETCH NEXT FROM _addrole 
INTO @dbrole, @membername

end
close _addrole
deallocate _addrole

