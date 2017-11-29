use uhtdba
go

DECLARE @Search varchar(255)
SET @Search='updatestats'

SELECT DISTINCT
    o.name AS Object_Name,o.type_desc
    FROM sys.sql_modules        m 
        INNER JOIN sys.objects  o ON m.object_id=o.object_id
    WHERE m.definition Like '%'+@Search+'%'
    ORDER BY 2,1
/*
use uhtdba
go
exec sp_helptext 'usp_rebuild_indexes_single'
go
*/