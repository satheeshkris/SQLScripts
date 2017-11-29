
----Would be using it post restore to Drop Users and UD Roles.---
--step1---

--Drop Users--------------------------------------------------- 
declare @user_name varchar(100), @exec_sql varchar(2000)
declare user_cursor cursor for
select name from sysusers 
where issqlrole = 0
and hasdbaccess = 1
and name <> 'dbo'

open user_cursor
FETCH NEXT FROM user_cursor  into @user_name 
   WHILE @@FETCH_STATUS  = 0
   BEGIN
           set @exec_sql = 'exec sp_revokedbaccess ' +  '['+  @user_name   +']'
             
      --print @exec_sql
       execute (@exec_sql)
 FETCH NEXT FROM user_cursor  into @user_name    
    END

   close user_cursor
   deallocate user_cursor



--step2---
--Drop Roles----------------------------------------------------------------
declare @role_name varchar(100), @exec_sql varchar(2000)
declare user_cursor cursor for
select name from sysusers 
where issqlrole = 1
and name <> 'dbo'
and name not in ('db_owner','db_accessadmin','db_securityadmin','db_ddladmin',
'db_backupoperator','db_datareader','db_datawriter','db_denydatareader',
'db_denydatawriter','public')
order by name

open user_cursor
FETCH NEXT FROM user_cursor  into @role_name 
   WHILE @@FETCH_STATUS  = 0
   BEGIN
           set @exec_sql = 'exec sp_droprole ' +  '['+  @role_name   +']'
             
      ---print @exec_sql
       execute (@exec_sql)
 FETCH NEXT FROM user_cursor  into @role_name    
    END

   close user_cursor
   deallocate user_cursor




---step3----
--this script will create another script as output. Just run the output script on target database---

SELECT 'GRANT VIEW DEFINITION ON  [' + USER_NAME(uid) + '].[' + name + '] TO ' + '[db_xl_developers]'
FROM sysobjects
WHERE 
type = 'P'
AND OBJECTPROPERTY(OBJECT_ID(QUOTENAME(USER_NAME(uid)) + '.' + QUOTENAME(name)), 'IsMSShipped') = 0
--AND name LIKE 'Rep%' /*To grant EXECUTE permission on only procedures starting with Rep*/
GO


CHANGE OWNER OF DATABASE TO 'SA'



