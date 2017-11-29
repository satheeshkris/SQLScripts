DECLARE @ColumnList VARCHAR(MAX) = NULL
	   ,@Counter INT = 0
SELECT @ColumnList = COALESCE(@ColumnList+IIF(@Counter%3=0,CHAR(13),'')+CAST(',['+COLUMN_NAME+']' AS CHAR(53)),CAST('['+COLUMN_NAME+']' AS CHAR(53)))
	   ,@Counter = @Counter + 1
from	   INFORMATION_SCHEMA.COLUMNS AS C WHERE C.TABLE_NAME = 'employees'
PRINT @ColumnList;