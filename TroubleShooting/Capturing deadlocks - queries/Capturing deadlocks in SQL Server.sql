/* Capturing Deadlocks in SQL Server */ 

/*
Turn on/off trace flag 1204 
*/
DBCC TRACEON (1204);
GO 
DBCC TRACEOFF (1204);
GO 

/*
Turn on/off trace flag 1222
*/
DBCC TRACEON (1222);
GO 
DBCC TRACEOFF (1222);
GO 

/* 
SQL Server 2012 and 2014 
Query the system_health Extended Event session 
*/
SELECT
    DATEADD(mi,
    DATEDIFF(mi, GETUTCDATE(), CURRENT_TIMESTAMP),
    DeadlockEventXML.value(
      '(event/@timestamp)[1]', 'datetime2')) AS [event time] ,
	DeadlockEventXML.value('(//process[@id[ //victim-list/victimProcess[1]/@id]]/@hostname)[1]', 'nvarchar(max)') as hostname,
	DeadlockEventXML.value('(//process[@id[ //victim-list/victimProcess[1]/@id]]/@clientapp)[1]', 'nvarchar(max)') as clientapp,
		DB_NAME(DeadlockEventXML.value('(//process[@id[ //victim-list/victimProcess[1]/@id]]/@currentdb)[1]', 'nvarchar(max)')) as [Database],
		DeadlockEventXML.value('(//process[@id[ //victim-list/victimProcess[1]/@id]]/@transactionname)[1]', 'nvarchar(max)') as VictimTransactionName,
		DeadlockEventXML.value('(//process[@id[ //victim-list/victimProcess[1]/@id]]/@isolationlevel)[1]', 'nvarchar(max)') as IsolationLevel,
    DeadlockEventXML.query(
      '(event/data[@name="xml_report"]/value/deadlock)[1]')
      AS deadlock_graph, 
	   DeadlockEventXML 
  FROM    
  (  SELECT    XEvent.query('.') AS DeadlockEventXML, Data.TargetData 
          FROM      ( SELECT    CAST(target_data AS XML) AS TargetData
                      FROM      sys.dm_xe_session_targets st
                                JOIN sys.dm_xe_sessions s
                                 ON s.address = st.event_session_address
                      WHERE     s.name = 'system_health'
                                AND st.target_name = 'ring_buffer'
                    ) AS Data
                    CROSS APPLY TargetData.nodes
                  ('RingBufferTarget/event[@name="xml_deadlock_report"]')
                    AS XEventData ( XEvent )
        ) AS DeadlockInfo 