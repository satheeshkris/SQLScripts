use master
go

--	Step 1: Create Your @destination_table
DECLARE @destination_table VARCHAR(4000) ;
SET @destination_table = 'WhoIsActive_ResultSets';

DECLARE @schema VARCHAR(4000) ;
--	Specify all your proc parameters here
EXEC master..sp_WhoIsActive @get_plans=1, @get_full_inner_text=1, @get_transaction_info=1, @get_task_info=2, @get_locks=1, @get_avg_time=1, @get_additional_info=1,@find_block_leaders=1,
							@return_schema = 1,
							@schema = @schema OUTPUT ;

SET @schema = REPLACE(@schema, '<table_name>', @destination_table) ;

PRINT @schema
EXEC(@schema) ;
GO

--	Step 2: Create Your Loop to Periodically Log Data
USE [msdb]
GO

/****** Object:  Job [Log_With_sp_WhoIsActive]    Script Date: 12/27/2016 4:55:22 PM ******/
BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0
/****** Object:  JobCategory [[Uncategorized (Local)]]    Script Date: 12/27/2016 4:55:22 PM ******/
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'[Uncategorized (Local)]' AND category_class=1)
BEGIN
EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'[Uncategorized (Local)]'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

END

DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'Log_With_sp_WhoIsActive', 
		@enabled=1, 
		@notify_level_eventlog=0, 
		@notify_level_email=0, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'This job will log activities using Adam Mechanic''s [sp_whoIsActive] stored procedure.

Results are saved into master..WhoIsActive_ResultSets table.

Job will run every 3 seconds once started.', 
		@category_name=N'[Uncategorized (Local)]', 
		@owner_login_name=N'sa', @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
/****** Object:  Step [Log activities with [sp_WhoIsActive]]    Script Date: 12/27/2016 4:55:22 PM ******/
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Log activities with [sp_WhoIsActive]', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'DECLARE	@destination_table VARCHAR(4000);
SET @destination_table = ''WhoIsActive_ResultSets'';

EXEC master..sp_WhoIsActive @get_plans=1, @get_full_inner_text=1, @get_transaction_info=1, @get_task_info=2, @get_locks=1, @get_avg_time=1, @get_additional_info=1,@find_block_leaders=1,
            @destination_table = @destination_table ;', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Log_Using_whoIsActive_Every_3_Seconds', 
		@enabled=1, 
		@freq_type=4, 
		@freq_interval=1, 
		@freq_subday_type=2, 
		@freq_subday_interval=10, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=0, 
		@active_start_date=20161227, 
		@active_end_date=99991231, 
		@active_start_time=0, 
		@active_end_time=235959, 
		@schedule_uid=N'f583e6cd-9431-4afc-94a3-e3ef9bfa0d27'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:
GO
/*
DECLARE	@destination_table VARCHAR(4000);
SET @destination_table = 'WhoIsActive_ResultSets';

EXEC master..sp_WhoIsActive @get_plans=1, @get_full_inner_text=1, @get_transaction_info=1, @get_task_info=2, @get_locks=1, @get_avg_time=1, @get_additional_info=1,@find_block_leaders=1,
            @destination_table = @destination_table;
*/

--	Step 3: Query the resultset
SELECT * FROM WhoIsActive_ResultSets r
	WHERE CAST(r.collection_time AS DATE) = CAST(GETDATE() AS date);

SELECT * FROM WhoIsActive_ResultSets r
	WHERE r.collection_time BETWEEN '2016-12-28 08:42:20.527' AND '2016-12-28 08:51:30.797'
