--	http://blog.sqlauthority.com/2015/09/12/sql-server-who-dropped-table-or-database/

SELECT DISTINCT Trace.EventID, TraceEvents.NAME AS Event_Desc
FROM   ::fn_trace_geteventinfo(1) Trace
,sys.trace_events TraceEvents
WHERE Trace.eventID = TraceEvents.trace_event_id

-- read all available traces.
DECLARE @current VARCHAR(500);
DECLARE @start VARCHAR(500);
DECLARE @indx INT;
SELECT @current = path
FROM sys.traces
WHERE is_default = 1;
SET @current = REVERSE(@current)
SELECT @indx = PATINDEX('%\%', @current)
SET @current = REVERSE(@current)
SET @start = LEFT(@current, LEN(@current) - @indx) + '\log.trc';
-- CHNAGE FILER AS NEEDED
SELECT CASE EventClass
WHEN 46 THEN 'Object:Created'
WHEN 47 THEN 'Object:Deleted'
WHEN 164 THEN 'Object:Altered'
END, DatabaseName, ObjectName, HostName, ApplicationName, LoginName, StartTime
 FROM::fn_trace_gettable(@start, DEFAULT)
WHERE EventClass IN (46,47,164) AND EventSubclass = 0 AND DatabaseID <> 2
AND DatabaseName not in ('master')
ORDER BY StartTime DESC