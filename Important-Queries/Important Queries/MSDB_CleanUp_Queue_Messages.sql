-- Cleanup queue messages

-- Cleanup message from transmission queue and conversation endpoint by ending the conversation cleanly.

/*
During implementing & testing a Service Broker solution faulty messages could fill up the
messages queues. This Transact-SQL script clean up all / filtered messages in the exisiting queues
by ending the conversations cleanly.

Requieres db_owner or SysAdmin permissions.
Works with Microsoft SQL Server 2005 and higher versions in all editions.
*/

-- Cleanup message from transmission queue and conversation endpoint by ending the conversation cleanly.
DECLARE @conversation uniqueidentifier
DECLARE @cnt int;
SET @cnt = 0;

--** Cleanup transmission queue.
DECLARE MsgCursor CURSOR LOCAL FOR
    SELECT [conversation_handle]
    FROM sys.transmission_queue
    -- Add where filter for your purpose e.g. on service name or message type.

-- Open the cursor
OPEN MsgCursor;
    
FETCH NEXT FROM MsgCursor
    INTO @conversation;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- End conversation with cleanup.
    END CONVERSATION @conversation WITH CLEANUP;

    SET @cnt = @cnt + 1;
    FETCH NEXT FROM MsgCursor
        INTO @conversation;
END;

CLOSE MsgCursor;
DEALLOCATE MsgCursor;
PRINT CONVERT(varchar(10), @cnt) + ' Messages removed from transmission queue.';


--** Cleanup conversation endpoint.
SET @cnt = 0;

DECLARE MsgCursor CURSOR LOCAL FOR
    SELECT [conversation_handle]
    FROM sys.conversation_endpoints
    -- Add where filter for your purpose.

-- Open the cursor
OPEN MsgCursor;
    
FETCH NEXT FROM MsgCursor
    INTO @conversation;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- End conversation with cleanup.
    END CONVERSATION @conversation WITH CLEANUP;

    SET @cnt = @cnt + 1;
    FETCH NEXT FROM MsgCursor
        INTO @conversation;
END;

CLOSE MsgCursor;
DEALLOCATE MsgCursor;
PRINT CONVERT(varchar(10), @cnt) + ' Messages removed from conversation endpoint.';