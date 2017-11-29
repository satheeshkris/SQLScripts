
use master
go
sp_configure 'show advanced options',1
go
reconfigure with override
go
sp_configure 'Database Mail XPs',1
--go
--sp_configure 'SQL Mail XPs',0
go
reconfigure
go

--#################################################################################################
-- BEGIN Mail Settings admin
--#################################################################################################
IF NOT EXISTS(SELECT * FROM msdb.dbo.sysmail_profile WHERE  name = 'admin') 
  BEGIN
    --CREATE Profile [admin]
    EXECUTE msdb.dbo.sysmail_add_profile_sp
      @profile_name = 'admin',
      @description  = 'Profile for sending Automated DBA Notifications';
  END --IF EXISTS profile
  
  IF NOT EXISTS(SELECT * FROM msdb.dbo.sysmail_account WHERE  name = 'SQLAgent')
  BEGIN
    --CREATE Account [SQLAgent]
    EXECUTE msdb.dbo.sysmail_add_account_sp
    @account_name            = 'SQLAgent',
    @email_address           = 'sqlagentservice@gmail.com',
    @display_name            = 'SQLAlerts',
    @replyto_address         = 'sqlagentservice@gmail.com',
    @description             = '',
    @mailserver_name         = 'smtp.gmail.com',
    @mailserver_type         = 'SMTP',
    @port                    = 587,
    @username                = 'sqlagentservice@gmail.com',
    @password                = 'SomeDummyPassword', 
    @use_default_credentials =  0 ,
    @enable_ssl              =  1 ;
  END --IF EXISTS  account
  
IF NOT EXISTS(SELECT *
              FROM msdb.dbo.sysmail_profileaccount pa
                INNER JOIN msdb.dbo.sysmail_profile p ON pa.profile_id = p.profile_id
                INNER JOIN msdb.dbo.sysmail_account a ON pa.account_id = a.account_id  
              WHERE p.name = 'admin'
                AND a.name = 'SQLAgent') 
  BEGIN
    -- Associate Account [SQLAgent] to Profile [admin]
    EXECUTE msdb.dbo.sysmail_add_profileaccount_sp
      @profile_name = 'admin',
      @account_name = 'SQLAgent',
      @sequence_number = 1 ;
  END --IF EXISTS associate accounts to profiles
--#################################################################################################
-- Drop Settings For admin

EXEC msdb.dbo.sp_send_dbmail  
    @profile_name = 'admin',  
    @recipients = 'ajay.dwivedi2007@gmail.com',  
    @body = 'Hi Ajay,

This is a test mail from latop Server <LH7U05CG6260G3W>. Please ignore it.

Regards,
SQL Server Agent
',  
    @subject = 'Test Mail from latop Server <LH7U05CG6260G3W>' ;  
	

select * from msdb.dbo.sysmail_sentitems 
select * from msdb.dbo.sysmail_unsentitems 
select * from msdb.dbo.sysmail_faileditems 

SELECT items.subject,
    items.last_mod_date
    ,l.description FROM msdb.dbo.sysmail_faileditems as items
INNER JOIN msdb.dbo.sysmail_event_log AS l
    ON items.mailitem_id = l.mailitem_id
GO

/*
The mail could not be sent to the recipients because of the mail server failure. (Sending Mail using Account 1 (2016-11-13T22:29:31). Exception Message: Could not connect to mail server. (A connection attempt failed because the connected party did not properly respond after a period of time, or established connection failed because connected host has failed to respond 74.125.200.109:587).
)
*/
