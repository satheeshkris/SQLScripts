--	Deadlocks using SQL Server Extended Events
	--	https://www.brentozar.com/archive/2014/03/extended-events-doesnt-hard/
	--	http://www.sqlservergeeks.com/sql-server-capture-deadlocks-using-extended-events/
	--	http://www.sqlfreelancer.com/blog/?p=529
	--	https://www.youtube.com/watch?v=w274s3U4bNs
	--	https://www.brentozar.com/archive/2014/06/capturing-deadlock-information/
/*	How to analyze Deadlock graph
	1) For writing mail
		https://ask.sqlservercentral.com/questions/119697/tip-how-to-read-a-deadlock-graph.html
	2) 
*/

--	Check all events
SELECT * FROM sys.dm_xe_objects
	WHERE name IN ('lock_deadlock','blocked_process_report','xml_deadlock_report')
--	Check columns for event
SELECT * FROM sys.dm_xe_object_columns
	WHERE object_name IN ('lock_deadlock','blocked_process_report','xml_deadlock_report')

--	Create folder
exec master..xp_create_subdir 'C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\Backup\XEventSessions'


--	Collecting Blocked Process Reports and Deadlocks Using Extended Events
	/* Make sure this path exists before you start the trace! */
CREATE EVENT SESSION [blocked_process] ON SERVER
ADD EVENT sqlserver.blocked_process_report(
    ACTION(sqlserver.client_app_name,
           sqlserver.client_hostname,
           sqlserver.database_name)) ,
ADD EVENT sqlserver.xml_deadlock_report (
    ACTION(sqlserver.client_app_name,
           sqlserver.client_hostname,
           sqlserver.database_name))
ADD TARGET package0.asynchronous_file_target
(SET filename = N'C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\Backup\XEventSessions\blocked_process.xel',
     metadatafile = N'C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\Backup\XEventSessions\blocked_process.xem',
     max_file_size=(65536),
     max_rollover_files=5)
WITH (MAX_DISPATCH_LATENCY = 5SECONDS)
GO

--	Set the blocked process threshold
EXEC sp_configure 'show advanced options', 1 ;
GO
RECONFIGURE ;
GO
/* Enabled the blocked process report */
EXEC sp_configure 'blocked process threshold', '5';
RECONFIGURE
GO
/* Start the Extended Events session */
ALTER EVENT SESSION [blocked_process] ON SERVER
STATE = START;


/*	Reading the Block Process Report from Extended Events */
;WITH events_cte AS (
  SELECT
    xevents.event_data,
    DATEADD(mi,
    DATEDIFF(mi, GETUTCDATE(), CURRENT_TIMESTAMP),
    xevents.event_data.value(
      '(event/@timestamp)[1]', 'datetime2')) AS [event time] ,
    xevents.event_data.value(
      '(event/action[@name="client_app_name"]/value)[1]', 'nvarchar(128)')
      AS [client app name],
    xevents.event_data.value(
      '(event/action[@name="client_hostname"]/value)[1]', 'nvarchar(max)')
      AS [client host name],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="database_name"]/value)[1]', 'nvarchar(max)')
      AS [database name],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="database_id"]/value)[1]', 'int')
      AS [database_id],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="object_id"]/value)[1]', 'int')
      AS [object_id],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="index_id"]/value)[1]', 'int')
      AS [index_id],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="duration"]/value)[1]', 'bigint') / 1000
      AS [duration (ms)],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="lock_mode"]/text)[1]', 'varchar')
      AS [lock_mode],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="login_sid"]/value)[1]', 'int')
      AS [login_sid],
    xevents.event_data.query(
      '(event[@name="blocked_process_report"]/data[@name="blocked_process"]/value/blocked-process-report)[1]')
      AS blocked_process_report,
    xevents.event_data.query(
      '(event/data[@name="xml_report"]/value/deadlock)[1]')
      AS deadlock_graph
  FROM    sys.fn_xe_file_target_read_file
    ('C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\Backup\XEventSessions\blocked_process*.xel',
     'C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\Backup\XEventSessions\blocked_process*.xem',
     null, null)
    CROSS APPLY (SELECT CAST(event_data AS XML) AS event_data) as xevents
)
SELECT
  CASE WHEN blocked_process_report.value('(blocked-process-report[@monitorLoop])[1]', 'nvarchar(max)') IS NULL
       THEN 'Deadlock'
       ELSE 'Blocked Process'
       END AS ReportType,
  [event time],
  CASE [client app name] WHEN '' THEN ' -- N/A -- '
                         ELSE [client app name]
                         END AS [client app _name],
  CASE [client host name] WHEN '' THEN ' -- N/A -- '
                          ELSE [client host name]
                          END AS [client host name],
  [database name],
  COALESCE(OBJECT_SCHEMA_NAME(object_id, database_id), ' -- N/A -- ') AS [schema],
  COALESCE(OBJECT_NAME(object_id, database_id), ' -- N/A -- ') AS [table],
  index_id,
  [duration (ms)],
  lock_mode,
  COALESCE(SUSER_NAME(login_sid), ' -- N/A -- ') AS username,
  CASE WHEN blocked_process_report.value('(blocked-process-report[@monitorLoop])[1]', 'nvarchar(max)') IS NULL
       THEN deadlock_graph
       ELSE blocked_process_report
       END AS Report
FROM events_cte
ORDER BY [event time] DESC ;

--	Fetch Deadlock graph from 'system_health' extended event session



/*
	(@1 tinyint)SELECT * FROM [Person].[Person] WHERE [BusinessEntityID]=@1
*/

--	Viewing the Extended Events Deadlock Graphs
/*	1) Save the result of above query as *.xdl (xml deadlock) format.
	2) And, open the saved *.xdl file using SSMS or SQL Sentry Plan Explorer.

*/

--stop the event
ALTER EVENT SESSION blocked_process
ON SERVER
STATE = STOP;

-- start the event
ALTER EVENT SESSION blocked_process
ON SERVER
STATE = START
GO