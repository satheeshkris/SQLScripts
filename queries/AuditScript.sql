---1.Installation directory is “D:\MSSQL<$xxxx>”?

declare @returnvalue int,

@path nvarchar(4000)

exec @returnvalue = master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',N'Software\Microsoft\MSSQLServer\Setup',N'SQLPath', @path output, 'no_output'

select 'InstalltionPath' = @path

 go

---2.MSSQL Server Port Number (1436, 1437, 1438 …)?

DECLARE @test varchar(20), @key varchar(100)
if charindex('\',@@servername,0) <>0
begin
set @key = 'SOFTWARE\MICROSOFT\Microsoft SQL Server\'
+@@servicename+'\MSSQLServer\Supersocketnetlib\TCP'
end
else
begin
set @key = 'SOFTWARE\MICROSOFT\MSSQLServer\MSSQLServer \Supersocketnetlib\TCP'
end

EXEC master..xp_regread @rootkey='HKEY_LOCAL_MACHINE',
@key=@key,@value_name='Tcpport',@value=@test OUTPUT


SELECT  ' Port Number:'+convert(varchar(10),@test)

--3.Latest service pack approved by DMS installed?


Use master 

SELECT 'Server Version'=@@version , 'Service Pack' = SERVERPROPERTY('ProductLevel')

--4. Microsoft SQL Server service account is the recommended service startup account and set to automatic?

DECLARE @serviceaccount varchar(100) 
EXECUTE master.dbo.xp_instance_regread 
N'HKEY_LOCAL_MACHINE', 
N'SYSTEM\CurrentControlSet\Services\MSSQLSERVER', 
N'ObjectName', 
@ServiceAccount OUTPUT, 
N'no_output' 

SELECT @Serviceaccount as SQLServer_ServiceAccount 

set @Serviceaccount ='' 

--5. MS SQL Server Agent service account is the recommended service startup account and set to automatic?

EXECUTE master.dbo.xp_instance_regread 
N'HKEY_LOCAL_MACHINE', 
N'SYSTEM\CurrentControlSet\Services\SQLSERVERAGENT', 
N'ObjectName', 
@ServiceAccount OUTPUT, 
N'no_output' 

SELECT @Serviceaccount as SQLServer_ServiceAccount 

--6.Default data file path is set in the server database properties?
declare @returncode int,

@path nvarchar(4000)

exec @returncode = master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',N'Software\Microsoft\MSSQLServer\MSSQLServer',N'DefaultData', @path output, 'no_output'

Select 'DataDirectory' = @path

--7.Default data file path is set in the server database properties?

declare @returncode1 int,

@path1 nvarchar(4000)

exec @returncode1 = master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',N'Software\Microsoft\MSSQLServer\MSSQLServer',N'DefaultLog', @path1 output, 'no_output'

Select 'DataDirectory' = @path1

--8. “admin” database is setup for storing backup log information?

select name  from sysdatabases where name = 'admin'

--9-Database Backups in Place

-- 10.SQLLiteSpeed installed?

exec master.dbo.xp_sqllitespeed_version
go

--11. Auto Close and Auto Shrink DB Option is unchecked

SELECT s.name AS DatabaseName
	, CASE DATABASEPROPERTY(s.name, 'IsAutoShrink')
			when 1 then 'Yes'
			when 0 then 'No'
			else 'Invalid input' END AS IsAutoShrink
	, CASE DATABASEPROPERTY(s.name, 'IsAutoClose')
			when 1 then 'Yes'
			when 0 then 'No'
			else 'Invalid input' END AS IsAutoClose
FROM master..sysdatabases s
ORDER BY s.name

--12. Northwind and Pubs, Adwentous works are  databases are dropped

--13. File/Filegroup sizes are fixed
use model
If (select top 1 isnull(growth,1) from sysfiles where growth=0)=0  
begin
Select 'Since Auto Growth Property is not set on Model '
select filename,maxsize,growth from sysfiles
end
else
begin
Select 'Since Auto Growth Property is  set on model '
select filename,maxsize,growth from sysfiles
end

--14. Tempdb set to auto grow

use tempdb
If (select top 1 isnull(growth,1) from sysfiles where growth=0)=0  
begin
Select 'Since Auto Growth Property is not set on Tempdb '
select filename,maxsize,growth from sysfiles
end
else
begin
Select 'Since Auto Growth Property is  set on TempDB '
select filename,maxsize,growth from sysfiles
end

---15.All Databases owned by “sa”
if (select substring(@@version,CHARINDEX('-', @@version)+2,4))= '9.00'
begin
declare  @roundedversion table  (dbname varchar(1000), db_size nvarchar(1000), owner varchar(1000), dbid int, created datetime,status varchar(1000), cmpt int)
declare @cmd1 as nvarchar(1500)
select @cmd1 = 'sp_helpdb'
insert into @roundedversion exec sp_executesql @cmd1
select dbname, owner from @roundedversion
end
else
select name, suser_sname(sid) from master.dbo.sysdatabases
go

--16.[USA\Admin DMS] group is added to the system with sysadmin role.


--17.[Builtin\Administrators] group is removed
--18.IDs other than 'sa' and 'Admin DMS' that has sysadmin role enabled.
SELECT 
	name AS Login, 
	sysadmin =
	CASE
		WHEN sysadmin = 1 THEN 'X'
		ELSE ''
	END,  
	securityadmin =
	CASE
		WHEN securityadmin = 1 THEN 'X'
		ELSE ''
	END, 
	serveradmin =
	CASE
		WHEN serveradmin = 1 THEN 'X'
		ELSE ''
	END,
	setupadmin =
	CASE
		WHEN setupadmin = 1 THEN 'X'
		ELSE ''
	END,
	processadmin =
	CASE
		WHEN processadmin = 1 THEN 'X'
		ELSE ''
	END,
	diskadmin =
	CASE
		WHEN diskadmin = 1 THEN 'X'
		ELSE ''
	END,
	dbcreator =
	CASE
		WHEN dbcreator = 1 THEN 'X'
		ELSE ''
	END,
	bulkadmin =
	CASE
		WHEN bulkadmin = 1 THEN 'X'
		ELSE ''
	END,
	CONVERT(CHAR(16),createdate,120) AS 'DateCreated' 
FROM master.dbo.syslogins 
WHERE 
	sysadmin = 1
ORDER BY NAME

GO
	
--Any other server-wide role, not including ones in the first list above. Works with both SQL 2000 and 2005

SELECT 
	name AS Login, 
	securityadmin =
	CASE
		WHEN securityadmin = 1 THEN 'X'
		ELSE ''
	END, 
	serveradmin =
	CASE
		WHEN serveradmin = 1 THEN 'X'
		ELSE ''
	END,
	setupadmin =
	CASE
		WHEN setupadmin = 1 THEN 'X'
		ELSE ''
	END,
	processadmin =
	CASE
		WHEN processadmin = 1 THEN 'X'
		ELSE ''
	END,
	diskadmin =
	CASE
		WHEN diskadmin = 1 THEN 'X'
		ELSE ''
	END,
	dbcreator =
	CASE
		WHEN dbcreator = 1 THEN 'X'
		ELSE ''
	END,
	bulkadmin =
	CASE
		WHEN bulkadmin = 1 THEN 'X'
		ELSE ''
	END,
	CONVERT(CHAR(16),createdate,120) AS 'DateCreated' 
FROM master.dbo.syslogins 
WHERE 
	(securityadmin = 1
	OR serveradmin = 1
	OR setupadmin = 1
	OR processadmin = 1
	OR diskadmin = 1
	OR dbcreator = 1
	OR bulkadmin = 1)
	AND sysadmin <> 1
ORDER BY NAME

--19. SQL Server login level Auditing is enabled
--if Audit level is 0, then NONE
--if Audit level  is 1, Failed Logins Only
-- if Audit Level is 2, Successfully Logins Only
--If Both Failed and successfully logins Only

EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', 
 N'Software\Microsoft\MSSQLServer\MSSQLServer', N'AuditLevel'

--20. AD Group Level security is implemented
-- set Audit level so both failed and successful logins are audited
-- if the login mode is 2, then we have SQL + Windows Authnetication else We have only Wndows Authentiocation

EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', 
 N'Software\Microsoft\MSSqlserver\MSSqlServer', N'LoginMode'

--21.All individual user access is removed
--22.Access is based only on roles created/Is Global DMS default db roles created (db_xl_xxxx)?
--23.Disable [SQL Debugger] account


if exists (select* from master.dbo.syslogins where loginname = 'SQL Debugger')
select 'SQL Debugger Login present'
else
select 'SQL Debugger Login not present '


--24. Disable guest login account &--25.Remove the guest user account in all the databases, except for master and tempdb
if exists (select name from model.dbo.sysusers where name = 'Guest' and status = 2)
select 'Guest user present in model'
else
select 'Guest user not present in model'

if exists (select * from msdb.dbo.sysusers where name = 'Guest' and status = 2)
select 'Guest user is present in msdb'
else
select 'Guest user is not present in msdb'


if exists (select* from master.dbo.syslogins where loginname = 'Guest')
select 'Guest Login present'
else
select 'Guest Login not present '

--26.Blank “sa” password
--27.Strong password for the “sa” account

SET NOCOUNT ON 

--Variables 
DECLARE @lngCounter INTEGER
DECLARE @lngCounter1 INTEGER
DECLARE @lngLogCount INTEGER
DECLARE @strName VARCHAR(256)

--Create table to hold SQL logins 
CREATE TABLE #tLogins
(
numID INTEGER IDENTITY(1,1)
,strLogin sysname NULL 
,lngPass integer NULL 
,Password varchar(500) NULL
,Type int NULL
)

--Insert non ntuser into temp table 
INSERT INTO #tLogins (strLogin)
SELECT name FROM master.dbo.syslogins WHERE isntname = 0
SET @lngLogCount = @@ROWCOUNT 

--Determine if password and name are the ssame 
SET @lngCounter = @lngLogCount

WHILE @lngCounter <> 0
BEGIN 
    SET @strName = (SELECT strLogin FROM #tLogins WHERE numID = @lngCounter)

    UPDATE #tLogins
    SET 
		lngPass = (SELECT PWDCOMPARE (@strName,(SELECT password FROM master.dbo.syslogins WHERE name = @strName))), 
		Type = 
		CASE 
			WHEN (SELECT PWDCOMPARE (@strName,(SELECT password FROM master.dbo.syslogins WHERE name = @strName))) = 1 THEN 2 -- Password same as login
			ELSE NULL
		END		
    WHERE numID = @lngCounter
    AND Type IS NULL

    SET @lngCounter = @lngCounter - 1
END 

--Reset column for next password test 
UPDATE #tLogins
SET lngPass = 0

--Determine if password is only one character long 
SET @lngCounter = @lngLogCount

WHILE @lngCounter <> 0
BEGIN 
    SET @lngCounter1 = 1
    SET @strName = (SELECT strLogin FROM #tLogins WHERE numID = @lngCounter)
    WHILE @lngCounter1 < 256
    BEGIN 
        UPDATE #tLogins
        SET lngPass = (SELECT PWDCOMPARE (CHAR(@lngCounter1),(SELECT password FROM master.dbo.syslogins WHERE name = @strName))), Password = UPPER(CHAR(@lngCounter1)) + ' or ' + LOWER(CHAR(@lngCounter1)), 
		Type = 
		CASE 
			WHEN (SELECT PWDCOMPARE (CHAR(@lngCounter1),(SELECT password FROM master.dbo.syslogins WHERE name = @strName))) = 1 THEN 3 --password is only one character long 
			ELSE NULL
		END
        WHERE numID = @lngCounter
        AND lngPass <> 1
        AND Type IS NULL
        
        SET @lngCounter1 = @lngCounter1 + 1
        
    END 

    SET @lngCounter = @lngCounter - 1
END 

--Return combined results
SELECT name AS 'Login Name', Passsword = '(BLANK)' FROM master.dbo.syslogins 
WHERE password IS NULL 
AND isntname = 0
	UNION ALL
SELECT strLogin AS 'Login Name', Password = strLogin FROM #tLogins WHERE Type = 2
	UNION ALL
SELECT 'Login Name' = strLogin, Password FROM #tLogins WHERE Type = 3
ORDER BY name

drop table #tLogins
GO
--28.Is memory dynamic?

use master
go
sp_configure 'awe enabled'
go
sp_configure 'max server memory (MB)'
go



