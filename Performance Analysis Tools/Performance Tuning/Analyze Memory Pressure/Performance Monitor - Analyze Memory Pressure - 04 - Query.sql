USE tempdb
GO

CREATE TABLE dbo.mymessages (ID INT, mymessage TEXT);

INSERT INTO dbo.mymessages
SELECT TOP 100000 m1.message_id, m1.text 
FROM	sys.messages AS m1
CROSS JOIN
		sys.messages AS m2