
--	1) Code to verify B+ Tree Architecture
	--	https://msdn.microsoft.com/en-us/library/ms188917.aspx
use tempdb

create table employee
(id int identity(1,1) not null
,name char(4000) not null
)

alter table employee
	add constraint pk_id primary key clustered (id)

insert into employee
values ('Ajay Dwivedi')
,('Vijay Dwivedi')
,('Rajiv Dixit')
,('Prabhu Chawla')
,('Swati Gupta')

SELECT object_name(object_id) AS TableName, * FROM sys.dm_db_index_physical_stats(db_id(),object_id('employee'),null,null,'DETAILED')
/*	Check index_depth
*/