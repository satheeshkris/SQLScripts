/*	Scripts in Series
1.	sp_WhoIsActive
2.	
*/

USE tempdb
GO

IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_NAME = 'sp_WhoIsActive')
	EXEC ('CREATE PROC dbo.sp_WhoIsActive AS SELECT ''stub version, to be replaced''')
GO

/*********************************************************************************************
Who Is Active? v11.17 (2016-10-18)
(C) 2007-2016, Adam Machanic

Feedback: mailto:amachanic@gmail.com
Updates: http://whoisactive.com

License: 
	Who is Active? is free to download and use for personal, educational, and internal 
	corporate purposes, provided that this header is preserved. Redistribution or sale 
	of Who is Active?, in whole or in part, is prohibited without the author's express 
	written consent.
*********************************************************************************************/
ALTER PROC dbo.sp_WhoIsActive
(
--~
	--Filters--Both inclusive and exclusive
	--Set either filter to '' to disable
	--Valid filter types are: session, program, database, login, and host
	--Session is a session ID, and either 0 or '' can be used to indicate "all" sessions
	--All other filter types support % or _ as wildcards
	@filter sysname = '',
	@filter_type VARCHAR(10) = 'session',
	@not_filter sysname = '',
	@not_filter_type VARCHAR(10) = 'session',

	--Retrieve data about the calling session?
	@show_own_spid BIT = 0,

	--Retrieve data about system sessions?
	@show_system_spids BIT = 0,

	--Controls how sleeping SPIDs are handled, based on the idea of levels of interest
	--0 does not pull any sleeping SPIDs
	--1 pulls only those sleeping SPIDs that also have an open transaction
	--2 pulls all sleeping SPIDs
	@show_sleeping_spids TINYINT = 1,

	--If 1, gets the full stored procedure or running batch, when available
	--If 0, gets only the actual statement that is currently running in the batch or procedure
	@get_full_inner_text BIT = 0,

	--Get associated query plans for running tasks, if available
	--If @get_plans = 1, gets the plan based on the request's statement offset
	--If @get_plans = 2, gets the entire plan based on the request's plan_handle
	@get_plans TINYINT = 0,

	--Get the associated outer ad hoc query or stored procedure call, if available
	@get_outer_command BIT = 0,

	--Enables pulling transaction log write info and transaction duration
	@get_transaction_info BIT = 0,

	--Get information on active tasks, based on three interest levels
	--Level 0 does not pull any task-related information
	--Level 1 is a lightweight mode that pulls the top non-CXPACKET wait, giving preference to blockers
	--Level 2 pulls all available task-based metrics, including: 
	--number of active tasks, current wait stats, physical I/O, context switches, and blocker information
	@get_task_info TINYINT = 1,

	--Gets associated locks for each request, aggregated in an XML format
	@get_locks BIT = 0,

	--Get average time for past runs of an active query
	--(based on the combination of plan handle, sql handle, and offset)
	@get_avg_time BIT = 0,

	--Get additional non-performance-related information about the session or request
	--text_size, language, date_format, date_first, quoted_identifier, arithabort, ansi_null_dflt_on, 
	--ansi_defaults, ansi_warnings, ansi_padding, ansi_nulls, concat_null_yields_null, 
	--transaction_isolation_level, lock_timeout, deadlock_priority, row_count, command_type
	--
	--If a SQL Agent job is running, an subnode called agent_info will be populated with some or all of
	--the following: job_id, job_name, step_id, step_name, msdb_query_error (in the event of an error)
	--
	--If @get_task_info is set to 2 and a lock wait is detected, a subnode called block_info will be
	--populated with some or all of the following: lock_type, database_name, object_id, file_id, hobt_id, 
	--applock_hash, metadata_resource, metadata_class_id, object_name, schema_name
	@get_additional_info BIT = 0,

	--Walk the blocking chain and count the number of 
	--total SPIDs blocked all the way down by a given session
	--Also enables task_info Level 1, if @get_task_info is set to 0
	@find_block_leaders BIT = 0,

	--Pull deltas on various metrics
	--Interval in seconds to wait before doing the second data pull
	@delta_interval TINYINT = 0,

	--List of desired output columns, in desired order
	--Note that the final output will be the intersection of all enabled features and all 
	--columns in the list. Therefore, only columns associated with enabled features will 
	--actually appear in the output. Likewise, removing columns from this list may effectively
	--disable features, even if they are turned on
	--
	--Each element in this list must be one of the valid output column names. Names must be
	--delimited by square brackets. White space, formatting, and additional characters are
	--allowed, as long as the list contains exact matches of delimited valid column names.
	@output_column_list VARCHAR(8000) = '[dd%][session_id][sql_text][sql_command][login_name][wait_info][tasks][tran_log%][cpu%][temp%][block%][reads%][writes%][context%][physical%][query_plan][locks][%]',

	--Column(s) by which to sort output, optionally with sort directions. 
		--Valid column choices:
		--session_id, physical_io, reads, physical_reads, writes, tempdb_allocations,
		--tempdb_current, CPU, context_switches, used_memory, physical_io_delta, 
		--reads_delta, physical_reads_delta, writes_delta, tempdb_allocations_delta, 
		--tempdb_current_delta, CPU_delta, context_switches_delta, used_memory_delta, 
		--tasks, tran_start_time, open_tran_count, blocking_session_id, blocked_session_count,
		--percent_complete, host_name, login_name, database_name, start_time, login_time
		--
		--Note that column names in the list must be bracket-delimited. Commas and/or white
		--space are not required. 
	@sort_order VARCHAR(500) = '[start_time] ASC',

	--Formats some of the output columns in a more "human readable" form
	--0 disables outfput format
	--1 formats the output for variable-width fonts
	--2 formats the output for fixed-width fonts
	@format_output TINYINT = 1,

	--If set to a non-blank value, the script will attempt to insert into the specified 
	--destination table. Please note that the script will not verify that the table exists, 
	--or that it has the correct schema, before doing the insert.
	--Table can be specified in one, two, or three-part format
	@destination_table VARCHAR(4000) = '',

	--If set to 1, no data collection will happen and no result set will be returned; instead,
	--a CREATE TABLE statement will be returned via the @schema parameter, which will match 
	--the schema of the result set that would be returned by using the same collection of the
	--rest of the parameters. The CREATE TABLE statement will have a placeholder token of 
	--<table_name> in place of an actual table name.
	@return_schema BIT = 0,
	@schema VARCHAR(MAX) = NULL OUTPUT,

	--Help! What do I do?
	@help BIT = 0
--~
)
/*
OUTPUT COLUMNS
--------------
Formatted/Non:	[session_id] [smallint] NOT NULL
	Session ID (a.k.a. SPID)

Formatted:		[dd hh:mm:ss.mss] [varchar](15) NULL
Non-Formatted:	<not returned>
	For an active request, time the query has been running
	For a sleeping session, time since the last batch completed

Formatted:		[dd hh:mm:ss.mss (avg)] [varchar](15) NULL
Non-Formatted:	[avg_elapsed_time] [int] NULL
	(Requires @get_avg_time option)
	How much time has the active portion of the query taken in the past, on average?

Formatted:		[physical_io] [varchar](30) NULL
Non-Formatted:	[physical_io] [bigint] NULL
	Shows the number of physical I/Os, for active requests

Formatted:		[reads] [varchar](30) NULL
Non-Formatted:	[reads] [bigint] NULL
	For an active request, number of reads done for the current query
	For a sleeping session, total number of reads done over the lifetime of the session

Formatted:		[physical_reads] [varchar](30) NULL
Non-Formatted:	[physical_reads] [bigint] NULL
	For an active request, number of physical reads done for the current query
	For a sleeping session, total number of physical reads done over the lifetime of the session

Formatted:		[writes] [varchar](30) NULL
Non-Formatted:	[writes] [bigint] NULL
	For an active request, number of writes done for the current query
	For a sleeping session, total number of writes done over the lifetime of the session

Formatted:		[tempdb_allocations] [varchar](30) NULL
Non-Formatted:	[tempdb_allocations] [bigint] NULL
	For an active request, number of TempDB writes done for the current query
	For a sleeping session, total number of TempDB writes done over the lifetime of the session

Formatted:		[tempdb_current] [varchar](30) NULL
Non-Formatted:	[tempdb_current] [bigint] NULL
	For an active request, number of TempDB pages currently allocated for the query
	For a sleeping session, number of TempDB pages currently allocated for the session

Formatted:		[CPU] [varchar](30) NULL
Non-Formatted:	[CPU] [int] NULL
	For an active request, total CPU time consumed by the current query
	For a sleeping session, total CPU time consumed over the lifetime of the session

Formatted:		[context_switches] [varchar](30) NULL
Non-Formatted:	[context_switches] [bigint] NULL
	Shows the number of context switches, for active requests

Formatted:		[used_memory] [varchar](30) NOT NULL
Non-Formatted:	[used_memory] [bigint] NOT NULL
	For an active request, total memory consumption for the current query
	For a sleeping session, total current memory consumption

Formatted:		[physical_io_delta] [varchar](30) NULL
Non-Formatted:	[physical_io_delta] [bigint] NULL
	(Requires @delta_interval option)
	Difference between the number of physical I/Os reported on the first and second collections. 
	If the request started after the first collection, the value will be NULL

Formatted:		[reads_delta] [varchar](30) NULL
Non-Formatted:	[reads_delta] [bigint] NULL
	(Requires @delta_interval option)
	Difference between the number of reads reported on the first and second collections. 
	If the request started after the first collection, the value will be NULL

Formatted:		[physical_reads_delta] [varchar](30) NULL
Non-Formatted:	[physical_reads_delta] [bigint] NULL
	(Requires @delta_interval option)
	Difference between the number of physical reads reported on the first and second collections. 
	If the request started after the first collection, the value will be NULL

Formatted:		[writes_delta] [varchar](30) NULL
Non-Formatted:	[writes_delta] [bigint] NULL
	(Requires @delta_interval option)
	Difference between the number of writes reported on the first and second collections. 
	If the request started after the first collection, the value will be NULL

Formatted:		[tempdb_allocations_delta] [varchar](30) NULL
Non-Formatted:	[tempdb_allocations_delta] [bigint] NULL
	(Requires @delta_interval option)
	Difference between the number of TempDB writes reported on the first and second collections. 
	If the request started after the first collection, the value will be NULL

Formatted:		[tempdb_current_delta] [varchar](30) NULL
Non-Formatted:	[tempdb_current_delta] [bigint] NULL
	(Requires @delta_interval option)
	Difference between the number of allocated TempDB pages reported on the first and second 
	collections. If the request started after the first collection, the value will be NULL

Formatted:		[CPU_delta] [varchar](30) NULL
Non-Formatted:	[CPU_delta] [int] NULL
	(Requires @delta_interval option)
	Difference between the CPU time reported on the first and second collections. 
	If the request started after the first collection, the value will be NULL

Formatted:		[context_switches_delta] [varchar](30) NULL
Non-Formatted:	[context_switches_delta] [bigint] NULL
	(Requires @delta_interval option)
	Difference between the context switches count reported on the first and second collections
	If the request started after the first collection, the value will be NULL

Formatted:		[used_memory_delta] [varchar](30) NULL
Non-Formatted:	[used_memory_delta] [bigint] NULL
	Difference between the memory usage reported on the first and second collections
	If the request started after the first collection, the value will be NULL

Formatted:		[tasks] [varchar](30) NULL
Non-Formatted:	[tasks] [smallint] NULL
	Number of worker tasks currently allocated, for active requests

Formatted/Non:	[status] [varchar](30) NOT NULL
	Activity status for the session (running, sleeping, etc)

Formatted/Non:	[wait_info] [nvarchar](4000) NULL
	Aggregates wait information, in the following format:
		(Ax: Bms/Cms/Dms)E
	A is the number of waiting tasks currently waiting on resource type E. B/C/D are wait
	times, in milliseconds. If only one thread is waiting, its wait time will be shown as B.
	If two tasks are waiting, each of their wait times will be shown (B/C). If three or more 
	tasks are waiting, the minimum, average, and maximum wait times will be shown (B/C/D).
	If wait type E is a page latch wait and the page is of a "special" type (e.g. PFS, GAM, SGAM), 
	the page type will be identified.
	If wait type E is CXPACKET, the nodeId from the query plan will be identified

Formatted/Non:	[locks] [xml] NULL
	(Requires @get_locks option)
	Aggregates lock information, in XML format.
	The lock XML includes the lock mode, locked object, and aggregates the number of requests. 
	Attempts are made to identify locked objects by name

Formatted/Non:	[tran_start_time] [datetime] NULL
	(Requires @get_transaction_info option)
	Date and time that the first transaction opened by a session caused a transaction log 
	write to occur.

Formatted/Non:	[tran_log_writes] [nvarchar](4000) NULL
	(Requires @get_transaction_info option)
	Aggregates transaction log write information, in the following format:
	A:wB (C kB)
	A is a database that has been touched by an active transaction
	B is the number of log writes that have been made in the database as a result of the transaction
	C is the number of log kilobytes consumed by the log records

Formatted:		[open_tran_count] [varchar](30) NULL
Non-Formatted:	[open_tran_count] [smallint] NULL
	Shows the number of open transactions the session has open

Formatted:		[sql_command] [xml] NULL
Non-Formatted:	[sql_command] [nvarchar](max) NULL
	(Requires @get_outer_command option)
	Shows the "outer" SQL command, i.e. the text of the batch or RPC sent to the server, 
	if available

Formatted:		[sql_text] [xml] NULL
Non-Formatted:	[sql_text] [nvarchar](max) NULL
	Shows the SQL text for active requests or the last statement executed
	for sleeping sessions, if available in either case.
	If @get_full_inner_text option is set, shows the full text of the batch.
	Otherwise, shows only the active statement within the batch.
	If the query text is locked, a special timeout message will be sent, in the following format:
		<timeout_exceeded />
	If an error occurs, an error message will be sent, in the following format:
		<error message="message" />

Formatted/Non:	[query_plan] [xml] NULL
	(Requires @get_plans option)
	Shows the query plan for the request, if available.
	If the plan is locked, a special timeout message will be sent, in the following format:
		<timeout_exceeded />
	If an error occurs, an error message will be sent, in the following format:
		<error message="message" />

Formatted/Non:	[blocking_session_id] [smallint] NULL
	When applicable, shows the blocking SPID

Formatted:		[blocked_session_count] [varchar](30) NULL
Non-Formatted:	[blocked_session_count] [smallint] NULL
	(Requires @find_block_leaders option)
	The total number of SPIDs blocked by this session,
	all the way down the blocking chain.

Formatted:		[percent_complete] [varchar](30) NULL
Non-Formatted:	[percent_complete] [real] NULL
	When applicable, shows the percent complete (e.g. for backups, restores, and some rollbacks)

Formatted/Non:	[host_name] [sysname] NOT NULL
	Shows the host name for the connection

Formatted/Non:	[login_name] [sysname] NOT NULL
	Shows the login name for the connection

Formatted/Non:	[database_name] [sysname] NULL
	Shows the connected database

Formatted/Non:	[program_name] [sysname] NULL
	Shows the reported program/application name

Formatted/Non:	[additional_info] [xml] NULL
	(Requires @get_additional_info option)
	Returns additional non-performance-related session/request information
	If the script finds a SQL Agent job running, the name of the job and job step will be reported
	If @get_task_info = 2 and the script finds a lock wait, the locked object will be reported

Formatted/Non:	[start_time] [datetime] NOT NULL
	For active requests, shows the time the request started
	For sleeping sessions, shows the time the last batch completed

Formatted/Non:	[login_time] [datetime] NOT NULL
	Shows the time that the session connected

Formatted/Non:	[request_id] [int] NULL
	For active requests, shows the request_id
	Should be 0 unless MARS is being used

Formatted/Non:	[collection_time] [datetime] NOT NULL
	Time that this script's final SELECT ran
*/
AS
BEGIN;
	SET NOCOUNT ON; 
	SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
	SET QUOTED_IDENTIFIER ON;
	SET ANSI_PADDING ON;
	SET CONCAT_NULL_YIELDS_NULL ON;
	SET ANSI_WARNINGS ON;
	SET NUMERIC_ROUNDABORT OFF;
	SET ARITHABORT ON;

	IF
		@filter IS NULL
		OR @filter_type IS NULL
		OR @not_filter IS NULL
		OR @not_filter_type IS NULL
		OR @show_own_spid IS NULL
		OR @show_system_spids IS NULL
		OR @show_sleeping_spids IS NULL
		OR @get_full_inner_text IS NULL
		OR @get_plans IS NULL
		OR @get_outer_command IS NULL
		OR @get_transaction_info IS NULL
		OR @get_task_info IS NULL
		OR @get_locks IS NULL
		OR @get_avg_time IS NULL
		OR @get_additional_info IS NULL
		OR @find_block_leaders IS NULL
		OR @delta_interval IS NULL
		OR @format_output IS NULL
		OR @output_column_list IS NULL
		OR @sort_order IS NULL
		OR @return_schema IS NULL
		OR @destination_table IS NULL
		OR @help IS NULL
	BEGIN;
		RAISERROR('Input parameters cannot be NULL', 16, 1);
		RETURN;
	END;
	
	IF @filter_type NOT IN ('session', 'program', 'database', 'login', 'host')
	BEGIN;
		RAISERROR('Valid filter types are: session, program, database, login, host', 16, 1);
		RETURN;
	END;
	
	IF @filter_type = 'session' AND @filter LIKE '%[^0123456789]%'
	BEGIN;
		RAISERROR('Session filters must be valid integers', 16, 1);
		RETURN;
	END;
	
	IF @not_filter_type NOT IN ('session', 'program', 'database', 'login', 'host')
	BEGIN;
		RAISERROR('Valid filter types are: session, program, database, login, host', 16, 1);
		RETURN;
	END;
	
	IF @not_filter_type = 'session' AND @not_filter LIKE '%[^0123456789]%'
	BEGIN;
		RAISERROR('Session filters must be valid integers', 16, 1);
		RETURN;
	END;
	
	IF @show_sleeping_spids NOT IN (0, 1, 2)
	BEGIN;
		RAISERROR('Valid values for @show_sleeping_spids are: 0, 1, or 2', 16, 1);
		RETURN;
	END;
	
	IF @get_plans NOT IN (0, 1, 2)
	BEGIN;
		RAISERROR('Valid values for @get_plans are: 0, 1, or 2', 16, 1);
		RETURN;
	END;

	IF @get_task_info NOT IN (0, 1, 2)
	BEGIN;
		RAISERROR('Valid values for @get_task_info are: 0, 1, or 2', 16, 1);
		RETURN;
	END;

	IF @format_output NOT IN (0, 1, 2)
	BEGIN;
		RAISERROR('Valid values for @format_output are: 0, 1, or 2', 16, 1);
		RETURN;
	END;
	
	IF @help = 1
	BEGIN;
		DECLARE 
			@header VARCHAR(MAX),
			@params VARCHAR(MAX),
			@outputs VARCHAR(MAX);

		SELECT 
			@header =
				REPLACE
				(
					REPLACE
					(
						CONVERT
						(
							VARCHAR(MAX),
							SUBSTRING
							(
								t.text, 
								CHARINDEX('/' + REPLICATE('*', 93), t.text) + 94,
								CHARINDEX(REPLICATE('*', 93) + '/', t.text) - (CHARINDEX('/' + REPLICATE('*', 93), t.text) + 94)
							)
						),
						CHAR(13)+CHAR(10),
						CHAR(13)
					),
					'	',
					''
				),
			@params =
				CHAR(13) +
					REPLACE
					(
						REPLACE
						(
							CONVERT
							(
								VARCHAR(MAX),
								SUBSTRING
								(
									t.text, 
									CHARINDEX('--~', t.text) + 5, 
									CHARINDEX('--~', t.text, CHARINDEX('--~', t.text) + 5) - (CHARINDEX('--~', t.text) + 5)
								)
							),
							CHAR(13)+CHAR(10),
							CHAR(13)
						),
						'	',
						''
					),
				@outputs = 
					CHAR(13) +
						REPLACE
						(
							REPLACE
							(
								REPLACE
								(
									CONVERT
									(
										VARCHAR(MAX),
										SUBSTRING
										(
											t.text, 
											CHARINDEX('OUTPUT COLUMNS'+CHAR(13)+CHAR(10)+'--------------', t.text) + 32,
											CHARINDEX('*/', t.text, CHARINDEX('OUTPUT COLUMNS'+CHAR(13)+CHAR(10)+'--------------', t.text) + 32) - (CHARINDEX('OUTPUT COLUMNS'+CHAR(13)+CHAR(10)+'--------------', t.text) + 32)
										)
									),
									CHAR(9),
									CHAR(255)
								),
								CHAR(13)+CHAR(10),
								CHAR(13)
							),
							'	',
							''
						) +
						CHAR(13)
		FROM sys.dm_exec_requests AS r
		CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
		WHERE
			r.session_id = @@SPID;

		WITH
		a0 AS
		(SELECT 1 AS n UNION ALL SELECT 1),
		a1 AS
		(SELECT 1 AS n FROM a0 AS a, a0 AS b),
		a2 AS
		(SELECT 1 AS n FROM a1 AS a, a1 AS b),
		a3 AS
		(SELECT 1 AS n FROM a2 AS a, a2 AS b),
		a4 AS
		(SELECT 1 AS n FROM a3 AS a, a3 AS b),
		numbers AS
		(
			SELECT TOP(LEN(@header) - 1)
				ROW_NUMBER() OVER
				(
					ORDER BY (SELECT NULL)
				) AS number
			FROM a4
			ORDER BY
				number
		)
		SELECT
			RTRIM(LTRIM(
				SUBSTRING
				(
					@header,
					number + 1,
					CHARINDEX(CHAR(13), @header, number + 1) - number - 1
				)
			)) AS [------header---------------------------------------------------------------------------------------------------------------]
		FROM numbers
		WHERE
			SUBSTRING(@header, number, 1) = CHAR(13);

		WITH
		a0 AS
		(SELECT 1 AS n UNION ALL SELECT 1),
		a1 AS
		(SELECT 1 AS n FROM a0 AS a, a0 AS b),
		a2 AS
		(SELECT 1 AS n FROM a1 AS a, a1 AS b),
		a3 AS
		(SELECT 1 AS n FROM a2 AS a, a2 AS b),
		a4 AS
		(SELECT 1 AS n FROM a3 AS a, a3 AS b),
		numbers AS
		(
			SELECT TOP(LEN(@params) - 1)
				ROW_NUMBER() OVER
				(
					ORDER BY (SELECT NULL)
				) AS number
			FROM a4
			ORDER BY
				number
		),
		tokens AS
		(
			SELECT 
				RTRIM(LTRIM(
					SUBSTRING
					(
						@params,
						number + 1,
						CHARINDEX(CHAR(13), @params, number + 1) - number - 1
					)
				)) AS token,
				number,
				CASE
					WHEN SUBSTRING(@params, number + 1, 1) = CHAR(13) THEN number
					ELSE COALESCE(NULLIF(CHARINDEX(',' + CHAR(13) + CHAR(13), @params, number), 0), LEN(@params)) 
				END AS param_group,
				ROW_NUMBER() OVER
				(
					PARTITION BY
						CHARINDEX(',' + CHAR(13) + CHAR(13), @params, number),
						SUBSTRING(@params, number+1, 1)
					ORDER BY 
						number
				) AS group_order
			FROM numbers
			WHERE
				SUBSTRING(@params, number, 1) = CHAR(13)
		),
		parsed_tokens AS
		(
			SELECT
				MIN
				(
					CASE
						WHEN token LIKE '@%' THEN token
						ELSE NULL
					END
				) AS parameter,
				MIN
				(
					CASE
						WHEN token LIKE '--%' THEN RIGHT(token, LEN(token) - 2)
						ELSE NULL
					END
				) AS description,
				param_group,
				group_order
			FROM tokens
			WHERE
				NOT 
				(
					token = '' 
					AND group_order > 1
				)
			GROUP BY
				param_group,
				group_order
		)
		SELECT
			CASE
				WHEN description IS NULL AND parameter IS NULL THEN '-------------------------------------------------------------------------'
				WHEN param_group = MAX(param_group) OVER() THEN parameter
				ELSE COALESCE(LEFT(parameter, LEN(parameter) - 1), '')
			END AS [------parameter----------------------------------------------------------],
			CASE
				WHEN description IS NULL AND parameter IS NULL THEN '----------------------------------------------------------------------------------------------------------------------'
				ELSE COALESCE(description, '')
			END AS [------description-----------------------------------------------------------------------------------------------------]
		FROM parsed_tokens
		ORDER BY
			param_group, 
			group_order;
		
		WITH
		a0 AS
		(SELECT 1 AS n UNION ALL SELECT 1),
		a1 AS
		(SELECT 1 AS n FROM a0 AS a, a0 AS b),
		a2 AS
		(SELECT 1 AS n FROM a1 AS a, a1 AS b),
		a3 AS
		(SELECT 1 AS n FROM a2 AS a, a2 AS b),
		a4 AS
		(SELECT 1 AS n FROM a3 AS a, a3 AS b),
		numbers AS
		(
			SELECT TOP(LEN(@outputs) - 1)
				ROW_NUMBER() OVER
				(
					ORDER BY (SELECT NULL)
				) AS number
			FROM a4
			ORDER BY
				number
		),
		tokens AS
		(
			SELECT 
				RTRIM(LTRIM(
					SUBSTRING
					(
						@outputs,
						number + 1,
						CASE
							WHEN 
								COALESCE(NULLIF(CHARINDEX(CHAR(13) + 'Formatted', @outputs, number + 1), 0), LEN(@outputs)) < 
								COALESCE(NULLIF(CHARINDEX(CHAR(13) + CHAR(255) COLLATE Latin1_General_Bin2, @outputs, number + 1), 0), LEN(@outputs))
								THEN COALESCE(NULLIF(CHARINDEX(CHAR(13) + 'Formatted', @outputs, number + 1), 0), LEN(@outputs)) - number - 1
							ELSE
								COALESCE(NULLIF(CHARINDEX(CHAR(13) + CHAR(255) COLLATE Latin1_General_Bin2, @outputs, number + 1), 0), LEN(@outputs)) - number - 1
						END
					)
				)) AS token,
				number,
				COALESCE(NULLIF(CHARINDEX(CHAR(13) + 'Formatted', @outputs, number + 1), 0), LEN(@outputs)) AS output_group,
				ROW_NUMBER() OVER
				(
					PARTITION BY 
						COALESCE(NULLIF(CHARINDEX(CHAR(13) + 'Formatted', @outputs, number + 1), 0), LEN(@outputs))
					ORDER BY
						number
				) AS output_group_order
			FROM numbers
			WHERE
				SUBSTRING(@outputs, number, 10) = CHAR(13) + 'Formatted'
				OR SUBSTRING(@outputs, number, 2) = CHAR(13) + CHAR(255) COLLATE Latin1_General_Bin2
		),
		output_tokens AS
		(
			SELECT 
				*,
				CASE output_group_order
					WHEN 2 THEN MAX(CASE output_group_order WHEN 1 THEN token ELSE NULL END) OVER (PARTITION BY output_group)
					ELSE ''
				END COLLATE Latin1_General_Bin2 AS column_info
			FROM tokens
		)
		SELECT
			CASE output_group_order
				WHEN 1 THEN '-----------------------------------'
				WHEN 2 THEN 
					CASE
						WHEN CHARINDEX('Formatted/Non:', column_info) = 1 THEN
							SUBSTRING(column_info, CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info)+1, CHARINDEX(']', column_info, CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info)+2) - CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info))
						ELSE
							SUBSTRING(column_info, CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info)+2, CHARINDEX(']', column_info, CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info)+2) - CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info)-1)
					END
				ELSE ''
			END AS formatted_column_name,
			CASE output_group_order
				WHEN 1 THEN '-----------------------------------'
				WHEN 2 THEN 
					CASE
						WHEN CHARINDEX('Formatted/Non:', column_info) = 1 THEN
							SUBSTRING(column_info, CHARINDEX(']', column_info)+2, LEN(column_info))
						ELSE
							SUBSTRING(column_info, CHARINDEX(']', column_info)+2, CHARINDEX('Non-Formatted:', column_info, CHARINDEX(']', column_info)+2) - CHARINDEX(']', column_info)-3)
					END
				ELSE ''
			END AS formatted_column_type,
			CASE output_group_order
				WHEN 1 THEN '---------------------------------------'
				WHEN 2 THEN 
					CASE
						WHEN CHARINDEX('Formatted/Non:', column_info) = 1 THEN ''
						ELSE
							CASE
								WHEN SUBSTRING(column_info, CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info, CHARINDEX('Non-Formatted:', column_info))+1, 1) = '<' THEN
									SUBSTRING(column_info, CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info, CHARINDEX('Non-Formatted:', column_info))+1, CHARINDEX('>', column_info, CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info, CHARINDEX('Non-Formatted:', column_info))+1) - CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info, CHARINDEX('Non-Formatted:', column_info)))
								ELSE
									SUBSTRING(column_info, CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info, CHARINDEX('Non-Formatted:', column_info))+1, CHARINDEX(']', column_info, CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info, CHARINDEX('Non-Formatted:', column_info))+1) - CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info, CHARINDEX('Non-Formatted:', column_info)))
							END
					END
				ELSE ''
			END AS unformatted_column_name,
			CASE output_group_order
				WHEN 1 THEN '---------------------------------------'
				WHEN 2 THEN 
					CASE
						WHEN CHARINDEX('Formatted/Non:', column_info) = 1 THEN ''
						ELSE
							CASE
								WHEN SUBSTRING(column_info, CHARINDEX(CHAR(255) COLLATE Latin1_General_Bin2, column_info, CHARINDEX('Non-Formatted:', column_info))+1, 1) = '<' THEN ''
								ELSE
									SUBSTRING(column_info, CHARINDEX(']', column_info, CHARINDEX('Non-Formatted:', column_info))+2, CHARINDEX('Non-Formatted:', column_info, CHARINDEX(']', column_info)+2) - CHARINDEX(']', column_info)-3)
							END
					END
				ELSE ''
			END AS unformatted_column_type,
			CASE output_group_order
				WHEN 1 THEN '----------------------------------------------------------------------------------------------------------------------'
				ELSE REPLACE(token, CHAR(255) COLLATE Latin1_General_Bin2, '')
			END AS [------description-----------------------------------------------------------------------------------------------------]
		FROM output_tokens
		WHERE
			NOT 
			(
				output_group_order = 1 
				AND output_group = LEN(@outputs)
			)
		ORDER BY
			output_group,
			CASE output_group_order
				WHEN 1 THEN 99
				ELSE output_group_order
			END;

		RETURN;
	END;

	WITH
	a0 AS
	(SELECT 1 AS n UNION ALL SELECT 1),
	a1 AS
	(SELECT 1 AS n FROM a0 AS a, a0 AS b),
	a2 AS
	(SELECT 1 AS n FROM a1 AS a, a1 AS b),
	a3 AS
	(SELECT 1 AS n FROM a2 AS a, a2 AS b),
	a4 AS
	(SELECT 1 AS n FROM a3 AS a, a3 AS b),
	numbers AS
	(
		SELECT TOP(LEN(@output_column_list))
			ROW_NUMBER() OVER
			(
				ORDER BY (SELECT NULL)
			) AS number
		FROM a4
		ORDER BY
			number
	),
	tokens AS
	(
		SELECT 
			'|[' +
				SUBSTRING
				(
					@output_column_list,
					number + 1,
					CHARINDEX(']', @output_column_list, number) - number - 1
				) + '|]' AS token,
			number
		FROM numbers
		WHERE
			SUBSTRING(@output_column_list, number, 1) = '['
	),
	ordered_columns AS
	(
		SELECT
			x.column_name,
			ROW_NUMBER() OVER
			(
				PARTITION BY
					x.column_name
				ORDER BY
					tokens.number,
					x.default_order
			) AS r,
			ROW_NUMBER() OVER
			(
				ORDER BY
					tokens.number,
					x.default_order
			) AS s
		FROM tokens
		JOIN
		(
			SELECT '[session_id]' AS column_name, 1 AS default_order
			UNION ALL
			SELECT '[dd hh:mm:ss.mss]', 2
			WHERE
				@format_output IN (1, 2)
			UNION ALL
			SELECT '[dd hh:mm:ss.mss (avg)]', 3
			WHERE
				@format_output IN (1, 2)
				AND @get_avg_time = 1
			UNION ALL
			SELECT '[avg_elapsed_time]', 4
			WHERE
				@format_output = 0
				AND @get_avg_time = 1
			UNION ALL
			SELECT '[physical_io]', 5
			WHERE
				@get_task_info = 2
			UNION ALL
			SELECT '[reads]', 6
			UNION ALL
			SELECT '[physical_reads]', 7
			UNION ALL
			SELECT '[writes]', 8
			UNION ALL
			SELECT '[tempdb_allocations]', 9
			UNION ALL
			SELECT '[tempdb_current]', 10
			UNION ALL
			SELECT '[CPU]', 11
			UNION ALL
			SELECT '[context_switches]', 12
			WHERE
				@get_task_info = 2
			UNION ALL
			SELECT '[used_memory]', 13
			UNION ALL
			SELECT '[physical_io_delta]', 14
			WHERE
				@delta_interval > 0	
				AND @get_task_info = 2
			UNION ALL
			SELECT '[reads_delta]', 15
			WHERE
				@delta_interval > 0
			UNION ALL
			SELECT '[physical_reads_delta]', 16
			WHERE
				@delta_interval > 0
			UNION ALL
			SELECT '[writes_delta]', 17
			WHERE
				@delta_interval > 0
			UNION ALL
			SELECT '[tempdb_allocations_delta]', 18
			WHERE
				@delta_interval > 0
			UNION ALL
			SELECT '[tempdb_current_delta]', 19
			WHERE
				@delta_interval > 0
			UNION ALL
			SELECT '[CPU_delta]', 20
			WHERE
				@delta_interval > 0
			UNION ALL
			SELECT '[context_switches_delta]', 21
			WHERE
				@delta_interval > 0
				AND @get_task_info = 2
			UNION ALL
			SELECT '[used_memory_delta]', 22
			WHERE
				@delta_interval > 0
			UNION ALL
			SELECT '[tasks]', 23
			WHERE
				@get_task_info = 2
			UNION ALL
			SELECT '[status]', 24
			UNION ALL
			SELECT '[wait_info]', 25
			WHERE
				@get_task_info > 0
				OR @find_block_leaders = 1
			UNION ALL
			SELECT '[locks]', 26
			WHERE
				@get_locks = 1
			UNION ALL
			SELECT '[tran_start_time]', 27
			WHERE
				@get_transaction_info = 1
			UNION ALL
			SELECT '[tran_log_writes]', 28
			WHERE
				@get_transaction_info = 1
			UNION ALL
			SELECT '[open_tran_count]', 29
			UNION ALL
			SELECT '[sql_command]', 30
			WHERE
				@get_outer_command = 1
			UNION ALL
			SELECT '[sql_text]', 31
			UNION ALL
			SELECT '[query_plan]', 32
			WHERE
				@get_plans >= 1
			UNION ALL
			SELECT '[blocking_session_id]', 33
			WHERE
				@get_task_info > 0
				OR @find_block_leaders = 1
			UNION ALL
			SELECT '[blocked_session_count]', 34
			WHERE
				@find_block_leaders = 1
			UNION ALL
			SELECT '[percent_complete]', 35
			UNION ALL
			SELECT '[host_name]', 36
			UNION ALL
			SELECT '[login_name]', 37
			UNION ALL
			SELECT '[database_name]', 38
			UNION ALL
			SELECT '[program_name]', 39
			UNION ALL
			SELECT '[additional_info]', 40
			WHERE
				@get_additional_info = 1
			UNION ALL
			SELECT '[start_time]', 41
			UNION ALL
			SELECT '[login_time]', 42
			UNION ALL
			SELECT '[request_id]', 43
			UNION ALL
			SELECT '[collection_time]', 44
		) AS x ON 
			x.column_name LIKE token ESCAPE '|'
	)
	SELECT
		@output_column_list =
			STUFF
			(
				(
					SELECT
						',' + column_name as [text()]
					FROM ordered_columns
					WHERE
						r = 1
					ORDER BY
						s
					FOR XML
						PATH('')
				),
				1,
				1,
				''
			);
	
	IF COALESCE(RTRIM(@output_column_list), '') = ''
	BEGIN;
		RAISERROR('No valid column matches found in @output_column_list or no columns remain due to selected options.', 16, 1);
		RETURN;
	END;
	
	IF @destination_table <> ''
	BEGIN;
		SET @destination_table = 
			--database
			COALESCE(QUOTENAME(PARSENAME(@destination_table, 3)) + '.', '') +
			--schema
			COALESCE(QUOTENAME(PARSENAME(@destination_table, 2)) + '.', '') +
			--table
			COALESCE(QUOTENAME(PARSENAME(@destination_table, 1)), '');
			
		IF COALESCE(RTRIM(@destination_table), '') = ''
		BEGIN;
			RAISERROR('Destination table not properly formatted.', 16, 1);
			RETURN;
		END;
	END;

	WITH
	a0 AS
	(SELECT 1 AS n UNION ALL SELECT 1),
	a1 AS
	(SELECT 1 AS n FROM a0 AS a, a0 AS b),
	a2 AS
	(SELECT 1 AS n FROM a1 AS a, a1 AS b),
	a3 AS
	(SELECT 1 AS n FROM a2 AS a, a2 AS b),
	a4 AS
	(SELECT 1 AS n FROM a3 AS a, a3 AS b),
	numbers AS
	(
		SELECT TOP(LEN(@sort_order))
			ROW_NUMBER() OVER
			(
				ORDER BY (SELECT NULL)
			) AS number
		FROM a4
		ORDER BY
			number
	),
	tokens AS
	(
		SELECT 
			'|[' +
				SUBSTRING
				(
					@sort_order,
					number + 1,
					CHARINDEX(']', @sort_order, number) - number - 1
				) + '|]' AS token,
			SUBSTRING
			(
				@sort_order,
				CHARINDEX(']', @sort_order, number) + 1,
				COALESCE(NULLIF(CHARINDEX('[', @sort_order, CHARINDEX(']', @sort_order, number)), 0), LEN(@sort_order)) - CHARINDEX(']', @sort_order, number)
			) AS next_chunk,
			number
		FROM numbers
		WHERE
			SUBSTRING(@sort_order, number, 1) = '['
	),
	ordered_columns AS
	(
		SELECT
			x.column_name +
				CASE
					WHEN tokens.next_chunk LIKE '%asc%' THEN ' ASC'
					WHEN tokens.next_chunk LIKE '%desc%' THEN ' DESC'
					ELSE ''
				END AS column_name,
			ROW_NUMBER() OVER
			(
				PARTITION BY
					x.column_name
				ORDER BY
					tokens.number
			) AS r,
			tokens.number
		FROM tokens
		JOIN
		(
			SELECT '[session_id]' AS column_name
			UNION ALL
			SELECT '[physical_io]'
			UNION ALL
			SELECT '[reads]'
			UNION ALL
			SELECT '[physical_reads]'
			UNION ALL
			SELECT '[writes]'
			UNION ALL
			SELECT '[tempdb_allocations]'
			UNION ALL
			SELECT '[tempdb_current]'
			UNION ALL
			SELECT '[CPU]'
			UNION ALL
			SELECT '[context_switches]'
			UNION ALL
			SELECT '[used_memory]'
			UNION ALL
			SELECT '[physical_io_delta]'
			UNION ALL
			SELECT '[reads_delta]'
			UNION ALL
			SELECT '[physical_reads_delta]'
			UNION ALL
			SELECT '[writes_delta]'
			UNION ALL
			SELECT '[tempdb_allocations_delta]'
			UNION ALL
			SELECT '[tempdb_current_delta]'
			UNION ALL
			SELECT '[CPU_delta]'
			UNION ALL
			SELECT '[context_switches_delta]'
			UNION ALL
			SELECT '[used_memory_delta]'
			UNION ALL
			SELECT '[tasks]'
			UNION ALL
			SELECT '[tran_start_time]'
			UNION ALL
			SELECT '[open_tran_count]'
			UNION ALL
			SELECT '[blocking_session_id]'
			UNION ALL
			SELECT '[blocked_session_count]'
			UNION ALL
			SELECT '[percent_complete]'
			UNION ALL
			SELECT '[host_name]'
			UNION ALL
			SELECT '[login_name]'
			UNION ALL
			SELECT '[database_name]'
			UNION ALL
			SELECT '[start_time]'
			UNION ALL
			SELECT '[login_time]'
		) AS x ON 
			x.column_name LIKE token ESCAPE '|'
	)
	SELECT
		@sort_order = COALESCE(z.sort_order, '')
	FROM
	(
		SELECT
			STUFF
			(
				(
					SELECT
						',' + column_name as [text()]
					FROM ordered_columns
					WHERE
						r = 1
					ORDER BY
						number
					FOR XML
						PATH('')
				),
				1,
				1,
				''
			) AS sort_order
	) AS z;

	CREATE TABLE #sessions
	(
		recursion SMALLINT NOT NULL,
		session_id SMALLINT NOT NULL,
		request_id INT NOT NULL,
		session_number INT NOT NULL,
		elapsed_time INT NOT NULL,
		avg_elapsed_time INT NULL,
		physical_io BIGINT NULL,
		reads BIGINT NULL,
		physical_reads BIGINT NULL,
		writes BIGINT NULL,
		tempdb_allocations BIGINT NULL,
		tempdb_current BIGINT NULL,
		CPU INT NULL,
		thread_CPU_snapshot BIGINT NULL,
		context_switches BIGINT NULL,
		used_memory BIGINT NOT NULL, 
		tasks SMALLINT NULL,
		status VARCHAR(30) NOT NULL,
		wait_info NVARCHAR(4000) NULL,
		locks XML NULL,
		transaction_id BIGINT NULL,
		tran_start_time DATETIME NULL,
		tran_log_writes NVARCHAR(4000) NULL,
		open_tran_count SMALLINT NULL,
		sql_command XML NULL,
		sql_handle VARBINARY(64) NULL,
		statement_start_offset INT NULL,
		statement_end_offset INT NULL,
		sql_text XML NULL,
		plan_handle VARBINARY(64) NULL,
		query_plan XML NULL,
		blocking_session_id SMALLINT NULL,
		blocked_session_count SMALLINT NULL,
		percent_complete REAL NULL,
		host_name sysname NULL,
		login_name sysname NOT NULL,
		database_name sysname NULL,
		program_name sysname NULL,
		additional_info XML NULL,
		start_time DATETIME NOT NULL,
		login_time DATETIME NULL,
		last_request_start_time DATETIME NULL,
		PRIMARY KEY CLUSTERED (session_id, request_id, recursion) WITH (IGNORE_DUP_KEY = ON),
		UNIQUE NONCLUSTERED (transaction_id, session_id, request_id, recursion) WITH (IGNORE_DUP_KEY = ON)
	);

	IF @return_schema = 0
	BEGIN;
		--Disable unnecessary autostats on the table
		CREATE STATISTICS s_session_id ON #sessions (session_id)
		WITH SAMPLE 0 ROWS, NORECOMPUTE;
		CREATE STATISTICS s_request_id ON #sessions (request_id)
		WITH SAMPLE 0 ROWS, NORECOMPUTE;
		CREATE STATISTICS s_transaction_id ON #sessions (transaction_id)
		WITH SAMPLE 0 ROWS, NORECOMPUTE;
		CREATE STATISTICS s_session_number ON #sessions (session_number)
		WITH SAMPLE 0 ROWS, NORECOMPUTE;
		CREATE STATISTICS s_status ON #sessions (status)
		WITH SAMPLE 0 ROWS, NORECOMPUTE;
		CREATE STATISTICS s_start_time ON #sessions (start_time)
		WITH SAMPLE 0 ROWS, NORECOMPUTE;
		CREATE STATISTICS s_last_request_start_time ON #sessions (last_request_start_time)
		WITH SAMPLE 0 ROWS, NORECOMPUTE;
		CREATE STATISTICS s_recursion ON #sessions (recursion)
		WITH SAMPLE 0 ROWS, NORECOMPUTE;

		DECLARE @recursion SMALLINT;
		SET @recursion = 
			CASE @delta_interval
				WHEN 0 THEN 1
				ELSE -1
			END;

		DECLARE @first_collection_ms_ticks BIGINT;
		DECLARE @last_collection_start DATETIME;

		--Used for the delta pull
		REDO:;
		
		IF 
			@get_locks = 1 
			AND @recursion = 1
			AND @output_column_list LIKE '%|[locks|]%' ESCAPE '|'
		BEGIN;
			SELECT
				y.resource_type,
				y.database_name,
				y.object_id,
				y.file_id,
				y.page_type,
				y.hobt_id,
				y.allocation_unit_id,
				y.index_id,
				y.schema_id,
				y.principal_id,
				y.request_mode,
				y.request_status,
				y.session_id,
				y.resource_description,
				y.request_count,
				s.request_id,
				s.start_time,
				CONVERT(sysname, NULL) AS object_name,
				CONVERT(sysname, NULL) AS index_name,
				CONVERT(sysname, NULL) AS schema_name,
				CONVERT(sysname, NULL) AS principal_name,
				CONVERT(NVARCHAR(2048), NULL) AS query_error
			INTO #locks
			FROM
			(
				SELECT
					sp.spid AS session_id,
					CASE sp.status
						WHEN 'sleeping' THEN CONVERT(INT, 0)
						ELSE sp.request_id
					END AS request_id,
					CASE sp.status
						WHEN 'sleeping' THEN sp.last_batch
						ELSE COALESCE(req.start_time, sp.last_batch)
					END AS start_time,
					sp.dbid
				FROM sys.sysprocesses AS sp
				OUTER APPLY
				(
					SELECT TOP(1)
						CASE
							WHEN 
							(
								sp.hostprocess > ''
								OR r.total_elapsed_time < 0
							) THEN
								r.start_time
							ELSE
								DATEADD
								(
									ms, 
									1000 * (DATEPART(ms, DATEADD(second, -(r.total_elapsed_time / 1000), GETDATE())) / 500) - DATEPART(ms, DATEADD(second, -(r.total_elapsed_time / 1000), GETDATE())), 
									DATEADD(second, -(r.total_elapsed_time / 1000), GETDATE())
								)
						END AS start_time
					FROM sys.dm_exec_requests AS r
					WHERE
						r.session_id = sp.spid
						AND r.request_id = sp.request_id
				) AS req
				WHERE
					--Process inclusive filter
					1 =
						CASE
							WHEN @filter <> '' THEN
								CASE @filter_type
									WHEN 'session' THEN
										CASE
											WHEN
												CONVERT(SMALLINT, @filter) = 0
												OR sp.spid = CONVERT(SMALLINT, @filter)
													THEN 1
											ELSE 0
										END
									WHEN 'program' THEN
										CASE
											WHEN sp.program_name LIKE @filter THEN 1
											ELSE 0
										END
									WHEN 'login' THEN
										CASE
											WHEN sp.loginame LIKE @filter THEN 1
											ELSE 0
										END
									WHEN 'host' THEN
										CASE
											WHEN sp.hostname LIKE @filter THEN 1
											ELSE 0
										END
									WHEN 'database' THEN
										CASE
											WHEN DB_NAME(sp.dbid) LIKE @filter THEN 1
											ELSE 0
										END
									ELSE 0
								END
							ELSE 1
						END
					--Process exclusive filter
					AND 0 =
						CASE
							WHEN @not_filter <> '' THEN
								CASE @not_filter_type
									WHEN 'session' THEN
										CASE
											WHEN sp.spid = CONVERT(SMALLINT, @not_filter) THEN 1
											ELSE 0
										END
									WHEN 'program' THEN
										CASE
											WHEN sp.program_name LIKE @not_filter THEN 1
											ELSE 0
										END
									WHEN 'login' THEN
										CASE
											WHEN sp.loginame LIKE @not_filter THEN 1
											ELSE 0
										END
									WHEN 'host' THEN
										CASE
											WHEN sp.hostname LIKE @not_filter THEN 1
											ELSE 0
										END
									WHEN 'database' THEN
										CASE
											WHEN DB_NAME(sp.dbid) LIKE @not_filter THEN 1
											ELSE 0
										END
									ELSE 0
								END
							ELSE 0
						END
					AND 
					(
						@show_own_spid = 1
						OR sp.spid <> @@SPID
					)
					AND 
					(
						@show_system_spids = 1
						OR sp.hostprocess > ''
					)
					AND sp.ecid = 0
			) AS s
			INNER HASH JOIN
			(
				SELECT
					x.resource_type,
					x.database_name,
					x.object_id,
					x.file_id,
					CASE
						WHEN x.page_no = 1 OR x.page_no % 8088 = 0 THEN 'PFS'
						WHEN x.page_no = 2 OR x.page_no % 511232 = 0 THEN 'GAM'
						WHEN x.page_no = 3 OR (x.page_no - 1) % 511232 = 0 THEN 'SGAM'
						WHEN x.page_no = 6 OR (x.page_no - 6) % 511232 = 0 THEN 'DCM'
						WHEN x.page_no = 7 OR (x.page_no - 7) % 511232 = 0 THEN 'BCM'
						WHEN x.page_no IS NOT NULL THEN '*'
						ELSE NULL
					END AS page_type,
					x.hobt_id,
					x.allocation_unit_id,
					x.index_id,
					x.schema_id,
					x.principal_id,
					x.request_mode,
					x.request_status,
					x.session_id,
					x.request_id,
					CASE
						WHEN COALESCE(x.object_id, x.file_id, x.hobt_id, x.allocation_unit_id, x.index_id, x.schema_id, x.principal_id) IS NULL THEN NULLIF(resource_description, '')
						ELSE NULL
					END AS resource_description,
					COUNT(*) AS request_count
				FROM
				(
					SELECT
						tl.resource_type +
							CASE
								WHEN tl.resource_subtype = '' THEN ''
								ELSE '.' + tl.resource_subtype
							END AS resource_type,
						COALESCE(DB_NAME(tl.resource_database_id), N'(null)') AS database_name,
						CONVERT
						(
							INT,
							CASE
								WHEN tl.resource_type = 'OBJECT' THEN tl.resource_associated_entity_id
								WHEN tl.resource_description LIKE '%object_id = %' THEN
									(
										SUBSTRING
										(
											tl.resource_description, 
											(CHARINDEX('object_id = ', tl.resource_description) + 12), 
											COALESCE
											(
												NULLIF
												(
													CHARINDEX(',', tl.resource_description, CHARINDEX('object_id = ', tl.resource_description) + 12),
													0
												), 
												DATALENGTH(tl.resource_description)+1
											) - (CHARINDEX('object_id = ', tl.resource_description) + 12)
										)
									)
								ELSE NULL
							END
						) AS object_id,
						CONVERT
						(
							INT,
							CASE 
								WHEN tl.resource_type = 'FILE' THEN CONVERT(INT, tl.resource_description)
								WHEN tl.resource_type IN ('PAGE', 'EXTENT', 'RID') THEN LEFT(tl.resource_description, CHARINDEX(':', tl.resource_description)-1)
								ELSE NULL
							END
						) AS file_id,
						CONVERT
						(
							INT,
							CASE
								WHEN tl.resource_type IN ('PAGE', 'EXTENT', 'RID') THEN 
									SUBSTRING
									(
										tl.resource_description, 
										CHARINDEX(':', tl.resource_description) + 1, 
										COALESCE
										(
											NULLIF
											(
												CHARINDEX(':', tl.resource_description, CHARINDEX(':', tl.resource_description) + 1), 
												0
											), 
											DATALENGTH(tl.resource_description)+1
										) - (CHARINDEX(':', tl.resource_description) + 1)
									)
								ELSE NULL
							END
						) AS page_no,
						CASE
							WHEN tl.resource_type IN ('PAGE', 'KEY', 'RID', 'HOBT') THEN tl.resource_associated_entity_id
							ELSE NULL
						END AS hobt_id,
						CASE
							WHEN tl.resource_type = 'ALLOCATION_UNIT' THEN tl.resource_associated_entity_id
							ELSE NULL
						END AS allocation_unit_id,
						CONVERT
						(
							INT,
							CASE
								WHEN
									/*TODO: Deal with server principals*/ 
									tl.resource_subtype <> 'SERVER_PRINCIPAL' 
									AND tl.resource_description LIKE '%index_id or stats_id = %' THEN
									(
										SUBSTRING
										(
											tl.resource_description, 
											(CHARINDEX('index_id or stats_id = ', tl.resource_description) + 23), 
											COALESCE
											(
												NULLIF
												(
													CHARINDEX(',', tl.resource_description, CHARINDEX('index_id or stats_id = ', tl.resource_description) + 23), 
													0
												), 
												DATALENGTH(tl.resource_description)+1
											) - (CHARINDEX('index_id or stats_id = ', tl.resource_description) + 23)
										)
									)
								ELSE NULL
							END 
						) AS index_id,
						CONVERT
						(
							INT,
							CASE
								WHEN tl.resource_description LIKE '%schema_id = %' THEN
									(
										SUBSTRING
										(
											tl.resource_description, 
											(CHARINDEX('schema_id = ', tl.resource_description) + 12), 
											COALESCE
											(
												NULLIF
												(
													CHARINDEX(',', tl.resource_description, CHARINDEX('schema_id = ', tl.resource_description) + 12), 
													0
												), 
												DATALENGTH(tl.resource_description)+1
											) - (CHARINDEX('schema_id = ', tl.resource_description) + 12)
										)
									)
								ELSE NULL
							END 
						) AS schema_id,
						CONVERT
						(
							INT,
							CASE
								WHEN tl.resource_description LIKE '%principal_id = %' THEN
									(
										SUBSTRING
										(
											tl.resource_description, 
											(CHARINDEX('principal_id = ', tl.resource_description) + 15), 
											COALESCE
											(
												NULLIF
												(
													CHARINDEX(',', tl.resource_description, CHARINDEX('principal_id = ', tl.resource_description) + 15), 
													0
												), 
												DATALENGTH(tl.resource_description)+1
											) - (CHARINDEX('principal_id = ', tl.resource_description) + 15)
										)
									)
								ELSE NULL
							END
						) AS principal_id,
						tl.request_mode,
						tl.request_status,
						tl.request_session_id AS session_id,
						tl.request_request_id AS request_id,

						/*TODO: Applocks, other resource_descriptions*/
						RTRIM(tl.resource_description) AS resource_description,
						tl.resource_associated_entity_id
						/*********************************************/
					FROM 
					(
						SELECT 
							request_session_id,
							CONVERT(VARCHAR(120), resource_type) COLLATE Latin1_General_Bin2 AS resource_type,
							CONVERT(VARCHAR(120), resource_subtype) COLLATE Latin1_General_Bin2 AS resource_subtype,
							resource_database_id,
							CONVERT(VARCHAR(512), resource_description) COLLATE Latin1_General_Bin2 AS resource_description,
							resource_associated_entity_id,
							CONVERT(VARCHAR(120), request_mode) COLLATE Latin1_General_Bin2 AS request_mode,
							CONVERT(VARCHAR(120), request_status) COLLATE Latin1_General_Bin2 AS request_status,
							request_request_id
						FROM sys.dm_tran_locks
					) AS tl
				) AS x
				GROUP BY
					x.resource_type,
					x.database_name,
					x.object_id,
					x.file_id,
					CASE
						WHEN x.page_no = 1 OR x.page_no % 8088 = 0 THEN 'PFS'
						WHEN x.page_no = 2 OR x.page_no % 511232 = 0 THEN 'GAM'
						WHEN x.page_no = 3 OR (x.page_no - 1) % 511232 = 0 THEN 'SGAM'
						WHEN x.page_no = 6 OR (x.page_no - 6) % 511232 = 0 THEN 'DCM'
						WHEN x.page_no = 7 OR (x.page_no - 7) % 511232 = 0 THEN 'BCM'
						WHEN x.page_no IS NOT NULL THEN '*'
						ELSE NULL
					END,
					x.hobt_id,
					x.allocation_unit_id,
					x.index_id,
					x.schema_id,
					x.principal_id,
					x.request_mode,
					x.request_status,
					x.session_id,
					x.request_id,
					CASE
						WHEN COALESCE(x.object_id, x.file_id, x.hobt_id, x.allocation_unit_id, x.index_id, x.schema_id, x.principal_id) IS NULL THEN NULLIF(resource_description, '')
						ELSE NULL
					END
			) AS y ON
				y.session_id = s.session_id
				AND y.request_id = s.request_id
			OPTION (HASH GROUP);

			--Disable unnecessary autostats on the table
			CREATE STATISTICS s_database_name ON #locks (database_name)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_object_id ON #locks (object_id)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_hobt_id ON #locks (hobt_id)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_allocation_unit_id ON #locks (allocation_unit_id)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_index_id ON #locks (index_id)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_schema_id ON #locks (schema_id)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_principal_id ON #locks (principal_id)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_request_id ON #locks (request_id)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_start_time ON #locks (start_time)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_resource_type ON #locks (resource_type)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_object_name ON #locks (object_name)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_schema_name ON #locks (schema_name)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_page_type ON #locks (page_type)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_request_mode ON #locks (request_mode)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_request_status ON #locks (request_status)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_resource_description ON #locks (resource_description)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_index_name ON #locks (index_name)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_principal_name ON #locks (principal_name)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
		END;
		
		DECLARE 
			@sql VARCHAR(MAX), 
			@sql_n NVARCHAR(MAX);

		SET @sql = 
			CONVERT(VARCHAR(MAX), '') +
			'DECLARE @blocker BIT;
			SET @blocker = 0;
			DECLARE @i INT;
			SET @i = 2147483647;

			DECLARE @sessions TABLE
			(
				session_id SMALLINT NOT NULL,
				request_id INT NOT NULL,
				login_time DATETIME,
				last_request_end_time DATETIME,
				status VARCHAR(30),
				statement_start_offset INT,
				statement_end_offset INT,
				sql_handle BINARY(20),
				host_name NVARCHAR(128),
				login_name NVARCHAR(128),
				program_name NVARCHAR(128),
				database_id SMALLINT,
				memory_usage INT,
				open_tran_count SMALLINT, 
				' +
				CASE
					WHEN 
					(
						@get_task_info <> 0 
						OR @find_block_leaders = 1 
					) THEN
						'wait_type NVARCHAR(32),
						wait_resource NVARCHAR(256),
						wait_time BIGINT, 
						'
					ELSE 
						''
				END +
				'blocked SMALLINT,
				is_user_process BIT,
				cmd VARCHAR(32),
				PRIMARY KEY CLUSTERED (session_id, request_id) WITH (IGNORE_DUP_KEY = ON)
			);

			DECLARE @blockers TABLE
			(
				session_id INT NOT NULL PRIMARY KEY WITH (IGNORE_DUP_KEY = ON)
			);

			BLOCKERS:;

			INSERT @sessions
			(
				session_id,
				request_id,
				login_time,
				last_request_end_time,
				status,
				statement_start_offset,
				statement_end_offset,
				sql_handle,
				host_name,
				login_name,
				program_name,
				database_id,
				memory_usage,
				open_tran_count, 
				' +
				CASE
					WHEN 
					(
						@get_task_info <> 0
						OR @find_block_leaders = 1 
					) THEN
						'wait_type,
						wait_resource,
						wait_time, 
						'
					ELSE
						''
				END +
				'blocked,
				is_user_process,
				cmd 
			)
			SELECT TOP(@i)
				spy.session_id,
				spy.request_id,
				spy.login_time,
				spy.last_request_end_time,
				spy.status,
				spy.statement_start_offset,
				spy.statement_end_offset,
				spy.sql_handle,
				spy.host_name,
				spy.login_name,
				spy.program_name,
				spy.database_id,
				spy.memory_usage,
				spy.open_tran_count,
				' +
				CASE
					WHEN 
					(
						@get_task_info <> 0  
						OR @find_block_leaders = 1 
					) THEN
						'spy.wait_type,
						CASE
							WHEN
								spy.wait_type LIKE N''PAGE%LATCH_%''
								OR spy.wait_type = N''CXPACKET''
								OR spy.wait_type LIKE N''LATCH[_]%''
								OR spy.wait_type = N''OLEDB'' THEN
									spy.wait_resource
							ELSE
								NULL
						END AS wait_resource,
						spy.wait_time, 
						'
					ELSE
						''
				END +
				'spy.blocked,
				spy.is_user_process,
				spy.cmd
			FROM
			(
				SELECT TOP(@i)
					spx.*, 
					' +
					CASE
						WHEN 
						(
							@get_task_info <> 0 
							OR @find_block_leaders = 1 
						) THEN
							'ROW_NUMBER() OVER
							(
								PARTITION BY
									spx.session_id,
									spx.request_id
								ORDER BY
									CASE
										WHEN spx.wait_type LIKE N''LCK[_]%'' THEN 
											1
										ELSE
											99
									END,
									spx.wait_time DESC,
									spx.blocked DESC
							) AS r 
							'
						ELSE 
							'1 AS r 
							'
					END +
				'FROM
				(
					SELECT TOP(@i)
						sp0.session_id,
						sp0.request_id,
						sp0.login_time,
						sp0.last_request_end_time,
						LOWER(sp0.status) AS status,
						CASE
							WHEN sp0.cmd = ''CREATE INDEX'' THEN
								0
							ELSE
								sp0.stmt_start
						END AS statement_start_offset,
						CASE
							WHEN sp0.cmd = N''CREATE INDEX'' THEN
								-1
							ELSE
								COALESCE(NULLIF(sp0.stmt_end, 0), -1)
						END AS statement_end_offset,
						sp0.sql_handle,
						sp0.host_name,
						sp0.login_name,
						sp0.program_name,
						sp0.database_id,
						sp0.memory_usage,
						sp0.open_tran_count, 
						' +
						CASE
							WHEN 
							(
								@get_task_info <> 0 
								OR @find_block_leaders = 1 
							) THEN
								'CASE
									WHEN sp0.wait_time > 0 AND sp0.wait_type <> N''CXPACKET'' THEN
										sp0.wait_type
									ELSE
										NULL
								END AS wait_type,
								CASE
									WHEN sp0.wait_time > 0 AND sp0.wait_type <> N''CXPACKET'' THEN 
										sp0.wait_resource
									ELSE
										NULL
								END AS wait_resource,
								CASE
									WHEN sp0.wait_type <> N''CXPACKET'' THEN
										sp0.wait_time
									ELSE
										0
								END AS wait_time, 
								'
							ELSE
								''
						END +
						'sp0.blocked,
						sp0.is_user_process,
						sp0.cmd
					FROM
					(
						SELECT TOP(@i)
							sp1.session_id,
							sp1.request_id,
							sp1.login_time,
							sp1.last_request_end_time,
							sp1.status,
							sp1.cmd,
							sp1.stmt_start,
							sp1.stmt_end,
							MAX(NULLIF(sp1.sql_handle, 0x00)) OVER (PARTITION BY sp1.session_id, sp1.request_id) AS sql_handle,
							sp1.host_name,
							MAX(sp1.login_name) OVER (PARTITION BY sp1.session_id, sp1.request_id) AS login_name,
							sp1.program_name,
							sp1.database_id,
							MAX(sp1.memory_usage)  OVER (PARTITION BY sp1.session_id, sp1.request_id) AS memory_usage,
							MAX(sp1.open_tran_count)  OVER (PARTITION BY sp1.session_id, sp1.request_id) AS open_tran_count,
							sp1.wait_type,
							sp1.wait_resource,
							sp1.wait_time,
							sp1.blocked,
							sp1.hostprocess,
							sp1.is_user_process
						FROM
						(
							SELECT TOP(@i)
								sp2.spid AS session_id,
								CASE sp2.status
									WHEN ''sleeping'' THEN
										CONVERT(INT, 0)
									ELSE
										sp2.request_id
								END AS request_id,
								MAX(sp2.login_time) AS login_time,
								MAX(sp2.last_batch) AS last_request_end_time,
								MAX(CONVERT(VARCHAR(30), RTRIM(sp2.status)) COLLATE Latin1_General_Bin2) AS status,
								MAX(CONVERT(VARCHAR(32), RTRIM(sp2.cmd)) COLLATE Latin1_General_Bin2) AS cmd,
								MAX(sp2.stmt_start) AS stmt_start,
								MAX(sp2.stmt_end) AS stmt_end,
								MAX(sp2.sql_handle) AS sql_handle,
								MAX(CONVERT(sysname, RTRIM(sp2.hostname)) COLLATE SQL_Latin1_General_CP1_CI_AS) AS host_name,
								MAX(CONVERT(sysname, RTRIM(sp2.loginame)) COLLATE SQL_Latin1_General_CP1_CI_AS) AS login_name,
								MAX
								(
									CASE
										WHEN blk.queue_id IS NOT NULL THEN
											N''Service Broker
												database_id: '' + CONVERT(NVARCHAR, blk.database_id) +
												N'' queue_id: '' + CONVERT(NVARCHAR, blk.queue_id)
										ELSE
											CONVERT
											(
												sysname,
												RTRIM(sp2.program_name)
											)
									END COLLATE SQL_Latin1_General_CP1_CI_AS
								) AS program_name,
								MAX(sp2.dbid) AS database_id,
								MAX(sp2.memusage) AS memory_usage,
								MAX(sp2.open_tran) AS open_tran_count,
								RTRIM(sp2.lastwaittype) AS wait_type,
								RTRIM(sp2.waitresource) AS wait_resource,
								MAX(sp2.waittime) AS wait_time,
								COALESCE(NULLIF(sp2.blocked, sp2.spid), 0) AS blocked,
								MAX
								(
									CASE
										WHEN blk.session_id = sp2.spid THEN
											''blocker''
										ELSE
											RTRIM(sp2.hostprocess)
									END
								) AS hostprocess,
								CONVERT
								(
									BIT,
									MAX
									(
										CASE
											WHEN sp2.hostprocess > '''' THEN
												1
											ELSE
												0
										END
									)
								) AS is_user_process
							FROM
							(
								SELECT TOP(@i)
									session_id,
									CONVERT(INT, NULL) AS queue_id,
									CONVERT(INT, NULL) AS database_id
								FROM @blockers

								UNION ALL

								SELECT TOP(@i)
									CONVERT(SMALLINT, 0),
									CONVERT(INT, NULL) AS queue_id,
									CONVERT(INT, NULL) AS database_id
								WHERE
									@blocker = 0

								UNION ALL

								SELECT TOP(@i)
									CONVERT(SMALLINT, spid),
									queue_id,
									database_id
								FROM sys.dm_broker_activated_tasks
								WHERE
									@blocker = 0
							) AS blk
							INNER JOIN sys.sysprocesses AS sp2 ON
								sp2.spid = blk.session_id
								OR
								(
									blk.session_id = 0
									AND @blocker = 0
								)
							' +
							CASE 
								WHEN 
								(
									@get_task_info = 0 
									AND @find_block_leaders = 0
								) THEN
									'WHERE
										sp2.ecid = 0 
									' 
								ELSE
									''
							END +
							'GROUP BY
								sp2.spid,
								CASE sp2.status
									WHEN ''sleeping'' THEN
										CONVERT(INT, 0)
									ELSE
										sp2.request_id
								END,
								RTRIM(sp2.lastwaittype),
								RTRIM(sp2.waitresource),
								COALESCE(NULLIF(sp2.blocked, sp2.spid), 0)
						) AS sp1
					) AS sp0
					WHERE
						@blocker = 1
						OR
						(1=1 
						' +
							--inclusive filter
							CASE
								WHEN @filter <> '' THEN
									CASE @filter_type
										WHEN 'session' THEN
											CASE
												WHEN CONVERT(SMALLINT, @filter) <> 0 THEN
													'AND sp0.session_id = CONVERT(SMALLINT, @filter) 
													'
												ELSE
													''
											END
										WHEN 'program' THEN
											'AND sp0.program_name LIKE @filter 
											'
										WHEN 'login' THEN
											'AND sp0.login_name LIKE @filter 
											'
										WHEN 'host' THEN
											'AND sp0.host_name LIKE @filter 
											'
										WHEN 'database' THEN
											'AND DB_NAME(sp0.database_id) LIKE @filter 
											'
										ELSE
											''
									END
								ELSE
									''
							END +
							--exclusive filter
							CASE
								WHEN @not_filter <> '' THEN
									CASE @not_filter_type
										WHEN 'session' THEN
											CASE
												WHEN CONVERT(SMALLINT, @not_filter) <> 0 THEN
													'AND sp0.session_id <> CONVERT(SMALLINT, @not_filter) 
													'
												ELSE
													''
											END
										WHEN 'program' THEN
											'AND sp0.program_name NOT LIKE @not_filter 
											'
										WHEN 'login' THEN
											'AND sp0.login_name NOT LIKE @not_filter 
											'
										WHEN 'host' THEN
											'AND sp0.host_name NOT LIKE @not_filter 
											'
										WHEN 'database' THEN
											'AND DB_NAME(sp0.database_id) NOT LIKE @not_filter 
											'
										ELSE
											''
									END
								ELSE
									''
							END +
							CASE @show_own_spid
								WHEN 1 THEN
									''
								ELSE
									'AND sp0.session_id <> @@spid 
									'
							END +
							CASE 
								WHEN @show_system_spids = 0 THEN
									'AND sp0.hostprocess > '''' 
									' 
								ELSE
									''
							END +
							CASE @show_sleeping_spids
								WHEN 0 THEN
									'AND sp0.status <> ''sleeping'' 
									'
								WHEN 1 THEN
									'AND
									(
										sp0.status <> ''sleeping''
										OR sp0.open_tran_count > 0
									)
									'
								ELSE
									''
							END +
						')
				) AS spx
			) AS spy
			WHERE
				spy.r = 1; 
			' + 
			CASE @recursion
				WHEN 1 THEN 
					'IF @@ROWCOUNT > 0
					BEGIN;
						INSERT @blockers
						(
							session_id
						)
						SELECT TOP(@i)
							blocked
						FROM @sessions
						WHERE
							NULLIF(blocked, 0) IS NOT NULL

						EXCEPT

						SELECT TOP(@i)
							session_id
						FROM @sessions; 
						' +

						CASE
							WHEN
							(
								@get_task_info > 0
								OR @find_block_leaders = 1
							) THEN
								'IF @@ROWCOUNT > 0
								BEGIN;
									SET @blocker = 1;
									GOTO BLOCKERS;
								END; 
								'
							ELSE 
								''
						END +
					'END; 
					'
				ELSE 
					''
			END +
			'SELECT TOP(@i)
				@recursion AS recursion,
				x.session_id,
				x.request_id,
				DENSE_RANK() OVER
				(
					ORDER BY
						x.session_id
				) AS session_number,
				' +
				CASE
					WHEN @output_column_list LIKE '%|[dd hh:mm:ss.mss|]%' ESCAPE '|' THEN 
						'x.elapsed_time '
					ELSE 
						'0 '
				END + 
					'AS elapsed_time, 
					' +
				CASE
					WHEN
						(
							@output_column_list LIKE '%|[dd hh:mm:ss.mss (avg)|]%' ESCAPE '|' OR 
							@output_column_list LIKE '%|[avg_elapsed_time|]%' ESCAPE '|'
						)
						AND @recursion = 1
							THEN 
								'x.avg_elapsed_time / 1000 '
					ELSE 
						'NULL '
				END + 
					'AS avg_elapsed_time, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[physical_io|]%' ESCAPE '|'
						OR @output_column_list LIKE '%|[physical_io_delta|]%' ESCAPE '|'
							THEN 
								'x.physical_io '
					ELSE 
						'NULL '
				END + 
					'AS physical_io, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[reads|]%' ESCAPE '|'
						OR @output_column_list LIKE '%|[reads_delta|]%' ESCAPE '|'
							THEN 
								'x.reads '
					ELSE 
						'0 '
				END + 
					'AS reads, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[physical_reads|]%' ESCAPE '|'
						OR @output_column_list LIKE '%|[physical_reads_delta|]%' ESCAPE '|'
							THEN 
								'x.physical_reads '
					ELSE 
						'0 '
				END + 
					'AS physical_reads, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[writes|]%' ESCAPE '|'
						OR @output_column_list LIKE '%|[writes_delta|]%' ESCAPE '|'
							THEN 
								'x.writes '
					ELSE 
						'0 '
				END + 
					'AS writes, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[tempdb_allocations|]%' ESCAPE '|'
						OR @output_column_list LIKE '%|[tempdb_allocations_delta|]%' ESCAPE '|'
							THEN 
								'x.tempdb_allocations '
					ELSE 
						'0 '
				END + 
					'AS tempdb_allocations, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[tempdb_current|]%' ESCAPE '|'
						OR @output_column_list LIKE '%|[tempdb_current_delta|]%' ESCAPE '|'
							THEN 
								'x.tempdb_current '
					ELSE 
						'0 '
				END + 
					'AS tempdb_current, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[CPU|]%' ESCAPE '|'
						OR @output_column_list LIKE '%|[CPU_delta|]%' ESCAPE '|'
							THEN
								'x.CPU '
					ELSE
						'0 '
				END + 
					'AS CPU, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[CPU_delta|]%' ESCAPE '|'
						AND @get_task_info = 2
							THEN 
								'x.thread_CPU_snapshot '
					ELSE 
						'0 '
				END + 
					'AS thread_CPU_snapshot, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[context_switches|]%' ESCAPE '|'
						OR @output_column_list LIKE '%|[context_switches_delta|]%' ESCAPE '|'
							THEN 
								'x.context_switches '
					ELSE 
						'NULL '
				END + 
					'AS context_switches, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[used_memory|]%' ESCAPE '|'
						OR @output_column_list LIKE '%|[used_memory_delta|]%' ESCAPE '|'
							THEN 
								'x.used_memory '
					ELSE 
						'0 '
				END + 
					'AS used_memory, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[tasks|]%' ESCAPE '|'
						AND @recursion = 1
							THEN 
								'x.tasks '
					ELSE 
						'NULL '
				END + 
					'AS tasks, 
					' +
				CASE
					WHEN 
						(
							@output_column_list LIKE '%|[status|]%' ESCAPE '|' 
							OR @output_column_list LIKE '%|[sql_command|]%' ESCAPE '|'
						)
						AND @recursion = 1
							THEN 
								'x.status '
					ELSE 
						''''' '
				END + 
					'AS status, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[wait_info|]%' ESCAPE '|' 
						AND @recursion = 1
							THEN 
								CASE @get_task_info
									WHEN 2 THEN
										'COALESCE(x.task_wait_info, x.sys_wait_info) '
									ELSE
										'x.sys_wait_info '
								END
					ELSE 
						'NULL '
				END + 
					'AS wait_info, 
					' +
				CASE
					WHEN 
						(
							@output_column_list LIKE '%|[tran_start_time|]%' ESCAPE '|' 
							OR @output_column_list LIKE '%|[tran_log_writes|]%' ESCAPE '|' 
						)
						AND @recursion = 1
							THEN 
								'x.transaction_id '
					ELSE 
						'NULL '
				END + 
					'AS transaction_id, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[open_tran_count|]%' ESCAPE '|' 
						AND @recursion = 1
							THEN 
								'x.open_tran_count '
					ELSE 
						'NULL '
				END + 
					'AS open_tran_count, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[sql_text|]%' ESCAPE '|' 
						AND @recursion = 1
							THEN 
								'x.sql_handle '
					ELSE 
						'NULL '
				END + 
					'AS sql_handle, 
					' +
				CASE
					WHEN 
						(
							@output_column_list LIKE '%|[sql_text|]%' ESCAPE '|' 
							OR @output_column_list LIKE '%|[query_plan|]%' ESCAPE '|' 
						)
						AND @recursion = 1
							THEN 
								'x.statement_start_offset '
					ELSE 
						'NULL '
				END + 
					'AS statement_start_offset, 
					' +
				CASE
					WHEN 
						(
							@output_column_list LIKE '%|[sql_text|]%' ESCAPE '|' 
							OR @output_column_list LIKE '%|[query_plan|]%' ESCAPE '|' 
						)
						AND @recursion = 1
							THEN 
								'x.statement_end_offset '
					ELSE 
						'NULL '
				END + 
					'AS statement_end_offset, 
					' +
				'NULL AS sql_text, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[query_plan|]%' ESCAPE '|' 
						AND @recursion = 1
							THEN 
								'x.plan_handle '
					ELSE 
						'NULL '
				END + 
					'AS plan_handle, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[blocking_session_id|]%' ESCAPE '|' 
						AND @recursion = 1
							THEN 
								'NULLIF(x.blocking_session_id, 0) '
					ELSE 
						'NULL '
				END + 
					'AS blocking_session_id, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[percent_complete|]%' ESCAPE '|'
						AND @recursion = 1
							THEN 
								'x.percent_complete '
					ELSE 
						'NULL '
				END + 
					'AS percent_complete, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[host_name|]%' ESCAPE '|' 
						AND @recursion = 1
							THEN 
								'x.host_name '
					ELSE 
						''''' '
				END + 
					'AS host_name, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[login_name|]%' ESCAPE '|' 
						AND @recursion = 1
							THEN 
								'x.login_name '
					ELSE 
						''''' '
				END + 
					'AS login_name, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[database_name|]%' ESCAPE '|' 
						AND @recursion = 1
							THEN 
								'DB_NAME(x.database_id) '
					ELSE 
						'NULL '
				END + 
					'AS database_name, 
					' +
				CASE
					WHEN 
						@output_column_list LIKE '%|[program_name|]%' ESCAPE '|' 
						AND @recursion = 1
							THEN 
								'x.program_name '
					ELSE 
						''''' '
				END + 
					'AS program_name, 
					' +
				CASE
					WHEN
						@output_column_list LIKE '%|[additional_info|]%' ESCAPE '|'
						AND @recursion = 1
							THEN
								'(
									SELECT TOP(@i)
										x.text_size,
										x.language,
										x.date_format,
										x.date_first,
										CASE x.quoted_identifier
											WHEN 0 THEN ''OFF''
											WHEN 1 THEN ''ON''
										END AS quoted_identifier,
										CASE x.arithabort
											WHEN 0 THEN ''OFF''
											WHEN 1 THEN ''ON''
										END AS arithabort,
										CASE x.ansi_null_dflt_on
											WHEN 0 THEN ''OFF''
											WHEN 1 THEN ''ON''
										END AS ansi_null_dflt_on,
										CASE x.ansi_defaults
											WHEN 0 THEN ''OFF''
											WHEN 1 THEN ''ON''
										END AS ansi_defaults,
										CASE x.ansi_warnings
											WHEN 0 THEN ''OFF''
											WHEN 1 THEN ''ON''
										END AS ansi_warnings,
										CASE x.ansi_padding
											WHEN 0 THEN ''OFF''
											WHEN 1 THEN ''ON''
										END AS ansi_padding,
										CASE ansi_nulls
											WHEN 0 THEN ''OFF''
											WHEN 1 THEN ''ON''
										END AS ansi_nulls,
										CASE x.concat_null_yields_null
											WHEN 0 THEN ''OFF''
											WHEN 1 THEN ''ON''
										END AS concat_null_yields_null,
										CASE x.transaction_isolation_level
											WHEN 0 THEN ''Unspecified''
											WHEN 1 THEN ''ReadUncomitted''
											WHEN 2 THEN ''ReadCommitted''
											WHEN 3 THEN ''Repeatable''
											WHEN 4 THEN ''Serializable''
											WHEN 5 THEN ''Snapshot''
										END AS transaction_isolation_level,
										x.lock_timeout,
										x.deadlock_priority,
										x.row_count,
										x.command_type, 
										master.dbo.fn_varbintohexstr(x.sql_handle) AS sql_handle,
										master.dbo.fn_varbintohexstr(x.plan_handle) AS plan_handle,
										' +
										CASE
											WHEN @output_column_list LIKE '%|[program_name|]%' ESCAPE '|' THEN
												'(
													SELECT TOP(1)
														CONVERT(uniqueidentifier, CONVERT(XML, '''').value(''xs:hexBinary( substring(sql:column("agent_info.job_id_string"), 0) )'', ''binary(16)'')) AS job_id,
														agent_info.step_id,
														(
															SELECT TOP(1)
																NULL
															FOR XML
																PATH(''job_name''),
																TYPE
														),
														(
															SELECT TOP(1)
																NULL
															FOR XML
																PATH(''step_name''),
																TYPE
														)
													FROM
													(
														SELECT TOP(1)
															SUBSTRING(x.program_name, CHARINDEX(''0x'', x.program_name) + 2, 32) AS job_id_string,
															SUBSTRING(x.program_name, CHARINDEX('': Step '', x.program_name) + 7, CHARINDEX('')'', x.program_name, CHARINDEX('': Step '', x.program_name)) - (CHARINDEX('': Step '', x.program_name) + 7)) AS step_id
														WHERE
															x.program_name LIKE N''SQLAgent - TSQL JobStep (Job 0x%''
													) AS agent_info
													FOR XML
														PATH(''agent_job_info''),
														TYPE
												),
												'
											ELSE ''
										END +
										CASE
											WHEN @get_task_info = 2 THEN
												'CONVERT(XML, x.block_info) AS block_info, 
												'
											ELSE
												''
										END +
										'x.host_process_id 
									FOR XML
										PATH(''additional_info''),
										TYPE
								) '
					ELSE
						'NULL '
				END + 
					'AS additional_info, 
				x.start_time, 
					' +
				CASE
					WHEN
						@output_column_list LIKE '%|[login_time|]%' ESCAPE '|'
						AND @recursion = 1
							THEN
								'x.login_time '
					ELSE 
						'NULL '
				END + 
					'AS login_time, 
				x.last_request_start_time
			FROM
			(
				SELECT TOP(@i)
					y.*,
					CASE
						WHEN DATEDIFF(hour, y.start_time, GETDATE()) > 576 THEN
							DATEDIFF(second, GETDATE(), y.start_time)
						ELSE DATEDIFF(ms, y.start_time, GETDATE())
					END AS elapsed_time,
					COALESCE(tempdb_info.tempdb_allocations, 0) AS tempdb_allocations,
					COALESCE
					(
						CASE
							WHEN tempdb_info.tempdb_current < 0 THEN 0
							ELSE tempdb_info.tempdb_current
						END,
						0
					) AS tempdb_current, 
					' +
					CASE
						WHEN 
							(
								@get_task_info <> 0
								OR @find_block_leaders = 1
							) THEN
								'N''('' + CONVERT(NVARCHAR, y.wait_duration_ms) + N''ms)'' +
									y.wait_type +
										CASE
											WHEN y.wait_type LIKE N''PAGE%LATCH_%'' THEN
												N'':'' +
												COALESCE(DB_NAME(CONVERT(INT, LEFT(y.resource_description, CHARINDEX(N'':'', y.resource_description) - 1))), N''(null)'') +
												N'':'' +
												SUBSTRING(y.resource_description, CHARINDEX(N'':'', y.resource_description) + 1, LEN(y.resource_description) - CHARINDEX(N'':'', REVERSE(y.resource_description)) - CHARINDEX(N'':'', y.resource_description)) +
												N''('' +
													CASE
														WHEN
															CONVERT(INT, RIGHT(y.resource_description, CHARINDEX(N'':'', REVERSE(y.resource_description)) - 1)) = 1 OR
															CONVERT(INT, RIGHT(y.resource_description, CHARINDEX(N'':'', REVERSE(y.resource_description)) - 1)) % 8088 = 0
																THEN 
																	N''PFS''
														WHEN
															CONVERT(INT, RIGHT(y.resource_description, CHARINDEX(N'':'', REVERSE(y.resource_description)) - 1)) = 2 OR
															CONVERT(INT, RIGHT(y.resource_description, CHARINDEX(N'':'', REVERSE(y.resource_description)) - 1)) % 511232 = 0
																THEN 
																	N''GAM''
														WHEN
															CONVERT(INT, RIGHT(y.resource_description, CHARINDEX(N'':'', REVERSE(y.resource_description)) - 1)) = 3 OR
															(CONVERT(INT, RIGHT(y.resource_description, CHARINDEX(N'':'', REVERSE(y.resource_description)) - 1)) - 1) % 511232 = 0
																THEN
																	N''SGAM''
														WHEN
															CONVERT(INT, RIGHT(y.resource_description, CHARINDEX(N'':'', REVERSE(y.resource_description)) - 1)) = 6 OR
															(CONVERT(INT, RIGHT(y.resource_description, CHARINDEX(N'':'', REVERSE(y.resource_description)) - 1)) - 6) % 511232 = 0 
																THEN 
																	N''DCM''
														WHEN
															CONVERT(INT, RIGHT(y.resource_description, CHARINDEX(N'':'', REVERSE(y.resource_description)) - 1)) = 7 OR
															(CONVERT(INT, RIGHT(y.resource_description, CHARINDEX(N'':'', REVERSE(y.resource_description)) - 1)) - 7) % 511232 = 0 
																THEN 
																	N''BCM''
														ELSE 
															N''*''
													END +
												N'')''
											WHEN y.wait_type = N''CXPACKET'' THEN
												N'':'' + SUBSTRING(y.resource_description, CHARINDEX(N''nodeId'', y.resource_description) + 7, 4)
											WHEN y.wait_type LIKE N''LATCH[_]%'' THEN
												N'' ['' + LEFT(y.resource_description, COALESCE(NULLIF(CHARINDEX(N'' '', y.resource_description), 0), LEN(y.resource_description) + 1) - 1) + N'']''
											WHEN
												y.wait_type = N''OLEDB''
												AND y.resource_description LIKE N''%(SPID=%)'' THEN
													N''['' + LEFT(y.resource_description, CHARINDEX(N''(SPID='', y.resource_description) - 2) +
														N'':'' + SUBSTRING(y.resource_description, CHARINDEX(N''(SPID='', y.resource_description) + 6, CHARINDEX(N'')'', y.resource_description, (CHARINDEX(N''(SPID='', y.resource_description) + 6)) - (CHARINDEX(N''(SPID='', y.resource_description) + 6)) + '']''
											ELSE
												N''''
										END COLLATE Latin1_General_Bin2 AS sys_wait_info, 
										'
							ELSE
								''
						END +
						CASE
							WHEN @get_task_info = 2 THEN
								'tasks.physical_io,
								tasks.context_switches,
								tasks.tasks,
								tasks.block_info,
								tasks.wait_info AS task_wait_info,
								tasks.thread_CPU_snapshot,
								'
							ELSE
								'' 
					END +
					CASE 
						WHEN NOT (@get_avg_time = 1 AND @recursion = 1) THEN
							'CONVERT(INT, NULL) '
						ELSE 
							'qs.total_elapsed_time / qs.execution_count '
					END + 
						'AS avg_elapsed_time 
				FROM
				(
					SELECT TOP(@i)
						sp.session_id,
						sp.request_id,
						COALESCE(r.logical_reads, s.logical_reads) AS reads,
						COALESCE(r.reads, s.reads) AS physical_reads,
						COALESCE(r.writes, s.writes) AS writes,
						COALESCE(r.CPU_time, s.CPU_time) AS CPU,
						sp.memory_usage + COALESCE(r.granted_query_memory, 0) AS used_memory,
						LOWER(sp.status) AS status,
						COALESCE(r.sql_handle, sp.sql_handle) AS sql_handle,
						COALESCE(r.statement_start_offset, sp.statement_start_offset) AS statement_start_offset,
						COALESCE(r.statement_end_offset, sp.statement_end_offset) AS statement_end_offset,
						' +
						CASE
							WHEN 
							(
								@get_task_info <> 0
								OR @find_block_leaders = 1 
							) THEN
								'sp.wait_type COLLATE Latin1_General_Bin2 AS wait_type,
								sp.wait_resource COLLATE Latin1_General_Bin2 AS resource_description,
								sp.wait_time AS wait_duration_ms, 
								'
							ELSE
								''
						END +
						'NULLIF(sp.blocked, 0) AS blocking_session_id,
						r.plan_handle,
						NULLIF(r.percent_complete, 0) AS percent_complete,
						sp.host_name,
						sp.login_name,
						sp.program_name,
						s.host_process_id,
						COALESCE(r.text_size, s.text_size) AS text_size,
						COALESCE(r.language, s.language) AS language,
						COALESCE(r.date_format, s.date_format) AS date_format,
						COALESCE(r.date_first, s.date_first) AS date_first,
						COALESCE(r.quoted_identifier, s.quoted_identifier) AS quoted_identifier,
						COALESCE(r.arithabort, s.arithabort) AS arithabort,
						COALESCE(r.ansi_null_dflt_on, s.ansi_null_dflt_on) AS ansi_null_dflt_on,
						COALESCE(r.ansi_defaults, s.ansi_defaults) AS ansi_defaults,
						COALESCE(r.ansi_warnings, s.ansi_warnings) AS ansi_warnings,
						COALESCE(r.ansi_padding, s.ansi_padding) AS ansi_padding,
						COALESCE(r.ansi_nulls, s.ansi_nulls) AS ansi_nulls,
						COALESCE(r.concat_null_yields_null, s.concat_null_yields_null) AS concat_null_yields_null,
						COALESCE(r.transaction_isolation_level, s.transaction_isolation_level) AS transaction_isolation_level,
						COALESCE(r.lock_timeout, s.lock_timeout) AS lock_timeout,
						COALESCE(r.deadlock_priority, s.deadlock_priority) AS deadlock_priority,
						COALESCE(r.row_count, s.row_count) AS row_count,
						COALESCE(r.command, sp.cmd) AS command_type,
						COALESCE
						(
							CASE
								WHEN
								(
									s.is_user_process = 0
									AND r.total_elapsed_time >= 0
								) THEN
									DATEADD
									(
										ms,
										1000 * (DATEPART(ms, DATEADD(second, -(r.total_elapsed_time / 1000), GETDATE())) / 500) - DATEPART(ms, DATEADD(second, -(r.total_elapsed_time / 1000), GETDATE())),
										DATEADD(second, -(r.total_elapsed_time / 1000), GETDATE())
									)
							END,
							NULLIF(COALESCE(r.start_time, sp.last_request_end_time), CONVERT(DATETIME, ''19000101'', 112)),
							(
								SELECT TOP(1)
									DATEADD(second, -(ms_ticks / 1000), GETDATE())
								FROM sys.dm_os_sys_info
							)
						) AS start_time,
						sp.login_time,
						CASE
							WHEN s.is_user_process = 1 THEN
								s.last_request_start_time
							ELSE
								COALESCE
								(
									DATEADD
									(
										ms,
										1000 * (DATEPART(ms, DATEADD(second, -(r.total_elapsed_time / 1000), GETDATE())) / 500) - DATEPART(ms, DATEADD(second, -(r.total_elapsed_time / 1000), GETDATE())),
										DATEADD(second, -(r.total_elapsed_time / 1000), GETDATE())
									),
									s.last_request_start_time
								)
						END AS last_request_start_time,
						r.transaction_id,
						sp.database_id,
						sp.open_tran_count
					FROM @sessions AS sp
					LEFT OUTER LOOP JOIN sys.dm_exec_sessions AS s ON
						s.session_id = sp.session_id
						AND s.login_time = sp.login_time
					LEFT OUTER LOOP JOIN sys.dm_exec_requests AS r ON
						sp.status <> ''sleeping''
						AND r.session_id = sp.session_id
						AND r.request_id = sp.request_id
						AND
						(
							(
								s.is_user_process = 0
								AND sp.is_user_process = 0
							)
							OR
							(
								r.start_time = s.last_request_start_time
								AND s.last_request_end_time <= sp.last_request_end_time
							)
						)
				) AS y
				' + 
				CASE 
					WHEN @get_task_info = 2 THEN
						CONVERT(VARCHAR(MAX), '') +
						'LEFT OUTER HASH JOIN
						(
							SELECT TOP(@i)
								task_nodes.task_node.value(''(session_id/text())[1]'', ''SMALLINT'') AS session_id,
								task_nodes.task_node.value(''(request_id/text())[1]'', ''INT'') AS request_id,
								task_nodes.task_node.value(''(physical_io/text())[1]'', ''BIGINT'') AS physical_io,
								task_nodes.task_node.value(''(context_switches/text())[1]'', ''BIGINT'') AS context_switches,
								task_nodes.task_node.value(''(tasks/text())[1]'', ''INT'') AS tasks,
								task_nodes.task_node.value(''(block_info/text())[1]'', ''NVARCHAR(4000)'') AS block_info,
								task_nodes.task_node.value(''(waits/text())[1]'', ''NVARCHAR(4000)'') AS wait_info,
								task_nodes.task_node.value(''(thread_CPU_snapshot/text())[1]'', ''BIGINT'') AS thread_CPU_snapshot
							FROM
							(
								SELECT TOP(@i)
									CONVERT
									(
										XML,
										REPLACE
										(
											CONVERT(NVARCHAR(MAX), tasks_raw.task_xml_raw) COLLATE Latin1_General_Bin2,
											N''</waits></tasks><tasks><waits>'',
											N'', ''
										)
									) AS task_xml
								FROM
								(
									SELECT TOP(@i)
										CASE waits.r
											WHEN 1 THEN
												waits.session_id
											ELSE
												NULL
										END AS [session_id],
										CASE waits.r
											WHEN 1 THEN
												waits.request_id
											ELSE
												NULL
										END AS [request_id],											
										CASE waits.r
											WHEN 1 THEN
												waits.physical_io
											ELSE
												NULL
										END AS [physical_io],
										CASE waits.r
											WHEN 1 THEN
												waits.context_switches
											ELSE
												NULL
										END AS [context_switches],
										CASE waits.r
											WHEN 1 THEN
												waits.thread_CPU_snapshot
											ELSE
												NULL
										END AS [thread_CPU_snapshot],
										CASE waits.r
											WHEN 1 THEN
												waits.tasks
											ELSE
												NULL
										END AS [tasks],
										CASE waits.r
											WHEN 1 THEN
												waits.block_info
											ELSE
												NULL
										END AS [block_info],
										REPLACE
										(
											REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
											REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
											REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
												CONVERT
												(
													NVARCHAR(MAX),
													N''('' +
														CONVERT(NVARCHAR, num_waits) + N''x: '' +
														CASE num_waits
															WHEN 1 THEN
																CONVERT(NVARCHAR, min_wait_time) + N''ms''
															WHEN 2 THEN
																CASE
																	WHEN min_wait_time <> max_wait_time THEN
																		CONVERT(NVARCHAR, min_wait_time) + N''/'' + CONVERT(NVARCHAR, max_wait_time) + N''ms''
																	ELSE
																		CONVERT(NVARCHAR, max_wait_time) + N''ms''
																END
															ELSE
																CASE
																	WHEN min_wait_time <> max_wait_time THEN
																		CONVERT(NVARCHAR, min_wait_time) + N''/'' + CONVERT(NVARCHAR, avg_wait_time) + N''/'' + CONVERT(NVARCHAR, max_wait_time) + N''ms''
																	ELSE 
																		CONVERT(NVARCHAR, max_wait_time) + N''ms''
																END
														END +
													N'')'' + wait_type COLLATE Latin1_General_Bin2
												),
												NCHAR(31),N''?''),NCHAR(30),N''?''),NCHAR(29),N''?''),NCHAR(28),N''?''),NCHAR(27),N''?''),NCHAR(26),N''?''),NCHAR(25),N''?''),NCHAR(24),N''?''),NCHAR(23),N''?''),NCHAR(22),N''?''),
												NCHAR(21),N''?''),NCHAR(20),N''?''),NCHAR(19),N''?''),NCHAR(18),N''?''),NCHAR(17),N''?''),NCHAR(16),N''?''),NCHAR(15),N''?''),NCHAR(14),N''?''),NCHAR(12),N''?''),
												NCHAR(11),N''?''),NCHAR(8),N''?''),NCHAR(7),N''?''),NCHAR(6),N''?''),NCHAR(5),N''?''),NCHAR(4),N''?''),NCHAR(3),N''?''),NCHAR(2),N''?''),NCHAR(1),N''?''),
											NCHAR(0),
											N''''
										) AS [waits]
									FROM
									(
										SELECT TOP(@i)
											w1.*,
											ROW_NUMBER() OVER
											(
												PARTITION BY
													w1.session_id,
													w1.request_id
												ORDER BY
													w1.block_info DESC,
													w1.num_waits DESC,
													w1.wait_type
											) AS r
										FROM
										(
											SELECT TOP(@i)
												task_info.session_id,
												task_info.request_id,
												task_info.physical_io,
												task_info.context_switches,
												task_info.thread_CPU_snapshot,
												task_info.num_tasks AS tasks,
												CASE
													WHEN task_info.runnable_time IS NOT NULL THEN
														''RUNNABLE''
													ELSE
														wt2.wait_type
												END AS wait_type,
												NULLIF(COUNT(COALESCE(task_info.runnable_time, wt2.waiting_task_address)), 0) AS num_waits,
												MIN(COALESCE(task_info.runnable_time, wt2.wait_duration_ms)) AS min_wait_time,
												AVG(COALESCE(task_info.runnable_time, wt2.wait_duration_ms)) AS avg_wait_time,
												MAX(COALESCE(task_info.runnable_time, wt2.wait_duration_ms)) AS max_wait_time,
												MAX(wt2.block_info) AS block_info
											FROM
											(
												SELECT TOP(@i)
													t.session_id,
													t.request_id,
													SUM(CONVERT(BIGINT, t.pending_io_count)) OVER (PARTITION BY t.session_id, t.request_id) AS physical_io,
													SUM(CONVERT(BIGINT, t.context_switches_count)) OVER (PARTITION BY t.session_id, t.request_id) AS context_switches, 
													' +
													CASE
														WHEN @output_column_list LIKE '%|[CPU_delta|]%' ESCAPE '|'
															THEN
																'SUM(tr.usermode_time + tr.kernel_time) OVER (PARTITION BY t.session_id, t.request_id) '
														ELSE
															'CONVERT(BIGINT, NULL) '
													END + 
														' AS thread_CPU_snapshot, 
													COUNT(*) OVER (PARTITION BY t.session_id, t.request_id) AS num_tasks,
													t.task_address,
													t.task_state,
													CASE
														WHEN
															t.task_state = ''RUNNABLE''
															AND w.runnable_time > 0 THEN
																w.runnable_time
														ELSE
															NULL
													END AS runnable_time
												FROM sys.dm_os_tasks AS t
												CROSS APPLY
												(
													SELECT TOP(1)
														sp2.session_id
													FROM @sessions AS sp2
													WHERE
														sp2.session_id = t.session_id
														AND sp2.request_id = t.request_id
														AND sp2.status <> ''sleeping''
												) AS sp20
												LEFT OUTER HASH JOIN
												(
													SELECT TOP(@i)
														(
															SELECT TOP(@i)
																ms_ticks
															FROM sys.dm_os_sys_info
														) -
															w0.wait_resumed_ms_ticks AS runnable_time,
														w0.worker_address,
														w0.thread_address,
														w0.task_bound_ms_ticks
													FROM sys.dm_os_workers AS w0
													WHERE
														w0.state = ''RUNNABLE''
														OR @first_collection_ms_ticks >= w0.task_bound_ms_ticks
												) AS w ON
													w.worker_address = t.worker_address 
												' +
												CASE
													WHEN @output_column_list LIKE '%|[CPU_delta|]%' ESCAPE '|'
														THEN
															'LEFT OUTER HASH JOIN sys.dm_os_threads AS tr ON
																tr.thread_address = w.thread_address
																AND @first_collection_ms_ticks >= w.task_bound_ms_ticks
															'
													ELSE
														''
												END +
											') AS task_info
											LEFT OUTER HASH JOIN
											(
												SELECT TOP(@i)
													wt1.wait_type,
													wt1.waiting_task_address,
													MAX(wt1.wait_duration_ms) AS wait_duration_ms,
													MAX(wt1.block_info) AS block_info
												FROM
												(
													SELECT DISTINCT TOP(@i)
														wt.wait_type +
															CASE
																WHEN wt.wait_type LIKE N''PAGE%LATCH_%'' THEN
																	'':'' +
																	COALESCE(DB_NAME(CONVERT(INT, LEFT(wt.resource_description, CHARINDEX(N'':'', wt.resource_description) - 1))), N''(null)'') +
																	N'':'' +
																	SUBSTRING(wt.resource_description, CHARINDEX(N'':'', wt.resource_description) + 1, LEN(wt.resource_description) - CHARINDEX(N'':'', REVERSE(wt.resource_description)) - CHARINDEX(N'':'', wt.resource_description)) +
																	N''('' +
																		CASE
																			WHEN
																				CONVERT(INT, RIGHT(wt.resource_description, CHARINDEX(N'':'', REVERSE(wt.resource_description)) - 1)) = 1 OR
																				CONVERT(INT, RIGHT(wt.resource_description, CHARINDEX(N'':'', REVERSE(wt.resource_description)) - 1)) % 8088 = 0
																					THEN 
																						N''PFS''
																			WHEN
																				CONVERT(INT, RIGHT(wt.resource_description, CHARINDEX(N'':'', REVERSE(wt.resource_description)) - 1)) = 2 OR
																				CONVERT(INT, RIGHT(wt.resource_description, CHARINDEX(N'':'', REVERSE(wt.resource_description)) - 1)) % 511232 = 0 
																					THEN 
																						N''GAM''
																			WHEN
																				CONVERT(INT, RIGHT(wt.resource_description, CHARINDEX(N'':'', REVERSE(wt.resource_description)) - 1)) = 3 OR
																				(CONVERT(INT, RIGHT(wt.resource_description, CHARINDEX(N'':'', REVERSE(wt.resource_description)) - 1)) - 1) % 511232 = 0 
																					THEN 
																						N''SGAM''
																			WHEN
																				CONVERT(INT, RIGHT(wt.resource_description, CHARINDEX(N'':'', REVERSE(wt.resource_description)) - 1)) = 6 OR
																				(CONVERT(INT, RIGHT(wt.resource_description, CHARINDEX(N'':'', REVERSE(wt.resource_description)) - 1)) - 6) % 511232 = 0 
																					THEN 
																						N''DCM''
																			WHEN
																				CONVERT(INT, RIGHT(wt.resource_description, CHARINDEX(N'':'', REVERSE(wt.resource_description)) - 1)) = 7 OR
																				(CONVERT(INT, RIGHT(wt.resource_description, CHARINDEX(N'':'', REVERSE(wt.resource_description)) - 1)) - 7) % 511232 = 0
																					THEN 
																						N''BCM''
																			ELSE
																				N''*''
																		END +
																	N'')''
																WHEN wt.wait_type = N''CXPACKET'' THEN
																	N'':'' + SUBSTRING(wt.resource_description, CHARINDEX(N''nodeId'', wt.resource_description) + 7, 4)
																WHEN wt.wait_type LIKE N''LATCH[_]%'' THEN
																	N'' ['' + LEFT(wt.resource_description, COALESCE(NULLIF(CHARINDEX(N'' '', wt.resource_description), 0), LEN(wt.resource_description) + 1) - 1) + N'']''
																ELSE 
																	N''''
															END COLLATE Latin1_General_Bin2 AS wait_type,
														CASE
															WHEN
															(
																wt.blocking_session_id IS NOT NULL
																AND wt.wait_type LIKE N''LCK[_]%''
															) THEN
																(
																	SELECT TOP(@i)
																		x.lock_type,
																		REPLACE
																		(
																			REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
																			REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
																			REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
																				DB_NAME
																				(
																					CONVERT
																					(
																						INT,
																						SUBSTRING(wt.resource_description, NULLIF(CHARINDEX(N''dbid='', wt.resource_description), 0) + 5, COALESCE(NULLIF(CHARINDEX(N'' '', wt.resource_description, CHARINDEX(N''dbid='', wt.resource_description) + 5), 0), LEN(wt.resource_description) + 1) - CHARINDEX(N''dbid='', wt.resource_description) - 5)
																					)
																				),
																				NCHAR(31),N''?''),NCHAR(30),N''?''),NCHAR(29),N''?''),NCHAR(28),N''?''),NCHAR(27),N''?''),NCHAR(26),N''?''),NCHAR(25),N''?''),NCHAR(24),N''?''),NCHAR(23),N''?''),NCHAR(22),N''?''),
																				NCHAR(21),N''?''),NCHAR(20),N''?''),NCHAR(19),N''?''),NCHAR(18),N''?''),NCHAR(17),N''?''),NCHAR(16),N''?''),NCHAR(15),N''?''),NCHAR(14),N''?''),NCHAR(12),N''?''),
																				NCHAR(11),N''?''),NCHAR(8),N''?''),NCHAR(7),N''?''),NCHAR(6),N''?''),NCHAR(5),N''?''),NCHAR(4),N''?''),NCHAR(3),N''?''),NCHAR(2),N''?''),NCHAR(1),N''?''),
																			NCHAR(0),
																			N''''
																		) AS database_name,
																		CASE x.lock_type
																			WHEN N''objectlock'' THEN
																				SUBSTRING(wt.resource_description, NULLIF(CHARINDEX(N''objid='', wt.resource_description), 0) + 6, COALESCE(NULLIF(CHARINDEX(N'' '', wt.resource_description, CHARINDEX(N''objid='', wt.resource_description) + 6), 0), LEN(wt.resource_description) + 1) - CHARINDEX(N''objid='', wt.resource_description) - 6)
																			ELSE
																				NULL
																		END AS object_id,
																		CASE x.lock_type
																			WHEN N''filelock'' THEN
																				SUBSTRING(wt.resource_description, NULLIF(CHARINDEX(N''fileid='', wt.resource_description), 0) + 7, COALESCE(NULLIF(CHARINDEX(N'' '', wt.resource_description, CHARINDEX(N''fileid='', wt.resource_description) + 7), 0), LEN(wt.resource_description) + 1) - CHARINDEX(N''fileid='', wt.resource_description) - 7)
																			ELSE
																				NULL
																		END AS file_id,
																		CASE
																			WHEN x.lock_type in (N''pagelock'', N''extentlock'', N''ridlock'') THEN
																				SUBSTRING(wt.resource_description, NULLIF(CHARINDEX(N''associatedObjectId='', wt.resource_description), 0) + 19, COALESCE(NULLIF(CHARINDEX(N'' '', wt.resource_description, CHARINDEX(N''associatedObjectId='', wt.resource_description) + 19), 0), LEN(wt.resource_description) + 1) - CHARINDEX(N''associatedObjectId='', wt.resource_description) - 19)
																			WHEN x.lock_type in (N''keylock'', N''hobtlock'', N''allocunitlock'') THEN
																				SUBSTRING(wt.resource_description, NULLIF(CHARINDEX(N''hobtid='', wt.resource_description), 0) + 7, COALESCE(NULLIF(CHARINDEX(N'' '', wt.resource_description, CHARINDEX(N''hobtid='', wt.resource_description) + 7), 0), LEN(wt.resource_description) + 1) - CHARINDEX(N''hobtid='', wt.resource_description) - 7)
																			ELSE
																				NULL
																		END AS hobt_id,
																		CASE x.lock_type
																			WHEN N''applicationlock'' THEN
																				SUBSTRING(wt.resource_description, NULLIF(CHARINDEX(N''hash='', wt.resource_description), 0) + 5, COALESCE(NULLIF(CHARINDEX(N'' '', wt.resource_description, CHARINDEX(N''hash='', wt.resource_description) + 5), 0), LEN(wt.resource_description) + 1) - CHARINDEX(N''hash='', wt.resource_description) - 5)
																			ELSE
																				NULL
																		END AS applock_hash,
																		CASE x.lock_type
																			WHEN N''metadatalock'' THEN
																				SUBSTRING(wt.resource_description, NULLIF(CHARINDEX(N''subresource='', wt.resource_description), 0) + 12, COALESCE(NULLIF(CHARINDEX(N'' '', wt.resource_description, CHARINDEX(N''subresource='', wt.resource_description) + 12), 0), LEN(wt.resource_description) + 1) - CHARINDEX(N''subresource='', wt.resource_description) - 12)
																			ELSE
																				NULL
																		END AS metadata_resource,
																		CASE x.lock_type
																			WHEN N''metadatalock'' THEN
																				SUBSTRING(wt.resource_description, NULLIF(CHARINDEX(N''classid='', wt.resource_description), 0) + 8, COALESCE(NULLIF(CHARINDEX(N'' dbid='', wt.resource_description) - CHARINDEX(N''classid='', wt.resource_description), 0), LEN(wt.resource_description) + 1) - 8)
																			ELSE
																				NULL
																		END AS metadata_class_id
																	FROM
																	(
																		SELECT TOP(1)
																			LEFT(wt.resource_description, CHARINDEX(N'' '', wt.resource_description) - 1) COLLATE Latin1_General_Bin2 AS lock_type
																	) AS x
																	FOR XML
																		PATH('''')
																)
															ELSE NULL
														END AS block_info,
														wt.wait_duration_ms,
														wt.waiting_task_address
													FROM
													(
														SELECT TOP(@i)
															wt0.wait_type COLLATE Latin1_General_Bin2 AS wait_type,
															wt0.resource_description COLLATE Latin1_General_Bin2 AS resource_description,
															wt0.wait_duration_ms,
															wt0.waiting_task_address,
															CASE
																WHEN wt0.blocking_session_id = p.blocked THEN
																	wt0.blocking_session_id
																ELSE
																	NULL
															END AS blocking_session_id
														FROM sys.dm_os_waiting_tasks AS wt0
														CROSS APPLY
														(
															SELECT TOP(1)
																s0.blocked
															FROM @sessions AS s0
															WHERE
																s0.session_id = wt0.session_id
																AND COALESCE(s0.wait_type, N'''') <> N''OLEDB''
																AND wt0.wait_type <> N''OLEDB''
														) AS p
													) AS wt
												) AS wt1
												GROUP BY
													wt1.wait_type,
													wt1.waiting_task_address
											) AS wt2 ON
												wt2.waiting_task_address = task_info.task_address
												AND wt2.wait_duration_ms > 0
												AND task_info.runnable_time IS NULL
											GROUP BY
												task_info.session_id,
												task_info.request_id,
												task_info.physical_io,
												task_info.context_switches,
												task_info.thread_CPU_snapshot,
												task_info.num_tasks,
												CASE
													WHEN task_info.runnable_time IS NOT NULL THEN
														''RUNNABLE''
													ELSE
														wt2.wait_type
												END
										) AS w1
									) AS waits
									ORDER BY
										waits.session_id,
										waits.request_id,
										waits.r
									FOR XML
										PATH(N''tasks''),
										TYPE
								) AS tasks_raw (task_xml_raw)
							) AS tasks_final
							CROSS APPLY tasks_final.task_xml.nodes(N''/tasks'') AS task_nodes (task_node)
							WHERE
								task_nodes.task_node.exist(N''session_id'') = 1
						) AS tasks ON
							tasks.session_id = y.session_id
							AND tasks.request_id = y.request_id 
						'
					ELSE
						''
				END +
				'LEFT OUTER HASH JOIN
				(
					SELECT TOP(@i)
						t_info.session_id,
						COALESCE(t_info.request_id, -1) AS request_id,
						SUM(t_info.tempdb_allocations) AS tempdb_allocations,
						SUM(t_info.tempdb_current) AS tempdb_current
					FROM
					(
						SELECT TOP(@i)
							tsu.session_id,
							tsu.request_id,
							tsu.user_objects_alloc_page_count +
								tsu.internal_objects_alloc_page_count AS tempdb_allocations,
							tsu.user_objects_alloc_page_count +
								tsu.internal_objects_alloc_page_count -
								tsu.user_objects_dealloc_page_count -
								tsu.internal_objects_dealloc_page_count AS tempdb_current
						FROM sys.dm_db_task_space_usage AS tsu
						CROSS APPLY
						(
							SELECT TOP(1)
								s0.session_id
							FROM @sessions AS s0
							WHERE
								s0.session_id = tsu.session_id
						) AS p

						UNION ALL

						SELECT TOP(@i)
							ssu.session_id,
							NULL AS request_id,
							ssu.user_objects_alloc_page_count +
								ssu.internal_objects_alloc_page_count AS tempdb_allocations,
							ssu.user_objects_alloc_page_count +
								ssu.internal_objects_alloc_page_count -
								ssu.user_objects_dealloc_page_count -
								ssu.internal_objects_dealloc_page_count AS tempdb_current
						FROM sys.dm_db_session_space_usage AS ssu
						CROSS APPLY
						(
							SELECT TOP(1)
								s0.session_id
							FROM @sessions AS s0
							WHERE
								s0.session_id = ssu.session_id
						) AS p
					) AS t_info
					GROUP BY
						t_info.session_id,
						COALESCE(t_info.request_id, -1)
				) AS tempdb_info ON
					tempdb_info.session_id = y.session_id
					AND tempdb_info.request_id =
						CASE
							WHEN y.status = N''sleeping'' THEN
								-1
							ELSE
								y.request_id
						END
				' +
				CASE 
					WHEN 
						NOT 
						(
							@get_avg_time = 1 
							AND @recursion = 1
						) THEN 
							''
					ELSE
						'LEFT OUTER HASH JOIN
						(
							SELECT TOP(@i)
								*
							FROM sys.dm_exec_query_stats
						) AS qs ON
							qs.sql_handle = y.sql_handle
							AND qs.plan_handle = y.plan_handle
							AND qs.statement_start_offset = y.statement_start_offset
							AND qs.statement_end_offset = y.statement_end_offset
						'
				END + 
			') AS x
			OPTION (KEEPFIXED PLAN, OPTIMIZE FOR (@i = 1)); ';

		SET @sql_n = CONVERT(NVARCHAR(MAX), @sql);

		SET @last_collection_start = GETDATE();

		IF @recursion = -1
		BEGIN;
			SELECT
				@first_collection_ms_ticks = ms_ticks
			FROM sys.dm_os_sys_info;
		END;

		INSERT #sessions
		(
			recursion,
			session_id,
			request_id,
			session_number,
			elapsed_time,
			avg_elapsed_time,
			physical_io,
			reads,
			physical_reads,
			writes,
			tempdb_allocations,
			tempdb_current,
			CPU,
			thread_CPU_snapshot,
			context_switches,
			used_memory,
			tasks,
			status,
			wait_info,
			transaction_id,
			open_tran_count,
			sql_handle,
			statement_start_offset,
			statement_end_offset,		
			sql_text,
			plan_handle,
			blocking_session_id,
			percent_complete,
			host_name,
			login_name,
			database_name,
			program_name,
			additional_info,
			start_time,
			login_time,
			last_request_start_time
		)
		EXEC sp_executesql 
			@sql_n,
			N'@recursion SMALLINT, @filter sysname, @not_filter sysname, @first_collection_ms_ticks BIGINT',
			@recursion, @filter, @not_filter, @first_collection_ms_ticks;

		--Collect transaction information?
		IF
			@recursion = 1
			AND
			(
				@output_column_list LIKE '%|[tran_start_time|]%' ESCAPE '|'
				OR @output_column_list LIKE '%|[tran_log_writes|]%' ESCAPE '|' 
			)
		BEGIN;	
			DECLARE @i INT;
			SET @i = 2147483647;

			UPDATE s
			SET
				tran_start_time =
					CONVERT
					(
						DATETIME,
						LEFT
						(
							x.trans_info,
							NULLIF(CHARINDEX(NCHAR(254) COLLATE Latin1_General_Bin2, x.trans_info) - 1, -1)
						),
						121
					),
				tran_log_writes =
					RIGHT
					(
						x.trans_info,
						LEN(x.trans_info) - CHARINDEX(NCHAR(254) COLLATE Latin1_General_Bin2, x.trans_info)
					)
			FROM
			(
				SELECT TOP(@i)
					trans_nodes.trans_node.value('(session_id/text())[1]', 'SMALLINT') AS session_id,
					COALESCE(trans_nodes.trans_node.value('(request_id/text())[1]', 'INT'), 0) AS request_id,
					trans_nodes.trans_node.value('(trans_info/text())[1]', 'NVARCHAR(4000)') AS trans_info				
				FROM
				(
					SELECT TOP(@i)
						CONVERT
						(
							XML,
							REPLACE
							(
								CONVERT(NVARCHAR(MAX), trans_raw.trans_xml_raw) COLLATE Latin1_General_Bin2, 
								N'</trans_info></trans><trans><trans_info>', N''
							)
						)
					FROM
					(
						SELECT TOP(@i)
							CASE u_trans.r
								WHEN 1 THEN u_trans.session_id
								ELSE NULL
							END AS [session_id],
							CASE u_trans.r
								WHEN 1 THEN u_trans.request_id
								ELSE NULL
							END AS [request_id],
							CONVERT
							(
								NVARCHAR(MAX),
								CASE
									WHEN u_trans.database_id IS NOT NULL THEN
										CASE u_trans.r
											WHEN 1 THEN COALESCE(CONVERT(NVARCHAR, u_trans.transaction_start_time, 121) + NCHAR(254), N'')
											ELSE N''
										END + 
											REPLACE
											(
												REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
												REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
												REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
													CONVERT(VARCHAR(128), COALESCE(DB_NAME(u_trans.database_id), N'(null)')),
													NCHAR(31),N'?'),NCHAR(30),N'?'),NCHAR(29),N'?'),NCHAR(28),N'?'),NCHAR(27),N'?'),NCHAR(26),N'?'),NCHAR(25),N'?'),NCHAR(24),N'?'),NCHAR(23),N'?'),NCHAR(22),N'?'),
													NCHAR(21),N'?'),NCHAR(20),N'?'),NCHAR(19),N'?'),NCHAR(18),N'?'),NCHAR(17),N'?'),NCHAR(16),N'?'),NCHAR(15),N'?'),NCHAR(14),N'?'),NCHAR(12),N'?'),
													NCHAR(11),N'?'),NCHAR(8),N'?'),NCHAR(7),N'?'),NCHAR(6),N'?'),NCHAR(5),N'?'),NCHAR(4),N'?'),NCHAR(3),N'?'),NCHAR(2),N'?'),NCHAR(1),N'?'),
												NCHAR(0),
												N'?'
											) +
											N': ' +
										CONVERT(NVARCHAR, u_trans.log_record_count) + N' (' + CONVERT(NVARCHAR, u_trans.log_kb_used) + N' kB)' +
										N','
									ELSE
										N'N/A,'
								END COLLATE Latin1_General_Bin2
							) AS [trans_info]
						FROM
						(
							SELECT TOP(@i)
								trans.*,
								ROW_NUMBER() OVER
								(
									PARTITION BY
										trans.session_id,
										trans.request_id
									ORDER BY
										trans.transaction_start_time DESC
								) AS r
							FROM
							(
								SELECT TOP(@i)
									session_tran_map.session_id,
									session_tran_map.request_id,
									s_tran.database_id,
									COALESCE(SUM(s_tran.database_transaction_log_record_count), 0) AS log_record_count,
									COALESCE(SUM(s_tran.database_transaction_log_bytes_used), 0) / 1024 AS log_kb_used,
									MIN(s_tran.database_transaction_begin_time) AS transaction_start_time
								FROM
								(
									SELECT TOP(@i)
										*
									FROM sys.dm_tran_active_transactions
									WHERE
										transaction_begin_time <= @last_collection_start
								) AS a_tran
								INNER HASH JOIN
								(
									SELECT TOP(@i)
										*
									FROM sys.dm_tran_database_transactions
									WHERE
										database_id < 32767
								) AS s_tran ON
									s_tran.transaction_id = a_tran.transaction_id
								LEFT OUTER HASH JOIN
								(
									SELECT TOP(@i)
										*
									FROM sys.dm_tran_session_transactions
								) AS tst ON
									s_tran.transaction_id = tst.transaction_id
								CROSS APPLY
								(
									SELECT TOP(1)
										s3.session_id,
										s3.request_id
									FROM
									(
										SELECT TOP(1)
											s1.session_id,
											s1.request_id
										FROM #sessions AS s1
										WHERE
											s1.transaction_id = s_tran.transaction_id
											AND s1.recursion = 1
											
										UNION ALL
									
										SELECT TOP(1)
											s2.session_id,
											s2.request_id
										FROM #sessions AS s2
										WHERE
											s2.session_id = tst.session_id
											AND s2.recursion = 1
									) AS s3
									ORDER BY
										s3.request_id
								) AS session_tran_map
								GROUP BY
									session_tran_map.session_id,
									session_tran_map.request_id,
									s_tran.database_id
							) AS trans
						) AS u_trans
						FOR XML
							PATH('trans'),
							TYPE
					) AS trans_raw (trans_xml_raw)
				) AS trans_final (trans_xml)
				CROSS APPLY trans_final.trans_xml.nodes('/trans') AS trans_nodes (trans_node)
			) AS x
			INNER HASH JOIN #sessions AS s ON
				s.session_id = x.session_id
				AND s.request_id = x.request_id
			OPTION (OPTIMIZE FOR (@i = 1));
		END;

		--Variables for text and plan collection
		DECLARE	
			@session_id SMALLINT,
			@request_id INT,
			@sql_handle VARBINARY(64),
			@plan_handle VARBINARY(64),
			@statement_start_offset INT,
			@statement_end_offset INT,
			@start_time DATETIME,
			@database_name sysname;

		IF 
			@recursion = 1
			AND @output_column_list LIKE '%|[sql_text|]%' ESCAPE '|'
		BEGIN;
			DECLARE sql_cursor
			CURSOR LOCAL FAST_FORWARD
			FOR 
				SELECT 
					session_id,
					request_id,
					sql_handle,
					statement_start_offset,
					statement_end_offset
				FROM #sessions
				WHERE
					recursion = 1
					AND sql_handle IS NOT NULL
			OPTION (KEEPFIXED PLAN);

			OPEN sql_cursor;

			FETCH NEXT FROM sql_cursor
			INTO 
				@session_id,
				@request_id,
				@sql_handle,
				@statement_start_offset,
				@statement_end_offset;

			--Wait up to 5 ms for the SQL text, then give up
			SET LOCK_TIMEOUT 5;

			WHILE @@FETCH_STATUS = 0
			BEGIN;
				BEGIN TRY;
					UPDATE s
					SET
						s.sql_text =
						(
							SELECT
								REPLACE
								(
									REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
									REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
									REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
										N'--' + NCHAR(13) + NCHAR(10) +
										CASE 
											WHEN @get_full_inner_text = 1 THEN est.text
											WHEN LEN(est.text) < (@statement_end_offset / 2) + 1 THEN est.text
											WHEN SUBSTRING(est.text, (@statement_start_offset/2), 2) LIKE N'[a-zA-Z0-9][a-zA-Z0-9]' THEN est.text
											ELSE
												CASE
													WHEN @statement_start_offset > 0 THEN
														SUBSTRING
														(
															est.text,
															((@statement_start_offset/2) + 1),
															(
																CASE
																	WHEN @statement_end_offset = -1 THEN 2147483647
																	ELSE ((@statement_end_offset - @statement_start_offset)/2) + 1
																END
															)
														)
													ELSE RTRIM(LTRIM(est.text))
												END
										END +
										NCHAR(13) + NCHAR(10) + N'--' COLLATE Latin1_General_Bin2,
										NCHAR(31),N'?'),NCHAR(30),N'?'),NCHAR(29),N'?'),NCHAR(28),N'?'),NCHAR(27),N'?'),NCHAR(26),N'?'),NCHAR(25),N'?'),NCHAR(24),N'?'),NCHAR(23),N'?'),NCHAR(22),N'?'),
										NCHAR(21),N'?'),NCHAR(20),N'?'),NCHAR(19),N'?'),NCHAR(18),N'?'),NCHAR(17),N'?'),NCHAR(16),N'?'),NCHAR(15),N'?'),NCHAR(14),N'?'),NCHAR(12),N'?'),
										NCHAR(11),N'?'),NCHAR(8),N'?'),NCHAR(7),N'?'),NCHAR(6),N'?'),NCHAR(5),N'?'),NCHAR(4),N'?'),NCHAR(3),N'?'),NCHAR(2),N'?'),NCHAR(1),N'?'),
									NCHAR(0),
									N''
								) AS [processing-instruction(query)]
							FOR XML
								PATH(''),
								TYPE
						),
						s.statement_start_offset = 
							CASE 
								WHEN LEN(est.text) < (@statement_end_offset / 2) + 1 THEN 0
								WHEN SUBSTRING(CONVERT(VARCHAR(MAX), est.text), (@statement_start_offset/2), 2) LIKE '[a-zA-Z0-9][a-zA-Z0-9]' THEN 0
								ELSE @statement_start_offset
							END,
						s.statement_end_offset = 
							CASE 
								WHEN LEN(est.text) < (@statement_end_offset / 2) + 1 THEN -1
								WHEN SUBSTRING(CONVERT(VARCHAR(MAX), est.text), (@statement_start_offset/2), 2) LIKE '[a-zA-Z0-9][a-zA-Z0-9]' THEN -1
								ELSE @statement_end_offset
							END
					FROM 
						#sessions AS s,
						(
							SELECT TOP(1)
								text
							FROM
							(
								SELECT 
									text, 
									0 AS row_num
								FROM sys.dm_exec_sql_text(@sql_handle)
								
								UNION ALL
								
								SELECT 
									NULL,
									1 AS row_num
							) AS est0
							ORDER BY
								row_num
						) AS est
					WHERE 
						s.session_id = @session_id
						AND s.request_id = @request_id
						AND s.recursion = 1
					OPTION (KEEPFIXED PLAN);
				END TRY
				BEGIN CATCH;
					UPDATE s
					SET
						s.sql_text = 
							CASE ERROR_NUMBER() 
								WHEN 1222 THEN '<timeout_exceeded />'
								ELSE '<error message="' + ERROR_MESSAGE() + '" />'
							END
					FROM #sessions AS s
					WHERE 
						s.session_id = @session_id
						AND s.request_id = @request_id
						AND s.recursion = 1
					OPTION (KEEPFIXED PLAN);
				END CATCH;

				FETCH NEXT FROM sql_cursor
				INTO
					@session_id,
					@request_id,
					@sql_handle,
					@statement_start_offset,
					@statement_end_offset;
			END;

			--Return this to the default
			SET LOCK_TIMEOUT -1;

			CLOSE sql_cursor;
			DEALLOCATE sql_cursor;
		END;

		IF 
			@get_outer_command = 1 
			AND @recursion = 1
			AND @output_column_list LIKE '%|[sql_command|]%' ESCAPE '|'
		BEGIN;
			DECLARE @buffer_results TABLE
			(
				EventType VARCHAR(30),
				Parameters INT,
				EventInfo NVARCHAR(4000),
				start_time DATETIME,
				session_number INT IDENTITY(1,1) NOT NULL PRIMARY KEY
			);

			DECLARE buffer_cursor
			CURSOR LOCAL FAST_FORWARD
			FOR 
				SELECT 
					session_id,
					MAX(start_time) AS start_time
				FROM #sessions
				WHERE
					recursion = 1
				GROUP BY
					session_id
				ORDER BY
					session_id
				OPTION (KEEPFIXED PLAN);

			OPEN buffer_cursor;

			FETCH NEXT FROM buffer_cursor
			INTO 
				@session_id,
				@start_time;

			WHILE @@FETCH_STATUS = 0
			BEGIN;
				BEGIN TRY;
					--In SQL Server 2008, DBCC INPUTBUFFER will throw 
					--an exception if the session no longer exists
					INSERT @buffer_results
					(
						EventType,
						Parameters,
						EventInfo
					)
					EXEC sp_executesql
						N'DBCC INPUTBUFFER(@session_id) WITH NO_INFOMSGS;',
						N'@session_id SMALLINT',
						@session_id;

					UPDATE br
					SET
						br.start_time = @start_time
					FROM @buffer_results AS br
					WHERE
						br.session_number = 
						(
							SELECT MAX(br2.session_number)
							FROM @buffer_results br2
						);
				END TRY
				BEGIN CATCH
				END CATCH;

				FETCH NEXT FROM buffer_cursor
				INTO 
					@session_id,
					@start_time;
			END;

			UPDATE s
			SET
				sql_command = 
				(
					SELECT 
						REPLACE
						(
							REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
							REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
							REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
								CONVERT
								(
									NVARCHAR(MAX),
									N'--' + NCHAR(13) + NCHAR(10) + br.EventInfo + NCHAR(13) + NCHAR(10) + N'--' COLLATE Latin1_General_Bin2
								),
								NCHAR(31),N'?'),NCHAR(30),N'?'),NCHAR(29),N'?'),NCHAR(28),N'?'),NCHAR(27),N'?'),NCHAR(26),N'?'),NCHAR(25),N'?'),NCHAR(24),N'?'),NCHAR(23),N'?'),NCHAR(22),N'?'),
								NCHAR(21),N'?'),NCHAR(20),N'?'),NCHAR(19),N'?'),NCHAR(18),N'?'),NCHAR(17),N'?'),NCHAR(16),N'?'),NCHAR(15),N'?'),NCHAR(14),N'?'),NCHAR(12),N'?'),
								NCHAR(11),N'?'),NCHAR(8),N'?'),NCHAR(7),N'?'),NCHAR(6),N'?'),NCHAR(5),N'?'),NCHAR(4),N'?'),NCHAR(3),N'?'),NCHAR(2),N'?'),NCHAR(1),N'?'),
							NCHAR(0),
							N''
						) AS [processing-instruction(query)]
					FROM @buffer_results AS br
					WHERE 
						br.session_number = s.session_number
						AND br.start_time = s.start_time
						AND 
						(
							(
								s.start_time = s.last_request_start_time
								AND EXISTS
								(
									SELECT *
									FROM sys.dm_exec_requests r2
									WHERE
										r2.session_id = s.session_id
										AND r2.request_id = s.request_id
										AND r2.start_time = s.start_time
								)
							)
							OR 
							(
								s.request_id = 0
								AND EXISTS
								(
									SELECT *
									FROM sys.dm_exec_sessions s2
									WHERE
										s2.session_id = s.session_id
										AND s2.last_request_start_time = s.last_request_start_time
								)
							)
						)
					FOR XML
						PATH(''),
						TYPE
				)
			FROM #sessions AS s
			WHERE
				recursion = 1
			OPTION (KEEPFIXED PLAN);

			CLOSE buffer_cursor;
			DEALLOCATE buffer_cursor;
		END;

		IF 
			@get_plans >= 1 
			AND @recursion = 1
			AND @output_column_list LIKE '%|[query_plan|]%' ESCAPE '|'
		BEGIN;
			DECLARE plan_cursor
			CURSOR LOCAL FAST_FORWARD
			FOR 
				SELECT
					session_id,
					request_id,
					plan_handle,
					statement_start_offset,
					statement_end_offset
				FROM #sessions
				WHERE
					recursion = 1
					AND plan_handle IS NOT NULL
			OPTION (KEEPFIXED PLAN);

			OPEN plan_cursor;

			FETCH NEXT FROM plan_cursor
			INTO 
				@session_id,
				@request_id,
				@plan_handle,
				@statement_start_offset,
				@statement_end_offset;

			--Wait up to 5 ms for a query plan, then give up
			SET LOCK_TIMEOUT 5;

			WHILE @@FETCH_STATUS = 0
			BEGIN;
				BEGIN TRY;
					UPDATE s
					SET
						s.query_plan =
						(
							SELECT
								CONVERT(xml, query_plan)
							FROM sys.dm_exec_text_query_plan
							(
								@plan_handle, 
								CASE @get_plans
									WHEN 1 THEN
										@statement_start_offset
									ELSE
										0
								END, 
								CASE @get_plans
									WHEN 1 THEN
										@statement_end_offset
									ELSE
										-1
								END
							)
						)
					FROM #sessions AS s
					WHERE 
						s.session_id = @session_id
						AND s.request_id = @request_id
						AND s.recursion = 1
					OPTION (KEEPFIXED PLAN);
				END TRY
				BEGIN CATCH;
					IF ERROR_NUMBER() = 6335
					BEGIN;
						UPDATE s
						SET
							s.query_plan =
							(
								SELECT
									N'--' + NCHAR(13) + NCHAR(10) + 
									N'-- Could not render showplan due to XML data type limitations. ' + NCHAR(13) + NCHAR(10) + 
									N'-- To see the graphical plan save the XML below as a .SQLPLAN file and re-open in SSMS.' + NCHAR(13) + NCHAR(10) +
									N'--' + NCHAR(13) + NCHAR(10) +
										REPLACE(qp.query_plan, N'<RelOp', NCHAR(13)+NCHAR(10)+N'<RelOp') + 
										NCHAR(13) + NCHAR(10) + N'--' COLLATE Latin1_General_Bin2 AS [processing-instruction(query_plan)]
								FROM sys.dm_exec_text_query_plan
								(
									@plan_handle, 
									CASE @get_plans
										WHEN 1 THEN
											@statement_start_offset
										ELSE
											0
									END, 
									CASE @get_plans
										WHEN 1 THEN
											@statement_end_offset
										ELSE
											-1
									END
								) AS qp
								FOR XML
									PATH(''),
									TYPE
							)
						FROM #sessions AS s
						WHERE 
							s.session_id = @session_id
							AND s.request_id = @request_id
							AND s.recursion = 1
						OPTION (KEEPFIXED PLAN);
					END;
					ELSE
					BEGIN;
						UPDATE s
						SET
							s.query_plan = 
								CASE ERROR_NUMBER() 
									WHEN 1222 THEN '<timeout_exceeded />'
									ELSE '<error message="' + ERROR_MESSAGE() + '" />'
								END
						FROM #sessions AS s
						WHERE 
							s.session_id = @session_id
							AND s.request_id = @request_id
							AND s.recursion = 1
						OPTION (KEEPFIXED PLAN);
					END;
				END CATCH;

				FETCH NEXT FROM plan_cursor
				INTO
					@session_id,
					@request_id,
					@plan_handle,
					@statement_start_offset,
					@statement_end_offset;
			END;

			--Return this to the default
			SET LOCK_TIMEOUT -1;

			CLOSE plan_cursor;
			DEALLOCATE plan_cursor;
		END;

		IF 
			@get_locks = 1 
			AND @recursion = 1
			AND @output_column_list LIKE '%|[locks|]%' ESCAPE '|'
		BEGIN;
			DECLARE locks_cursor
			CURSOR LOCAL FAST_FORWARD
			FOR 
				SELECT DISTINCT
					database_name
				FROM #locks
				WHERE
					EXISTS
					(
						SELECT *
						FROM #sessions AS s
						WHERE
							s.session_id = #locks.session_id
							AND recursion = 1
					)
					AND database_name <> '(null)'
				OPTION (KEEPFIXED PLAN);

			OPEN locks_cursor;

			FETCH NEXT FROM locks_cursor
			INTO 
				@database_name;

			WHILE @@FETCH_STATUS = 0
			BEGIN;
				BEGIN TRY;
					SET @sql_n = CONVERT(NVARCHAR(MAX), '') +
						'UPDATE l ' +
						'SET ' +
							'object_name = ' +
								'REPLACE ' +
								'( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
										'o.name COLLATE Latin1_General_Bin2, ' +
										'NCHAR(31),N''?''),NCHAR(30),N''?''),NCHAR(29),N''?''),NCHAR(28),N''?''),NCHAR(27),N''?''),NCHAR(26),N''?''),NCHAR(25),N''?''),NCHAR(24),N''?''),NCHAR(23),N''?''),NCHAR(22),N''?''), ' +
										'NCHAR(21),N''?''),NCHAR(20),N''?''),NCHAR(19),N''?''),NCHAR(18),N''?''),NCHAR(17),N''?''),NCHAR(16),N''?''),NCHAR(15),N''?''),NCHAR(14),N''?''),NCHAR(12),N''?''), ' +
										'NCHAR(11),N''?''),NCHAR(8),N''?''),NCHAR(7),N''?''),NCHAR(6),N''?''),NCHAR(5),N''?''),NCHAR(4),N''?''),NCHAR(3),N''?''),NCHAR(2),N''?''),NCHAR(1),N''?''), ' +
									'NCHAR(0), ' +
									N''''' ' +
								'), ' +
							'index_name = ' +
								'REPLACE ' +
								'( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
										'i.name COLLATE Latin1_General_Bin2, ' +
										'NCHAR(31),N''?''),NCHAR(30),N''?''),NCHAR(29),N''?''),NCHAR(28),N''?''),NCHAR(27),N''?''),NCHAR(26),N''?''),NCHAR(25),N''?''),NCHAR(24),N''?''),NCHAR(23),N''?''),NCHAR(22),N''?''), ' +
										'NCHAR(21),N''?''),NCHAR(20),N''?''),NCHAR(19),N''?''),NCHAR(18),N''?''),NCHAR(17),N''?''),NCHAR(16),N''?''),NCHAR(15),N''?''),NCHAR(14),N''?''),NCHAR(12),N''?''), ' +
										'NCHAR(11),N''?''),NCHAR(8),N''?''),NCHAR(7),N''?''),NCHAR(6),N''?''),NCHAR(5),N''?''),NCHAR(4),N''?''),NCHAR(3),N''?''),NCHAR(2),N''?''),NCHAR(1),N''?''), ' +
									'NCHAR(0), ' +
									N''''' ' +
								'), ' +
							'schema_name = ' +
								'REPLACE ' +
								'( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
										's.name COLLATE Latin1_General_Bin2, ' +
										'NCHAR(31),N''?''),NCHAR(30),N''?''),NCHAR(29),N''?''),NCHAR(28),N''?''),NCHAR(27),N''?''),NCHAR(26),N''?''),NCHAR(25),N''?''),NCHAR(24),N''?''),NCHAR(23),N''?''),NCHAR(22),N''?''), ' +
										'NCHAR(21),N''?''),NCHAR(20),N''?''),NCHAR(19),N''?''),NCHAR(18),N''?''),NCHAR(17),N''?''),NCHAR(16),N''?''),NCHAR(15),N''?''),NCHAR(14),N''?''),NCHAR(12),N''?''), ' +
										'NCHAR(11),N''?''),NCHAR(8),N''?''),NCHAR(7),N''?''),NCHAR(6),N''?''),NCHAR(5),N''?''),NCHAR(4),N''?''),NCHAR(3),N''?''),NCHAR(2),N''?''),NCHAR(1),N''?''), ' +
									'NCHAR(0), ' +
									N''''' ' +
								'), ' +
							'principal_name = ' + 
								'REPLACE ' +
								'( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
										'dp.name COLLATE Latin1_General_Bin2, ' +
										'NCHAR(31),N''?''),NCHAR(30),N''?''),NCHAR(29),N''?''),NCHAR(28),N''?''),NCHAR(27),N''?''),NCHAR(26),N''?''),NCHAR(25),N''?''),NCHAR(24),N''?''),NCHAR(23),N''?''),NCHAR(22),N''?''), ' +
										'NCHAR(21),N''?''),NCHAR(20),N''?''),NCHAR(19),N''?''),NCHAR(18),N''?''),NCHAR(17),N''?''),NCHAR(16),N''?''),NCHAR(15),N''?''),NCHAR(14),N''?''),NCHAR(12),N''?''), ' +
										'NCHAR(11),N''?''),NCHAR(8),N''?''),NCHAR(7),N''?''),NCHAR(6),N''?''),NCHAR(5),N''?''),NCHAR(4),N''?''),NCHAR(3),N''?''),NCHAR(2),N''?''),NCHAR(1),N''?''), ' +
									'NCHAR(0), ' +
									N''''' ' +
								') ' +
						'FROM #locks AS l ' +
						'LEFT OUTER JOIN ' + QUOTENAME(@database_name) + '.sys.allocation_units AS au ON ' +
							'au.allocation_unit_id = l.allocation_unit_id ' +
						'LEFT OUTER JOIN ' + QUOTENAME(@database_name) + '.sys.partitions AS p ON ' +
							'p.hobt_id = ' +
								'COALESCE ' +
								'( ' +
									'l.hobt_id, ' +
									'CASE ' +
										'WHEN au.type IN (1, 3) THEN au.container_id ' +
										'ELSE NULL ' +
									'END ' +
								') ' +
						'LEFT OUTER JOIN ' + QUOTENAME(@database_name) + '.sys.partitions AS p1 ON ' +
							'l.hobt_id IS NULL ' +
							'AND au.type = 2 ' +
							'AND p1.partition_id = au.container_id ' +
						'LEFT OUTER JOIN ' + QUOTENAME(@database_name) + '.sys.objects AS o ON ' +
							'o.object_id = COALESCE(l.object_id, p.object_id, p1.object_id) ' +
						'LEFT OUTER JOIN ' + QUOTENAME(@database_name) + '.sys.indexes AS i ON ' +
							'i.object_id = COALESCE(l.object_id, p.object_id, p1.object_id) ' +
							'AND i.index_id = COALESCE(l.index_id, p.index_id, p1.index_id) ' +
						'LEFT OUTER JOIN ' + QUOTENAME(@database_name) + '.sys.schemas AS s ON ' +
							's.schema_id = COALESCE(l.schema_id, o.schema_id) ' +
						'LEFT OUTER JOIN ' + QUOTENAME(@database_name) + '.sys.database_principals AS dp ON ' +
							'dp.principal_id = l.principal_id ' +
						'WHERE ' +
							'l.database_name = @database_name ' +
						'OPTION (KEEPFIXED PLAN); ';
					
					EXEC sp_executesql
						@sql_n,
						N'@database_name sysname',
						@database_name;
				END TRY
				BEGIN CATCH;
					UPDATE #locks
					SET
						query_error = 
							REPLACE
							(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
									CONVERT
									(
										NVARCHAR(MAX), 
										ERROR_MESSAGE() COLLATE Latin1_General_Bin2
									),
									NCHAR(31),N'?'),NCHAR(30),N'?'),NCHAR(29),N'?'),NCHAR(28),N'?'),NCHAR(27),N'?'),NCHAR(26),N'?'),NCHAR(25),N'?'),NCHAR(24),N'?'),NCHAR(23),N'?'),NCHAR(22),N'?'),
									NCHAR(21),N'?'),NCHAR(20),N'?'),NCHAR(19),N'?'),NCHAR(18),N'?'),NCHAR(17),N'?'),NCHAR(16),N'?'),NCHAR(15),N'?'),NCHAR(14),N'?'),NCHAR(12),N'?'),
									NCHAR(11),N'?'),NCHAR(8),N'?'),NCHAR(7),N'?'),NCHAR(6),N'?'),NCHAR(5),N'?'),NCHAR(4),N'?'),NCHAR(3),N'?'),NCHAR(2),N'?'),NCHAR(1),N'?'),
								NCHAR(0),
								N''
							)
					WHERE 
						database_name = @database_name
					OPTION (KEEPFIXED PLAN);
				END CATCH;

				FETCH NEXT FROM locks_cursor
				INTO
					@database_name;
			END;

			CLOSE locks_cursor;
			DEALLOCATE locks_cursor;

			CREATE CLUSTERED INDEX IX_SRD ON #locks (session_id, request_id, database_name);

			UPDATE s
			SET 
				s.locks =
				(
					SELECT 
						REPLACE
						(
							REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
							REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
							REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
								CONVERT
								(
									NVARCHAR(MAX), 
									l1.database_name COLLATE Latin1_General_Bin2
								),
								NCHAR(31),N'?'),NCHAR(30),N'?'),NCHAR(29),N'?'),NCHAR(28),N'?'),NCHAR(27),N'?'),NCHAR(26),N'?'),NCHAR(25),N'?'),NCHAR(24),N'?'),NCHAR(23),N'?'),NCHAR(22),N'?'),
								NCHAR(21),N'?'),NCHAR(20),N'?'),NCHAR(19),N'?'),NCHAR(18),N'?'),NCHAR(17),N'?'),NCHAR(16),N'?'),NCHAR(15),N'?'),NCHAR(14),N'?'),NCHAR(12),N'?'),
								NCHAR(11),N'?'),NCHAR(8),N'?'),NCHAR(7),N'?'),NCHAR(6),N'?'),NCHAR(5),N'?'),NCHAR(4),N'?'),NCHAR(3),N'?'),NCHAR(2),N'?'),NCHAR(1),N'?'),
							NCHAR(0),
							N''
						) AS [Database/@name],
						MIN(l1.query_error) AS [Database/@query_error],
						(
							SELECT 
								l2.request_mode AS [Lock/@request_mode],
								l2.request_status AS [Lock/@request_status],
								COUNT(*) AS [Lock/@request_count]
							FROM #locks AS l2
							WHERE 
								l1.session_id = l2.session_id
								AND l1.request_id = l2.request_id
								AND l2.database_name = l1.database_name
								AND l2.resource_type = 'DATABASE'
							GROUP BY
								l2.request_mode,
								l2.request_status
							FOR XML
								PATH(''),
								TYPE
						) AS [Database/Locks],
						(
							SELECT
								COALESCE(l3.object_name, '(null)') AS [Object/@name],
								l3.schema_name AS [Object/@schema_name],
								(
									SELECT
										l4.resource_type AS [Lock/@resource_type],
										l4.page_type AS [Lock/@page_type],
										l4.index_name AS [Lock/@index_name],
										CASE 
											WHEN l4.object_name IS NULL THEN l4.schema_name
											ELSE NULL
										END AS [Lock/@schema_name],
										l4.principal_name AS [Lock/@principal_name],
										l4.resource_description AS [Lock/@resource_description],
										l4.request_mode AS [Lock/@request_mode],
										l4.request_status AS [Lock/@request_status],
										SUM(l4.request_count) AS [Lock/@request_count]
									FROM #locks AS l4
									WHERE 
										l4.session_id = l3.session_id
										AND l4.request_id = l3.request_id
										AND l3.database_name = l4.database_name
										AND COALESCE(l3.object_name, '(null)') = COALESCE(l4.object_name, '(null)')
										AND COALESCE(l3.schema_name, '') = COALESCE(l4.schema_name, '')
										AND l4.resource_type <> 'DATABASE'
									GROUP BY
										l4.resource_type,
										l4.page_type,
										l4.index_name,
										CASE 
											WHEN l4.object_name IS NULL THEN l4.schema_name
											ELSE NULL
										END,
										l4.principal_name,
										l4.resource_description,
										l4.request_mode,
										l4.request_status
									FOR XML
										PATH(''),
										TYPE
								) AS [Object/Locks]
							FROM #locks AS l3
							WHERE 
								l3.session_id = l1.session_id
								AND l3.request_id = l1.request_id
								AND l3.database_name = l1.database_name
								AND l3.resource_type <> 'DATABASE'
							GROUP BY 
								l3.session_id,
								l3.request_id,
								l3.database_name,
								COALESCE(l3.object_name, '(null)'),
								l3.schema_name
							FOR XML
								PATH(''),
								TYPE
						) AS [Database/Objects]
					FROM #locks AS l1
					WHERE
						l1.session_id = s.session_id
						AND l1.request_id = s.request_id
						AND l1.start_time IN (s.start_time, s.last_request_start_time)
						AND s.recursion = 1
					GROUP BY 
						l1.session_id,
						l1.request_id,
						l1.database_name
					FOR XML
						PATH(''),
						TYPE
				)
			FROM #sessions s
			OPTION (KEEPFIXED PLAN);
		END;

		IF 
			@find_block_leaders = 1
			AND @recursion = 1
			AND @output_column_list LIKE '%|[blocked_session_count|]%' ESCAPE '|'
		BEGIN;
			WITH
			blockers AS
			(
				SELECT
					session_id,
					session_id AS top_level_session_id,
					CONVERT(VARCHAR(8000), '.' + CONVERT(VARCHAR(8000), session_id) + '.') AS the_path
				FROM #sessions
				WHERE
					recursion = 1

				UNION ALL

				SELECT
					s.session_id,
					b.top_level_session_id,
					CONVERT(VARCHAR(8000), b.the_path + CONVERT(VARCHAR(8000), s.session_id) + '.') AS the_path
				FROM blockers AS b
				JOIN #sessions AS s ON
					s.blocking_session_id = b.session_id
					AND s.recursion = 1
					AND b.the_path NOT LIKE '%.' + CONVERT(VARCHAR(8000), s.session_id) + '.%' COLLATE Latin1_General_Bin2
			)
			UPDATE s
			SET
				s.blocked_session_count = x.blocked_session_count
			FROM #sessions AS s
			JOIN
			(
				SELECT
					b.top_level_session_id AS session_id,
					COUNT(*) - 1 AS blocked_session_count
				FROM blockers AS b
				GROUP BY
					b.top_level_session_id
			) x ON
				s.session_id = x.session_id
			WHERE
				s.recursion = 1;
		END;

		IF
			@get_task_info = 2
			AND @output_column_list LIKE '%|[additional_info|]%' ESCAPE '|'
			AND @recursion = 1
		BEGIN;
			CREATE TABLE #blocked_requests
			(
				session_id SMALLINT NOT NULL,
				request_id INT NOT NULL,
				database_name sysname NOT NULL,
				object_id INT,
				hobt_id BIGINT,
				schema_id INT,
				schema_name sysname NULL,
				object_name sysname NULL,
				query_error NVARCHAR(2048),
				PRIMARY KEY (database_name, session_id, request_id)
			);

			CREATE STATISTICS s_database_name ON #blocked_requests (database_name)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_schema_name ON #blocked_requests (schema_name)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_object_name ON #blocked_requests (object_name)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
			CREATE STATISTICS s_query_error ON #blocked_requests (query_error)
			WITH SAMPLE 0 ROWS, NORECOMPUTE;
		
			INSERT #blocked_requests
			(
				session_id,
				request_id,
				database_name,
				object_id,
				hobt_id,
				schema_id
			)
			SELECT
				session_id,
				request_id,
				database_name,
				object_id,
				hobt_id,
				CONVERT(INT, SUBSTRING(schema_node, CHARINDEX(' = ', schema_node) + 3, LEN(schema_node))) AS schema_id
			FROM
			(
				SELECT
					session_id,
					request_id,
					agent_nodes.agent_node.value('(database_name/text())[1]', 'sysname') AS database_name,
					agent_nodes.agent_node.value('(object_id/text())[1]', 'int') AS object_id,
					agent_nodes.agent_node.value('(hobt_id/text())[1]', 'bigint') AS hobt_id,
					agent_nodes.agent_node.value('(metadata_resource/text()[.="SCHEMA"]/../../metadata_class_id/text())[1]', 'varchar(100)') AS schema_node
				FROM #sessions AS s
				CROSS APPLY s.additional_info.nodes('//block_info') AS agent_nodes (agent_node)
				WHERE
					s.recursion = 1
			) AS t
			WHERE
				t.database_name IS NOT NULL
				AND
				(
					t.object_id IS NOT NULL
					OR t.hobt_id IS NOT NULL
					OR t.schema_node IS NOT NULL
				);
			
			DECLARE blocks_cursor
			CURSOR LOCAL FAST_FORWARD
			FOR
				SELECT DISTINCT
					database_name
				FROM #blocked_requests;
				
			OPEN blocks_cursor;
			
			FETCH NEXT FROM blocks_cursor
			INTO 
				@database_name;
			
			WHILE @@FETCH_STATUS = 0
			BEGIN;
				BEGIN TRY;
					SET @sql_n = 
						CONVERT(NVARCHAR(MAX), '') +
						'UPDATE b ' +
						'SET ' +
							'b.schema_name = ' +
								'REPLACE ' +
								'( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
										's.name COLLATE Latin1_General_Bin2, ' +
										'NCHAR(31),N''?''),NCHAR(30),N''?''),NCHAR(29),N''?''),NCHAR(28),N''?''),NCHAR(27),N''?''),NCHAR(26),N''?''),NCHAR(25),N''?''),NCHAR(24),N''?''),NCHAR(23),N''?''),NCHAR(22),N''?''), ' +
										'NCHAR(21),N''?''),NCHAR(20),N''?''),NCHAR(19),N''?''),NCHAR(18),N''?''),NCHAR(17),N''?''),NCHAR(16),N''?''),NCHAR(15),N''?''),NCHAR(14),N''?''),NCHAR(12),N''?''), ' +
										'NCHAR(11),N''?''),NCHAR(8),N''?''),NCHAR(7),N''?''),NCHAR(6),N''?''),NCHAR(5),N''?''),NCHAR(4),N''?''),NCHAR(3),N''?''),NCHAR(2),N''?''),NCHAR(1),N''?''), ' +
									'NCHAR(0), ' +
									N''''' ' +
								'), ' +
							'b.object_name = ' +
								'REPLACE ' +
								'( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
									'REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( ' +
										'o.name COLLATE Latin1_General_Bin2, ' +
										'NCHAR(31),N''?''),NCHAR(30),N''?''),NCHAR(29),N''?''),NCHAR(28),N''?''),NCHAR(27),N''?''),NCHAR(26),N''?''),NCHAR(25),N''?''),NCHAR(24),N''?''),NCHAR(23),N''?''),NCHAR(22),N''?''), ' +
										'NCHAR(21),N''?''),NCHAR(20),N''?''),NCHAR(19),N''?''),NCHAR(18),N''?''),NCHAR(17),N''?''),NCHAR(16),N''?''),NCHAR(15),N''?''),NCHAR(14),N''?''),NCHAR(12),N''?''), ' +
										'NCHAR(11),N''?''),NCHAR(8),N''?''),NCHAR(7),N''?''),NCHAR(6),N''?''),NCHAR(5),N''?''),NCHAR(4),N''?''),NCHAR(3),N''?''),NCHAR(2),N''?''),NCHAR(1),N''?''), ' +
									'NCHAR(0), ' +
									N''''' ' +
								') ' +
						'FROM #blocked_requests AS b ' +
						'LEFT OUTER JOIN ' + QUOTENAME(@database_name) + '.sys.partitions AS p ON ' +
							'p.hobt_id = b.hobt_id ' +
						'LEFT OUTER JOIN ' + QUOTENAME(@database_name) + '.sys.objects AS o ON ' +
							'o.object_id = COALESCE(p.object_id, b.object_id) ' +
						'LEFT OUTER JOIN ' + QUOTENAME(@database_name) + '.sys.schemas AS s ON ' +
							's.schema_id = COALESCE(o.schema_id, b.schema_id) ' +
						'WHERE ' +
							'b.database_name = @database_name; ';
					
					EXEC sp_executesql
						@sql_n,
						N'@database_name sysname',
						@database_name;
				END TRY
				BEGIN CATCH;
					UPDATE #blocked_requests
					SET
						query_error = 
							REPLACE
							(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
									CONVERT
									(
										NVARCHAR(MAX), 
										ERROR_MESSAGE() COLLATE Latin1_General_Bin2
									),
									NCHAR(31),N'?'),NCHAR(30),N'?'),NCHAR(29),N'?'),NCHAR(28),N'?'),NCHAR(27),N'?'),NCHAR(26),N'?'),NCHAR(25),N'?'),NCHAR(24),N'?'),NCHAR(23),N'?'),NCHAR(22),N'?'),
									NCHAR(21),N'?'),NCHAR(20),N'?'),NCHAR(19),N'?'),NCHAR(18),N'?'),NCHAR(17),N'?'),NCHAR(16),N'?'),NCHAR(15),N'?'),NCHAR(14),N'?'),NCHAR(12),N'?'),
									NCHAR(11),N'?'),NCHAR(8),N'?'),NCHAR(7),N'?'),NCHAR(6),N'?'),NCHAR(5),N'?'),NCHAR(4),N'?'),NCHAR(3),N'?'),NCHAR(2),N'?'),NCHAR(1),N'?'),
								NCHAR(0),
								N''
							)
					WHERE
						database_name = @database_name;
				END CATCH;

				FETCH NEXT FROM blocks_cursor
				INTO
					@database_name;
			END;
			
			CLOSE blocks_cursor;
			DEALLOCATE blocks_cursor;
			
			UPDATE s
			SET
				additional_info.modify
				('
					insert <schema_name>{sql:column("b.schema_name")}</schema_name>
					as last
					into (/additional_info/block_info)[1]
				')
			FROM #sessions AS s
			INNER JOIN #blocked_requests AS b ON
				b.session_id = s.session_id
				AND b.request_id = s.request_id
				AND s.recursion = 1
			WHERE
				b.schema_name IS NOT NULL;

			UPDATE s
			SET
				additional_info.modify
				('
					insert <object_name>{sql:column("b.object_name")}</object_name>
					as last
					into (/additional_info/block_info)[1]
				')
			FROM #sessions AS s
			INNER JOIN #blocked_requests AS b ON
				b.session_id = s.session_id
				AND b.request_id = s.request_id
				AND s.recursion = 1
			WHERE
				b.object_name IS NOT NULL;

			UPDATE s
			SET
				additional_info.modify
				('
					insert <query_error>{sql:column("b.query_error")}</query_error>
					as last
					into (/additional_info/block_info)[1]
				')
			FROM #sessions AS s
			INNER JOIN #blocked_requests AS b ON
				b.session_id = s.session_id
				AND b.request_id = s.request_id
				AND s.recursion = 1
			WHERE
				b.query_error IS NOT NULL;
		END;

		IF
			@output_column_list LIKE '%|[program_name|]%' ESCAPE '|'
			AND @output_column_list LIKE '%|[additional_info|]%' ESCAPE '|'
			AND @recursion = 1
		BEGIN;
			DECLARE @job_id UNIQUEIDENTIFIER;
			DECLARE @step_id INT;

			DECLARE agent_cursor
			CURSOR LOCAL FAST_FORWARD
			FOR 
				SELECT
					s.session_id,
					agent_nodes.agent_node.value('(job_id/text())[1]', 'uniqueidentifier') AS job_id,
					agent_nodes.agent_node.value('(step_id/text())[1]', 'int') AS step_id
				FROM #sessions AS s
				CROSS APPLY s.additional_info.nodes('//agent_job_info') AS agent_nodes (agent_node)
				WHERE
					s.recursion = 1
			OPTION (KEEPFIXED PLAN);
			
			OPEN agent_cursor;

			FETCH NEXT FROM agent_cursor
			INTO 
				@session_id,
				@job_id,
				@step_id;

			WHILE @@FETCH_STATUS = 0
			BEGIN;
				BEGIN TRY;
					DECLARE @job_name sysname;
					SET @job_name = NULL;
					DECLARE @step_name sysname;
					SET @step_name = NULL;
					
					SELECT
						@job_name = 
							REPLACE
							(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
									j.name,
									NCHAR(31),N'?'),NCHAR(30),N'?'),NCHAR(29),N'?'),NCHAR(28),N'?'),NCHAR(27),N'?'),NCHAR(26),N'?'),NCHAR(25),N'?'),NCHAR(24),N'?'),NCHAR(23),N'?'),NCHAR(22),N'?'),
									NCHAR(21),N'?'),NCHAR(20),N'?'),NCHAR(19),N'?'),NCHAR(18),N'?'),NCHAR(17),N'?'),NCHAR(16),N'?'),NCHAR(15),N'?'),NCHAR(14),N'?'),NCHAR(12),N'?'),
									NCHAR(11),N'?'),NCHAR(8),N'?'),NCHAR(7),N'?'),NCHAR(6),N'?'),NCHAR(5),N'?'),NCHAR(4),N'?'),NCHAR(3),N'?'),NCHAR(2),N'?'),NCHAR(1),N'?'),
								NCHAR(0),
								N'?'
							),
						@step_name = 
							REPLACE
							(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
								REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
									s.step_name,
									NCHAR(31),N'?'),NCHAR(30),N'?'),NCHAR(29),N'?'),NCHAR(28),N'?'),NCHAR(27),N'?'),NCHAR(26),N'?'),NCHAR(25),N'?'),NCHAR(24),N'?'),NCHAR(23),N'?'),NCHAR(22),N'?'),
									NCHAR(21),N'?'),NCHAR(20),N'?'),NCHAR(19),N'?'),NCHAR(18),N'?'),NCHAR(17),N'?'),NCHAR(16),N'?'),NCHAR(15),N'?'),NCHAR(14),N'?'),NCHAR(12),N'?'),
									NCHAR(11),N'?'),NCHAR(8),N'?'),NCHAR(7),N'?'),NCHAR(6),N'?'),NCHAR(5),N'?'),NCHAR(4),N'?'),NCHAR(3),N'?'),NCHAR(2),N'?'),NCHAR(1),N'?'),
								NCHAR(0),
								N'?'
							)
					FROM msdb.dbo.sysjobs AS j
					INNER JOIN msdb..sysjobsteps AS s ON
						j.job_id = s.job_id
					WHERE
						j.job_id = @job_id
						AND s.step_id = @step_id;

					IF @job_name IS NOT NULL
					BEGIN;
						UPDATE s
						SET
							additional_info.modify
							('
								insert text{sql:variable("@job_name")}
								into (/additional_info/agent_job_info/job_name)[1]
							')
						FROM #sessions AS s
						WHERE 
							s.session_id = @session_id
						OPTION (KEEPFIXED PLAN);
						
						UPDATE s
						SET
							additional_info.modify
							('
								insert text{sql:variable("@step_name")}
								into (/additional_info/agent_job_info/step_name)[1]
							')
						FROM #sessions AS s
						WHERE 
							s.session_id = @session_id
						OPTION (KEEPFIXED PLAN);
					END;
				END TRY
				BEGIN CATCH;
					DECLARE @msdb_error_message NVARCHAR(256);
					SET @msdb_error_message = ERROR_MESSAGE();
				
					UPDATE s
					SET
						additional_info.modify
						('
							insert <msdb_query_error>{sql:variable("@msdb_error_message")}</msdb_query_error>
							as last
							into (/additional_info/agent_job_info)[1]
						')
					FROM #sessions AS s
					WHERE 
						s.session_id = @session_id
						AND s.recursion = 1
					OPTION (KEEPFIXED PLAN);
				END CATCH;

				FETCH NEXT FROM agent_cursor
				INTO 
					@session_id,
					@job_id,
					@step_id;
			END;

			CLOSE agent_cursor;
			DEALLOCATE agent_cursor;
		END; 
		
		IF 
			@delta_interval > 0 
			AND @recursion <> 1
		BEGIN;
			SET @recursion = 1;

			DECLARE @delay_time CHAR(12);
			SET @delay_time = CONVERT(VARCHAR, DATEADD(second, @delta_interval, 0), 114);
			WAITFOR DELAY @delay_time;

			GOTO REDO;
		END;
	END;

	SET @sql = 
		--Outer column list
		CONVERT
		(
			VARCHAR(MAX),
			CASE
				WHEN 
					@destination_table <> '' 
					AND @return_schema = 0 
						THEN 'INSERT ' + @destination_table + ' '
				ELSE ''
			END +
			'SELECT ' +
				@output_column_list + ' ' +
			CASE @return_schema
				WHEN 1 THEN 'INTO #session_schema '
				ELSE ''
			END
		--End outer column list
		) + 
		--Inner column list
		CONVERT
		(
			VARCHAR(MAX),
			'FROM ' +
			'( ' +
				'SELECT ' +
					'session_id, ' +
					--[dd hh:mm:ss.mss]
					CASE
						WHEN @format_output IN (1, 2) THEN
							'CASE ' +
								'WHEN elapsed_time < 0 THEN ' +
									'RIGHT ' +
									'( ' +
										'REPLICATE(''0'', max_elapsed_length) + CONVERT(VARCHAR, (-1 * elapsed_time) / 86400), ' +
										'max_elapsed_length ' +
									') + ' +
										'RIGHT ' +
										'( ' +
											'CONVERT(VARCHAR, DATEADD(second, (-1 * elapsed_time), 0), 120), ' +
											'9 ' +
										') + ' +
										'''.000'' ' +
								'ELSE ' +
									'RIGHT ' +
									'( ' +
										'REPLICATE(''0'', max_elapsed_length) + CONVERT(VARCHAR, elapsed_time / 86400000), ' +
										'max_elapsed_length ' +
									') + ' +
										'RIGHT ' +
										'( ' +
											'CONVERT(VARCHAR, DATEADD(second, elapsed_time / 1000, 0), 120), ' +
											'9 ' +
										') + ' +
										'''.'' + ' + 
										'RIGHT(''000'' + CONVERT(VARCHAR, elapsed_time % 1000), 3) ' +
							'END AS [dd hh:mm:ss.mss], '
						ELSE
							''
					END +
					--[dd hh:mm:ss.mss (avg)] / avg_elapsed_time
					CASE 
						WHEN  @format_output IN (1, 2) THEN 
							'RIGHT ' +
							'( ' +
								'''00'' + CONVERT(VARCHAR, avg_elapsed_time / 86400000), ' +
								'2 ' +
							') + ' +
								'RIGHT ' +
								'( ' +
									'CONVERT(VARCHAR, DATEADD(second, avg_elapsed_time / 1000, 0), 120), ' +
									'9 ' +
								') + ' +
								'''.'' + ' +
								'RIGHT(''000'' + CONVERT(VARCHAR, avg_elapsed_time % 1000), 3) AS [dd hh:mm:ss.mss (avg)], '
						ELSE
							'avg_elapsed_time, '
					END +
					--physical_io
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, physical_io))) OVER() - LEN(CONVERT(VARCHAR, physical_io))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, physical_io), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, physical_io), 1), 19)) AS '
						ELSE ''
					END + 'physical_io, ' +
					--reads
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, reads))) OVER() - LEN(CONVERT(VARCHAR, reads))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, reads), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, reads), 1), 19)) AS '
						ELSE ''
					END + 'reads, ' +
					--physical_reads
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, physical_reads))) OVER() - LEN(CONVERT(VARCHAR, physical_reads))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, physical_reads), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, physical_reads), 1), 19)) AS '
						ELSE ''
					END + 'physical_reads, ' +
					--writes
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, writes))) OVER() - LEN(CONVERT(VARCHAR, writes))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, writes), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, writes), 1), 19)) AS '
						ELSE ''
					END + 'writes, ' +
					--tempdb_allocations
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, tempdb_allocations))) OVER() - LEN(CONVERT(VARCHAR, tempdb_allocations))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, tempdb_allocations), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, tempdb_allocations), 1), 19)) AS '
						ELSE ''
					END + 'tempdb_allocations, ' +
					--tempdb_current
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, tempdb_current))) OVER() - LEN(CONVERT(VARCHAR, tempdb_current))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, tempdb_current), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, tempdb_current), 1), 19)) AS '
						ELSE ''
					END + 'tempdb_current, ' +
					--CPU
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, CPU))) OVER() - LEN(CONVERT(VARCHAR, CPU))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, CPU), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, CPU), 1), 19)) AS '
						ELSE ''
					END + 'CPU, ' +
					--context_switches
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, context_switches))) OVER() - LEN(CONVERT(VARCHAR, context_switches))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, context_switches), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, context_switches), 1), 19)) AS '
						ELSE ''
					END + 'context_switches, ' +
					--used_memory
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, used_memory))) OVER() - LEN(CONVERT(VARCHAR, used_memory))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, used_memory), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, used_memory), 1), 19)) AS '
						ELSE ''
					END + 'used_memory, ' +
					CASE
						WHEN @output_column_list LIKE '%|_delta|]%' ESCAPE '|' THEN
							--physical_io_delta			
							'CASE ' +
								'WHEN ' +
									'first_request_start_time = last_request_start_time ' + 
									'AND num_events = 2 ' +
									'AND physical_io_delta >= 0 ' +
										'THEN ' +
										CASE @format_output
											WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, physical_io_delta))) OVER() - LEN(CONVERT(VARCHAR, physical_io_delta))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, physical_io_delta), 1), 19)) ' 
											WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, physical_io_delta), 1), 19)) '
											ELSE 'physical_io_delta '
										END +
								'ELSE NULL ' +
							'END AS physical_io_delta, ' +
							--reads_delta
							'CASE ' +
								'WHEN ' +
									'first_request_start_time = last_request_start_time ' + 
									'AND num_events = 2 ' +
									'AND reads_delta >= 0 ' +
										'THEN ' +
										CASE @format_output
											WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, reads_delta))) OVER() - LEN(CONVERT(VARCHAR, reads_delta))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, reads_delta), 1), 19)) '
											WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, reads_delta), 1), 19)) '
											ELSE 'reads_delta '
										END +
								'ELSE NULL ' +
							'END AS reads_delta, ' +
							--physical_reads_delta
							'CASE ' +
								'WHEN ' +
									'first_request_start_time = last_request_start_time ' + 
									'AND num_events = 2 ' +
									'AND physical_reads_delta >= 0 ' +
										'THEN ' +
										CASE @format_output
											WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, physical_reads_delta))) OVER() - LEN(CONVERT(VARCHAR, physical_reads_delta))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, physical_reads_delta), 1), 19)) '
											WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, physical_reads_delta), 1), 19)) '
											ELSE 'physical_reads_delta '
										END + 
								'ELSE NULL ' +
							'END AS physical_reads_delta, ' +
							--writes_delta
							'CASE ' +
								'WHEN ' +
									'first_request_start_time = last_request_start_time ' + 
									'AND num_events = 2 ' +
									'AND writes_delta >= 0 ' +
										'THEN ' +
										CASE @format_output
											WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, writes_delta))) OVER() - LEN(CONVERT(VARCHAR, writes_delta))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, writes_delta), 1), 19)) '
											WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, writes_delta), 1), 19)) '
											ELSE 'writes_delta '
										END + 
								'ELSE NULL ' +
							'END AS writes_delta, ' +
							--tempdb_allocations_delta
							'CASE ' +
								'WHEN ' +
									'first_request_start_time = last_request_start_time ' + 
									'AND num_events = 2 ' +
									'AND tempdb_allocations_delta >= 0 ' +
										'THEN ' +
										CASE @format_output
											WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, tempdb_allocations_delta))) OVER() - LEN(CONVERT(VARCHAR, tempdb_allocations_delta))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, tempdb_allocations_delta), 1), 19)) '
											WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, tempdb_allocations_delta), 1), 19)) '
											ELSE 'tempdb_allocations_delta '
										END + 
								'ELSE NULL ' +
							'END AS tempdb_allocations_delta, ' +
							--tempdb_current_delta
							--this is the only one that can (legitimately) go negative 
							'CASE ' +
								'WHEN ' +
									'first_request_start_time = last_request_start_time ' + 
									'AND num_events = 2 ' +
										'THEN ' +
										CASE @format_output
											WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, tempdb_current_delta))) OVER() - LEN(CONVERT(VARCHAR, tempdb_current_delta))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, tempdb_current_delta), 1), 19)) '
											WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, tempdb_current_delta), 1), 19)) '
											ELSE 'tempdb_current_delta '
										END + 
								'ELSE NULL ' +
							'END AS tempdb_current_delta, ' +
							--CPU_delta
							'CASE ' +
								'WHEN ' +
									'first_request_start_time = last_request_start_time ' + 
									'AND num_events = 2 ' +
										'THEN ' +
											'CASE ' +
												'WHEN ' +
													'thread_CPU_delta > CPU_delta ' +
													'AND thread_CPU_delta > 0 ' +
														'THEN ' +
															CASE @format_output
																WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, thread_CPU_delta + CPU_delta))) OVER() - LEN(CONVERT(VARCHAR, thread_CPU_delta))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, thread_CPU_delta), 1), 19)) '
																WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, thread_CPU_delta), 1), 19)) '
																ELSE 'thread_CPU_delta '
															END + 
												'WHEN CPU_delta >= 0 THEN ' +
													CASE @format_output
														WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, thread_CPU_delta + CPU_delta))) OVER() - LEN(CONVERT(VARCHAR, CPU_delta))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, CPU_delta), 1), 19)) '
														WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, CPU_delta), 1), 19)) '
														ELSE 'CPU_delta '
													END + 
												'ELSE NULL ' +
											'END ' +
								'ELSE ' +
									'NULL ' +
							'END AS CPU_delta, ' +
							--context_switches_delta
							'CASE ' +
								'WHEN ' +
									'first_request_start_time = last_request_start_time ' + 
									'AND num_events = 2 ' +
									'AND context_switches_delta >= 0 ' +
										'THEN ' +
										CASE @format_output
											WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, context_switches_delta))) OVER() - LEN(CONVERT(VARCHAR, context_switches_delta))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, context_switches_delta), 1), 19)) '
											WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, context_switches_delta), 1), 19)) '
											ELSE 'context_switches_delta '
										END + 
								'ELSE NULL ' +
							'END AS context_switches_delta, ' +
							--used_memory_delta
							'CASE ' +
								'WHEN ' +
									'first_request_start_time = last_request_start_time ' + 
									'AND num_events = 2 ' +
									'AND used_memory_delta >= 0 ' +
										'THEN ' +
										CASE @format_output
											WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, used_memory_delta))) OVER() - LEN(CONVERT(VARCHAR, used_memory_delta))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, used_memory_delta), 1), 19)) '
											WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, used_memory_delta), 1), 19)) '
											ELSE 'used_memory_delta '
										END + 
								'ELSE NULL ' +
							'END AS used_memory_delta, '
						ELSE ''
					END +
					--tasks
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, tasks))) OVER() - LEN(CONVERT(VARCHAR, tasks))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, tasks), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, tasks), 1), 19)) '
						ELSE ''
					END + 'tasks, ' +
					'status, ' +
					'wait_info, ' +
					'locks, ' +
					'tran_start_time, ' +
					'LEFT(tran_log_writes, LEN(tran_log_writes) - 1) AS tran_log_writes, ' +
					--open_tran_count
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, open_tran_count))) OVER() - LEN(CONVERT(VARCHAR, open_tran_count))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, open_tran_count), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, open_tran_count), 1), 19)) AS '
						ELSE ''
					END + 'open_tran_count, ' +
					--sql_command
					CASE @format_output 
						WHEN 0 THEN 'REPLACE(REPLACE(CONVERT(NVARCHAR(MAX), sql_command), ''<?query --''+CHAR(13)+CHAR(10), ''''), CHAR(13)+CHAR(10)+''--?>'', '''') AS '
						ELSE ''
					END + 'sql_command, ' +
					--sql_text
					CASE @format_output 
						WHEN 0 THEN 'REPLACE(REPLACE(CONVERT(NVARCHAR(MAX), sql_text), ''<?query --''+CHAR(13)+CHAR(10), ''''), CHAR(13)+CHAR(10)+''--?>'', '''') AS '
						ELSE ''
					END + 'sql_text, ' +
					'query_plan, ' +
					'blocking_session_id, ' +
					--blocked_session_count
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, blocked_session_count))) OVER() - LEN(CONVERT(VARCHAR, blocked_session_count))) + LEFT(CONVERT(CHAR(22), CONVERT(MONEY, blocked_session_count), 1), 19)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, LEFT(CONVERT(CHAR(22), CONVERT(MONEY, blocked_session_count), 1), 19)) AS '
						ELSE ''
					END + 'blocked_session_count, ' +
					--percent_complete
					CASE @format_output
						WHEN 1 THEN 'CONVERT(VARCHAR, SPACE(MAX(LEN(CONVERT(VARCHAR, CONVERT(MONEY, percent_complete), 2))) OVER() - LEN(CONVERT(VARCHAR, CONVERT(MONEY, percent_complete), 2))) + CONVERT(CHAR(22), CONVERT(MONEY, percent_complete), 2)) AS '
						WHEN 2 THEN 'CONVERT(VARCHAR, CONVERT(CHAR(22), CONVERT(MONEY, blocked_session_count), 1)) AS '
						ELSE ''
					END + 'percent_complete, ' +
					'host_name, ' +
					'login_name, ' +
					'database_name, ' +
					'program_name, ' +
					'additional_info, ' +
					'start_time, ' +
					'login_time, ' +
					'CASE ' +
						'WHEN status = N''sleeping'' THEN NULL ' +
						'ELSE request_id ' +
					'END AS request_id, ' +
					'GETDATE() AS collection_time '
		--End inner column list
		) +
		--Derived table and INSERT specification
		CONVERT
		(
			VARCHAR(MAX),
				'FROM ' +
				'( ' +
					'SELECT TOP(2147483647) ' +
						'*, ' +
						'CASE ' +
							'MAX ' +
							'( ' +
								'LEN ' +
								'( ' +
									'CONVERT ' +
									'( ' +
										'VARCHAR, ' +
										'CASE ' +
											'WHEN elapsed_time < 0 THEN ' +
												'(-1 * elapsed_time) / 86400 ' +
											'ELSE ' +
												'elapsed_time / 86400000 ' +
										'END ' +
									') ' +
								') ' +
							') OVER () ' +
								'WHEN 1 THEN 2 ' +
								'ELSE ' +
									'MAX ' +
									'( ' +
										'LEN ' +
										'( ' +
											'CONVERT ' +
											'( ' +
												'VARCHAR, ' +
												'CASE ' +
													'WHEN elapsed_time < 0 THEN ' +
														'(-1 * elapsed_time) / 86400 ' +
													'ELSE ' +
														'elapsed_time / 86400000 ' +
												'END ' +
											') ' +
										') ' +
									') OVER () ' +
						'END AS max_elapsed_length, ' +
						CASE
							WHEN @output_column_list LIKE '%|_delta|]%' ESCAPE '|' THEN
								'MAX(physical_io * recursion) OVER (PARTITION BY session_id, request_id) + ' +
									'MIN(physical_io * recursion) OVER (PARTITION BY session_id, request_id) AS physical_io_delta, ' +
								'MAX(reads * recursion) OVER (PARTITION BY session_id, request_id) + ' +
									'MIN(reads * recursion) OVER (PARTITION BY session_id, request_id) AS reads_delta, ' +
								'MAX(physical_reads * recursion) OVER (PARTITION BY session_id, request_id) + ' +
									'MIN(physical_reads * recursion) OVER (PARTITION BY session_id, request_id) AS physical_reads_delta, ' +
								'MAX(writes * recursion) OVER (PARTITION BY session_id, request_id) + ' +
									'MIN(writes * recursion) OVER (PARTITION BY session_id, request_id) AS writes_delta, ' +
								'MAX(tempdb_allocations * recursion) OVER (PARTITION BY session_id, request_id) + ' +
									'MIN(tempdb_allocations * recursion) OVER (PARTITION BY session_id, request_id) AS tempdb_allocations_delta, ' +
								'MAX(tempdb_current * recursion) OVER (PARTITION BY session_id, request_id) + ' +
									'MIN(tempdb_current * recursion) OVER (PARTITION BY session_id, request_id) AS tempdb_current_delta, ' +
								'MAX(CPU * recursion) OVER (PARTITION BY session_id, request_id) + ' +
									'MIN(CPU * recursion) OVER (PARTITION BY session_id, request_id) AS CPU_delta, ' +
								'MAX(thread_CPU_snapshot * recursion) OVER (PARTITION BY session_id, request_id) + ' +
									'MIN(thread_CPU_snapshot * recursion) OVER (PARTITION BY session_id, request_id) AS thread_CPU_delta, ' +
								'MAX(context_switches * recursion) OVER (PARTITION BY session_id, request_id) + ' +
									'MIN(context_switches * recursion) OVER (PARTITION BY session_id, request_id) AS context_switches_delta, ' +
								'MAX(used_memory * recursion) OVER (PARTITION BY session_id, request_id) + ' +
									'MIN(used_memory * recursion) OVER (PARTITION BY session_id, request_id) AS used_memory_delta, ' +
								'MIN(last_request_start_time) OVER (PARTITION BY session_id, request_id) AS first_request_start_time, '
							ELSE ''
						END +
						'COUNT(*) OVER (PARTITION BY session_id, request_id) AS num_events ' +
					'FROM #sessions AS s1 ' +
					CASE 
						WHEN @sort_order = '' THEN ''
						ELSE
							'ORDER BY ' +
								@sort_order
					END +
				') AS s ' +
				'WHERE ' +
					's.recursion = 1 ' +
			') x ' +
			'OPTION (KEEPFIXED PLAN); ' +
			'' +
			CASE @return_schema
				WHEN 1 THEN
					'SET @schema = ' +
						'''CREATE TABLE <table_name> ( '' + ' +
							'STUFF ' +
							'( ' +
								'( ' +
									'SELECT ' +
										''','' + ' +
										'QUOTENAME(COLUMN_NAME) + '' '' + ' +
										'DATA_TYPE + ' + 
										'CASE ' +
											'WHEN DATA_TYPE LIKE ''%char'' THEN ''('' + COALESCE(NULLIF(CONVERT(VARCHAR, CHARACTER_MAXIMUM_LENGTH), ''-1''), ''max'') + '') '' ' +
											'ELSE '' '' ' +
										'END + ' +
										'CASE IS_NULLABLE ' +
											'WHEN ''NO'' THEN ''NOT '' ' +
											'ELSE '''' ' +
										'END + ''NULL'' AS [text()] ' +
									'FROM tempdb.INFORMATION_SCHEMA.COLUMNS ' +
									'WHERE ' +
										'TABLE_NAME = (SELECT name FROM tempdb.sys.objects WHERE object_id = OBJECT_ID(''tempdb..#session_schema'')) ' +
										'ORDER BY ' +
											'ORDINAL_POSITION ' +
									'FOR XML ' +
										'PATH('''') ' +
								'), + ' +
								'1, ' +
								'1, ' +
								''''' ' +
							') + ' +
						''')''; ' 
				ELSE ''
			END
		--End derived table and INSERT specification
		);

	SET @sql_n = CONVERT(NVARCHAR(MAX), @sql);

	EXEC sp_executesql
		@sql_n,
		N'@schema VARCHAR(MAX) OUTPUT',
		@schema OUTPUT;
END;
GO



USE tempdb
GO

IF OBJECT_ID('dbo.sp_BlitzWho') IS NULL
	EXEC ('CREATE PROCEDURE dbo.sp_BlitzWho AS RETURN 0;')
GO

ALTER PROCEDURE [dbo].[sp_BlitzWho] 
	@Help TINYINT = 0
AS
BEGIN
	SET NOCOUNT ON;
	SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

	IF @Help = 1
		PRINT '
sp_BlitzWho from http://FirstResponderKit.org

This script gives you a snapshot of everything currently executing on your SQL Server.

To learn more, visit http://FirstResponderKit.org where you can download new
versions for free, watch training videos on how it works, get more info on
the findings, contribute your own code, and more.

Known limitations of this version:
 - Only Microsoft-supported versions of SQL Server. Sorry, 2005 and 2000.
   
MIT License

Copyright (c) 2016 Brent Ozar Unlimited

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
';

/* Get the major and minor build numbers */
DECLARE  @ProductVersion NVARCHAR(128)
		,@ProductVersionMajor DECIMAL(10,2)
		,@ProductVersionMinor DECIMAL(10,2)
		,@EnhanceFlag BIT = 0
		,@StringToExecute NVARCHAR(MAX)
		,@EnhanceSQL NVARCHAR(MAX) = 
					N'[query_stats].last_dop,
					  [query_stats].min_dop,
					  [query_stats].max_dop,
					  [query_stats].last_grant_kb,
					  [query_stats].min_grant_kb,
					  [query_stats].max_grant_kb,
					  [query_stats].last_used_grant_kb,
					  [query_stats].min_used_grant_kb,
					  [query_stats].max_used_grant_kb,
					  [query_stats].last_ideal_grant_kb,
					  [query_stats].min_ideal_grant_kb,
					  [query_stats].max_ideal_grant_kb,
					  [query_stats].last_reserved_threads,
					  [query_stats].min_reserved_threads,
					  [query_stats].max_reserved_threads,
					  [query_stats].last_used_threads,
					  [query_stats].min_used_threads,
					  [query_stats].max_used_threads,'

SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128));
SELECT @ProductVersionMajor = SUBSTRING(@ProductVersion, 1,CHARINDEX('.', @ProductVersion) + 1 ),
@ProductVersionMinor = PARSENAME(CONVERT(VARCHAR(32), @ProductVersion), 2)



IF @ProductVersionMajor > 9 and @ProductVersionMajor < 11
BEGIN
SET @StringToExecute = N'
					    SELECT  GETDATE() AS [run_date] ,
			            CONVERT(VARCHAR, DATEADD(ms, [r].[total_elapsed_time], 0), 114) AS [elapsed_time] ,
			            [s].[session_id] ,
						DB_NAME(s.database_id) AS database_name,
			            [wt].[wait_info] ,
			            [s].[status] ,
			            ISNULL(SUBSTRING([dest].[text],
			                             ( [query_stats].[statement_start_offset] / 2 ) + 1,
			                             ( ( CASE [query_stats].[statement_end_offset]
			                                   WHEN -1 THEN DATALENGTH([dest].[text])
			                                   ELSE [query_stats].[statement_end_offset]
			                                 END - [query_stats].[statement_start_offset] )
			                               / 2 ) + 1), [dest].[text]) AS [query_text] ,
			            [derp].[query_plan] ,
			            [qmg].[query_cost] ,
					    [r].[blocking_session_id] ,
			            [r].[cpu_time] AS [request_cpu_time],
			            [r].[logical_reads] AS [request_logical_reads],
			            [r].[writes] AS [request_writes],
			            [r].[reads] AS [request_physical_reads] ,
			            [s].[cpu_time] AS [session_cpu],
			            [s].[logical_reads] AS [session_logical_reads],
			            [s].[reads] AS [session_physical_reads] ,
			            [s].[writes] AS [session_writes],
			            [s].[memory_usage] ,
			            [r].[estimated_completion_time] ,
			            [r].[deadlock_priority] ,
			            CASE 
			              WHEN [s].[transaction_isolation_level] = 0 THEN ''Unspecified''
			              WHEN [s].[transaction_isolation_level] = 1 THEN ''Read Uncommitted''
			              WHEN [s].[transaction_isolation_level] = 2 AND EXISTS (SELECT 1 FROM [sys].[dm_tran_active_snapshot_database_transactions] AS [trn] WHERE [s].[session_id] = [trn].[session_id] AND [is_snapshot] = 0 ) THEN ''Read Committed Snapshot Isolation''
						  WHEN [s].[transaction_isolation_level] = 2 AND NOT EXISTS (SELECT 1 FROM [sys].[dm_tran_active_snapshot_database_transactions] AS [trn] WHERE [s].[session_id] = [trn].[session_id] AND [is_snapshot] = 0 ) THEN ''Read Committed''
			              WHEN [s].[transaction_isolation_level] = 3 THEN ''Repeatable Read''
			              WHEN [s].[transaction_isolation_level] = 4 THEN ''Serializable''
			              WHEN [s].[transaction_isolation_level] = 5 THEN ''Snapshot''
			              ELSE ''WHAT HAVE YOU DONE?''
			            END AS [transaction_isolation_level] ,
			            [r].[open_transaction_count] ,
			            [qmg].[dop] AS [degree_of_parallelism] ,
			            [qmg].[request_time] ,
			            COALESCE(CAST([qmg].[grant_time] AS VARCHAR), ''N/A'') AS [grant_time] ,
			            [qmg].[requested_memory_kb] ,
			            [qmg].[granted_memory_kb] AS [grant_memory_kb],
			            CASE WHEN [qmg].[grant_time] IS NULL THEN ''N/A''
                             WHEN [qmg].[requested_memory_kb] < [qmg].[granted_memory_kb]
			                 THEN ''Query Granted Less Than Query Requested''
			                 ELSE ''Memory Request Granted''
			            END AS [is_request_granted] ,
			            [qmg].[required_memory_kb] ,
			            [qmg].[used_memory_kb] ,
			            [qmg].[ideal_memory_kb] ,
			            [qmg].[is_small] ,
			            [qmg].[timeout_sec] ,
			            [qmg].[resource_semaphore_id] ,
			            COALESCE(CAST([qmg].[wait_order] AS VARCHAR), ''N/A'') AS [wait_order] ,
			            COALESCE(CAST([qmg].[wait_time_ms] AS VARCHAR),
			                     ''N/A'') AS [wait_time_ms] ,
			            CASE [qmg].[is_next_candidate]
			              WHEN 0 THEN ''No''
			              WHEN 1 THEN ''Yes''
			              ELSE ''N/A''
			            END AS [next_candidate_for_memory_grant] ,
			            [qrs].[target_memory_kb] ,
			            COALESCE(CAST([qrs].[max_target_memory_kb] AS VARCHAR),
			                     ''Small Query Resource Semaphore'') AS [max_target_memory_kb] ,
			            [qrs].[total_memory_kb] ,
			            [qrs].[available_memory_kb] ,
			            [qrs].[granted_memory_kb] ,
			            [qrs].[used_memory_kb] ,
			            [qrs].[grantee_count] ,
			            [qrs].[waiter_count] ,
			            [qrs].[timeout_error_count] ,
			            COALESCE(CAST([qrs].[forced_grant_count] AS VARCHAR),
			                     ''Small Query Resource Semaphore'') AS [forced_grant_count],
					    [s].[nt_domain] ,
			            [s].[host_name] ,
			            [s].[login_name] ,
			            [s].[nt_user_name] ,
			            [s].[program_name] ,
			            [s].[client_interface_name] ,
			            [s].[login_time] ,
			            [r].[start_time] 
			    FROM    [sys].[dm_exec_sessions] AS [s]
			    INNER JOIN    [sys].[dm_exec_requests] AS [r]
			    ON      [r].[session_id] = [s].[session_id]
			    LEFT JOIN ( SELECT DISTINCT
			                        [wait].[session_id] ,
			                        ( SELECT    [waitwait].[wait_type] + N'' (''
			                                    + CAST(SUM([waitwait].[wait_duration_ms]) AS NVARCHAR(128))
			                                    + N'' ms) ''
			                          FROM      [sys].[dm_os_waiting_tasks] AS [waitwait]
			                          WHERE     [waitwait].[session_id] = [wait].[session_id]
			                          GROUP BY  [waitwait].[wait_type]
			                          ORDER BY  SUM([waitwait].[wait_duration_ms]) DESC
			                        FOR
			                          XML PATH('''') ) AS [wait_info]
			                FROM    [sys].[dm_os_waiting_tasks] AS [wait] ) AS [wt]
			    ON      [s].[session_id] = [wt].[session_id]
			    LEFT JOIN [sys].[dm_exec_query_stats] AS [query_stats]
			    ON      [r].[sql_handle] = [query_stats].[sql_handle]
						AND [r].[plan_handle] = [query_stats].[plan_handle]
			            AND [r].[statement_start_offset] = [query_stats].[statement_start_offset]
			            AND [r].[statement_end_offset] = [query_stats].[statement_end_offset]
			    LEFT JOIN [sys].[dm_exec_query_memory_grants] [qmg]
			    ON      [r].[session_id] = [qmg].[session_id]
						AND [r].[request_id] = [qmg].[request_id]
			    LEFT JOIN [sys].[dm_exec_query_resource_semaphores] [qrs]
			    ON      [qmg].[resource_semaphore_id] = [qrs].[resource_semaphore_id]
					    AND [qmg].[pool_id] = [qrs].[pool_id]
			    OUTER APPLY [sys].[dm_exec_sql_text]([r].[sql_handle]) AS [dest]
			    OUTER APPLY [sys].[dm_exec_query_plan]([r].[plan_handle]) AS [derp]
			    WHERE   [r].[session_id] <> @@SPID
			            AND [s].[status] <> ''sleeping''
			    ORDER BY 2 DESC;
			    '
END
IF @ProductVersionMajor >= 11 
BEGIN
SELECT @EnhanceFlag = 
	    CASE WHEN @ProductVersionMajor = 11 AND @ProductVersionMinor >= 6020 THEN 1
		     WHEN @ProductVersionMajor = 12 AND @ProductVersionMinor >= 5000 THEN 1
		     WHEN @ProductVersionMajor = 13 AND	@ProductVersionMinor >= 1601 THEN 1
		     ELSE 0 
	    END

SELECT @StringToExecute = N'
					    SELECT  GETDATE() AS [run_date] ,
			            CONVERT(VARCHAR, DATEADD(ms, [r].[total_elapsed_time], 0), 114) AS [elapsed_time] ,
			            [s].[session_id] ,
						DB_NAME(s.database_id) AS database_name,
			            [wt].[wait_info] ,
			            [s].[status] ,
			            ISNULL(SUBSTRING([dest].[text],
			                             ( [query_stats].[statement_start_offset] / 2 ) + 1,
			                             ( ( CASE [query_stats].[statement_end_offset]
			                                   WHEN -1 THEN DATALENGTH([dest].[text])
			                                   ELSE [query_stats].[statement_end_offset]
			                                 END - [query_stats].[statement_start_offset] )
			                               / 2 ) + 1), [dest].[text]) AS [query_text] ,
			            [derp].[query_plan] ,
			            [qmg].[query_cost] ,
					    [r].[blocking_session_id] ,
			            [r].[cpu_time] AS [request_cpu_time],
			            [r].[logical_reads] AS [request_logical_reads],
			            [r].[writes] AS [request_writes],
			            [r].[reads] AS [request_physical_reads] ,
			            [s].[cpu_time] AS [session_cpu],
			            [s].[logical_reads] AS [session_logical_reads],
			            [s].[reads] AS [session_physical_reads] ,
			            [s].[writes] AS [session_writes],
			            [s].[memory_usage] ,
			            [r].[estimated_completion_time] ,
			            [r].[deadlock_priority] ,'
					    + 
					    CASE @EnhanceFlag
					    WHEN 1 THEN @EnhanceSQL
					    ELSE N'' END +
					    N'CASE 
			              WHEN [s].[transaction_isolation_level] = 0 THEN ''Unspecified''
			              WHEN [s].[transaction_isolation_level] = 1 THEN ''Read Uncommitted''
			              WHEN [s].[transaction_isolation_level] = 2 AND EXISTS (SELECT 1 FROM [sys].[dm_tran_active_snapshot_database_transactions] AS [trn] WHERE [s].[session_id] = [trn].[session_id] AND [is_snapshot] = 0 ) THEN ''Read Committed Snapshot Isolation''
						  WHEN [s].[transaction_isolation_level] = 2 AND NOT EXISTS (SELECT 1 FROM [sys].[dm_tran_active_snapshot_database_transactions] AS [trn] WHERE [s].[session_id] = [trn].[session_id] AND [is_snapshot] = 0 ) THEN ''Read Committed''
			              WHEN [s].[transaction_isolation_level] = 3 THEN ''Repeatable Read''
			              WHEN [s].[transaction_isolation_level] = 4 THEN ''Serializable''
			              WHEN [s].[transaction_isolation_level] = 5 THEN ''Snapshot''
			              ELSE ''WHAT HAVE YOU DONE?''
			            END AS [transaction_isolation_level] ,
			            [r].[open_transaction_count] ,
			            [qmg].[dop] AS [degree_of_parallelism] ,
			            [qmg].[request_time] ,
			            COALESCE(CAST([qmg].[grant_time] AS VARCHAR), ''Memory Not Granted'') AS [grant_time] ,
			            [qmg].[requested_memory_kb] ,
			            [qmg].[granted_memory_kb] AS [grant_memory_kb],
			            CASE WHEN [qmg].[grant_time] IS NULL THEN ''N/A''
                             WHEN [qmg].[requested_memory_kb] < [qmg].[granted_memory_kb]
			                 THEN ''Query Granted Less Than Query Requested''
			                 ELSE ''Memory Request Granted''
			            END AS [is_request_granted] ,
			            [qmg].[required_memory_kb] ,
			            [qmg].[used_memory_kb] ,
			            [qmg].[ideal_memory_kb] ,
			            [qmg].[is_small] ,
			            [qmg].[timeout_sec] ,
			            [qmg].[resource_semaphore_id] ,
			            COALESCE(CAST([qmg].[wait_order] AS VARCHAR), ''N/A'') AS [wait_order] ,
			            COALESCE(CAST([qmg].[wait_time_ms] AS VARCHAR),
			                     ''N/A'') AS [wait_time_ms] ,
			            CASE [qmg].[is_next_candidate]
			              WHEN 0 THEN ''No''
			              WHEN 1 THEN ''Yes''
			              ELSE ''N/A''
			            END AS [next_candidate_for_memory_grant] ,
			            [qrs].[target_memory_kb] ,
			            COALESCE(CAST([qrs].[max_target_memory_kb] AS VARCHAR),
			                     ''Small Query Resource Semaphore'') AS [max_target_memory_kb] ,
			            [qrs].[total_memory_kb] ,
			            [qrs].[available_memory_kb] ,
			            [qrs].[granted_memory_kb] ,
			            [qrs].[used_memory_kb] ,
			            [qrs].[grantee_count] ,
			            [qrs].[waiter_count] ,
			            [qrs].[timeout_error_count] ,
			            COALESCE(CAST([qrs].[forced_grant_count] AS VARCHAR),
			                     ''Small Query Resource Semaphore'') AS [forced_grant_count],
					    [s].[nt_domain] ,
			            [s].[host_name] ,
			            [s].[login_name] ,
			            [s].[nt_user_name] ,
			            [s].[program_name] ,
			            [s].[client_interface_name] ,
			            [s].[login_time] ,
			            [r].[start_time] 
			    FROM    [sys].[dm_exec_sessions] AS [s]
			    INNER JOIN    [sys].[dm_exec_requests] AS [r]
			    ON      [r].[session_id] = [s].[session_id]
			    LEFT JOIN ( SELECT DISTINCT
			                        [wait].[session_id] ,
			                        ( SELECT    [waitwait].[wait_type] + N'' (''
			                                    + CAST(SUM([waitwait].[wait_duration_ms]) AS NVARCHAR(128))
			                                    + N'' ms) ''
			                          FROM      [sys].[dm_os_waiting_tasks] AS [waitwait]
			                          WHERE     [waitwait].[session_id] = [wait].[session_id]
			                          GROUP BY  [waitwait].[wait_type]
			                          ORDER BY  SUM([waitwait].[wait_duration_ms]) DESC
			                        FOR
			                          XML PATH('''') ) AS [wait_info]
			                FROM    [sys].[dm_os_waiting_tasks] AS [wait] ) AS [wt]
			    ON      [s].[session_id] = [wt].[session_id]
			    LEFT JOIN [sys].[dm_exec_query_stats] AS [query_stats]
			    ON      [r].[sql_handle] = [query_stats].[sql_handle]
						AND [r].[plan_handle] = [query_stats].[plan_handle]
			            AND [r].[statement_start_offset] = [query_stats].[statement_start_offset]
			            AND [r].[statement_end_offset] = [query_stats].[statement_end_offset]
			    LEFT JOIN [sys].[dm_exec_query_memory_grants] [qmg]
			    ON      [r].[session_id] = [qmg].[session_id]
						AND [r].[request_id] = [qmg].[request_id]
			    LEFT JOIN [sys].[dm_exec_query_resource_semaphores] [qrs]
			    ON      [qmg].[resource_semaphore_id] = [qrs].[resource_semaphore_id]
					    AND [qmg].[pool_id] = [qrs].[pool_id]
			    OUTER APPLY [sys].[dm_exec_sql_text]([r].[sql_handle]) AS [dest]
			    OUTER APPLY [sys].[dm_exec_query_plan]([r].[plan_handle]) AS [derp]
			    WHERE   [r].[session_id] <> @@SPID
			            AND [s].[status] <> ''sleeping''
			    ORDER BY 2 DESC;
			    '

END 

EXEC(@StringToExecute);

END
GO




USE [tempdb];
GO

IF OBJECT_ID('dbo.sp_foreachdb') IS NOT NULL
    DROP PROCEDURE dbo.sp_foreachdb
GO

CREATE PROCEDURE dbo.sp_foreachdb
    @command NVARCHAR(MAX) ,
    @replace_character NCHAR(1) = N'?' ,
    @print_dbname BIT = 0 ,
    @print_command_only BIT = 0 ,
    @suppress_quotename BIT = 0 ,
    @system_only BIT = NULL ,
    @user_only BIT = NULL ,
    @name_pattern NVARCHAR(300) = N'%' ,
    @database_list NVARCHAR(MAX) = NULL ,
    @exclude_list NVARCHAR(MAX) = NULL ,
    @recovery_model_desc NVARCHAR(120) = NULL ,
    @compatibility_level TINYINT = NULL ,
    @state_desc NVARCHAR(120) = N'ONLINE' ,
    @is_read_only BIT = 0 ,
    @is_auto_close_on BIT = NULL ,
    @is_auto_shrink_on BIT = NULL ,
    @is_broker_enabled BIT = NULL
AS
    BEGIN
        SET NOCOUNT ON;

        DECLARE @sql NVARCHAR(MAX) ,
            @dblist NVARCHAR(MAX) ,
            @exlist NVARCHAR(MAX) ,
            @db NVARCHAR(300) ,
            @i INT;

        IF @database_list > N''
            BEGIN
       ;
                WITH    n ( n )
                          AS ( SELECT   ROW_NUMBER() OVER ( ORDER BY s1.name )
                                        - 1
                               FROM     sys.objects AS s1
                                        CROSS JOIN sys.objects AS s2
                             )
                    SELECT  @dblist = REPLACE(REPLACE(REPLACE(x, '</x><x>',
                                                              ','), '</x>', ''),
                                              '<x>', '')
                    FROM    ( SELECT DISTINCT
                                        x = 'N'''
                                        + LTRIM(RTRIM(SUBSTRING(@database_list,
                                                              n,
                                                              CHARINDEX(',',
                                                              @database_list
                                                              + ',', n) - n)))
                                        + ''''
                              FROM      n
                              WHERE     n <= LEN(@database_list)
                                        AND SUBSTRING(',' + @database_list, n,
                                                      1) = ','
                            FOR
                              XML PATH('')
                            ) AS y ( x );
            END
-- Added for @exclude_list
        IF @exclude_list > N''
            BEGIN
       ;
                WITH    n ( n )
                          AS ( SELECT   ROW_NUMBER() OVER ( ORDER BY s1.name )
                                        - 1
                               FROM     sys.objects AS s1
                                        CROSS JOIN sys.objects AS s2
                             )
                    SELECT  @exlist = REPLACE(REPLACE(REPLACE(x, '</x><x>',
                                                              ','), '</x>', ''),
                                              '<x>', '')
                    FROM    ( SELECT DISTINCT
                                        x = 'N'''
                                        + LTRIM(RTRIM(SUBSTRING(@exclude_list,
                                                              n,
                                                              CHARINDEX(',',
                                                              @exclude_list
                                                              + ',', n) - n)))
                                        + ''''
                              FROM      n
                              WHERE     n <= LEN(@exclude_list)
                                        AND SUBSTRING(',' + @exclude_list, n,
                                                      1) = ','
                            FOR
                              XML PATH('')
                            ) AS y ( x );
            END

        CREATE TABLE #x ( db NVARCHAR(300) );

        SET @sql = N'SELECT name FROM sys.databases WHERE 1=1'
            + CASE WHEN @system_only = 1 THEN ' AND database_id IN (1,2,3,4)'
                   ELSE ''
              END
            + CASE WHEN @user_only = 1
                   THEN ' AND database_id NOT IN (1,2,3,4)'
                   ELSE ''
              END
-- To exclude databases from changes	
            + CASE WHEN @exlist IS NOT NULL
                   THEN ' AND name NOT IN (' + @exlist + ')'
                   ELSE ''
              END + CASE WHEN @name_pattern <> N'%'
                         THEN ' AND name LIKE N''%' + REPLACE(@name_pattern,
                                                              '''', '''''')
                              + '%'''
                         ELSE ''
                    END + CASE WHEN @dblist IS NOT NULL
                               THEN ' AND name IN (' + @dblist + ')'
                               ELSE ''
                          END
            + CASE WHEN @recovery_model_desc IS NOT NULL
                   THEN ' AND recovery_model_desc = N'''
                        + @recovery_model_desc + ''''
                   ELSE ''
              END
            + CASE WHEN @compatibility_level IS NOT NULL
                   THEN ' AND compatibility_level = '
                        + RTRIM(@compatibility_level)
                   ELSE ''
              END
            + CASE WHEN @state_desc IS NOT NULL
                   THEN ' AND state_desc = N''' + @state_desc + ''''
                   ELSE ''
              END
            + CASE WHEN @is_read_only IS NOT NULL
                   THEN ' AND is_read_only = ' + RTRIM(@is_read_only)
                   ELSE ''
              END
            + CASE WHEN @is_auto_close_on IS NOT NULL
                   THEN ' AND is_auto_close_on = ' + RTRIM(@is_auto_close_on)
                   ELSE ''
              END
            + CASE WHEN @is_auto_shrink_on IS NOT NULL
                   THEN ' AND is_auto_shrink_on = ' + RTRIM(@is_auto_shrink_on)
                   ELSE ''
              END
            + CASE WHEN @is_broker_enabled IS NOT NULL
                   THEN ' AND is_broker_enabled = ' + RTRIM(@is_broker_enabled)
                   ELSE ''
              END;

        INSERT  #x
                EXEC sp_executesql @sql;

        DECLARE c CURSOR LOCAL FORWARD_ONLY STATIC READ_ONLY
        FOR
            SELECT  CASE WHEN @suppress_quotename = 1 THEN db
                         ELSE QUOTENAME(db)
                    END
            FROM    #x
            ORDER BY db;

        OPEN c;

        FETCH NEXT FROM c INTO @db;

        WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @sql = REPLACE(@command, @replace_character, @db);

                IF @print_command_only = 1
                    BEGIN
                        PRINT '/* For ' + @db + ': */' + CHAR(13) + CHAR(10)
                            + CHAR(13) + CHAR(10) + @sql + CHAR(13) + CHAR(10)
                            + CHAR(13) + CHAR(10);
                    END
                ELSE
                    BEGIN
                        IF @print_dbname = 1
                            BEGIN
                                PRINT '/* ' + @db + ' */';
                            END

                        EXEC sp_executesql @sql;
                    END

                FETCH NEXT FROM c INTO @db;
            END

        CLOSE c;
        DEALLOCATE c;
    END
GO



USE tempdb
GO

IF OBJECT_ID('dbo.sp_Blitz') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_Blitz AS RETURN 0;')
GO

ALTER PROCEDURE [dbo].[sp_Blitz]
    @Help TINYINT = 0 ,
    @CheckUserDatabaseObjects TINYINT = 1 ,
    @CheckProcedureCache TINYINT = 0 ,
    @OutputType VARCHAR(20) = 'TABLE' ,
    @OutputProcedureCache TINYINT = 0 ,
    @CheckProcedureCacheFilter VARCHAR(10) = NULL ,
    @CheckServerInfo TINYINT = 0 ,
    @SkipChecksServer NVARCHAR(256) = NULL ,
    @SkipChecksDatabase NVARCHAR(256) = NULL ,
    @SkipChecksSchema NVARCHAR(256) = NULL ,
    @SkipChecksTable NVARCHAR(256) = NULL ,
    @IgnorePrioritiesBelow INT = NULL ,
    @IgnorePrioritiesAbove INT = NULL ,
    @OutputServerName NVARCHAR(256) = NULL ,
    @OutputDatabaseName NVARCHAR(256) = NULL ,
    @OutputSchemaName NVARCHAR(256) = NULL ,
    @OutputTableName NVARCHAR(256) = NULL ,
    @OutputXMLasNVARCHAR TINYINT = 0 ,
    @EmailRecipients VARCHAR(MAX) = NULL ,
    @EmailProfile sysname = NULL ,
    @SummaryMode TINYINT = 0 ,
    @BringThePain TINYINT = 0 ,
    @VersionDate DATETIME = NULL OUTPUT
AS
    SET NOCOUNT ON;
	SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
	SET @VersionDate = '20161210';
	SET @OutputType = UPPER(@OutputType);

	IF @Help = 1 PRINT '
	/*
	sp_Blitz from http://FirstResponderKit.org
	
	This script checks the health of your SQL Server and gives you a prioritized
	to-do list of the most urgent things you should consider fixing.

	To learn more, visit http://FirstResponderKit.org where you can download new
	versions for free, watch training videos on how it works, get more info on
	the findings, contribute your own code, and more.

	Known limitations of this version:
	 - Only Microsoft-supported versions of SQL Server. Sorry, 2005 and 2000.
	 - If a database name has a question mark in it, some tests will fail. Gotta
	   love that unsupported sp_MSforeachdb.
	 - If you have offline databases, sp_Blitz fails the first time you run it,
	   but does work the second time. (Hoo, boy, this will be fun to debug.)
      - @OutputServerName will output QueryPlans as NVARCHAR(MAX) since Microsoft
	    has refused to support XML columns in Linked Server queries. The bug is now
		16 years old! *~ \o/ ~*

	Unknown limitations of this version:
	 - None.  (If we knew them, they would be known. Duh.)

     Changes - for the full list of improvements and fixes in this version, see:
     https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/


	Parameter explanations:

	@CheckUserDatabaseObjects	1=review user databases for triggers, heaps, etc. Takes more time for more databases and objects.
	@CheckServerInfo			1=show server info like CPUs, memory, virtualization
	@CheckProcedureCache		1=top 20-50 resource-intensive cache plans and analyze them for common performance issues.
	@OutputProcedureCache		1=output the top 20-50 resource-intensive plans even if they did not trigger an alarm
	@CheckProcedureCacheFilter	''CPU'' | ''Reads'' | ''Duration'' | ''ExecCount''
	@OutputType					''TABLE''=table | ''COUNT''=row with number found | ''MARKDOWN''=bulleted list | ''SCHEMA''=version and field list | ''NONE'' = none
	@IgnorePrioritiesBelow		50=ignore priorities below 50
	@IgnorePrioritiesAbove		50=ignore priorities above 50
	For the rest of the parameters, see http://www.brentozar.com/blitz/documentation for details.

    MIT License

	Copyright (c) 2016 Brent Ozar Unlimited

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.


	*/'
	ELSE IF @OutputType = 'SCHEMA'
	BEGIN
		SELECT FieldList = '[Priority] TINYINT, [FindingsGroup] VARCHAR(50), [Finding] VARCHAR(200), [DatabaseName] NVARCHAR(128), [URL] VARCHAR(200), [Details] NVARCHAR(4000), [QueryPlan] NVARCHAR(MAX), [QueryPlanFiltered] NVARCHAR(MAX), [CheckID] INT'

	END
	ELSE /* IF @OutputType = 'SCHEMA' */
	BEGIN

		/*
		We start by creating #BlitzResults. It's a temp table that will store all of
		the results from our checks. Throughout the rest of this stored procedure,
		we're running a series of checks looking for dangerous things inside the SQL
		Server. When we find a problem, we insert rows into #BlitzResults. At the
		end, we return these results to the end user.

		#BlitzResults has a CheckID field, but there's no Check table. As we do
		checks, we insert data into this table, and we manually put in the CheckID.
		For a list of checks, visit http://FirstResponderKit.org.
		*/
		DECLARE @StringToExecute NVARCHAR(4000)
			,@curr_tracefilename NVARCHAR(500)
			,@base_tracefilename NVARCHAR(500)
			,@indx int
			,@query_result_separator CHAR(1)
			,@EmailSubject NVARCHAR(255)
			,@EmailBody NVARCHAR(MAX)
			,@EmailAttachmentFilename NVARCHAR(255)
			,@ProductVersion NVARCHAR(128)
			,@ProductVersionMajor DECIMAL(10,2)
			,@ProductVersionMinor DECIMAL(10,2)
			,@CurrentName NVARCHAR(128)
			,@CurrentDefaultValue NVARCHAR(200)
			,@CurrentCheckID INT
			,@CurrentPriority INT
			,@CurrentFinding VARCHAR(200)
			,@CurrentURL VARCHAR(200)
			,@CurrentDetails NVARCHAR(4000)
			,@MsSinceWaitsCleared DECIMAL(38,0)
			,@CpuMsSinceWaitsCleared DECIMAL(38,0)
			,@ResultText NVARCHAR(MAX)
			,@crlf NVARCHAR(2)
			,@Processors int
			,@NUMANodes int
			,@MinServerMemory bigint
			,@MaxServerMemory bigint
			,@ColumnStoreIndexesInUse bit;


		SET @crlf = NCHAR(13) + NCHAR(10);
		SET @ResultText = 'sp_Blitz Results: ' + @crlf;
		
		IF OBJECT_ID('tempdb..#BlitzResults') IS NOT NULL
			DROP TABLE #BlitzResults;
		CREATE TABLE #BlitzResults
			(
			  ID INT IDENTITY(1, 1) ,
			  CheckID INT ,
			  DatabaseName NVARCHAR(128) ,
			  Priority TINYINT ,
			  FindingsGroup VARCHAR(50) ,
			  Finding VARCHAR(200) ,
			  URL VARCHAR(200) ,
			  Details NVARCHAR(4000) ,
			  QueryPlan [XML] NULL ,
			  QueryPlanFiltered [NVARCHAR](MAX) NULL
			);

		IF OBJECT_ID('tempdb..#TemporaryDatabaseResults') IS NOT NULL
			DROP TABLE #TemporaryDatabaseResults;
		CREATE TABLE #TemporaryDatabaseResults
			(
			  DatabaseName NVARCHAR(128) ,
			  Finding NVARCHAR(128)
			);

		/*
		You can build your own table with a list of checks to skip. For example, you
		might have some databases that you don't care about, or some checks you don't
		want to run. Then, when you run sp_Blitz, you can specify these parameters:
		@SkipChecksDatabase = 'DBAtools',
		@SkipChecksSchema = 'dbo',
		@SkipChecksTable = 'BlitzChecksToSkip'
		Pass in the database, schema, and table that contains the list of checks you
		want to skip. This part of the code checks those parameters, gets the list,
		and then saves those in a temp table. As we run each check, we'll see if we
		need to skip it.

		Really anal-retentive users will note that the @SkipChecksServer parameter is
		not used. YET. We added that parameter in so that we could avoid changing the
		stored proc's surface area (interface) later.
		*/
		IF OBJECT_ID('tempdb..#SkipChecks') IS NOT NULL
			DROP TABLE #SkipChecks;
		CREATE TABLE #SkipChecks
			(
			  DatabaseName NVARCHAR(128) ,
			  CheckID INT ,
			  ServerName NVARCHAR(128)
			);
		CREATE CLUSTERED INDEX IX_CheckID_DatabaseName ON #SkipChecks(CheckID, DatabaseName);

		IF @SkipChecksTable IS NOT NULL
			AND @SkipChecksSchema IS NOT NULL
			AND @SkipChecksDatabase IS NOT NULL
			BEGIN
				SET @StringToExecute = 'INSERT INTO #SkipChecks(DatabaseName, CheckID, ServerName )
				SELECT DISTINCT DatabaseName, CheckID, ServerName
				FROM ' + QUOTENAME(@SkipChecksDatabase) + '.' + QUOTENAME(@SkipChecksSchema) + '.' + QUOTENAME(@SkipChecksTable)
					+ ' WHERE ServerName IS NULL OR ServerName = SERVERPROPERTY(''ServerName'');'
				EXEC(@StringToExecute)
			END

		IF NOT EXISTS ( SELECT  1
							FROM    #SkipChecks
							WHERE   DatabaseName IS NULL AND CheckID = 106 )
							AND (select convert(int,value_in_use) from sys.configurations where name = 'default trace enabled' ) = 1
			BEGIN
					select @curr_tracefilename = [path] from sys.traces where is_default = 1 ;
					set @curr_tracefilename = reverse(@curr_tracefilename);
					select @indx = patindex('%\%', @curr_tracefilename) ;
					set @curr_tracefilename = reverse(@curr_tracefilename) ;
					set @base_tracefilename = left( @curr_tracefilename,len(@curr_tracefilename) - @indx) + '\log.trc' ;
			END

		/* If the server has any databases on Antiques Roadshow, skip the checks that would break due to CTEs. */
		IF @CheckUserDatabaseObjects = 1 AND EXISTS(SELECT * FROM sys.databases WHERE compatibility_level < 90)
		BEGIN
			SET @CheckUserDatabaseObjects = 0;
			PRINT 'Databases with compatibility level < 90 found, so setting @CheckUserDatabaseObjects = 0.';
			PRINT 'The database-level checks rely on CTEs, which are not supported in SQL 2000 compat level databases.';
			PRINT 'Get with the cool kids and switch to a current compatibility level, Grandpa. To find the problems, run:';
			PRINT 'SELECT * FROM sys.databases WHERE compatibility_level < 90;';
		END


			/* If the server is Amazon RDS, skip checks that it doesn't allow */
		IF LEFT(CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS VARCHAR(8000)), 8) = 'EC2AMAZ-'
		   AND LEFT(CAST(SERVERPROPERTY('MachineName') AS VARCHAR(8000)), 8) = 'EC2AMAZ-'
		   AND LEFT(CAST(SERVERPROPERTY('ServerName') AS VARCHAR(8000)), 8) = 'EC2AMAZ-'
			BEGIN
						INSERT INTO #SkipChecks (CheckID) VALUES (6);
						INSERT INTO #SkipChecks (CheckID) VALUES (29);
						INSERT INTO #SkipChecks (CheckID) VALUES (30);
						INSERT INTO #SkipChecks (CheckID) VALUES (31);
						INSERT INTO #SkipChecks (CheckID) VALUES (40); /* TempDB only has one data file */
						INSERT INTO #SkipChecks (CheckID) VALUES (57);
						INSERT INTO #SkipChecks (CheckID) VALUES (59);
						INSERT INTO #SkipChecks (CheckID) VALUES (61);
						INSERT INTO #SkipChecks (CheckID) VALUES (62);
						INSERT INTO #SkipChecks (CheckID) VALUES (68);
						INSERT INTO #SkipChecks (CheckID) VALUES (69);
						INSERT INTO #SkipChecks (CheckID) VALUES (73);
						INSERT INTO #SkipChecks (CheckID) VALUES (79);
						INSERT INTO #SkipChecks (CheckID) VALUES (92);
						INSERT INTO #SkipChecks (CheckID) VALUES (94);
						INSERT INTO #SkipChecks (CheckID) VALUES (96);
						INSERT INTO #SkipChecks (CheckID) VALUES (98);
						INSERT INTO #SkipChecks (CheckID) VALUES (100); /* Remote DAC disabled */
						INSERT INTO #SkipChecks (CheckID) VALUES (123);
						INSERT INTO #SkipChecks (CheckID) VALUES (177);
						INSERT INTO #SkipChecks (CheckID) VALUES (180); /* 180/181 are maintenance plans */
						INSERT INTO #SkipChecks (CheckID) VALUES (181);
			END /* Amazon RDS skipped checks */



		/*
		That's the end of the SkipChecks stuff.
		The next several tables are used by various checks later.
		*/
		IF OBJECT_ID('tempdb..#ConfigurationDefaults') IS NOT NULL
			DROP TABLE #ConfigurationDefaults;
		CREATE TABLE #ConfigurationDefaults
			(
			  name NVARCHAR(128) ,
			  DefaultValue BIGINT,
			  CheckID INT
			);

        IF OBJECT_ID ('tempdb..#Recompile') IS NOT NULL 
            DROP TABLE #Recompile; 
        CREATE TABLE #Recompile( 
            DBName varchar(200), 
            ProcName varchar(300), 
            RecompileFlag varchar(1),
            SPSchema varchar(50)
        );

		IF OBJECT_ID('tempdb..#DatabaseDefaults') IS NOT NULL
			DROP TABLE #DatabaseDefaults;
		CREATE TABLE #DatabaseDefaults
			(
				name NVARCHAR(128) ,
				DefaultValue NVARCHAR(200),
				CheckID INT,
		        Priority INT,
		        Finding VARCHAR(200),
		        URL VARCHAR(200),
		        Details NVARCHAR(4000)
			);

		IF OBJECT_ID('tempdb..#DatabaseScopedConfigurationDefaults') IS NOT NULL
			DROP TABLE #DatabaseScopedConfigurationDefaults;
		CREATE TABLE #DatabaseScopedConfigurationDefaults
			(ID INT IDENTITY(1,1), configuration_id INT, [name] NVARCHAR(60), default_value sql_variant, default_value_for_secondary sql_variant, CheckID INT, );



		IF OBJECT_ID('tempdb..#DBCCs') IS NOT NULL
			DROP TABLE #DBCCs;
		CREATE TABLE #DBCCs
			(
			  ID INT IDENTITY(1, 1)
					 PRIMARY KEY ,
			  ParentObject VARCHAR(255) ,
			  Object VARCHAR(255) ,
			  Field VARCHAR(255) ,
			  Value VARCHAR(255) ,
			  DbName NVARCHAR(128) NULL
			)


		IF OBJECT_ID('tempdb..#LogInfo2012') IS NOT NULL
			DROP TABLE #LogInfo2012;
		CREATE TABLE #LogInfo2012
			(
			  recoveryunitid INT ,
			  FileID SMALLINT ,
			  FileSize BIGINT ,
			  StartOffset BIGINT ,
			  FSeqNo BIGINT ,
			  [Status] TINYINT ,
			  Parity TINYINT ,
			  CreateLSN NUMERIC(38)
			);

		IF OBJECT_ID('tempdb..#LogInfo') IS NOT NULL
			DROP TABLE #LogInfo;
		CREATE TABLE #LogInfo
			(
			  FileID SMALLINT ,
			  FileSize BIGINT ,
			  StartOffset BIGINT ,
			  FSeqNo BIGINT ,
			  [Status] TINYINT ,
			  Parity TINYINT ,
			  CreateLSN NUMERIC(38)
			);

		IF OBJECT_ID('tempdb..#partdb') IS NOT NULL
			DROP TABLE #partdb;
		CREATE TABLE #partdb
			(
			  dbname NVARCHAR(128) ,
			  objectname NVARCHAR(200) ,
			  type_desc NVARCHAR(128)
			)

		IF OBJECT_ID('tempdb..#TraceStatus') IS NOT NULL
			DROP TABLE #TraceStatus;
		CREATE TABLE #TraceStatus
			(
			  TraceFlag VARCHAR(10) ,
			  status BIT ,
			  Global BIT ,
			  Session BIT
			);

		IF OBJECT_ID('tempdb..#driveInfo') IS NOT NULL
			DROP TABLE #driveInfo;
		CREATE TABLE #driveInfo
			(
			  drive NVARCHAR ,
			  SIZE DECIMAL(18, 2)
			)


		IF OBJECT_ID('tempdb..#dm_exec_query_stats') IS NOT NULL
			DROP TABLE #dm_exec_query_stats;
		CREATE TABLE #dm_exec_query_stats
			(
			  [id] [int] NOT NULL
						 IDENTITY(1, 1) ,
			  [sql_handle] [varbinary](64) NOT NULL ,
			  [statement_start_offset] [int] NOT NULL ,
			  [statement_end_offset] [int] NOT NULL ,
			  [plan_generation_num] [bigint] NOT NULL ,
			  [plan_handle] [varbinary](64) NOT NULL ,
			  [creation_time] [datetime] NOT NULL ,
			  [last_execution_time] [datetime] NOT NULL ,
			  [execution_count] [bigint] NOT NULL ,
			  [total_worker_time] [bigint] NOT NULL ,
			  [last_worker_time] [bigint] NOT NULL ,
			  [min_worker_time] [bigint] NOT NULL ,
			  [max_worker_time] [bigint] NOT NULL ,
			  [total_physical_reads] [bigint] NOT NULL ,
			  [last_physical_reads] [bigint] NOT NULL ,
			  [min_physical_reads] [bigint] NOT NULL ,
			  [max_physical_reads] [bigint] NOT NULL ,
			  [total_logical_writes] [bigint] NOT NULL ,
			  [last_logical_writes] [bigint] NOT NULL ,
			  [min_logical_writes] [bigint] NOT NULL ,
			  [max_logical_writes] [bigint] NOT NULL ,
			  [total_logical_reads] [bigint] NOT NULL ,
			  [last_logical_reads] [bigint] NOT NULL ,
			  [min_logical_reads] [bigint] NOT NULL ,
			  [max_logical_reads] [bigint] NOT NULL ,
			  [total_clr_time] [bigint] NOT NULL ,
			  [last_clr_time] [bigint] NOT NULL ,
			  [min_clr_time] [bigint] NOT NULL ,
			  [max_clr_time] [bigint] NOT NULL ,
			  [total_elapsed_time] [bigint] NOT NULL ,
			  [last_elapsed_time] [bigint] NOT NULL ,
			  [min_elapsed_time] [bigint] NOT NULL ,
			  [max_elapsed_time] [bigint] NOT NULL ,
			  [query_hash] [binary](8) NULL ,
			  [query_plan_hash] [binary](8) NULL ,
			  [query_plan] [xml] NULL ,
			  [query_plan_filtered] [nvarchar](MAX) NULL ,
			  [text] [nvarchar](MAX) COLLATE SQL_Latin1_General_CP1_CI_AS
									 NULL ,
			  [text_filtered] [nvarchar](MAX) COLLATE SQL_Latin1_General_CP1_CI_AS
											  NULL
			)

		IF OBJECT_ID('tempdb..#ErrorLog') IS NOT NULL
			DROP TABLE #ErrorLog;
		CREATE TABLE #ErrorLog
			(
			  LogDate DATETIME ,
			  ProcessInfo NVARCHAR(20) ,
			  [Text] NVARCHAR(1000) 
			);

		IF OBJECT_ID('tempdb..#IgnorableWaits') IS NOT NULL
			DROP TABLE #IgnorableWaits;
		CREATE TABLE #IgnorableWaits (wait_type NVARCHAR(60));
		INSERT INTO #IgnorableWaits VALUES ('BROKER_EVENTHANDLER');
		INSERT INTO #IgnorableWaits VALUES ('BROKER_RECEIVE_WAITFOR');
		INSERT INTO #IgnorableWaits VALUES ('BROKER_TASK_STOP');
		INSERT INTO #IgnorableWaits VALUES ('BROKER_TO_FLUSH');
		INSERT INTO #IgnorableWaits VALUES ('BROKER_TRANSMITTER');
		INSERT INTO #IgnorableWaits VALUES ('CHECKPOINT_QUEUE');
		INSERT INTO #IgnorableWaits VALUES ('CLR_AUTO_EVENT');
		INSERT INTO #IgnorableWaits VALUES ('CLR_MANUAL_EVENT');
		INSERT INTO #IgnorableWaits VALUES ('CLR_SEMAPHORE');
		INSERT INTO #IgnorableWaits VALUES ('DBMIRROR_DBM_EVENT');
		INSERT INTO #IgnorableWaits VALUES ('DBMIRROR_DBM_MUTEX');
		INSERT INTO #IgnorableWaits VALUES ('DBMIRROR_EVENTS_QUEUE');
		INSERT INTO #IgnorableWaits VALUES ('DBMIRROR_WORKER_QUEUE');
		INSERT INTO #IgnorableWaits VALUES ('DBMIRRORING_CMD');
		INSERT INTO #IgnorableWaits VALUES ('DIRTY_PAGE_POLL');
		INSERT INTO #IgnorableWaits VALUES ('DISPATCHER_QUEUE_SEMAPHORE');
		INSERT INTO #IgnorableWaits VALUES ('FT_IFTS_SCHEDULER_IDLE_WAIT');
		INSERT INTO #IgnorableWaits VALUES ('FT_IFTSHC_MUTEX');
		INSERT INTO #IgnorableWaits VALUES ('HADR_CLUSAPI_CALL');
		INSERT INTO #IgnorableWaits VALUES ('HADR_FILESTREAM_IOMGR_IOCOMPLETION');
		INSERT INTO #IgnorableWaits VALUES ('HADR_LOGCAPTURE_WAIT');
		INSERT INTO #IgnorableWaits VALUES ('HADR_NOTIFICATION_DEQUEUE');
		INSERT INTO #IgnorableWaits VALUES ('HADR_TIMER_TASK');
		INSERT INTO #IgnorableWaits VALUES ('HADR_WORK_QUEUE');
		INSERT INTO #IgnorableWaits VALUES ('LAZYWRITER_SLEEP');
		INSERT INTO #IgnorableWaits VALUES ('LOGMGR_QUEUE');
		INSERT INTO #IgnorableWaits VALUES ('ONDEMAND_TASK_QUEUE');
		INSERT INTO #IgnorableWaits VALUES ('PREEMPTIVE_HADR_LEASE_MECHANISM');
		INSERT INTO #IgnorableWaits VALUES ('PREEMPTIVE_SP_SERVER_DIAGNOSTICS');
		INSERT INTO #IgnorableWaits VALUES ('QDS_ASYNC_QUEUE');
		INSERT INTO #IgnorableWaits VALUES ('QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP');
		INSERT INTO #IgnorableWaits VALUES ('QDS_PERSIST_TASK_MAIN_LOOP_SLEEP');
		INSERT INTO #IgnorableWaits VALUES ('QDS_SHUTDOWN_QUEUE');
		INSERT INTO #IgnorableWaits VALUES ('REDO_THREAD_PENDING_WORK');
		INSERT INTO #IgnorableWaits VALUES ('REQUEST_FOR_DEADLOCK_SEARCH');
		INSERT INTO #IgnorableWaits VALUES ('SLEEP_SYSTEMTASK');
		INSERT INTO #IgnorableWaits VALUES ('SLEEP_TASK');
		INSERT INTO #IgnorableWaits VALUES ('SP_SERVER_DIAGNOSTICS_SLEEP');
		INSERT INTO #IgnorableWaits VALUES ('SQLTRACE_BUFFER_FLUSH');
		INSERT INTO #IgnorableWaits VALUES ('SQLTRACE_INCREMENTAL_FLUSH_SLEEP');
		INSERT INTO #IgnorableWaits VALUES ('UCS_SESSION_REGISTRATION');
		INSERT INTO #IgnorableWaits VALUES ('WAIT_XTP_OFFLINE_CKPT_NEW_LOG');
		INSERT INTO #IgnorableWaits VALUES ('WAITFOR');
		INSERT INTO #IgnorableWaits VALUES ('XE_DISPATCHER_WAIT');
		INSERT INTO #IgnorableWaits VALUES ('XE_LIVE_TARGET_TVF');
		INSERT INTO #IgnorableWaits VALUES ('XE_TIMER_EVENT');


        /* Used for the default trace checks. */
        DECLARE @TracePath NVARCHAR(256);
        SELECT @TracePath=CAST(value as NVARCHAR(256))
            FROM sys.fn_trace_getinfo(1)
            WHERE traceid=1 AND property=2;
        
        SELECT @MsSinceWaitsCleared = DATEDIFF(MINUTE, create_date, CURRENT_TIMESTAMP) * 60000.0
            FROM    sys.databases
            WHERE   name='tempdb';

		/* Have they cleared wait stats? Using a 10% fudge factor */
		IF @MsSinceWaitsCleared * .9 > (SELECT wait_time_ms FROM sys.dm_os_wait_stats WHERE wait_type = 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP')
			BEGIN
				SET @MsSinceWaitsCleared = (SELECT wait_time_ms FROM sys.dm_os_wait_stats WHERE wait_type = 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP')
				INSERT  INTO #BlitzResults
						( CheckID ,
							Priority ,
							FindingsGroup ,
							Finding ,
							URL ,
							Details
						)
					VALUES( 185,
								240,
								'Wait Stats',
								'Wait Stats Have Been Cleared',
								'http://BrentOzar.com/go/waits',
								'Someone ran DBCC SQLPERF to clear sys.dm_os_wait_stats at approximately: ' + CONVERT(NVARCHAR(100), DATEADD(ms, (-1 * @MsSinceWaitsCleared), GETDATE()), 120))
			END

		/* @CpuMsSinceWaitsCleared is used for waits stats calculations */
		SELECT @CpuMsSinceWaitsCleared = @MsSinceWaitsCleared * scheduler_count
			FROM sys.dm_os_sys_info;


		/* If we're outputting CSV or Markdown, don't bother checking the plan cache because we cannot export plans. */
		IF @OutputType = 'CSV' OR @OutputType = 'MARKDOWN'
			SET @CheckProcedureCache = 0;

		/* If we're posting a question on Stack, include background info on the server */
		IF @OutputType = 'MARKDOWN'
			SET @CheckServerInfo = 1;


		/* Only run CheckUserDatabaseObjects if there are less than 50 databases. */
		IF @BringThePain = 0 AND 50 <= (SELECT COUNT(*) FROM sys.databases) AND @CheckUserDatabaseObjects = 1
			BEGIN
			SET @CheckUserDatabaseObjects = 0;
			PRINT 'Running sp_Blitz @CheckUserDatabaseObjects = 1 on a server with 50+ databases may cause temporary insanity for the server and/or user.';
			PRINT 'If you''re sure you want to do this, run again with the parameter @BringThePain = 1.';
			END

		/* Sanitize our inputs */
		SELECT
			@OutputServerName = QUOTENAME(@OutputServerName),
			@OutputDatabaseName = QUOTENAME(@OutputDatabaseName),
			@OutputSchemaName = QUOTENAME(@OutputSchemaName),
			@OutputTableName = QUOTENAME(@OutputTableName)

		/* Get the major and minor build numbers */
		SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128));
		SELECT @ProductVersionMajor = SUBSTRING(@ProductVersion, 1,CHARINDEX('.', @ProductVersion) + 1 ),
			@ProductVersionMinor = PARSENAME(CONVERT(varchar(32), @ProductVersion), 2)
		
		/*
		Whew! we're finally done with the setup, and we can start doing checks.
		First, let's make sure we're actually supposed to do checks on this server.
		The user could have passed in a SkipChecks table that specified to skip ALL
		checks on this server, so let's check for that:
		*/
		IF ( ( SERVERPROPERTY('ServerName') NOT IN ( SELECT ServerName
													 FROM   #SkipChecks
													 WHERE  DatabaseName IS NULL
															AND CheckID IS NULL ) )
			 OR ( @SkipChecksTable IS NULL )
		   )
			BEGIN

				/*
				Our very first check! We'll put more comments in this one just to
				explain exactly how it works. First, we check to see if we're
				supposed to skip CheckID 1 (that's the check we're working on.)
				*/
				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 1 )
					BEGIN

						/*
						Below, we check master.sys.databases looking for databases
						that haven't had a backup in the last week. If we find any,
						we insert them into #BlitzResults, the temp table that
						tracks our server's problems. Note that if the check does
						NOT find any problems, we don't save that. We're only
						saving the problems, not the successful checks.
						*/
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  1 AS CheckID ,
										d.[name] AS DatabaseName ,
										1 AS Priority ,
										'Backup' AS FindingsGroup ,
										'Backups Not Performed Recently' AS Finding ,
										'http://BrentOzar.com/go/nobak' AS URL ,
										'Last backed up: '
										+ COALESCE(CAST(MAX(b.backup_finish_date) AS VARCHAR(25)),'never') AS Details
								FROM    master.sys.databases d
										LEFT OUTER JOIN msdb.dbo.backupset b ON d.name COLLATE SQL_Latin1_General_CP1_CI_AS = b.database_name COLLATE SQL_Latin1_General_CP1_CI_AS
																  AND b.type = 'D'
																  AND b.server_name = SERVERPROPERTY('ServerName') /*Backupset ran on current server */
								WHERE   d.database_id <> 2  /* Bonus points if you know what that means */
										AND d.state NOT IN(1, 6, 10) /* Not currently offline or restoring, like log shipping databases */
										AND d.is_in_standby = 0 /* Not a log shipping target database */
										AND d.source_database_id IS NULL /* Excludes database snapshots */
										AND d.name NOT IN ( SELECT DISTINCT
																  DatabaseName
															FROM  #SkipChecks
															WHERE CheckID IS NULL )
										/*
										The above NOT IN filters out the databases we're not supposed to check.
										*/
								GROUP BY d.name
								HAVING  MAX(b.backup_finish_date) <= DATEADD(dd,
																  -7, GETDATE())
                                        OR MAX(b.backup_finish_date) IS NULL;
						/*
						And there you have it. The rest of this stored procedure works the same
						way: it asks:
						- Should I skip this check?
						- If not, do I find problems?
						- Insert the results into #BlitzResults
						*/

					END

				/*
				And that's the end of CheckID #1.

				CheckID #2 is a little simpler because it only involves one query, and it's
				more typical for queries that people contribute. But keep reading, because
				the next check gets more complex again.
				*/

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 2 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
										SELECT DISTINCT
										2 AS CheckID ,
										d.name AS DatabaseName ,
										1 AS Priority ,
										'Backup' AS FindingsGroup ,
										'Full Recovery Mode w/o Log Backups' AS Finding ,
										'http://BrentOzar.com/go/biglogs' AS URL ,
										( 'The ' + CAST(CAST((SELECT ((SUM([mf].[size]) * 8.) / 1024.) FROM sys.[master_files] AS [mf] WHERE [mf].[database_id] = d.[database_id] AND [mf].[type_desc] = 'LOG') AS DECIMAL(18,2)) AS VARCHAR) + 'MB log file has not been backed up in the last week.' ) AS Details
								FROM    master.sys.databases d
								WHERE   d.recovery_model IN ( 1, 2 )
										AND d.database_id NOT IN ( 2, 3 )
										AND d.source_database_id IS NULL
										AND d.state NOT IN(1, 6, 10) /* Not currently offline or restoring, like log shipping databases */
										AND d.is_in_standby = 0 /* Not a log shipping target database */
										AND d.source_database_id IS NULL /* Excludes database snapshots */
										AND d.name NOT IN ( SELECT DISTINCT
																  DatabaseName
															FROM  #SkipChecks
															WHERE CheckID IS NULL )
										AND NOT EXISTS ( SELECT *
														 FROM   msdb.dbo.backupset b
														 WHERE  d.name COLLATE SQL_Latin1_General_CP1_CI_AS = b.database_name COLLATE SQL_Latin1_General_CP1_CI_AS
																AND b.type = 'L'
																AND b.backup_finish_date >= DATEADD(dd,
																  -7, GETDATE()) ); 
					END


				/*
				Next up, we've got CheckID 8. (These don't have to go in order.) This one
				won't work on SQL Server 2005 because it relies on a new DMV that didn't
				exist prior to SQL Server 2008. This means we have to check the SQL Server
				version first, then build a dynamic string with the query we want to run:
				*/

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 8 )
					BEGIN
						IF @@VERSION NOT LIKE '%Microsoft SQL Server 2000%'
							AND @@VERSION NOT LIKE '%Microsoft SQL Server 2005%'
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults
							(CheckID, Priority,
							FindingsGroup,
							Finding, URL,
							Details)
					  SELECT 8 AS CheckID,
					  230 AS Priority,
					  ''Security'' AS FindingsGroup,
					  ''Server Audits Running'' AS Finding,
					  ''http://BrentOzar.com/go/audits'' AS URL,
					  (''SQL Server built-in audit functionality is being used by server audit: '' + [name]) AS Details FROM sys.dm_server_audit_status'
								EXECUTE(@StringToExecute)
							END;
					END

				/*
				But what if you need to run a query in every individual database?
				Hop down to the @CheckUserDatabaseObjects section.
                
				And that's the basic idea! You can read through the rest of the
				checks if you like - some more exciting stuff happens closer to the
				end of the stored proc, where we start doing things like checking
				the plan cache, but those aren't as cleanly commented.

				If you'd like to contribute your own check, use one of the check
				formats shown above and email it to Help@BrentOzar.com. You don't
				have to pick a CheckID or a link - we'll take care of that when we
				test and publish the code. Thanks!
				*/


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 93 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT
										93 AS CheckID ,
										1 AS Priority ,
										'Backup' AS FindingsGroup ,
										'Backing Up to Same Drive Where Databases Reside' AS Finding ,
										'http://BrentOzar.com/go/backup' AS URL ,
										CAST(COUNT(1) AS VARCHAR(50)) + ' backups done on drive '
										+ UPPER(LEFT(bmf.physical_device_name, 3))
										+ ' in the last two weeks, where database files also live. This represents a serious risk if that array fails.' Details
								FROM    msdb.dbo.backupmediafamily AS bmf
										INNER JOIN msdb.dbo.backupset AS bs ON bmf.media_set_id = bs.media_set_id
																  AND bs.backup_start_date >= ( DATEADD(dd,
																  -14, GETDATE()) )
										/* Filter out databases that were recently restored: */
										LEFT OUTER JOIN msdb.dbo.restorehistory rh ON bs.database_name = rh.destination_database_name AND rh.restore_date > DATEADD(dd, -14, GETDATE())
								WHERE   UPPER(LEFT(bmf.physical_device_name COLLATE SQL_Latin1_General_CP1_CI_AS, 3)) IN (
										SELECT DISTINCT
												UPPER(LEFT(mf.physical_name COLLATE SQL_Latin1_General_CP1_CI_AS, 3))
										FROM    sys.master_files AS mf )
										AND rh.destination_database_name IS NULL
								GROUP BY UPPER(LEFT(bmf.physical_device_name, 3))
					END


					IF NOT EXISTS ( SELECT  1
									FROM    #SkipChecks
									WHERE   DatabaseName IS NULL AND CheckID = 119 )
						AND EXISTS ( SELECT *
									 FROM   sys.all_objects o
									 WHERE  o.name = 'dm_database_encryption_keys' )
						BEGIN
							SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, DatabaseName, URL, Details)
								SELECT 119 AS CheckID,
								1 AS Priority,
								''Backup'' AS FindingsGroup,
								''TDE Certificate Not Backed Up Recently'' AS Finding,
								db_name(dek.database_id) AS DatabaseName,
								''http://BrentOzar.com/go/tde'' AS URL,
								''The certificate '' + c.name + '' is used to encrypt database '' + db_name(dek.database_id) + ''. Last backup date: '' + COALESCE(CAST(c.pvt_key_last_backup_date AS VARCHAR(100)), ''Never'') AS Details
								FROM sys.certificates c INNER JOIN sys.dm_database_encryption_keys dek ON c.thumbprint = dek.encryptor_thumbprint
								WHERE pvt_key_last_backup_date IS NULL OR pvt_key_last_backup_date <= DATEADD(dd, -30, GETDATE())';
							EXECUTE(@StringToExecute);
						END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 3 )
					BEGIN
						IF DATEADD(dd, -60, GETDATE()) > (SELECT TOP 1 backup_start_date FROM msdb.dbo.backupset ORDER BY 1)
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT TOP 1
										3 AS CheckID ,
										'msdb' ,
										200 AS Priority ,
										'Backup' AS FindingsGroup ,
										'MSDB Backup History Not Purged' AS Finding ,
										'http://BrentOzar.com/go/history' AS URL ,
										( 'Database backup history retained back to '
										  + CAST(bs.backup_start_date AS VARCHAR(20)) ) AS Details
								FROM    msdb.dbo.backupset bs
								ORDER BY backup_set_id ASC;
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 186 )
					BEGIN
						IF DATEADD(dd, -2, GETDATE()) < (SELECT TOP 1 backup_start_date FROM msdb.dbo.backupset ORDER BY 1)
							INSERT  INTO #BlitzResults
									( CheckID ,
									  DatabaseName ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT TOP 1
											186 AS CheckID ,
											'msdb' ,
											200 AS Priority ,
											'Backup' AS FindingsGroup ,
											'MSDB Backup History Purged Too Frequently' AS Finding ,
											'http://BrentOzar.com/go/history' AS URL ,
											( 'Database backup history only retained back to '
											  + CAST(bs.backup_start_date AS VARCHAR(20)) ) AS Details
									FROM    msdb.dbo.backupset bs
									ORDER BY backup_set_id ASC;
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 178 )
					AND EXISTS (SELECT *
									FROM msdb.dbo.backupset bs
									WHERE bs.type = 'D'
									AND bs.backup_size >= 50000000000 /* At least 50GB */
									AND DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date) <= 60 /* Backup took less than 60 seconds */
									AND bs.backup_finish_date >= DATEADD(DAY, -14, GETDATE()) /* In the last 2 weeks */)
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT 178 AS CheckID ,
										200 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Snapshot Backups Occurring' AS Finding ,
										'http://BrentOzar.com/go/snaps' AS URL ,
										( CAST(COUNT(*) AS VARCHAR(20)) + ' snapshot-looking backups have occurred in the last two weeks, indicating that IO may be freezing up.') AS Details
								FROM msdb.dbo.backupset bs
								WHERE bs.type = 'D'
								AND bs.backup_size >= 50000000000 /* At least 50GB */
								AND DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date) <= 60 /* Backup took less than 60 seconds */
								AND bs.backup_finish_date >= DATEADD(DAY, -14, GETDATE()) /* In the last 2 weeks */
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 4 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  4 AS CheckID ,
										230 AS Priority ,
										'Security' AS FindingsGroup ,
										'Sysadmins' AS Finding ,
										'http://BrentOzar.com/go/sa' AS URL ,
										( 'Login [' + l.name
										  + '] is a sysadmin - meaning they can do absolutely anything in SQL Server, including dropping databases or hiding their tracks.' ) AS Details
								FROM    master.sys.syslogins l
								WHERE   l.sysadmin = 1
										AND l.name <> SUSER_SNAME(0x01)
										AND l.denylogin = 0
										AND l.name NOT LIKE 'NT SERVICE\%'
										AND l.name <> 'l_certSignSmDetach'; /* Added in SQL 2016 */
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 5 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  5 AS CheckID ,
										230 AS Priority ,
										'Security' AS FindingsGroup ,
										'Security Admins' AS Finding ,
										'http://BrentOzar.com/go/sa' AS URL ,
										( 'Login [' + l.name
										  + '] is a security admin - meaning they can give themselves permission to do absolutely anything in SQL Server, including dropping databases or hiding their tracks.' ) AS Details
								FROM    master.sys.syslogins l
								WHERE   l.securityadmin = 1
										AND l.name <> SUSER_SNAME(0x01)
										AND l.denylogin = 0;
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 104 )
					BEGIN
						INSERT  INTO #BlitzResults
								( [CheckID] ,
								  [Priority] ,
								  [FindingsGroup] ,
								  [Finding] ,
								  [URL] ,
								  [Details]
								)
								SELECT  104 AS [CheckID] ,
										230 AS [Priority] ,
										'Security' AS [FindingsGroup] ,
										'Login Can Control Server' AS [Finding] ,
										'http://BrentOzar.com/go/sa' AS [URL] ,
										'Login [' + pri.[name]
										+ '] has the CONTROL SERVER permission - meaning they can do absolutely anything in SQL Server, including dropping databases or hiding their tracks.' AS [Details]
								FROM    sys.server_principals AS pri
								WHERE   pri.[principal_id] IN (
										SELECT  p.[grantee_principal_id]
										FROM    sys.server_permissions AS p
										WHERE   p.[state] IN ( 'G', 'W' )
												AND p.[class] = 100
												AND p.[type] = 'CL' )
										AND pri.[name] NOT LIKE '##%##'
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 6 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  6 AS CheckID ,
										230 AS Priority ,
										'Security' AS FindingsGroup ,
										'Jobs Owned By Users' AS Finding ,
										'http://BrentOzar.com/go/owners' AS URL ,
										( 'Job [' + j.name + '] is owned by ['
										  + SUSER_SNAME(j.owner_sid)
										  + '] - meaning if their login is disabled or not available due to Active Directory problems, the job will stop working.' ) AS Details
								FROM    msdb.dbo.sysjobs j
								WHERE   j.enabled = 1
										AND SUSER_SNAME(j.owner_sid) <> SUSER_SNAME(0x01);
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 7 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  7 AS CheckID ,
										230 AS Priority ,
										'Security' AS FindingsGroup ,
										'Stored Procedure Runs at Startup' AS Finding ,
										'http://BrentOzar.com/go/startup' AS URL ,
										( 'Stored procedure [master].['
										  + r.SPECIFIC_SCHEMA + '].['
										  + r.SPECIFIC_NAME
										  + '] runs automatically when SQL Server starts up.  Make sure you know exactly what this stored procedure is doing, because it could pose a security risk.' ) AS Details
								FROM    master.INFORMATION_SCHEMA.ROUTINES r
								WHERE   OBJECTPROPERTY(OBJECT_ID(ROUTINE_NAME),
													   'ExecIsStartup') = 1;
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 10 )
					BEGIN
						IF @@VERSION NOT LIKE '%Microsoft SQL Server 2000%'
							AND @@VERSION NOT LIKE '%Microsoft SQL Server 2005%'
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults
							(CheckID,
							Priority,
							FindingsGroup,
							Finding,
							URL,
							Details)
					  SELECT 10 AS CheckID,
					  100 AS Priority,
					  ''Performance'' AS FindingsGroup,
					  ''Resource Governor Enabled'' AS Finding,
					  ''http://BrentOzar.com/go/rg'' AS URL,
					  (''Resource Governor is enabled.  Queries may be throttled.  Make sure you understand how the Classifier Function is configured.'') AS Details FROM sys.resource_governor_configuration WHERE is_enabled = 1'
								EXECUTE(@StringToExecute)
							END;
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 11 )
					BEGIN
						IF @@VERSION NOT LIKE '%Microsoft SQL Server 2000%'
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults
							(CheckID,
							Priority,
							FindingsGroup,
							Finding,
							URL,
							Details)
					  SELECT 11 AS CheckID,
					  100 AS Priority,
					  ''Performance'' AS FindingsGroup,
					  ''Server Triggers Enabled'' AS Finding,
					  ''http://BrentOzar.com/go/logontriggers/'' AS URL,
					  (''Server Trigger ['' + [name] ++ ''] is enabled.  Make sure you understand what that trigger is doing - the less work it does, the better.'') AS Details FROM sys.server_triggers WHERE is_disabled = 0 AND is_ms_shipped = 0'
								EXECUTE(@StringToExecute)
							END;
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 12 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  12 AS CheckID ,
										[name] AS DatabaseName ,
										10 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Auto-Close Enabled' AS Finding ,
										'http://BrentOzar.com/go/autoclose' AS URL ,
										( 'Database [' + [name]
										  + '] has auto-close enabled.  This setting can dramatically decrease performance.' ) AS Details
								FROM    sys.databases
								WHERE   is_auto_close_on = 1
										AND name NOT IN ( SELECT DISTINCT
																  DatabaseName
														  FROM    #SkipChecks 
														  WHERE CheckID IS NULL)
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 13 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  13 AS CheckID ,
										[name] AS DatabaseName ,
										10 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Auto-Shrink Enabled' AS Finding ,
										'http://BrentOzar.com/go/autoshrink' AS URL ,
										( 'Database [' + [name]
										  + '] has auto-shrink enabled.  This setting can dramatically decrease performance.' ) AS Details
								FROM    sys.databases
								WHERE   is_auto_shrink_on = 1
										AND name NOT IN ( SELECT DISTINCT
																  DatabaseName
														  FROM    #SkipChecks 
														  WHERE CheckID IS NULL);
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 14 )
					BEGIN
						IF @@VERSION NOT LIKE '%Microsoft SQL Server 2000%'
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults
							(CheckID,
							DatabaseName,
							Priority,
							FindingsGroup,
							Finding,
							URL,
							Details)
					  SELECT 14 AS CheckID,
					  [name] as DatabaseName,
					  50 AS Priority,
					  ''Reliability'' AS FindingsGroup,
					  ''Page Verification Not Optimal'' AS Finding,
					  ''http://BrentOzar.com/go/torn'' AS URL,
					  (''Database ['' + [name] + ''] has '' + [page_verify_option_desc] + '' for page verification.  SQL Server may have a harder time recognizing and recovering from storage corruption.  Consider using CHECKSUM instead.'') COLLATE database_default AS Details
					  FROM sys.databases
					  WHERE page_verify_option < 2
					  AND name <> ''tempdb''
					  and name not in (select distinct DatabaseName from #SkipChecks)'
								EXECUTE(@StringToExecute)
							END;
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 15 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  15 AS CheckID ,
										[name] AS DatabaseName ,
										110 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Auto-Create Stats Disabled' AS Finding ,
										'http://BrentOzar.com/go/acs' AS URL ,
										( 'Database [' + [name]
										  + '] has auto-create-stats disabled.  SQL Server uses statistics to build better execution plans, and without the ability to automatically create more, performance may suffer.' ) AS Details
								FROM    sys.databases
								WHERE   is_auto_create_stats_on = 0
										AND name NOT IN ( SELECT DISTINCT
																  DatabaseName
														  FROM    #SkipChecks 
														  WHERE CheckID IS NULL)
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 16 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  16 AS CheckID ,
										[name] AS DatabaseName ,
										110 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Auto-Update Stats Disabled' AS Finding ,
										'http://BrentOzar.com/go/aus' AS URL ,
										( 'Database [' + [name]
										  + '] has auto-update-stats disabled.  SQL Server uses statistics to build better execution plans, and without the ability to automatically update them, performance may suffer.' ) AS Details
								FROM    sys.databases
								WHERE   is_auto_update_stats_on = 0
										AND name NOT IN ( SELECT DISTINCT
																  DatabaseName
														  FROM    #SkipChecks 
														  WHERE CheckID IS NULL)
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 17 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  17 AS CheckID ,
										[name] AS DatabaseName ,
										150 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Stats Updated Asynchronously' AS Finding ,
										'http://BrentOzar.com/go/asyncstats' AS URL ,
										( 'Database [' + [name]
										  + '] has auto-update-stats-async enabled.  When SQL Server gets a query for a table with out-of-date statistics, it will run the query with the stats it has - while updating stats to make later queries better. The initial run of the query may suffer, though.' ) AS Details
								FROM    sys.databases
								WHERE   is_auto_update_stats_async_on = 1
										AND name NOT IN ( SELECT DISTINCT
																  DatabaseName
														  FROM    #SkipChecks 
														  WHERE CheckID IS NULL)
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 18 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  18 AS CheckID ,
										[name] AS DatabaseName ,
										150 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Forced Parameterization On' AS Finding ,
										'http://BrentOzar.com/go/forced' AS URL ,
										( 'Database [' + [name]
										  + '] has forced parameterization enabled.  SQL Server will aggressively reuse query execution plans even if the applications do not parameterize their queries.  This can be a performance booster with some programming languages, or it may use universally bad execution plans when better alternatives are available for certain parameters.' ) AS Details
								FROM    sys.databases
								WHERE   is_parameterization_forced = 1
										AND name NOT IN ( SELECT  DatabaseName
														  FROM    #SkipChecks 
														  WHERE CheckID IS NULL)
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 20 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  20 AS CheckID ,
										[name] AS DatabaseName ,
										200 AS Priority ,
										'Informational' AS FindingsGroup ,
										'Date Correlation On' AS Finding ,
										'http://BrentOzar.com/go/corr' AS URL ,
										( 'Database [' + [name]
										  + '] has date correlation enabled.  This is not a default setting, and it has some performance overhead.  It tells SQL Server that date fields in two tables are related, and SQL Server maintains statistics showing that relation.' ) AS Details
								FROM    sys.databases
								WHERE   is_date_correlation_on = 1
										AND name NOT IN ( SELECT DISTINCT
																  DatabaseName
														  FROM    #SkipChecks 
														  WHERE CheckID IS NULL)
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 21 )
					BEGIN
						IF @@VERSION NOT LIKE '%Microsoft SQL Server 2000%'
							AND @@VERSION NOT LIKE '%Microsoft SQL Server 2005%'
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults
							(CheckID,
							DatabaseName,
							Priority,
							FindingsGroup,
							Finding,
							URL,
							Details)
					  SELECT 21 AS CheckID,
					  [name] as DatabaseName,
					  200 AS Priority,
					  ''Informational'' AS FindingsGroup,
					  ''Database Encrypted'' AS Finding,
					  ''http://BrentOzar.com/go/tde'' AS URL,
					  (''Database ['' + [name] + ''] has Transparent Data Encryption enabled.  Make absolutely sure you have backed up the certificate and private key, or else you will not be able to restore this database.'') AS Details
					  FROM sys.databases
					  WHERE is_encrypted = 1
					  and name not in (select distinct DatabaseName from #SkipChecks)'
								EXECUTE(@StringToExecute)
							END;
					END

				/*
				Believe it or not, SQL Server doesn't track the default values
				for sp_configure options! We'll make our own list here.
				*/
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'access check cache bucket count', 0, 1001 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'access check cache quota', 0, 1002 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'Ad Hoc Distributed Queries', 0, 1003 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'affinity I/O mask', 0, 1004 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'affinity mask', 0, 1005 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'affinity64 mask', 0, 1066 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'affinity64 I/O mask', 0, 1067 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'Agent XPs', 0, 1071 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'allow updates', 0, 1007 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'awe enabled', 0, 1008 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'backup checksum default', 0, 1070 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'backup compression default', 0, 1073 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'blocked process threshold', 0, 1009 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'blocked process threshold (s)', 0, 1009 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'c2 audit mode', 0, 1010 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'clr enabled', 0, 1011 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'common criteria compliance enabled', 0, 1074 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'contained database authentication', 0, 1068 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'cost threshold for parallelism', 5, 1012 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'cross db ownership chaining', 0, 1013 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'cursor threshold', -1, 1014 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'Database Mail XPs', 0, 1072 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'default full-text language', 1033, 1016 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'default language', 0, 1017 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'default trace enabled', 1, 1018 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'disallow results from triggers', 0, 1019 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'EKM provider enabled', 0, 1075 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'filestream access level', 0, 1076 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'fill factor (%)', 0, 1020 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'ft crawl bandwidth (max)', 100, 1021 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'ft crawl bandwidth (min)', 0, 1022 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'ft notify bandwidth (max)', 100, 1023 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'ft notify bandwidth (min)', 0, 1024 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'index create memory (KB)', 0, 1025 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'in-doubt xact resolution', 0, 1026 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'lightweight pooling', 0, 1027 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'locks', 0, 1028 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'max degree of parallelism', 0, 1029 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'max full-text crawl range', 4, 1030 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'max server memory (MB)', 2147483647, 1031 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'max text repl size (B)', 65536, 1032 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'max worker threads', 0, 1033 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'media retention', 0, 1034 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'min memory per query (KB)', 1024, 1035 );
				/* Accepting both 0 and 16 below because both have been seen in the wild as defaults. */
				IF EXISTS ( SELECT  *
							FROM    sys.configurations
							WHERE   name = 'min server memory (MB)'
									AND value_in_use IN ( 0, 16 ) )
					INSERT  INTO #ConfigurationDefaults
							SELECT  'min server memory (MB)' ,
									CAST(value_in_use AS BIGINT), 1036
							FROM    sys.configurations
							WHERE   name = 'min server memory (MB)'
				ELSE
					INSERT  INTO #ConfigurationDefaults
					VALUES  ( 'min server memory (MB)', 0, 1036 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'nested triggers', 1, 1037 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'network packet size (B)', 4096, 1038 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'Ole Automation Procedures', 0, 1039 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'open objects', 0, 1040 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'optimize for ad hoc workloads', 0, 1041 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'PH timeout (s)', 60, 1042 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'precompute rank', 0, 1043 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'priority boost', 0, 1044 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'query governor cost limit', 0, 1045 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'query wait (s)', -1, 1046 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'recovery interval (min)', 0, 1047 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'remote access', 1, 1048 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'remote admin connections', 0, 1049 );
				/* SQL Server 2012 changes a configuration default */
				IF @@VERSION LIKE '%Microsoft SQL Server 2005%'
					OR @@VERSION LIKE '%Microsoft SQL Server 2008%'
					BEGIN
						INSERT  INTO #ConfigurationDefaults
						VALUES  ( 'remote login timeout (s)', 20, 1069 );
					END
				ELSE
					BEGIN
						INSERT  INTO #ConfigurationDefaults
						VALUES  ( 'remote login timeout (s)', 10, 1069 );
					END
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'remote proc trans', 0, 1050 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'remote query timeout (s)', 600, 1051 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'Replication XPs', 0, 1052 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'RPC parameter data validation', 0, 1053 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'scan for startup procs', 0, 1054 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'server trigger recursion', 1, 1055 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'set working set size', 0, 1056 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'show advanced options', 0, 1057 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'SMO and DMO XPs', 1, 1058 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'SQL Mail XPs', 0, 1059 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'transform noise words', 0, 1060 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'two digit year cutoff', 2049, 1061 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'user connections', 0, 1062 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'user options', 0, 1063 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'Web Assistant Procedures', 0, 1064 );
				INSERT  INTO #ConfigurationDefaults
				VALUES  ( 'xp_cmdshell', 0, 1065 );


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 22 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  cd.CheckID ,
										200 AS Priority ,
										'Non-Default Server Config' AS FindingsGroup ,
										cr.name AS Finding ,
										'http://BrentOzar.com/go/conf' AS URL ,
										( 'This sp_configure option has been changed.  Its default value is '
										  + COALESCE(CAST(cd.[DefaultValue] AS VARCHAR(100)),
													 '(unknown)')
										  + ' and it has been set to '
										  + CAST(cr.value_in_use AS VARCHAR(100))
										  + '.' ) AS Details
								FROM    sys.configurations cr
										INNER JOIN #ConfigurationDefaults cd ON cd.name = cr.name
										LEFT OUTER JOIN #ConfigurationDefaults cdUsed ON cdUsed.name = cr.name
																  AND cdUsed.DefaultValue = cr.value_in_use
								WHERE   cdUsed.name IS NULL;
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 190 )
					BEGIN
						SELECT @MinServerMemory = CAST(value_in_use as BIGINT) FROM sys.configurations WHERE name = 'min server memory (MB)'
						SELECT @MaxServerMemory = CAST(value_in_use as BIGINT) FROM sys.configurations WHERE name = 'max server memory (MB)'
						
						IF (@MinServerMemory = @MaxServerMemory)
						BEGIN
						INSERT INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								VALUES  
									(	190,
										200,
										'Performance',
										'Non-Dynamic Memory',
										'http://BrentOzar.com/go/memory',
										'Minimum Server Memory setting is the same as the Maximum (both set to ' + CAST(@MinServerMemory AS NVARCHAR(50)) + '). This will not allow dynamic memory. Please revise memory settings'
									)
						END
					END
					
					IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 188 )
					BEGIN

						/* Let's set variables so that our query is still SARGable */
						SET @Processors = (SELECT cpu_count FROM sys.dm_os_sys_info)
						SET @NUMANodes = (SELECT COUNT(1)
											FROM sys.dm_os_performance_counters pc
											WHERE pc.object_name LIKE '%Buffer Node%'
												AND counter_name = 'Page life expectancy')
						/* If Cost Threshold for Parallelism is default then flag as a potential issue */
						/* If MAXDOP is default and processors > 8 or NUMA nodes > 1 then flag as potential issue */
						INSERT INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  188 AS CheckID ,
										200 AS Priority ,
										'Performance' AS FindingsGroup ,
										cr.name AS Finding ,
										'http://BrentOzar.com/go/cxpacket' AS URL ,
										( 'Set to ' + CAST(cr.value_in_use AS NVARCHAR(50)) + ', its default value. Changing this sp_configure setting may reduce CXPACKET waits.')
								FROM    sys.configurations cr
										INNER JOIN #ConfigurationDefaults cd ON cd.name = cr.name
											AND cr.value_in_use = cd.DefaultValue
								WHERE   cr.name = 'cost threshold for parallelism'
									OR (cr.name = 'max degree of parallelism' AND (@NUMANodes > 1 OR @Processors > 8));
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 24 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT DISTINCT
										24 AS CheckID ,
										DB_NAME(database_id) AS DatabaseName ,
										170 AS Priority ,
										'File Configuration' AS FindingsGroup ,
										'System Database on C Drive' AS Finding ,
										'http://BrentOzar.com/go/cdrive' AS URL ,
										( 'The ' + DB_NAME(database_id)
										  + ' database has a file on the C drive.  Putting system databases on the C drive runs the risk of crashing the server when it runs out of space.' ) AS Details
								FROM    sys.master_files
								WHERE   UPPER(LEFT(physical_name, 1)) = 'C'
										AND DB_NAME(database_id) IN ( 'master',
																  'model', 'msdb' );
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 25 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT TOP 1
										25 AS CheckID ,
										'tempdb' ,
										20 AS Priority ,
										'File Configuration' AS FindingsGroup ,
										'TempDB on C Drive' AS Finding ,
										'http://BrentOzar.com/go/cdrive' AS URL ,
										CASE WHEN growth > 0
											 THEN ( 'The tempdb database has files on the C drive.  TempDB frequently grows unpredictably, putting your server at risk of running out of C drive space and crashing hard.  C is also often much slower than other drives, so performance may be suffering.' )
											 ELSE ( 'The tempdb database has files on the C drive.  TempDB is not set to Autogrow, hopefully it is big enough.  C is also often much slower than other drives, so performance may be suffering.' )
										END AS Details
								FROM    sys.master_files
								WHERE   UPPER(LEFT(physical_name, 1)) = 'C'
										AND DB_NAME(database_id) = 'tempdb';
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 26 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT DISTINCT
										26 AS CheckID ,
										DB_NAME(database_id) AS DatabaseName ,
										20 AS Priority ,
										'Reliability' AS FindingsGroup ,
										'User Databases on C Drive' AS Finding ,
										'http://BrentOzar.com/go/cdrive' AS URL ,
										( 'The ' + DB_NAME(database_id)
										  + ' database has a file on the C drive.  Putting databases on the C drive runs the risk of crashing the server when it runs out of space.' ) AS Details
								FROM    sys.master_files
								WHERE   UPPER(LEFT(physical_name, 1)) = 'C'
										AND DB_NAME(database_id) NOT IN ( 'master',
																  'model', 'msdb',
																  'tempdb' )
										AND DB_NAME(database_id) NOT IN (
										SELECT DISTINCT
												DatabaseName
										FROM    #SkipChecks )
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 27 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  27 AS CheckID ,
										'master' AS DatabaseName ,
										200 AS Priority ,
										'Informational' AS FindingsGroup ,
										'Tables in the Master Database' AS Finding ,
										'http://BrentOzar.com/go/mastuser' AS URL ,
										( 'The ' + name
										  + ' table in the master database was created by end users on '
										  + CAST(create_date AS VARCHAR(20))
										  + '. Tables in the master database may not be restored in the event of a disaster.' ) AS Details
								FROM    master.sys.tables
								WHERE   is_ms_shipped = 0;
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 28 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  28 AS CheckID ,
										200 AS Priority ,
										'Informational' AS FindingsGroup ,
										'Tables in the MSDB Database' AS Finding ,
										'http://BrentOzar.com/go/msdbuser' AS URL ,
										( 'The ' + name
										  + ' table in the msdb database was created by end users on '
										  + CAST(create_date AS VARCHAR(20))
										  + '. Tables in the msdb database may not be restored in the event of a disaster.' ) AS Details
								FROM    msdb.sys.tables
								WHERE   is_ms_shipped = 0 AND name NOT LIKE '%DTA_%';
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 29 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  29 AS CheckID ,
										200 AS Priority ,
										'Informational' AS FindingsGroup ,
										'Tables in the Model Database' AS Finding ,
										'http://BrentOzar.com/go/model' AS URL ,
										( 'The ' + name
										  + ' table in the model database was created by end users on '
										  + CAST(create_date AS VARCHAR(20))
										  + '. Tables in the model database are automatically copied into all new databases.' ) AS Details
								FROM    model.sys.tables
								WHERE   is_ms_shipped = 0;
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 30 )
					BEGIN
						IF ( SELECT COUNT(*)
							 FROM   msdb.dbo.sysalerts
							 WHERE  severity BETWEEN 19 AND 25
						   ) < 7
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  30 AS CheckID ,
											200 AS Priority ,
											'Monitoring' AS FindingsGroup ,
											'Not All Alerts Configured' AS Finding ,
											'http://BrentOzar.com/go/alert' AS URL ,
											( 'Not all SQL Server Agent alerts have been configured.  This is a free, easy way to get notified of corruption, job failures, or major outages even before monitoring systems pick it up.' ) AS Details;
					END



				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 59 )
					BEGIN
						IF EXISTS ( SELECT  *
									FROM    msdb.dbo.sysalerts
									WHERE   enabled = 1
											AND COALESCE(has_notification, 0) = 0
											AND (job_id IS NULL OR job_id = 0x))
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  59 AS CheckID ,
											200 AS Priority ,
											'Monitoring' AS FindingsGroup ,
											'Alerts Configured without Follow Up' AS Finding ,
											'http://BrentOzar.com/go/alert' AS URL ,
											( 'SQL Server Agent alerts have been configured but they either do not notify anyone or else they do not take any action.  This is a free, easy way to get notified of corruption, job failures, or major outages even before monitoring systems pick it up.' ) AS Details;
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 96 )
					BEGIN
						IF NOT EXISTS ( SELECT  *
										FROM    msdb.dbo.sysalerts
										WHERE   message_id IN ( 823, 824, 825 ) )
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  96 AS CheckID ,
											200 AS Priority ,
											'Monitoring' AS FindingsGroup ,
											'No Alerts for Corruption' AS Finding ,
											'http://BrentOzar.com/go/alert' AS URL ,
											( 'SQL Server Agent alerts do not exist for errors 823, 824, and 825.  These three errors can give you notification about early hardware failure. Enabling them can prevent you a lot of heartbreak.' ) AS Details;
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 61 )
					BEGIN
						IF NOT EXISTS ( SELECT  *
										FROM    msdb.dbo.sysalerts
										WHERE   severity BETWEEN 19 AND 25 )
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  61 AS CheckID ,
											200 AS Priority ,
											'Monitoring' AS FindingsGroup ,
											'No Alerts for Sev 19-25' AS Finding ,
											'http://BrentOzar.com/go/alert' AS URL ,
											( 'SQL Server Agent alerts do not exist for severity levels 19 through 25.  These are some very severe SQL Server errors. Knowing that these are happening may let you recover from errors faster.' ) AS Details;
					END

		--check for disabled alerts
				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 98 )
					BEGIN
						IF EXISTS ( SELECT  name
									FROM    msdb.dbo.sysalerts
									WHERE   enabled = 0 )
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  98 AS CheckID ,
											200 AS Priority ,
											'Monitoring' AS FindingsGroup ,
											'Alerts Disabled' AS Finding ,
											'http://www.BrentOzar.com/go/alerts/' AS URL ,
											( 'The following Alert is disabled, please review and enable if desired: '
											  + name ) AS Details
									FROM    msdb.dbo.sysalerts
									WHERE   enabled = 0
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 31 )
					BEGIN
						IF NOT EXISTS ( SELECT  *
										FROM    msdb.dbo.sysoperators
										WHERE   enabled = 1 )
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  31 AS CheckID ,
											200 AS Priority ,
											'Monitoring' AS FindingsGroup ,
											'No Operators Configured/Enabled' AS Finding ,
											'http://BrentOzar.com/go/op' AS URL ,
											( 'No SQL Server Agent operators (emails) have been configured.  This is a free, easy way to get notified of corruption, job failures, or major outages even before monitoring systems pick it up.' ) AS Details;
					END



				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 34 )
					BEGIN
						IF EXISTS ( SELECT  *
									FROM    sys.all_objects
									WHERE   name = 'dm_db_mirroring_auto_page_repair' )
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults
				(CheckID,
				DatabaseName,
				Priority,
				FindingsGroup,
				Finding,
				URL,
				Details)
		  SELECT DISTINCT
		  34 AS CheckID ,
		  db.name ,
		  1 AS Priority ,
		  ''Corruption'' AS FindingsGroup ,
		  ''Database Corruption Detected'' AS Finding ,
		  ''http://BrentOzar.com/go/repair'' AS URL ,
		  ( ''Database mirroring has automatically repaired at least one corrupt page in the last 30 days. For more information, query the DMV sys.dm_db_mirroring_auto_page_repair.'' ) AS Details
		  FROM (SELECT rp2.database_id, rp2.modification_time 
			FROM sys.dm_db_mirroring_auto_page_repair rp2 
			WHERE rp2.[database_id] not in (
			SELECT db2.[database_id] 
			FROM sys.databases as db2 
			WHERE db2.[state] = 1
			) ) as rp 
		  INNER JOIN master.sys.databases db ON rp.database_id = db.database_id
		  WHERE   rp.modification_time >= DATEADD(dd, -30, GETDATE()) ;'
								EXECUTE(@StringToExecute)
							END;
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 89 )
					BEGIN
						IF EXISTS ( SELECT  *
									FROM    sys.all_objects
									WHERE   name = 'dm_hadr_auto_page_repair' )
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults
				(CheckID,
				DatabaseName,
				Priority,
				FindingsGroup,
				Finding,
				URL,
				Details)
		  SELECT DISTINCT
		  89 AS CheckID ,
		  db.name ,
		  1 AS Priority ,
		  ''Corruption'' AS FindingsGroup ,
		  ''Database Corruption Detected'' AS Finding ,
		  ''http://BrentOzar.com/go/repair'' AS URL ,
		  ( ''AlwaysOn has automatically repaired at least one corrupt page in the last 30 days. For more information, query the DMV sys.dm_hadr_auto_page_repair.'' ) AS Details
		  FROM    sys.dm_hadr_auto_page_repair rp
		  INNER JOIN master.sys.databases db ON rp.database_id = db.database_id
		  WHERE   rp.modification_time >= DATEADD(dd, -30, GETDATE()) ;'
								EXECUTE(@StringToExecute)
							END;
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 90 )
					BEGIN
						IF EXISTS ( SELECT  *
									FROM    msdb.sys.all_objects
									WHERE   name = 'suspect_pages' )
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults
				(CheckID,
				DatabaseName,
				Priority,
				FindingsGroup,
				Finding,
				URL,
				Details)
		  SELECT DISTINCT
		  90 AS CheckID ,
		  db.name ,
		  1 AS Priority ,
		  ''Corruption'' AS FindingsGroup ,
		  ''Database Corruption Detected'' AS Finding ,
		  ''http://BrentOzar.com/go/repair'' AS URL ,
		  ( ''SQL Server has detected at least one corrupt page in the last 30 days. For more information, query the system table msdb.dbo.suspect_pages.'' ) AS Details
		  FROM    msdb.dbo.suspect_pages sp
		  INNER JOIN master.sys.databases db ON sp.database_id = db.database_id
		  WHERE   sp.last_update_date >= DATEADD(dd, -30, GETDATE()) ;'
								EXECUTE(@StringToExecute)
							END;
					END


				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 36 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT DISTINCT
										36 AS CheckID ,
										150 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Slow Storage Reads on Drive '
										+ UPPER(LEFT(mf.physical_name, 1)) AS Finding ,
										'http://BrentOzar.com/go/slow' AS URL ,
										'Reads are averaging longer than 200ms for at least one database on this drive.  For specific database file speeds, run the query from the information link.' AS Details
								FROM    sys.dm_io_virtual_file_stats(NULL, NULL)
										AS fs
										INNER JOIN sys.master_files AS mf ON fs.database_id = mf.database_id
																  AND fs.[file_id] = mf.[file_id]
								WHERE   ( io_stall_read_ms / ( 1.0 + num_of_reads ) ) > 200
								AND num_of_reads > 100000;
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 37 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT DISTINCT
										37 AS CheckID ,
										150 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Slow Storage Writes on Drive '
										+ UPPER(LEFT(mf.physical_name, 1)) AS Finding ,
										'http://BrentOzar.com/go/slow' AS URL ,
										'Writes are averaging longer than 100ms for at least one database on this drive.  For specific database file speeds, run the query from the information link.' AS Details
								FROM    sys.dm_io_virtual_file_stats(NULL, NULL)
										AS fs
										INNER JOIN sys.master_files AS mf ON fs.database_id = mf.database_id
																  AND fs.[file_id] = mf.[file_id]
								WHERE   ( io_stall_write_ms / ( 1.0
																+ num_of_writes ) ) > 100
																AND num_of_writes > 100000;
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 40 )
					BEGIN
						IF ( SELECT COUNT(*)
							 FROM   tempdb.sys.database_files
							 WHERE  type_desc = 'ROWS'
						   ) = 1
							BEGIN
								INSERT  INTO #BlitzResults
										( CheckID ,
										  DatabaseName ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details
										)
								VALUES  ( 40 ,
										  'tempdb' ,
										  170 ,
										  'File Configuration' ,
										  'TempDB Only Has 1 Data File' ,
										  'http://BrentOzar.com/go/tempdb' ,
										  'TempDB is only configured with one data file.  More data files are usually required to alleviate SGAM contention.'
										);
							END;
					END

						IF ( SELECT COUNT (distinct [size])
							FROM   tempdb.sys.database_files
							WHERE  type_desc = 'ROWS'
							) <> 1
							BEGIN
								INSERT  INTO #BlitzResults
										( CheckID ,
										  DatabaseName ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details
										)
								VALUES  ( 183 ,
										  'tempdb' ,
										  170 ,
										  'File Configuration' ,
										  'TempDB Unevenly Sized Data Files' ,
										  'http://BrentOzar.com/go/tempdb' ,
										  'TempDB data files are not configured with the same size.  Unevenly sized tempdb data files will result in unevenly sized workloads.'
										);
							END;

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 44 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  44 AS CheckID ,
										150 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Queries Forcing Order Hints' AS Finding ,
										'http://BrentOzar.com/go/hints' AS URL ,
										CAST(occurrence AS VARCHAR(10))
										+ ' instances of order hinting have been recorded since restart.  This means queries are bossing the SQL Server optimizer around, and if they don''t know what they''re doing, this can cause more harm than good.  This can also explain why DBA tuning efforts aren''t working.' AS Details
								FROM    sys.dm_exec_query_optimizer_info
								WHERE   counter = 'order hint'
										AND occurrence > 1000
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 45 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  45 AS CheckID ,
										150 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Queries Forcing Join Hints' AS Finding ,
										'http://BrentOzar.com/go/hints' AS URL ,
										CAST(occurrence AS VARCHAR(10))
										+ ' instances of join hinting have been recorded since restart.  This means queries are bossing the SQL Server optimizer around, and if they don''t know what they''re doing, this can cause more harm than good.  This can also explain why DBA tuning efforts aren''t working.' AS Details
								FROM    sys.dm_exec_query_optimizer_info
								WHERE   counter = 'join hint'
										AND occurrence > 1000
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 49 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT DISTINCT
										49 AS CheckID ,
										200 AS Priority ,
										'Informational' AS FindingsGroup ,
										'Linked Server Configured' AS Finding ,
										'http://BrentOzar.com/go/link' AS URL ,
										+CASE WHEN l.remote_name = 'sa'
											  THEN s.data_source
												   + ' is configured as a linked server. Check its security configuration as it is connecting with sa, because any user who queries it will get admin-level permissions.'
											  ELSE s.data_source
												   + ' is configured as a linked server. Check its security configuration to make sure it isn''t connecting with SA or some other bone-headed administrative login, because any user who queries it might get admin-level permissions.'
										 END AS Details
								FROM    sys.servers s
										INNER JOIN sys.linked_logins l ON s.server_id = l.server_id
								WHERE   s.is_linked = 1
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 50 )
					BEGIN
						IF @@VERSION NOT LIKE '%Microsoft SQL Server 2000%'
							AND @@VERSION NOT LIKE '%Microsoft SQL Server 2005%'
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
		  SELECT  50 AS CheckID ,
		  100 AS Priority ,
		  ''Performance'' AS FindingsGroup ,
		  ''Max Memory Set Too High'' AS Finding ,
		  ''http://BrentOzar.com/go/max'' AS URL ,
		  ''SQL Server max memory is set to ''
			+ CAST(c.value_in_use AS VARCHAR(20))
			+ '' megabytes, but the server only has ''
			+ CAST(( CAST(m.total_physical_memory_kb AS BIGINT) / 1024 ) AS VARCHAR(20))
			+ '' megabytes.  SQL Server may drain the system dry of memory, and under certain conditions, this can cause Windows to swap to disk.'' AS Details
		  FROM    sys.dm_os_sys_memory m
		  INNER JOIN sys.configurations c ON c.name = ''max server memory (MB)''
		  WHERE   CAST(m.total_physical_memory_kb AS BIGINT) < ( CAST(c.value_in_use AS BIGINT) * 1024 )'
								EXECUTE(@StringToExecute)
							END;
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 51 )
					BEGIN
						IF @@VERSION NOT LIKE '%Microsoft SQL Server 2000%'
							AND @@VERSION NOT LIKE '%Microsoft SQL Server 2005%'
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
		  SELECT  51 AS CheckID ,
		  1 AS Priority ,
		  ''Performance'' AS FindingsGroup ,
		  ''Memory Dangerously Low'' AS Finding ,
		  ''http://BrentOzar.com/go/max'' AS URL ,
		  ''The server has '' + CAST(( CAST(m.total_physical_memory_kb AS BIGINT) / 1024 ) AS VARCHAR(20)) + '' megabytes of physical memory, but only '' + CAST(( CAST(m.available_physical_memory_kb AS BIGINT) / 1024 ) AS VARCHAR(20))
			+ '' megabytes are available.  As the server runs out of memory, there is danger of swapping to disk, which will kill performance.'' AS Details
		  FROM    sys.dm_os_sys_memory m
		  WHERE   CAST(m.available_physical_memory_kb AS BIGINT) < 262144'
								EXECUTE(@StringToExecute)
							END;
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 159 )
					BEGIN
						IF @@VERSION NOT LIKE '%Microsoft SQL Server 2000%'
							AND @@VERSION NOT LIKE '%Microsoft SQL Server 2005%'
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
		  SELECT DISTINCT 159 AS CheckID ,
		  1 AS Priority ,
		  ''Performance'' AS FindingsGroup ,
		  ''Memory Dangerously Low in NUMA Nodes'' AS Finding ,
		  ''http://BrentOzar.com/go/max'' AS URL ,
		  ''At least one NUMA node is reporting THREAD_RESOURCES_LOW in sys.dm_os_nodes and can no longer create threads.'' AS Details
		  FROM    sys.dm_os_nodes m
		  WHERE   node_state_desc LIKE ''%THREAD_RESOURCES_LOW%'''
								EXECUTE(@StringToExecute)
							END;
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 53 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT TOP 1
										53 AS CheckID ,
										200 AS Priority ,
										'Informational' AS FindingsGroup ,
										'Cluster Node' AS Finding ,
										'http://BrentOzar.com/go/node' AS URL ,
										'This is a node in a cluster.' AS Details
								FROM    sys.dm_os_cluster_nodes
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 55 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  55 AS CheckID ,
										[name] AS DatabaseName ,
										230 AS Priority ,
										'Security' AS FindingsGroup ,
										'Database Owner <> SA' AS Finding ,
										'http://BrentOzar.com/go/owndb' AS URL ,
										( 'Database name: ' + [name] + '   '
										  + 'Owner name: ' + SUSER_SNAME(owner_sid) ) AS Details
								FROM    sys.databases
								WHERE   SUSER_SNAME(owner_sid) <> SUSER_SNAME(0x01)
										AND name NOT IN ( SELECT DISTINCT
																  DatabaseName
														  FROM    #SkipChecks 
														  WHERE CheckID IS NULL);
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 57 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  57 AS CheckID ,
										230 AS Priority ,
										'Security' AS FindingsGroup ,
										'SQL Agent Job Runs at Startup' AS Finding ,
										'http://BrentOzar.com/go/startup' AS URL ,
										( 'Job [' + j.name
										  + '] runs automatically when SQL Server Agent starts up.  Make sure you know exactly what this job is doing, because it could pose a security risk.' ) AS Details
								FROM    msdb.dbo.sysschedules sched
										JOIN msdb.dbo.sysjobschedules jsched ON sched.schedule_id = jsched.schedule_id
										JOIN msdb.dbo.sysjobs j ON jsched.job_id = j.job_id
								WHERE   sched.freq_type = 64
								        AND sched.enabled = 1;
					END



				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 97 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  97 AS CheckID ,
										100 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Unusual SQL Server Edition' AS Finding ,
										'http://BrentOzar.com/go/workgroup' AS URL ,
										( 'This server is using '
										  + CAST(SERVERPROPERTY('edition') AS VARCHAR(100))
										  + ', which is capped at low amounts of CPU and memory.' ) AS Details
								WHERE   CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) NOT LIKE '%Standard%'
										AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) NOT LIKE '%Enterprise%'
										AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) NOT LIKE '%Data Center%'
										AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) NOT LIKE '%Developer%'
										AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) NOT LIKE '%Business Intelligence%'
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 154 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  154 AS CheckID ,
										10 AS Priority ,
										'Performance' AS FindingsGroup ,
										'32-bit SQL Server Installed' AS Finding ,
										'http://BrentOzar.com/go/32bit' AS URL ,
										( 'This server uses the 32-bit x86 binaries for SQL Server instead of the 64-bit x64 binaries. The amount of memory available for query workspace and execution plans is heavily limited.' ) AS Details
								WHERE   CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) NOT LIKE '%64%'
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 62 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  62 AS CheckID ,
										[name] AS DatabaseName ,
										200 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Old Compatibility Level' AS Finding ,
										'http://BrentOzar.com/go/compatlevel' AS URL ,
										( 'Database ' + [name]
										  + ' is compatibility level '
										  + CAST(compatibility_level AS VARCHAR(20))
										  + ', which may cause unwanted results when trying to run queries that have newer T-SQL features.' ) AS Details
								FROM    sys.databases
								WHERE   name NOT IN ( SELECT DISTINCT
																DatabaseName
													  FROM      #SkipChecks 
													  WHERE CheckID IS NULL)
										AND compatibility_level <= 90
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 94 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  94 AS CheckID ,
										200 AS [Priority] ,
										'Monitoring' AS FindingsGroup ,
										'Agent Jobs Without Failure Emails' AS Finding ,
										'http://BrentOzar.com/go/alerts' AS URL ,
										'The job ' + [name]
										+ ' has not been set up to notify an operator if it fails.' AS Details
								FROM    msdb.[dbo].[sysjobs] j
										INNER JOIN ( SELECT DISTINCT
															[job_id]
													 FROM   [msdb].[dbo].[sysjobschedules]
													 WHERE  next_run_date > 0
												   ) s ON j.job_id = s.job_id
								WHERE   j.enabled = 1
										AND j.notify_email_operator_id = 0
										AND j.notify_netsend_operator_id = 0
										AND j.notify_page_operator_id = 0
										AND j.category_id <> 100 /* Exclude SSRS category */
					END


				IF EXISTS ( SELECT  1
							FROM    sys.configurations
							WHERE   name = 'remote admin connections'
									AND value_in_use = 0 )
					AND NOT EXISTS ( SELECT 1
									 FROM   #SkipChecks
									 WHERE  DatabaseName IS NULL AND CheckID = 100 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  100 AS CheckID ,
										50 AS Priority ,
										'Reliability' AS FindingGroup ,
										'Remote DAC Disabled' AS Finding ,
										'http://BrentOzar.com/go/dac' AS URL ,
										'Remote access to the Dedicated Admin Connection (DAC) is not enabled. The DAC can make remote troubleshooting much easier when SQL Server is unresponsive.'
					END


				IF EXISTS ( SELECT  *
							FROM    sys.dm_os_schedulers
							WHERE   is_online = 0 )
					AND NOT EXISTS ( SELECT 1
									 FROM   #SkipChecks
									 WHERE  DatabaseName IS NULL AND CheckID = 101 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  101 AS CheckID ,
										50 AS Priority ,
										'Performance' AS FindingGroup ,
										'CPU Schedulers Offline' AS Finding ,
										'http://BrentOzar.com/go/schedulers' AS URL ,
										'Some CPU cores are not accessible to SQL Server due to affinity masking or licensing problems.'
					END


					IF NOT EXISTS ( SELECT  1
									FROM    #SkipChecks
									WHERE   DatabaseName IS NULL AND CheckID = 110 )
								AND EXISTS (SELECT * FROM master.sys.all_objects WHERE name = 'dm_os_memory_nodes')
						BEGIN
							SET @StringToExecute = 'IF EXISTS (SELECT  *
												FROM sys.dm_os_nodes n
												INNER JOIN sys.dm_os_memory_nodes m ON n.memory_node_id = m.memory_node_id
												WHERE n.node_state_desc = ''OFFLINE'')
												INSERT  INTO #BlitzResults
														( CheckID ,
														  Priority ,
														  FindingsGroup ,
														  Finding ,
														  URL ,
														  Details
														)
														SELECT  110 AS CheckID ,
																50 AS Priority ,
																''Performance'' AS FindingGroup ,
																''Memory Nodes Offline'' AS Finding ,
																''http://BrentOzar.com/go/schedulers'' AS URL ,
																''Due to affinity masking or licensing problems, some of the memory may not be available.''';
									EXECUTE(@StringToExecute);
						END


				IF EXISTS ( SELECT  *
							FROM    sys.databases
							WHERE   state > 1 )
					AND NOT EXISTS ( SELECT 1
									 FROM   #SkipChecks
									 WHERE  DatabaseName IS NULL AND CheckID = 102 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  102 AS CheckID ,
										[name] ,
										20 AS Priority ,
										'Reliability' AS FindingGroup ,
										'Unusual Database State: ' + [state_desc] AS Finding ,
										'http://BrentOzar.com/go/repair' AS URL ,
										'This database may not be online.'
								FROM    sys.databases
								WHERE   state > 1
					END

				IF EXISTS ( SELECT  *
							FROM    master.sys.extended_procedures )
					AND NOT EXISTS ( SELECT 1
									 FROM   #SkipChecks
									 WHERE  DatabaseName IS NULL AND CheckID = 105 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  105 AS CheckID ,
										'master' ,
										200 AS Priority ,
										'Reliability' AS FindingGroup ,
										'Extended Stored Procedures in Master' AS Finding ,
										'http://BrentOzar.com/go/clr' AS URL ,
										'The [' + name
										+ '] extended stored procedure is in the master database. CLR may be in use, and the master database now needs to be part of your backup/recovery planning.'
								FROM    master.sys.extended_procedures
					END



					IF NOT EXISTS ( SELECT 1
										 FROM   #SkipChecks
										 WHERE  DatabaseName IS NULL AND CheckID = 107 )
						BEGIN
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  107 AS CheckID ,
											50 AS Priority ,
											'Performance' AS FindingGroup ,
											'Poison Wait Detected: THREADPOOL'  AS Finding ,
											'http://BrentOzar.com/go/poison' AS URL ,
											CONVERT(VARCHAR(10), (SUM([wait_time_ms]) / 1000) / 86400) + ':' + CONVERT(VARCHAR(20), DATEADD(s, (SUM([wait_time_ms]) / 1000), 0), 108) + ' of this wait have been recorded. This wait often indicates killer performance problems.'
									FROM sys.[dm_os_wait_stats]
									WHERE wait_type = 'THREADPOOL'
									GROUP BY wait_type
								    HAVING SUM([wait_time_ms]) > (SELECT 5000 * datediff(HH,create_date,CURRENT_TIMESTAMP) AS hours_since_startup FROM sys.databases WHERE name='tempdb')
									AND SUM([wait_time_ms]) > 60000
						END

					IF NOT EXISTS ( SELECT 1
										 FROM   #SkipChecks
										 WHERE  DatabaseName IS NULL AND CheckID = 108 )
						BEGIN
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  108 AS CheckID ,
											50 AS Priority ,
											'Performance' AS FindingGroup ,
											'Poison Wait Detected: RESOURCE_SEMAPHORE'  AS Finding ,
											'http://BrentOzar.com/go/poison' AS URL ,
											CONVERT(VARCHAR(10), (SUM([wait_time_ms]) / 1000) / 86400) + ':' + CONVERT(VARCHAR(20), DATEADD(s, (SUM([wait_time_ms]) / 1000), 0), 108) + ' of this wait have been recorded. This wait often indicates killer performance problems.'
									FROM sys.[dm_os_wait_stats]
									WHERE wait_type = 'RESOURCE_SEMAPHORE'
									GROUP BY wait_type
								    HAVING SUM([wait_time_ms]) > (SELECT 5000 * datediff(HH,create_date,CURRENT_TIMESTAMP) AS hours_since_startup FROM sys.databases WHERE name='tempdb')
									AND SUM([wait_time_ms]) > 60000
						END


					IF NOT EXISTS ( SELECT 1
										 FROM   #SkipChecks
										 WHERE  DatabaseName IS NULL AND CheckID = 109 )
						BEGIN
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  109 AS CheckID ,
											50 AS Priority ,
											'Performance' AS FindingGroup ,
											'Poison Wait Detected: RESOURCE_SEMAPHORE_QUERY_COMPILE'  AS Finding ,
											'http://BrentOzar.com/go/poison' AS URL ,
											CONVERT(VARCHAR(10), (SUM([wait_time_ms]) / 1000) / 86400) + ':' + CONVERT(VARCHAR(20), DATEADD(s, (SUM([wait_time_ms]) / 1000), 0), 108) + ' of this wait have been recorded. This wait often indicates killer performance problems.'
									FROM sys.[dm_os_wait_stats]
									WHERE wait_type = 'RESOURCE_SEMAPHORE_QUERY_COMPILE'
									GROUP BY wait_type
								    HAVING SUM([wait_time_ms]) > (SELECT 5000 * datediff(HH,create_date,CURRENT_TIMESTAMP) AS hours_since_startup FROM sys.databases WHERE name='tempdb')
									AND SUM([wait_time_ms]) > 60000
						END


					IF NOT EXISTS ( SELECT 1
										 FROM   #SkipChecks
										 WHERE  DatabaseName IS NULL AND CheckID = 121 )
						BEGIN
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  121 AS CheckID ,
											50 AS Priority ,
											'Performance' AS FindingGroup ,
											'Poison Wait Detected: Serializable Locking'  AS Finding ,
											'http://BrentOzar.com/go/serializable' AS URL ,
											CONVERT(VARCHAR(10), (SUM([wait_time_ms]) / 1000) / 86400) + ':' + CONVERT(VARCHAR(20), DATEADD(s, (SUM([wait_time_ms]) / 1000), 0), 108) + ' of LCK_M_R% waits have been recorded. This wait often indicates killer performance problems.'
									FROM sys.[dm_os_wait_stats]
									WHERE wait_type IN ('LCK_M_RS_S', 'LCK_M_RS_U', 'LCK_M_RIn_NL','LCK_M_RIn_S', 'LCK_M_RIn_U','LCK_M_RIn_X', 'LCK_M_RX_S', 'LCK_M_RX_U','LCK_M_RX_X')
								    HAVING SUM([wait_time_ms]) > (SELECT 5000 * datediff(HH,create_date,CURRENT_TIMESTAMP) AS hours_since_startup FROM sys.databases WHERE name='tempdb')
									AND SUM([wait_time_ms]) > 60000
						END




					IF @ProductVersionMajor >= 11 AND NOT EXISTS ( SELECT 1
										 FROM   #SkipChecks
										 WHERE  DatabaseName IS NULL AND CheckID = 162 )
						BEGIN
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  162 AS CheckID ,
											50 AS Priority ,
											'Performance' AS FindingGroup ,
											'Poison Wait Detected: CMEMTHREAD & NUMA'  AS Finding ,
											'http://BrentOzar.com/go/poison' AS URL ,
											CONVERT(VARCHAR(10), (SUM([wait_time_ms]) / 1000) / 86400) + ':' + CONVERT(VARCHAR(20), DATEADD(s, (SUM([wait_time_ms]) / 1000), 0), 108) + ' of this wait have been recorded. In servers with over 8 cores per NUMA node, when CMEMTHREAD waits are a bottleneck, trace flag 8048 may be needed.'
									FROM sys.dm_os_nodes n 
									INNER JOIN sys.[dm_os_wait_stats] w ON w.wait_type = 'CMEMTHREAD'
									WHERE n.node_id = 0 AND n.online_scheduler_count >= 8
									GROUP BY w.wait_type
								    HAVING SUM([wait_time_ms]) > (SELECT 5000 * datediff(HH,create_date,CURRENT_TIMESTAMP) AS hours_since_startup FROM sys.databases WHERE name='tempdb')
									AND SUM([wait_time_ms]) > 60000;
						END




						IF NOT EXISTS ( SELECT 1
										 FROM   #SkipChecks
										 WHERE  DatabaseName IS NULL AND CheckID = 111 )
						BEGIN
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  DatabaseName ,
									  URL ,
									  Details
									)
									SELECT  111 AS CheckID ,
											50 AS Priority ,
											'Reliability' AS FindingGroup ,
											'Possibly Broken Log Shipping'  AS Finding ,
											d.[name] ,
											'http://BrentOzar.com/go/shipping' AS URL ,
											d.[name] + ' is in a restoring state, but has not had a backup applied in the last two days. This is a possible indication of a broken transaction log shipping setup.'
											FROM [master].sys.databases d
											INNER JOIN [master].sys.database_mirroring dm ON d.database_id = dm.database_id
												AND dm.mirroring_role IS NULL
											WHERE ( d.[state] = 1
											OR (d.[state] = 0 AND d.[is_in_standby] = 1) )
											AND NOT EXISTS(SELECT * FROM msdb.dbo.restorehistory rh
											INNER JOIN msdb.dbo.backupset bs ON rh.backup_set_id = bs.backup_set_id
											WHERE d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = rh.destination_database_name COLLATE SQL_Latin1_General_CP1_CI_AS
											AND rh.restore_date >= DATEADD(dd, -2, GETDATE()))

						END


						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 112 )
									AND EXISTS (SELECT * FROM master.sys.all_objects WHERE name = 'change_tracking_databases')
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults
									(CheckID,
									Priority,
									FindingsGroup,
									Finding,
									URL,
									Details)
							  SELECT 112 AS CheckID,
							  100 AS Priority,
							  ''Performance'' AS FindingsGroup,
							  ''Change Tracking Enabled'' AS Finding,
							  ''http://BrentOzar.com/go/tracking'' AS URL,
							  ( d.[name] + '' has change tracking enabled. This is not a default setting, and it has some performance overhead. It keeps track of changes to rows in tables that have change tracking turned on.'' ) AS Details FROM sys.change_tracking_databases AS ctd INNER JOIN sys.databases AS d ON ctd.database_id = d.database_id';
										EXECUTE(@StringToExecute);
							END


						IF NOT EXISTS ( SELECT 1
										 FROM   #SkipChecks
										 WHERE  DatabaseName IS NULL AND CheckID = 116 )
									AND EXISTS (SELECT * FROM msdb.sys.all_columns WHERE name = 'compressed_backup_size')
						BEGIN
							SET @StringToExecute = 'INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  116 AS CheckID ,
											200 AS Priority ,
											''Informational'' AS FindingGroup ,
											''Backup Compression Default Off''  AS Finding ,
											''http://BrentOzar.com/go/backup'' AS URL ,
											''Uncompressed full backups have happened recently, and backup compression is not turned on at the server level. Backup compression is included with SQL Server 2008R2 & newer, even in Standard Edition. We recommend turning backup compression on by default so that ad-hoc backups will get compressed.''
											FROM sys.configurations
											WHERE configuration_id = 1579 AND CAST(value_in_use AS INT) = 0
                                            AND EXISTS (SELECT * FROM msdb.dbo.backupset WHERE backup_size = compressed_backup_size AND type = ''D'' AND backup_finish_date >= DATEADD(DD, -14, GETDATE()));'
										EXECUTE(@StringToExecute);
						END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 117 )
									AND EXISTS (SELECT * FROM master.sys.all_objects WHERE name = 'dm_exec_query_resource_semaphores')
							BEGIN
								SET @StringToExecute = 'IF 0 < (SELECT SUM([forced_grant_count]) FROM sys.dm_exec_query_resource_semaphores WHERE [forced_grant_count] IS NOT NULL)
								INSERT INTO #BlitzResults
									(CheckID,
									Priority,
									FindingsGroup,
									Finding,
									URL,
									Details)
							  SELECT 117 AS CheckID,
							  100 AS Priority,
							  ''Performance'' AS FindingsGroup,
							  ''Memory Pressure Affecting Queries'' AS Finding,
							  ''http://BrentOzar.com/go/grants'' AS URL,
							  CAST(SUM(forced_grant_count) AS NVARCHAR(100)) + '' forced grants reported in the DMV sys.dm_exec_query_resource_semaphores, indicating memory pressure has affected query runtimes.''
							  FROM sys.dm_exec_query_resource_semaphores WHERE [forced_grant_count] IS NOT NULL;'
										EXECUTE(@StringToExecute);
							END



						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 124 )
							BEGIN
								INSERT INTO #BlitzResults
									(CheckID,
									Priority,
									FindingsGroup,
									Finding,
									URL,
									Details)
								SELECT 124, 150, 'Performance', 'Deadlocks Happening Daily', 'http://BrentOzar.com/go/deadlocks',
									CAST(p.cntr_value AS NVARCHAR(100)) + ' deadlocks have been recorded since startup.' AS Details
								FROM sys.dm_os_performance_counters p
									INNER JOIN sys.databases d ON d.name = 'tempdb'
								WHERE RTRIM(p.counter_name) = 'Number of Deadlocks/sec'
									AND RTRIM(p.instance_name) = '_Total'
									AND p.cntr_value > 0
									AND (1.0 * p.cntr_value / NULLIF(datediff(DD,create_date,CURRENT_TIMESTAMP),0)) > 10;
							END


						IF DATEADD(mi, -15, GETDATE()) < (SELECT TOP 1 creation_time FROM sys.dm_exec_query_stats ORDER BY creation_time)
						BEGIN
							INSERT INTO #BlitzResults
								(CheckID,
								Priority,
								FindingsGroup,
								Finding,
								URL,
								Details)
							SELECT TOP 1 125, 10, 'Performance', 'Plan Cache Erased Recently', 'http://BrentOzar.com/askbrent/plan-cache-erased-recently/',
								'The oldest query in the plan cache was created at ' + CAST(creation_time AS NVARCHAR(50)) + '. Someone ran DBCC FREEPROCCACHE, restarted SQL Server, or it is under horrific memory pressure.'
							FROM sys.dm_exec_query_stats WITH (NOLOCK)
							ORDER BY creation_time	
						END;

						IF EXISTS (SELECT * FROM sys.configurations WHERE name = 'priority boost' AND (value = 1 OR value_in_use = 1))
						BEGIN
							INSERT INTO #BlitzResults
								(CheckID,
								Priority,
								FindingsGroup,
								Finding,
								URL,
								Details)
							VALUES(126, 5, 'Reliability', 'Priority Boost Enabled', 'http://BrentOzar.com/go/priorityboost/',
								'Priority Boost sounds awesome, but it can actually cause your SQL Server to crash.')
						END;

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 128 )
							BEGIN

							IF (@ProductVersionMajor = 12 AND @ProductVersionMinor < 2000) OR
							   (@ProductVersionMajor = 11 AND @ProductVersionMinor < 3000) OR
							   (@ProductVersionMajor = 10.5 AND @ProductVersionMinor < 6000) OR
							   (@ProductVersionMajor = 10 AND @ProductVersionMinor < 6000) OR
							   (@ProductVersionMajor = 9 /*AND @ProductVersionMinor <= 5000*/)
								BEGIN
								INSERT INTO #BlitzResults(CheckID, Priority, FindingsGroup, Finding, URL, Details)
									VALUES(128, 20, 'Reliability', 'Unsupported Build of SQL Server', 'http://BrentOzar.com/go/unsupported',
										'Version ' + CAST(@ProductVersionMajor AS VARCHAR(100)) + '.' + 
										CASE WHEN @ProductVersionMajor > 9 THEN
										CAST(@ProductVersionMinor AS VARCHAR(100)) + ' is no longer supported by Microsoft. You need to apply a service pack.'
										ELSE ' is no longer support by Microsoft. You should be making plans to upgrade to a modern version of SQL Server.' END);
								END;

							END;
							
						/* Reliability - Dangerous Build of SQL Server (Corruption) */
						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 129 )
							BEGIN
							IF (@ProductVersionMajor = 11 AND @ProductVersionMinor >= 3000 AND @ProductVersionMinor <= 3436) OR
							   (@ProductVersionMajor = 11 AND @ProductVersionMinor = 5058) OR
							   (@ProductVersionMajor = 12 AND @ProductVersionMinor >= 2000 AND @ProductVersionMinor <= 2342)
								BEGIN
								INSERT INTO #BlitzResults(CheckID, Priority, FindingsGroup, Finding, URL, Details)
									VALUES(129, 20, 'Reliability', 'Dangerous Build of SQL Server (Corruption)', 'http://sqlperformance.com/2014/06/sql-indexes/hotfix-sql-2012-rebuilds',
										'There are dangerous known bugs with version ' + CAST(@ProductVersionMajor AS VARCHAR(100)) + '.' + CAST(@ProductVersionMinor AS VARCHAR(100)) + '. Check the URL for details and apply the right service pack or hotfix.');
								END;

							END;

						/* Reliability - Dangerous Build of SQL Server (Security) */
						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 157 )
							BEGIN
							IF (@ProductVersionMajor = 10 AND @ProductVersionMinor >= 5500 AND @ProductVersionMinor <= 5512) OR
							   (@ProductVersionMajor = 10 AND @ProductVersionMinor >= 5750 AND @ProductVersionMinor <= 5867) OR
							   (@ProductVersionMajor = 10.5 AND @ProductVersionMinor >= 4000 AND @ProductVersionMinor <= 4017) OR
							   (@ProductVersionMajor = 10.5 AND @ProductVersionMinor >= 4251 AND @ProductVersionMinor <= 4319) OR
							   (@ProductVersionMajor = 11 AND @ProductVersionMinor >= 3000 AND @ProductVersionMinor <= 3129) OR
							   (@ProductVersionMajor = 11 AND @ProductVersionMinor >= 3300 AND @ProductVersionMinor <= 3447) OR
							   (@ProductVersionMajor = 12 AND @ProductVersionMinor >= 2000 AND @ProductVersionMinor <= 2253) OR
							   (@ProductVersionMajor = 12 AND @ProductVersionMinor >= 2300 AND @ProductVersionMinor <= 2370)
								BEGIN
								INSERT INTO #BlitzResults(CheckID, Priority, FindingsGroup, Finding, URL, Details)
									VALUES(157, 20, 'Reliability', 'Dangerous Build of SQL Server (Security)', 'https://technet.microsoft.com/en-us/library/security/MS14-044',
										'There are dangerous known bugs with version ' + CAST(@ProductVersionMajor AS VARCHAR(100)) + '.' + CAST(@ProductVersionMinor AS VARCHAR(100)) + '. Check the URL for details and apply the right service pack or hotfix.');
								END;

							END;
						
						/* Check if SQL 2016 Standard Edition but not SP1 */
						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 189 )
							BEGIN
							IF (@ProductVersionMajor = 13 AND @ProductVersionMinor < 4001 AND @@VERSION LIKE '%Standard Edition%') 
								BEGIN
								INSERT INTO #BlitzResults(CheckID, Priority, FindingsGroup, Finding, URL, Details)
									VALUES(189, 100, 'Features', 'Missing Features', 'https://blogs.msdn.microsoft.com/sqlreleaseservices/sql-server-2016-service-pack-1-sp1-released/',
										'SQL 2016 Standard Edition is being used but not Service Pack 1. Check the URL for a list of Enterprise Features that are included in Standard Edition as of SP1.');
								END;

							END;						

                        /* Performance - High Memory Use for In-Memory OLTP (Hekaton) */
                        IF NOT EXISTS ( SELECT  1
				                        FROM    #SkipChecks
				                        WHERE   DatabaseName IS NULL AND CheckID = 145 )
	                        AND EXISTS ( SELECT *
					                        FROM   sys.all_objects o
					                        WHERE  o.name = 'dm_db_xtp_table_memory_stats' )
	                        BEGIN
		                        SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
			                        SELECT 145 AS CheckID,
			                        10 AS Priority,
			                        ''Performance'' AS FindingsGroup,
			                        ''High Memory Use for In-Memory OLTP (Hekaton)'' AS Finding,
			                        ''http://BrentOzar.com/go/hekaton'' AS URL,
			                        CAST(CAST((SUM(mem.pages_kb / 1024.0) / CAST(value_in_use AS INT) * 100) AS INT) AS NVARCHAR(100)) + ''% of your '' + CAST(CAST((CAST(value_in_use AS DECIMAL(38,1)) / 1024) AS MONEY) AS NVARCHAR(100)) + ''GB of your max server memory is being used for in-memory OLTP tables (Hekaton). Microsoft recommends having 2X your Hekaton table space available in memory just for Hekaton, with a max of 250GB of in-memory data regardless of your server memory capacity.'' AS Details
			                        FROM sys.configurations c INNER JOIN sys.dm_os_memory_clerks mem ON mem.type = ''MEMORYCLERK_XTP''
                                    WHERE c.name = ''max server memory (MB)''
                                    GROUP BY c.value_in_use
                                    HAVING CAST(value_in_use AS DECIMAL(38,2)) * .25 < SUM(mem.pages_kb / 1024.0)
                                      OR SUM(mem.pages_kb / 1024.0) > 250000';
		                        EXECUTE(@StringToExecute);
	                        END


                        /* Performance - In-Memory OLTP (Hekaton) In Use */
                        IF NOT EXISTS ( SELECT  1
				                        FROM    #SkipChecks
				                        WHERE   DatabaseName IS NULL AND CheckID = 146 )
	                        AND EXISTS ( SELECT *
					                        FROM   sys.all_objects o
					                        WHERE  o.name = 'dm_db_xtp_table_memory_stats' )
	                        BEGIN
		                        SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
			                        SELECT 146 AS CheckID,
			                        200 AS Priority,
			                        ''Performance'' AS FindingsGroup,
			                        ''In-Memory OLTP (Hekaton) In Use'' AS Finding,
			                        ''http://BrentOzar.com/go/hekaton'' AS URL,
			                        CAST(CAST((SUM(mem.pages_kb / 1024.0) / CAST(value_in_use AS INT) * 100) AS INT) AS NVARCHAR(100)) + ''% of your '' + CAST(CAST((CAST(value_in_use AS DECIMAL(38,1)) / 1024) AS MONEY) AS NVARCHAR(100)) + ''GB of your max server memory is being used for in-memory OLTP tables (Hekaton).'' AS Details
			                        FROM sys.configurations c INNER JOIN sys.dm_os_memory_clerks mem ON mem.type = ''MEMORYCLERK_XTP''
                                    WHERE c.name = ''max server memory (MB)''
                                    GROUP BY c.value_in_use
                                    HAVING SUM(mem.pages_kb / 1024.0) > 10';
		                        EXECUTE(@StringToExecute);
	                        END

                        /* In-Memory OLTP (Hekaton) - Transaction Errors */
                        IF NOT EXISTS ( SELECT  1
				                        FROM    #SkipChecks
				                        WHERE   DatabaseName IS NULL AND CheckID = 147 )
	                        AND EXISTS ( SELECT *
					                        FROM   sys.all_objects o
					                        WHERE  o.name = 'dm_xtp_transaction_stats' )
	                        BEGIN
		                        SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
			                        SELECT 147 AS CheckID,
			                        100 AS Priority,
			                        ''In-Memory OLTP (Hekaton)'' AS FindingsGroup,
			                        ''Transaction Errors'' AS Finding,
			                        ''http://BrentOzar.com/go/hekaton'' AS URL,
			                        ''Since restart: '' + CAST(validation_failures AS NVARCHAR(100)) + '' validation failures, '' + CAST(dependencies_failed AS NVARCHAR(100)) + '' dependency failures, '' + CAST(write_conflicts AS NVARCHAR(100)) + '' write conflicts, '' + CAST(unique_constraint_violations AS NVARCHAR(100)) + '' unique constraint violations.'' AS Details
			                        FROM sys.dm_xtp_transaction_stats
                                    WHERE validation_failures <> 0
                                            OR dependencies_failed <> 0
                                            OR write_conflicts <> 0
                                            OR unique_constraint_violations <> 0;'
		                        EXECUTE(@StringToExecute);
	                        END



                        /* Reliability - Database Files on Network File Shares */
                        IF NOT EXISTS ( SELECT  1
				                        FROM    #SkipChecks
				                        WHERE   DatabaseName IS NULL AND CheckID = 148 )
	                        BEGIN
		                        INSERT  INTO #BlitzResults
				                        ( CheckID ,
					                        DatabaseName ,
					                        Priority ,
					                        FindingsGroup ,
					                        Finding ,
					                        URL ,
					                        Details
				                        )
				                        SELECT DISTINCT 148 AS CheckID ,
						                        d.[name] AS DatabaseName ,
						                        170 AS Priority ,
						                        'Reliability' AS FindingsGroup ,
						                        'Database Files on Network File Shares' AS Finding ,
						                        'http://BrentOzar.com/go/nas' AS URL ,
						                        ( 'Files for this database are on: ' + LEFT(mf.physical_name, 30)) AS Details
				                        FROM    sys.databases d
                                          INNER JOIN sys.master_files mf ON d.database_id = mf.database_id
				                        WHERE mf.physical_name LIKE '\\%'
						                        AND d.name NOT IN ( SELECT DISTINCT
													                        DatabaseName
											                        FROM    #SkipChecks 
																	WHERE CheckID IS NULL)
	                        END

                        /* Reliability - Database Files Stored in Azure */
                        IF NOT EXISTS ( SELECT  1
				                        FROM    #SkipChecks
				                        WHERE   DatabaseName IS NULL AND CheckID = 149 )
	                        BEGIN
		                        INSERT  INTO #BlitzResults
				                        ( CheckID ,
					                        DatabaseName ,
					                        Priority ,
					                        FindingsGroup ,
					                        Finding ,
					                        URL ,
					                        Details
				                        )
				                        SELECT DISTINCT 149 AS CheckID ,
						                        d.[name] AS DatabaseName ,
						                        170 AS Priority ,
						                        'Reliability' AS FindingsGroup ,
						                        'Database Files Stored in Azure' AS Finding ,
						                        'http://BrentOzar.com/go/azurefiles' AS URL ,
						                        ( 'Files for this database are on: ' + LEFT(mf.physical_name, 30)) AS Details
				                        FROM    sys.databases d
                                          INNER JOIN sys.master_files mf ON d.database_id = mf.database_id
				                        WHERE mf.physical_name LIKE 'http://%'
						                        AND d.name NOT IN ( SELECT DISTINCT
													                        DatabaseName
											                        FROM    #SkipChecks 
																	WHERE CheckID IS NULL)
	                        END


                        /* Reliability - Errors Logged Recently in the Default Trace */
                        IF NOT EXISTS ( SELECT  1
				                        FROM    #SkipChecks
				                        WHERE   DatabaseName IS NULL AND CheckID = 150 )
                            AND @TracePath IS NOT NULL
	                        BEGIN

		                        INSERT  INTO #BlitzResults
				                        ( CheckID ,
					                        DatabaseName ,
					                        Priority ,
					                        FindingsGroup ,
					                        Finding ,
					                        URL ,
					                        Details
				                        )
				                        SELECT DISTINCT 150 AS CheckID ,
					                            t.DatabaseName,
						                        50 AS Priority ,
						                        'Reliability' AS FindingsGroup ,
						                        'Errors Logged Recently in the Default Trace' AS Finding ,
						                        'http://BrentOzar.com/go/defaulttrace' AS URL ,
						                         CAST(t.TextData AS NVARCHAR(4000)) AS Details
                                        FROM    sys.fn_trace_gettable(@TracePath, DEFAULT) t
                                        WHERE t.EventClass = 22
                                          AND t.Severity >= 17
                                          AND t.StartTime > DATEADD(dd, -30, GETDATE())
	                        END


                        /* Performance - Log File Growths Slow */
                        IF NOT EXISTS ( SELECT  1
				                        FROM    #SkipChecks
				                        WHERE   DatabaseName IS NULL AND CheckID = 151 )
                            AND @TracePath IS NOT NULL
	                        BEGIN
		                        INSERT  INTO #BlitzResults
				                        ( CheckID ,
					                        DatabaseName ,
					                        Priority ,
					                        FindingsGroup ,
					                        Finding ,
					                        URL ,
					                        Details
				                        )
				                        SELECT DISTINCT 151 AS CheckID ,
					                            t.DatabaseName,
						                        50 AS Priority ,
						                        'Performance' AS FindingsGroup ,
						                        'Log File Growths Slow' AS Finding ,
						                        'http://BrentOzar.com/go/filegrowth' AS URL ,
						                        CAST(COUNT(*) AS NVARCHAR(100)) + ' growths took more than 15 seconds each. Consider setting log file autogrowth to a smaller increment.' AS Details
                                        FROM    sys.fn_trace_gettable(@TracePath, DEFAULT) t
                                        WHERE t.EventClass = 93
                                          AND t.StartTime > DATEADD(dd, -30, GETDATE())
                                          AND t.Duration > 15000000
                                        GROUP BY t.DatabaseName
                                        HAVING COUNT(*) > 1
	                        END


                        /* Performance - Many Plans for One Query */
                        IF NOT EXISTS ( SELECT  1
				                        FROM    #SkipChecks
				                        WHERE   DatabaseName IS NULL AND CheckID = 160 )
                            AND EXISTS (SELECT * FROM sys.all_columns WHERE name = 'query_hash')
	                        BEGIN
		                        SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
			                        SELECT TOP 1 160 AS CheckID,
			                        100 AS Priority,
			                        ''Performance'' AS FindingsGroup,
			                        ''Many Plans for One Query'' AS Finding,
			                        ''http://BrentOzar.com/go/parameterization'' AS URL,
			                        CAST(COUNT(DISTINCT plan_handle) AS NVARCHAR(50)) + '' plans are present for a single query in the plan cache - meaning we probably have parameterization issues.'' AS Details
			                        FROM sys.dm_exec_query_stats qs
                                    CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) pa
                                    WHERE pa.attribute = ''dbid''
                                    GROUP BY qs.query_hash, pa.value
                                    HAVING COUNT(DISTINCT plan_handle) > 50
									ORDER BY COUNT(DISTINCT plan_handle) DESC;';
		                        EXECUTE(@StringToExecute);
	                        END


                        /* Performance - High Number of Cached Plans */
                        IF NOT EXISTS ( SELECT  1
				                        FROM    #SkipChecks
				                        WHERE   DatabaseName IS NULL AND CheckID = 161 )
	                        BEGIN
		                        SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
			                        SELECT TOP 1 161 AS CheckID,
			                        100 AS Priority,
			                        ''Performance'' AS FindingsGroup,
			                        ''High Number of Cached Plans'' AS Finding,
			                        ''http://BrentOzar.com/go/planlimits'' AS URL,
			                        ''Your server configuration is limited to '' + CAST(ht.buckets_count * 4 AS VARCHAR(20)) + '' '' + ht.name + '', and you are currently caching '' + CAST(cc.entries_count AS VARCHAR(20)) + ''.'' AS Details
			                        FROM sys.dm_os_memory_cache_hash_tables ht
			                        INNER JOIN sys.dm_os_memory_cache_counters cc ON ht.name = cc.name AND ht.type = cc.type
			                        where ht.name IN ( ''SQL Plans'' , ''Object Plans'' , ''Bound Trees'' )
			                        AND cc.entries_count >= (3 * ht.buckets_count)';
		                        EXECUTE(@StringToExecute);
	                        END


						/* Performance - Too Much Free Memory */
						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 165 )
							BEGIN
								INSERT INTO #BlitzResults
									(CheckID,
									Priority,
									FindingsGroup,
									Finding,
									URL,
									Details)
								SELECT 165, 50, 'Performance', 'Too Much Free Memory', 'http://BrentOzar.com/go/freememory',
									CAST((CAST(cFree.cntr_value AS BIGINT) / 1024 / 1024 ) AS NVARCHAR(100)) + N'GB of free memory inside SQL Server''s buffer pool, which is ' + CAST((CAST(cTotal.cntr_value AS BIGINT) / 1024 / 1024) AS NVARCHAR(100)) + N'GB. You would think lots of free memory would be good, but check out the URL for more information.' AS Details
								FROM sys.dm_os_performance_counters cFree
								INNER JOIN sys.dm_os_performance_counters cTotal ON cTotal.object_name LIKE N'%Memory Manager%'
									AND cTotal.counter_name = N'Total Server Memory (KB)                                                                                                        '
								WHERE cFree.object_name LIKE N'%Memory Manager%'
									AND cFree.counter_name = N'Free Memory (KB)                                                                                                                '
									AND CAST(cTotal.cntr_value AS BIGINT) > 4000
									AND CAST(cTotal.cntr_value AS BIGINT) * .3 <= CAST(cFree.cntr_value AS BIGINT)
                                    AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) NOT LIKE '%Standard%'

							END


                        /* Outdated sp_Blitz - sp_Blitz is Over 6 Months Old */
                        IF NOT EXISTS ( SELECT  1
				                        FROM    #SkipChecks
				                        WHERE   DatabaseName IS NULL AND CheckID = 155 )
				           AND DATEDIFF(MM, @VersionDate, GETDATE()) > 6
	                        BEGIN
		                        INSERT  INTO #BlitzResults
				                        ( CheckID ,
					                        Priority ,
					                        FindingsGroup ,
					                        Finding ,
					                        URL ,
					                        Details
				                        )
				                        SELECT 155 AS CheckID ,
						                        0 AS Priority ,
						                        'Outdated sp_Blitz' AS FindingsGroup ,
						                        'sp_Blitz is Over 6 Months Old' AS Finding ,
						                        'http://FirstResponderKit.org/' AS URL ,
						                        'Some things get better with age, like fine wine and your T-SQL. However, sp_Blitz is not one of those things - time to go download the current one.' AS Details
	                        END


						/* Populate a list of database defaults. I'm doing this kind of oddly -
						    it reads like a lot of work, but this way it compiles & runs on all
						    versions of SQL Server.
						*/
						INSERT INTO #DatabaseDefaults
						  SELECT 'is_supplemental_logging_enabled', 0, 131, 210, 'Supplemental Logging Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'is_supplemental_logging_enabled' AND object_id = OBJECT_ID('sys.databases');
						INSERT INTO #DatabaseDefaults
						  SELECT 'snapshot_isolation_state', 0, 132, 210, 'Snapshot Isolation Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'snapshot_isolation_state' AND object_id = OBJECT_ID('sys.databases');
						INSERT INTO #DatabaseDefaults
						  SELECT 'is_read_committed_snapshot_on', 0, 133, 210, 'Read Committed Snapshot Isolation Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'is_read_committed_snapshot_on' AND object_id = OBJECT_ID('sys.databases');
						INSERT INTO #DatabaseDefaults
						  SELECT 'is_auto_create_stats_incremental_on', 0, 134, 210, 'Auto Create Stats Incremental Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'is_auto_create_stats_incremental_on' AND object_id = OBJECT_ID('sys.databases');
						INSERT INTO #DatabaseDefaults
						  SELECT 'is_ansi_null_default_on', 0, 135, 210, 'ANSI NULL Default Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'is_ansi_null_default_on' AND object_id = OBJECT_ID('sys.databases');
						INSERT INTO #DatabaseDefaults
						  SELECT 'is_recursive_triggers_on', 0, 136, 210, 'Recursive Triggers Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'is_recursive_triggers_on' AND object_id = OBJECT_ID('sys.databases');
						INSERT INTO #DatabaseDefaults
						  SELECT 'is_trustworthy_on', 0, 137, 210, 'Trustworthy Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'is_trustworthy_on' AND object_id = OBJECT_ID('sys.databases');
						INSERT INTO #DatabaseDefaults
						  SELECT 'is_parameterization_forced', 0, 138, 210, 'Forced Parameterization Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'is_parameterization_forced' AND object_id = OBJECT_ID('sys.databases');
						/* Not alerting for this since we actually want it and we have a separate check for it:
						INSERT INTO #DatabaseDefaults
						  SELECT 'is_query_store_on', 0, 139, 210, 'Query Store Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'is_query_store_on' AND object_id = OBJECT_ID('sys.databases');
						*/
						INSERT INTO #DatabaseDefaults
						  SELECT 'is_cdc_enabled', 0, 140, 210, 'Change Data Capture Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'is_cdc_enabled' AND object_id = OBJECT_ID('sys.databases');
						INSERT INTO #DatabaseDefaults
						  SELECT 'containment', 0, 141, 210, 'Containment Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'containment' AND object_id = OBJECT_ID('sys.databases');
						INSERT INTO #DatabaseDefaults
						  SELECT 'target_recovery_time_in_seconds', 0, 142, 210, 'Target Recovery Time Changed', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'target_recovery_time_in_seconds' AND object_id = OBJECT_ID('sys.databases');
						INSERT INTO #DatabaseDefaults
						  SELECT 'delayed_durability', 0, 143, 210, 'Delayed Durability Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'delayed_durability' AND object_id = OBJECT_ID('sys.databases');
						INSERT INTO #DatabaseDefaults
						  SELECT 'is_memory_optimized_elevate_to_snapshot_on', 0, 144, 210, 'Memory Optimized Enabled', 'http://BrentOzar.com/go/dbdefaults', NULL
						  FROM sys.all_columns 
						  WHERE name = 'is_memory_optimized_elevate_to_snapshot_on' AND object_id = OBJECT_ID('sys.databases');

						DECLARE DatabaseDefaultsLoop CURSOR FOR
						  SELECT name, DefaultValue, CheckID, Priority, Finding, URL, Details
						  FROM #DatabaseDefaults

						OPEN DatabaseDefaultsLoop
						FETCH NEXT FROM DatabaseDefaultsLoop into @CurrentName, @CurrentDefaultValue, @CurrentCheckID, @CurrentPriority, @CurrentFinding, @CurrentURL, @CurrentDetails
						WHILE @@FETCH_STATUS = 0
						BEGIN 

							/* Target Recovery Time (142) can be either 0 or 60 due to a number of bugs */
						    IF @CurrentCheckID = 142
								SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details)
								   SELECT ' + CAST(@CurrentCheckID AS NVARCHAR(200)) + ', d.[name], ' + CAST(@CurrentPriority AS NVARCHAR(200)) + ', ''Non-Default Database Config'', ''' + @CurrentFinding + ''',''' + @CurrentURL + ''',''' + COALESCE(@CurrentDetails, 'This database setting is not the default.') + '''
									FROM sys.databases d
									WHERE d.database_id > 4 AND (d.[' + @CurrentName + '] NOT IN (0, 60) OR d.[' + @CurrentName + '] IS NULL);';
							ELSE
								SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details)
								   SELECT ' + CAST(@CurrentCheckID AS NVARCHAR(200)) + ', d.[name], ' + CAST(@CurrentPriority AS NVARCHAR(200)) + ', ''Non-Default Database Config'', ''' + @CurrentFinding + ''',''' + @CurrentURL + ''',''' + COALESCE(@CurrentDetails, 'This database setting is not the default.') + '''
									FROM sys.databases d
									WHERE d.database_id > 4 AND (d.[' + @CurrentName + '] <> ' + @CurrentDefaultValue + ' OR d.[' + @CurrentName + '] IS NULL);';
						    EXEC (@StringToExecute);

						FETCH NEXT FROM DatabaseDefaultsLoop into @CurrentName, @CurrentDefaultValue, @CurrentCheckID, @CurrentPriority, @CurrentFinding, @CurrentURL, @CurrentDetails 
						END

						CLOSE DatabaseDefaultsLoop
						DEALLOCATE DatabaseDefaultsLoop;
							

/*This checks to see if Agent is Offline*/
IF @ProductVersionMajor >= 10 AND @ProductVersionMinor >= 50 
			   AND NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 167 )
					BEGIN
					IF EXISTS ( SELECT  1
											FROM    sys.all_objects
											WHERE   name = 'dm_server_services' )
									BEGIN
						  INSERT    INTO [#BlitzResults]
									( [CheckID] ,
									  [Priority] ,
									  [FindingsGroup] ,
									  [Finding] ,
									  [URL] ,
									  [Details] )

							SELECT
							167 AS [CheckID] ,
							250 AS [Priority] ,
							'Server Info' AS [FindingsGroup] ,
							'Agent is Currently Offline' AS [Finding] ,
							'' AS [URL] ,
							( 'Oops! It looks like the ' + [servicename] + ' service is ' + [status_desc] + '. The startup type is ' + [startup_type_desc] + '.'
							   ) AS [Details]
						  FROM
							[sys].[dm_server_services]
						  WHERE [status_desc] <> 'Running'
						  AND [servicename] LIKE 'SQL Server Agent%'
						  AND CAST(SERVERPROPERTY('Edition') AS VARCHAR(1000)) NOT LIKE '%xpress%'

					END; 
				END;

/*This checks to see if the Full Text thingy is offline*/
IF @ProductVersionMajor >= 10 AND @ProductVersionMinor >= 50 
			   AND NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 168 )
					BEGIN
					IF EXISTS ( SELECT  1
											FROM    sys.all_objects
											WHERE   name = 'dm_server_services' )
					BEGIN
						  INSERT    INTO [#BlitzResults]
									( [CheckID] ,
									  [Priority] ,
									  [FindingsGroup] ,
									  [Finding] ,
									  [URL] ,
									  [Details] )

							SELECT
							168 AS [CheckID] ,
							250 AS [Priority] ,
							'Server Info' AS [FindingsGroup] ,
							'Full-text Filter Daemon Launcher is Currently Offline' AS [Finding] ,
							'' AS [URL] ,
							( 'Oops! It looks like the ' + [servicename] + ' service is ' + [status_desc] + '. The startup type is ' + [startup_type_desc] + '.'
							   ) AS [Details]
						  FROM
							[sys].[dm_server_services]
						  WHERE [status_desc] <> 'Running'
						  AND [servicename] LIKE 'SQL Full-text Filter Daemon Launcher%'

					END;
					END; 

/*This checks which service account SQL Server is running as.*/
IF @ProductVersionMajor >= 10 AND @ProductVersionMinor >= 50 
			   AND NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 169 )

					BEGIN
					IF EXISTS ( SELECT  1
											FROM    sys.all_objects
											WHERE   name = 'dm_server_services' )
					BEGIN
						  INSERT    INTO [#BlitzResults]
									( [CheckID] ,
									  [Priority] ,
									  [FindingsGroup] ,
									  [Finding] ,
									  [URL] ,
									  [Details] )

							SELECT
							169 AS [CheckID] ,
							250 AS [Priority] ,
							'Informational' AS [FindingsGroup] ,
							'SQL Server is running under an NT Service account' AS [Finding] ,
							'http://BrentOzar.com/go/setup' AS [URL] ,
							( 'I''m running as ' + [service_account] + '. I wish I had an Active Directory service account instead.'
							   ) AS [Details]
						  FROM
							[sys].[dm_server_services]
						  WHERE [service_account] LIKE 'NT Service%'
						  AND [servicename] LIKE 'SQL Server%'
						  AND [servicename] NOT LIKE 'SQL Server Agent%'

					END;
					END;

/*This checks which service account SQL Agent is running as.*/
IF @ProductVersionMajor >= 10 AND @ProductVersionMinor >= 50 
			   AND NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 170 )

					BEGIN
					IF EXISTS ( SELECT  1
											FROM    sys.all_objects
											WHERE   name = 'dm_server_services' )
					BEGIN
						  INSERT    INTO [#BlitzResults]
									( [CheckID] ,
									  [Priority] ,
									  [FindingsGroup] ,
									  [Finding] ,
									  [URL] ,
									  [Details] )

							SELECT
							170 AS [CheckID] ,
							250 AS [Priority] ,
							'Informational' AS [FindingsGroup] ,
							'SQL Server Agent is running under an NT Service account' AS [Finding] ,
							'http://BrentOzar.com/go/setup' AS [URL] ,
							( 'I''m running as ' + [service_account] + '. I wish I had an Active Directory service account instead.'
							   ) AS [Details]
						  FROM
							[sys].[dm_server_services]
						  WHERE [service_account] LIKE 'NT Service%'
						  AND [servicename] LIKE 'SQL Server Agent%'

					END; 
					END;

/*This counts memory dumps and gives min and max date of in view*/
IF @ProductVersionMajor >= 10 AND @ProductVersionMinor >= 50 
			   AND NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 171 )
					BEGIN
					IF EXISTS ( SELECT  1
											FROM    sys.all_objects
											WHERE   name = 'dm_server_memory_dumps' )
					BEGIN
						IF 5 <= (SELECT COUNT(*) FROM [sys].[dm_server_memory_dumps] WHERE [creation_time] >= DATEADD(year, -1, GETDATE()))
						  INSERT    INTO [#BlitzResults]
									( [CheckID] ,
									  [Priority] ,
									  [FindingsGroup] ,
									  [Finding] ,
									  [URL] ,
									  [Details] )

							SELECT
							171 AS [CheckID] ,
							20 AS [Priority] ,
							'Reliability' AS [FindingsGroup] ,
							'Memory Dumps Have Occurred' AS [Finding] ,
							'http://BrentOzar.com/go/dump' AS [URL] ,
							( 'That ain''t good. I''ve had ' + 
								CAST(COUNT(*) AS VARCHAR(100)) + ' memory dumps between ' + 
								CAST(CAST(MIN([creation_time]) AS DATETIME) AS VARCHAR(100)) +
								' and ' +
								CAST(CAST(MAX([creation_time]) AS DATETIME) AS VARCHAR(100)) +
								'!'
							   ) AS [Details]
						  FROM
							[sys].[dm_server_memory_dumps]
						  WHERE [creation_time] >= DATEADD(year, -1, GETDATE());

					END; 
					END;

/*Checks to see if you're on Developer or Evaluation*/
					IF	NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 173 )
					BEGIN
						  INSERT    INTO [#BlitzResults]
									( [CheckID] ,
									  [Priority] ,
									  [FindingsGroup] ,
									  [Finding] ,
									  [URL] ,
									  [Details] )

							SELECT
							173 AS [CheckID] ,
							200 AS [Priority] ,
							'Licensing' AS [FindingsGroup] ,
							'Non-Production License' AS [Finding] ,
							'http://BrentOzar.com/go/licensing' AS [URL] ,
							( 'We''re not the licensing police, but if this is supposed to be a production server, and you''re running ' + 
							CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) +
							' the good folks at Microsoft might get upset with you. Better start counting those cores.'
							   ) AS [Details]
							WHERE CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) LIKE '%Developer%'
							OR CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) LIKE '%Evaluation%'

					END

/*Checks to see if Buffer Pool Extensions are in use*/
			IF @ProductVersionMajor >= 12  
			   AND NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 174 )
					BEGIN
						  INSERT    INTO [#BlitzResults]
									( [CheckID] ,
									  [Priority] ,
									  [FindingsGroup] ,
									  [Finding] ,
									  [URL] ,
									  [Details] )

							SELECT
							174 AS [CheckID] ,
							200 AS [Priority] ,
							'Performance' AS [FindingsGroup] ,
							'Buffer Pool Extensions Enabled' AS [Finding] ,
							'http://BrentOzar.com/go/bpe' AS [URL] ,
							( 'You have Buffer Pool Extensions enabled, and one lives here: ' + 
								[path] +
								'. It''s currently ' +
								CASE WHEN [current_size_in_kb] / 1024. / 1024. > 0
																	 THEN CAST([current_size_in_kb] / 1024. / 1024. AS VARCHAR(100))
																		  + ' GB'
																	 ELSE CAST([current_size_in_kb] / 1024. AS VARCHAR(100))
																		  + ' MB'
								END +
								'. Did you know that BPEs only provide single threaded access 8 bytes at a time?'	
							   ) AS [Details]
							 FROM sys.dm_os_buffer_pool_extension_configuration
							 WHERE [state_description] <> 'BUFFER POOL EXTENSION DISABLED'

					END

/*Check for too many tempdb files*/
			IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 175 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
										SELECT DISTINCT
										175 AS CheckID ,
										'TempDB' AS DatabaseName ,
										170 AS Priority ,
										'File Configuration' AS FindingsGroup ,
										'TempDB Has >16 Data Files' AS Finding ,
										'http://BrentOzar.com/go/tempdb' AS URL ,
										'Woah, Nelly! TempDB has ' + CAST(COUNT_BIG(*) AS VARCHAR) + '. Did you forget to terminate a loop somewhere?' AS Details
								  FROM sys.[master_files] AS [mf] 
								  WHERE [mf].[database_id] = 2 AND [mf].[type] = 0
								  HAVING COUNT_BIG(*) > 16; 
					END	

			IF NOT EXISTS ( SELECT  1
											FROM    #SkipChecks
											WHERE   DatabaseName IS NULL AND CheckID = 176 )
			IF EXISTS ( SELECT  1
														FROM    sys.all_objects
														WHERE   name = 'dm_xe_sessions' )
								BEGIN
								BEGIN
									INSERT  INTO #BlitzResults
											( CheckID ,
											  DatabaseName ,
											  Priority ,
											  FindingsGroup ,
											  Finding ,
											  URL ,
											  Details
											)
													SELECT DISTINCT
													176 AS CheckID ,
													'' AS DatabaseName ,
													200 AS Priority ,
													'Monitoring' AS FindingsGroup ,
													'Extended Events Hyperextension' AS Finding ,
													'http://BrentOzar.com/go/xe' AS URL ,
													'Hey big spender, you have ' + CAST(COUNT_BIG(*) AS VARCHAR) + ' Extended Events sessions running. You sure you meant to do that?' AS Details
											    FROM sys.dm_xe_sessions
												WHERE [name] NOT IN
												('system_health', 'sp_server_diagnostics session', 'hkenginexesession', 'telemetry_xevents')
												AND name NOT LIKE '%$A%'
											  HAVING COUNT_BIG(*) >= 2; 
								END	
								END
			
			/*Harmful startup parameter*/
			IF NOT EXISTS ( SELECT  1
											FROM    #SkipChecks
											WHERE   DatabaseName IS NULL AND CheckID = 177 )
								BEGIN
								IF EXISTS ( SELECT  1
														FROM    sys.all_objects
														WHERE   name = 'dm_server_registry' )
			
								BEGIN
									INSERT  INTO #BlitzResults
											( CheckID ,
											  DatabaseName ,
											  Priority ,
											  FindingsGroup ,
											  Finding ,
											  URL ,
											  Details
											)
													SELECT DISTINCT
													177 AS CheckID ,
													'' AS DatabaseName ,
													5 AS Priority ,
													'Monitoring' AS FindingsGroup ,
													'Disabled Internal Monitoring Features' AS Finding ,
													'https://msdn.microsoft.com/en-us/library/ms190737.aspx' AS URL ,
													'You have -x as a startup parameter. You should head to the URL and read more about what it does to your system.' AS Details
													FROM
													[sys].[dm_server_registry] AS [dsr]
													WHERE
													[dsr].[registry_key] LIKE N'%MSSQLServer\Parameters'
													AND [dsr].[value_data] = '-x';; 
								END		
								END
			
			
			/* Reliability - Dangerous Third Party Modules - 179 */
			IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 179 )
					BEGIN
						  INSERT    INTO [#BlitzResults]
									( [CheckID] ,
									  [Priority] ,
									  [FindingsGroup] ,
									  [Finding] ,
									  [URL] ,
									  [Details] )

							SELECT
							179 AS [CheckID] ,
							5 AS [Priority] ,
							'Reliability' AS [FindingsGroup] ,
							'Dangerous Third Party Modules' AS [Finding] ,
							'https://support.microsoft.com/en-us/kb/2033238' AS [URL] ,
							( COALESCE(company, '') + ' - ' + COALESCE(description, '') + ' - ' + COALESCE(name, '') + ' - suspected dangerous third party module is installed.') AS [Details]
							FROM sys.dm_os_loaded_modules 
							WHERE UPPER(name) LIKE UPPER('%\ENTAPI.DLL') /* McAfee VirusScan Enterprise */
							OR UPPER(name) LIKE UPPER('%\HIPI.DLL') OR UPPER(name) LIKE UPPER('%\HcSQL.dll') OR UPPER(name) LIKE UPPER('%\HcApi.dll') OR UPPER(name) LIKE UPPER('%\HcThe.dll') /* McAfee Host Intrusion */
							OR UPPER(name) LIKE UPPER('%\SOPHOS_DETOURED.DLL') OR UPPER(name) LIKE UPPER('%\SOPHOS_DETOURED_x64.DLL') OR UPPER(name) LIKE UPPER('%\SWI_IFSLSP_64.dll') /* Sophos AV */
							OR UPPER(name) LIKE UPPER('%\PIOLEDB.DLL') OR UPPER(name) LIKE UPPER('%\PISDK.DLL') /* OSISoft PI data access */

					END

			/*Find shrink database tasks*/

			IF NOT EXISTS ( SELECT  1
											FROM    #SkipChecks
											WHERE   DatabaseName IS NULL AND CheckID = 180 )
							AND CONVERT(VARCHAR(128), SERVERPROPERTY ('productversion')) LIKE '1%' /* Only run on 2008+ */
					BEGIN
						;
						WITH XMLNAMESPACES ('www.microsoft.com/SqlServer/Dts' AS [dts])
						,[maintenance_plan_steps] AS (
							SELECT [name]
								, CAST(CAST([packagedata] AS VARBINARY(MAX)) AS XML) AS [maintenance_plan_xml]
							FROM [msdb].[dbo].[sysssispackages]
							WHERE [packagetype] = 6
						   )
							INSERT    INTO [#BlitzResults]
									( [CheckID] ,
										[Priority] ,
										[FindingsGroup] ,
										[Finding] ,
										[URL] ,
										[Details] )									  
						SELECT
						180 AS [CheckID] ,
						100 AS [Priority] ,
						'Performance' AS [FindingsGroup] ,
						'Shrink Database Step In Maintenance Plan' AS [Finding] ,
						'http://BrentOzar.com/go/autoshrink' AS [URL] ,									  
						'The maintenance plan ' + [mps].[name] + ' has a step to shrink databases in it. Shrinking databases is as outdated as maintenance plans.' AS [Details] 
						FROM [maintenance_plan_steps] [mps]
							CROSS APPLY [maintenance_plan_xml].[nodes]('//dts:Executables/dts:Executable') [t]([c])
						WHERE [c].[value]('(@dts:ObjectName)', 'VARCHAR(128)') = 'Shrink Database Task'

						END


		/*Find repetitive maintenance tasks*/
		IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 181 )
						AND CONVERT(VARCHAR(128), SERVERPROPERTY ('productversion')) LIKE '1%' /* Only run on 2008+ */
				BEGIN
						;
						WITH XMLNAMESPACES ('www.microsoft.com/SqlServer/Dts' AS [dts])
						,[maintenance_plan_steps] AS (
							SELECT [name]
								, CAST(CAST([packagedata] AS VARBINARY(MAX)) AS XML) AS [maintenance_plan_xml]
							FROM [msdb].[dbo].[sysssispackages]
							WHERE [packagetype] = 6
							), [maintenance_plan_table] AS (
						SELECT [mps].[name]
							,[c].[value]('(@dts:ObjectName)', 'NVARCHAR(128)') AS [step_name]
						FROM [maintenance_plan_steps] [mps]
							CROSS APPLY [maintenance_plan_xml].[nodes]('//dts:Executables/dts:Executable') [t]([c])
						), [mp_steps_pretty] AS (SELECT DISTINCT [m1].[name] ,
								STUFF((SELECT N', ' + [m2].[step_name]  FROM [maintenance_plan_table] AS [m2] WHERE [m1].[name] = [m2].[name] 
								FOR XML PATH(N'')), 1, 2, N'') AS [maintenance_plan_steps]
						FROM [maintenance_plan_table] AS [m1])
						
							INSERT    INTO [#BlitzResults]
									( [CheckID] ,
										[Priority] ,
										[FindingsGroup] ,
										[Finding] ,
										[URL] ,
										[Details] )						
						
						SELECT
						181 AS [CheckID] ,
						100 AS [Priority] ,
						'Performance' AS [FindingsGroup] ,
						'Repetitive Steps In Maintenance Plans' AS [Finding] ,
						'https://ola.hallengren.com/' AS [URL] , 
						'The maintenance plan ' + [m].[name] + ' is doing repetitive work on indexes and statistics. Perhaps it''s time to try something more modern?' AS [Details]
						FROM [mp_steps_pretty] m
						WHERE m.[maintenance_plan_steps] LIKE '%Rebuild%Reorganize%'
						OR m.[maintenance_plan_steps] LIKE '%Rebuild%Update%'

						END
			

			/* Reliability - No Failover Cluster Nodes Available - 184 */
			IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 184 )
				AND CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)) NOT LIKE '10%'
				AND CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)) NOT LIKE '9%'
					BEGIN
		                        SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
			                        							SELECT TOP 1
							  184 AS CheckID ,
							  20 AS Priority ,
							  ''Reliability'' AS FindingsGroup ,
							  ''No Failover Cluster Nodes Available'' AS Finding ,
							  ''http://BrentOzar.com/go/node'' AS URL ,
							  ''There are no failover cluster nodes available if the active node fails'' AS Details
							FROM (
							  SELECT SUM(CASE WHEN [status] = 0 AND [is_current_owner] = 0 THEN 1 ELSE 0 END) AS [available_nodes]
							  FROM sys.dm_os_cluster_nodes
							) a
							WHERE [available_nodes] < 1';
		                        EXECUTE(@StringToExecute);
					END

		/* Reliability - TempDB File Error */
		IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 191 )
			AND (SELECT COUNT(*) FROM sys.master_files WHERE database_id = 2) <> (SELECT COUNT(*) FROM tempdb.sys.database_files)
				BEGIN
					INSERT    INTO [#BlitzResults]
							( [CheckID] ,
								[Priority] ,
								[FindingsGroup] ,
								[Finding] ,
								[URL] ,
								[Details] )						
						
						SELECT
						191 AS [CheckID] ,
						50 AS [Priority] ,
						'Reliability' AS [FindingsGroup] ,
						'TempDB File Error' AS [Finding] ,
						'http://BrentOzar.com/go/tempdboops' AS [URL] , 
						'Mismatch between the number of TempDB files in sys.master_files versus tempdb.sys.database_files' AS [Details]
				END


				IF @CheckUserDatabaseObjects = 1
					BEGIN

                        /*
                        But what if you need to run a query in every individual database?
				        Check out CheckID 99 below. Yes, it uses sp_MSforeachdb, and no,
				        we're not happy about that. sp_MSforeachdb is known to have a lot
				        of issues, like skipping databases sometimes. However, this is the
				        only built-in option that we have. If you're writing your own code
				        for database maintenance, consider Aaron Bertrand's alternative:
				        http://www.mssqltips.com/sqlservertip/2201/making-a-more-reliable-and-flexible-spmsforeachdb/
				        We don't include that as part of sp_Blitz, of course, because
				        copying and distributing copyrighted code from others without their
				        written permission isn't a good idea.
				        */
				        IF NOT EXISTS ( SELECT  1
								        FROM    #SkipChecks
								        WHERE   DatabaseName IS NULL AND CheckID = 99 )
					        BEGIN
						        EXEC dbo.sp_MSforeachdb 'USE [?];  IF EXISTS (SELECT * FROM  sys.tables WITH (NOLOCK) WHERE name = ''sysmergepublications'' ) IF EXISTS ( SELECT * FROM sysmergepublications WITH (NOLOCK) WHERE retention = 0)   INSERT INTO #BlitzResults (CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details) SELECT DISTINCT 99, DB_NAME(), 110, ''Performance'', ''Infinite merge replication metadata retention period'', ''http://BrentOzar.com/go/merge'', (''The ['' + DB_NAME() + ''] database has merge replication metadata retention period set to infinite - this can be the case of significant performance issues.'')';
					        END
				        /*
				        Note that by using sp_MSforeachdb, we're running the query in all
				        databases. We're not checking #SkipChecks here for each database to
				        see if we should run the check in this database. That means we may
				        still run a skipped check if it involves sp_MSforeachdb. We just
				        don't output those results in the last step.
                        */


						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 163 )
                            AND EXISTS(SELECT * FROM sys.all_objects WHERE name = 'database_query_store_options')
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?];
			                            INSERT INTO #BlitzResults
			                            (CheckID,
			                            DatabaseName,
			                            Priority,
			                            FindingsGroup,
			                            Finding,
			                            URL,
			                            Details)
		                              SELECT TOP 1 163,
		                              ''?'',
		                              10,
		                              ''Performance'',
		                              ''Query Store Disabled'',
		                              ''http://BrentOzar.com/go/querystore'',
		                              (''The new SQL Server 2016 Query Store feature has not been enabled on this database.'')
		                              FROM [?].sys.database_query_store_options WHERE desired_state = 0 AND ''?'' NOT IN (''master'', ''model'', ''msdb'', ''tempdb'', ''DWConfiguration'', ''DWDiagnostics'', ''DWQueue'', ''ReportServer'', ''ReportServerTempDB'')';
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 182 )
                            AND EXISTS(SELECT * FROM sys.all_objects WHERE name = 'database_query_store_options')
							AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) NOT LIKE '%Enterprise%'
							AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) NOT LIKE '%Developer%'
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?];
			                            INSERT INTO #BlitzResults
			                            (CheckID,
			                            DatabaseName,
			                            Priority,
			                            FindingsGroup,
			                            Finding,
			                            URL,
			                            Details)
		                              SELECT TOP 1 182,
		                              ''?'',
		                              20,
		                              ''Reliability'',
		                              ''Query Store Cleanup Disabled'',
		                              ''http://BrentOzar.com/go/cleanup'',
		                              (''SQL 2016 RTM has a bug involving dumps that happen every time Query Store cleanup jobs run.'')
		                              FROM [?].sys.database_query_store_options WHERE desired_state <> 0 AND ''?'' NOT IN (''master'', ''model'', ''msdb'', ''tempdb'', ''DWConfiguration'', ''DWDiagnostics'', ''DWQueue'', ''ReportServer'', ''ReportServerTempDB'')';
							END


				        IF NOT EXISTS ( SELECT  1
								        FROM    #SkipChecks
								        WHERE   DatabaseName IS NULL AND CheckID = 41 )
					        BEGIN
						        EXEC dbo.sp_MSforeachdb 'use [?];
		                              INSERT INTO #BlitzResults
		                              (CheckID,
		                              DatabaseName,
		                              Priority,
		                              FindingsGroup,
		                              Finding,
		                              URL,
		                              Details)
		                              SELECT 41,
		                              ''?'',
		                              170,
		                              ''File Configuration'',
		                              ''Multiple Log Files on One Drive'',
		                              ''http://BrentOzar.com/go/manylogs'',
		                              (''The ['' + DB_NAME() + ''] database has multiple log files on the '' + LEFT(physical_name, 1) + '' drive. This is not a performance booster because log file access is sequential, not parallel.'')
		                              FROM [?].sys.database_files WHERE type_desc = ''LOG''
			                            AND ''?'' <> ''[tempdb]''
		                              GROUP BY LEFT(physical_name, 1)
		                              HAVING COUNT(*) > 1';
					        END

				        IF NOT EXISTS ( SELECT  1
								        FROM    #SkipChecks
								        WHERE   DatabaseName IS NULL AND CheckID = 42 )
					        BEGIN
						        EXEC dbo.sp_MSforeachdb 'use [?];
			                            INSERT INTO #BlitzResults
			                            (CheckID,
			                            DatabaseName,
			                            Priority,
			                            FindingsGroup,
			                            Finding,
			                            URL,
			                            Details)
			                            SELECT DISTINCT 42,
			                            ''?'',
			                            170,
			                            ''File Configuration'',
			                            ''Uneven File Growth Settings in One Filegroup'',
			                            ''http://BrentOzar.com/go/grow'',
			                            (''The ['' + DB_NAME() + ''] database has multiple data files in one filegroup, but they are not all set up to grow in identical amounts.  This can lead to uneven file activity inside the filegroup.'')
			                            FROM [?].sys.database_files
			                            WHERE type_desc = ''ROWS''
			                            GROUP BY data_space_id
			                            HAVING COUNT(DISTINCT growth) > 1 OR COUNT(DISTINCT is_percent_growth) > 1';
					        END


				            IF NOT EXISTS ( SELECT  1
								            FROM    #SkipChecks
								            WHERE   DatabaseName IS NULL AND CheckID = 82 )
					            BEGIN
						            EXEC sp_MSforeachdb 'use [?];
		                                INSERT INTO #BlitzResults
		                                (CheckID,
		                                DatabaseName,
		                                Priority,
		                                FindingsGroup,
		                                Finding,
		                                URL, Details)
		                                SELECT  DISTINCT 82 AS CheckID,
		                                ''?'' as DatabaseName,
		                                170 AS Priority,
		                                ''File Configuration'' AS FindingsGroup,
		                                ''File growth set to percent'',
		                                ''http://brentozar.com/go/percentgrowth'' AS URL,
		                                ''The ['' + DB_NAME() + ''] database file '' + f.physical_name + '' has grown to '' + CAST((f.size * 8 / 1000000) AS NVARCHAR(10)) + '' GB, and is using percent filegrowth settings. This can lead to slow performance during growths if Instant File Initialization is not enabled.''
		                                FROM    [?].sys.database_files f
		                                WHERE   is_percent_growth = 1 and size > 128000 ';
					            END



                            /* addition by Henrik Staun Poulsen, Stovi Software */
				            IF NOT EXISTS ( SELECT  1
								            FROM    #SkipChecks
								            WHERE   DatabaseName IS NULL AND CheckID = 158 )
					            BEGIN
						            EXEC sp_MSforeachdb 'use [?];
		                                INSERT INTO #BlitzResults
		                                (CheckID,
		                                DatabaseName,
		                                Priority,
		                                FindingsGroup,
		                                Finding,
		                                URL, Details)
		                                SELECT  DISTINCT 158 AS CheckID,
		                                ''?'' as DatabaseName,
		                                170 AS Priority,
		                                ''File Configuration'' AS FindingsGroup,
		                                ''File growth set to 1MB'',
		                                ''http://brentozar.com/go/percentgrowth'' AS URL,
		                                ''The ['' + DB_NAME() + ''] database file '' + f.physical_name + '' is using 1MB filegrowth settings, but it has grown to '' + CAST((f.size * 8 / 1000000) AS NVARCHAR(10)) + '' GB. Time to up the growth amount.''
		                                FROM    [?].sys.database_files f
                                        WHERE is_percent_growth = 0 and growth=128 and size > 128000 ';
					            END



				        IF NOT EXISTS ( SELECT  1
								        FROM    #SkipChecks
								        WHERE   DatabaseName IS NULL AND CheckID = 33 )
					        BEGIN
						        IF @@VERSION NOT LIKE '%Microsoft SQL Server 2000%'
							        AND @@VERSION NOT LIKE '%Microsoft SQL Server 2005%'
							        BEGIN
								        EXEC dbo.sp_MSforeachdb 'USE [?]; INSERT INTO #BlitzResults
					                                (CheckID,
					                                DatabaseName,
					                                Priority,
					                                FindingsGroup,
					                                Finding,
					                                URL,
					                                Details)
		                                  SELECT DISTINCT 33,
		                                  db_name(),
		                                  200,
		                                  ''Licensing'',
		                                  ''Enterprise Edition Features In Use'',
		                                  ''http://BrentOzar.com/go/ee'',
		                                  (''The ['' + DB_NAME() + ''] database is using '' + feature_name + ''.  If this database is restored onto a Standard Edition server, the restore will fail.'')
		                                  FROM [?].sys.dm_db_persisted_sku_features';
							        END;
					        END


				        IF NOT EXISTS ( SELECT  1
								        FROM    #SkipChecks
								        WHERE   DatabaseName IS NULL AND CheckID = 19 )
					        BEGIN
						        /* Method 1: Check sys.databases parameters */
						        INSERT  INTO #BlitzResults
								        ( CheckID ,
								          DatabaseName ,
								          Priority ,
								          FindingsGroup ,
								          Finding ,
								          URL ,
								          Details
								        )

								        SELECT  19 AS CheckID ,
										        [name] AS DatabaseName ,
										        200 AS Priority ,
										        'Informational' AS FindingsGroup ,
										        'Replication In Use' AS Finding ,
										        'http://BrentOzar.com/go/repl' AS URL ,
										        ( 'Database [' + [name]
										          + '] is a replication publisher, subscriber, or distributor.' ) AS Details
								        FROM    sys.databases
								        WHERE   name NOT IN ( SELECT DISTINCT
																        DatabaseName
													          FROM      #SkipChecks 
													          WHERE CheckID IS NULL)
										        AND is_published = 1
										        OR is_subscribed = 1
										        OR is_merge_published = 1
										        OR is_distributor = 1;

						        /* Method B: check subscribers for MSreplication_objects tables */
						        EXEC dbo.sp_MSforeachdb 'USE [?]; INSERT INTO #BlitzResults
										        (CheckID,
										        DatabaseName,
										        Priority,
										        FindingsGroup,
										        Finding,
										        URL,
										        Details)
							          SELECT DISTINCT 19,
							          db_name(),
							          200,
							          ''Informational'',
							          ''Replication In Use'',
							          ''http://BrentOzar.com/go/repl'',
							          (''['' + DB_NAME() + ''] has MSreplication_objects tables in it, indicating it is a replication subscriber.'')
							          FROM [?].sys.tables
							          WHERE name = ''dbo.MSreplication_objects'' AND ''?'' <> ''master''';

					        END



						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 32 )
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?];
			INSERT INTO #BlitzResults
			(CheckID,
			DatabaseName,
			Priority,
			FindingsGroup,
			Finding,
			URL,
			Details)
			SELECT 32,
			''?'',
			150,
			''Performance'',
			''Triggers on Tables'',
			''http://BrentOzar.com/go/trig'',
			(''The ['' + DB_NAME() + ''] database has '' + CAST(SUM(1) AS NVARCHAR(50)) + '' triggers.'')
			FROM [?].sys.triggers t INNER JOIN [?].sys.objects o ON t.parent_id = o.object_id
			INNER JOIN [?].sys.schemas s ON o.schema_id = s.schema_id WHERE t.is_ms_shipped = 0 AND DB_NAME() != ''ReportServer''
			HAVING SUM(1) > 0';
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 38 )
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?];
			INSERT INTO #BlitzResults
			(CheckID,
			DatabaseName,
			Priority,
			FindingsGroup,
			Finding,
			URL,
			Details)
		  SELECT DISTINCT 38,
		  ''?'',
		  110,
		  ''Performance'',
		  ''Active Tables Without Clustered Indexes'',
		  ''http://BrentOzar.com/go/heaps'',
		  (''The ['' + DB_NAME() + ''] database has heaps - tables without a clustered index - that are being actively queried.'')
		  FROM [?].sys.indexes i INNER JOIN [?].sys.objects o ON i.object_id = o.object_id
		  INNER JOIN [?].sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
		  INNER JOIN sys.databases sd ON sd.name = ''?''
		  LEFT OUTER JOIN [?].sys.dm_db_index_usage_stats ius ON i.object_id = ius.object_id AND i.index_id = ius.index_id AND ius.database_id = sd.database_id
		  WHERE i.type_desc = ''HEAP'' AND COALESCE(ius.user_seeks, ius.user_scans, ius.user_lookups, ius.user_updates) IS NOT NULL
		  AND sd.name <> ''tempdb'' AND sd.name <> ''DWDiagnostics'' AND o.is_ms_shipped = 0 AND o.type <> ''S''';
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 164 )
                            AND EXISTS(SELECT * FROM sys.all_objects WHERE name = 'fn_validate_plan_guide')
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?];
			INSERT INTO #BlitzResults
			(CheckID,
			DatabaseName,
			Priority,
			FindingsGroup,
			Finding,
			URL,
			Details)
		  SELECT DISTINCT 164,
		  ''?'',
		  20,
		  ''Reliability'',
		  ''Plan Guides Failing'',
		  ''http://BrentOzar.com/go/misguided'',
		  (''The ['' + DB_NAME() + ''] database has plan guides that are no longer valid, so the queries involved may be failing silently.'')
		  FROM [?].sys.plan_guides g CROSS APPLY fn_validate_plan_guide(g.plan_guide_id)';
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 39 )
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?];
			INSERT INTO #BlitzResults
			(CheckID,
			DatabaseName,
			Priority,
			FindingsGroup,
			Finding,
			URL,
			Details)
		  SELECT DISTINCT 39,
		  ''?'',
		  150,
		  ''Performance'',
		  ''Inactive Tables Without Clustered Indexes'',
		  ''http://BrentOzar.com/go/heaps'',
		  (''The ['' + DB_NAME() + ''] database has heaps - tables without a clustered index - that have not been queried since the last restart.  These may be backup tables carelessly left behind.'')
		  FROM [?].sys.indexes i INNER JOIN [?].sys.objects o ON i.object_id = o.object_id
		  INNER JOIN [?].sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
		  INNER JOIN sys.databases sd ON sd.name = ''?''
		  LEFT OUTER JOIN [?].sys.dm_db_index_usage_stats ius ON i.object_id = ius.object_id AND i.index_id = ius.index_id AND ius.database_id = sd.database_id
		  WHERE i.type_desc = ''HEAP'' AND COALESCE(ius.user_seeks, ius.user_scans, ius.user_lookups, ius.user_updates) IS NULL
		  AND sd.name <> ''tempdb'' AND sd.name <> ''DWDiagnostics'' AND o.is_ms_shipped = 0 AND o.type <> ''S''';
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 46 )
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?];
		  INSERT INTO #BlitzResults
				(CheckID,
				DatabaseName,
				Priority,
				FindingsGroup,
				Finding,
				URL,
				Details)
		  SELECT 46,
		  ''?'',
		  150,
		  ''Performance'',
		  ''Leftover Fake Indexes From Wizards'',
		  ''http://BrentOzar.com/go/hypo'',
		  (''The index ['' + DB_NAME() + ''].['' + s.name + ''].['' + o.name + ''].['' + i.name + ''] is a leftover hypothetical index from the Index Tuning Wizard or Database Tuning Advisor.  This index is not actually helping performance and should be removed.'')
		  from [?].sys.indexes i INNER JOIN [?].sys.objects o ON i.object_id = o.object_id INNER JOIN [?].sys.schemas s ON o.schema_id = s.schema_id
		  WHERE i.is_hypothetical = 1';
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 47 )
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?];
		  INSERT INTO #BlitzResults
				(CheckID,
				DatabaseName,
				Priority,
				FindingsGroup,
				Finding,
				URL,
				Details)
		  SELECT 47,
		  ''?'',
		  100,
		  ''Performance'',
		  ''Indexes Disabled'',
		  ''http://BrentOzar.com/go/ixoff'',
		  (''The index ['' + DB_NAME() + ''].['' + s.name + ''].['' + o.name + ''].['' + i.name + ''] is disabled.  This index is not actually helping performance and should either be enabled or removed.'')
		  from [?].sys.indexes i INNER JOIN [?].sys.objects o ON i.object_id = o.object_id INNER JOIN [?].sys.schemas s ON o.schema_id = s.schema_id
		  WHERE i.is_disabled = 1';
							END


						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 48 )
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?];
		  INSERT INTO #BlitzResults
				(CheckID,
				DatabaseName,
				Priority,
				FindingsGroup,
				Finding,
				URL,
				Details)
		  SELECT DISTINCT 48,
		  ''?'',
		  150,
		  ''Performance'',
		  ''Foreign Keys Not Trusted'',
		  ''http://BrentOzar.com/go/trust'',
		  (''The ['' + DB_NAME() + ''] database has foreign keys that were probably disabled, data was changed, and then the key was enabled again.  Simply enabling the key is not enough for the optimizer to use this key - we have to alter the table using the WITH CHECK CHECK CONSTRAINT parameter.'')
		  from [?].sys.foreign_keys i INNER JOIN [?].sys.objects o ON i.parent_object_id = o.object_id INNER JOIN [?].sys.schemas s ON o.schema_id = s.schema_id
		  WHERE i.is_not_trusted = 1 AND i.is_not_for_replication = 0 AND i.is_disabled = 0 AND ''?'' NOT IN (''master'', ''model'', ''msdb'', ''ReportServer'', ''ReportServerTempDB'')';
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 56 )
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?];
		  INSERT INTO #BlitzResults
				(CheckID,
				DatabaseName,
				Priority,
				FindingsGroup,
				Finding,
				URL,
				Details)
		  SELECT 56,
		  ''?'',
		  150,
		  ''Performance'',
		  ''Check Constraint Not Trusted'',
		  ''http://BrentOzar.com/go/trust'',
		  (''The check constraint ['' + DB_NAME() + ''].['' + s.name + ''].['' + o.name + ''].['' + i.name + ''] is not trusted - meaning, it was disabled, data was changed, and then the constraint was enabled again.  Simply enabling the constraint is not enough for the optimizer to use this constraint - we have to alter the table using the WITH CHECK CHECK CONSTRAINT parameter.'')
		  from [?].sys.check_constraints i INNER JOIN [?].sys.objects o ON i.parent_object_id = o.object_id
		  INNER JOIN [?].sys.schemas s ON o.schema_id = s.schema_id
		  WHERE i.is_not_trusted = 1 AND i.is_not_for_replication = 0 AND i.is_disabled = 0';
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 95 )
							BEGIN
								IF @@VERSION NOT LIKE '%Microsoft SQL Server 2000%'
									AND @@VERSION NOT LIKE '%Microsoft SQL Server 2005%'
									BEGIN
										EXEC dbo.sp_MSforeachdb 'USE [?];
			INSERT INTO #BlitzResults
				  (CheckID,
				  DatabaseName,
				  Priority,
				  FindingsGroup,
				  Finding,
				  URL,
				  Details)
			SELECT TOP 1 95 AS CheckID,
			''?'' as DatabaseName,
			110 AS Priority,
			''Performance'' AS FindingsGroup,
			''Plan Guides Enabled'' AS Finding,
			''http://BrentOzar.com/go/guides'' AS URL,
			(''Database ['' + DB_NAME() + ''] has query plan guides so a query will always get a specific execution plan. If you are having trouble getting query performance to improve, it might be due to a frozen plan. Review the DMV sys.plan_guides to learn more about the plan guides in place on this server.'') AS Details
			FROM [?].sys.plan_guides WHERE is_disabled = 0'
									END;
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 60 )
							BEGIN
								EXEC sp_MSforeachdb 'USE [?];
		  INSERT INTO #BlitzResults
				(CheckID,
				DatabaseName,
				Priority,
				FindingsGroup,
				Finding,
				URL,
				Details)
		  SELECT  DISTINCT 60 AS CheckID,
		  ''?'' as DatabaseName,
		  100 AS Priority,
		  ''Performance'' AS FindingsGroup,
		  ''Fill Factor Changed'',
		  ''http://brentozar.com/go/fillfactor'' AS URL,
		  ''The ['' + DB_NAME() + ''] database has objects with fill factor < 80%. This can cause memory and storage performance problems, but may also prevent page splits.''
		  FROM    [?].sys.indexes
		  WHERE   fill_factor <> 0 AND fill_factor < 80 AND is_disabled = 0 AND is_hypothetical = 0';
							END



						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 78 )
							BEGIN
                                EXECUTE master.sys.sp_MSforeachdb 'USE [?]; 
                                    INSERT INTO #Recompile 
                                    SELECT DBName = DB_Name(), SPName = SO.name, SM.is_recompiled, ISR.SPECIFIC_SCHEMA 
                                    FROM sys.sql_modules AS SM 
                                    LEFT OUTER JOIN master.sys.databases AS sDB ON SM.object_id = DB_id() 
                                    LEFT OUTER JOIN dbo.sysobjects AS SO ON SM.object_id = SO.id and type = ''P'' 
                                    LEFT OUTER JOIN INFORMATION_SCHEMA.ROUTINES AS ISR on ISR.Routine_Name = SO.name AND ISR.SPECIFIC_CATALOG = DB_Name()
                                    WHERE SM.is_recompiled=1 
                                    ' 
                                INSERT INTO #BlitzResults
													(Priority,
													FindingsGroup,
                                                    Finding,
                                                    DatabaseName,
                                                    URL,
                                                    Details,
                                                    CheckID)
                                SELECT [Priority] = '100', 
                                    FindingsGroup = 'Performance', 
                                    Finding = 'Stored Procedure WITH RECOMPILE',
                                    DatabaseName = DBName,
                                    URL = 'http://BrentOzar.com/go/recompile',
                                    Details = '[' + DBName + '].[' + SPSchema + '].[' + ProcName + '] has WITH RECOMPILE in the stored procedure code, which may cause increased CPU usage due to constant recompiles of the code.',
                                    CheckID = '78'
                                FROM #Recompile AS TR WHERE ProcName NOT LIKE 'sp_AskBrent%' AND ProcName NOT LIKE 'sp_Blitz%' 
                                DROP TABLE #Recompile;
                            END



						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 86 )
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?]; INSERT INTO #BlitzResults (CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details) SELECT DISTINCT 86, DB_NAME(), 230, ''Security'', ''Elevated Permissions on a Database'', ''http://BrentOzar.com/go/elevated'', (''In ['' + DB_NAME() + ''], user ['' + u.name + '']  has the role ['' + g.name + ''].  This user can perform tasks beyond just reading and writing data.'') FROM [?].dbo.sysmembers m inner join [?].dbo.sysusers u on m.memberuid = u.uid inner join sysusers g on m.groupuid = g.uid where u.name <> ''dbo'' and g.name in (''db_owner'' , ''db_accessadmin'' , ''db_securityadmin'' , ''db_ddladmin'')';
							END


							/*Check for non-aligned indexes in partioned databases*/

										IF NOT EXISTS ( SELECT  1
														FROM    #SkipChecks
														WHERE   DatabaseName IS NULL AND CheckID = 72 )
											BEGIN
												EXEC dbo.sp_MSforeachdb 'USE [?];
								insert into #partdb(dbname, objectname, type_desc)
								SELECT distinct db_name(DB_ID()) as DBName,o.name Object_Name,ds.type_desc
								FROM sys.objects AS o JOIN sys.indexes AS i ON o.object_id = i.object_id
								JOIN sys.data_spaces ds on ds.data_space_id = i.data_space_id
								LEFT OUTER JOIN sys.dm_db_index_usage_stats AS s ON i.object_id = s.object_id AND i.index_id = s.index_id AND s.database_id = DB_ID()
								WHERE  o.type = ''u''
								 -- Clustered and Non-Clustered indexes
								AND i.type IN (1, 2)
								AND o.object_id in
								  (
									SELECT a.object_id from
									  (SELECT ob.object_id, ds.type_desc from sys.objects ob JOIN sys.indexes ind on ind.object_id = ob.object_id join sys.data_spaces ds on ds.data_space_id = ind.data_space_id
									  GROUP BY ob.object_id, ds.type_desc ) a group by a.object_id having COUNT (*) > 1
								  )'
												INSERT  INTO #BlitzResults
														( CheckID ,
														  DatabaseName ,
														  Priority ,
														  FindingsGroup ,
														  Finding ,
														  URL ,
														  Details
														)
														SELECT DISTINCT
																72 AS CheckID ,
																dbname AS DatabaseName ,
																100 AS Priority ,
																'Performance' AS FindingsGroup ,
																'The partitioned database ' + dbname
																+ ' may have non-aligned indexes' AS Finding ,
																'http://BrentOzar.com/go/aligned' AS URL ,
																'Having non-aligned indexes on partitioned tables may cause inefficient query plans and CPU pressure' AS Details
														FROM    #partdb
														WHERE   dbname IS NOT NULL
																AND dbname NOT IN ( SELECT DISTINCT
																						  DatabaseName
																					FROM  #SkipChecks 
																					WHERE CheckID IS NULL)
												DROP TABLE #partdb
											END


					IF NOT EXISTS ( SELECT  1
									FROM    #SkipChecks
									WHERE   DatabaseName IS NULL AND CheckID = 113 )
									BEGIN
							  EXEC dbo.sp_MSforeachdb 'USE [?];
							  INSERT INTO #BlitzResults
									(CheckID,
									DatabaseName,
									Priority,
									FindingsGroup,
									Finding,
									URL,
									Details)
							  SELECT DISTINCT 113,
							  ''?'',
							  50,
							  ''Reliability'',
							  ''Full Text Indexes Not Updating'',
							  ''http://BrentOzar.com/go/fulltext'',
							  (''At least one full text index in this database has not been crawled in the last week.'')
							  from [?].sys.fulltext_indexes i WHERE change_tracking_state_desc <> ''AUTO'' AND i.is_enabled = 1 AND i.crawl_end_date < DATEADD(dd, -7, GETDATE())';
												END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 115 )
							BEGIN
								EXEC dbo.sp_MSforeachdb 'USE [?];
		  INSERT INTO #BlitzResults
				(CheckID,
				DatabaseName,
				Priority,
				FindingsGroup,
				Finding,
				URL,
				Details)
		  SELECT 115,
		  ''?'',
		  110,
		  ''Performance'',
		  ''Parallelism Rocket Surgery'',
		  ''http://BrentOzar.com/go/makeparallel'',
		  (''['' + DB_NAME() + ''] has a make_parallel function, indicating that an advanced developer may be manhandling SQL Server into forcing queries to go parallel.'')
		  from [?].INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_NAME = ''make_parallel'' AND ROUTINE_TYPE = ''FUNCTION''';
							END


						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 122 )
							BEGIN
								/* SQL Server 2012 and newer uses temporary stats for AlwaysOn Availability Groups, and those show up as user-created */
								IF EXISTS (SELECT *
									  FROM sys.all_columns c
									  INNER JOIN sys.all_objects o ON c.object_id = o.object_id
									  WHERE c.name = 'is_temporary' AND o.name = 'stats')

										EXEC dbo.sp_MSforeachdb 'USE [?];
												INSERT INTO #BlitzResults
													(CheckID,
													DatabaseName,
													Priority,
													FindingsGroup,
													Finding,
													URL,
													Details)
												SELECT TOP 1 122,
												''?'',
												200,
												''Performance'',
												''User-Created Statistics In Place'',
												''http://BrentOzar.com/go/userstats'',
												(''['' + DB_NAME() + ''] has '' + CAST(SUM(1) AS NVARCHAR(10)) + '' user-created statistics. This indicates that someone is being a rocket scientist with the stats, and might actually be slowing things down, especially during stats updates.'')
												from [?].sys.stats WHERE user_created = 1 AND is_temporary = 0
                                                HAVING SUM(1) > 0;';

									ELSE
										EXEC dbo.sp_MSforeachdb 'USE [?];
												INSERT INTO #BlitzResults
													(CheckID,
													DatabaseName,
													Priority,
													FindingsGroup,
													Finding,
													URL,
													Details)
												SELECT 122,
												''?'',
												200,
												''Performance'',
												''User-Created Statistics In Place'',
												''http://BrentOzar.com/go/userstats'',
												(''['' + DB_NAME() + ''] has '' + CAST(SUM(1) AS NVARCHAR(10)) + '' user-created statistics. This indicates that someone is being a rocket scientist with the stats, and might actually be slowing things down, especially during stats updates.'')
												from [?].sys.stats WHERE user_created = 1
                                                HAVING SUM(1) > 0;';


							END /* IF NOT EXISTS ( SELECT  1 */


		        /*Check for high VLF count: this will omit any database snapshots*/

				        IF NOT EXISTS ( SELECT  1
								        FROM    #SkipChecks
								        WHERE   DatabaseName IS NULL AND CheckID = 69 )
					        BEGIN
						        IF @ProductVersionMajor >= 11

							        BEGIN
								        EXEC sp_MSforeachdb N'USE [?];
		                                      INSERT INTO #LogInfo2012
		                                      EXEC sp_executesql N''DBCC LogInfo() WITH NO_INFOMSGS'';
		                                      IF    @@ROWCOUNT > 999
		                                      BEGIN
			                                    INSERT  INTO #BlitzResults
			                                    ( CheckID
			                                    ,DatabaseName
			                                    ,Priority
			                                    ,FindingsGroup
			                                    ,Finding
			                                    ,URL
			                                    ,Details)
			                                    SELECT      69
			                                    ,DB_NAME()
			                                    ,170
			                                    ,''File Configuration''
			                                    ,''High VLF Count''
			                                    ,''http://BrentOzar.com/go/vlf''
			                                    ,''The ['' + DB_NAME() + ''] database has '' +  CAST(COUNT(*) as VARCHAR(20)) + '' virtual log files (VLFs). This may be slowing down startup, restores, and even inserts/updates/deletes.''
			                                    FROM #LogInfo2012
			                                    WHERE EXISTS (SELECT name FROM master.sys.databases
					                                    WHERE source_database_id is null) ;
		                                      END
		                                    TRUNCATE TABLE #LogInfo2012;'
								        DROP TABLE #LogInfo2012;
							        END
						        ELSE
							        BEGIN
								        EXEC sp_MSforeachdb N'USE [?];
		                                      INSERT INTO #LogInfo
		                                      EXEC sp_executesql N''DBCC LogInfo() WITH NO_INFOMSGS'';
		                                      IF    @@ROWCOUNT > 999
		                                      BEGIN
			                                    INSERT  INTO #BlitzResults
			                                    ( CheckID
			                                    ,DatabaseName
			                                    ,Priority
			                                    ,FindingsGroup
			                                    ,Finding
			                                    ,URL
			                                    ,Details)
			                                    SELECT      69
			                                    ,DB_NAME()
			                                    ,170
			                                    ,''File Configuration''
			                                    ,''High VLF Count''
			                                    ,''http://BrentOzar.com/go/vlf''
			                                    ,''The ['' + DB_NAME() + ''] database has '' +  CAST(COUNT(*) as VARCHAR(20)) + '' virtual log files (VLFs). This may be slowing down startup, restores, and even inserts/updates/deletes.''
			                                    FROM #LogInfo
			                                    WHERE EXISTS (SELECT name FROM master.sys.databases
			                                    WHERE source_database_id is null);
		                                      END
		                                      TRUNCATE TABLE #LogInfo;'
								        DROP TABLE #LogInfo;
							        END
					        END


				        IF NOT EXISTS ( SELECT  1
								        FROM    #SkipChecks
								        WHERE   DatabaseName IS NULL AND CheckID = 80 )
					        BEGIN
						        EXEC dbo.sp_MSforeachdb 'USE [?]; INSERT INTO #BlitzResults (CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details) SELECT DISTINCT 80, DB_NAME(), 170, ''Reliability'', ''Max File Size Set'', ''http://BrentOzar.com/go/maxsize'', (''The ['' + DB_NAME() + ''] database file '' + name + '' has a max file size set to '' + CAST(CAST(max_size AS BIGINT) * 8 / 1024 AS VARCHAR(100)) + ''MB. If it runs out of space, the database will stop working even though there may be drive space available.'') FROM sys.database_files WHERE max_size <> 268435456 AND max_size <> -1 AND type <> 2 AND name <> ''DWDiagnostics'' ';
					        END

	
						/* Check if columnstore indexes are in use - for Github issue #615 */
				        IF NOT EXISTS ( SELECT  1
								        FROM    #SkipChecks
								        WHERE   DatabaseName IS NULL AND CheckID = 74 ) /* Trace flags */
					        BEGIN
								TRUNCATE TABLE #TemporaryDatabaseResults;
						        EXEC dbo.sp_MSforeachdb 'USE [?]; IF EXISTS(SELECT * FROM sys.indexes WHERE type IN (5,6)) INSERT INTO #TemporaryDatabaseResults (DatabaseName, Finding) VALUES (DB_NAME(), ''Yup'')';
								IF EXISTS (SELECT * FROM #TemporaryDatabaseResults) SET @ColumnStoreIndexesInUse = 1;
					        END


						/* Non-Default Database Scoped Config - Github issue #598 */
				        IF EXISTS ( SELECT * FROM sys.all_objects WHERE [name] = 'database_scoped_configurations' )
					        BEGIN
								INSERT INTO #DatabaseScopedConfigurationDefaults (configuration_id, [name], default_value, default_value_for_secondary, CheckID)
									SELECT 1, 'MAXDOP', 0, NULL, 194
									UNION ALL
									SELECT 2, 'LEGACY_CARDINALITY_ESTIMATION', 0, NULL, 195
									UNION ALL
									SELECT 3, 'PARAMETER_SNIFFING', 1, NULL, 196
									UNION ALL
									SELECT 4, 'QUERY_OPTIMIZER_HOTFIXES', 0, NULL, 197;
						        EXEC dbo.sp_MSforeachdb 'USE [?]; INSERT INTO #BlitzResults (CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details) 
									SELECT def1.CheckID, DB_NAME(), 210, ''Non-Default Database Scoped Config'', dsc.[name], ''http://BrentOzar.com/go/dbscope'', (''Set value: '' + COALESCE(CAST(dsc.value AS NVARCHAR(100)),''Empty'') + '' Default: '' + COALESCE(CAST(def1.default_value AS NVARCHAR(100)),''Empty'') + '' Set value for secondary: '' + COALESCE(CAST(dsc.value_for_secondary AS NVARCHAR(100)),''Empty'') + '' Default value for secondary: '' + COALESCE(CAST(def1.default_value_for_secondary AS NVARCHAR(100)),''Empty''))
									FROM [?].sys.database_scoped_configurations dsc 
									INNER JOIN #DatabaseScopedConfigurationDefaults def1 ON dsc.configuration_id = def1.configuration_id
									LEFT OUTER JOIN #DatabaseScopedConfigurationDefaults def ON dsc.configuration_id = def.configuration_id AND (dsc.value = def.default_value OR dsc.value IS NULL) AND (dsc.value_for_secondary = def.default_value_for_secondary OR dsc.value_for_secondary IS NULL)
									LEFT OUTER JOIN #SkipChecks sk ON def.CheckID = sk.CheckID AND (sk.DatabaseName IS NULL OR sk.DatabaseName = DB_NAME())
									WHERE def.configuration_id IS NULL AND sk.CheckID IS NULL ORDER BY 1';
					        END



	
					END /* IF @CheckUserDatabaseObjects = 1 */

				IF @CheckProcedureCache = 1
					BEGIN

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 35 )
							BEGIN
								INSERT  INTO #BlitzResults
										( CheckID ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details
										)
										SELECT  35 AS CheckID ,
												100 AS Priority ,
												'Performance' AS FindingsGroup ,
												'Single-Use Plans in Procedure Cache' AS Finding ,
												'http://BrentOzar.com/go/single' AS URL ,
												( CAST(COUNT(*) AS VARCHAR(10))
												  + ' query plans are taking up memory in the procedure cache. This may be wasted memory if we cache plans for queries that never get called again. This may be a good use case for SQL Server 2008''s Optimize for Ad Hoc or for Forced Parameterization.' ) AS Details
										FROM    sys.dm_exec_cached_plans AS cp
										WHERE   cp.usecounts = 1
												AND cp.objtype = 'Adhoc'
												AND EXISTS ( SELECT
																  1
															 FROM sys.configurations
															 WHERE
																  name = 'optimize for ad hoc workloads'
																  AND value_in_use = 0 )
										HAVING  COUNT(*) > 1;
							END


		  /* Set up the cache tables. Different on 2005 since it doesn't support query_hash, query_plan_hash. */
						IF @@VERSION LIKE '%Microsoft SQL Server 2005%'
							BEGIN
								IF @CheckProcedureCacheFilter = 'CPU'
									OR @CheckProcedureCacheFilter IS NULL
									BEGIN
										SET @StringToExecute = 'WITH queries ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time])
			  AS (SELECT TOP 20 qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time]
			  FROM sys.dm_exec_query_stats qs
			  ORDER BY qs.total_worker_time DESC)
			  INSERT INTO #dm_exec_query_stats ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time])
			  SELECT qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time]
			  FROM queries qs
			  LEFT OUTER JOIN #dm_exec_query_stats qsCaught ON qs.sql_handle = qsCaught.sql_handle AND qs.plan_handle = qsCaught.plan_handle AND qs.statement_start_offset = qsCaught.statement_start_offset
			  WHERE qsCaught.sql_handle IS NULL;'
										EXECUTE(@StringToExecute)
									END

								IF @CheckProcedureCacheFilter = 'Reads'
									OR @CheckProcedureCacheFilter IS NULL
									BEGIN
										SET @StringToExecute = 'WITH queries ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time])
		  AS (SELECT TOP 20 qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time]
		  FROM sys.dm_exec_query_stats qs
		  ORDER BY qs.total_logical_reads DESC)
		  INSERT INTO #dm_exec_query_stats ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time])
		  SELECT qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time]
		  FROM queries qs
		  LEFT OUTER JOIN #dm_exec_query_stats qsCaught ON qs.sql_handle = qsCaught.sql_handle AND qs.plan_handle = qsCaught.plan_handle AND qs.statement_start_offset = qsCaught.statement_start_offset
		  WHERE qsCaught.sql_handle IS NULL;'
										EXECUTE(@StringToExecute)
									END

								IF @CheckProcedureCacheFilter = 'ExecCount'
									OR @CheckProcedureCacheFilter IS NULL
									BEGIN
										SET @StringToExecute = 'WITH queries ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time])
		  AS (SELECT TOP 20 qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time]
		  FROM sys.dm_exec_query_stats qs
		  ORDER BY qs.execution_count DESC)
		  INSERT INTO #dm_exec_query_stats ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time])
		  SELECT qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time]
		  FROM queries qs
		  LEFT OUTER JOIN #dm_exec_query_stats qsCaught ON qs.sql_handle = qsCaught.sql_handle AND qs.plan_handle = qsCaught.plan_handle AND qs.statement_start_offset = qsCaught.statement_start_offset
		  WHERE qsCaught.sql_handle IS NULL;'
										EXECUTE(@StringToExecute)
									END

								IF @CheckProcedureCacheFilter = 'Duration'
									OR @CheckProcedureCacheFilter IS NULL
									BEGIN
										SET @StringToExecute = 'WITH queries ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time])
			AS (SELECT TOP 20 qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time]
			FROM sys.dm_exec_query_stats qs
			ORDER BY qs.total_elapsed_time DESC)
			INSERT INTO #dm_exec_query_stats ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time])
			SELECT qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time]
			FROM queries qs
			LEFT OUTER JOIN #dm_exec_query_stats qsCaught ON qs.sql_handle = qsCaught.sql_handle AND qs.plan_handle = qsCaught.plan_handle AND qs.statement_start_offset = qsCaught.statement_start_offset
			WHERE qsCaught.sql_handle IS NULL;'
										EXECUTE(@StringToExecute)
									END

							END;
						IF @ProductVersionMajor >= 10
							BEGIN
								IF @CheckProcedureCacheFilter = 'CPU'
									OR @CheckProcedureCacheFilter IS NULL
									BEGIN
										SET @StringToExecute = 'WITH queries ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time],[query_hash],[query_plan_hash])
		  AS (SELECT TOP 20 qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time],qs.[query_hash],qs.[query_plan_hash]
		  FROM sys.dm_exec_query_stats qs
		  ORDER BY qs.total_worker_time DESC)
		  INSERT INTO #dm_exec_query_stats ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time],[query_hash],[query_plan_hash])
		  SELECT qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time],qs.[query_hash],qs.[query_plan_hash]
		  FROM queries qs
		  LEFT OUTER JOIN #dm_exec_query_stats qsCaught ON qs.sql_handle = qsCaught.sql_handle AND qs.plan_handle = qsCaught.plan_handle AND qs.statement_start_offset = qsCaught.statement_start_offset
		  WHERE qsCaught.sql_handle IS NULL;'
										EXECUTE(@StringToExecute)
									END

								IF @CheckProcedureCacheFilter = 'Reads'
									OR @CheckProcedureCacheFilter IS NULL
									BEGIN
										SET @StringToExecute = 'WITH queries ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time],[query_hash],[query_plan_hash])
		  AS (SELECT TOP 20 qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time],qs.[query_hash],qs.[query_plan_hash]
		  FROM sys.dm_exec_query_stats qs
		  ORDER BY qs.total_logical_reads DESC)
		  INSERT INTO #dm_exec_query_stats ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time],[query_hash],[query_plan_hash])
		  SELECT qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time],qs.[query_hash],qs.[query_plan_hash]
		  FROM queries qs
		  LEFT OUTER JOIN #dm_exec_query_stats qsCaught ON qs.sql_handle = qsCaught.sql_handle AND qs.plan_handle = qsCaught.plan_handle AND qs.statement_start_offset = qsCaught.statement_start_offset
		  WHERE qsCaught.sql_handle IS NULL;'
										EXECUTE(@StringToExecute)
									END

								IF @CheckProcedureCacheFilter = 'ExecCount'
									OR @CheckProcedureCacheFilter IS NULL
									BEGIN
										SET @StringToExecute = 'WITH queries ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time],[query_hash],[query_plan_hash])
		  AS (SELECT TOP 20 qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time],qs.[query_hash],qs.[query_plan_hash]
		  FROM sys.dm_exec_query_stats qs
		  ORDER BY qs.execution_count DESC)
		  INSERT INTO #dm_exec_query_stats ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time],[query_hash],[query_plan_hash])
		  SELECT qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time],qs.[query_hash],qs.[query_plan_hash]
		  FROM queries qs
		  LEFT OUTER JOIN #dm_exec_query_stats qsCaught ON qs.sql_handle = qsCaught.sql_handle AND qs.plan_handle = qsCaught.plan_handle AND qs.statement_start_offset = qsCaught.statement_start_offset
		  WHERE qsCaught.sql_handle IS NULL;'
										EXECUTE(@StringToExecute)
									END

								IF @CheckProcedureCacheFilter = 'Duration'
									OR @CheckProcedureCacheFilter IS NULL
									BEGIN
										SET @StringToExecute = 'WITH queries ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time],[query_hash],[query_plan_hash])
		  AS (SELECT TOP 20 qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time],qs.[query_hash],qs.[query_plan_hash]
		  FROM sys.dm_exec_query_stats qs
		  ORDER BY qs.total_elapsed_time DESC)
		  INSERT INTO #dm_exec_query_stats ([sql_handle],[statement_start_offset],[statement_end_offset],[plan_generation_num],[plan_handle],[creation_time],[last_execution_time],[execution_count],[total_worker_time],[last_worker_time],[min_worker_time],[max_worker_time],[total_physical_reads],[last_physical_reads],[min_physical_reads],[max_physical_reads],[total_logical_writes],[last_logical_writes],[min_logical_writes],[max_logical_writes],[total_logical_reads],[last_logical_reads],[min_logical_reads],[max_logical_reads],[total_clr_time],[last_clr_time],[min_clr_time],[max_clr_time],[total_elapsed_time],[last_elapsed_time],[min_elapsed_time],[max_elapsed_time],[query_hash],[query_plan_hash])
		  SELECT qs.[sql_handle],qs.[statement_start_offset],qs.[statement_end_offset],qs.[plan_generation_num],qs.[plan_handle],qs.[creation_time],qs.[last_execution_time],qs.[execution_count],qs.[total_worker_time],qs.[last_worker_time],qs.[min_worker_time],qs.[max_worker_time],qs.[total_physical_reads],qs.[last_physical_reads],qs.[min_physical_reads],qs.[max_physical_reads],qs.[total_logical_writes],qs.[last_logical_writes],qs.[min_logical_writes],qs.[max_logical_writes],qs.[total_logical_reads],qs.[last_logical_reads],qs.[min_logical_reads],qs.[max_logical_reads],qs.[total_clr_time],qs.[last_clr_time],qs.[min_clr_time],qs.[max_clr_time],qs.[total_elapsed_time],qs.[last_elapsed_time],qs.[min_elapsed_time],qs.[max_elapsed_time],qs.[query_hash],qs.[query_plan_hash]
		  FROM queries qs
		  LEFT OUTER JOIN #dm_exec_query_stats qsCaught ON qs.sql_handle = qsCaught.sql_handle AND qs.plan_handle = qsCaught.plan_handle AND qs.statement_start_offset = qsCaught.statement_start_offset
		  WHERE qsCaught.sql_handle IS NULL;'
										EXECUTE(@StringToExecute)
									END

		/* Populate the query_plan_filtered field. Only works in 2005SP2+, but we're just doing it in 2008 to be safe. */
								UPDATE  #dm_exec_query_stats
								SET     query_plan_filtered = qp.query_plan
								FROM    #dm_exec_query_stats qs
										CROSS APPLY sys.dm_exec_text_query_plan(qs.plan_handle,
																  qs.statement_start_offset,
																  qs.statement_end_offset)
										AS qp

							END;

		/* Populate the additional query_plan, text, and text_filtered fields */
						UPDATE  #dm_exec_query_stats
						SET     query_plan = qp.query_plan ,
								[text] = st.[text] ,
								text_filtered = SUBSTRING(st.text,
														  ( qs.statement_start_offset
															/ 2 ) + 1,
														  ( ( CASE qs.statement_end_offset
																WHEN -1
																THEN DATALENGTH(st.text)
																ELSE qs.statement_end_offset
															  END
															  - qs.statement_start_offset )
															/ 2 ) + 1)
						FROM    #dm_exec_query_stats qs
								CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
								CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle)
								AS qp

		/* Dump instances of our own script. We're not trying to tune ourselves. */
						DELETE  #dm_exec_query_stats
						WHERE   text LIKE '%sp_Blitz%'
								OR text LIKE '%#BlitzResults%'

		/* Look for implicit conversions */

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 63 )
							BEGIN
								INSERT  INTO #BlitzResults
										( CheckID ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details ,
										  QueryPlan ,
										  QueryPlanFiltered
										)
										SELECT  63 AS CheckID ,
												120 AS Priority ,
												'Query Plans' AS FindingsGroup ,
												'Implicit Conversion' AS Finding ,
												'http://BrentOzar.com/go/implicit' AS URL ,
												( 'One of the top resource-intensive queries is comparing two fields that are not the same datatype.' ) AS Details ,
												qs.query_plan ,
												qs.query_plan_filtered
										FROM    #dm_exec_query_stats qs
										WHERE   COALESCE(qs.query_plan_filtered,
														 CAST(qs.query_plan AS NVARCHAR(MAX))) LIKE '%CONVERT_IMPLICIT%'
												AND COALESCE(qs.query_plan_filtered,
															 CAST(qs.query_plan AS NVARCHAR(MAX))) LIKE '%PhysicalOp="Index Scan"%'
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 64 )
							BEGIN
								INSERT  INTO #BlitzResults
										( CheckID ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details ,
										  QueryPlan ,
										  QueryPlanFiltered
										)
										SELECT  64 AS CheckID ,
												120 AS Priority ,
												'Query Plans' AS FindingsGroup ,
												'Implicit Conversion Affecting Cardinality' AS Finding ,
												'http://BrentOzar.com/go/implicit' AS URL ,
												( 'One of the top resource-intensive queries has an implicit conversion that is affecting cardinality estimation.' ) AS Details ,
												qs.query_plan ,
												qs.query_plan_filtered
										FROM    #dm_exec_query_stats qs
										WHERE   COALESCE(qs.query_plan_filtered,
														 CAST(qs.query_plan AS NVARCHAR(MAX))) LIKE '%<PlanAffectingConvert ConvertIssue="Cardinality Estimate" Expression="CONVERT_IMPLICIT%'
							END

							/* @cms4j, 29.11.2013: Look for RID or Key Lookups */
							IF NOT EXISTS ( SELECT  1
											FROM    #SkipChecks
											WHERE   DatabaseName IS NULL AND CheckID = 118 )
								BEGIN
									INSERT  INTO #BlitzResults
											( CheckID ,
											  Priority ,
											  FindingsGroup ,
											  Finding ,
											  URL ,
											  Details ,
											  QueryPlan ,
											  QueryPlanFiltered
											)
											SELECT  118 AS CheckID ,
													120 AS Priority ,
													'Query Plans' AS FindingsGroup ,
													'RID or Key Lookups' AS Finding ,
													'http://BrentOzar.com/go/lookup' AS URL ,
													'One of the top resource-intensive queries contains RID or Key Lookups. Try to avoid them by creating covering indexes.' AS Details ,
													qs.query_plan ,
													qs.query_plan_filtered
											FROM    #dm_exec_query_stats qs
											WHERE   COALESCE(qs.query_plan_filtered,
															 CAST(qs.query_plan AS NVARCHAR(MAX))) LIKE '%Lookup="1"%'
								END /* @cms4j, 29.11.2013: Look for RID or Key Lookups */


						/* Look for missing indexes */
						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 65 )
							BEGIN
								INSERT  INTO #BlitzResults
										( CheckID ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details ,
										  QueryPlan ,
										  QueryPlanFiltered
										)
										SELECT  65 AS CheckID ,
												120 AS Priority ,
												'Query Plans' AS FindingsGroup ,
												'Missing Index' AS Finding ,
												'http://BrentOzar.com/go/missingindex' AS URL ,
												( 'One of the top resource-intensive queries may be dramatically improved by adding an index.' ) AS Details ,
												qs.query_plan ,
												qs.query_plan_filtered
										FROM    #dm_exec_query_stats qs
										WHERE   COALESCE(qs.query_plan_filtered,
														 CAST(qs.query_plan AS NVARCHAR(MAX))) LIKE '%MissingIndexGroup%'
							END

						/* Look for cursors */
						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 66 )
							BEGIN
								INSERT  INTO #BlitzResults
										( CheckID ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details ,
										  QueryPlan ,
										  QueryPlanFiltered
										)
										SELECT  66 AS CheckID ,
												120 AS Priority ,
												'Query Plans' AS FindingsGroup ,
												'Cursor' AS Finding ,
												'http://BrentOzar.com/go/cursor' AS URL ,
												( 'One of the top resource-intensive queries is using a cursor.' ) AS Details ,
												qs.query_plan ,
												qs.query_plan_filtered
										FROM    #dm_exec_query_stats qs
										WHERE   COALESCE(qs.query_plan_filtered,
														 CAST(qs.query_plan AS NVARCHAR(MAX))) LIKE '%<StmtCursor%'
							END

		/* Look for scalar user-defined functions */

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 67 )
							BEGIN
								INSERT  INTO #BlitzResults
										( CheckID ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details ,
										  QueryPlan ,
										  QueryPlanFiltered
										)
										SELECT  67 AS CheckID ,
												120 AS Priority ,
												'Query Plans' AS FindingsGroup ,
												'Scalar UDFs' AS Finding ,
												'http://BrentOzar.com/go/functions' AS URL ,
												( 'One of the top resource-intensive queries is using a user-defined scalar function that may inhibit parallelism.' ) AS Details ,
												qs.query_plan ,
												qs.query_plan_filtered
										FROM    #dm_exec_query_stats qs
										WHERE   COALESCE(qs.query_plan_filtered,
														 CAST(qs.query_plan AS NVARCHAR(MAX))) LIKE '%<UserDefinedFunction%'
							END

					END /* IF @CheckProcedureCache = 1 */
									  
		/*Check to see if the HA endpoint account is set at the same as the SQL Server Service Account*/
		IF @ProductVersionMajor >= 10
								AND NOT EXISTS ( SELECT 1
								FROM #SkipChecks
								WHERE DatabaseName IS NULL AND CheckID = 187 )

		IF SERVERPROPERTY('IsHadrEnabled') = 1
    		BEGIN
                INSERT    INTO [#BlitzResults]
                               	( [CheckID] ,
                                [Priority] ,
                                [FindingsGroup] ,
                                [Finding] ,
                                [URL] ,
                                [Details] )
               	SELECT
                        187 AS [CheckID] ,
                        230 AS [Priority] ,
                        'Security' AS [FindingsGroup] ,
                        'Endpoints Owned by Users' AS [Finding] ,
                       	'http://BrentOzar.com/go/owners' AS [URL] ,
                        ( 'Endpoint ' + ep.[name] + ' is owned by ' + SUSER_NAME(ep.principal_id) + '. If the endpoint owner login is disabled or not available due to Active Directory problems, the high availability will stop working.'
                        ) AS [Details]
					FROM sys.database_mirroring_endpoints ep
					LEFT OUTER JOIN sys.dm_server_services s ON SUSER_NAME(ep.principal_id) = s.service_account
					WHERE s.service_account IS NULL;
    		END

		/*Check for the last good DBCC CHECKDB date */
				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 68 )
					BEGIN
						EXEC sp_MSforeachdb N'USE [?];
						INSERT #DBCCs
							(ParentObject,
							Object,
							Field,
							Value)
						EXEC (''DBCC DBInfo() With TableResults, NO_INFOMSGS'');
						UPDATE #DBCCs SET DbName = N''?'' WHERE DbName IS NULL;';

						WITH    DB2
								  AS ( SELECT DISTINCT
												Field ,
												Value ,
												DbName
									   FROM     #DBCCs
									   WHERE    Field = 'dbi_dbccLastKnownGood'
									 )
							INSERT  INTO #BlitzResults
									( CheckID ,
									  DatabaseName ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  68 AS CheckID ,
											DB2.DbName AS DatabaseName ,
											1 AS PRIORITY ,
											'Reliability' AS FindingsGroup ,
											'Last good DBCC CHECKDB over 2 weeks old' AS Finding ,
											'http://BrentOzar.com/go/checkdb' AS URL ,
											'Last successful CHECKDB: '
											+ CASE DB2.Value
												WHEN '1900-01-01 00:00:00.000'
												THEN ' never.'
												ELSE DB2.Value
											  END AS Details
									FROM    DB2
									WHERE   DB2.DbName <> 'tempdb'
											AND DB2.DbName NOT IN ( SELECT DISTINCT
																  DatabaseName
																FROM
																  #SkipChecks 
																WHERE CheckID IS NULL)
											AND CONVERT(DATETIME, DB2.Value, 121) < DATEADD(DD,
																  -14,
																  CURRENT_TIMESTAMP)
					END




	/*Verify that the servername is set */
			IF NOT EXISTS ( SELECT  1
							FROM    #SkipChecks
							WHERE   DatabaseName IS NULL AND CheckID = 70 )
				BEGIN
					IF @@SERVERNAME IS NULL
						BEGIN
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  70 AS CheckID ,
											200 AS Priority ,
											'Informational' AS FindingsGroup ,
											'@@Servername Not Set' AS Finding ,
											'http://BrentOzar.com/go/servername' AS URL ,
											'@@Servername variable is null. You can fix it by executing: "sp_addserver ''<LocalServerName>'', local"' AS Details
						END;

					IF  /* @@SERVERNAME IS set */
						(@@SERVERNAME IS NOT NULL
						AND
						/* not a named instance */
						CHARINDEX('\',CAST(SERVERPROPERTY('ServerName') AS NVARCHAR)) = 0
						AND
						/* not clustered, when computername may be different than the servername */
						SERVERPROPERTY('IsClustered') = 0
						AND
						/* @@SERVERNAME is different than the computer name */
						@@SERVERNAME <> CAST(ISNULL(SERVERPROPERTY('ComputerNamePhysicalNetBIOS'),@@SERVERNAME) AS NVARCHAR) )
						 BEGIN
							INSERT  INTO #BlitzResults
									( CheckID ,
									  Priority ,
									  FindingsGroup ,
									  Finding ,
									  URL ,
									  Details
									)
									SELECT  70 AS CheckID ,
											200 AS Priority ,
											'Configuration' AS FindingsGroup ,
											'@@Servername Not Correct' AS Finding ,
											'http://BrentOzar.com/go/servername' AS URL ,
											'The @@Servername is different than the computer name, which may trigger certificate errors.' AS Details
						END;

				END
		/*Check to see if a failsafe operator has been configured*/
				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 73 )
					BEGIN

						DECLARE @AlertInfo TABLE
							(
							  FailSafeOperator NVARCHAR(255) ,
							  NotificationMethod INT ,
							  ForwardingServer NVARCHAR(255) ,
							  ForwardingSeverity INT ,
							  PagerToTemplate NVARCHAR(255) ,
							  PagerCCTemplate NVARCHAR(255) ,
							  PagerSubjectTemplate NVARCHAR(255) ,
							  PagerSendSubjectOnly NVARCHAR(255) ,
							  ForwardAlways INT
							)
						INSERT  INTO @AlertInfo
								EXEC [master].[dbo].[sp_MSgetalertinfo] @includeaddresses = 0
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  73 AS CheckID ,
										200 AS Priority ,
										'Monitoring' AS FindingsGroup ,
										'No failsafe operator configured' AS Finding ,
										'http://BrentOzar.com/go/failsafe' AS URL ,
										( 'No failsafe operator is configured on this server.  This is a good idea just in-case there are issues with the [msdb] database that prevents alerting.' ) AS Details
								FROM    @AlertInfo
								WHERE   FailSafeOperator IS NULL;
					END

/*Identify globally enabled trace flags*/
				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 74 )
					BEGIN
						INSERT  INTO #TraceStatus
								EXEC ( ' DBCC TRACESTATUS(-1) WITH NO_INFOMSGS'
									)
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  74 AS CheckID ,
										200 AS Priority ,
										'Informational' AS FindingsGroup ,
										'TraceFlag On' AS Finding ,
										CASE WHEN [T].[TraceFlag] = '834'  AND @ColumnStoreIndexesInUse = 1 THEN 'https://support.microsoft.com/en-us/kb/3210239'
											 ELSE'http://www.BrentOzar.com/go/traceflags/' END AS URL ,
										'Trace flag ' + 
										CASE WHEN [T].[TraceFlag] = '2330' THEN ' 2330 enabled globally. Using this trace Flag disables missing index requests'
											 WHEN [T].[TraceFlag] = '1211' THEN ' 1211 enabled globally. Using this Trace Flag disables lock escalation when you least expect it. No Bueno!'
											 WHEN [T].[TraceFlag] = '1224' THEN ' 1224 enabled globally. Using this Trace Flag disables lock escalation based on the number of locks being taken. You shouldn''t have done that, Dave.'
											 WHEN [T].[TraceFlag] = '652'  THEN ' 652 enabled globally. Using this Trace Flag disables pre-fetching during index scans. If you hate slow queries, you should turn that off.'
											 WHEN [T].[TraceFlag] = '661'  THEN ' 661 enabled globally. Using this Trace Flag disables ghost record removal. Who you gonna call? No one, turn that thing off.'
											 WHEN [T].[TraceFlag] = '1806'  THEN ' 1806 enabled globally. Using this Trace Flag disables instant file initialization. I question your sanity.'
											 WHEN [T].[TraceFlag] = '3505'  THEN ' 3505 enabled globally. Using this Trace Flag disables Checkpoints. Probably not the wisest idea.'
											 WHEN [T].[TraceFlag] = '8649'  THEN ' 8649 enabled globally. Using this Trace Flag drops cost thresholf for parallelism down to 0. I hope this is a dev server.'
										     WHEN [T].[TraceFlag] = '834' AND @ColumnStoreIndexesInUse = 1 THEN ' 834 is enabled globally. Using this Trace Flag with Columnstore Indexes is not a great idea.'
											 ELSE [T].[TraceFlag] + ' is enabled globally.' END 
										AS Details
								FROM    #TraceStatus T
					END

		/*Check for transaction log file larger than data file */
				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 75 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  75 AS CheckID ,
										DB_NAME(a.database_id) ,
										50 AS Priority ,
										'Reliability' AS FindingsGroup ,
										'Transaction Log Larger than Data File' AS Finding ,
										'http://BrentOzar.com/go/biglog' AS URL ,
										'The database [' + DB_NAME(a.database_id)
										+ '] has a ' + CAST((CAST(a.size AS BIGINT) * 8 / 1000000) AS NVARCHAR(20)) + ' GB transaction log file, larger than the total data file sizes. This may indicate that transaction log backups are not being performed or not performed often enough.' AS Details
								FROM    sys.master_files a
								WHERE   a.type = 1
										AND DB_NAME(a.database_id) NOT IN (
										SELECT DISTINCT
												DatabaseName
										FROM    #SkipChecks )
										AND a.size > 125000 /* Size is measured in pages here, so this gets us log files over 1GB. */
										AND a.size > ( SELECT   SUM(CAST(b.size AS BIGINT))
													   FROM     sys.master_files b
													   WHERE    a.database_id = b.database_id
																AND b.type = 0
													 )
										AND a.database_id IN (
										SELECT  database_id
										FROM    sys.databases
										WHERE   source_database_id IS NULL )
					END

		/*Check for collation conflicts between user databases and tempdb */
				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 76 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  76 AS CheckID ,
										name AS DatabaseName ,
										200 AS Priority ,
										'Informational' AS FindingsGroup ,
										'Collation is ' + collation_name AS Finding ,
										'http://BrentOzar.com/go/collate' AS URL ,
										'Collation differences between user databases and tempdb can cause conflicts especially when comparing string values' AS Details
								FROM    sys.databases
							WHERE   name NOT IN ( 'master', 'model', 'msdb')
										AND name NOT LIKE 'ReportServer%'
										AND name NOT IN ( SELECT DISTINCT
																  DatabaseName
														  FROM    #SkipChecks 
														  WHERE CheckID IS NULL)
										AND collation_name <> ( SELECT
																  collation_name
																FROM
																  sys.databases
																WHERE
																  name = 'tempdb'
															  )
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 77 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  DatabaseName ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  77 AS CheckID ,
										dSnap.[name] AS DatabaseName ,
										50 AS Priority ,
										'Reliability' AS FindingsGroup ,
										'Database Snapshot Online' AS Finding ,
										'http://BrentOzar.com/go/snapshot' AS URL ,
										'Database [' + dSnap.[name]
										+ '] is a snapshot of ['
										+ dOriginal.[name]
										+ ']. Make sure you have enough drive space to maintain the snapshot as the original database grows.' AS Details
								FROM    sys.databases dSnap
										INNER JOIN sys.databases dOriginal ON dSnap.source_database_id = dOriginal.database_id
																  AND dSnap.name NOT IN (
																  SELECT DISTINCT
																  DatabaseName
																  FROM
																  #SkipChecks )
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 79 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  79 AS CheckID ,
										100 AS Priority ,
										'Performance' AS FindingsGroup ,
										'Shrink Database Job' AS Finding ,
										'http://BrentOzar.com/go/autoshrink' AS URL ,
										'In the [' + j.[name] + '] job, step ['
										+ step.[step_name]
										+ '] has SHRINKDATABASE or SHRINKFILE, which may be causing database fragmentation.' AS Details
								FROM    msdb.dbo.sysjobs j
										INNER JOIN msdb.dbo.sysjobsteps step ON j.job_id = step.job_id
								WHERE   step.command LIKE N'%SHRINKDATABASE%'
										OR step.command LIKE N'%SHRINKFILE%'
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 81 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT  81 AS CheckID ,
										200 AS Priority ,
										'Non-Active Server Config' AS FindingsGroup ,
										cr.name AS Finding ,
										'http://www.BrentOzar.com/blitz/sp_configure/' AS URL ,
										( 'This sp_configure option isn''t running under its set value.  Its set value is '
										  + CAST(cr.[value] AS VARCHAR(100))
										  + ' and its running value is '
										  + CAST(cr.value_in_use AS VARCHAR(100))
										  + '. When someone does a RECONFIGURE or restarts the instance, this setting will start taking effect.' ) AS Details
								FROM    sys.configurations cr
								WHERE   cr.value <> cr.value_in_use
                                 AND NOT (cr.name = 'min server memory (MB)' AND cr.value IN (0,16) AND cr.value_in_use IN (0,16));
					END

				IF NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 123 )
					BEGIN
						INSERT  INTO #BlitzResults
								( CheckID ,
								  Priority ,
								  FindingsGroup ,
								  Finding ,
								  URL ,
								  Details
								)
								SELECT TOP 1 123 AS CheckID ,
										200 AS Priority ,
										'Informational' AS FindingsGroup ,
										'Agent Jobs Starting Simultaneously' AS Finding ,
										'http://BrentOzar.com/go/busyagent/' AS URL ,
										( 'Multiple SQL Server Agent jobs are configured to start simultaneously. For detailed schedule listings, see the query in the URL.' ) AS Details
								FROM    msdb.dbo.sysjobactivity
								WHERE start_execution_date > DATEADD(dd, -14, GETDATE())
								GROUP BY start_execution_date HAVING COUNT(*) > 1;
					END


				IF @CheckServerInfo = 1
					BEGIN

/*This checks Windows version. It would be better if Microsoft gave everything a separate build number, but whatever.*/
IF @ProductVersionMajor >= 10 AND @ProductVersionMinor >= 50 
			   AND NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 172 )
					BEGIN
					IF EXISTS ( SELECT  1
											FROM    sys.all_objects
											WHERE   name = 'dm_os_windows_info' )

					BEGIN
						  INSERT    INTO [#BlitzResults]
									( [CheckID] ,
									  [Priority] ,
									  [FindingsGroup] ,
									  [Finding] ,
									  [URL] ,
									  [Details] )

							SELECT
							172 AS [CheckID] ,
							250 AS [Priority] ,
							'Server Info' AS [FindingsGroup] ,
							'Windows Version' AS [Finding] ,
							'https://en.wikipedia.org/wiki/List_of_Microsoft_Windows_versions' AS [URL] ,
							( CASE 
								WHEN [owi].[windows_release] = '5' THEN 'You''re running a really old version: Windows 2000, version ' + CAST([owi].[windows_release] AS VARCHAR(5))
								WHEN [owi].[windows_release] > '5' AND [owi].[windows_release] < '6' THEN 'You''re running a really old version: Windows Server 2003/2003R2 era, version ' + CAST([owi].[windows_release] AS VARCHAR(5))
								WHEN [owi].[windows_release] >= '6' AND [owi].[windows_release] <= '6.1' THEN 'You''re running a pretty old version: Windows: Server 2008/2008R2 era, version ' + CAST([owi].[windows_release] AS VARCHAR(5))
								WHEN [owi].[windows_release] = '6.2' THEN 'You''re running a rather modern version of Windows: Server 2012 era, version ' + CAST([owi].[windows_release] AS VARCHAR(5))
								WHEN [owi].[windows_release] = '6.3' THEN 'You''re running a pretty modern version of Windows: Server 2012R2 era, version ' + CAST([owi].[windows_release] AS VARCHAR(5))
								WHEN [owi].[windows_release] > '6.3' THEN 'Hot dog! You''re living in the future! You''re running version ' + CAST([owi].[windows_release] AS VARCHAR(5))
								ELSE 'I have no idea which version of Windows you''re on. Sorry.'
								END
							   ) AS [Details]
							 FROM [sys].[dm_os_windows_info] [owi]

					END;
					END;

/*
This check hits the dm_os_process_memory system view
to see if locked_page_allocations_kb is > 0,
which could indicate that locked pages in memory is enabled.
*/
IF @ProductVersionMajor >= 10 AND  NOT EXISTS ( SELECT  1
								FROM    #SkipChecks
								WHERE   DatabaseName IS NULL AND CheckID = 166 )
					BEGIN
						  INSERT    INTO [#BlitzResults]
									( [CheckID] ,
									  [Priority] ,
									  [FindingsGroup] ,
									  [Finding] ,
									  [URL] ,
									  [Details] )
							SELECT
							166 AS [CheckID] ,
							250 AS [Priority] ,
							'Server Info' AS [FindingsGroup] ,
							'Locked Pages In Memory Enabled' AS [Finding] ,
							'http://BrentOzar.com/go/lpim' AS [URL] ,
							( 'You currently have '
							  + CASE WHEN [dopm].[locked_page_allocations_kb] / 1024. / 1024. > 0
									 THEN CAST([dopm].[locked_page_allocations_kb] / 1024. / 1024. AS VARCHAR(100))
										  + ' GB'
									 ELSE CAST([dopm].[locked_page_allocations_kb] / 1024. AS VARCHAR(100))
										  + ' MB'
								END + ' of pages locked in memory.' ) AS [Details]
						  FROM
							[sys].[dm_os_process_memory] AS [dopm]
						  WHERE
							[dopm].[locked_page_allocations_kb] > 0;
					END; 

			/* Server Info - Locked Pages In Memory Enabled - Check 166 - SQL Server 2016 SP1 and newer */
						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 166 )
							AND EXISTS ( SELECT  *
											FROM    sys.all_objects o
													INNER JOIN sys.all_columns c ON o.object_id = c.object_id
											WHERE   o.name = 'dm_os_sys_info'
													AND c.name = 'sql_memory_model' )
							BEGIN
										SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
			SELECT  166 AS CheckID ,
			250 AS Priority ,
			''Server Info'' AS FindingsGroup ,
			''Memory Model Unconventional'' AS Finding ,
			''http://BrentOzar.com/go/lpim'' AS URL ,
			''Memory Model: '' + CAST(sql_memory_model_desc AS NVARCHAR(100))
			FROM sys.dm_os_sys_info WHERE sql_memory_model <> 1';
										EXECUTE(@StringToExecute);
									END



			/*
			Starting with SQL Server 2014 SP2, Instant File Initialization 
			is logged in the SQL Server Error Log.
			*/
					IF NOT EXISTS ( SELECT  1
									FROM    #SkipChecks
									WHERE   DatabaseName IS NULL AND CheckID = 184 )
							AND (@ProductVersionMajor >= 13) OR (@ProductVersionMajor = 12 AND @ProductVersionMinor >= 5000)
						BEGIN
							INSERT INTO #ErrorLog
							EXEC sys.xp_readerrorlog 0, 1, N'Database Instant File Initialization: enabled';

							IF @@ROWCOUNT > 0
								INSERT  INTO #BlitzResults
										( CheckID ,
										  [Priority] ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details
										)
										SELECT
												193 AS [CheckID] ,
												250 AS [Priority] ,
												'Server Info' AS [FindingsGroup] ,
												'Instant File Initialization Enabled' AS [Finding] ,
												'http://BrentOzar.com/go/instant' AS [URL] ,
												'The service account has the Perform Volume Maintenance Tasks permission.'
						END; 

			/* Server Info - Instant File Initialization Not Enabled - Check 192 - SQL Server 2016 SP1 and newer */
						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 192 )
							AND EXISTS ( SELECT  *
											FROM    sys.all_objects o
													INNER JOIN sys.all_columns c ON o.object_id = c.object_id
											WHERE   o.name = 'dm_server_services'
													AND c.name = 'instant_file_initialization_enabled' )
							BEGIN
										SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
			SELECT  192 AS CheckID ,
			50 AS Priority ,
			''Server Info'' AS FindingsGroup ,
			''Instant File Initialization Not Enabled'' AS Finding ,
			''http://BrentOzar.com/go/instant'' AS URL ,
			''Consider enabling IFI for faster restores and data file growths.''
			FROM sys.dm_server_services WHERE instant_file_initialization_enabled <> ''Y'' AND filename LIKE ''%sqlservr.exe%''';
										EXECUTE(@StringToExecute);
									END





					IF NOT EXISTS ( SELECT  1
									FROM    #SkipChecks
									WHERE   DatabaseName IS NULL AND CheckID = 130 )
						BEGIN
									INSERT  INTO #BlitzResults
											( CheckID ,
											  Priority ,
											  FindingsGroup ,
											  Finding ,
											  URL ,
											  Details
											)
											SELECT  130 AS CheckID ,
													250 AS Priority ,
													'Server Info' AS FindingsGroup ,
													'Server Name' AS Finding ,
													'http://BrentOzar.com/go/servername' AS URL ,
													@@SERVERNAME AS Details
												WHERE @@SERVERNAME IS NOT NULL;
								END;



						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 83 )
							BEGIN
								IF EXISTS ( SELECT  *
											FROM    sys.all_objects
											WHERE   name = 'dm_server_services' )
									BEGIN
										SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
				SELECT  83 AS CheckID ,
				250 AS Priority ,
				''Server Info'' AS FindingsGroup ,
				''Services'' AS Finding ,
				'''' AS URL ,
				N''Service: '' + servicename + N'' runs under service account '' + service_account + N''. Last startup time: '' + COALESCE(CAST(CAST(last_startup_time AS DATETIME) AS VARCHAR(50)), ''not shown.'') + ''. Startup type: '' + startup_type_desc + N'', currently '' + status_desc + ''.''
				FROM sys.dm_server_services;'
										EXECUTE(@StringToExecute);
									END
							END

			/* Check 84 - SQL Server 2012 */
						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 84 )
							BEGIN
								IF EXISTS ( SELECT  *
											FROM    sys.all_objects o
													INNER JOIN sys.all_columns c ON o.object_id = c.object_id
											WHERE   o.name = 'dm_os_sys_info'
													AND c.name = 'physical_memory_kb' )
									BEGIN
										SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
			SELECT  84 AS CheckID ,
			250 AS Priority ,
			''Server Info'' AS FindingsGroup ,
			''Hardware'' AS Finding ,
			'''' AS URL ,
			''Logical processors: '' + CAST(cpu_count AS VARCHAR(50)) + ''. Physical memory: '' + CAST( CAST(ROUND((physical_memory_kb / 1024.0 / 1024), 1) AS INT) AS VARCHAR(50)) + ''GB.''
			FROM sys.dm_os_sys_info';
										EXECUTE(@StringToExecute);
									END

			/* Check 84 - SQL Server 2008 */
								IF EXISTS ( SELECT  *
											FROM    sys.all_objects o
													INNER JOIN sys.all_columns c ON o.object_id = c.object_id
											WHERE   o.name = 'dm_os_sys_info'
													AND c.name = 'physical_memory_in_bytes' )
									BEGIN
										SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
			SELECT  84 AS CheckID ,
			250 AS Priority ,
			''Server Info'' AS FindingsGroup ,
			''Hardware'' AS Finding ,
			'''' AS URL ,
			''Logical processors: '' + CAST(cpu_count AS VARCHAR(50)) + ''. Physical memory: '' + CAST( CAST(ROUND((physical_memory_in_bytes / 1024.0 / 1024 / 1024), 1) AS INT) AS VARCHAR(50)) + ''GB.''
			FROM sys.dm_os_sys_info';
										EXECUTE(@StringToExecute);
									END
							END


						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 85 )
							BEGIN
								INSERT  INTO #BlitzResults
										( CheckID ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details
										)
										SELECT  85 AS CheckID ,
												250 AS Priority ,
												'Server Info' AS FindingsGroup ,
												'SQL Server Service' AS Finding ,
												'' AS URL ,
												N'Version: '
												+ CAST(SERVERPROPERTY('productversion') AS NVARCHAR(100))
												+ N'. Patch Level: '
												+ CAST(SERVERPROPERTY('productlevel') AS NVARCHAR(100))
												+ N'. Edition: '
												+ CAST(SERVERPROPERTY('edition') AS VARCHAR(100))
												+ N'. AlwaysOn Enabled: '
												+ CAST(COALESCE(SERVERPROPERTY('IsHadrEnabled'),
																0) AS VARCHAR(100))
												+ N'. AlwaysOn Mgr Status: '
												+ CAST(COALESCE(SERVERPROPERTY('HadrManagerStatus'),
																0) AS VARCHAR(100))
							END


						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 88 )
							BEGIN
								INSERT  INTO #BlitzResults
										( CheckID ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details
										)
										SELECT  88 AS CheckID ,
												250 AS Priority ,
												'Server Info' AS FindingsGroup ,
												'SQL Server Last Restart' AS Finding ,
												'' AS URL ,
												CAST(create_date AS VARCHAR(100))
										FROM    sys.databases
										WHERE   database_id = 2
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 91 )
							BEGIN
								INSERT  INTO #BlitzResults
										( CheckID ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details
										)
										SELECT  91 AS CheckID ,
												250 AS Priority ,
												'Server Info' AS FindingsGroup ,
												'Server Last Restart' AS Finding ,
												'' AS URL ,
												CAST(DATEADD(SECOND, (ms_ticks/1000)*(-1), GETDATE()) AS nvarchar(25))
										FROM sys.dm_os_sys_info
							END


						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 92 )
							BEGIN
								INSERT  INTO #driveInfo
										( drive, SIZE )
										EXEC master..xp_fixeddrives

								INSERT  INTO #BlitzResults
										( CheckID ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details
										)
										SELECT  92 AS CheckID ,
												250 AS Priority ,
												'Server Info' AS FindingsGroup ,
												'Drive ' + i.drive + ' Space' AS Finding ,
												'' AS URL ,
												CAST(i.SIZE AS VARCHAR)
												+ 'MB free on ' + i.drive
												+ ' drive' AS Details
										FROM    #driveInfo AS i
								DROP TABLE #driveInfo
							END


						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 103 )
							AND EXISTS ( SELECT *
										 FROM   sys.all_objects o
												INNER JOIN sys.all_columns c ON o.object_id = c.object_id
										 WHERE  o.name = 'dm_os_sys_info'
												AND c.name = 'virtual_machine_type_desc' )
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
									SELECT 103 AS CheckID,
									250 AS Priority,
									''Server Info'' AS FindingsGroup,
									''Virtual Server'' AS Finding,
									''http://BrentOzar.com/go/virtual'' AS URL,
									''Type: ('' + virtual_machine_type_desc + '')'' AS Details
									FROM sys.dm_os_sys_info
									WHERE virtual_machine_type <> 0';
								EXECUTE(@StringToExecute);
							END

						IF NOT EXISTS ( SELECT  1
										FROM    #SkipChecks
										WHERE   DatabaseName IS NULL AND CheckID = 114 )
							AND EXISTS ( SELECT *
										 FROM   sys.all_objects o
										 WHERE  o.name = 'dm_os_memory_nodes' )
							AND EXISTS ( SELECT *
										 FROM   sys.all_objects o
										 INNER JOIN sys.all_columns c ON o.object_id = c.object_id
										 WHERE  o.name = 'dm_os_nodes'
                                	 		AND c.name = 'processor_group' )
							BEGIN
								SET @StringToExecute = 'INSERT INTO #BlitzResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
										SELECT  114 AS CheckID ,
												250 AS Priority ,
												''Server Info'' AS FindingsGroup ,
												''Hardware - NUMA Config'' AS Finding ,
												'''' AS URL ,
												''Node: '' + CAST(n.node_id AS NVARCHAR(10)) + '' State: '' + node_state_desc
												+ '' Online schedulers: '' + CAST(n.online_scheduler_count AS NVARCHAR(10)) + '' Offline schedulers: '' + CAST(oac.offline_schedulers AS VARCHAR(100)) + '' Processor Group: '' + CAST(n.processor_group AS NVARCHAR(10))
												+ '' Memory node: '' + CAST(n.memory_node_id AS NVARCHAR(10)) + '' Memory VAS Reserved GB: '' + CAST(CAST((m.virtual_address_space_reserved_kb / 1024.0 / 1024) AS INT) AS NVARCHAR(100))
										FROM sys.dm_os_nodes n
										INNER JOIN sys.dm_os_memory_nodes m ON n.memory_node_id = m.memory_node_id
										OUTER APPLY (SELECT 
										COUNT(*) AS [offline_schedulers]
										FROM sys.dm_os_schedulers dos
										WHERE n.node_id = dos.parent_node_id 
										AND dos.status = ''VISIBLE OFFLINE''
										) oac
										WHERE n.node_state_desc NOT LIKE ''%DAC%''
										ORDER BY n.node_id'
								EXECUTE(@StringToExecute);
							END


							IF NOT EXISTS ( SELECT  1
											FROM    #SkipChecks
											WHERE   DatabaseName IS NULL AND CheckID = 106 )
											AND (select convert(int,value_in_use) from sys.configurations where name = 'default trace enabled' ) = 1
                                AND DATALENGTH( COALESCE( @base_tracefilename, '' ) ) > DATALENGTH('.TRC')
							BEGIN

								INSERT  INTO #BlitzResults
										( CheckID ,
										  Priority ,
										  FindingsGroup ,
										  Finding ,
										  URL ,
										  Details
										)
										SELECT
												 106 AS CheckID
												,250 AS Priority
												,'Server Info' AS FindingsGroup
												,'Default Trace Contents' AS Finding
												,'http://BrentOzar.com/go/trace' AS URL
												,'The default trace holds '+cast(DATEDIFF(hour,MIN(StartTime),GETDATE())as varchar)+' hours of data'
												+' between '+cast(Min(StartTime) as varchar)+' and '+cast(GETDATE()as varchar)
												+('. The default trace files are located in: '+left( @curr_tracefilename,len(@curr_tracefilename) - @indx)
												) as Details
										FROM    ::fn_trace_gettable( @base_tracefilename, default )
										WHERE EventClass BETWEEN 65500 and 65600
							END /* CheckID 106 */


							IF NOT EXISTS ( SELECT  1
											FROM    #SkipChecks
											WHERE   DatabaseName IS NULL AND CheckID = 152 )
							BEGIN
								IF EXISTS (SELECT * FROM sys.dm_os_wait_stats ws
											LEFT OUTER JOIN #IgnorableWaits i ON ws.wait_type = i.wait_type
											WHERE wait_time_ms > .1 * @CpuMsSinceWaitsCleared AND waiting_tasks_count > 0 
											AND i.wait_type IS NULL)
									BEGIN
									/* Check for waits that have had more than 10% of the server's wait time */
									WITH os(wait_type, waiting_tasks_count, wait_time_ms, max_wait_time_ms, signal_wait_time_ms)
									AS
									(SELECT ws.wait_type, waiting_tasks_count, wait_time_ms, max_wait_time_ms, signal_wait_time_ms
										FROM sys.dm_os_wait_stats ws
										LEFT OUTER JOIN #IgnorableWaits i ON ws.wait_type = i.wait_type
											WHERE i.wait_type IS NULL 
												AND wait_time_ms > .1 * @CpuMsSinceWaitsCleared
												AND waiting_tasks_count > 0)
									INSERT  INTO #BlitzResults
											( CheckID ,
											  Priority ,
											  FindingsGroup ,
											  Finding ,
											  URL ,
											  Details
											)
											SELECT TOP 9
													 152 AS CheckID
													,240 AS Priority
													,'Wait Stats' AS FindingsGroup
													, CAST(ROW_NUMBER() OVER(ORDER BY os.wait_time_ms DESC) AS NVARCHAR(10)) + N' - ' + os.wait_type AS Finding
													,'http://BrentOzar.com/go/waits' AS URL
													, Details = CAST(CAST(SUM(os.wait_time_ms / 1000.0 / 60 / 60) OVER (PARTITION BY os.wait_type) AS NUMERIC(18,1)) AS NVARCHAR(20)) + N' hours of waits, ' +
													CAST(CAST((SUM(60.0 * os.wait_time_ms) OVER (PARTITION BY os.wait_type) ) / @MsSinceWaitsCleared  AS NUMERIC(18,1)) AS NVARCHAR(20)) + N' minutes average wait time per hour, ' + 
													/* CAST(CAST(
														100.* SUM(os.wait_time_ms) OVER (PARTITION BY os.wait_type) 
														/ (1. * SUM(os.wait_time_ms) OVER () )
														AS NUMERIC(18,1)) AS NVARCHAR(40)) + N'% of waits, ' + */
													CAST(CAST(
														100. * SUM(os.signal_wait_time_ms) OVER (PARTITION BY os.wait_type) 
														/ (1. * SUM(os.wait_time_ms) OVER ())
														AS NUMERIC(18,1)) AS NVARCHAR(40)) + N'% signal wait, ' + 
													CAST(SUM(os.waiting_tasks_count) OVER (PARTITION BY os.wait_type) AS NVARCHAR(40)) + N' waiting tasks, ' +
													CAST(CASE WHEN  SUM(os.waiting_tasks_count) OVER (PARTITION BY os.wait_type) > 0
													THEN
														CAST(
															SUM(os.wait_time_ms) OVER (PARTITION BY os.wait_type)
																/ (1. * SUM(os.waiting_tasks_count) OVER (PARTITION BY os.wait_type)) 
															AS NUMERIC(18,1))
													ELSE 0 END AS NVARCHAR(40)) + N' ms average wait time.'
											FROM    os
											ORDER BY SUM(os.wait_time_ms / 1000.0 / 60 / 60) OVER (PARTITION BY os.wait_type) DESC;
									END /* IF EXISTS (SELECT * FROM sys.dm_os_wait_stats WHERE wait_time_ms > 0 AND waiting_tasks_count > 0) */

								/* If no waits were found, add a note about that */
								IF NOT EXISTS (SELECT * FROM #BlitzResults WHERE CheckID IN (107, 108, 109, 121, 152, 162))
								BEGIN
									INSERT  INTO #BlitzResults
											( CheckID ,
											  Priority ,
											  FindingsGroup ,
											  Finding ,
											  URL ,
											  Details
											)
										VALUES (153, 240, 'Wait Stats', 'No Significant Waits Detected', 'http://BrentOzar.com/go/waits', 'This server might be just sitting around idle, or someone may have cleared wait stats recently.');
								END
							END /* CheckID 152 */    

					END /* IF @CheckServerInfo = 1 */
			END /* IF ( ( SERVERPROPERTY('ServerName') NOT IN ( SELECT ServerName */


				/* Delete priorites they wanted to skip. */
				IF @IgnorePrioritiesAbove IS NOT NULL
					DELETE  #BlitzResults
					WHERE   [Priority] > @IgnorePrioritiesAbove AND CheckID <> -1;

				IF @IgnorePrioritiesBelow IS NOT NULL
					DELETE  #BlitzResults
					WHERE   [Priority] < @IgnorePrioritiesBelow AND CheckID <> -1;

				/* Delete checks they wanted to skip. */
				IF @SkipChecksTable IS NOT NULL
					BEGIN
						DELETE  FROM #BlitzResults
						WHERE   DatabaseName IN ( SELECT    DatabaseName
												  FROM      #SkipChecks
												  WHERE CheckID IS NULL
												  AND (ServerName IS NULL OR ServerName = SERVERPROPERTY('ServerName')));
						DELETE  FROM #BlitzResults
						WHERE   CheckID IN ( SELECT    CheckID
												  FROM      #SkipChecks
												  WHERE DatabaseName IS NULL
												  AND (ServerName IS NULL OR ServerName = SERVERPROPERTY('ServerName')));
						DELETE r FROM #BlitzResults r
							INNER JOIN #SkipChecks c ON r.DatabaseName = c.DatabaseName and r.CheckID = c.CheckID
												  AND (ServerName IS NULL OR ServerName = SERVERPROPERTY('ServerName'));
					END

				/* Add summary mode */
				IF @SummaryMode > 0
					BEGIN
					UPDATE #BlitzResults
					  SET Finding = br.Finding + ' (' + CAST(brTotals.recs AS NVARCHAR(20)) + ')'
					  FROM #BlitzResults br
						INNER JOIN (SELECT FindingsGroup, Finding, Priority, COUNT(*) AS recs FROM #BlitzResults GROUP BY FindingsGroup, Finding, Priority) brTotals ON br.FindingsGroup = brTotals.FindingsGroup AND br.Finding = brTotals.Finding AND br.Priority = brTotals.Priority
						WHERE brTotals.recs > 1;

					DELETE br
					  FROM #BlitzResults br
					  WHERE EXISTS (SELECT * FROM #BlitzResults brLower WHERE br.FindingsGroup = brLower.FindingsGroup AND br.Finding = brLower.Finding AND br.Priority = brLower.Priority AND br.ID > brLower.ID);

					END

				/* Add credits for the nice folks who put so much time into building and maintaining this for free: */
				INSERT  INTO #BlitzResults
						( CheckID ,
						  Priority ,
						  FindingsGroup ,
						  Finding ,
						  URL ,
						  Details
						)
				VALUES  ( -1 ,
						  255 ,
						  'Thanks!' ,
						  'From Your Community Volunteers' ,
						  'http://FirstResponderKit.org' ,
						  'We hope you found this tool useful.'
						);

				INSERT  INTO #BlitzResults
						( CheckID ,
						  Priority ,
						  FindingsGroup ,
						  Finding ,
						  URL ,
						  Details

						)
				VALUES  ( -1 ,
						  0 ,
						  'sp_Blitz ' + CAST(CONVERT(DATETIME, @VersionDate, 102) AS VARCHAR(100)),
						  'SQL Server First Responder Kit' ,
						  'http://FirstResponderKit.org/' ,
						  'To get help or add your own contributions, join us at http://FirstResponderKit.org.'

						);

				INSERT  INTO #BlitzResults
						( CheckID ,
						  Priority ,
						  FindingsGroup ,
						  Finding ,
						  URL ,
						  Details

						)
				SELECT 156 ,
						  254 ,
						  'Rundate' ,
						  GETDATE() ,
						  'http://FirstResponderKit.org/' ,
						  'Captain''s log: stardate something and something...';
						  
				IF @EmailRecipients IS NOT NULL
					BEGIN
					/* Database mail won't work off a local temp table. I'm not happy about this hacky workaround either. */
					IF (OBJECT_ID('tempdb..##BlitzResults', 'U') IS NOT NULL) DROP TABLE ##BlitzResults;
					SELECT * INTO ##BlitzResults FROM #BlitzResults;
					SET @query_result_separator = char(9);
					SET @StringToExecute = 'SET NOCOUNT ON;SELECT [Priority] , [FindingsGroup] , [Finding] , [DatabaseName] , [URL] ,  [Details] , CheckID FROM ##BlitzResults ORDER BY Priority , FindingsGroup, Finding, Details; SET NOCOUNT OFF;';
					SET @EmailSubject = 'sp_Blitz Results for ' + @@SERVERNAME;
					SET @EmailBody = 'sp_Blitz ' + CAST(CONVERT(DATETIME, @VersionDate, 102) AS VARCHAR(100)) + '. http://FirstResponderKit.org';
					IF @EmailProfile IS NULL
						EXEC msdb.dbo.sp_send_dbmail
							@recipients = @EmailRecipients,
							@subject = @EmailSubject,
							@body = @EmailBody,
							@query_attachment_filename = 'sp_Blitz-Results.csv',
							@attach_query_result_as_file = 1,
							@query_result_header = 1,
							@query_result_width = 32767,
							@append_query_error = 1,
							@query_result_no_padding = 1,
							@query_result_separator = @query_result_separator,
							@query = @StringToExecute;
					ELSE
						EXEC msdb.dbo.sp_send_dbmail
							@profile_name = @EmailProfile,
							@recipients = @EmailRecipients,
							@subject = @EmailSubject,
							@body = @EmailBody,
							@query_attachment_filename = 'sp_Blitz-Results.csv',
							@attach_query_result_as_file = 1,
							@query_result_header = 1,
							@query_result_width = 32767,
							@append_query_error = 1,
							@query_result_no_padding = 1,
							@query_result_separator = @query_result_separator,
							@query = @StringToExecute;
					IF (OBJECT_ID('tempdb..##BlitzResults', 'U') IS NOT NULL) DROP TABLE ##BlitzResults;
				END

				/* Checks if @OutputServerName is populated with a valid linked server, and that the database name specified is valid */
				DECLARE @ValidOutputServer BIT
				DECLARE @ValidOutputLocation BIT
				DECLARE @LinkedServerDBCheck NVARCHAR(2000)
				DECLARE @ValidLinkedServerDB INT
				DECLARE @tmpdbchk table (cnt int)
				IF @OutputServerName IS NOT NULL
					BEGIN
						IF EXISTS (SELECT server_id FROM sys.servers WHERE QUOTENAME([name]) = @OutputServerName)
							BEGIN
								SET @LinkedServerDBCheck = 'SELECT 1 WHERE EXISTS (SELECT * FROM '+@OutputServerName+'.master.sys.databases WHERE QUOTENAME([name]) = '''+@OutputDatabaseName+''')'
								INSERT INTO @tmpdbchk EXEC sys.sp_executesql @LinkedServerDBCheck
								SET @ValidLinkedServerDB = (SELECT COUNT(*) FROM @tmpdbchk)
								IF (@ValidLinkedServerDB > 0)
									BEGIN
										SET @ValidOutputServer = 1
										SET @ValidOutputLocation = 1
									END
								ELSE
									RAISERROR('The specified database was not found on the output server', 16, 0)
							END
						ELSE
							BEGIN
								RAISERROR('The specified output server was not found', 16, 0)
							END
					END
				ELSE
					BEGIN
						IF @OutputDatabaseName IS NOT NULL
							AND @OutputSchemaName IS NOT NULL
							AND @OutputTableName IS NOT NULL
							AND EXISTS ( SELECT *
								 FROM   sys.databases
								 WHERE  QUOTENAME([name]) = @OutputDatabaseName)
							BEGIN
								SET @ValidOutputLocation = 1
							END
						ELSE IF @OutputDatabaseName IS NOT NULL
							AND @OutputSchemaName IS NOT NULL
							AND @OutputTableName IS NOT NULL
							AND NOT EXISTS ( SELECT *
								 FROM   sys.databases
								 WHERE  QUOTENAME([name]) = @OutputDatabaseName)
							BEGIN
								RAISERROR('The specified output database was not found on this server', 16, 0)
							END
						ELSE
							BEGIN
								SET @ValidOutputLocation = 0 
							END
					END

				/* @OutputTableName lets us export the results to a permanent table */
				IF @ValidOutputLocation = 1
					BEGIN
						SET @StringToExecute = 'USE '
							+ @OutputDatabaseName
							+ '; IF EXISTS(SELECT * FROM '
							+ @OutputDatabaseName
							+ '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
							+ @OutputSchemaName
							+ ''') AND NOT EXISTS (SELECT * FROM '
							+ @OutputDatabaseName
							+ '.INFORMATION_SCHEMA.TABLES WHERE QUOTENAME(TABLE_SCHEMA) = '''
							+ @OutputSchemaName + ''' AND QUOTENAME(TABLE_NAME) = '''
							+ @OutputTableName + ''') CREATE TABLE '
							+ @OutputSchemaName + '.'
							+ @OutputTableName
							+ ' (ID INT IDENTITY(1,1) NOT NULL,
								ServerName NVARCHAR(128),
								CheckDate DATETIMEOFFSET,
								Priority TINYINT ,
								FindingsGroup VARCHAR(50) ,
								Finding VARCHAR(200) ,
								DatabaseName NVARCHAR(128),
								URL VARCHAR(200) ,
								Details NVARCHAR(4000) ,
								QueryPlan [XML] NULL ,
								QueryPlanFiltered [NVARCHAR](MAX) NULL,
								CheckID INT ,
								CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
						IF @ValidOutputServer = 1
							BEGIN
								SET @StringToExecute = REPLACE(@StringToExecute,''''+@OutputSchemaName+'''',''''''+@OutputSchemaName+'''''')
								SET @StringToExecute = REPLACE(@StringToExecute,''''+@OutputTableName+'''',''''''+@OutputTableName+'''''')
								SET @StringToExecute = REPLACE(@StringToExecute,'[XML]','[NVARCHAR](MAX)')
								EXEC('EXEC('''+@StringToExecute+''') AT ' + @OutputServerName);
							END   
						ELSE
							BEGIN
								EXEC(@StringToExecute);
							END
						IF @ValidOutputServer = 1
							BEGIN
								SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
								+ @OutputServerName + '.'
								+ @OutputDatabaseName
								+ '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
								+ @OutputSchemaName + ''') INSERT '
								+ @OutputServerName + '.'
								+ @OutputDatabaseName + '.'
								+ @OutputSchemaName + '.'
								+ @OutputTableName
								+ ' (ServerName, CheckDate, CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details, QueryPlan, QueryPlanFiltered) SELECT '''
								+ CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
								+ ''', SYSDATETIMEOFFSET(), CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details, CAST(QueryPlan AS NVARCHAR(MAX)), QueryPlanFiltered FROM #BlitzResults ORDER BY Priority , FindingsGroup , Finding , Details';

								EXEC(@StringToExecute);
							END   
						ELSE
							BEGIN
								SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
								+ @OutputDatabaseName
								+ '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
								+ @OutputSchemaName + ''') INSERT '
								+ @OutputDatabaseName + '.'
								+ @OutputSchemaName + '.'
								+ @OutputTableName
								+ ' (ServerName, CheckDate, CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details, QueryPlan, QueryPlanFiltered) SELECT '''
								+ CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
								+ ''', SYSDATETIMEOFFSET(), CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details, QueryPlan, QueryPlanFiltered FROM #BlitzResults ORDER BY Priority , FindingsGroup , Finding , Details';
								
								EXEC(@StringToExecute);
							END
					END
				ELSE IF (SUBSTRING(@OutputTableName, 2, 2) = '##')
					BEGIN
						IF @ValidOutputServer = 1
							BEGIN
								RAISERROR('Due to the nature of temporary tables, outputting to a linked server requires a permanent table.', 16, 0)
							END
						ELSE
							BEGIN
								SET @StringToExecute = N' IF (OBJECT_ID(''tempdb..'
									+ @OutputTableName
									+ ''') IS NOT NULL) DROP TABLE ' + @OutputTableName + ';'
									+ 'CREATE TABLE '
									+ @OutputTableName
									+ ' (ID INT IDENTITY(1,1) NOT NULL,
										ServerName NVARCHAR(128),
										CheckDate DATETIMEOFFSET,
										Priority TINYINT ,
										FindingsGroup VARCHAR(50) ,
										Finding VARCHAR(200) ,
										DatabaseName NVARCHAR(128),
										URL VARCHAR(200) ,
										Details NVARCHAR(4000) ,
										QueryPlan [XML] NULL ,
										QueryPlanFiltered [NVARCHAR](MAX) NULL,
										CheckID INT ,
										CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
									+ ' INSERT '
									+ @OutputTableName
									+ ' (ServerName, CheckDate, CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details, QueryPlan, QueryPlanFiltered) SELECT '''
									+ CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
									+ ''', SYSDATETIMEOFFSET(), CheckID, DatabaseName, Priority, FindingsGroup, Finding, URL, Details, QueryPlan, QueryPlanFiltered FROM #BlitzResults ORDER BY Priority , FindingsGroup , Finding , Details';
							
									EXEC(@StringToExecute);
							END
					END
				ELSE IF (SUBSTRING(@OutputTableName, 2, 1) = '#')
					BEGIN
						RAISERROR('Due to the nature of Dymamic SQL, only global (i.e. double pound (##)) temp tables are supported for @OutputTableName', 16, 0)
					END


				DECLARE @separator AS VARCHAR(1);
				IF @OutputType = 'RSV'
					SET @separator = CHAR(31);
				ELSE
					SET @separator = ',';

				IF @OutputType = 'COUNT'
					BEGIN
						SELECT  COUNT(*) AS Warnings
						FROM    #BlitzResults
					END
				ELSE
					IF @OutputType IN ( 'CSV', 'RSV' )
						BEGIN

							SELECT  Result = CAST([Priority] AS NVARCHAR(100))
									+ @separator + CAST(CheckID AS NVARCHAR(100))
									+ @separator + COALESCE([FindingsGroup],
															'(N/A)') + @separator
									+ COALESCE([Finding], '(N/A)') + @separator
									+ COALESCE(DatabaseName, '(N/A)') + @separator
									+ COALESCE([URL], '(N/A)') + @separator
									+ COALESCE([Details], '(N/A)')
							FROM    #BlitzResults
							ORDER BY Priority ,
									FindingsGroup ,
									Finding ,
									DatabaseName ,
									Details;
						END
					ELSE IF @OutputXMLasNVARCHAR = 1 AND @OutputType <> 'NONE'
						BEGIN
							SELECT  [Priority] ,
									[FindingsGroup] ,
									[Finding] ,
									[DatabaseName] ,
									[URL] ,
									[Details] ,
									CAST([QueryPlan] AS NVARCHAR(MAX)) AS QueryPlan,
									[QueryPlanFiltered] ,
									CheckID
							FROM    #BlitzResults
							ORDER BY Priority ,
									FindingsGroup ,
									Finding ,
									DatabaseName ,
									Details;
						END
					ELSE IF @OutputType = 'MARKDOWN'
						BEGIN
							WITH Results AS (SELECT row_number() OVER (ORDER BY Priority, FindingsGroup, Finding, DatabaseName, Details) AS rownum, * 
												FROM #BlitzResults
												WHERE Priority > 0 AND Priority < 255 AND FindingsGroup IS NOT NULL AND Finding IS NOT NULL
												AND FindingsGroup <> 'Security' /* Specifically excluding security checks for public exports */)
							SELECT 
								CASE 
									WHEN r.Priority <> COALESCE(rPrior.Priority, 0) OR r.FindingsGroup <> rPrior.FindingsGroup  THEN @crlf + N'**Priority ' + CAST(COALESCE(r.Priority,N'') AS NVARCHAR(5)) + N': ' + COALESCE(r.FindingsGroup,N'') + N'**:' + @crlf + @crlf 
									ELSE N'' 
								END
								+ CASE WHEN r.Finding <> COALESCE(rPrior.Finding,N'') AND r.Finding <> rNext.Finding THEN N'- ' + COALESCE(r.Finding,N'') + N' ' + COALESCE(r.DatabaseName, N'') + N' - ' + COALESCE(r.Details,N'') + @crlf
									   WHEN r.Finding <> COALESCE(rPrior.Finding,N'') AND r.Finding = rNext.Finding AND r.Details = rNext.Details THEN N'- ' + COALESCE(r.Finding,N'') + N' - ' + COALESCE(r.Details,N'') + @crlf + @crlf + N'    * ' + COALESCE(r.DatabaseName, N'') + @crlf
									   WHEN r.Finding <> COALESCE(rPrior.Finding,N'') AND r.Finding = rNext.Finding THEN N'- ' + COALESCE(r.Finding,N'') + @crlf + CASE WHEN r.DatabaseName IS NULL THEN N'' ELSE  N'    * ' + COALESCE(r.DatabaseName,N'') END + CASE WHEN r.Details <> rPrior.Details THEN N' - ' + COALESCE(r.Details,N'') + @crlf ELSE '' END
									   ELSE CASE WHEN r.DatabaseName IS NULL THEN N'' ELSE  N'    * ' + COALESCE(r.DatabaseName,N'') END + CASE WHEN r.Details <> rPrior.Details THEN N' - ' + COALESCE(r.Details,N'') + @crlf ELSE N'' + @crlf END 
								END + @crlf 
							  FROM Results r
							  LEFT OUTER JOIN Results rPrior ON r.rownum = rPrior.rownum + 1
							  LEFT OUTER JOIN Results rNext ON r.rownum = rNext.rownum - 1
							ORDER BY r.rownum FOR XML PATH(N'');
						END
					ELSE IF @OutputType <> 'NONE'
						BEGIN
							SELECT  [Priority] ,
									[FindingsGroup] ,
									[Finding] ,
									[DatabaseName] ,
									[URL] ,
									[Details] ,
									[QueryPlan] ,
									[QueryPlanFiltered] ,
									CheckID
							FROM    #BlitzResults
							ORDER BY Priority ,
									FindingsGroup ,
									Finding ,
									DatabaseName ,
									Details;
						END

				DROP TABLE #BlitzResults;

				IF @OutputProcedureCache = 1
				AND @CheckProcedureCache = 1
					SELECT TOP 20
							total_worker_time / execution_count AS AvgCPU ,
							total_worker_time AS TotalCPU ,
							CAST(ROUND(100.00 * total_worker_time
									   / ( SELECT   SUM(total_worker_time)
										   FROM     sys.dm_exec_query_stats
										 ), 2) AS MONEY) AS PercentCPU ,
							total_elapsed_time / execution_count AS AvgDuration ,
							total_elapsed_time AS TotalDuration ,
							CAST(ROUND(100.00 * total_elapsed_time
									   / ( SELECT   SUM(total_elapsed_time)
										   FROM     sys.dm_exec_query_stats
										 ), 2) AS MONEY) AS PercentDuration ,
							total_logical_reads / execution_count AS AvgReads ,
							total_logical_reads AS TotalReads ,
							CAST(ROUND(100.00 * total_logical_reads
									   / ( SELECT   SUM(total_logical_reads)
										   FROM     sys.dm_exec_query_stats
										 ), 2) AS MONEY) AS PercentReads ,
							execution_count ,
							CAST(ROUND(100.00 * execution_count
									   / ( SELECT   SUM(execution_count)
										   FROM     sys.dm_exec_query_stats
										 ), 2) AS MONEY) AS PercentExecutions ,
							CASE WHEN DATEDIFF(mi, creation_time,
											   qs.last_execution_time) = 0 THEN 0
								 ELSE CAST(( 1.00 * execution_count / DATEDIFF(mi,
																  creation_time,
																  qs.last_execution_time) ) AS MONEY)
							END AS executions_per_minute ,
							qs.creation_time AS plan_creation_time ,
							qs.last_execution_time ,
							text ,
							text_filtered ,
							query_plan ,
							query_plan_filtered ,
							sql_handle ,
							query_hash ,
							plan_handle ,
							query_plan_hash
					FROM    #dm_exec_query_stats qs
					ORDER BY CASE UPPER(@CheckProcedureCacheFilter)
							   WHEN 'CPU' THEN total_worker_time
							   WHEN 'READS' THEN total_logical_reads
							   WHEN 'EXECCOUNT' THEN execution_count
							   WHEN 'DURATION' THEN total_elapsed_time
							   ELSE total_worker_time
							 END DESC

	END /* ELSE -- IF @OutputType = 'SCHEMA' */

    SET NOCOUNT OFF;
GO

/*
--Sample execution call with the most common parameters:
EXEC [dbo].[sp_Blitz]
    @CheckUserDatabaseObjects = 1 ,
    @CheckProcedureCache = 0 ,
    @OutputType = 'TABLE' ,
    @OutputProcedureCache = 0 ,
    @CheckProcedureCacheFilter = NULL,
    @CheckServerInfo = 1
*/



USE tempdb
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

IF (
SELECT
  CASE 
     WHEN CONVERT(NVARCHAR(128), SERVERPROPERTY ('PRODUCTVERSION')) like '8%' THEN 0
     WHEN CONVERT(NVARCHAR(128), SERVERPROPERTY ('PRODUCTVERSION')) like '9%' THEN 0
	 ELSE 1
  END 
) = 0
BEGIN
	DECLARE @msg VARCHAR(8000) 
	SELECT @msg = 'Sorry, sp_BlitzCache doesn''t work on versions of SQL prior to 2008.' + REPLICATE(CHAR(13), 7933)
	PRINT @msg
	RETURN
END

IF OBJECT_ID('dbo.sp_BlitzCache') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_BlitzCache AS RETURN 0;')
GO

IF OBJECT_ID('dbo.sp_BlitzCache') IS NOT NULL AND OBJECT_ID('tempdb.dbo.##bou_BlitzCacheProcs', 'U') IS NOT NULL
    EXEC ('DROP TABLE ##bou_BlitzCacheProcs;')
GO

IF OBJECT_ID('dbo.sp_BlitzCache') IS NOT NULL AND OBJECT_ID('tempdb.dbo.##bou_BlitzCacheResults', 'U') IS NOT NULL
    EXEC ('DROP TABLE ##bou_BlitzCacheResults;')
GO

CREATE TABLE ##bou_BlitzCacheResults (
    SPID INT,
    ID INT IDENTITY(1,1),
    CheckID INT,
    Priority TINYINT,
    FindingsGroup VARCHAR(50),
    Finding VARCHAR(200),
    URL VARCHAR(200),
    Details VARCHAR(4000) 
);

CREATE TABLE ##bou_BlitzCacheProcs (
        SPID INT ,
        QueryType NVARCHAR(256),
        DatabaseName sysname,
        AverageCPU DECIMAL(38,4),
        AverageCPUPerMinute DECIMAL(38,4),
        TotalCPU DECIMAL(38,4),
        PercentCPUByType MONEY,
        PercentCPU MONEY,
        AverageDuration DECIMAL(38,4),
        TotalDuration DECIMAL(38,4),
        PercentDuration MONEY,
        PercentDurationByType MONEY,
        AverageReads BIGINT,
        TotalReads BIGINT,
        PercentReads MONEY,
        PercentReadsByType MONEY,
        ExecutionCount BIGINT,
        PercentExecutions MONEY,
        PercentExecutionsByType MONEY,
        ExecutionsPerMinute MONEY,
        TotalWrites BIGINT,
        AverageWrites MONEY,
        PercentWrites MONEY,
        PercentWritesByType MONEY,
        WritesPerMinute MONEY,
        PlanCreationTime DATETIME,
		PlanCreationTimeHours AS DATEDIFF(HOUR, PlanCreationTime, SYSDATETIME()),
        LastExecutionTime DATETIME,
        PlanHandle VARBINARY(64),
		[Remove Plan Handle From Cache] AS 
			CASE WHEN [PlanHandle] IS NOT NULL 
			THEN 'DBCC FREEPROCCACHE (' + CONVERT(VARCHAR(128), [PlanHandle], 1) + ');'
			ELSE 'N/A' END,
		SqlHandle VARBINARY(64),
			[Remove SQL Handle From Cache] AS 
			CASE WHEN [SqlHandle] IS NOT NULL 
			THEN 'DBCC FREEPROCCACHE (' + CONVERT(VARCHAR(128), [SqlHandle], 1) + ');'
			ELSE 'N/A' END,
		[SQL Handle More Info] AS 
			CASE WHEN [SqlHandle] IS NOT NULL 
			THEN 'EXEC sp_BlitzCache @OnlySqlHandles = ''' + CONVERT(VARCHAR(128), [SqlHandle], 1) + '''; '
			ELSE 'N/A' END,
		QueryHash BINARY(8),
		[Query Hash More Info] AS 
			CASE WHEN [QueryHash] IS NOT NULL 
			THEN 'EXEC sp_BlitzCache @OnlyQueryHashes = ''' + CONVERT(VARCHAR(32), [QueryHash], 1) + '''; '
			ELSE 'N/A' END,
        QueryPlanHash BINARY(8),
        StatementStartOffset INT,
        StatementEndOffset INT,
        MinReturnedRows BIGINT,
        MaxReturnedRows BIGINT,
        AverageReturnedRows MONEY,
        TotalReturnedRows BIGINT,
        LastReturnedRows BIGINT,
		/*The Memory Grant columns are only supported 
		  in certain versions, giggle giggle.
		*/
		MinGrantKB BIGINT,
		MaxGrantKB BIGINT,
		MinUsedGrantKB BIGINT, 
		MaxUsedGrantKB BIGINT,
		PercentMemoryGrantUsed MONEY,
		AvgMaxMemoryGrant MONEY,
        QueryText NVARCHAR(MAX),
        QueryPlan XML,
        /* these next four columns are the total for the type of query.
            don't actually use them for anything apart from math by type.
            */
        TotalWorkerTimeForType BIGINT,
        TotalElapsedTimeForType BIGINT,
        TotalReadsForType BIGINT,
        TotalExecutionCountForType BIGINT,
        TotalWritesForType BIGINT,
        NumberOfPlans INT,
        NumberOfDistinctPlans INT,
        SerialDesiredMemory FLOAT,
        SerialRequiredMemory FLOAT,
        CachedPlanSize FLOAT,
        CompileTime FLOAT,
        CompileCPU FLOAT ,
        CompileMemory FLOAT ,
        min_worker_time BIGINT,
        max_worker_time BIGINT,
        is_forced_plan BIT,
        is_forced_parameterized BIT,
        is_cursor BIT,
		is_optimistic_cursor BIT,
		is_forward_only_cursor BIT,
        is_parallel BIT,
		is_forced_serial BIT,
		is_key_lookup_expensive BIT,
		key_lookup_cost FLOAT,
		is_remote_query_expensive BIT,
		remote_query_cost FLOAT,
        frequent_execution BIT,
        parameter_sniffing BIT,
        unparameterized_query BIT,
        near_parallel BIT,
        plan_warnings BIT,
        plan_multiple_plans BIT,
        long_running BIT,
        downlevel_estimator BIT,
        implicit_conversions BIT,
        busy_loops BIT,
        tvf_join BIT,
        tvf_estimate BIT,
        compile_timeout BIT,
        compile_memory_limit_exceeded BIT,
        warning_no_join_predicate BIT,
        QueryPlanCost FLOAT,
        missing_index_count INT,
        unmatched_index_count INT,
        min_elapsed_time BIGINT,
        max_elapsed_time BIGINT,
        age_minutes MONEY,
        age_minutes_lifetime MONEY,
        is_trivial BIT,
		trace_flags_session VARCHAR(1000),
		is_unused_grant BIT,
		function_count INT,
		clr_function_count INT,
		is_table_variable BIT,
		no_stats_warning BIT,
		relop_warnings BIT,
		is_table_scan BIT,
	    backwards_scan BIT,
	    forced_index BIT,
	    forced_seek BIT,
	    forced_scan BIT,
		columnstore_row_mode BIT,
		is_computed_scalar BIT ,
		is_sort_expensive bit,
		sort_cost float,
        SetOptions VARCHAR(MAX),
        Warnings VARCHAR(MAX)
    );
GO 

ALTER PROCEDURE dbo.sp_BlitzCache
    @Help BIT = 0,
    @Top INT = 10,
    @SortOrder VARCHAR(50) = 'CPU',
    @UseTriggersAnyway BIT = NULL,
    @ExportToExcel BIT = 0,
    @ExpertMode TINYINT = 0,
    @OutputServerName NVARCHAR(256) = NULL ,
    @OutputDatabaseName NVARCHAR(256) = NULL ,
    @OutputSchemaName NVARCHAR(256) = NULL ,
    @OutputTableName NVARCHAR(256) = NULL ,
    @ConfigurationDatabaseName NVARCHAR(128) = NULL ,
    @ConfigurationSchemaName NVARCHAR(256) = NULL ,
    @ConfigurationTableName NVARCHAR(256) = NULL ,
    @DurationFilter DECIMAL(38,4) = NULL ,
    @HideSummary BIT = 0 ,
    @IgnoreSystemDBs BIT = 1 ,
    @OnlyQueryHashes VARCHAR(MAX) = NULL ,
    @IgnoreQueryHashes VARCHAR(MAX) = NULL ,
    @OnlySqlHandles VARCHAR(MAX) = NULL ,
    @QueryFilter VARCHAR(10) = 'ALL' ,
    @DatabaseName NVARCHAR(128) = NULL ,
   @StoredProcName NVARCHAR(128) = NULL,
    @Reanalyze BIT = 0 ,
    @SkipAnalysis BIT = 0 ,
    @BringThePain BIT = 0 /* This will forcibly set @Top to 2,147,483,647 */
WITH RECOMPILE
AS
BEGIN
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @Version VARCHAR(30);
DECLARE @VersionDate VARCHAR(30);
 SET @Version = '4.1';
 SET @VersionDate = '20161210';

IF @Help = 1 PRINT '
sp_BlitzCache from http://FirstResponderKit.org
	
This script displays your most resource-intensive queries from the plan cache,
and points to ways you can tune these queries to make them faster.


To learn more, visit http://FirstResponderKit.org where you can download new
versions for free, watch training videos on how it works, get more info on
the findings, contribute your own code, and more.

Known limitations of this version:
 - This query will not run on SQL Server 2005.
 - SQL Server 2008 and 2008R2 have a bug in trigger stats, so that output is
   excluded by default.
 - @IgnoreQueryHashes and @OnlyQueryHashes require a CSV list of hashes
   with no spaces between the hash values.
 - @OutputServerName is not functional yet.

Unknown limitations of this version:
 - May or may not be vulnerable to the wick effect.

Changes - for the full list of improvements and fixes in this version, see:
https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/



MIT License

Copyright (c) 2016 Brent Ozar Unlimited

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'

DECLARE @nl NVARCHAR(2) = NCHAR(13) + NCHAR(10) ;

IF @Help = 1
BEGIN
    SELECT N'@Help' AS [Parameter Name] ,
           N'BIT' AS [Data Type] ,
           N'Displays this help message.' AS [Parameter Description]

    UNION ALL
    SELECT N'@Top',
           N'INT',
           N'The number of records to retrieve and analyze from the plan cache. The following DMVs are used as the plan cache: dm_exec_query_stats, dm_exec_procedure_stats, dm_exec_trigger_stats.'

    UNION ALL
    SELECT N'@SortOrder',
           N'VARCHAR(10)',
           N'Data processing and display order. @SortOrder will still be used, even when preparing output for a table or for excel. Possible values are: "CPU", "Reads", "Writes", "Duration", "Executions", "Recent Compilations", "Memory Grant". Additionally, the word "Average" or "Avg" can be used to sort on averages rather than total. "Executions per minute" and "Executions / minute" can be used to sort by execution per minute. For the truly lazy, "xpm" can also be used.'

    UNION ALL
    SELECT N'@UseTriggersAnyway',
           N'BIT',
           N'On SQL Server 2008R2 and earlier, trigger execution count is incorrect - trigger execution count is incremented once per execution of a SQL agent job. If you still want to see relative execution count of triggers, then you can force sp_BlitzCache to include this information.'

    UNION ALL
    SELECT N'@ExportToExcel',
           N'BIT',
           N'Prepare output for exporting to Excel. Newlines and additional whitespace are removed from query text and the execution plan is not displayed.'

    UNION ALL
    SELECT N'@ExpertMode',
           N'TINYINT',
           N'Default 0. When set to 1, results include more columns. When 2, mode is optimized for Opserver, the open source dashboard.'

    UNION ALL
    SELECT N'@OutputDatabaseName',
           N'NVARCHAR(128)',
           N'The output database. If this does not exist SQL Server will divide by zero and everything will fall apart.'

    UNION ALL
    SELECT N'@OutputSchemaName',
           N'NVARCHAR(256)',
           N'The output schema. If this does not exist SQL Server will divide by zero and everything will fall apart.'

    UNION ALL
    SELECT N'@OutputTableName',
           N'NVARCHAR(256)',
           N'The output table. If this does not exist, it will be created for you.'

    UNION ALL
    SELECT N'@DurationFilter',
           N'DECIMAL(38,4)',
           N'Excludes queries with an average duration (in seconds) less than @DurationFilter.'

    UNION ALL
    SELECT N'@HideSummary',
           N'BIT',
           N'Hides the findings summary result set.'

    UNION ALL
    SELECT N'@IgnoreSystemDBs',
           N'BIT',
           N'Ignores plans found in the system databases (master, model, msdb, tempdb, and resourcedb)'

    UNION ALL
    SELECT N'@OnlyQueryHashes',
           N'VARCHAR(MAX)',
           N'A list of query hashes to query. All other query hashes will be ignored. Stored procedures and triggers will be ignored.'

    UNION ALL
    SELECT N'@IgnoreQueryHashes',
           N'VARCHAR(MAX)',
           N'A list of query hashes to ignore.'
    
    UNION ALL
    SELECT N'@OnlySqlHandles',
           N'VARCHAR(MAX)',
           N'One or more sql_handles to use for filtering results.'

    UNION ALL
    SELECT N'@DatabaseName',
           N'NVARCHAR(128)',
           N'A database name which is used for filtering results.'

    UNION ALL
    SELECT N'@BringThePain',
           N'BIT',
           N'This forces sp_BlitzCache to examine the entire plan cache. Be careful running this on servers with a lot of memory or a large execution plan cache.'

    UNION ALL
    SELECT N'@QueryFilter',
           N'VARCHAR(10)',
           N'Filter out stored procedures or statements. The default value is ''ALL''. Allowed values are ''procedures'', ''statements'', or ''all'' (any variation in capitalization is acceptable).'

    UNION ALL
    SELECT N'@Reanalyze',
           N'BIT',
           N'The default is 0. When set to 0, sp_BlitzCache will re-evalute the plan cache. Set this to 1 to reanalyze existing results';
           


    /* Column definitions */
    SELECT N'# Executions' AS [Column Name],
           N'BIGINT' AS [Data Type],
           N'The number of executions of this particular query. This is computed across statements, procedures, and triggers and aggregated by the SQL handle.' AS [Column Description]

    UNION ALL
    SELECT N'Executions / Minute',
           N'MONEY',
           N'Number of executions per minute - calculated for the life of the current plan. Plan life is the last execution time minus the plan creation time.'

    UNION ALL
    SELECT N'Execution Weight',
           N'MONEY',
           N'An arbitrary metric of total "execution-ness". A weight of 2 is "one more" than a weight of 1.'

    UNION ALL
    SELECT N'Database',
           N'sysname',
           N'The name of the database where the plan was encountered. If the database name cannot be determined for some reason, a value of NA will be substituted. A value of 32767 indicates the plan comes from ResourceDB.'

    UNION ALL
    SELECT N'Total CPU',
           N'BIGINT',
           N'Total CPU time, reported in milliseconds, that was consumed by all executions of this query since the last compilation.'

    UNION ALL
    SELECT N'Avg CPU',
           N'BIGINT',
           N'Average CPU time, reported in milliseconds, consumed by each execution of this query since the last compilation.'

    UNION ALL
    SELECT N'CPU Weight',
           N'MONEY',
           N'An arbitrary metric of total "CPU-ness". A weight of 2 is "one more" than a weight of 1.'


    UNION ALL
    SELECT N'Total Duration',
           N'BIGINT',
           N'Total elapsed time, reported in milliseconds, consumed by all executions of this query since last compilation.'

    UNION ALL
    SELECT N'Avg Duration',
           N'BIGINT',
           N'Average elapsed time, reported in milliseconds, consumed by each execution of this query since the last compilation.'

    UNION ALL
    SELECT N'Duration Weight',
           N'MONEY',
           N'An arbitrary metric of total "Duration-ness". A weight of 2 is "one more" than a weight of 1.'

    UNION ALL
    SELECT N'Total Reads',
           N'BIGINT',
           N'Total logical reads performed by this query since last compilation.'

    UNION ALL
    SELECT N'Average Reads',
           N'BIGINT',
           N'Average logical reads performed by each execution of this query since the last compilation.'

    UNION ALL
    SELECT N'Read Weight',
           N'MONEY',
           N'An arbitrary metric of "Read-ness". A weight of 2 is "one more" than a weight of 1.'

    UNION ALL
    SELECT N'Total Writes',
           N'BIGINT',
           N'Total logical writes performed by this query since last compilation.'

    UNION ALL
    SELECT N'Average Writes',
           N'BIGINT',
           N'Average logical writes performed by each execution this query since last compilation.'

    UNION ALL
    SELECT N'Write Weight',
           N'MONEY',
           N'An arbitrary metric of "Write-ness". A weight of 2 is "one more" than a weight of 1.'

    UNION ALL
    SELECT N'Query Type',
           N'NVARCHAR(256)',
           N'The type of query being examined. This can be "Procedure", "Statement", or "Trigger".'

    UNION ALL
    SELECT N'Query Text',
           N'NVARCHAR(4000)',
           N'The text of the query. This may be truncated by either SQL Server or by sp_BlitzCache(tm) for display purposes.'

    UNION ALL
    SELECT N'% Executions (Type)',
           N'MONEY',
           N'Percent of executions relative to the type of query - e.g. 17.2% of all stored procedure executions.'

    UNION ALL
    SELECT N'% CPU (Type)',
           N'MONEY',
           N'Percent of CPU time consumed by this query for a given type of query - e.g. 22% of CPU of all stored procedures executed.'

    UNION ALL
    SELECT N'% Duration (Type)',
           N'MONEY',
           N'Percent of elapsed time consumed by this query for a given type of query - e.g. 12% of all statements executed.'

    UNION ALL
    SELECT N'% Reads (Type)',
           N'MONEY',
           N'Percent of reads consumed by this query for a given type of query - e.g. 34.2% of all stored procedures executed.'

    UNION ALL
    SELECT N'% Writes (Type)',
           N'MONEY',
           N'Percent of writes performed by this query for a given type of query - e.g. 43.2% of all statements executed.'

    UNION ALL
    SELECT N'Total Rows',
           N'BIGINT',
           N'Total number of rows returned for all executions of this query. This only applies to query level stats, not stored procedures or triggers.'

    UNION ALL
    SELECT N'Average Rows',
           N'MONEY',
           N'Average number of rows returned by each execution of the query.'

    UNION ALL
    SELECT N'Min Rows',
           N'BIGINT',
           N'The minimum number of rows returned by any execution of this query.'

    UNION ALL
    SELECT N'Max Rows',
           N'BIGINT',
           N'The maximum number of rows returned by any execution of this query.'

    UNION ALL
    SELECT N'MinGrantKB',
           N'BIGINT',
           N'The minim memory grant the query received in kb.'

    UNION ALL
    SELECT N'MaxGrantKB',
           N'BIGINT',
           N'The maximum memory grant the query received in kb.'

    UNION ALL
    SELECT N'MinUsedGrantKB',
           N'BIGINT',
           N'The minim used memory grant the query received in kb.'

    UNION ALL
    SELECT N'MaxUsedGrantKB',
           N'BIGINT',
           N'The maximum used memory grant the query received in kb.'

    UNION ALL
    SELECT N'PercentMemoryGrantUsed',
           N'MONEY',
           N'Result of dividing the maximum grant used by the minimum granted.'

    UNION ALL
    SELECT N'AvgMaxMemoryGrant',
           N'MONEY',
           N'The average maximum memory grant for a query.'

    UNION ALL
    SELECT N'# Plans',
           N'INT',
           N'The total number of execution plans found that match a given query.'

    UNION ALL
    SELECT N'# Distinct Plans',
           N'INT',
           N'The number of distinct execution plans that match a given query. '
            + NCHAR(13) + NCHAR(10)
            + N'This may be caused by running the same query across multiple databases or because of a lack of proper parameterization in the database.'

    UNION ALL
    SELECT N'Created At',
           N'DATETIME',
           N'Time that the execution plan was last compiled.'

    UNION ALL
    SELECT N'Last Execution',
           N'DATETIME',
           N'The last time that this query was executed.'

    UNION ALL
    SELECT N'Query Plan',
           N'XML',
           N'The query plan. Click to display a graphical plan or, if you need to patch SSMS, a pile of XML.'

    UNION ALL
    SELECT N'Plan Handle',
           N'VARBINARY(64)',
           N'An arbitrary identifier referring to the compiled plan this query is a part of.'

    UNION ALL
    SELECT N'SQL Handle',
           N'VARBINARY(64)',
           N'An arbitrary identifier referring to a batch or stored procedure that this query is a part of.'

    UNION ALL
    SELECT N'Query Hash',
           N'BINARY(8)',
           N'A hash of the query. Queries with the same query hash have similar logic but only differ by literal values or database.'

    UNION ALL
    SELECT N'Warnings',
           N'VARCHAR(MAX)',
           N'A list of individual warnings generated by this query.' ;


           
    /* Configuration table description */
    SELECT N'Frequent Execution Threshold' AS [Configuration Parameter] ,
           N'100' AS [Default Value] ,
           N'Executions / Minute' AS [Unit of Measure] ,
           N'Executions / Minute before a "Frequent Execution Threshold" warning is triggered.' AS [Description]

    UNION ALL
    SELECT N'Parameter Sniffing Variance Percent' ,
           N'30' ,
           N'Percent' ,
           N'Variance required between min/max values and average values before a "Parameter Sniffing" warning is triggered. Applies to worker time and returned rows.'

    UNION ALL
    SELECT N'Parameter Sniffing IO Threshold' ,
           N'100,000' ,
           N'Logical reads' ,
           N'Minimum number of average logical reads before parameter sniffing checks are evaluated.'

    UNION ALL
    SELECT N'Cost Threshold for Parallelism Warning' AS [Configuration Parameter] ,
           N'10' ,
           N'Percent' ,
           N'Trigger a "Nearly Parallel" warning when a query''s cost is within X percent of the cost threshold for parallelism.'

    UNION ALL
    SELECT N'Long Running Query Warning' AS [Configuration Parameter] ,
           N'300' ,
           N'Seconds' ,
           N'Triggers a "Long Running Query Warning" when average duration, max CPU time, or max clock time is higher than this number.'

    UNION ALL
    SELECT N'Unused Memory Grant Warning' AS [Configuration Parameter] ,
           N'10' ,
           N'Percent' ,
           N'Triggers an "Unused Memory Grant Warning" when a query uses >= X percent of its memory grant.'
    RETURN
END

/*Validate version*/
IF (
SELECT
  CASE 
     WHEN CONVERT(NVARCHAR(128), SERVERPROPERTY ('PRODUCTVERSION')) like '8%' THEN 0
     WHEN CONVERT(NVARCHAR(128), SERVERPROPERTY ('PRODUCTVERSION')) like '9%' THEN 0
	 ELSE 1
  END 
) = 0
BEGIN
	DECLARE @version_msg VARCHAR(8000) 
	SELECT @version_msg = 'Sorry, sp_BlitzCache doesn''t work on versions of SQL prior to 2008.' + REPLICATE(CHAR(13), 7933);
	PRINT @version_msg;
	RETURN;
END

/* validate user inputs */
IF @Top IS NULL 
    OR @SortOrder IS NULL 
    OR @QueryFilter IS NULL 
    OR @Reanalyze IS NULL
BEGIN
    RAISERROR(N'Several parameters (@Top, @SortOrder, @QueryFilter, @renalyze) are required. Do not set them to NULL. Please try again.', 16, 1) WITH NOWAIT;
    RETURN;
END

RAISERROR(N'Creating temp tables for results and warnings.', 0, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb.dbo.##bou_BlitzCacheResults') IS NULL
BEGIN
    CREATE TABLE ##bou_BlitzCacheResults (
        SPID INT,
        ID INT IDENTITY(1,1),
        CheckID INT,
        Priority TINYINT,
        FindingsGroup VARCHAR(50),
        Finding VARCHAR(200),
        URL VARCHAR(200),
        Details VARCHAR(4000)
    );
END

IF OBJECT_ID('tempdb.dbo.##bou_BlitzCacheProcs') IS NULL
BEGIN
    CREATE TABLE ##bou_BlitzCacheProcs (
        SPID INT ,
        QueryType NVARCHAR(256),
        DatabaseName sysname,
        AverageCPU DECIMAL(38,4),
        AverageCPUPerMinute DECIMAL(38,4),
        TotalCPU DECIMAL(38,4),
        PercentCPUByType MONEY,
        PercentCPU MONEY,
        AverageDuration DECIMAL(38,4),
        TotalDuration DECIMAL(38,4),
        PercentDuration MONEY,
        PercentDurationByType MONEY,
        AverageReads BIGINT,
        TotalReads BIGINT,
        PercentReads MONEY,
        PercentReadsByType MONEY,
        ExecutionCount BIGINT,
        PercentExecutions MONEY,
        PercentExecutionsByType MONEY,
        ExecutionsPerMinute MONEY,
        TotalWrites BIGINT,
        AverageWrites MONEY,
        PercentWrites MONEY,
        PercentWritesByType MONEY,
        WritesPerMinute MONEY,
        PlanCreationTime DATETIME,
		PlanCreationTimeHours AS DATEDIFF(HOUR, PlanCreationTime, SYSDATETIME()),
        LastExecutionTime DATETIME,
        PlanHandle VARBINARY(64),
		[Remove Plan Handle From Cache] AS 
			CASE WHEN [PlanHandle] IS NOT NULL 
			THEN 'DBCC FREEPROCCACHE (' + CONVERT(VARCHAR(128), [PlanHandle], 1) + ');'
			ELSE 'N/A' END,
		SqlHandle VARBINARY(64),
			[Remove SQL Handle From Cache] AS 
			CASE WHEN [SqlHandle] IS NOT NULL 
			THEN 'DBCC FREEPROCCACHE (' + CONVERT(VARCHAR(128), [SqlHandle], 1) + ');'
			ELSE 'N/A' END,
		[SQL Handle More Info] AS 
			CASE WHEN [SqlHandle] IS NOT NULL 
			THEN 'EXEC sp_BlitzCache @OnlySqlHandles = ''' + CONVERT(VARCHAR(128), [SqlHandle], 1) + '''; '
			ELSE 'N/A' END,
		QueryHash BINARY(8),
		[Query Hash More Info] AS 
			CASE WHEN [QueryHash] IS NOT NULL 
			THEN 'EXEC sp_BlitzCache @OnlyQueryHashes = ''' + CONVERT(VARCHAR(32), [QueryHash], 1) + '''; '
			ELSE 'N/A' END,
        QueryPlanHash BINARY(8),
        StatementStartOffset INT,
        StatementEndOffset INT,
        MinReturnedRows BIGINT,
        MaxReturnedRows BIGINT,
        AverageReturnedRows MONEY,
        TotalReturnedRows BIGINT,
        LastReturnedRows BIGINT,
		MinGrantKB BIGINT,
		MaxGrantKB BIGINT,
		MinUsedGrantKB BIGINT, 
		MaxUsedGrantKB BIGINT,
		PercentMemoryGrantUsed MONEY,
		AvgMaxMemoryGrant MONEY,
        QueryText NVARCHAR(MAX),
        QueryPlan XML,
        /* these next four columns are the total for the type of query.
            don't actually use them for anything apart from math by type.
            */
        TotalWorkerTimeForType BIGINT,
        TotalElapsedTimeForType BIGINT,
        TotalReadsForType BIGINT,
        TotalExecutionCountForType BIGINT,
        TotalWritesForType BIGINT,
        NumberOfPlans INT,
        NumberOfDistinctPlans INT,
        SerialDesiredMemory FLOAT,
        SerialRequiredMemory FLOAT,
        CachedPlanSize FLOAT,
        CompileTime FLOAT,
        CompileCPU FLOAT ,
        CompileMemory FLOAT ,
        min_worker_time BIGINT,
        max_worker_time BIGINT,
        is_forced_plan BIT,
        is_forced_parameterized BIT,
        is_cursor BIT,
		is_optimistic_cursor BIT,
		is_forward_only_cursor BIT,
        is_parallel BIT,
		is_forced_serial BIT,
		is_key_lookup_expensive BIT,
		key_lookup_cost FLOAT,
		is_remote_query_expensive BIT,
		remote_query_cost FLOAT,
        frequent_execution BIT,
        parameter_sniffing BIT,
        unparameterized_query BIT,
        near_parallel BIT,
        plan_warnings BIT,
        plan_multiple_plans BIT,
        long_running BIT,
        downlevel_estimator BIT,
        implicit_conversions BIT,
        busy_loops BIT,
        tvf_join BIT,
        tvf_estimate BIT,
        compile_timeout BIT,
        compile_memory_limit_exceeded BIT,
        warning_no_join_predicate BIT,
        QueryPlanCost FLOAT,
        missing_index_count INT,
        unmatched_index_count INT,
        min_elapsed_time BIGINT,
        max_elapsed_time BIGINT,
        age_minutes MONEY,
        age_minutes_lifetime MONEY,
        is_trivial BIT,
		trace_flags_session VARCHAR(1000),
		is_unused_grant BIT,
		function_count INT,
		clr_function_count INT,
		is_table_variable BIT,
		no_stats_warning BIT,
		relop_warnings BIT,
		is_table_scan BIT,
	    backwards_scan BIT,
	    forced_index BIT,
	    forced_seek BIT,
	    forced_scan BIT,
		columnstore_row_mode BIT,
		is_computed_scalar BIT ,
		is_sort_expensive bit,
		sort_cost float,
        SetOptions VARCHAR(MAX),
        Warnings VARCHAR(MAX)
    );
END

DECLARE @DurationFilter_i INT,
		@MinMemoryPerQuery INT,
        @msg NVARCHAR(4000) ;


IF @BringThePain = 1
   BEGIN
   RAISERROR(N'You have chosen to bring the pain. Setting top to 2147483647.', 0, 1) WITH NOWAIT;
   SET @Top = 2147483647;
   END 

/* Change duration from seconds to milliseconds */
IF @DurationFilter IS NOT NULL
  BEGIN
  RAISERROR(N'Converting Duration Filter to milliseconds', 0, 1) WITH NOWAIT;
  SET @DurationFilter_i = CAST((@DurationFilter * 1000.0) AS INT)
  END 

RAISERROR(N'Checking database validity', 0, 1) WITH NOWAIT;
SET @DatabaseName = LTRIM(RTRIM(@DatabaseName)) ;
IF (DB_ID(@DatabaseName)) IS NULL AND @DatabaseName <> ''
BEGIN
   RAISERROR('The database you specified does not exist. Please check the name and try again.', 16, 1);
   RETURN;
END
IF (SELECT DATABASEPROPERTYEX(@DatabaseName, 'Status')) <> 'ONLINE'
BEGIN
   RAISERROR('The database you specified is not readable. Please check the name and try again. Better yet, check your server.', 16, 1);
   RETURN;
END

SELECT @MinMemoryPerQuery = CONVERT(INT, c.value) FROM sys.configurations AS c WHERE c.name = 'min memory per query (KB)';

SET @SortOrder = LOWER(@SortOrder);
SET @SortOrder = REPLACE(REPLACE(@SortOrder, 'average', 'avg'), '.', '');
SET @SortOrder = REPLACE(@SortOrder, 'executions per minute', 'avg executions');
SET @SortOrder = REPLACE(@SortOrder, 'executions / minute', 'avg executions');
SET @SortOrder = REPLACE(@SortOrder, 'xpm', 'avg executions');
SET @SortOrder = REPLACE(@SortOrder, 'recent compilations', 'compiles');

RAISERROR(N'Checking sort order', 0, 1) WITH NOWAIT;
IF @SortOrder NOT IN ('cpu', 'avg cpu', 'reads', 'avg reads', 'writes', 'avg writes',
                       'duration', 'avg duration', 'executions', 'avg executions',
                       'compiles', 'memory grant', 'avg memory grant')
  BEGIN
  RAISERROR(N'Invalid sort order chosen, reverting to cpu', 0, 1) WITH NOWAIT;
  SET @SortOrder = 'cpu';
  END 

SELECT @OutputDatabaseName = QUOTENAME(@OutputDatabaseName),
       @OutputSchemaName   = QUOTENAME(@OutputSchemaName),
       @OutputTableName    = QUOTENAME(@OutputTableName);

SET @QueryFilter = LOWER(@QueryFilter);

IF LEFT(@QueryFilter, 3) NOT IN ('all', 'sta', 'pro')
  BEGIN
  RAISERROR(N'Invalid query filter chosen. Reverting to all.', 0, 1) WITH NOWAIT;
  SET @QueryFilter = 'all';
  END

IF @SkipAnalysis = 1
  BEGIN
  RAISERROR(N'Skip Analysis set to 1, hiding Summary', 0, 1) WITH NOWAIT;
  SET @HideSummary = 1;
  END 

IF @Reanalyze = 1 AND OBJECT_ID('tempdb..##bou_BlitzCacheResults') IS NULL
  BEGIN
  RAISERROR(N'##bou_BlitzCacheResults does not exist, can''t reanalyze', 0, 1) WITH NOWAIT;
  SET @Reanalyze = 0;
  END

IF @Reanalyze = 0
  BEGIN
  RAISERROR(N'Cleaning up old warnings for your SPID', 0, 1) WITH NOWAIT;
  DELETE ##bou_BlitzCacheResults
    WHERE SPID = @@SPID;
  RAISERROR(N'Cleaning up old plans for your SPID', 0, 1) WITH NOWAIT;
  DELETE ##bou_BlitzCacheProcs
    WHERE SPID = @@SPID;
  END  

IF @Reanalyze = 1 
	BEGIN
	RAISERROR(N'Reanalyzing current data, skipping to results', 0, 1) WITH NOWAIT;
    GOTO Results
	END

RAISERROR(N'Creating temp tables for internal processing', 0, 1) WITH NOWAIT;
IF OBJECT_ID('tempdb..#only_query_hashes') IS NOT NULL
    DROP TABLE #only_query_hashes ;

IF OBJECT_ID('tempdb..#ignore_query_hashes') IS NOT NULL
    DROP TABLE #ignore_query_hashes ;

IF OBJECT_ID('tempdb..#only_sql_handles') IS NOT NULL
    DROP TABLE #only_sql_handles ;
   
IF OBJECT_ID('tempdb..#p') IS NOT NULL
    DROP TABLE #p;

IF OBJECT_ID ('tempdb..#checkversion') IS NOT NULL
    DROP TABLE #checkversion;

IF OBJECT_ID ('tempdb..#configuration') IS NOT NULL
    DROP TABLE #configuration;

CREATE TABLE #only_query_hashes (
    query_hash BINARY(8)
);

CREATE TABLE #ignore_query_hashes (
    query_hash BINARY(8)
);

CREATE TABLE #only_sql_handles (
    sql_handle VARBINARY(64)
);

CREATE TABLE #p (
    SqlHandle VARBINARY(64),
    TotalCPU BIGINT,
    TotalDuration BIGINT,
    TotalReads BIGINT,
    TotalWrites BIGINT,
    ExecutionCount BIGINT
);

CREATE TABLE #checkversion (
    version NVARCHAR(128),
    common_version AS SUBSTRING(version, 1, CHARINDEX('.', version) + 1 ),
    major AS PARSENAME(CONVERT(VARCHAR(32), version), 4),
    minor AS PARSENAME(CONVERT(VARCHAR(32), version), 3),
    build AS PARSENAME(CONVERT(VARCHAR(32), version), 2),
    revision AS PARSENAME(CONVERT(VARCHAR(32), version), 1)
);

CREATE TABLE #configuration (
    parameter_name VARCHAR(100),
    value DECIMAL(38,0)
);

RAISERROR(N'Checking plan cache age', 0, 1) WITH NOWAIT;
WITH x AS (
SELECT SUM(CASE WHEN DATEDIFF(HOUR, deqs.creation_time, SYSDATETIME()) < 24 THEN 1 ELSE 0 END) AS [plans_24],
	   SUM(CASE WHEN DATEDIFF(HOUR, deqs.creation_time, SYSDATETIME()) < 4 THEN 1 ELSE 0 END) AS [plans_4],
	   COUNT(deqs.creation_time) AS [total_plans]
FROM sys.dm_exec_query_stats AS deqs
)
SELECT CONVERT(DECIMAL(3,2), x.plans_24 / (1. * NULLIF(x.total_plans, 0))) * 100 AS [percent_24],
	   CONVERT(DECIMAL(3,2), x.plans_4 / (1. * NULLIF(x.total_plans, 0))) * 100 AS [percent_4],
	   @@SPID AS SPID
INTO #plan_creation
FROM x


RAISERROR(N'Checking plan stub count', 0, 1) WITH NOWAIT;
SELECT  CONVERT(DECIMAL(9, 2), ( CAST(COUNT(*) AS DECIMAL(9, 2)) / ( SELECT COUNT (*) FROM sys.dm_exec_cached_plans ) )) AS plan_stubs_percent,
        COUNT(*) AS total_plan_stubs,
		( SELECT COUNT (*) FROM sys.dm_exec_cached_plans ) AS total_plans,
        ISNULL(AVG(DATEDIFF(HOUR, qs.creation_time, GETDATE())), 0) AS avg_plan_age,
		@@SPID AS SPID
INTO #plan_stubs_warning
FROM    sys.dm_exec_cached_plans cp
LEFT JOIN sys.dm_exec_query_stats qs
ON      cp.plan_handle = qs.plan_handle
WHERE   cp.cacheobjtype = 'Compiled Plan Stub';


RAISERROR(N'Checking single use plan count', 0, 1) WITH NOWAIT;
SELECT  CONVERT(DECIMAL(9, 2), ( CAST(COUNT(*) AS DECIMAL(9, 2)) / ( SELECT COUNT (*) FROM sys.dm_exec_cached_plans ) )) AS single_use_plans_percent,
        COUNT(*) AS total_single_use_plans,
		( SELECT COUNT (*) FROM sys.dm_exec_cached_plans ) AS total_plans,
        ISNULL(AVG(DATEDIFF(HOUR, qs.creation_time, GETDATE())), 0) AS avg_plan_age,
		@@SPID AS SPID
INTO #single_use_plans_warning
FROM    sys.dm_exec_cached_plans cp
LEFT JOIN sys.dm_exec_query_stats qs
ON      cp.plan_handle = qs.plan_handle
WHERE   cp.usecounts = 1
        AND cp.cacheobjtype = 'Compiled Plan';



SET @OnlySqlHandles = LTRIM(RTRIM(@OnlySqlHandles)) ;
SET @OnlyQueryHashes = LTRIM(RTRIM(@OnlyQueryHashes)) ;
SET @IgnoreQueryHashes = LTRIM(RTRIM(@IgnoreQueryHashes)) ;

DECLARE @individual VARCHAR(100) ;

IF @OnlySqlHandles IS NOT NULL
    AND LEN(@OnlySqlHandles) > 0
BEGIN
    RAISERROR(N'Processing SQL Handles', 0, 1) WITH NOWAIT;
	SET @individual = '';

    WHILE LEN(@OnlySqlHandles) > 0
    BEGIN
        IF PATINDEX('%,%', @OnlySqlHandles) > 0
        BEGIN  
               SET @individual = SUBSTRING(@OnlySqlHandles, 0, PATINDEX('%,%',@OnlySqlHandles)) ;
               
               INSERT INTO #only_sql_handles
               SELECT CAST('' AS XML).value('xs:hexBinary( substring(sql:variable("@individual"), sql:column("t.pos")) )', 'varbinary(max)')
               FROM (SELECT CASE SUBSTRING(@individual, 1, 2) WHEN '0x' THEN 3 ELSE 0 END) AS t(pos)
               
               --SELECT CAST(SUBSTRING(@individual, 1, 2) AS BINARY(8));

               SET @OnlySqlHandles = SUBSTRING(@OnlySqlHandles, LEN(@individual + ',') + 1, LEN(@OnlySqlHandles)) ;
        END
        ELSE
        BEGIN
               SET @individual = @OnlySqlHandles
               SET @OnlySqlHandles = NULL

               INSERT INTO #only_sql_handles
               SELECT CAST('' AS XML).value('xs:hexBinary( substring(sql:variable("@individual"), sql:column("t.pos")) )', 'varbinary(max)')
               FROM (SELECT CASE SUBSTRING(@individual, 1, 2) WHEN '0x' THEN 3 ELSE 0 END) AS t(pos)

               --SELECT CAST(SUBSTRING(@individual, 1, 2) AS VARBINARY(MAX)) ;
        END
    END
END    

IF @StoredProcName IS NOT NULL AND @StoredProcName <> N''

BEGIN
	RAISERROR(N'Setting up filter for stored procedure name', 0, 1) WITH NOWAIT;
	INSERT #only_sql_handles
	        ( sql_handle )
	SELECT  ISNULL(deps.sql_handle, CONVERT(VARBINARY(64),''))
	FROM sys.dm_exec_procedure_stats AS deps
	WHERE OBJECT_NAME(deps.object_id, deps.database_id) = @StoredProcName

END



IF ((@OnlyQueryHashes IS NOT NULL AND LEN(@OnlyQueryHashes) > 0)
    OR (@IgnoreQueryHashes IS NOT NULL AND LEN(@IgnoreQueryHashes) > 0))
   AND LEFT(@QueryFilter, 3) = 'pro'
BEGIN
   RAISERROR('You cannot limit by query hash and filter by stored procedure', 16, 1);
   RETURN;
END

/* If the user is attempting to limit by query hash, set up the
   #only_query_hashes temp table. This will be used to narrow down
   results.

   Just a reminder: Using @OnlyQueryHashes will ignore stored
   procedures and triggers.
 */
IF @OnlyQueryHashes IS NOT NULL
   AND LEN(@OnlyQueryHashes) > 0
BEGIN
	RAISERROR(N'Setting up filter for Query Hashes', 0, 1) WITH NOWAIT;
    SET @individual = '';

   WHILE LEN(@OnlyQueryHashes) > 0
   BEGIN
        IF PATINDEX('%,%', @OnlyQueryHashes) > 0
        BEGIN  
               SET @individual = SUBSTRING(@OnlyQueryHashes, 0, PATINDEX('%,%',@OnlyQueryHashes)) ;
               
               INSERT INTO #only_query_hashes
               SELECT CAST('' AS XML).value('xs:hexBinary( substring(sql:variable("@individual"), sql:column("t.pos")) )', 'varbinary(max)')
               FROM (SELECT CASE SUBSTRING(@individual, 1, 2) WHEN '0x' THEN 3 ELSE 0 END) AS t(pos)
               
               --SELECT CAST(SUBSTRING(@individual, 1, 2) AS BINARY(8));

               SET @OnlyQueryHashes = SUBSTRING(@OnlyQueryHashes, LEN(@individual + ',') + 1, LEN(@OnlyQueryHashes)) ;
        END
        ELSE
        BEGIN
               SET @individual = @OnlyQueryHashes
               SET @OnlyQueryHashes = NULL

               INSERT INTO #only_query_hashes
               SELECT CAST('' AS XML).value('xs:hexBinary( substring(sql:variable("@individual"), sql:column("t.pos")) )', 'varbinary(max)')
               FROM (SELECT CASE SUBSTRING(@individual, 1, 2) WHEN '0x' THEN 3 ELSE 0 END) AS t(pos)

               --SELECT CAST(SUBSTRING(@individual, 1, 2) AS VARBINARY(MAX)) ;
        END
   END
END

/* If the user is setting up a list of query hashes to ignore, those
   values will be inserted into #ignore_query_hashes. This is used to
   exclude values from query results.

   Just a reminder: Using @IgnoreQueryHashes will ignore stored
   procedures and triggers.
 */
IF @IgnoreQueryHashes IS NOT NULL
   AND LEN(@IgnoreQueryHashes) > 0
BEGIN
	RAISERROR(N'Setting up filter to ignore query hashes', 0, 1) WITH NOWAIT;
   SET @individual = '' ;

   WHILE LEN(@IgnoreQueryHashes) > 0
   BEGIN
        IF PATINDEX('%,%', @IgnoreQueryHashes) > 0
        BEGIN  
               SET @individual = SUBSTRING(@IgnoreQueryHashes, 0, PATINDEX('%,%',@IgnoreQueryHashes)) ;
               
               INSERT INTO #ignore_query_hashes
               SELECT CAST('' AS XML).value('xs:hexBinary( substring(sql:variable("@individual"), sql:column("t.pos")) )', 'varbinary(max)')
               FROM (SELECT CASE SUBSTRING(@individual, 1, 2) WHEN '0x' THEN 3 ELSE 0 END) AS t(pos) ;
               
               SET @IgnoreQueryHashes = SUBSTRING(@IgnoreQueryHashes, LEN(@individual + ',') + 1, LEN(@IgnoreQueryHashes)) ;
        END
        ELSE
        BEGIN
               SET @individual = @IgnoreQueryHashes ;
               SET @IgnoreQueryHashes = NULL ;

               INSERT INTO #ignore_query_hashes
               SELECT CAST('' AS XML).value('xs:hexBinary( substring(sql:variable("@individual"), sql:column("t.pos")) )', 'varbinary(max)')
               FROM (SELECT CASE SUBSTRING(@individual, 1, 2) WHEN '0x' THEN 3 ELSE 0 END) AS t(pos) ;
        END
   END
END

IF @ConfigurationDatabaseName IS NOT NULL
BEGIN
   RAISERROR(N'Reading values from Configuration Database', 0, 1) WITH NOWAIT;
   DECLARE @config_sql NVARCHAR(MAX) = N'INSERT INTO #configuration SELECT parameter_name, value FROM '
        + QUOTENAME(@ConfigurationDatabaseName)
        + '.' + QUOTENAME(@ConfigurationSchemaName)
        + '.' + QUOTENAME(@ConfigurationTableName)
        + ' ; ' ;
   EXEC(@config_sql);
END

RAISERROR(N'Setting up variables', 0, 1) WITH NOWAIT;
DECLARE @sql NVARCHAR(MAX) = N'',
        @insert_list NVARCHAR(MAX) = N'',
        @plans_triggers_select_list NVARCHAR(MAX) = N'',
        @body NVARCHAR(MAX) = N'',
        @body_where NVARCHAR(MAX) = N'WHERE 1 = 1 ' + @nl,
        @body_order NVARCHAR(MAX) = N'ORDER BY #sortable# DESC OPTION (RECOMPILE) ',
        
        @q NVARCHAR(1) = N'''',
        @pv VARCHAR(20),
        @pos TINYINT,
        @v DECIMAL(6,2),
        @build INT;


RAISERROR (N'Determining SQL Server version.',0,1) WITH NOWAIT;

INSERT INTO #checkversion (version)
SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))
OPTION (RECOMPILE);


SELECT @v = common_version ,
       @build = build
FROM   #checkversion
OPTION (RECOMPILE);

IF (@SortOrder IN ('memory grant', 'avg memory grant')) 
AND ((@v < 11)
OR (@v = 11 AND @build < 6020) 
OR (@v = 12 AND @build < 5000) 
OR (@v = 13 AND @build < 1601))
BEGIN
   RAISERROR('Your version of SQL does not support sorting by memory grant or average memory grant. Please use another sort order.', 16, 1);
   RETURN;
END

RAISERROR (N'Creating dynamic SQL based on SQL Server version.',0,1) WITH NOWAIT;

SET @insert_list += N'
INSERT INTO ##bou_BlitzCacheProcs (SPID, QueryType, DatabaseName, AverageCPU, TotalCPU, AverageCPUPerMinute, PercentCPUByType, PercentDurationByType,
                    PercentReadsByType, PercentExecutionsByType, AverageDuration, TotalDuration, AverageReads, TotalReads, ExecutionCount,
                    ExecutionsPerMinute, TotalWrites, AverageWrites, PercentWritesByType, WritesPerMinute, PlanCreationTime,
                    LastExecutionTime, StatementStartOffset, StatementEndOffset, MinReturnedRows, MaxReturnedRows, AverageReturnedRows, TotalReturnedRows,
                    LastReturnedRows, MinGrantKB, MaxGrantKB, MinUsedGrantKB, MaxUsedGrantKB, PercentMemoryGrantUsed, AvgMaxMemoryGrant,
					QueryText, QueryPlan, TotalWorkerTimeForType, TotalElapsedTimeForType, TotalReadsForType,
                    TotalExecutionCountForType, TotalWritesForType, SqlHandle, PlanHandle, QueryHash, QueryPlanHash,
                    min_worker_time, max_worker_time, is_parallel, min_elapsed_time, max_elapsed_time, age_minutes, age_minutes_lifetime) ' ;

SET @body += N'
FROM   (SELECT TOP (@Top) x.*, xpa.*,
               CAST((CASE WHEN DATEDIFF(mi, cached_time, GETDATE()) > 0 AND execution_count > 1
                          THEN DATEDIFF(mi, cached_time, GETDATE()) 
                          ELSE NULL END) as MONEY) as age_minutes,
               CAST((CASE WHEN DATEDIFF(mi, cached_time, last_execution_time) > 0 AND execution_count > 1
                          THEN DATEDIFF(mi, cached_time, last_execution_time) 
                          ELSE Null END) as MONEY) as age_minutes_lifetime
        FROM   sys.#view# x
               CROSS APPLY (SELECT * FROM sys.dm_exec_plan_attributes(x.plan_handle) AS ixpa 
                            WHERE ixpa.attribute = ''dbid'') AS xpa ' + @nl ;

SET @body += N'        WHERE  1 = 1 ' +  @nl ;


IF @IgnoreSystemDBs = 1
    BEGIN
	RAISERROR(N'Ignoring system databases by default', 0, 1) WITH NOWAIT;
	SET @body += N'               AND COALESCE(DB_NAME(CAST(xpa.value AS INT)), '''') NOT IN (''master'', ''model'', ''msdb'', ''tempdb'', ''32767'') AND COALESCE(DB_NAME(CAST(xpa.value AS INT)), '''') NOT IN (SELECT name FROM sys.databases WHERE is_distributor = 1)' + @nl ;
	END 

IF @DatabaseName IS NOT NULL OR @DatabaseName <> ''
	BEGIN 
    RAISERROR(N'Filtering database name chosen', 0, 1) WITH NOWAIT;
	SET @body += N'               AND CAST(xpa.value AS BIGINT) = DB_ID('
                 + QUOTENAME(@DatabaseName, N'''')
                 + N') ' + @nl;
	END 

IF (SELECT COUNT(*) FROM #only_sql_handles) > 0
BEGIN
    RAISERROR(N'Including only chosen SQL Handles', 0, 1) WITH NOWAIT;
	SET @body += N'               AND EXISTS(SELECT 1/0 FROM #only_sql_handles q WHERE q.sql_handle = x.sql_handle) ' + @nl ;
END      

IF (SELECT COUNT(*) FROM #only_query_hashes) > 0
   AND (SELECT COUNT(*) FROM #ignore_query_hashes) = 0
   AND (SELECT COUNT(*) FROM #only_sql_handles) = 0
BEGIN
    RAISERROR(N'Including only chosen Query Hashes', 0, 1) WITH NOWAIT;
	SET @body += N'               AND EXISTS(SELECT 1/0 FROM #only_query_hashes q WHERE q.query_hash = x.query_hash) ' + @nl ;
END

/* filtering for query hashes */
IF (SELECT COUNT(*) FROM #ignore_query_hashes) > 0
   AND (SELECT COUNT(*) FROM #only_query_hashes) = 0
BEGIN
    RAISERROR(N'Excluding chosen Query Hashes', 0, 1) WITH NOWAIT;
	SET @body += N'               AND NOT EXISTS(SELECT 1/0 FROM #ignore_query_hashes iq WHERE iq.query_hash = x.query_hash) ' + @nl ;
END
/* end filtering for query hashes */


IF @DurationFilter IS NOT NULL
    BEGIN 
	RAISERROR(N'Setting duration filter', 0, 1) WITH NOWAIT;
	SET @body += N'       AND (total_elapsed_time / 1000.0) / execution_count > @min_duration ' + @nl ;
	END 


/* Apply the sort order here to only grab relevant plans.
   This should make it faster to process since we'll be pulling back fewer
   plans for processing.
 */
RAISERROR(N'Applying chosen sort order', 0, 1) WITH NOWAIT;
SELECT @body += N'        ORDER BY ' +
                CASE @SortOrder  WHEN N'cpu' THEN N'total_worker_time'
                                 WHEN N'reads' THEN N'total_logical_reads'
                                 WHEN N'writes' THEN N'total_logical_writes'
                                 WHEN N'duration' THEN N'total_elapsed_time'
                                 WHEN N'executions' THEN N'execution_count'
                                 WHEN N'compiles' THEN N'cached_time'
								 WHEN N'memory grant' THEN N'max_grant_kb'
                                 /* And now the averages */
                                 WHEN N'avg cpu' THEN N'total_worker_time / execution_count'
                                 WHEN N'avg reads' THEN N'total_logical_reads / execution_count'
                                 WHEN N'avg writes' THEN N'total_logical_writes / execution_count'
                                 WHEN N'avg duration' THEN N'total_elapsed_time / execution_count'
								 WHEN N'avg memory grant' THEN N'CASE WHEN max_grant_kb = 0 THEN 0 ELSE max_grant_kb / execution_count END'
                                 WHEN N'avg executions' THEN 'CASE WHEN execution_count = 0 THEN 0
            WHEN COALESCE(CAST((CASE WHEN DATEDIFF(mi, cached_time, GETDATE()) > 0 AND execution_count > 1
                          THEN DATEDIFF(mi, cached_time, GETDATE())
                          ELSE NULL END) as MONEY), CAST((CASE WHEN DATEDIFF(mi, cached_time, last_execution_time) > 0 AND execution_count > 1
                          THEN DATEDIFF(mi, cached_time, last_execution_time)
                          ELSE Null END) as MONEY), 0) = 0 THEN 0
            ELSE CAST((1.00 * execution_count / COALESCE(CAST((CASE WHEN DATEDIFF(mi, cached_time, GETDATE()) > 0 AND execution_count > 1
                          THEN DATEDIFF(mi, cached_time, GETDATE())
                          ELSE NULL END) as MONEY), CAST((CASE WHEN DATEDIFF(mi, cached_time, last_execution_time) > 0 AND execution_count > 1
                          THEN DATEDIFF(mi, cached_time, last_execution_time)
                          ELSE Null END) as MONEY))) AS money)
            END '
                END + N' DESC ' + @nl ;


                          
SET @body += N') AS qs 
	   CROSS JOIN(SELECT SUM(execution_count) AS t_TotalExecs,
                         SUM(CAST(total_elapsed_time AS BIGINT) / 1000.0) AS t_TotalElapsed,
                         SUM(CAST(total_worker_time AS BIGINT) / 1000.0) AS t_TotalWorker,
                         SUM(CAST(total_logical_reads AS BIGINT)) AS t_TotalReads,
                         SUM(CAST(total_logical_writes AS BIGINT)) AS t_TotalWrites
                  FROM   sys.#view#) AS t
       CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS pa
       CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
       CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp ' + @nl ;

SET @body_where += N'       AND pa.attribute = ' + QUOTENAME('dbid', @q) + @nl ;



SET @plans_triggers_select_list += N'
SELECT TOP (@Top)
       @@SPID ,
       ''Procedure: '' + COALESCE(OBJECT_NAME(qs.object_id, qs.database_id),'''') AS QueryType,
       COALESCE(DB_NAME(database_id), CAST(pa.value AS sysname), ''-- N/A --'') AS DatabaseName,
       (total_worker_time / 1000.0) / execution_count AS AvgCPU ,
       (total_worker_time / 1000.0) AS TotalCPU ,
       CASE WHEN total_worker_time = 0 THEN 0
            WHEN COALESCE(age_minutes, DATEDIFF(mi, qs.cached_time, qs.last_execution_time), 0) = 0 THEN 0
            ELSE CAST((total_worker_time / 1000.0) / COALESCE(age_minutes, DATEDIFF(mi, qs.cached_time, qs.last_execution_time)) AS MONEY)
            END AS AverageCPUPerMinute ,
       CASE WHEN t.t_TotalWorker = 0 THEN 0
            ELSE CAST(ROUND(100.00 * (total_worker_time / 1000.0) / t.t_TotalWorker, 2) AS MONEY)
            END AS PercentCPUByType,
       CASE WHEN t.t_TotalElapsed = 0 THEN 0
            ELSE CAST(ROUND(100.00 * (total_elapsed_time / 1000.0) / t.t_TotalElapsed, 2) AS MONEY)
            END AS PercentDurationByType,
       CASE WHEN t.t_TotalReads = 0 THEN 0
            ELSE CAST(ROUND(100.00 * total_logical_reads / t.t_TotalReads, 2) AS MONEY)
            END AS PercentReadsByType,
       CASE WHEN t.t_TotalExecs = 0 THEN 0
            ELSE CAST(ROUND(100.00 * execution_count / t.t_TotalExecs, 2) AS MONEY)
            END AS PercentExecutionsByType,
       (total_elapsed_time / 1000.0) / execution_count AS AvgDuration ,
       (total_elapsed_time / 1000.0) AS TotalDuration ,
       total_logical_reads / execution_count AS AvgReads ,
       total_logical_reads AS TotalReads ,
       execution_count AS ExecutionCount ,
       CASE WHEN execution_count = 0 THEN 0
            WHEN COALESCE(age_minutes, DATEDIFF(mi, qs.cached_time, qs.last_execution_time), 0) = 0 THEN 0
            ELSE CAST((1.00 * execution_count / COALESCE(age_minutes, DATEDIFF(mi, qs.cached_time, qs.last_execution_time))) AS money)
            END AS ExecutionsPerMinute ,
       total_logical_writes AS TotalWrites ,
       total_logical_writes / execution_count AS AverageWrites ,
       CASE WHEN t.t_TotalWrites = 0 THEN 0
            ELSE CAST(ROUND(100.00 * total_logical_writes / t.t_TotalWrites, 2) AS MONEY)
            END AS PercentWritesByType,
       CASE WHEN total_logical_writes = 0 THEN 0
            WHEN COALESCE(age_minutes, DATEDIFF(mi, qs.cached_time, qs.last_execution_time), 0) = 0 THEN 0
            ELSE CAST((1.00 * total_logical_writes / COALESCE(age_minutes, DATEDIFF(mi, qs.cached_time, qs.last_execution_time), 0)) AS money)
            END AS WritesPerMinute,
       qs.cached_time AS PlanCreationTime,
       qs.last_execution_time AS LastExecutionTime,
       NULL AS StatementStartOffset,
       NULL AS StatementEndOffset,
       NULL AS MinReturnedRows,
       NULL AS MaxReturnedRows,
       NULL AS AvgReturnedRows,
       NULL AS TotalReturnedRows,
       NULL AS LastReturnedRows,
       NULL AS MinGrantKB,
       NULL AS MaxGrantKB,
       NULL AS MinUsedGrantKB, 
	   NULL AS MaxUsedGrantKB,
	   NULL AS PercentMemoryGrantUsed, 
	   NULL AS AvgMaxMemoryGrant,
       st.text AS QueryText ,
       query_plan AS QueryPlan,
       t.t_TotalWorker,
       t.t_TotalElapsed,
       t.t_TotalReads,
       t.t_TotalExecs,
       t.t_TotalWrites,
       qs.sql_handle AS SqlHandle,
       qs.plan_handle AS PlanHandle,
       NULL AS QueryHash,
       NULL AS QueryPlanHash,
       qs.min_worker_time / 1000.0,
       qs.max_worker_time / 1000.0,
       CASE WHEN qp.query_plan.value(''declare namespace p="http://schemas.microsoft.com/sqlserver/2004/07/showplan";max(//p:RelOp/@Parallel)'', ''float'')  > 0 THEN 1 ELSE 0 END,
       qs.min_elapsed_time / 1000.0,
       qs.max_elapsed_time / 1000.0,
       age_minutes, 
       age_minutes_lifetime '


IF LEFT(@QueryFilter, 3) IN ('all', 'sta')
BEGIN
    SET @sql += @insert_list;
    
    SET @sql += N'
    SELECT TOP (@Top)
           @@SPID ,
           ''Statement'' AS QueryType,
           COALESCE(DB_NAME(CAST(pa.value AS INT)), ''-- N/A --'') AS DatabaseName,
           (total_worker_time / 1000.0) / execution_count AS AvgCPU ,
           (total_worker_time / 1000.0) AS TotalCPU ,
           CASE WHEN total_worker_time = 0 THEN 0
                WHEN COALESCE(age_minutes, DATEDIFF(mi, qs.creation_time, qs.last_execution_time), 0) = 0 THEN 0
                ELSE CAST((total_worker_time / 1000.0) / COALESCE(age_minutes, DATEDIFF(mi, qs.creation_time, qs.last_execution_time)) AS MONEY)
                END AS AverageCPUPerMinute ,
           CAST(ROUND(100.00 * (total_worker_time / 1000.0) / t.t_TotalWorker, 2) AS MONEY) AS PercentCPUByType,
           CAST(ROUND(100.00 * (total_elapsed_time / 1000.0) / t.t_TotalElapsed, 2) AS MONEY) AS PercentDurationByType,
           CAST(ROUND(100.00 * total_logical_reads / t.t_TotalReads, 2) AS MONEY) AS PercentReadsByType,
           CAST(ROUND(100.00 * execution_count / t.t_TotalExecs, 2) AS MONEY) AS PercentExecutionsByType,
           (total_elapsed_time / 1000.0) / execution_count AS AvgDuration ,
           (total_elapsed_time / 1000.0) AS TotalDuration ,
           total_logical_reads / execution_count AS AvgReads ,
           total_logical_reads AS TotalReads ,
           execution_count AS ExecutionCount ,
           CASE WHEN execution_count = 0 THEN 0
                WHEN COALESCE(age_minutes, DATEDIFF(mi, qs.creation_time, qs.last_execution_time), 0) = 0 THEN 0
                ELSE CAST((1.00 * execution_count / COALESCE(age_minutes, DATEDIFF(mi, qs.creation_time, qs.last_execution_time))) AS money)
                END AS ExecutionsPerMinute ,
           total_logical_writes AS TotalWrites ,
           total_logical_writes / execution_count AS AverageWrites ,
           CASE WHEN t.t_TotalWrites = 0 THEN 0
                ELSE CAST(ROUND(100.00 * total_logical_writes / t.t_TotalWrites, 2) AS MONEY)
                END AS PercentWritesByType,
           CASE WHEN total_logical_writes = 0 THEN 0
                WHEN COALESCE(age_minutes, DATEDIFF(mi, qs.creation_time, qs.last_execution_time), 0) = 0 THEN 0
                ELSE CAST((1.00 * total_logical_writes / COALESCE(age_minutes, DATEDIFF(mi, qs.creation_time, qs.last_execution_time), 0)) AS money)
                END AS WritesPerMinute,
           qs.creation_time AS PlanCreationTime,
           qs.last_execution_time AS LastExecutionTime,
           qs.statement_start_offset AS StatementStartOffset,
           qs.statement_end_offset AS StatementEndOffset, '
    
    IF (@v >= 11) OR (@v >= 10.5 AND @build >= 2500)
    BEGIN
        RAISERROR(N'Adding additional info columns for newer versions of SQL', 0, 1) WITH NOWAIT;
		SET @sql += N'
           qs.min_rows AS MinReturnedRows,
           qs.max_rows AS MaxReturnedRows,
           CAST(qs.total_rows as MONEY) / execution_count AS AvgReturnedRows,
           qs.total_rows AS TotalReturnedRows,
           qs.last_rows AS LastReturnedRows, ' ;
    END
    ELSE
    BEGIN
		RAISERROR(N'Substituting NULLs for more info columns in older versions of SQL', 0, 1) WITH NOWAIT;
        SET @sql += N'
           NULL AS MinReturnedRows,
           NULL AS MaxReturnedRows,
           NULL AS AvgReturnedRows,
           NULL AS TotalReturnedRows,
           NULL AS LastReturnedRows, ' ;
    END

    IF (@v = 11 AND @build >= 6020) OR (@v = 12 AND @build >= 5000) OR (@v = 13 AND @build >= 1601)

    BEGIN
        RAISERROR(N'Getting memory grant information for newer versions of SQL', 0, 1) WITH NOWAIT;
		SET @sql += N'
           min_grant_kb AS MinGrantKB,
           max_grant_kb AS MaxGrantKB,
           min_used_grant_kb AS MinUsedGrantKB,
           max_used_grant_kb AS MaxUsedGrantKB,
           CAST(ISNULL(NULLIF(( max_used_grant_kb * 1.00 ), 0) / NULLIF(min_grant_kb, 0), 0) * 100. AS MONEY) AS PercentMemoryGrantUsed,
		   CAST(ISNULL(NULLIF(( max_grant_kb * 1. ), 0) / NULLIF(execution_count, 0), 0) AS MONEY) AS AvgMaxMemoryGrant, ';
    END
    ELSE
    BEGIN
        RAISERROR(N'Substituting NULLs for memory grant columns in older versions of SQL', 0, 1) WITH NOWAIT;
		SET @sql += N'
           NULL AS MinGrantKB,
           NULL AS MaxGrantKB,
           NULL AS MinUsedGrantKB, 
		   NULL AS MaxUsedGrantKB,
		   NULL AS PercentMemoryGrantUsed, 
		   NULL AS AvgMaxMemoryGrant, ' ;
    END

    
    SET @sql += N'
           SUBSTRING(st.text, ( qs.statement_start_offset / 2 ) + 1, ( ( CASE qs.statement_end_offset
                                                                            WHEN -1 THEN DATALENGTH(st.text)
                                                                            ELSE qs.statement_end_offset
                                                                          END - qs.statement_start_offset ) / 2 ) + 1) AS QueryText ,
           query_plan AS QueryPlan,
           t.t_TotalWorker,
           t.t_TotalElapsed,
           t.t_TotalReads,
           t.t_TotalExecs,
           t.t_TotalWrites,
           qs.sql_handle AS SqlHandle,
           qs.plan_handle AS PlanHandle,
           qs.query_hash AS QueryHash,
           qs.query_plan_hash AS QueryPlanHash,
           qs.min_worker_time / 1000.0,
           qs.max_worker_time / 1000.0,
           CASE WHEN qp.query_plan.value(''declare namespace p="http://schemas.microsoft.com/sqlserver/2004/07/showplan";max(//p:RelOp/@Parallel)'', ''float'')  > 0 THEN 1 ELSE 0 END,
           qs.min_elapsed_time / 1000.0,
           qs.max_worker_time  / 1000.0,
           age_minutes,
           age_minutes_lifetime ';
    
    SET @sql += REPLACE(REPLACE(@body, '#view#', 'dm_exec_query_stats'), 'cached_time', 'creation_time') ;
    
    SET @sql += REPLACE(@body_where, 'cached_time', 'creation_time') ;
    
    SET @sql += @body_order + @nl + @nl + @nl;

    IF @SortOrder = 'compiles'
    BEGIN
        RAISERROR(N'Sorting by compiles', 0, 1) WITH NOWAIT;
		SET @sql = REPLACE(@sql, '#sortable#', 'creation_time');
    END
END


IF (@QueryFilter = 'all' 
   AND (SELECT COUNT(*) FROM #only_query_hashes) = 0 
   AND (SELECT COUNT(*) FROM #ignore_query_hashes) = 0) 
   AND (@SortOrder NOT IN ('memory grant', 'avg memory grant'))
   OR (LEFT(@QueryFilter, 3) = 'pro')
BEGIN
    SET @sql += @insert_list;
    SET @sql += REPLACE(@plans_triggers_select_list, '#query_type#', 'Stored Procedure') ;

    SET @sql += REPLACE(@body, '#view#', 'dm_exec_procedure_stats') ; 
    SET @sql += @body_where ;

    IF @IgnoreSystemDBs = 1
       SET @sql += N' AND COALESCE(DB_NAME(database_id), CAST(pa.value AS sysname), '''') NOT IN (''master'', ''model'', ''msdb'', ''tempdb'', ''32767'') AND COALESCE(DB_NAME(database_id), CAST(pa.value AS sysname), '''') NOT IN (SELECT name FROM sys.databases WHERE is_distributor = 1)' + @nl ;

    SET @sql += @body_order + @nl + @nl + @nl ;
END



/*******************************************************************************
 *
 * Because the trigger execution count in SQL Server 2008R2 and earlier is not
 * correct, we ignore triggers for these versions of SQL Server. If you'd like
 * to include trigger numbers, just know that the ExecutionCount,
 * PercentExecutions, and ExecutionsPerMinute are wildly inaccurate for
 * triggers on these versions of SQL Server.
 *
 * This is why we can't have nice things.
 *
 ******************************************************************************/
IF (@UseTriggersAnyway = 1 OR @v >= 11)
   AND (SELECT COUNT(*) FROM #only_query_hashes) = 0
   AND (SELECT COUNT(*) FROM #ignore_query_hashes) = 0
   AND (@QueryFilter = 'all')
   AND (@SortOrder NOT IN ('memory grant', 'avg memory grant'))
BEGIN
   RAISERROR (N'Adding SQL to collect trigger stats.',0,1) WITH NOWAIT;

   /* Trigger level information from the plan cache */
   SET @sql += @insert_list ;

   SET @sql += REPLACE(@plans_triggers_select_list, '#query_type#', 'Trigger') ;

   SET @sql += REPLACE(@body, '#view#', 'dm_exec_trigger_stats') ;

   SET @sql += @body_where ;

   IF @IgnoreSystemDBs = 1
      SET @sql += N' AND COALESCE(DB_NAME(database_id), CAST(pa.value AS sysname), '''') NOT IN (''master'', ''model'', ''msdb'', ''tempdb'', ''32767'') AND COALESCE(DB_NAME(database_id), CAST(pa.value AS sysname), '''') NOT IN (SELECT name FROM sys.databases WHERE is_distributor = 1)' + @nl ;
   
   SET @sql += @body_order + @nl + @nl + @nl ;
END

DECLARE @sort NVARCHAR(MAX);

SELECT @sort = CASE @SortOrder  WHEN N'cpu' THEN N'total_worker_time'
                                WHEN N'reads' THEN N'total_logical_reads'
                                WHEN N'writes' THEN N'total_logical_writes'
                                WHEN N'duration' THEN N'total_elapsed_time'
                                WHEN N'executions' THEN N'execution_count'
                                WHEN N'compiles' THEN N'cached_time'
								WHEN N'memory grant' THEN N'max_grant_kb'
                                /* And now the averages */
                                WHEN N'avg cpu' THEN N'total_worker_time / execution_count'
                                WHEN N'avg reads' THEN N'total_logical_reads / execution_count'
                                WHEN N'avg writes' THEN N'total_logical_writes / execution_count'
                                WHEN N'avg duration' THEN N'total_elapsed_time / execution_count'
								WHEN N'avg memory grant' THEN N'CASE WHEN max_grant_kb = 0 THEN 0 ELSE max_grant_kb / execution_count END'
                                WHEN N'avg executions' THEN N'CASE WHEN execution_count = 0 THEN 0
            WHEN COALESCE(age_minutes, age_minutes_lifetime, 0) = 0 THEN 0
            ELSE CAST((1.00 * execution_count / COALESCE(age_minutes, age_minutes_lifetime)) AS money)
            END'
               END ;

SELECT @sql = REPLACE(@sql, '#sortable#', @sort);

SET @sql += N'
INSERT INTO #p (SqlHandle, TotalCPU, TotalReads, TotalDuration, TotalWrites, ExecutionCount)
SELECT  SqlHandle,
        TotalCPU,
        TotalReads,
        TotalDuration,
        TotalWrites,
        ExecutionCount
FROM    (SELECT  SqlHandle,
                 TotalCPU,
                 TotalReads,
                 TotalDuration,
                 TotalWrites,
                 ExecutionCount,
                 ROW_NUMBER() OVER (PARTITION BY SqlHandle ORDER BY #sortable# DESC) AS rn
         FROM    ##bou_BlitzCacheProcs) AS x
WHERE x.rn = 1
OPTION (RECOMPILE);
';

SELECT @sort = CASE @SortOrder  WHEN N'cpu' THEN N'TotalCPU'
                                WHEN N'reads' THEN N'TotalReads'
                                WHEN N'writes' THEN N'TotalWrites'
                                WHEN N'duration' THEN N'TotalDuration'
                                WHEN N'executions' THEN N'ExecutionCount'
                                WHEN N'compiles' THEN N'PlanCreationTime'
								WHEN N'memory grant' THEN N'MaxGrantKB'
                                WHEN N'avg cpu' THEN N'TotalCPU / ExecutionCount'
                                WHEN N'avg reads' THEN N'TotalReads / ExecutionCount'
                                WHEN N'avg writes' THEN N'TotalWrites / ExecutionCount'
                                WHEN N'avg duration' THEN N'TotalDuration / ExecutionCount'
								WHEN N'avg memory grant' THEN N'AvgMaxMemoryGrant'
                                WHEN N'avg executions' THEN N'CASE WHEN ExecutionCount = 0 THEN 0
            WHEN COALESCE(age_minutes, age_minutes_lifetime, 0) = 0 THEN 0
            ELSE CAST((1.00 * ExecutionCount / COALESCE(age_minutes, age_minutes_lifetime)) AS money)
            END'
               END ;

SELECT @sql = REPLACE(@sql, '#sortable#', @sort);

IF @Reanalyze = 0
BEGIN
    RAISERROR('Collecting execution plan information.', 0, 1) WITH NOWAIT;

    EXEC sp_executesql @sql, N'@Top INT, @min_duration INT', @Top, @DurationFilter_i;
END

/*
--Debugging section
SELECT DATALENGTH(@sql)
PRINT SUBSTRING(@sql, 0, 4000)
PRINT SUBSTRING(@sql, 4000, 8000)
PRINT SUBSTRING(@sql, 8000, 12000)
PRINT SUBSTRING(@sql, 16000, 24000)
PRINT SUBSTRING(@sql, 24000, 28000)
PRINT SUBSTRING(@sql, 28000, 32000)
PRINT SUBSTRING(@sql, 32000, 36000)
PRINT SUBSTRING(@sql, 36000, 40000)
*/

/* Update ##bou_BlitzCacheProcs to get Stored Proc info 
 * This should get totals for all statements in a Stored Proc
 */
RAISERROR(N'Attempting to aggregate stored proc info from separate statements', 0, 1) WITH NOWAIT;
;WITH agg AS (
    SELECT 
        b.SqlHandle,
        SUM(b.MinReturnedRows) AS MinReturnedRows,
        SUM(b.MaxReturnedRows) AS MaxReturnedRows,
        SUM(b.AverageReturnedRows) AS AverageReturnedRows,
        SUM(b.TotalReturnedRows) AS TotalReturnedRows,
        SUM(b.LastReturnedRows) AS LastReturnedRows
    FROM ##bou_BlitzCacheProcs b
    WHERE b.QueryHash IS NOT NULL 
    GROUP BY b.SqlHandle
)
UPDATE b
    SET 
        b.MinReturnedRows     = b2.MinReturnedRows,
        b.MaxReturnedRows     = b2.MaxReturnedRows,
        b.AverageReturnedRows = b2.AverageReturnedRows,
        b.TotalReturnedRows   = b2.TotalReturnedRows,
        b.LastReturnedRows    = b2.LastReturnedRows
FROM ##bou_BlitzCacheProcs b
JOIN agg b2
ON b2.SqlHandle = b.SqlHandle
WHERE b.QueryHash IS NULL
OPTION (RECOMPILE) ;

/* Compute the total CPU, etc across our active set of the plan cache.
 * Yes, there's a flaw - this doesn't include anything outside of our @Top
 * metric.
 */
RAISERROR('Computing CPU, duration, read, and write metrics', 0, 1) WITH NOWAIT;
DECLARE @total_duration BIGINT,
        @total_cpu BIGINT,
        @total_reads BIGINT,
        @total_writes BIGINT,
        @total_execution_count BIGINT;

SELECT  @total_cpu = SUM(TotalCPU),
        @total_duration = SUM(TotalDuration),
        @total_reads = SUM(TotalReads),
        @total_writes = SUM(TotalWrites),
        @total_execution_count = SUM(ExecutionCount)
FROM    #p
OPTION (RECOMPILE) ;

DECLARE @cr NVARCHAR(1) = NCHAR(13);
DECLARE @lf NVARCHAR(1) = NCHAR(10);
DECLARE @tab NVARCHAR(1) = NCHAR(9);

/* Update CPU percentage for stored procedures */
RAISERROR(N'Update CPU percentage for stored procedures', 0, 1) WITH NOWAIT;
UPDATE ##bou_BlitzCacheProcs
SET     PercentCPU = y.PercentCPU,
        PercentDuration = y.PercentDuration,
        PercentReads = y.PercentReads,
        PercentWrites = y.PercentWrites,
        PercentExecutions = y.PercentExecutions,
        ExecutionsPerMinute = y.ExecutionsPerMinute,
        /* Strip newlines and tabs. Tabs are replaced with multiple spaces
           so that the later whitespace trim will completely eliminate them
         */
        QueryText = REPLACE(REPLACE(REPLACE(QueryText, @cr, ' '), @lf, ' '), @tab, '  ')
FROM (
    SELECT  PlanHandle,
            CASE @total_cpu WHEN 0 THEN 0
                 ELSE CAST((100. * TotalCPU) / @total_cpu AS MONEY) END AS PercentCPU,
            CASE @total_duration WHEN 0 THEN 0
                 ELSE CAST((100. * TotalDuration) / @total_duration AS MONEY) END AS PercentDuration,
            CASE @total_reads WHEN 0 THEN 0
                 ELSE CAST((100. * TotalReads) / @total_reads AS MONEY) END AS PercentReads,
            CASE @total_writes WHEN 0 THEN 0
                 ELSE CAST((100. * TotalWrites) / @total_writes AS MONEY) END AS PercentWrites,
            CASE @total_execution_count WHEN 0 THEN 0
                 ELSE CAST((100. * ExecutionCount) / @total_execution_count AS MONEY) END AS PercentExecutions,
            CASE DATEDIFF(mi, PlanCreationTime, LastExecutionTime)
                WHEN 0 THEN 0
                ELSE CAST((1.00 * ExecutionCount / DATEDIFF(mi, PlanCreationTime, LastExecutionTime)) AS MONEY)
            END AS ExecutionsPerMinute
    FROM (
        SELECT  PlanHandle,
                TotalCPU,
                TotalDuration,
                TotalReads,
                TotalWrites,
                ExecutionCount,
                PlanCreationTime,
                LastExecutionTime
        FROM    ##bou_BlitzCacheProcs
        WHERE   PlanHandle IS NOT NULL
        GROUP BY PlanHandle,
                TotalCPU,
                TotalDuration,
                TotalReads,
                TotalWrites,
                ExecutionCount,
                PlanCreationTime,
                LastExecutionTime
    ) AS x
) AS y
WHERE ##bou_BlitzCacheProcs.PlanHandle = y.PlanHandle
      AND ##bou_BlitzCacheProcs.PlanHandle IS NOT NULL
OPTION (RECOMPILE) ;


RAISERROR(N'Gather percentage information from grouped results', 0, 1) WITH NOWAIT;
UPDATE ##bou_BlitzCacheProcs
SET     PercentCPU = y.PercentCPU,
        PercentDuration = y.PercentDuration,
        PercentReads = y.PercentReads,
        PercentWrites = y.PercentWrites,
        PercentExecutions = y.PercentExecutions,
        ExecutionsPerMinute = y.ExecutionsPerMinute,
        /* Strip newlines and tabs. Tabs are replaced with multiple spaces
           so that the later whitespace trim will completely eliminate them
         */
        QueryText = REPLACE(REPLACE(REPLACE(QueryText, @cr, ' '), @lf, ' '), @tab, '  ')
FROM (
    SELECT  DatabaseName,
            SqlHandle,
            QueryHash,
            CASE @total_cpu WHEN 0 THEN 0
                 ELSE CAST((100. * TotalCPU) / @total_cpu AS MONEY) END AS PercentCPU,
            CASE @total_duration WHEN 0 THEN 0
                 ELSE CAST((100. * TotalDuration) / @total_duration AS MONEY) END AS PercentDuration,
            CASE @total_reads WHEN 0 THEN 0
                 ELSE CAST((100. * TotalReads) / @total_reads AS MONEY) END AS PercentReads,
            CASE @total_writes WHEN 0 THEN 0
                 ELSE CAST((100. * TotalWrites) / @total_writes AS MONEY) END AS PercentWrites,
            CASE @total_execution_count WHEN 0 THEN 0
                 ELSE CAST((100. * ExecutionCount) / @total_execution_count AS MONEY) END AS PercentExecutions,
            CASE  DATEDIFF(mi, PlanCreationTime, LastExecutionTime)
                WHEN 0 THEN 0
                ELSE CAST((1.00 * ExecutionCount / DATEDIFF(mi, PlanCreationTime, LastExecutionTime)) AS MONEY)
            END AS ExecutionsPerMinute
    FROM (
        SELECT  DatabaseName,
                SqlHandle,
                QueryHash,
                TotalCPU,
                TotalDuration,
                TotalReads,
                TotalWrites,
                ExecutionCount,
                PlanCreationTime,
                LastExecutionTime
        FROM    ##bou_BlitzCacheProcs
        GROUP BY DatabaseName,
                SqlHandle,
                QueryHash,
                TotalCPU,
                TotalDuration,
                TotalReads,
                TotalWrites,
                ExecutionCount,
                PlanCreationTime,
                LastExecutionTime
    ) AS x
) AS y
WHERE   ##bou_BlitzCacheProcs.SqlHandle = y.SqlHandle
        AND ##bou_BlitzCacheProcs.QueryHash = y.QueryHash
        AND ##bou_BlitzCacheProcs.DatabaseName = y.DatabaseName
        AND ##bou_BlitzCacheProcs.PlanHandle IS NULL
OPTION (RECOMPILE) ;



/* Testing using XML nodes to speed up processing */
RAISERROR(N'Begin XML nodes processing', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
SELECT  QueryHash ,
        SqlHandle ,
		PlanHandle,
        q.n.query('.') AS statement
INTO    #statements
FROM    ##bou_BlitzCacheProcs p
        CROSS APPLY p.QueryPlan.nodes('//p:StmtSimple') AS q(n) 
OPTION (RECOMPILE) ;

WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
INSERT #statements
SELECT  QueryHash ,
        SqlHandle ,
		PlanHandle,
        q.n.query('.') AS statement
FROM    ##bou_BlitzCacheProcs p
        CROSS APPLY p.QueryPlan.nodes('//p:StmtCursor') AS q(n) 
OPTION (RECOMPILE) ;

WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
SELECT  QueryHash ,
        SqlHandle ,
        q.n.query('.') AS query_plan
INTO    #query_plan
FROM    #statements p
        CROSS APPLY p.statement.nodes('//p:QueryPlan') AS q(n) 
OPTION (RECOMPILE) ;

WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
SELECT  QueryHash ,
        SqlHandle ,
        q.n.query('.') AS relop
INTO    #relop
FROM    #query_plan p
        CROSS APPLY p.query_plan.nodes('//p:RelOp') AS q(n) 
OPTION (RECOMPILE) ;



-- high level plan stuff
RAISERROR(N'Gathering high level plan information', 0, 1) WITH NOWAIT;
UPDATE  ##bou_BlitzCacheProcs
SET     NumberOfDistinctPlans = distinct_plan_count,
        NumberOfPlans = number_of_plans ,
        plan_multiple_plans = CASE WHEN distinct_plan_count < number_of_plans THEN 1 END
FROM (
        SELECT  COUNT(DISTINCT QueryHash) AS distinct_plan_count,
                COUNT(QueryHash) AS number_of_plans,
                QueryHash
        FROM    ##bou_BlitzCacheProcs
        GROUP BY QueryHash
) AS x
WHERE ##bou_BlitzCacheProcs.QueryHash = x.QueryHash
OPTION (RECOMPILE) ;

-- statement level checks
RAISERROR(N'Performing statement level checks', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE ##bou_BlitzCacheProcs
SET     QueryPlanCost = CASE WHEN QueryType LIKE '%Stored Procedure%' THEN
                                statement.value('sum(/p:StmtSimple/@StatementSubTreeCost)', 'float')
                             ELSE
                                statement.value('sum(/p:StmtSimple[xs:hexBinary(substring(@QueryPlanHash, 3)) = xs:hexBinary(sql:column("QueryPlanHash"))]/@StatementSubTreeCost)', 'float')
                        END ,
        compile_timeout = CASE WHEN statement.exist('/p:StmtSimple/@StatementOptmEarlyAbortReason[.="TimeOut"]') = 1 THEN 1 END ,
        compile_memory_limit_exceeded = CASE WHEN statement.exist('/p:StmtSimple/@StatementOptmEarlyAbortReason[.="MemoryLimitExceeded"]') = 1 THEN 1 END ,
        unmatched_index_count = statement.value('count(//p:UnmatchedIndexes/Parameterization/Object)', 'int') ,
        is_trivial = CASE WHEN statement.exist('/p:StmtSimple[@StatementOptmLevel[.="TRIVIAL"]]/p:QueryPlan/p:ParameterList') = 1 THEN 1 END ,
        unparameterized_query = CASE WHEN statement.exist('//p:StmtSimple[@StatementOptmLevel[.="FULL"]]/p:QueryPlan/p:ParameterList') = 1 AND
                                          statement.exist('//p:StmtSimple[@StatementOptmLevel[.="FULL"]]/p:QueryPlan/p:ParameterList/p:ColumnReference') = 0 THEN 1
                                     WHEN statement.exist('//p:StmtSimple[@StatementOptmLevel[.="FULL"]]/p:QueryPlan/p:ParameterList') = 0 AND
                                          statement.exist('//p:StmtSimple[@StatementOptmLevel[.="FULL"]]/*/p:RelOp/descendant::p:ScalarOperator/p:Identifier/p:ColumnReference[contains(@Column, "@")]') = 1 THEN 1
                                END
FROM    #statements s
WHERE   s.QueryHash = ##bou_BlitzCacheProcs.QueryHash
OPTION (RECOMPILE);

--Gather Stored Proc costs
RAISERROR(N'Gathering stored procedure costs', 0, 1) WITH NOWAIT;
;WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
, QueryCost AS (
  SELECT
    statement.value('sum(/p:StmtSimple/@StatementSubTreeCost)', 'float') AS SubTreeCost,
    s.PlanHandle,
	s.SqlHandle
  FROM #statements AS s
  WHERE PlanHandle IS NOT NULL
)
, QueryCostUpdate AS (
  SELECT
	SUM(qc.SubTreeCost) OVER (PARTITION BY SqlHandle, PlanHandle) PlanTotalQuery,
    qc.PlanHandle,
    qc.SqlHandle
  FROM QueryCost qc
    WHERE qc.SubTreeCost > 0
)
  UPDATE b
    SET b.QueryPlanCost = 
    CASE WHEN 
      b.QueryType LIKE '%Procedure%' THEN 
         (SELECT TOP 1 PlanTotalQuery FROM QueryCostUpdate qcu WHERE qcu.PlanHandle = b.PlanHandle ORDER BY PlanTotalQuery DESC)
       ELSE 
         b.QueryPlanCost 
    	 END
  FROM QueryCostUpdate qcu
    JOIN  ##bou_BlitzCacheProcs AS b
  ON qcu.SqlHandle = b.SqlHandle
OPTION (RECOMPILE);

-- query level checks
RAISERROR(N'Performing query level checks', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE  ##bou_BlitzCacheProcs
SET     missing_index_count = query_plan.value('count(/p:QueryPlan/p:MissingIndexes/p:MissingIndexGroup)', 'int') ,
        SerialDesiredMemory = query_plan.value('sum(/p:QueryPlan/p:MemoryGrantInfo/@SerialDesiredMemory)', 'float') ,
        SerialRequiredMemory = query_plan.value('sum(/p:QueryPlan/p:MemoryGrantInfo/@SerialRequiredMemory)', 'float'),
        CachedPlanSize = query_plan.value('sum(/p:QueryPlan/@CachedPlanSize)', 'float') ,
        CompileTime = query_plan.value('sum(/p:QueryPlan/@CompileTime)', 'float') ,
        CompileCPU = query_plan.value('sum(/p:QueryPlan/@CompileCPU)', 'float') ,
        CompileMemory = query_plan.value('sum(/p:QueryPlan/@CompileMemory)', 'float') ,
        implicit_conversions = CASE WHEN query_plan.exist('/p:QueryPlan/p:Warnings/p:PlanAffectingConvert/@Expression[contains(., "CONVERT_IMPLICIT")]') = 1 THEN 1 END ,
        plan_warnings = CASE WHEN query_plan.value('count(/p:QueryPlan/p:Warnings)', 'int') > 0 THEN 1 END,
		is_forced_serial = CASE WHEN query_plan.value('count(/p:QueryPlan/@NonParallelPlanReason)', 'int') > 0 THEN 1 END
FROM    #query_plan qp
WHERE   qp.QueryHash = ##bou_BlitzCacheProcs.QueryHash
OPTION (RECOMPILE);

-- operator level checks
RAISERROR(N'Performing operator level checks', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE p
SET    busy_loops = CASE WHEN (x.estimated_executions / 100.0) > x.estimated_rows THEN 1 END ,
       tvf_join = CASE WHEN x.tvf_join = 1 THEN 1 END ,
       warning_no_join_predicate = CASE WHEN x.no_join_warning = 1 THEN 1 END,
	   is_table_variable = CASE WHEN x.is_table_variable = 1 THEN 1 END,
	   no_stats_warning = CASE WHEN x.no_stats_warning = 1 THEN 1 END,
	   relop_warnings = CASE WHEN x.relop_warnings = 1 THEN 1 END
FROM   ##bou_BlitzCacheProcs p
       JOIN (
            SELECT qs.SqlHandle,
                   relop.value('sum(/p:RelOp/@EstimateRows)', 'float') AS estimated_rows ,
                   relop.value('sum(/p:RelOp/@EstimateRewinds)', 'float') + relop.value('sum(/p:RelOp/@EstimateRebinds)', 'float') + 1.0 AS estimated_executions ,
                   relop.exist('/p:RelOp[contains(@LogicalOp, "Join")]/*/p:RelOp[(@LogicalOp[.="Table-valued function"])]') AS tvf_join,
                   relop.exist('/p:RelOp/p:Warnings[(@NoJoinPredicate[.="1"])]') AS no_join_warning,
				   relop.exist('/p:RelOp//*[local-name() = "Object"]/@Table[contains(., "@")]') AS is_table_variable,
				   relop.exist('/p:RelOp/p:Warnings/p:ColumnsWithNoStatistics') AS no_stats_warning ,
				   relop.exist('/p:RelOp/p:Warnings') AS relop_warnings
            FROM   #relop qs
       ) AS x ON p.SqlHandle = x.SqlHandle
OPTION (RECOMPILE);


RAISERROR(N'Checking for functions', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
, x AS (
SELECT qs.QueryHash,
	   n.fn.value('count(distinct-values(//p:UserDefinedFunction[not(@IsClrFunction)]))', 'INT') AS function_count,
	   n.fn.value('count(distinct-values(//p:UserDefinedFunction[@IsClrFunction = "1"]))', 'INT') AS clr_function_count
FROM   #relop qs
CROSS APPLY relop.nodes('/p:RelOp/p:ComputeScalar/p:DefinedValues/p:DefinedValue/p:ScalarOperator') n(fn)
)
UPDATE p
SET	   p.function_count = x.function_count,
	   p.clr_function_count = x.clr_function_count
FROM ##bou_BlitzCacheProcs AS p
JOIN x ON x.QueryHash = p.QueryHash
OPTION (RECOMPILE);


RAISERROR(N'Checking for expensive key lookups', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE ##bou_BlitzCacheProcs
SET key_lookup_cost = x.key_lookup_cost
FROM (
SELECT 
       qs.SqlHandle,
	   relop.value('sum(/p:RelOp/@EstimatedTotalSubtreeCost)', 'float') AS key_lookup_cost
FROM   #relop qs
WHERE [relop].exist('/p:RelOp/p:IndexScan[(@Lookup[.="1"])]') = 1
) AS x
WHERE ##bou_BlitzCacheProcs.SqlHandle = x.SqlHandle
OPTION (RECOMPILE) ;


RAISERROR(N'Checking for expensive remote queries', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE ##bou_BlitzCacheProcs
SET remote_query_cost = x.remote_query_cost
FROM (
SELECT 
       qs.SqlHandle,
	   relop.value('sum(/p:RelOp/@EstimatedTotalSubtreeCost)', 'float') AS remote_query_cost
FROM   #relop qs
WHERE [relop].exist('/p:RelOp[(@PhysicalOp[contains(., "Remote")])]') = 1
) AS x
WHERE ##bou_BlitzCacheProcs.SqlHandle = x.SqlHandle
OPTION (RECOMPILE) ;

RAISERROR(N'Checking for expensive sorts', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE ##bou_BlitzCacheProcs
SET sort_cost = (x.sort_io + x.sort_cpu) 
FROM (
SELECT 
       qs.SqlHandle,
	   relop.value('sum(/p:RelOp/@EstimateIO)', 'float') AS sort_io,
	   relop.value('sum(/p:RelOp/@EstimateCPU)', 'float') AS sort_cpu
FROM   #relop qs
WHERE [relop].exist('/p:RelOp[(@PhysicalOp[.="Sort"])]') = 1
) AS x
WHERE ##bou_BlitzCacheProcs.SqlHandle = x.SqlHandle
OPTION (RECOMPILE) ;

RAISERROR(N'Checking for icky cursors', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE b
SET b.is_optimistic_cursor =  CASE WHEN n1.fn.exist('//p:CursorPlan/@CursorConcurrency[.="Optimistic"]') = 1 THEN 1 END,
	b.is_forward_only_cursor = CASE WHEN n1.fn.exist('//p:CursorPlan/@ForwardOnly[.="true"]') = 1 THEN 1 ELSE 0 END
FROM ##bou_BlitzCacheProcs b
JOIN #statements AS qs
ON b.QueryHash = qs.QueryHash
CROSS APPLY qs.statement.nodes('/p:StmtCursor') AS n1(fn)
OPTION (RECOMPILE) ;


RAISERROR(N'Checking for bad scans and plan forcing', 0, 1) WITH NOWAIT;
;WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE b
SET 
b.is_table_scan = x.is_table_scan,
b.backwards_scan = x.backwards_scan,
b.forced_index = x.forced_index,
b.forced_seek = x.forced_seek,
b.forced_scan = x.forced_scan
FROM ##bou_BlitzCacheProcs b
JOIN (
SELECT 
       qs.SqlHandle,
	   0 AS is_table_scan,
	   q.n.exist('@ScanDirection[.="BACKWARD"]') AS backwards_scan,
	   q.n.value('@ForcedIndex', 'bit') AS forced_index,
	   q.n.value('@ForceSeek', 'bit') AS forced_seek,
	   q.n.value('@ForceScan', 'bit') AS forced_scan
FROM   #relop qs
CROSS APPLY qs.relop.nodes('//p:IndexScan') AS q(n)
UNION ALL
SELECT 
       qs.SqlHandle,
	   1 AS is_table_scan,
	   q.n.exist('@ScanDirection[.="BACKWARD"]') AS backwards_scan,
	   q.n.value('@ForcedIndex', 'bit') AS forced_index,
	   q.n.value('@ForceSeek', 'bit') AS forced_seek,
	   q.n.value('@ForceScan', 'bit') AS forced_scan
FROM   #relop qs
CROSS APPLY qs.relop.nodes('//p:TableScan') AS q(n)
) AS x ON b.SqlHandle = x.SqlHandle
OPTION (RECOMPILE) ;


RAISERROR(N'Checking for ColumnStore queries operating in Row Mode instead of Batch Mode', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE ##bou_BlitzCacheProcs
SET columnstore_row_mode = x.is_row_mode
FROM (
SELECT 
       qs.SqlHandle,
	   relop.exist('/p:RelOp[(@EstimatedExecutionMode[.="Row"])]') AS is_row_mode
FROM   #relop qs
WHERE [relop].exist('/p:RelOp/p:IndexScan[(@Storage[.="ColumnStore"])]') = 1
) AS x
WHERE ##bou_BlitzCacheProcs.SqlHandle = x.SqlHandle
OPTION (RECOMPILE) ;


RAISERROR(N'Checking for computed columns that reference scalar UDFs', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE ##bou_BlitzCacheProcs
SET is_computed_scalar = x.computed_column_function
FROM (
SELECT qs.SqlHandle,
	   n.fn.value('count(distinct-values(//p:UserDefinedFunction[not(@IsClrFunction)]))', 'INT') AS computed_column_function
FROM   #relop qs
CROSS APPLY relop.nodes('/p:RelOp/p:ComputeScalar/p:DefinedValues/p:DefinedValue/p:ScalarOperator') n(fn)
WHERE n.fn.exist('/p:RelOp/p:ComputeScalar/p:DefinedValues/p:DefinedValue/p:ColumnReference[(@ComputedColumn[.="1"])]') = 1
) AS x
WHERE ##bou_BlitzCacheProcs.SqlHandle = x.SqlHandle
OPTION (RECOMPILE)


IF @v >= 12
BEGIN
    RAISERROR('Checking for downlevel cardinality estimators being used on SQL Server 2014.', 0, 1) WITH NOWAIT;

    WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
    UPDATE  p
    SET     downlevel_estimator = CASE WHEN statement.value('min(//p:StmtSimple/@CardinalityEstimationModelVersion)', 'int') < (@v * 10) THEN 1 END
    FROM    ##bou_BlitzCacheProcs p
            JOIN #statements s ON p.QueryHash = s.QueryHash 
	OPTION (RECOMPILE) ;
END ;

/* END Testing using XML nodes to speed up processing */
RAISERROR(N'Gathering additional plan level information', 0, 1) WITH NOWAIT;
WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE ##bou_BlitzCacheProcs
SET NumberOfDistinctPlans = distinct_plan_count,
    NumberOfPlans = number_of_plans,
    QueryPlanCost = CASE WHEN QueryType LIKE '%Procedure%' THEN
        QueryPlanCost
        ELSE
        QueryPlan.value('sum(//p:StmtSimple[xs:hexBinary(substring(@QueryPlanHash, 3)) = xs:hexBinary(sql:column("QueryPlanHash"))]/@StatementSubTreeCost)', 'float')
        END,
	missing_index_count = QueryPlan.value('count(//p:MissingIndexGroup)', 'int') ,
    unmatched_index_count = QueryPlan.value('count(//p:UnmatchedIndexes/p:Parameterization/p:Object)', 'int') ,
    plan_multiple_plans = CASE WHEN distinct_plan_count < number_of_plans THEN 1 END ,
    is_trivial = CASE WHEN QueryPlan.exist('//p:StmtSimple[@StatementOptmLevel[.="TRIVIAL"]]/p:QueryPlan/p:ParameterList') = 1 THEN 1 END ,
    SerialDesiredMemory = QueryPlan.value('sum(//p:MemoryGrantInfo/@SerialDesiredMemory)', 'float') ,
    SerialRequiredMemory = QueryPlan.value('sum(//p:MemoryGrantInfo/@SerialRequiredMemory)', 'float'),
    CachedPlanSize = QueryPlan.value('sum(//p:QueryPlan/@CachedPlanSize)', 'float') ,
    CompileTime = QueryPlan.value('sum(//p:QueryPlan/@CompileTime)', 'float') ,
    CompileCPU = QueryPlan.value('sum(//p:QueryPlan/@CompileCPU)', 'float') ,
    CompileMemory = QueryPlan.value('sum(//p:QueryPlan/@CompileMemory)', 'float')
FROM (
SELECT COUNT(DISTINCT QueryHash) AS distinct_plan_count,
       COUNT(QueryHash) AS number_of_plans,
       QueryHash
FROM   ##bou_BlitzCacheProcs
GROUP BY QueryHash
) AS x
WHERE ##bou_BlitzCacheProcs.QueryHash = x.QueryHash
OPTION (RECOMPILE) ;

/* Update to grab stored procedure name for individual statements */
RAISERROR(N'Attempting to get stored procedure name for individual statements', 0, 1) WITH NOWAIT;
UPDATE  p
SET     QueryType = QueryType + ' (parent ' +
                    + QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id, s.database_id))
                    + '.'
                    + QUOTENAME(OBJECT_NAME(s.object_id, s.database_id)) + ')'
FROM    ##bou_BlitzCacheProcs p
        JOIN sys.dm_exec_procedure_stats s ON p.SqlHandle = s.sql_handle
WHERE   QueryType = 'Statement'

/* Trace Flag Checks 2014 SP2 and 2016 SP1 only)*/
RAISERROR(N'Trace flag checks', 0, 1) WITH NOWAIT;
;WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
, tf_pretty AS (
SELECT  qp.QueryHash,
		qp.SqlHandle,
		q.n.value('@Value', 'INT') AS trace_flag,
		q.n.value('@Scope', 'VARCHAR(10)') AS scope
FROM    #query_plan qp
CROSS APPLY qp.query_plan.nodes('/p:QueryPlan/p:TraceFlags/p:TraceFlag') AS q(n)
)
SELECT DISTINCT tf1.SqlHandle , tf1.QueryHash,
    STUFF((
          SELECT DISTINCT ', ' + CONVERT(VARCHAR(5), tf2.trace_flag)
          FROM  tf_pretty AS tf2 
          WHERE tf1.SqlHandle = tf2.SqlHandle 
		  AND tf1.QueryHash = tf2.QueryHash
		  AND tf2.scope = 'Global'
        FOR XML PATH(N'')), 1, 2, N''
      ) AS global_trace_flags,
    STUFF((
          SELECT DISTINCT ', ' + CONVERT(VARCHAR(5), tf2.trace_flag)
          FROM  tf_pretty AS tf2 
          WHERE tf1.SqlHandle = tf2.SqlHandle 
		  AND tf1.QueryHash = tf2.QueryHash
		  AND tf2.scope = 'Session'
        FOR XML PATH(N'')), 1, 2, N''
      ) AS session_trace_flags
INTO #trace_flags
FROM tf_pretty AS tf1
OPTION (RECOMPILE);

UPDATE p
SET    p.trace_flags_session = tf.session_trace_flags
FROM   ##bou_BlitzCacheProcs p
JOIN #trace_flags tf ON tf.QueryHash = p.QueryHash --AND tf.SqlHandle = p.PlanHandle
OPTION(RECOMPILE);

IF @SkipAnalysis = 1
    BEGIN
	RAISERROR(N'Skipping analysis, going to results', 0, 1) WITH NOWAIT; 
	GOTO Results ;
	END 


/* Set configuration values */
RAISERROR(N'Setting configuration values', 0, 1) WITH NOWAIT;
DECLARE @execution_threshold INT = 1000 ,
        @parameter_sniffing_warning_pct TINYINT = 30,
        /* This is in average reads */
        @parameter_sniffing_io_threshold BIGINT = 100000 ,
        @ctp_threshold_pct TINYINT = 10,
        @long_running_query_warning_seconds BIGINT = 300 * 1000 ,
		@memory_grant_warning_percent INT = 10;

IF EXISTS (SELECT 1/0 FROM #configuration WHERE 'frequent execution threshold' = LOWER(parameter_name))
BEGIN
    SELECT @execution_threshold = CAST(value AS INT)
    FROM   #configuration
    WHERE  'frequent execution threshold' = LOWER(parameter_name) ;

    SET @msg = ' Setting "frequent execution threshold" to ' + CAST(@execution_threshold AS VARCHAR(10)) ;

    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END

IF EXISTS (SELECT 1/0 FROM #configuration WHERE 'parameter sniffing variance percent' = LOWER(parameter_name))
BEGIN
    SELECT @parameter_sniffing_warning_pct = CAST(value AS TINYINT)
    FROM   #configuration
    WHERE  'parameter sniffing variance percent' = LOWER(parameter_name) ;

    SET @msg = ' Setting "parameter sniffing variance percent" to ' + CAST(@parameter_sniffing_warning_pct AS VARCHAR(3)) ;

    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END

IF EXISTS (SELECT 1/0 FROM #configuration WHERE 'parameter sniffing io threshold' = LOWER(parameter_name))
BEGIN
    SELECT @parameter_sniffing_io_threshold = CAST(value AS BIGINT)
    FROM   #configuration
    WHERE 'parameter sniffing io threshold' = LOWER(parameter_name) ;

    SET @msg = ' Setting "parameter sniffing io threshold" to ' + CAST(@parameter_sniffing_io_threshold AS VARCHAR(10));

    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END

IF EXISTS (SELECT 1/0 FROM #configuration WHERE 'cost threshold for parallelism warning' = LOWER(parameter_name))
BEGIN
    SELECT @ctp_threshold_pct = CAST(value AS TINYINT)
    FROM   #configuration
    WHERE 'cost threshold for parallelism warning' = LOWER(parameter_name) ;

    SET @msg = ' Setting "cost threshold for parallelism warning" to ' + CAST(@ctp_threshold_pct AS VARCHAR(3));

    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END

IF EXISTS (SELECT 1/0 FROM #configuration WHERE 'long running query warning (seconds)' = LOWER(parameter_name))
BEGIN
    SELECT @long_running_query_warning_seconds = CAST(value * 1000 AS BIGINT)
    FROM   #configuration
    WHERE 'long running query warning (seconds)' = LOWER(parameter_name) ;

    SET @msg = ' Setting "long running query warning (seconds)" to ' + CAST(@long_running_query_warning_seconds AS VARCHAR(10));

    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END

IF EXISTS (SELECT 1/0 FROM #configuration WHERE 'unused memory grant' = LOWER(parameter_name))
BEGIN
    SELECT @memory_grant_warning_percent = CAST(value AS INT)
    FROM   #configuration
    WHERE 'unused memory grant' = LOWER(parameter_name) ;

    SET @msg = ' Setting "unused memory grant" to ' + CAST(@memory_grant_warning_percent AS VARCHAR(10));

    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END

DECLARE @ctp INT ;

SELECT  @ctp = NULLIF(CAST(value AS INT), 0)
FROM    sys.configurations
WHERE   name = 'cost threshold for parallelism'
OPTION (RECOMPILE);


/* Update to populate checks columns */
RAISERROR('Checking for query level SQL Server issues.', 0, 1) WITH NOWAIT;

WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
UPDATE ##bou_BlitzCacheProcs
SET    frequent_execution = CASE WHEN ExecutionsPerMinute > @execution_threshold THEN 1 END ,
       parameter_sniffing = CASE WHEN AverageReads > @parameter_sniffing_io_threshold
                                      AND min_worker_time < ((1.0 - (@parameter_sniffing_warning_pct / 100.0)) * AverageCPU) THEN 1
                                 WHEN AverageReads > @parameter_sniffing_io_threshold
                                      AND max_worker_time > ((1.0 + (@parameter_sniffing_warning_pct / 100.0)) * AverageCPU) THEN 1
                                 WHEN AverageReads > @parameter_sniffing_io_threshold
                                      AND MinReturnedRows < ((1.0 - (@parameter_sniffing_warning_pct / 100.0)) * AverageReturnedRows) THEN 1
                                 WHEN AverageReads > @parameter_sniffing_io_threshold
                                      AND MaxReturnedRows > ((1.0 + (@parameter_sniffing_warning_pct / 100.0)) * AverageReturnedRows) THEN 1 END ,
       near_parallel = CASE WHEN QueryPlanCost BETWEEN @ctp * (1 - (@ctp_threshold_pct / 100.0)) AND @ctp THEN 1 END,
       long_running = CASE WHEN AverageDuration > @long_running_query_warning_seconds THEN 1
                           WHEN max_worker_time > @long_running_query_warning_seconds THEN 1
                           WHEN max_elapsed_time > @long_running_query_warning_seconds THEN 1 END,
	   is_key_lookup_expensive = CASE WHEN QueryPlanCost > (@ctp / 2) AND key_lookup_cost >= QueryPlanCost * .5 THEN 1 END,
	   is_sort_expensive = CASE WHEN QueryPlanCost > (@ctp / 2) AND sort_cost >= QueryPlanCost * .5 THEN 1 END,
	   is_remote_query_expensive = CASE WHEN remote_query_cost >= QueryPlanCost * .05 THEN 1 END,
	   is_forced_serial = CASE WHEN is_forced_serial = 1 AND QueryPlanCost > (@ctp / 2) THEN 1 END,
	   is_unused_grant = CASE WHEN PercentMemoryGrantUsed <= @memory_grant_warning_percent AND MinGrantKB > @MinMemoryPerQuery THEN 1 END
OPTION (RECOMPILE) ;



RAISERROR('Checking for forced parameterization and cursors.', 0, 1) WITH NOWAIT;

/* Set options checks */
UPDATE p
       SET is_forced_parameterized = CASE WHEN (CAST(pa.value AS INT) & 131072 = 131072) THEN 1
       END ,
       is_forced_plan = CASE WHEN (CAST(pa.value AS INT) & 4 = 4) THEN 1 
       END ,
       SetOptions = SUBSTRING(
                    CASE WHEN (CAST(pa.value AS INT) & 1 = 1) THEN ', ANSI_PADDING' ELSE '' END +
                    CASE WHEN (CAST(pa.value AS INT) & 8 = 8) THEN ', CONCAT_NULL_YIELDS_NULL' ELSE '' END +
                    CASE WHEN (CAST(pa.value AS INT) & 16 = 16) THEN ', ANSI_WARNINGS' ELSE '' END +
                    CASE WHEN (CAST(pa.value AS INT) & 32 = 32) THEN ', ANSI_NULLS' ELSE '' END +
                    CASE WHEN (CAST(pa.value AS INT) & 64 = 64) THEN ', QUOTED_IDENTIFIER' ELSE '' END +
                    CASE WHEN (CAST(pa.value AS INT) & 4096 = 4096) THEN ', ARITH_ABORT' ELSE '' END +
                    CASE WHEN (CAST(pa.value AS INT) & 8192 = 8191) THEN ', NUMERIC_ROUNDABORT' ELSE '' END 
                    , 2, 200000)
FROM   ##bou_BlitzCacheProcs p
       CROSS APPLY sys.dm_exec_plan_attributes(p.PlanHandle) pa
WHERE  pa.attribute = 'set_options' 
OPTION (RECOMPILE) ;


/* Cursor checks */
UPDATE p
SET    is_cursor = CASE WHEN CAST(pa.value AS INT) <> 0 THEN 1 END
FROM   ##bou_BlitzCacheProcs p
       CROSS APPLY sys.dm_exec_plan_attributes(p.PlanHandle) pa
WHERE  pa.attribute LIKE '%cursor%' 
OPTION (RECOMPILE) ;



RAISERROR('Populating Warnings column', 0, 1) WITH NOWAIT;

/* Populate warnings */
UPDATE ##bou_BlitzCacheProcs
SET    Warnings = CASE WHEN QueryPlan IS NULL THEN 'We couldn''t find a plan for this query. Possible reasons for this include dynamic SQL, RECOMPILE hints, and encrypted code.' ELSE
				  SUBSTRING(
                  CASE WHEN warning_no_join_predicate = 1 THEN ', No Join Predicate' ELSE '' END +
                  CASE WHEN compile_timeout = 1 THEN ', Compilation Timeout' ELSE '' END +
                  CASE WHEN compile_memory_limit_exceeded = 1 THEN ', Compile Memory Limit Exceeded' ELSE '' END +
                  CASE WHEN busy_loops = 1 THEN ', Busy Loops' ELSE '' END +
                  CASE WHEN is_forced_plan = 1 THEN ', Forced Plan' ELSE '' END +
                  CASE WHEN is_forced_parameterized = 1 THEN ', Forced Parameterization' ELSE '' END +
                  CASE WHEN unparameterized_query = 1 THEN ', Unparameterized Query' ELSE '' END +
                  CASE WHEN missing_index_count > 0 THEN ', Missing Indexes (' + CAST(missing_index_count AS VARCHAR(3)) + ')' ELSE '' END +
                  CASE WHEN unmatched_index_count > 0 THEN ', Unmatched Indexes (' + CAST(unmatched_index_count AS VARCHAR(3)) + ')' ELSE '' END +                  
                  CASE WHEN is_cursor = 1 THEN ', Cursor' 
							+ CASE WHEN is_optimistic_cursor = 1 THEN ' with optimistic' ELSE '' END
							+ CASE WHEN is_forward_only_cursor = 0 THEN ' with forward only' ELSE '' END							
				  ELSE '' END +
                  CASE WHEN is_parallel = 1 THEN ', Parallel' ELSE '' END +
                  CASE WHEN near_parallel = 1 THEN ', Nearly Parallel' ELSE '' END +
                  CASE WHEN frequent_execution = 1 THEN ', Frequent Execution' ELSE '' END +
                  CASE WHEN plan_warnings = 1 THEN ', Plan Warnings' ELSE '' END +
                  CASE WHEN parameter_sniffing = 1 THEN ', Parameter Sniffing' ELSE '' END +
                  CASE WHEN long_running = 1 THEN ', Long Running Query' ELSE '' END +
                  CASE WHEN downlevel_estimator = 1 THEN ', Downlevel CE' ELSE '' END +
                  CASE WHEN implicit_conversions = 1 THEN ', Implicit Conversions' ELSE '' END +
                  CASE WHEN tvf_join = 1 THEN ', Function Join' ELSE '' END +
                  CASE WHEN plan_multiple_plans = 1 THEN ', Multiple Plans' ELSE '' END +
                  CASE WHEN is_trivial = 1 THEN ', Trivial Plans' ELSE '' END +
				  CASE WHEN is_forced_serial = 1 THEN ', Forced Serialization' ELSE '' END +
				  CASE WHEN is_key_lookup_expensive = 1 THEN ', Expensive Key Lookup' ELSE '' END +
				  CASE WHEN is_remote_query_expensive = 1 THEN ', Expensive Remote Query' ELSE '' END + 
				  CASE WHEN trace_flags_session IS NOT NULL THEN ', Session Level Trace Flag(s) Enabled: ' + trace_flags_session ELSE '' END +
				  CASE WHEN is_unused_grant = 1 THEN ', Unused Memory Grant' ELSE '' END +
				  CASE WHEN function_count > 0 THEN ', Calls ' + CONVERT(VARCHAR(10), function_count) + ' function(s)' ELSE '' END + 
				  CASE WHEN clr_function_count > 0 THEN ', Calls ' + CONVERT(VARCHAR(10), clr_function_count) + ' CLR function(s)' ELSE '' END + 
				  CASE WHEN PlanCreationTimeHours <= 4 THEN ', Plan created last 4hrs' ELSE '' END +
				  CASE WHEN is_table_variable = 1 THEN ', Table Variables' ELSE '' END +
				  CASE WHEN no_stats_warning = 1 THEN ', Columns With No Statistics' ELSE '' END +
				  CASE WHEN relop_warnings = 1 THEN ', Operator Warnings' ELSE '' END  + 
				  CASE WHEN is_table_scan = 1 THEN ', Table Scans' ELSE '' END  + 
				  CASE WHEN backwards_scan = 1 THEN ', Backwards Scans' ELSE '' END  + 
				  CASE WHEN forced_index = 1 THEN ', Forced Indexes' ELSE '' END  + 
				  CASE WHEN forced_seek = 1 THEN ', Forced Seeks' ELSE '' END  + 
				  CASE WHEN forced_scan = 1 THEN ', Forced Scans' ELSE '' END  +
				  CASE WHEN columnstore_row_mode = 1 THEN ', ColumnStore Row Mode ' ELSE '' END +
				  CASE WHEN is_computed_scalar = 1 THEN ', Computed Column UDF ' ELSE '' END  +
				  CASE WHEN is_sort_expensive = 1 THEN ', Expensive Sort' ELSE '' END 
                  , 2, 200000) 
				  END
				  OPTION (RECOMPILE) ;






Results:
IF @OutputDatabaseName IS NOT NULL
   AND @OutputSchemaName IS NOT NULL
   AND @OutputTableName IS NOT NULL
BEGIN
    RAISERROR('Writing results to table.', 0, 1) WITH NOWAIT;

    /* send results to a table */
    DECLARE @insert_sql NVARCHAR(MAX) = N'' ;

    SET @insert_sql = 'USE '
        + @OutputDatabaseName
        + '; IF EXISTS(SELECT * FROM '
        + @OutputDatabaseName
        + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
        + @OutputSchemaName
        + ''') AND NOT EXISTS (SELECT * FROM '
        + @OutputDatabaseName
        + '.INFORMATION_SCHEMA.TABLES WHERE QUOTENAME(TABLE_SCHEMA) = '''
        + @OutputSchemaName + ''' AND QUOTENAME(TABLE_NAME) = '''
        + @OutputTableName + ''') CREATE TABLE '
        + @OutputSchemaName + '.'
        + @OutputTableName
        + N'(ID bigint NOT NULL IDENTITY(1,1),
          ServerName nvarchar(256),
		  CheckDate DATETIMEOFFSET,
          Version nvarchar(256),
          QueryType nvarchar(256),
          Warnings varchar(max),
          DatabaseName sysname,
          SerialDesiredMemory float,
          SerialRequiredMemory float,
          AverageCPU bigint,
          TotalCPU bigint,
          PercentCPUByType money,
          CPUWeight money,
          AverageDuration bigint,
          TotalDuration bigint,
          DurationWeight money,
          PercentDurationByType money,
          AverageReads bigint,
          TotalReads bigint,
          ReadWeight money,
          PercentReadsByType money,
          AverageWrites bigint,
          TotalWrites bigint,
          WriteWeight money,
          PercentWritesByType money,
          ExecutionCount bigint,
          ExecutionWeight money,
          PercentExecutionsByType money,' + N'
          ExecutionsPerMinute money,
          PlanCreationTime datetime,
		  PlanCreationTimeHours AS DATEDIFF(HOUR, PlanCreationTime, SYSDATETIME()),
          LastExecutionTime datetime,
		  PlanHandle varbinary(64),
		  [Remove Plan Handle From Cache] AS 
			CASE WHEN [PlanHandle] IS NOT NULL 
			THEN ''DBCC FREEPROCCACHE ('' + CONVERT(VARCHAR(128), [PlanHandle], 1) + '');''
			ELSE ''N/A'' END,
		  SqlHandle varbinary(64),
			[Remove SQL Handle From Cache] AS 
			CASE WHEN [SqlHandle] IS NOT NULL 
			THEN ''DBCC FREEPROCCACHE ('' + CONVERT(VARCHAR(128), [SqlHandle], 1) + '');''
			ELSE ''N/A'' END,
		  [SQL Handle More Info] AS 
			CASE WHEN [SqlHandle] IS NOT NULL 
			THEN ''EXEC sp_BlitzCache @OnlySqlHandles = '''''' + CONVERT(VARCHAR(128), [SqlHandle], 1) + ''''''; ''
			ELSE ''N/A'' END,
		  QueryHash binary(8),
		  [Query Hash More Info] AS 
			CASE WHEN [QueryHash] IS NOT NULL 
			THEN ''EXEC sp_BlitzCache @OnlyQueryHashes = '''''' + CONVERT(VARCHAR(32), [QueryHash], 1) + ''''''; ''
			ELSE ''N/A'' END,
          QueryPlanHash binary(8),
          StatementStartOffset int,
          StatementEndOffset int,
          MinReturnedRows bigint,
          MaxReturnedRows bigint,
          AverageReturnedRows money,
          TotalReturnedRows bigint,
          QueryText nvarchar(max),
          QueryPlan xml,
          NumberOfPlans int,
          NumberOfDistinctPlans int,
		  MinGrantKB BIGINT,
		  MaxGrantKB BIGINT,
		  MinUsedGrantKB BIGINT, 
		  MaxUsedGrantKB BIGINT,
		  PercentMemoryGrantUsed MONEY,
		  AvgMaxMemoryGrant MONEY,
		  QueryPlanCost FLOAT,
          CONSTRAINT [PK_' +CAST(NEWID() AS NCHAR(36)) + '] PRIMARY KEY CLUSTERED(ID))';

    EXEC sp_executesql @insert_sql ;


    SET @insert_sql =N' IF EXISTS(SELECT * FROM '
          + @OutputDatabaseName
          + N'.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
          + @OutputSchemaName + N''') '
          + 'INSERT '
          + @OutputDatabaseName + '.'
          + @OutputSchemaName + '.'
          + @OutputTableName
          + N' (ServerName, CheckDate, Version, QueryType, DatabaseName, AverageCPU, TotalCPU, PercentCPUByType, CPUWeight, AverageDuration, TotalDuration, DurationWeight, PercentDurationByType, AverageReads, TotalReads, ReadWeight, PercentReadsByType, '
          + N' AverageWrites, TotalWrites, WriteWeight, PercentWritesByType, ExecutionCount, ExecutionWeight, PercentExecutionsByType, '
          + N' ExecutionsPerMinute, PlanCreationTime, LastExecutionTime, PlanHandle, SqlHandle, QueryHash, StatementStartOffset, StatementEndOffset, MinReturnedRows, MaxReturnedRows, AverageReturnedRows, TotalReturnedRows, QueryText, QueryPlan, NumberOfPlans, NumberOfDistinctPlans, Warnings, '
          + N' SerialRequiredMemory, SerialDesiredMemory, MinGrantKB, MaxGrantKB, MinUsedGrantKB, MaxUsedGrantKB, PercentMemoryGrantUsed, AvgMaxMemoryGrant, QueryPlanCost ) '
          + N'SELECT TOP (@Top) '
          + QUOTENAME(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128)), N'''') + N', SYSDATETIMEOFFSET(),'
          + QUOTENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), N'''') + ', '
          + N' QueryType, DatabaseName, AverageCPU, TotalCPU, PercentCPUByType, PercentCPU, AverageDuration, TotalDuration, PercentDuration, PercentDurationByType, AverageReads, TotalReads, PercentReads, PercentReadsByType, '
          + N' AverageWrites, TotalWrites, PercentWrites, PercentWritesByType, ExecutionCount, PercentExecutions, PercentExecutionsByType, '
          + N' ExecutionsPerMinute, PlanCreationTime, LastExecutionTime, PlanHandle, SqlHandle, QueryHash, StatementStartOffset, StatementEndOffset, MinReturnedRows, MaxReturnedRows, AverageReturnedRows, TotalReturnedRows, QueryText, QueryPlan, NumberOfPlans, NumberOfDistinctPlans, Warnings, '
          + N' SerialRequiredMemory, SerialDesiredMemory, MinGrantKB, MaxGrantKB, MinUsedGrantKB, MaxUsedGrantKB, PercentMemoryGrantUsed, AvgMaxMemoryGrant, QueryPlanCost '
          + N' FROM ##bou_BlitzCacheProcs '
          
    SELECT @insert_sql += N' ORDER BY ' + CASE @SortOrder WHEN 'cpu' THEN N' TotalCPU '
                                                    WHEN 'reads' THEN N' TotalReads '
                                                    WHEN 'writes' THEN N' TotalWrites '
                                                    WHEN 'duration' THEN N' TotalDuration '
                                                    WHEN 'executions' THEN N' ExecutionCount '
                                                    WHEN 'compiles' THEN N' PlanCreationTime '
													WHEN 'memory grant' THEN N' MaxGrantKB'
                                                    WHEN 'avg cpu' THEN N' AverageCPU'
                                                    WHEN 'avg reads' THEN N' AverageReads'
                                                    WHEN 'avg writes' THEN N' AverageWrites'
                                                    WHEN 'avg duration' THEN N' AverageDuration'
                                                    WHEN 'avg executions' THEN N' ExecutionsPerMinute'
													WHEN 'avg memory grant' THEN N' AvgMaxMemoryGrant'
                                                    END + N' DESC '

    SET @insert_sql += N' OPTION (RECOMPILE) ; '    
    
    EXEC sp_executesql @insert_sql, N'@Top INT', @Top;

    RETURN
END
ELSE IF @ExportToExcel = 1
BEGIN
    RAISERROR('Displaying results with Excel formatting (no plans).', 0, 1) WITH NOWAIT;

    /* excel output */
    UPDATE ##bou_BlitzCacheProcs
    SET QueryText = SUBSTRING(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(QueryText)),' ','<>'),'><',''),'<>',' '), 1, 32000);

    SET @sql = N'
    SELECT  TOP (@Top)
            DatabaseName AS [Database Name],
            QueryPlanCost AS [Cost],
            QueryText,
            QueryType AS [Query Type],
            Warnings,
            ExecutionCount,
            ExecutionsPerMinute AS [Executions / Minute],
            PercentExecutions AS [Execution Weight],
            PercentExecutionsByType AS [% Executions (Type)],
            SerialDesiredMemory AS [Serial Desired Memory],
            SerialRequiredMemory AS [Serial Required Memory],
            TotalCPU AS [Total CPU (ms)],
            AverageCPU AS [Avg CPU (ms)],
            PercentCPU AS [CPU Weight],
            PercentCPUByType AS [% CPU (Type)],
            TotalDuration AS [Total Duration (ms)],
            AverageDuration AS [Avg Duration (ms)],
            PercentDuration AS [Duration Weight],
            PercentDurationByType AS [% Duration (Type)],
            TotalReads AS [Total Reads],
            AverageReads AS [Average Reads],
            PercentReads AS [Read Weight],
            PercentReadsByType AS [% Reads (Type)],
            TotalWrites AS [Total Writes],
            AverageWrites AS [Average Writes],
            PercentWrites AS [Write Weight],
            PercentWritesByType AS [% Writes (Type)],
            TotalReturnedRows,
            AverageReturnedRows,
            MinReturnedRows,
            MaxReturnedRows,
		    MinGrantKB,
		    MaxGrantKB,
		    MinUsedGrantKB, 
		    MaxUsedGrantKB,
		    PercentMemoryGrantUsed,
			AvgMaxMemoryGrant,
            NumberOfPlans,
            NumberOfDistinctPlans,
            PlanCreationTime AS [Created At],
            LastExecutionTime AS [Last Execution],
            StatementStartOffset,
            StatementEndOffset,
			PlanHandle AS [Plan Handle],  
			SqlHandle AS [SQL Handle],  
            QueryHash,
            QueryPlanHash,
            COALESCE(SetOptions, '''') AS [SET Options]
    FROM    ##bou_BlitzCacheProcs
    WHERE   1 = 1 ' + @nl

    SELECT @sql += N' ORDER BY ' + CASE @SortOrder WHEN 'cpu' THEN ' TotalCPU '
                              WHEN 'reads' THEN ' TotalReads '
                              WHEN 'writes' THEN ' TotalWrites '
                              WHEN 'duration' THEN ' TotalDuration '
                              WHEN 'executions' THEN ' ExecutionCount '
                              WHEN 'compiles' THEN ' PlanCreationTime '
							  WHEN 'memory grant' THEN 'MaxGrantKB'
                              WHEN 'avg cpu' THEN 'AverageCPU'
                              WHEN 'avg reads' THEN 'AverageReads'
                              WHEN 'avg writes' THEN 'AverageWrites'
                              WHEN 'avg duration' THEN 'AverageDuration'
                              WHEN 'avg executions' THEN 'ExecutionsPerMinute'
							  WHEN 'avg memory grant' THEN 'AvgMaxMemoryGrant'
                              END + N' DESC '

    SET @sql += N' OPTION (RECOMPILE) ; '

    EXEC sp_executesql @sql, N'@Top INT', @Top ;
END


RAISERROR('Displaying analysis of plan cache.', 0, 1) WITH NOWAIT;

DECLARE @columns NVARCHAR(MAX) = N'' ;

IF @ExpertMode = 0
BEGIN
    RAISERROR(N'Returning ExpertMode = 0', 0, 1) WITH NOWAIT;
	SET @columns = N' DatabaseName AS [Database],
    QueryPlanCost AS [Cost],
    QueryText AS [Query Text],
    QueryType AS [Query Type],
    Warnings AS [Warnings],
    ExecutionCount AS [# Executions],
    ExecutionsPerMinute AS [Executions / Minute],
    PercentExecutions AS [Execution Weight],
    TotalCPU AS [Total CPU (ms)],
    AverageCPU AS [Avg CPU (ms)],
    PercentCPU AS [CPU Weight],
    TotalDuration AS [Total Duration (ms)],
    AverageDuration AS [Avg Duration (ms)],
    PercentDuration AS [Duration Weight],
    TotalReads AS [Total Reads],
    AverageReads AS [Avg Reads],
    PercentReads AS [Read Weight],
    TotalWrites AS [Total Writes],
    AverageWrites AS [Avg Writes],
    PercentWrites AS [Write Weight],
    AverageReturnedRows AS [Average Rows],
	MinGrantKB AS [Minimum Memory Grant KB],
	MaxGrantKB AS [Maximum Memory Grant KB],
	MinUsedGrantKB AS [Minimum Used Grant KB], 
	MaxUsedGrantKB AS [Maximum Used Grant KB],
	AvgMaxMemoryGrant AS [Average Max Memory Grant],
    PlanCreationTime AS [Created At],
    LastExecutionTime AS [Last Execution],
	PlanHandle AS [Plan Handle], 
	SqlHandle AS [SQL Handle], 
    QueryPlan AS [Query Plan],
    COALESCE(SetOptions, '''') AS [SET Options] ';
END
ELSE
BEGIN
    SET @columns = N' DatabaseName AS [Database],
        QueryText AS [Query Text],
        QueryType AS [Query Type],
        Warnings AS [Warnings], ' + @nl

    IF @ExpertMode = 2 /* Opserver */
    BEGIN
        RAISERROR(N'Returning Expert Mode = 2', 0, 1) WITH NOWAIT;
		SET @columns += N'        
				  CASE WHEN QueryPlan IS NULL THEN ''We couldn''''t find a plan for this query. Possible reasons for this include dynamic SQL, RECOMPILE hints, and encrypted code.'' ELSE
				  SUBSTRING(
                  CASE WHEN warning_no_join_predicate = 1 THEN '', 20'' ELSE '''' END +
                  CASE WHEN compile_timeout = 1 THEN '', 18'' ELSE '''' END +
                  CASE WHEN compile_memory_limit_exceeded = 1 THEN '', 19'' ELSE '''' END +
                  CASE WHEN busy_loops = 1 THEN '', 16'' ELSE '''' END +
                  CASE WHEN is_forced_plan = 1 THEN '', 3'' ELSE '''' END +
                  CASE WHEN is_forced_parameterized > 0 THEN '', 5'' ELSE '''' END +
                  CASE WHEN unparameterized_query = 1 THEN '', 23'' ELSE '''' END +
                  CASE WHEN missing_index_count > 0 THEN '', 10'' ELSE '''' END +
                  CASE WHEN unmatched_index_count > 0 THEN '', 22'' ELSE '''' END +                  
                  CASE WHEN is_cursor = 1 THEN '', 4'' ELSE '''' END +
                  CASE WHEN is_parallel = 1 THEN '', 6'' ELSE '''' END +
                  CASE WHEN near_parallel = 1 THEN '', 7'' ELSE '''' END +
                  CASE WHEN frequent_execution = 1 THEN '', 1'' ELSE '''' END +
                  CASE WHEN plan_warnings = 1 THEN '', 8'' ELSE '''' END +
                  CASE WHEN parameter_sniffing = 1 THEN '', 2'' ELSE '''' END +
                  CASE WHEN long_running = 1 THEN '', 9'' ELSE '''' END +
                  CASE WHEN downlevel_estimator = 1 THEN '', 13'' ELSE '''' END +
                  CASE WHEN implicit_conversions = 1 THEN '', 14'' ELSE '''' END +
                  CASE WHEN tvf_join = 1 THEN '', 17'' ELSE '''' END +
                  CASE WHEN plan_multiple_plans = 1 THEN '', 21'' ELSE '''' END +
                  CASE WHEN unmatched_index_count > 0 THEN '', 22'' ELSE '''' END + 
                  CASE WHEN is_trivial = 1 THEN '', 24'' ELSE '''' END + 
				  CASE WHEN is_forced_serial = 1 THEN '', 25'' ELSE '''' END +
                  CASE WHEN is_key_lookup_expensive = 1 THEN '', 26'' ELSE '''' END +
				  CASE WHEN is_remote_query_expensive = 1 THEN '', 28'' ELSE '''' END + 
				  CASE WHEN trace_flags_session IS NOT NULL THEN '', 29'' ELSE '''' END + 
				  CASE WHEN is_unused_grant = 1 THEN '', 30'' ELSE '''' END +
				  CASE WHEN function_count > 0 IS NOT NULL THEN '', 31'' ELSE '''' END +
				  CASE WHEN clr_function_count > 0 THEN '', 32'' ELSE '''' END +
				  CASE WHEN PlanCreationTimeHours <= 4 THEN '', 33'' ELSE '''' END +
				  CASE WHEN is_table_variable = 1 THEN '', 34'' ELSE '''' END  + 
				  CASE WHEN no_stats_warning = 1 THEN '', 35'' ELSE '''' END  +
				  CASE WHEN relop_warnings = 1 THEN '', 36'' ELSE '''' END +
				  CASE WHEN is_table_scan = 1 THEN '', 37'' ELSE '''' END +
				  CASE WHEN backwards_scan = 1 THEN '', 38'' ELSE '''' END + 
				  CASE WHEN forced_index = 1 THEN '', 39'' ELSE '''' END +
				  CASE WHEN forced_seek = 1 OR forced_scan = 1 THEN '', 40'' ELSE '''' END +
				  CASE WHEN columnstore_row_mode = 1 THEN '', 41 '' ELSE '' END + 
				  CASE WHEN is_computed_scalar = 1 THEN '', 42 '' ELSE '' END +
				  CASE WHEN is_sort_expensive = 1 THEN '', 43'' ELSE '''' END
				  , 2, 200000) END AS opserver_warning , ' + @nl ;
    END
    
    SET @columns += N'        ExecutionCount AS [# Executions],
        ExecutionsPerMinute AS [Executions / Minute],
        PercentExecutions AS [Execution Weight],
        SerialDesiredMemory AS [Serial Desired Memory],
        SerialRequiredMemory AS [Serial Required Memory],
        TotalCPU AS [Total CPU (ms)],
        AverageCPU AS [Avg CPU (ms)],
        PercentCPU AS [CPU Weight],
        TotalDuration AS [Total Duration (ms)],
        AverageDuration AS [Avg Duration (ms)],
        PercentDuration AS [Duration Weight],
        TotalReads AS [Total Reads],
        AverageReads AS [Average Reads],
        PercentReads AS [Read Weight],
        TotalWrites AS [Total Writes],
        AverageWrites AS [Average Writes],
        PercentWrites AS [Write Weight],
        PercentExecutionsByType AS [% Executions (Type)],
        PercentCPUByType AS [% CPU (Type)],
        PercentDurationByType AS [% Duration (Type)],
        PercentReadsByType AS [% Reads (Type)],
        PercentWritesByType AS [% Writes (Type)],
        TotalReturnedRows AS [Total Rows],
        AverageReturnedRows AS [Avg Rows],
        MinReturnedRows AS [Min Rows],
        MaxReturnedRows AS [Max Rows],
		MinGrantKB AS [Minimum Memory Grant KB],
		MaxGrantKB AS [Maximum Memory Grant KB],
		MinUsedGrantKB AS [Minimum Used Grant KB], 
		MaxUsedGrantKB AS [Maximum Used Grant KB],
		AvgMaxMemoryGrant AS [Average Max Memory Grant],
        NumberOfPlans AS [# Plans],
        NumberOfDistinctPlans AS [# Distinct Plans],
        PlanCreationTime AS [Created At],
        LastExecutionTime AS [Last Execution],
        QueryPlanCost AS [Query Plan Cost],
        QueryPlan AS [Query Plan],
        CachedPlanSize AS [Cached Plan Size (KB)],
        CompileTime AS [Compile Time (ms)],
        CompileCPU AS [Compile CPU (ms)],
        CompileMemory AS [Compile memory (KB)],
        COALESCE(SetOptions, '''') AS [SET Options],
		PlanHandle AS [Plan Handle], 
		SqlHandle AS [SQL Handle], 
		[SQL Handle More Info],
        QueryHash AS [Query Hash],
		[Query Hash More Info],
        QueryPlanHash AS [Query Plan Hash],
        StatementStartOffset,
        StatementEndOffset,
		[Remove Plan Handle From Cache],
		[Remove SQL Handle From Cache] ';
END



SET @sql = N'
SELECT  TOP (@Top) ' + @columns + @nl + N'
FROM    ##bou_BlitzCacheProcs
WHERE   SPID = @spid ' + @nl

SELECT @sql += N' ORDER BY ' + CASE @SortOrder WHEN 'cpu' THEN N' TotalCPU '
                                                WHEN 'reads' THEN N' TotalReads '
                                                WHEN 'writes' THEN N' TotalWrites '
                                                WHEN 'duration' THEN N' TotalDuration '
                                                WHEN 'executions' THEN N' ExecutionCount '
                                                WHEN 'compiles' THEN N' PlanCreationTime '
												WHEN 'memory grant' THEN N' MaxGrantKB'
                                                WHEN 'avg cpu' THEN N' AverageCPU'
                                                WHEN 'avg reads' THEN N' AverageReads'
                                                WHEN 'avg writes' THEN N' AverageWrites'
                                                WHEN 'avg duration' THEN N' AverageDuration'
                                                WHEN 'avg executions' THEN N' ExecutionsPerMinute'
												WHEN 'avg memory grant' THEN N' AvgMaxMemoryGrant'
                               END + N' DESC '
SET @sql += N' OPTION (RECOMPILE) ; '


EXEC sp_executesql @sql, N'@Top INT, @spid INT', @Top, @@SPID ;

IF @HideSummary = 0 AND @ExportToExcel = 0
BEGIN
    IF @Reanalyze = 0
    BEGIN
        RAISERROR('Building query plan summary data.', 0, 1) WITH NOWAIT;

        /* Build summary data */
        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE frequent_execution = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    1,
                    100,
                    'Execution Pattern',
                    'Frequently Executed Queries',
                    'http://brentozar.com/blitzcache/frequently-executed-queries/',
                    'Queries are being executed more than '
                    + CAST (@execution_threshold AS VARCHAR(5))
                    + ' times per minute. This can put additional load on the server, even when queries are lightweight.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  parameter_sniffing = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    2,
                    50,
                    'Parameterization',
                    'Parameter Sniffing',
                    'http://brentozar.com/blitzcache/parameter-sniffing/',
                    'There are signs of parameter sniffing (wide variance in rows return or time to execute). Investigate query patterns and tune code appropriately.') ;

        /* Forced execution plans */
        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  is_forced_plan = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    3,
                    5,
                    'Parameterization',
                    'Forced Plans',
                    'http://brentozar.com/blitzcache/forced-plans/',
                    'Execution plans have been compiled with forced plans, either through FORCEPLAN, plan guides, or forced parameterization. This will make general tuning efforts less effective.');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  is_cursor = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    4,
                    200,
                    'Cursors',
                    'Cursors',
                    'http://brentozar.com/blitzcache/cursors-found-slow-queries/',
                    'There are cursors in the plan cache. This is neither good nor bad, but it is a thing. Cursors are weird in SQL Server.');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  is_cursor = 1
				   AND is_optimistic_cursor = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    4,
                    200,
                    'Cursors',
                    'Optimistic Cursors',
                    'http://brentozar.com/blitzcache/cursors-found-slow-queries/',
                    'There are optimistic cursors in the plan cache, which can harm performance.');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  is_cursor = 1
				   AND is_forward_only_cursor = 0
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    4,
                    200,
                    'Cursors',
                    'Non-forward Only Cursors',
                    'http://brentozar.com/blitzcache/cursors-found-slow-queries/',
                    'There are non-forward only cursors in the plan cache, which can harm performance.');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  is_forced_parameterized = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    5,
                    50,
                    'Parameterization',
                    'Forced Parameterization',
                    'http://brentozar.com/blitzcache/forced-parameterization/',
                    'Execution plans have been compiled with forced parameterization.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.is_parallel = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    6,
                    200,
                    'Execution Plans',
                    'Parallelism',
                    'http://brentozar.com/blitzcache/parallel-plans-detected/',
                    'Parallel plans detected. These warrant investigation, but are neither good nor bad.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  near_parallel = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    7,
                    200,
                    'Execution Plans',
                    'Nearly Parallel',
                    'http://brentozar.com/blitzcache/query-cost-near-cost-threshold-parallelism/',
                    'Queries near the cost threshold for parallelism. These may go parallel when you least expect it.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  plan_warnings = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    8,
                    50,
                    'Execution Plans',
                    'Query Plan Warnings',
                    'http://brentozar.com/blitzcache/query-plan-warnings/',
                    'Warnings detected in execution plans. SQL Server is telling you that something bad is going on that requires your attention.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  long_running = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    9,
                    50,
                    'Performance',
                    'Long Running Queries',
                    'http://brentozar.com/blitzcache/long-running-queries/',
                    'Long running queries have been found. These are queries with an average duration longer than '
                    + CAST(@long_running_query_warning_seconds / 1000 / 1000 AS VARCHAR(5))
                    + ' second(s). These queries should be investigated for additional tuning options') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.missing_index_count > 0
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    10,
                    50,
                    'Performance',
                    'Missing Index Request',
                    'http://brentozar.com/blitzcache/missing-index-request/',
                    'Queries found with missing indexes.');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.downlevel_estimator = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    13,
                    200,
                    'Cardinality',
                    'Legacy Cardinality Estimator in Use',
                    'http://brentozar.com/blitzcache/legacy-cardinality-estimator/',
                    'A legacy cardinality estimator is being used by one or more queries. Investigate whether you need to be using this cardinality estimator. This may be caused by compatibility levels, global trace flags, or query level trace flags.');

        IF EXISTS (SELECT 1/0
                   FROM ##bou_BlitzCacheProcs p
                   WHERE implicit_conversions = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    14,
                    50,
                    'Performance',
                    'Implicit Conversions',
                    'http://brentozar.com/go/implicit',
                    'One or more queries are comparing two fields that are not of the same data type.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  busy_loops = 1
				   AND SPID = @@SPID)
        INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
        VALUES (@@SPID,
                16,
                10,
                'Performance',
                'Frequently executed operators',
                'http://brentozar.com/blitzcache/busy-loops/',
                'Operations have been found that are executed 100 times more often than the number of rows returned by each iteration. This is an indicator that something is off in query execution.');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  tvf_join = 1
				   AND SPID = @@SPID)
        INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
        VALUES (@@SPID,
                17,
                50,
                'Performance',
                'Joining to table valued functions',
                'http://brentozar.com/blitzcache/tvf-join/',
                'Execution plans have been found that join to table valued functions (TVFs). TVFs produce inaccurate estimates of the number of rows returned and can lead to any number of query plan problems.');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  compile_timeout = 1
				   AND SPID = @@SPID)
        INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
        VALUES (@@SPID,
                18,
                50,
                'Execution Plans',
                'Compilation timeout',
                'http://brentozar.com/blitzcache/compilation-timeout/',
                'Query compilation timed out for one or more queries. SQL Server did not find a plan that meets acceptable performance criteria in the time allotted so the best guess was returned. There is a very good chance that this plan isn''t even below average - it''s probably terrible.');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  compile_memory_limit_exceeded = 1
				   AND SPID = @@SPID)
        INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
        VALUES (@@SPID,
                19,
                50,
                'Execution Plans',
                'Compilation memory limit exceeded',
                'http://brentozar.com/blitzcache/compile-memory-limit-exceeded/',
                'The optimizer has a limited amount of memory available. One or more queries are complex enough that SQL Server was unable to allocate enough memory to fully optimize the query. A best fit plan was found, and it''s probably terrible.');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  warning_no_join_predicate = 1
				   AND SPID = @@SPID)
        INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
        VALUES (@@SPID,
                20,
                10,
                'Execution Plans',
                'No join predicate',
                'http://brentozar.com/blitzcache/no-join-predicate/',
                'Operators in a query have no join predicate. This means that all rows from one table will be matched with all rows from anther table producing a Cartesian product. That''s a whole lot of rows. This may be your goal, but it''s important to investigate why this is happening.');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  plan_multiple_plans = 1
				   AND SPID = @@SPID)
        INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
        VALUES (@@SPID,
                21,
                200,
                'Execution Plans',
                'Multiple execution plans',
                'http://brentozar.com/blitzcache/multiple-plans/',
                'Queries exist with multiple execution plans (as determined by query_plan_hash). Investigate possible ways to parameterize these queries or otherwise reduce the plan count/');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  unmatched_index_count > 0
				   AND SPID = @@SPID)
        INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
        VALUES (@@SPID,
                22,
                100,
                'Performance',
                'Unmatched indexes',
                'http://brentozar.com/blitzcache/unmatched-indexes',
                'An index could have been used, but SQL Server chose not to use it - likely due to parameterization and filtered indexes.');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  unparameterized_query = 1
				   AND SPID = @@SPID)
        INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
        VALUES (@@SPID,
                23,
                100,
                'Parameterization',
                'Unparameterized queries',
                'http://brentozar.com/blitzcache/unparameterized-queries',
                'Unparameterized queries found. These could be ad hoc queries, data exploration, or queries using "OPTIMIZE FOR UNKNOWN".');

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs
                   WHERE  is_trivial = 1
				   AND SPID = @@SPID)
        INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
        VALUES (@@SPID,
                24,
                100,
                'Execution Plans',
                'Trivial Plans',
                'http://brentozar.com/blitzcache/trivial-plans',
                'Trivial plans get almost no optimization. If you''re finding these in the top worst queries, something may be going wrong.');
    
        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.is_forced_serial= 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    25,
                    10,
                    'Execution Plans',
                    'Forced Serialization',
                    'http://www.brentozar.com/blitzcache/forced-serialization/',
                    'Something in your plan is forcing a serial query. Further investigation is needed if this is not by design.') ;	

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.is_key_lookup_expensive= 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    26,
                    100,
                    'Execution Plans',
                    'Expensive Key Lookups',
                    'http://www.brentozar.com/blitzcache/expensive-key-lookups/',
                    'There''s a key lookup in your plan that costs >=50% of the total plan cost.') ;	

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.is_remote_query_expensive= 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    28,
                    100,
                    'Execution Plans',
                    'Expensive Remote Query',
                    'http://www.brentozar.com/blitzcache/expensive-remote-query/',
                    'There''s a remote query in your plan that costs >=50% of the total plan cost.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.trace_flags_session IS NOT NULL
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    29,
                    100,
                    'Trace Flags',
                    'Session Level Trace Flags Enabled',
                    'https://www.brentozar.com/blitz/trace-flags-enabled-globally/',
                    'Someone is enabling session level Trace Flags in a query.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.is_unused_grant IS NOT NULL
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    30,
                    100,
                    'Unused memory grants',
                    'Queries are asking for more memory than they''re using',
                    'https://www.brentozar.com/blitzcache/unused-memory-grants/',
                    'Queries have large unused memory grants. This can cause concurrency issues, if queries are waiting a long time to get memory to run.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.function_count > 0
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    31,
                    100,
                    'Compute Scalar That References A Function',
                    'This could be trouble if you''re using Scalar Functions or MSTVFs',
                    'https://www.brentozar.com/blitzcache/compute-scalar-functions/',
                    'Both of these will force queries to run serially, run at least once per row, and may result in poor cardinality estimates') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.clr_function_count > 0
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    32,
                    100,
                    'Compute Scalar That References A CLR Function',
                    'This could be trouble if your CLR functions perform data access',
                    'https://www.brentozar.com/blitzcache/compute-scalar-functions/',
                    'May force queries to run serially, run at least once per row, and may result in poor cardinlity estimates') ;


        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.is_table_variable = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    33,
                    100,
                    'Table Variables detected',
                    'Beware nasty side effects',
                    'https://www.brentozar.com/blitzcache/table-variables/',
                    'All modifications are single threaded, and selects have really low row estimates.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.no_stats_warning = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    35,
                    100,
                    'Columns with no statistics',
                    'Poor cardinality estimates may ensue',
                    'https://www.brentozar.com/blitzcache/columns-no-statistics/',
                    'Sometimes this happens with indexed views, other times because auto create stats is turned off.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.relop_warnings = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    36,
                    100,
                    'Operator Warnings',
                    'SQL is throwing operator level plan warnings',
                    'http://brentozar.com/blitzcache/query-plan-warnings/',
                    'Check the plan for more details.') ;

        IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.is_table_scan = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    37,
                    100,
                    'Table Scans',
                    'Your database has HEAPs',
                    'https://www.brentozar.com/archive/2012/05/video-heaps/',
                    'This may not be a problem. Run sp_BlitzIndex for more information.') ;
        
		IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.backwards_scan = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    38,
                    100,
                    'Backwards Scans',
                    'Indexes are being read backwards',
                    'https://www.brentozar.com/blitzcache/backwards-scans/',
                    'This isn''t always a problem. They can cause serial zones in plans, and may need an index to match sort order.') ;

		IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.forced_index = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    39,
                    100,
                    'Index forcing',
                    'Someone is using hints to force index usage',
                    'https://www.brentozar.com/blitzcache/optimizer-forcing/',
                    'This can cause inefficient plans, and will prevent missing index requests.') ;

		IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.forced_seek = 1
				   OR p.forced_scan = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    40,
                    100,
                    'Seek/Scan forcing',
                    'Someone is using hints to force index seeks/scans',
                    'https://www.brentozar.com/blitzcache/optimizer-forcing/',
                    'This can cause inefficient plans by taking seek vs scan choice away from the optimizer.') ;

		IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.columnstore_row_mode = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    41,
                    100,
                    'ColumnStore indexes operating in Row Mode',
                    'Batch Mode is optimal for ColumnStore indexes',
                    'https://www.brentozar.com/blitzcache/columnstore-indexes-operating-row-mode/',
                    'ColumnStore indexes operating in Row Mode indicate really poor query choices.') ;

		IF EXISTS (SELECT 1/0
                   FROM   ##bou_BlitzCacheProcs p
                   WHERE  p.is_computed_scalar = 1
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    42,
                    50,
                    'Computed Columns Referencing Scalar UDFs',
                    'This makes a whole lot of stuff run serially',
                    'https://www.brentozar.com/blitzcache/computed-columns-referencing-functions/',
                    'This can cause a whole mess of bad serializartion problems.') ;

        IF EXISTS (SELECT 1/0
                    FROM   ##bou_BlitzCacheProcs p
                    WHERE  p.is_sort_expensive= 1
  					AND SPID = @@SPID)
             INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
             VALUES (@@SPID,
                     43,
                     100,
                     'Execution Plans',
                     'Expensive Sort',
                     'http://www.brentozar.com/blitzcache/expensive-sorts/',
                     'There''s a sort in your plan that costs >=50% of the total plan cost.') ;

        IF EXISTS (SELECT 1/0
                   FROM   #plan_creation p
                   WHERE (p.percent_24 > 0 OR p.percent_4 > 0)
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            SELECT SPID,
                    999,
                    254,
                    'Plan Cache Information',
                    'You have ' + CONVERT(NVARCHAR(10), p.percent_24) + '% plans created in the past 24 hours, and ' + CONVERT(NVARCHAR(10), p.percent_4) + '% created in the past 4 hours.',
                    '',
                    'If these percentages are high, it may be a sign of memory pressure or plan cache instability.'
			FROM   #plan_creation p	;

        IF EXISTS (SELECT 1/0
                   FROM   #single_use_plans_warning p
                   WHERE p.total_plans >= 1000
				   AND p.single_use_plans_percent >= 10.
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            SELECT SPID,
                    999,
                    255,
                    'Plan Cache Information',
                    'Your plan cache is ' + CONVERT(NVARCHAR(10), p.single_use_plans_percent) + '% single use plans with an average age of ' + CONVERT(NVARCHAR(10), p.avg_plan_age) + ' minutes.',
                    '',
                    'Having a lot of single use plans indicates plan cache bloat. This can be cause by non-parameterized dynamic SQL and EF code, or lots of ad hoc queries.'
			FROM   #single_use_plans_warning p	;

        IF EXISTS (SELECT 1/0
                   FROM   #plan_stubs_warning p
                   WHERE p.total_plans >= 1000
				   AND p.plan_stubs_percent >= 30.
				   AND p.total_plan_stubs >= (40009 * 4) 
				   AND SPID = @@SPID)
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            SELECT SPID,
                    999,
                    255,
                    'Plan Cache Information',
                    'Your plan cache has ' + CONVERT(NVARCHAR(10), p.total_plan_stubs) + ' plan stubs, with an average age of ' + CONVERT(NVARCHAR(10), p.avg_plan_age) + ' minutes.',
                    'https://www.brentozar.com/blitz/poison-wait-detected/',
                    'A high number of plan stubs may result in CMEMTHREAD waits, which you have ' 
						+ CONVERT(VARCHAR(10), (SELECT CONVERT(DECIMAL(9,0), (dows.wait_time_ms / 60000.)) FROM sys.dm_os_wait_stats AS dows WHERE dows.wait_type = 'CMEMTHREAD')) + ' minutes of.'
			FROM   #plan_stubs_warning p	;			
			
        IF EXISTS (SELECT 1/0
                   FROM   #trace_flags AS tf 
                   WHERE  tf.global_trace_flags IS NOT NULL
				   )
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    1000,
                    255,
                    'Global Trace Flags Enabled',
                    'You have Global Trace Flags enabled on your server',
                    'https://www.brentozar.com/blitz/trace-flags-enabled-globally/',
                    'You have the following Global Trace Flags enabled: ' + (SELECT TOP 1 tf.global_trace_flags FROM #trace_flags AS tf WHERE tf.global_trace_flags IS NOT NULL)) ;

        IF NOT EXISTS (SELECT 1/0
					   FROM   ##bou_BlitzCacheResults AS bcr
                       WHERE  bcr.Priority = 2147483647
				      )
            INSERT INTO ##bou_BlitzCacheResults (SPID, CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (@@SPID,
                    2147483647,
                    255,
                    'Thanks for using sp_BlitzCache!' ,
                    'From Your Community Volunteers',
                    'http://FirstResponderKit.org',
                    'We hope you found this tool useful. Current version: ' + @Version + ' released on ' + @VersionDate);
	
	END            
    
    SELECT  Priority,
            FindingsGroup,
            Finding,
            URL,
            Details,
            CheckID
    FROM    ##bou_BlitzCacheResults
    WHERE   SPID = @@SPID
    GROUP BY Priority,
            FindingsGroup,
            Finding,
            URL,
            Details,
            CheckID
    ORDER BY Priority ASC, CheckID ASC
    OPTION (RECOMPILE);
END


END

GO



USE tempdb
GO

IF OBJECT_ID('dbo.sp_BlitzFirst') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_BlitzFirst AS RETURN 0;')
GO


ALTER PROCEDURE [dbo].[sp_BlitzFirst]
    @Question NVARCHAR(MAX) = NULL ,
    @Help TINYINT = 0 ,
    @AsOf DATETIMEOFFSET = NULL ,
    @ExpertMode TINYINT = 0 ,
    @Seconds INT = 5 ,
    @OutputType VARCHAR(20) = 'TABLE' ,
    @OutputServerName NVARCHAR(256) = NULL ,
    @OutputDatabaseName NVARCHAR(256) = NULL ,
    @OutputSchemaName NVARCHAR(256) = NULL ,
    @OutputTableName NVARCHAR(256) = NULL ,
    @OutputTableNameFileStats NVARCHAR(256) = NULL ,
    @OutputTableNamePerfmonStats NVARCHAR(256) = NULL ,
    @OutputTableNameWaitStats NVARCHAR(256) = NULL ,
    @OutputXMLasNVARCHAR TINYINT = 0 ,
    @FilterPlansByDatabase VARCHAR(MAX) = NULL ,
    @CheckProcedureCache TINYINT = 0 ,
    @FileLatencyThresholdMS INT = 100 ,
    @SinceStartup TINYINT = 0 ,
    @VersionDate DATETIME = NULL OUTPUT
    WITH EXECUTE AS CALLER, RECOMPILE
AS
BEGIN
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET @VersionDate = '20161210'

IF @Help = 1 PRINT '
sp_BlitzFirst from http://FirstResponderKit.org
	
This script gives you a prioritized list of why your SQL Server is slow right now.

This is not an overall health check - for that, check out sp_Blitz.

To learn more, visit http://FirstResponderKit.org where you can download new
versions for free, watch training videos on how it works, get more info on
the findings, contribute your own code, and more.

Known limitations of this version:
 - Only Microsoft-supported versions of SQL Server. Sorry, 2005 and 2000. It
   may work just fine on 2005, and if it does, hug your parents. Just don''t
   file support issues if it breaks.
 - If a temp table called #CustomPerfmonCounters exists for any other session,
   but not our session, this stored proc will fail with an error saying the
   temp table #CustomPerfmonCounters does not exist.
 - @OutputServerName is not functional yet.

Unknown limitations of this version:
 - None. Like Zombo.com, the only limit is yourself.

Changes - for the full list of improvements and fixes in this version, see:
https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/


MIT License

Copyright (c) 2016 Brent Ozar Unlimited

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

'


RAISERROR('Setting up configuration variables',10,1) WITH NOWAIT;
DECLARE @StringToExecute NVARCHAR(MAX),
    @ParmDefinitions NVARCHAR(4000),
    @Parm1 NVARCHAR(4000),
    @OurSessionID INT,
    @LineFeed NVARCHAR(10),
    @StockWarningHeader NVARCHAR(500),
    @StockWarningFooter NVARCHAR(100),
    @StockDetailsHeader NVARCHAR(100),
    @StockDetailsFooter NVARCHAR(100),
    @StartSampleTime DATETIMEOFFSET,
    @FinishSampleTime DATETIMEOFFSET,
	@FinishSampleTimeWaitFor DATETIME,
    @ServiceName sysname,
    @OutputTableNameFileStats_View NVARCHAR(256),
    @OutputTableNamePerfmonStats_View NVARCHAR(256),
    @OutputTableNameWaitStats_View NVARCHAR(256),
    @ObjectFullName NVARCHAR(2000);

/* Sanitize our inputs */
SELECT
    @OutputTableNameFileStats_View = QUOTENAME(@OutputTableNameFileStats + '_Deltas'),
    @OutputTableNamePerfmonStats_View = QUOTENAME(@OutputTableNamePerfmonStats + '_Deltas'),
    @OutputTableNameWaitStats_View = QUOTENAME(@OutputTableNameWaitStats + '_Deltas');

SELECT
    @OutputDatabaseName = QUOTENAME(@OutputDatabaseName),
    @OutputSchemaName = QUOTENAME(@OutputSchemaName),
    @OutputTableName = QUOTENAME(@OutputTableName),
    @OutputTableNameFileStats = QUOTENAME(@OutputTableNameFileStats),
    @OutputTableNamePerfmonStats = QUOTENAME(@OutputTableNamePerfmonStats),
    @OutputTableNameWaitStats = QUOTENAME(@OutputTableNameWaitStats),
    @LineFeed = CHAR(13) + CHAR(10),
    @StartSampleTime = SYSDATETIMEOFFSET(),
    @FinishSampleTime = DATEADD(ss, @Seconds, SYSDATETIMEOFFSET()),
	@FinishSampleTimeWaitFor = DATEADD(ss, @Seconds, GETDATE()),
    @OurSessionID = @@SPID;


IF @SinceStartup = 1
    SELECT @Seconds = 0, @ExpertMode = 1;

IF @Seconds = 0 AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) = 'SQL Azure'
    SELECT @StartSampleTime = DATEADD(ms, AVG(-wait_time_ms), SYSDATETIMEOFFSET()), @FinishSampleTime = SYSDATETIMEOFFSET()
        FROM sys.dm_os_wait_stats w
        WHERE wait_type IN ('BROKER_TASK_STOP','DIRTY_PAGE_POLL','HADR_FILESTREAM_IOMGR_IOCOMPLETION','LAZYWRITER_SLEEP',
                            'LOGMGR_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH','XE_DISPATCHER_WAIT','XE_TIMER_EVENT')
ELSE IF @Seconds = 0 AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) <> 'SQL Azure'
    SELECT @StartSampleTime = create_date , @FinishSampleTime = SYSDATETIMEOFFSET()
        FROM sys.databases
        WHERE database_id = 2;
ELSE
    SELECT @StartSampleTime = SYSDATETIMEOFFSET(), @FinishSampleTime = DATEADD(ss, @Seconds, SYSDATETIMEOFFSET());

IF @OutputType = 'SCHEMA'
BEGIN
    SELECT FieldList = '[Priority] TINYINT, [FindingsGroup] VARCHAR(50), [Finding] VARCHAR(200), [URL] VARCHAR(200), [Details] NVARCHAR(4000), [HowToStopIt] NVARCHAR(MAX), [QueryPlan] XML, [QueryText] NVARCHAR(MAX)'

END
ELSE IF @AsOf IS NOT NULL AND @OutputDatabaseName IS NOT NULL AND @OutputSchemaName IS NOT NULL AND @OutputTableName IS NOT NULL
BEGIN
    /* They want to look into the past. */

        SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName + ''') SELECT CheckDate, [Priority], [FindingsGroup], [Finding], [URL], CAST([Details] AS [XML]) AS Details,'
            + '[HowToStopIt], [CheckID], [StartTime], [LoginName], [NTUserName], [OriginalLoginName], [ProgramName], [HostName], [DatabaseID],'
            + '[DatabaseName], [OpenTransactionCount], [QueryPlan], [QueryText] FROM '
            + @OutputDatabaseName + '.'
            + @OutputSchemaName + '.'
            + @OutputTableName
            + ' WHERE CheckDate >= DATEADD(mi, -15, ''' + CAST(@AsOf AS NVARCHAR(100)) + ''')'
            + ' AND CheckDate <= DATEADD(mi, 15, ''' + CAST(@AsOf AS NVARCHAR(100)) + ''')'
            + ' /*ORDER BY CheckDate, Priority , FindingsGroup , Finding , Details*/;';
        EXEC(@StringToExecute);


END /* IF @AsOf IS NOT NULL AND @OutputDatabaseName IS NOT NULL AND @OutputSchemaName IS NOT NULL AND @OutputTableName IS NOT NULL */
ELSE IF @Question IS NULL /* IF @OutputType = 'SCHEMA' */
BEGIN
    /* What's running right now? This is the first and last result set. */
    IF @SinceStartup = 0 AND @Seconds > 0 AND @ExpertMode = 1 
    BEGIN
		IF OBJECT_ID('dbo.sp_BlitzWho') IS NULL
		BEGIN
			PRINT N'sp_BlitzWho is not installed in the current database_files.  You can get a copy from http://FirstResponderKit.org'
		END
		ELSE
		BEGIN
			EXEC [dbo].[sp_BlitzWho]
		END
    END /* IF @SinceStartup = 0 AND @Seconds > 0 AND @ExpertMode = 1   -   What's running right now? This is the first and last result set. */
     

    RAISERROR('Now starting diagnostic analysis',10,1) WITH NOWAIT;

    /*
    We start by creating #BlitzFirstResults. It's a temp table that will store
    the results from our checks. Throughout the rest of this stored procedure,
    we're running a series of checks looking for dangerous things inside the SQL
    Server. When we find a problem, we insert rows into #BlitzResults. At the
    end, we return these results to the end user.

    #BlitzFirstResults has a CheckID field, but there's no Check table. As we do
    checks, we insert data into this table, and we manually put in the CheckID.
    We (Brent Ozar Unlimited) maintain a list of the checks by ID#. You can
    download that from http://FirstResponderKit.org if you want to build
    a tool that relies on the output of sp_BlitzFirst.
    */

    IF OBJECT_ID('tempdb..#BlitzFirstResults') IS NOT NULL
        DROP TABLE #BlitzFirstResults;
    CREATE TABLE #BlitzFirstResults
        (
          ID INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
          CheckID INT NOT NULL,
          Priority TINYINT NOT NULL,
          FindingsGroup VARCHAR(50) NOT NULL,
          Finding VARCHAR(200) NOT NULL,
          URL VARCHAR(200) NULL,
          Details NVARCHAR(4000) NULL,
          HowToStopIt NVARCHAR(MAX) NULL,
          QueryPlan [XML] NULL,
          QueryText NVARCHAR(MAX) NULL,
          StartTime DATETIMEOFFSET NULL,
          LoginName NVARCHAR(128) NULL,
          NTUserName NVARCHAR(128) NULL,
          OriginalLoginName NVARCHAR(128) NULL,
          ProgramName NVARCHAR(128) NULL,
          HostName NVARCHAR(128) NULL,
          DatabaseID INT NULL,
          DatabaseName NVARCHAR(128) NULL,
          OpenTransactionCount INT NULL,
          QueryStatsNowID INT NULL,
          QueryStatsFirstID INT NULL,
          PlanHandle VARBINARY(64) NULL,
          DetailsInt INT NULL,
        );

    IF OBJECT_ID('tempdb..#WaitStats') IS NOT NULL
        DROP TABLE #WaitStats;
    CREATE TABLE #WaitStats (Pass TINYINT NOT NULL, wait_type NVARCHAR(60), wait_time_ms BIGINT, signal_wait_time_ms BIGINT, waiting_tasks_count BIGINT, SampleTime DATETIMEOFFSET);

    IF OBJECT_ID('tempdb..#FileStats') IS NOT NULL
        DROP TABLE #FileStats;
    CREATE TABLE #FileStats (
        ID INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
        Pass TINYINT NOT NULL,
        SampleTime DATETIMEOFFSET NOT NULL,
        DatabaseID INT NOT NULL,
        FileID INT NOT NULL,
        DatabaseName NVARCHAR(256) ,
        FileLogicalName NVARCHAR(256) ,
        TypeDesc NVARCHAR(60) ,
        SizeOnDiskMB BIGINT ,
        io_stall_read_ms BIGINT ,
        num_of_reads BIGINT ,
        bytes_read BIGINT ,
        io_stall_write_ms BIGINT ,
        num_of_writes BIGINT ,
        bytes_written BIGINT,
        PhysicalName NVARCHAR(520) ,
        avg_stall_read_ms INT ,
        avg_stall_write_ms INT
    );

    IF OBJECT_ID('tempdb..#QueryStats') IS NOT NULL
        DROP TABLE #QueryStats;
    CREATE TABLE #QueryStats (
        ID INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
        Pass INT NOT NULL,
        SampleTime DATETIMEOFFSET NOT NULL,
        [sql_handle] VARBINARY(64),
        statement_start_offset INT,
        statement_end_offset INT,
        plan_generation_num BIGINT,
        plan_handle VARBINARY(64),
        execution_count BIGINT,
        total_worker_time BIGINT,
        total_physical_reads BIGINT,
        total_logical_writes BIGINT,
        total_logical_reads BIGINT,
        total_clr_time BIGINT,
        total_elapsed_time BIGINT,
        creation_time DATETIMEOFFSET,
        query_hash BINARY(8),
        query_plan_hash BINARY(8),
        Points TINYINT
    );

    IF OBJECT_ID('tempdb..#PerfmonStats') IS NOT NULL
        DROP TABLE #PerfmonStats;
    CREATE TABLE #PerfmonStats (
        ID INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
        Pass TINYINT NOT NULL,
        SampleTime DATETIMEOFFSET NOT NULL,
        [object_name] NVARCHAR(128) NOT NULL,
        [counter_name] NVARCHAR(128) NOT NULL,
        [instance_name] NVARCHAR(128) NULL,
        [cntr_value] BIGINT NULL,
        [cntr_type] INT NOT NULL,
        [value_delta] BIGINT NULL,
        [value_per_second] DECIMAL(18,2) NULL
    );

    IF OBJECT_ID('tempdb..#PerfmonCounters') IS NOT NULL
        DROP TABLE #PerfmonCounters;
    CREATE TABLE #PerfmonCounters (
        ID INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
        [object_name] NVARCHAR(128) NOT NULL,
        [counter_name] NVARCHAR(128) NOT NULL,
        [instance_name] NVARCHAR(128) NULL
    );

    IF OBJECT_ID('tempdb..#FilterPlansByDatabase') IS NOT NULL
        DROP TABLE #FilterPlansByDatabase;
    CREATE TABLE #FilterPlansByDatabase (DatabaseID INT PRIMARY KEY CLUSTERED);

    IF OBJECT_ID('tempdb..#MasterFiles') IS NOT NULL
        DROP TABLE #MasterFiles;
    CREATE TABLE #MasterFiles (database_id INT, file_id INT, type_desc NVARCHAR(50), name NVARCHAR(255), physical_name NVARCHAR(255), size BIGINT);
    /* Azure SQL Database doesn't have sys.master_files, so we have to build our own. */
    IF CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) = 'SQL Azure'
        SET @StringToExecute = 'INSERT INTO #MasterFiles (database_id, file_id, type_desc, name, physical_name, size) SELECT DB_ID(), file_id, type_desc, name, physical_name, size FROM sys.database_files;'
    ELSE
        SET @StringToExecute = 'INSERT INTO #MasterFiles (database_id, file_id, type_desc, name, physical_name, size) SELECT database_id, file_id, type_desc, name, physical_name, size FROM sys.master_files;'
    EXEC(@StringToExecute);

    IF @FilterPlansByDatabase IS NOT NULL
        BEGIN
        IF UPPER(LEFT(@FilterPlansByDatabase,4)) = 'USER'
            BEGIN
            INSERT INTO #FilterPlansByDatabase (DatabaseID)
            SELECT database_id
                FROM sys.databases
                WHERE [name] NOT IN ('master', 'model', 'msdb', 'tempdb')
            END
        ELSE
            BEGIN
            SET @FilterPlansByDatabase = @FilterPlansByDatabase + ','
            ;WITH a AS
                (
                SELECT CAST(1 AS BIGINT) f, CHARINDEX(',', @FilterPlansByDatabase) t, 1 SEQ
                UNION ALL
                SELECT t + 1, CHARINDEX(',', @FilterPlansByDatabase, t + 1), SEQ + 1
                FROM a
                WHERE CHARINDEX(',', @FilterPlansByDatabase, t + 1) > 0
                )
            INSERT #FilterPlansByDatabase (DatabaseID)
                SELECT SUBSTRING(@FilterPlansByDatabase, f, t - f)
                FROM a
                WHERE SUBSTRING(@FilterPlansByDatabase, f, t - f) IS NOT NULL
                OPTION (MAXRECURSION 0)
            END
        END


    SET @StockWarningHeader = '<?ClickToSeeCommmand -- ' + @LineFeed + @LineFeed
        + 'WARNING: Running this command may result in data loss or an outage.' + @LineFeed
        + 'This tool is meant as a shortcut to help generate scripts for DBAs.' + @LineFeed
        + 'It is not a substitute for database training and experience.' + @LineFeed
        + 'Now, having said that, here''s the details:' + @LineFeed + @LineFeed;

    SELECT @StockWarningFooter = @LineFeed + @LineFeed + '-- ?>',
        @StockDetailsHeader = '<?ClickToSeeDetails -- ' + @LineFeed,
        @StockDetailsFooter = @LineFeed + ' -- ?>';

    /* Get the instance name to use as a Perfmon counter prefix. */
    IF CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) = 'SQL Azure'
        SELECT TOP 1 @ServiceName = LEFT(object_name, (CHARINDEX(':', object_name) - 1))
        FROM sys.dm_os_performance_counters;
    ELSE
        BEGIN
        SET @StringToExecute = 'INSERT INTO #PerfmonStats(object_name, Pass, SampleTime, counter_name, cntr_type) SELECT CASE WHEN @@SERVICENAME = ''MSSQLSERVER'' THEN ''SQLServer'' ELSE ''MSSQL$'' + @@SERVICENAME END, 0, SYSDATETIMEOFFSET(), ''stuffing'', 0 ;'
        EXEC(@StringToExecute);
        SELECT @ServiceName = object_name FROM #PerfmonStats;
        DELETE #PerfmonStats;
        END

    /* Build a list of queries that were run in the last 10 seconds.
       We're looking for the death-by-a-thousand-small-cuts scenario
       where a query is constantly running, and it doesn't have that
       big of an impact individually, but it has a ton of impact
       overall. We're going to build this list, and then after we
       finish our @Seconds sample, we'll compare our plan cache to
       this list to see what ran the most. */

    /* Populate #QueryStats. SQL 2005 doesn't have query hash or query plan hash. */
    IF @CheckProcedureCache = 1 
	BEGIN
		RAISERROR('@CheckProcedureCache = 1, capturing first pass of plan cache',10,1) WITH NOWAIT;
		IF @@VERSION LIKE 'Microsoft SQL Server 2005%'
			BEGIN
			IF @FilterPlansByDatabase IS NULL
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 1 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, NULL AS query_hash, NULL AS query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											WHERE qs.last_execution_time >= (DATEADD(ss, -10, SYSDATETIMEOFFSET()));';
				END
			ELSE
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 1 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, NULL AS query_hash, NULL AS query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
												CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS attr
												INNER JOIN #FilterPlansByDatabase dbs ON CAST(attr.value AS INT) = dbs.DatabaseID
											WHERE qs.last_execution_time >= (DATEADD(ss, -10, SYSDATETIMEOFFSET()))
												AND attr.attribute = ''dbid'';';
				END
			END
		ELSE
			BEGIN
			IF @FilterPlansByDatabase IS NULL
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 1 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											WHERE qs.last_execution_time >= (DATEADD(ss, -10, SYSDATETIMEOFFSET()));';
				END
			ELSE
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 1 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS attr
											INNER JOIN #FilterPlansByDatabase dbs ON CAST(attr.value AS INT) = dbs.DatabaseID
											WHERE qs.last_execution_time >= (DATEADD(ss, -10, SYSDATETIMEOFFSET()))
												AND attr.attribute = ''dbid'';';
				END
			END
		EXEC(@StringToExecute);

		/* Get the totals for the entire plan cache */
		INSERT INTO #QueryStats (Pass, SampleTime, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time)
		SELECT -1 AS Pass, SYSDATETIMEOFFSET(), SUM(execution_count), SUM(total_worker_time), SUM(total_physical_reads), SUM(total_logical_writes), SUM(total_logical_reads), SUM(total_clr_time), SUM(total_elapsed_time), MIN(creation_time)
			FROM sys.dm_exec_query_stats qs;
    END /*IF @CheckProcedureCache = 1 */


    IF EXISTS (SELECT *
                    FROM tempdb.sys.all_objects obj
                    INNER JOIN tempdb.sys.all_columns col1 ON obj.object_id = col1.object_id AND col1.name = 'object_name'
                    INNER JOIN tempdb.sys.all_columns col2 ON obj.object_id = col2.object_id AND col2.name = 'counter_name'
                    INNER JOIN tempdb.sys.all_columns col3 ON obj.object_id = col3.object_id AND col3.name = 'instance_name'
                    WHERE obj.name LIKE '%CustomPerfmonCounters%')
        BEGIN
        SET @StringToExecute = 'INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) SELECT [object_name],[counter_name],[instance_name] FROM #CustomPerfmonCounters'
        EXEC(@StringToExecute);
        END
    ELSE
        BEGIN
        /* Add our default Perfmon counters */
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Forwarded Records/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Page compression attempts/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Page Splits/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Skipped Ghosted Records/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Table Lock Escalations/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Worktables Created/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Page life expectancy', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Page reads/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Page writes/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Readahead pages/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Target pages', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Total pages', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Databases','', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Active Transactions','_Total')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Databases','Log Growths', '_Total')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Databases','Log Shrinks', '_Total')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Exec Statistics','Distributed Query', 'Execs in progress')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Exec Statistics','DTC calls', 'Execs in progress')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Exec Statistics','Extended Procedures', 'Execs in progress')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Exec Statistics','OLEDB calls', 'Execs in progress')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','Active Temp Tables', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','Logins/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','Logouts/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','Mars Deadlocks', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','Processes blocked', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Number of Deadlocks/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Memory Manager','Memory Grants Pending', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Errors','Errors/sec', '_Total')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Batch Requests/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Forced Parameterizations/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Guided plan executions/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','SQL Attention rate', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','SQL Compilations/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','SQL Re-Compilations/sec', NULL)
        /* Below counters added by Jefferson Elias */
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Worktables From Cache Base',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Worktables From Cache Ratio',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Database pages',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Free pages',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Stolen pages',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Memory Manager','Granted Workspace Memory (KB)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Memory Manager','Maximum Workspace Memory (KB)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Memory Manager','Target Server Memory (KB)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Memory Manager','Total Server Memory (KB)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Buffer cache hit ratio',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Buffer cache hit ratio base',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Checkpoint pages/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Free list stalls/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Lazy writes/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Auto-Param Attempts/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Failed Auto-Params/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Safe Auto-Params/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Unsafe Auto-Params/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Workfiles Created/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','User Connections',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Latches','Average Latch Wait Time (ms)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Latches','Average Latch Wait Time Base',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Latches','Latch Waits/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Latches','Total Latch Wait Time (ms)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Average Wait Time (ms)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Average Wait Time Base',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Lock Requests/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Lock Timeouts/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Lock Wait Time (ms)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Lock Waits/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Transactions','Longest Transaction Running Time',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Full Scans/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Index Searches/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Page lookups/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Cursor Manager by Type','Active cursors',NULL)
        END

    /* Populate #FileStats, #PerfmonStats, #WaitStats with DMV data.
        After we finish doing our checks, we'll take another sample and compare them. */
	RAISERROR('Capturing first pass of wait stats, perfmon counters, file stats',10,1) WITH NOWAIT;
    INSERT #WaitStats(Pass, SampleTime, wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count)
		SELECT 
		x.Pass, 
		x.SampleTime, 
		x.wait_type, 
		SUM(x.sum_wait_time_ms) AS sum_wait_time_ms, 
		SUM(x.sum_signal_wait_time_ms) AS sum_signal_wait_time_ms, 
		SUM(x.sum_waiting_tasks) AS sum_waiting_tasks
		FROM (
		SELECT  
				1 AS Pass,
				CASE @Seconds WHEN 0 THEN @StartSampleTime ELSE SYSDATETIMEOFFSET() END AS SampleTime,
				owt.wait_type,
		        CASE @Seconds WHEN 0 THEN 0 ELSE SUM(owt.wait_duration_ms) OVER (PARTITION BY owt.wait_type, owt.session_id)
					 - CASE WHEN @Seconds = 0 THEN 0 ELSE (@Seconds * 1000) END END AS sum_wait_time_ms,
				0 AS sum_signal_wait_time_ms,
				0 AS sum_waiting_tasks
			FROM    sys.dm_os_waiting_tasks owt
			WHERE owt.session_id > 50
			AND owt.wait_duration_ms >= CASE @Seconds WHEN 0 THEN 0 ELSE @Seconds * 1000 END
		UNION ALL
		SELECT
		       1 AS Pass,
		       CASE @Seconds WHEN 0 THEN @StartSampleTime ELSE SYSDATETIMEOFFSET() END AS SampleTime,
		       os.wait_type,
		       CASE @Seconds WHEN 0 THEN 0 ELSE SUM(os.wait_time_ms) OVER (PARTITION BY os.wait_type) END AS sum_wait_time_ms,
		       CASE @Seconds WHEN 0 THEN 0 ELSE SUM(os.signal_wait_time_ms) OVER (PARTITION BY os.wait_type ) END AS sum_signal_wait_time_ms,
		       CASE @Seconds WHEN 0 THEN 0 ELSE SUM(os.waiting_tasks_count) OVER (PARTITION BY os.wait_type) END AS sum_waiting_tasks
		   FROM sys.dm_os_wait_stats os
		) x
		   WHERE x.wait_type NOT IN (
		       'REQUEST_FOR_DEADLOCK_SEARCH',
		       'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
		       'SQLTRACE_BUFFER_FLUSH',
		       'LAZYWRITER_SLEEP',
		       'XE_TIMER_EVENT',
		       'XE_DISPATCHER_WAIT',
		       'FT_IFTS_SCHEDULER_IDLE_WAIT',
		       'LOGMGR_QUEUE',
		       'CHECKPOINT_QUEUE',
		       'BROKER_TO_FLUSH',
		       'BROKER_TASK_STOP',
		       'BROKER_EVENTHANDLER',
		       'SLEEP_TASK',
		       'WAITFOR',
		       'DBMIRROR_DBM_MUTEX',
		       'DBMIRROR_EVENTS_QUEUE',
		       'DBMIRRORING_CMD',
		       'DISPATCHER_QUEUE_SEMAPHORE',
		       'BROKER_RECEIVE_WAITFOR',
		       'CLR_AUTO_EVENT',
		       'DIRTY_PAGE_POLL',
		       'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
		       'ONDEMAND_TASK_QUEUE',
		       'FT_IFTSHC_MUTEX',
		       'CLR_MANUAL_EVENT',
		       'CLR_SEMAPHORE',
		       'DBMIRROR_WORKER_QUEUE',
		       'DBMIRROR_DBM_EVENT',
		       'SP_SERVER_DIAGNOSTICS_SLEEP',
		       'HADR_CLUSAPI_CALL',
		       'HADR_LOGCAPTURE_WAIT',
		       'HADR_NOTIFICATION_DEQUEUE',
		       'HADR_TIMER_TASK',
		       'HADR_WORK_QUEUE',
		       'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
		       'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
		       'RESOURCE_GOVERNOR_IDLE',
		       'QDS_ASYNC_QUEUE',
		       'QDS_SHUTDOWN_QUEUE',
		       'SLEEP_SYSTEMTASK',
		       'BROKER_TRANSMITTER',
		       'REDO_THREAD_PENDING_WORK',
		       'UCS_SESSION_REGISTRATION'
		   )
		GROUP BY x.Pass, x.SampleTime, x.wait_type
		ORDER BY sum_wait_time_ms DESC;


    INSERT INTO #FileStats (Pass, SampleTime, DatabaseID, FileID, DatabaseName, FileLogicalName, SizeOnDiskMB, io_stall_read_ms ,
        num_of_reads, [bytes_read] , io_stall_write_ms,num_of_writes, [bytes_written], PhysicalName, TypeDesc)
    SELECT
        1 AS Pass,
        CASE @Seconds WHEN 0 THEN @StartSampleTime ELSE SYSDATETIMEOFFSET() END AS SampleTime,
        mf.[database_id],
        mf.[file_id],
        DB_NAME(vfs.database_id) AS [db_name],
        mf.name + N' [' + mf.type_desc COLLATE SQL_Latin1_General_CP1_CI_AS + N']' AS file_logical_name ,
        CAST(( ( vfs.size_on_disk_bytes / 1024.0 ) / 1024.0 ) AS INT) AS size_on_disk_mb ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.io_stall_read_ms END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.num_of_reads END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.[num_of_bytes_read] END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.io_stall_write_ms END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.num_of_writes END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.[num_of_bytes_written] END ,
        mf.physical_name,
        mf.type_desc
    FROM sys.dm_io_virtual_file_stats (NULL, NULL) AS vfs
    INNER JOIN #MasterFiles AS mf ON vfs.file_id = mf.file_id
        AND vfs.database_id = mf.database_id
    WHERE vfs.num_of_reads > 0
        OR vfs.num_of_writes > 0;

    INSERT INTO #PerfmonStats (Pass, SampleTime, [object_name],[counter_name],[instance_name],[cntr_value],[cntr_type])
    SELECT         1 AS Pass,
        CASE @Seconds WHEN 0 THEN @StartSampleTime ELSE SYSDATETIMEOFFSET() END AS SampleTime, RTRIM(dmv.object_name), RTRIM(dmv.counter_name), RTRIM(dmv.instance_name), CASE @Seconds WHEN 0 THEN 0 ELSE dmv.cntr_value END, dmv.cntr_type
        FROM #PerfmonCounters counters
        INNER JOIN sys.dm_os_performance_counters dmv ON counters.counter_name COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.counter_name) COLLATE SQL_Latin1_General_CP1_CI_AS
            AND counters.[object_name] COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.[object_name]) COLLATE SQL_Latin1_General_CP1_CI_AS
            AND (counters.[instance_name] IS NULL OR counters.[instance_name] COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.[instance_name]) COLLATE SQL_Latin1_General_CP1_CI_AS)


	RAISERROR('Beginning investigatory queries',10,1) WITH NOWAIT;


    /* Maintenance Tasks Running - Backup Running - CheckID 1 */
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount)
    SELECT 1 AS CheckID,
        1 AS Priority,
        'Maintenance Tasks Running' AS FindingGroup,
        'Backup Running' AS Finding,
        'http://www.BrentOzar.com/askbrent/backups/' AS URL,
        'Backup of ' + DB_NAME(db.resource_database_id) + ' database (' + (SELECT CAST(CAST(SUM(size * 8.0 / 1024 / 1024) AS BIGINT) AS NVARCHAR) FROM #MasterFiles WHERE database_id = db.resource_database_id) + 'GB) is ' + CAST(r.percent_complete AS NVARCHAR(100)) + '% complete, has been running since ' + CAST(r.start_time AS NVARCHAR(100)) + '. ' AS Details,
        'KILL ' + CAST(r.session_id AS NVARCHAR(100)) + ';' AS HowToStopIt,
        pl.query_plan AS QueryPlan,
        r.start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        db.[resource_database_id] AS DatabaseID,
        DB_NAME(db.resource_database_id) AS DatabaseName,
        0 AS OpenTransactionCount
    FROM sys.dm_exec_requests r
    INNER JOIN sys.dm_exec_connections c ON r.session_id = c.session_id
    INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
    INNER JOIN (
    SELECT DISTINCT request_session_id, resource_database_id
    FROM    sys.dm_tran_locks
    WHERE resource_type = N'DATABASE'
    AND     request_mode = N'S'
    AND     request_status = N'GRANT'
    AND     request_owner_type = N'SHARED_TRANSACTION_WORKSPACE') AS db ON s.session_id = db.request_session_id
    CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) pl
    WHERE r.command LIKE 'BACKUP%';


    /* If there's a backup running, add details explaining how long full backup has been taking in the last month. */
    IF @Seconds > 0 AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) <> 'SQL Azure'
    BEGIN
        SET @StringToExecute = 'UPDATE #BlitzFirstResults SET Details = Details + '' Over the last 60 days, the full backup usually takes '' + CAST((SELECT AVG(DATEDIFF(mi, bs.backup_start_date, bs.backup_finish_date)) FROM msdb.dbo.backupset bs WHERE abr.DatabaseName = bs.database_name AND bs.type = ''D'' AND bs.backup_start_date > DATEADD(dd, -60, SYSDATETIMEOFFSET()) AND bs.backup_finish_date IS NOT NULL) AS NVARCHAR(100)) + '' minutes.'' FROM #BlitzFirstResults abr WHERE abr.CheckID = 1 AND EXISTS (SELECT * FROM msdb.dbo.backupset bs WHERE bs.type = ''D'' AND bs.backup_start_date > DATEADD(dd, -60, SYSDATETIMEOFFSET()) AND bs.backup_finish_date IS NOT NULL AND abr.DatabaseName = bs.database_name AND DATEDIFF(mi, bs.backup_start_date, bs.backup_finish_date) > 1)';
        EXEC(@StringToExecute);
    END


    /* Maintenance Tasks Running - DBCC Running - CheckID 2 */
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount)
    SELECT 2 AS CheckID,
        1 AS Priority,
        'Maintenance Tasks Running' AS FindingGroup,
        'DBCC Running' AS Finding,
        'http://www.BrentOzar.com/askbrent/dbcc/' AS URL,
        'Corruption check of ' + DB_NAME(db.resource_database_id) + ' database (' + (SELECT CAST(CAST(SUM(size * 8.0 / 1024 / 1024) AS BIGINT) AS NVARCHAR) FROM #MasterFiles WHERE database_id = db.resource_database_id) + 'GB) has been running since ' + CAST(r.start_time AS NVARCHAR(100)) + '. ' AS Details,
        'KILL ' + CAST(r.session_id AS NVARCHAR(100)) + ';' AS HowToStopIt,
        pl.query_plan AS QueryPlan,
        r.start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        db.[resource_database_id] AS DatabaseID,
        DB_NAME(db.resource_database_id) AS DatabaseName,
        0 AS OpenTransactionCount
    FROM sys.dm_exec_requests r
    INNER JOIN sys.dm_exec_connections c ON r.session_id = c.session_id
    INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
    INNER JOIN (SELECT DISTINCT l.request_session_id, l.resource_database_id
    FROM    sys.dm_tran_locks l
    INNER JOIN sys.databases d ON l.resource_database_id = d.database_id
    WHERE l.resource_type = N'DATABASE'
    AND     l.request_mode = N'S'
    AND    l.request_status = N'GRANT'
    AND    l.request_owner_type = N'SHARED_TRANSACTION_WORKSPACE') AS db ON s.session_id = db.request_session_id
    CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) pl
    WHERE r.command LIKE 'DBCC%';


    /* Maintenance Tasks Running - Restore Running - CheckID 3 */
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount)
    SELECT 3 AS CheckID,
        1 AS Priority,
        'Maintenance Tasks Running' AS FindingGroup,
        'Restore Running' AS Finding,
        'http://www.BrentOzar.com/askbrent/backups/' AS URL,
        'Restore of ' + DB_NAME(db.resource_database_id) + ' database (' + (SELECT CAST(CAST(SUM(size * 8.0 / 1024 / 1024) AS BIGINT) AS NVARCHAR) FROM #MasterFiles WHERE database_id = db.resource_database_id) + 'GB) is ' + CAST(r.percent_complete AS NVARCHAR(100)) + '% complete, has been running since ' + CAST(r.start_time AS NVARCHAR(100)) + '. ' AS Details,
        'KILL ' + CAST(r.session_id AS NVARCHAR(100)) + ';' AS HowToStopIt,
        pl.query_plan AS QueryPlan,
        r.start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        db.[resource_database_id] AS DatabaseID,
        DB_NAME(db.resource_database_id) AS DatabaseName,
        0 AS OpenTransactionCount
    FROM sys.dm_exec_requests r
    INNER JOIN sys.dm_exec_connections c ON r.session_id = c.session_id
    INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
    INNER JOIN (
    SELECT DISTINCT request_session_id, resource_database_id
    FROM    sys.dm_tran_locks
    WHERE resource_type = N'DATABASE'
    AND     request_mode = N'S'
    AND     request_status = N'GRANT'
    AND     request_owner_type = N'SHARED_TRANSACTION_WORKSPACE') AS db ON s.session_id = db.request_session_id
    CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) pl
    WHERE r.command LIKE 'RESTORE%';


    /* SQL Server Internal Maintenance - Database File Growing - CheckID 4 */
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount)
    SELECT 4 AS CheckID,
        1 AS Priority,
        'SQL Server Internal Maintenance' AS FindingGroup,
        'Database File Growing' AS Finding,
        'http://www.BrentOzar.com/go/instant' AS URL,
        'SQL Server is waiting for Windows to provide storage space for a database restore, a data file growth, or a log file growth. This task has been running since ' + CAST(r.start_time AS NVARCHAR(100)) + '.' + @LineFeed + 'Check the query plan (expert mode) to identify the database involved.' AS Details,
        'Unfortunately, you can''t stop this, but you can prevent it next time. Check out http://www.BrentOzar.com/go/instant for details.' AS HowToStopIt,
        pl.query_plan AS QueryPlan,
        r.start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        NULL AS DatabaseID,
        NULL AS DatabaseName,
        0 AS OpenTransactionCount
    FROM sys.dm_os_waiting_tasks t
    INNER JOIN sys.dm_exec_connections c ON t.session_id = c.session_id
    INNER JOIN sys.dm_exec_requests r ON t.session_id = r.session_id
    INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
    CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) pl
    WHERE t.wait_type = 'PREEMPTIVE_OS_WRITEFILEGATHER'


    /* Query Problems - Long-Running Query Blocking Others - CheckID 5 */
    /*
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount)
    SELECT 5 AS CheckID,
        1 AS Priority,
        'Query Problems' AS FindingGroup,
        'Long-Running Query Blocking Others' AS Finding,
        'http://www.BrentOzar.com/go/blocking' AS URL,
        'Query in ' + DB_NAME(db.resource_database_id) + ' has been running since ' + CAST(r.start_time AS NVARCHAR(100)) + '. ' + @LineFeed + @LineFeed
            + CAST(COALESCE((SELECT TOP 1 [text] FROM sys.dm_exec_sql_text(rBlocker.sql_handle)),
            (SELECT TOP 1 [text] FROM master..sysprocesses spBlocker CROSS APPLY sys.dm_exec_sql_text(spBlocker.sql_handle) WHERE spBlocker.spid = tBlocked.blocking_session_id), '') AS NVARCHAR(2000)) AS Details,
        'KILL ' + CAST(tBlocked.blocking_session_id AS NVARCHAR(100)) + ';' AS HowToStopIt,
        (SELECT TOP 1 query_plan FROM sys.dm_exec_query_plan(rBlocker.plan_handle)) AS QueryPlan,
        COALESCE((SELECT TOP 1 [text] FROM sys.dm_exec_sql_text(rBlocker.sql_handle)),
            (SELECT TOP 1 [text] FROM master..sysprocesses spBlocker CROSS APPLY sys.dm_exec_sql_text(spBlocker.sql_handle) WHERE spBlocker.spid = tBlocked.blocking_session_id)) AS QueryText,
        r.start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        db.[resource_database_id] AS DatabaseID,
        DB_NAME(db.resource_database_id) AS DatabaseName,
        0 AS OpenTransactionCount
    FROM sys.dm_exec_sessions s
    INNER JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
    INNER JOIN sys.dm_exec_connections c ON s.session_id = c.session_id
    INNER JOIN sys.dm_os_waiting_tasks tBlocked ON tBlocked.session_id = s.session_id AND tBlocked.session_id <> s.session_id
    INNER JOIN (
    SELECT DISTINCT request_session_id, resource_database_id
    FROM    sys.dm_tran_locks
    WHERE resource_type = N'DATABASE'
    AND     request_mode = N'S'
    AND     request_status = N'GRANT'
    AND     request_owner_type = N'SHARED_TRANSACTION_WORKSPACE') AS db ON s.session_id = db.request_session_id
    LEFT OUTER JOIN sys.dm_exec_requests rBlocker ON tBlocked.blocking_session_id = rBlocker.session_id
      WHERE NOT EXISTS (SELECT * FROM sys.dm_os_waiting_tasks tBlocker WHERE tBlocker.session_id = tBlocked.blocking_session_id AND tBlocker.blocking_session_id IS NOT NULL)
      AND s.last_request_start_time < DATEADD(SECOND, -30, SYSDATETIMEOFFSET())
    */

    /* Query Problems - Plan Cache Erased Recently */
    IF DATEADD(mi, -15, SYSDATETIMEOFFSET()) < (SELECT TOP 1 creation_time FROM sys.dm_exec_query_stats ORDER BY creation_time)
    BEGIN
        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
        SELECT TOP 1 7 AS CheckID,
            50 AS Priority,
            'Query Problems' AS FindingGroup,
            'Plan Cache Erased Recently' AS Finding,
            'http://www.BrentOzar.com/askbrent/plan-cache-erased-recently/' AS URL,
            'The oldest query in the plan cache was created at ' + CAST(creation_time AS NVARCHAR(50)) + '. ' + @LineFeed + @LineFeed
                + 'This indicates that someone ran DBCC FREEPROCCACHE at that time,' + @LineFeed
                + 'Giving SQL Server temporary amnesia. Now, as queries come in,' + @LineFeed
                + 'SQL Server has to use a lot of CPU power in order to build execution' + @LineFeed
                + 'plans and put them in cache again. This causes high CPU loads.' AS Details,
            'Find who did that, and stop them from doing it again.' AS HowToStopIt
        FROM sys.dm_exec_query_stats
        ORDER BY creation_time
    END;


    /* Query Problems - Sleeping Query with Open Transactions - CheckID 8 */
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, QueryText, OpenTransactionCount)
    SELECT 8 AS CheckID,
        50 AS Priority,
        'Query Problems' AS FindingGroup,
        'Sleeping Query with Open Transactions' AS Finding,
        'http://www.brentozar.com/askbrent/sleeping-query-with-open-transactions/' AS URL,
        'Database: ' + DB_NAME(db.resource_database_id) + @LineFeed + 'Host: ' + s.[host_name] + @LineFeed + 'Program: ' + s.[program_name] + @LineFeed + 'Asleep with open transactions and locks since ' + CAST(s.last_request_end_time AS NVARCHAR(100)) + '. ' AS Details,
        'KILL ' + CAST(s.session_id AS NVARCHAR(100)) + ';' AS HowToStopIt,
        s.last_request_start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        db.[resource_database_id] AS DatabaseID,
        DB_NAME(db.resource_database_id) AS DatabaseName,
        (SELECT TOP 1 [text] FROM sys.dm_exec_sql_text(c.most_recent_sql_handle)) AS QueryText,
        sessions_with_transactions.open_transaction_count AS OpenTransactionCount
    FROM (SELECT session_id, SUM(open_transaction_count) AS open_transaction_count FROM sys.dm_exec_requests WHERE open_transaction_count > 0 GROUP BY session_id) AS sessions_with_transactions
    INNER JOIN sys.dm_exec_sessions s ON sessions_with_transactions.session_id = s.session_id
    INNER JOIN sys.dm_exec_connections c ON s.session_id = c.session_id
    INNER JOIN (
    SELECT DISTINCT request_session_id, resource_database_id
    FROM    sys.dm_tran_locks
    WHERE resource_type = N'DATABASE'
    AND     request_mode = N'S'
    AND     request_status = N'GRANT'
    AND     request_owner_type = N'SHARED_TRANSACTION_WORKSPACE') AS db ON s.session_id = db.request_session_id
    WHERE s.status = 'sleeping'
    AND s.last_request_end_time < DATEADD(ss, -10, SYSDATETIMEOFFSET())
    AND EXISTS(SELECT * FROM sys.dm_tran_locks WHERE request_session_id = s.session_id
    AND NOT (resource_type = N'DATABASE' AND request_mode = N'S' AND request_status = N'GRANT' AND request_owner_type = N'SHARED_TRANSACTION_WORKSPACE'))


    /* Query Problems - Query Rolling Back - CheckID 9 */
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, QueryText)
    SELECT 9 AS CheckID,
        1 AS Priority,
        'Query Problems' AS FindingGroup,
        'Query Rolling Back' AS Finding,
        'http://www.BrentOzar.com/askbrent/rollback/' AS URL,
        'Rollback started at ' + CAST(r.start_time AS NVARCHAR(100)) + ', is ' + CAST(r.percent_complete AS NVARCHAR(100)) + '% complete.' AS Details,
        'Unfortunately, you can''t stop this. Whatever you do, don''t restart the server in an attempt to fix it - SQL Server will keep rolling back.' AS HowToStopIt,
        r.start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        db.[resource_database_id] AS DatabaseID,
        DB_NAME(db.resource_database_id) AS DatabaseName,
        (SELECT TOP 1 [text] FROM sys.dm_exec_sql_text(c.most_recent_sql_handle)) AS QueryText
    FROM sys.dm_exec_sessions s
    INNER JOIN sys.dm_exec_connections c ON s.session_id = c.session_id
    INNER JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
    LEFT OUTER JOIN (
        SELECT DISTINCT request_session_id, resource_database_id
        FROM    sys.dm_tran_locks
        WHERE resource_type = N'DATABASE'
        AND     request_mode = N'S'
        AND     request_status = N'GRANT'
        AND     request_owner_type = N'SHARED_TRANSACTION_WORKSPACE') AS db ON s.session_id = db.request_session_id
    WHERE r.status = 'rollback'


    /* Server Performance - Page Life Expectancy Low - CheckID 10 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 10 AS CheckID,
        50 AS Priority,
        'Server Performance' AS FindingGroup,
        'Page Life Expectancy Low' AS Finding,
        'http://www.BrentOzar.com/askbrent/page-life-expectancy/' AS URL,
        'SQL Server Buffer Manager:Page life expectancy is ' + CAST(c.cntr_value AS NVARCHAR(10)) + ' seconds.' + @LineFeed
            + 'This means SQL Server can only keep data pages in memory for that many seconds after reading those pages in from storage.' + @LineFeed
            + 'This is a symptom, not a cause - it indicates very read-intensive queries that need an index, or insufficient server memory.' AS Details,
        'Add more memory to the server, or find the queries reading a lot of data, and make them more efficient (or fix them with indexes).' AS HowToStopIt
    FROM sys.dm_os_performance_counters c
    WHERE object_name LIKE 'SQLServer:Buffer Manager%'
    AND counter_name LIKE 'Page life expectancy%'
    AND cntr_value < 300

    /* Server Info - Database Size, Total GB - CheckID 21 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
    SELECT 21 AS CheckID,
        251 AS Priority,
        'Server Info' AS FindingGroup,
        'Database Size, Total GB' AS Finding,
        CAST(SUM (CAST(size AS BIGINT)*8./1024./1024.) AS VARCHAR(100)) AS Details,
        SUM (CAST(size AS BIGINT))*8./1024./1024. AS DetailsInt,
        'http://www.BrentOzar.com/askbrent/' AS URL
    FROM #MasterFiles
    WHERE database_id > 4

    /* Server Info - Database Count - CheckID 22 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
    SELECT 22 AS CheckID,
        251 AS Priority,
        'Server Info' AS FindingGroup,
        'Database Count' AS Finding,
        CAST(SUM(1) AS VARCHAR(100)) AS Details,
        SUM (1) AS DetailsInt,
        'http://www.BrentOzar.com/askbrent/' AS URL
    FROM sys.databases
    WHERE database_id > 4

    /* Server Performance - High CPU Utilization CheckID 24 */
    IF @Seconds < 30
        BEGIN
        /* If we're waiting less than 30 seconds, run this check now rather than wait til the end.
           We get this data from the ring buffers, and it's only updated once per minute, so might
           as well get it now - whereas if we're checking 30+ seconds, it might get updated by the
           end of our sp_BlitzFirst session. */
        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
        SELECT 24, 50, 'Server Performance', 'High CPU Utilization', CAST(100 - SystemIdle AS NVARCHAR(20)) + N'%. Ring buffer details: ' + CAST(record AS NVARCHAR(4000)), 100 - SystemIdle, 'http://www.BrentOzar.com/go/cpu'
            FROM (
                SELECT record,
                    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle
                FROM (
                    SELECT TOP 1 CONVERT(XML, record) AS record
                    FROM sys.dm_os_ring_buffers
                    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                    AND record LIKE '%<SystemHealth>%'
                    ORDER BY timestamp DESC) AS rb
            ) AS y
            WHERE 100 - SystemIdle >= 50

        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
        SELECT 23, 250, 'Server Info', 'CPU Utilization', CAST(100 - SystemIdle AS NVARCHAR(20)) + N'%. Ring buffer details: ' + CAST(record AS NVARCHAR(4000)), 100 - SystemIdle, 'http://www.BrentOzar.com/go/cpu'
            FROM (
                SELECT record,
                    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle
                FROM (
                    SELECT TOP 1 CONVERT(XML, record) AS record
                    FROM sys.dm_os_ring_buffers
                    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                    AND record LIKE '%<SystemHealth>%'
                    ORDER BY timestamp DESC) AS rb
            ) AS y

        END /* IF @Seconds < 30 */

	RAISERROR('Finished running investigatory queries',10,1) WITH NOWAIT;


    /* End of checks. If we haven't waited @Seconds seconds, wait. */
    IF SYSDATETIMEOFFSET() < @FinishSampleTime
		BEGIN
		RAISERROR('Waiting to match @Seconds parameter',10,1) WITH NOWAIT;
        WAITFOR TIME @FinishSampleTimeWaitFor;
		END

	RAISERROR('Capturing second pass of wait stats, perfmon counters, file stats',10,1) WITH NOWAIT;
    /* Populate #FileStats, #PerfmonStats, #WaitStats with DMV data. In a second, we'll compare these. */
    INSERT #WaitStats(Pass, SampleTime, wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count)
		SELECT 
		x.Pass, 
		x.SampleTime, 
		x.wait_type, 
		SUM(x.sum_wait_time_ms) AS sum_wait_time_ms, 
		SUM(x.sum_signal_wait_time_ms) AS sum_signal_wait_time_ms, 
		SUM(x.sum_waiting_tasks) AS sum_waiting_tasks
		FROM (
		SELECT  
				2 AS Pass,
				SYSDATETIMEOFFSET() AS SampleTime,
				owt.wait_type,
		        SUM(owt.wait_duration_ms) OVER (PARTITION BY owt.wait_type, owt.session_id)
					 - CASE WHEN @Seconds = 0 THEN 0 ELSE (@Seconds * 1000) END AS sum_wait_time_ms,
				0 AS sum_signal_wait_time_ms,
				CASE @Seconds WHEN 0 THEN 0 ELSE 1 END AS sum_waiting_tasks
			FROM    sys.dm_os_waiting_tasks owt
			WHERE owt.session_id > 50
			AND owt.wait_duration_ms >= CASE @Seconds WHEN 0 THEN 0 ELSE @Seconds * 1000 END
		UNION ALL
		SELECT
		       2 AS Pass,
		       SYSDATETIMEOFFSET() AS SampleTime,
		       os.wait_type,
			   SUM(os.wait_time_ms) OVER (PARTITION BY os.wait_type) AS sum_wait_time_ms,
			   SUM(os.signal_wait_time_ms) OVER (PARTITION BY os.wait_type ) AS sum_signal_wait_time_ms,
			   SUM(os.waiting_tasks_count) OVER (PARTITION BY os.wait_type) AS sum_waiting_tasks
		   FROM sys.dm_os_wait_stats os
		) x
		   WHERE x.wait_type NOT IN (
		       'REQUEST_FOR_DEADLOCK_SEARCH',
		       'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
		       'SQLTRACE_BUFFER_FLUSH',
		       'LAZYWRITER_SLEEP',
		       'XE_TIMER_EVENT',
		       'XE_DISPATCHER_WAIT',
		       'FT_IFTS_SCHEDULER_IDLE_WAIT',
		       'LOGMGR_QUEUE',
		       'CHECKPOINT_QUEUE',
		       'BROKER_TO_FLUSH',
		       'BROKER_TASK_STOP',
		       'BROKER_EVENTHANDLER',
		       'SLEEP_TASK',
		       'WAITFOR',
		       'DBMIRROR_DBM_MUTEX',
		       'DBMIRROR_EVENTS_QUEUE',
		       'DBMIRRORING_CMD',
		       'DISPATCHER_QUEUE_SEMAPHORE',
		       'BROKER_RECEIVE_WAITFOR',
		       'CLR_AUTO_EVENT',
		       'DIRTY_PAGE_POLL',
		       'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
		       'ONDEMAND_TASK_QUEUE',
		       'FT_IFTSHC_MUTEX',
		       'CLR_MANUAL_EVENT',
		       'CLR_SEMAPHORE',
		       'DBMIRROR_WORKER_QUEUE',
		       'DBMIRROR_DBM_EVENT',
		       'SP_SERVER_DIAGNOSTICS_SLEEP',
		       'HADR_CLUSAPI_CALL',
		       'HADR_LOGCAPTURE_WAIT',
		       'HADR_NOTIFICATION_DEQUEUE',
		       'HADR_TIMER_TASK',
		       'HADR_WORK_QUEUE',
		       'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
		       'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
		       'RESOURCE_GOVERNOR_IDLE',
		       'QDS_ASYNC_QUEUE',
		       'QDS_SHUTDOWN_QUEUE',
		       'SLEEP_SYSTEMTASK',
		       'BROKER_TRANSMITTER',
		       'REDO_THREAD_PENDING_WORK',
		       'UCS_SESSION_REGISTRATION'
		   )
		GROUP BY x.Pass, x.SampleTime, x.wait_type
		ORDER BY sum_wait_time_ms DESC;

    INSERT INTO #FileStats (Pass, SampleTime, DatabaseID, FileID, DatabaseName, FileLogicalName, SizeOnDiskMB, io_stall_read_ms ,
        num_of_reads, [bytes_read] , io_stall_write_ms,num_of_writes, [bytes_written], PhysicalName, TypeDesc, avg_stall_read_ms, avg_stall_write_ms)
    SELECT         2 AS Pass,
        SYSDATETIMEOFFSET() AS SampleTime,
        mf.[database_id],
        mf.[file_id],
        DB_NAME(vfs.database_id) AS [db_name],
        mf.name + N' [' + mf.type_desc COLLATE SQL_Latin1_General_CP1_CI_AS + N']' AS file_logical_name ,
        CAST(( ( vfs.size_on_disk_bytes / 1024.0 ) / 1024.0 ) AS INT) AS size_on_disk_mb ,
        vfs.io_stall_read_ms ,
        vfs.num_of_reads ,
        vfs.[num_of_bytes_read],
        vfs.io_stall_write_ms ,
        vfs.num_of_writes ,
        vfs.[num_of_bytes_written],
        mf.physical_name,
        mf.type_desc,
        0,
        0
    FROM sys.dm_io_virtual_file_stats (NULL, NULL) AS vfs
    INNER JOIN #MasterFiles AS mf ON vfs.file_id = mf.file_id
        AND vfs.database_id = mf.database_id
    WHERE vfs.num_of_reads > 0
        OR vfs.num_of_writes > 0;

    INSERT INTO #PerfmonStats (Pass, SampleTime, [object_name],[counter_name],[instance_name],[cntr_value],[cntr_type])
    SELECT         2 AS Pass,
        SYSDATETIMEOFFSET() AS SampleTime,
        RTRIM(dmv.object_name), RTRIM(dmv.counter_name), RTRIM(dmv.instance_name), dmv.cntr_value, dmv.cntr_type
        FROM #PerfmonCounters counters
        INNER JOIN sys.dm_os_performance_counters dmv ON counters.counter_name COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.counter_name) COLLATE SQL_Latin1_General_CP1_CI_AS
            AND counters.[object_name] COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.[object_name]) COLLATE SQL_Latin1_General_CP1_CI_AS
            AND (counters.[instance_name] IS NULL OR counters.[instance_name] COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.[instance_name]) COLLATE SQL_Latin1_General_CP1_CI_AS)

    /* Set the latencies and averages. We could do this with a CTE, but we're not ambitious today. */
    UPDATE fNow
    SET avg_stall_read_ms = ((fNow.io_stall_read_ms - fBase.io_stall_read_ms) / (fNow.num_of_reads - fBase.num_of_reads))
    FROM #FileStats fNow
    INNER JOIN #FileStats fBase ON fNow.DatabaseID = fBase.DatabaseID AND fNow.FileID = fBase.FileID AND fNow.SampleTime > fBase.SampleTime AND fNow.num_of_reads > fBase.num_of_reads AND fNow.io_stall_read_ms > fBase.io_stall_read_ms
    WHERE (fNow.num_of_reads - fBase.num_of_reads) > 0

    UPDATE fNow
    SET avg_stall_write_ms = ((fNow.io_stall_write_ms - fBase.io_stall_write_ms) / (fNow.num_of_writes - fBase.num_of_writes))
    FROM #FileStats fNow
    INNER JOIN #FileStats fBase ON fNow.DatabaseID = fBase.DatabaseID AND fNow.FileID = fBase.FileID AND fNow.SampleTime > fBase.SampleTime AND fNow.num_of_writes > fBase.num_of_writes AND fNow.io_stall_write_ms > fBase.io_stall_write_ms
    WHERE (fNow.num_of_writes - fBase.num_of_writes) > 0

    UPDATE pNow
        SET [value_delta] = pNow.cntr_value - pFirst.cntr_value,
            [value_per_second] = ((1.0 * pNow.cntr_value - pFirst.cntr_value) / DATEDIFF(ss, pFirst.SampleTime, pNow.SampleTime))
        FROM #PerfmonStats pNow
            INNER JOIN #PerfmonStats pFirst ON pFirst.[object_name] = pNow.[object_name] AND pFirst.counter_name = pNow.counter_name AND (pFirst.instance_name = pNow.instance_name OR (pFirst.instance_name IS NULL AND pNow.instance_name IS NULL))
                AND pNow.ID > pFirst.ID
        WHERE  DATEDIFF(ss, pFirst.SampleTime, pNow.SampleTime) > 0;


    /* If we're within 10 seconds of our projected finish time, do the plan cache analysis. */
    IF DATEDIFF(ss, @FinishSampleTime, SYSDATETIMEOFFSET()) > 10 AND @CheckProcedureCache = 1
        BEGIN

            INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (18, 210, 'Query Stats', 'Plan Cache Analysis Skipped', 'http://www.BrentOzar.com/go/topqueries',
                'Due to excessive load, the plan cache analysis was skipped. To override this, use @ExpertMode = 1.')

        END
    ELSE IF @CheckProcedureCache = 1
        BEGIN


		RAISERROR('@CheckProcedureCache = 1, capturing second pass of plan cache',10,1) WITH NOWAIT;

        /* Populate #QueryStats. SQL 2005 doesn't have query hash or query plan hash. */
		IF @@VERSION LIKE 'Microsoft SQL Server 2005%'
			BEGIN
			IF @FilterPlansByDatabase IS NULL
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, NULL AS query_hash, NULL AS query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											WHERE qs.last_execution_time >= @StartSampleTimeText;';
				END
			ELSE
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, NULL AS query_hash, NULL AS query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
												CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS attr
												INNER JOIN #FilterPlansByDatabase dbs ON CAST(attr.value AS INT) = dbs.DatabaseID
											WHERE qs.last_execution_time >= @StartSampleTimeText
												AND attr.attribute = ''dbid'';';
				END
			END
		ELSE
			BEGIN
			IF @FilterPlansByDatabase IS NULL
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											WHERE qs.last_execution_time >= @StartSampleTimeText';
				END
			ELSE
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS attr
											INNER JOIN #FilterPlansByDatabase dbs ON CAST(attr.value AS INT) = dbs.DatabaseID
											WHERE qs.last_execution_time >= @StartSampleTimeText
												AND attr.attribute = ''dbid'';';
				END
			END
		/* Old version pre-2016/06/13:
        IF @@VERSION LIKE 'Microsoft SQL Server 2005%'
            SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
                                        SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, NULL AS query_hash, NULL AS query_plan_hash, 0
                                        FROM sys.dm_exec_query_stats qs
                                        WHERE qs.last_execution_time >= @StartSampleTimeText;';
        ELSE
            SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
                                        SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, 0
                                        FROM sys.dm_exec_query_stats qs
                                        WHERE qs.last_execution_time >= @StartSampleTimeText;';
		*/
        SET @ParmDefinitions = N'@StartSampleTimeText NVARCHAR(100)';
        SET @Parm1 = CONVERT(NVARCHAR(100), CAST(@StartSampleTime AS DATETIME), 127);

        EXECUTE sp_executesql @StringToExecute, @ParmDefinitions, @StartSampleTimeText = @Parm1;

		RAISERROR('@CheckProcedureCache = 1, totaling up plan cache metrics',10,1) WITH NOWAIT;

        /* Get the totals for the entire plan cache */
        INSERT INTO #QueryStats (Pass, SampleTime, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time)
        SELECT 0 AS Pass, SYSDATETIMEOFFSET(), SUM(execution_count), SUM(total_worker_time), SUM(total_physical_reads), SUM(total_logical_writes), SUM(total_logical_reads), SUM(total_clr_time), SUM(total_elapsed_time), MIN(creation_time)
            FROM sys.dm_exec_query_stats qs;


		RAISERROR('@CheckProcedureCache = 1, so analyzing execution plans',10,1) WITH NOWAIT;
        /*
        Pick the most resource-intensive queries to review. Update the Points field
        in #QueryStats - if a query is in the top 10 for logical reads, CPU time,
        duration, or execution, add 1 to its points.
        */
        WITH qsTop AS (
        SELECT TOP 10 qsNow.ID
        FROM #QueryStats qsNow
          INNER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
        WHERE qsNow.total_elapsed_time > qsFirst.total_elapsed_time
            AND qsNow.Pass = 2
            AND qsNow.total_elapsed_time - qsFirst.total_elapsed_time > 1000000 /* Only queries with over 1 second of runtime */
        ORDER BY (qsNow.total_elapsed_time - COALESCE(qsFirst.total_elapsed_time, 0)) DESC)
        UPDATE #QueryStats
            SET Points = Points + 1
            FROM #QueryStats qs
            INNER JOIN qsTop ON qs.ID = qsTop.ID;

        WITH qsTop AS (
        SELECT TOP 10 qsNow.ID
        FROM #QueryStats qsNow
          INNER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
        WHERE qsNow.total_logical_reads > qsFirst.total_logical_reads
            AND qsNow.Pass = 2
            AND qsNow.total_logical_reads - qsFirst.total_logical_reads > 1000 /* Only queries with over 1000 reads */
        ORDER BY (qsNow.total_logical_reads - COALESCE(qsFirst.total_logical_reads, 0)) DESC)
        UPDATE #QueryStats
            SET Points = Points + 1
            FROM #QueryStats qs
            INNER JOIN qsTop ON qs.ID = qsTop.ID;

        WITH qsTop AS (
        SELECT TOP 10 qsNow.ID
        FROM #QueryStats qsNow
          INNER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
        WHERE qsNow.total_worker_time > qsFirst.total_worker_time
            AND qsNow.Pass = 2
            AND qsNow.total_worker_time - qsFirst.total_worker_time > 1000000 /* Only queries with over 1 second of worker time */
        ORDER BY (qsNow.total_worker_time - COALESCE(qsFirst.total_worker_time, 0)) DESC)
        UPDATE #QueryStats
            SET Points = Points + 1
            FROM #QueryStats qs
            INNER JOIN qsTop ON qs.ID = qsTop.ID;

        WITH qsTop AS (
        SELECT TOP 10 qsNow.ID
        FROM #QueryStats qsNow
          INNER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
        WHERE qsNow.execution_count > qsFirst.execution_count
            AND qsNow.Pass = 2
            AND (qsNow.total_elapsed_time - qsFirst.total_elapsed_time > 1000000 /* Only queries with over 1 second of runtime */
                OR qsNow.total_logical_reads - qsFirst.total_logical_reads > 1000 /* Only queries with over 1000 reads */
                OR qsNow.total_worker_time - qsFirst.total_worker_time > 1000000 /* Only queries with over 1 second of worker time */)
        ORDER BY (qsNow.execution_count - COALESCE(qsFirst.execution_count, 0)) DESC)
        UPDATE #QueryStats
            SET Points = Points + 1
            FROM #QueryStats qs
            INNER JOIN qsTop ON qs.ID = qsTop.ID;

        /* Query Stats - CheckID 17 - Most Resource-Intensive Queries */
        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, QueryStatsNowID, QueryStatsFirstID, PlanHandle)
        SELECT 17, 210, 'Query Stats', 'Most Resource-Intensive Queries', 'http://www.BrentOzar.com/go/topqueries',
            'Query stats during the sample:' + @LineFeed +
            'Executions: ' + CAST(qsNow.execution_count - (COALESCE(qsFirst.execution_count, 0)) AS NVARCHAR(100)) + @LineFeed +
            'Elapsed Time: ' + CAST(qsNow.total_elapsed_time - (COALESCE(qsFirst.total_elapsed_time, 0)) AS NVARCHAR(100)) + @LineFeed +
            'CPU Time: ' + CAST(qsNow.total_worker_time - (COALESCE(qsFirst.total_worker_time, 0)) AS NVARCHAR(100)) + @LineFeed +
            'Logical Reads: ' + CAST(qsNow.total_logical_reads - (COALESCE(qsFirst.total_logical_reads, 0)) AS NVARCHAR(100)) + @LineFeed +
            'Logical Writes: ' + CAST(qsNow.total_logical_writes - (COALESCE(qsFirst.total_logical_writes, 0)) AS NVARCHAR(100)) + @LineFeed +
            'CLR Time: ' + CAST(qsNow.total_clr_time - (COALESCE(qsFirst.total_clr_time, 0)) AS NVARCHAR(100)) + @LineFeed +
            @LineFeed + @LineFeed + 'Query stats since ' + CONVERT(NVARCHAR(100), qsNow.creation_time ,121) + @LineFeed +
            'Executions: ' + CAST(qsNow.execution_count AS NVARCHAR(100)) +
                    CASE qsTotal.execution_count WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.execution_count / qsTotal.execution_count AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            'Elapsed Time: ' + CAST(qsNow.total_elapsed_time AS NVARCHAR(100)) +
                    CASE qsTotal.total_elapsed_time WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.total_elapsed_time / qsTotal.total_elapsed_time AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            'CPU Time: ' + CAST(qsNow.total_worker_time AS NVARCHAR(100)) +
                    CASE qsTotal.total_worker_time WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.total_worker_time / qsTotal.total_worker_time AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            'Logical Reads: ' + CAST(qsNow.total_logical_reads AS NVARCHAR(100)) +
                    CASE qsTotal.total_logical_reads WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.total_logical_reads / qsTotal.total_logical_reads AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            'Logical Writes: ' + CAST(qsNow.total_logical_writes AS NVARCHAR(100)) +
                    CASE qsTotal.total_logical_writes WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.total_logical_writes / qsTotal.total_logical_writes AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            'CLR Time: ' + CAST(qsNow.total_clr_time AS NVARCHAR(100)) +
                    CASE qsTotal.total_clr_time WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.total_clr_time / qsTotal.total_clr_time AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            --@LineFeed + @LineFeed + 'Query hash: ' + CAST(qsNow.query_hash AS NVARCHAR(100)) + @LineFeed +
            --@LineFeed + @LineFeed + 'Query plan hash: ' + CAST(qsNow.query_plan_hash AS NVARCHAR(100)) +
            @LineFeed AS Details,
            'See the URL for tuning tips on why this query may be consuming resources.' AS HowToStopIt,
            qp.query_plan,
            QueryText = SUBSTRING(st.text,
                 (qsNow.statement_start_offset / 2) + 1,
                 ((CASE qsNow.statement_end_offset
                   WHEN -1 THEN DATALENGTH(st.text)
                   ELSE qsNow.statement_end_offset
                   END - qsNow.statement_start_offset) / 2) + 1),
            qsNow.ID AS QueryStatsNowID,
            qsFirst.ID AS QueryStatsFirstID,
            qsNow.plan_handle AS PlanHandle
            FROM #QueryStats qsNow
                INNER JOIN #QueryStats qsTotal ON qsTotal.Pass = 0
                LEFT OUTER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
                CROSS APPLY sys.dm_exec_sql_text(qsNow.sql_handle) AS st
                CROSS APPLY sys.dm_exec_query_plan(qsNow.plan_handle) AS qp
            WHERE qsNow.Points > 0 AND st.text IS NOT NULL AND qp.query_plan IS NOT NULL

            UPDATE #BlitzFirstResults
                SET DatabaseID = CAST(attr.value AS INT),
                DatabaseName = DB_NAME(CAST(attr.value AS INT))
            FROM #BlitzFirstResults
                CROSS APPLY sys.dm_exec_plan_attributes(#BlitzFirstResults.PlanHandle) AS attr
            WHERE attr.attribute = 'dbid'


        END /* IF DATEDIFF(ss, @FinishSampleTime, SYSDATETIMEOFFSET()) > 10 AND @CheckProcedureCache = 1 */


	RAISERROR('Analyzing changes between first and second passes of DMVs',10,1) WITH NOWAIT;

    /* Wait Stats - CheckID 6 */
    /* Compare the current wait stats to the sample we took at the start, and insert the top 10 waits. */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, DetailsInt)
    SELECT TOP 10 6 AS CheckID,
        200 AS Priority,
        'Wait Stats' AS FindingGroup,
        wNow.wait_type AS Finding,
        N'http://www.brentozar.com/sql/wait-stats/#' + wNow.wait_type AS URL,
        'For ' + CAST(((wNow.wait_time_ms - COALESCE(wBase.wait_time_ms,0)) / 1000) AS NVARCHAR(100)) + ' seconds over the last ' + CASE @Seconds WHEN 0 THEN (CAST(DATEDIFF(dd,@StartSampleTime,@FinishSampleTime) AS NVARCHAR(10)) + ' days') ELSE (CAST(@Seconds AS NVARCHAR(10)) + ' seconds') END + ', SQL Server was waiting on this particular bottleneck.' + @LineFeed + @LineFeed AS Details,
        'See the URL for more details on how to mitigate this wait type.' AS HowToStopIt,
        ((wNow.wait_time_ms - COALESCE(wBase.wait_time_ms,0)) / 1000) AS DetailsInt
    FROM #WaitStats wNow
    LEFT OUTER JOIN #WaitStats wBase ON wNow.wait_type = wBase.wait_type AND wNow.SampleTime > wBase.SampleTime
    WHERE wNow.wait_time_ms > (wBase.wait_time_ms + (.5 * (DATEDIFF(ss,@StartSampleTime,@FinishSampleTime)) * 1000)) /* Only look for things we've actually waited on for half of the time or more */
    ORDER BY (wNow.wait_time_ms - COALESCE(wBase.wait_time_ms,0)) DESC;

    /* Server Performance - Slow Data File Reads - CheckID 11 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, DatabaseID, DatabaseName)
    SELECT TOP 10 11 AS CheckID,
        50 AS Priority,
        'Server Performance' AS FindingGroup,
        'Slow Data File Reads' AS Finding,
        'http://www.BrentOzar.com/go/slow/' AS URL,
        'File: ' + fNow.PhysicalName + @LineFeed
            + 'Number of reads during the sample: ' + CAST((fNow.num_of_reads - fBase.num_of_reads) AS NVARCHAR(20)) + @LineFeed
            + 'Seconds spent waiting on storage for these reads: ' + CAST(((fNow.io_stall_read_ms - fBase.io_stall_read_ms) / 1000.0) AS NVARCHAR(20)) + @LineFeed
            + 'Average read latency during the sample: ' + CAST(((fNow.io_stall_read_ms - fBase.io_stall_read_ms) / (fNow.num_of_reads - fBase.num_of_reads) ) AS NVARCHAR(20)) + ' milliseconds' + @LineFeed
            + 'Microsoft guidance for data file read speed: 20ms or less.' + @LineFeed + @LineFeed AS Details,
        'See the URL for more details on how to mitigate this wait type.' AS HowToStopIt,
        fNow.DatabaseID,
        fNow.DatabaseName
    FROM #FileStats fNow
    INNER JOIN #FileStats fBase ON fNow.DatabaseID = fBase.DatabaseID AND fNow.FileID = fBase.FileID AND fNow.SampleTime > fBase.SampleTime AND fNow.num_of_reads > fBase.num_of_reads AND fNow.io_stall_read_ms > (fBase.io_stall_read_ms + 1000)
    WHERE (fNow.io_stall_read_ms - fBase.io_stall_read_ms) / (fNow.num_of_reads - fBase.num_of_reads) >= @FileLatencyThresholdMS
        AND fNow.TypeDesc = 'ROWS'
    ORDER BY (fNow.io_stall_read_ms - fBase.io_stall_read_ms) / (fNow.num_of_reads - fBase.num_of_reads) DESC;

    /* Server Performance - Slow Log File Writes - CheckID 12 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, DatabaseID, DatabaseName)
    SELECT TOP 10 12 AS CheckID,
        50 AS Priority,
        'Server Performance' AS FindingGroup,
        'Slow Log File Writes' AS Finding,
        'http://www.BrentOzar.com/go/slow/' AS URL,
        'File: ' + fNow.PhysicalName + @LineFeed
            + 'Number of writes during the sample: ' + CAST((fNow.num_of_writes - fBase.num_of_writes) AS NVARCHAR(20)) + @LineFeed
            + 'Seconds spent waiting on storage for these writes: ' + CAST(((fNow.io_stall_write_ms - fBase.io_stall_write_ms) / 1000.0) AS NVARCHAR(20)) + @LineFeed
            + 'Average write latency during the sample: ' + CAST(((fNow.io_stall_write_ms - fBase.io_stall_write_ms) / (fNow.num_of_writes - fBase.num_of_writes) ) AS NVARCHAR(20)) + ' milliseconds' + @LineFeed
            + 'Microsoft guidance for log file write speed: 3ms or less.' + @LineFeed + @LineFeed AS Details,
        'See the URL for more details on how to mitigate this wait type.' AS HowToStopIt,
        fNow.DatabaseID,
        fNow.DatabaseName
    FROM #FileStats fNow
    INNER JOIN #FileStats fBase ON fNow.DatabaseID = fBase.DatabaseID AND fNow.FileID = fBase.FileID AND fNow.SampleTime > fBase.SampleTime AND fNow.num_of_writes > fBase.num_of_writes AND fNow.io_stall_write_ms > (fBase.io_stall_write_ms + 1000)
    WHERE (fNow.io_stall_write_ms - fBase.io_stall_write_ms) / (fNow.num_of_writes - fBase.num_of_writes) >= @FileLatencyThresholdMS
        AND fNow.TypeDesc = 'LOG'
    ORDER BY (fNow.io_stall_write_ms - fBase.io_stall_write_ms) / (fNow.num_of_writes - fBase.num_of_writes) DESC;


    /* SQL Server Internal Maintenance - Log File Growing - CheckID 13 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 13 AS CheckID,
        1 AS Priority,
        'SQL Server Internal Maintenance' AS FindingGroup,
        'Log File Growing' AS Finding,
        'http://www.BrentOzar.com/askbrent/file-growing/' AS URL,
        'Number of growths during the sample: ' + CAST(ps.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'Determined by sampling Perfmon counter ' + ps.object_name + ' - ' + ps.counter_name + @LineFeed AS Details,
        'Pre-grow data and log files during maintenance windows so that they do not grow during production loads. See the URL for more details.'  AS HowToStopIt
    FROM #PerfmonStats ps
    WHERE ps.Pass = 2
        AND object_name = @ServiceName + ':Databases'
        AND counter_name = 'Log Growths'
        AND value_delta > 0


    /* SQL Server Internal Maintenance - Log File Shrinking - CheckID 14 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 14 AS CheckID,
        1 AS Priority,
        'SQL Server Internal Maintenance' AS FindingGroup,
        'Log File Shrinking' AS Finding,
        'http://www.BrentOzar.com/askbrent/file-shrinking/' AS URL,
        'Number of shrinks during the sample: ' + CAST(ps.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'Determined by sampling Perfmon counter ' + ps.object_name + ' - ' + ps.counter_name + @LineFeed AS Details,
        'Pre-grow data and log files during maintenance windows so that they do not grow during production loads. See the URL for more details.' AS HowToStopIt
    FROM #PerfmonStats ps
    WHERE ps.Pass = 2
        AND object_name = @ServiceName + ':Databases'
        AND counter_name = 'Log Shrinks'
        AND value_delta > 0

    /* Query Problems - Compilations/Sec High - CheckID 15 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 15 AS CheckID,
        50 AS Priority,
        'Query Problems' AS FindingGroup,
        'Compilations/Sec High' AS Finding,
        'http://www.BrentOzar.com/askbrent/compilations/' AS URL,
        'Number of batch requests during the sample: ' + CAST(ps.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'Number of compilations during the sample: ' + CAST(psComp.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'For OLTP environments, Microsoft recommends that 90% of batch requests should hit the plan cache, and not be compiled from scratch. We are exceeding that threshold.' + @LineFeed AS Details,
        'Find out why plans are not being reused, and consider enabling Forced Parameterization. See the URL for more details.' AS HowToStopIt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats psComp ON psComp.Pass = 2 AND psComp.object_name = @ServiceName + ':SQL Statistics' AND psComp.counter_name = 'SQL Compilations/sec' AND psComp.value_delta > 0
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':SQL Statistics'
        AND ps.counter_name = 'Batch Requests/sec'
        AND ps.value_delta > (1000 * @Seconds) /* Ignore servers sitting idle */
        AND (psComp.value_delta * 10) > ps.value_delta /* Compilations are more than 10% of batch requests per second */

    /* Query Problems - Re-Compilations/Sec High - CheckID 16 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 16 AS CheckID,
        50 AS Priority,
        'Query Problems' AS FindingGroup,
        'Re-Compilations/Sec High' AS Finding,
        'http://www.BrentOzar.com/askbrent/recompilations/' AS URL,
        'Number of batch requests during the sample: ' + CAST(ps.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'Number of recompilations during the sample: ' + CAST(psComp.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'More than 10% of our queries are being recompiled. This is typically due to statistics changing on objects.' + @LineFeed AS Details,
        'Find out which objects are changing so quickly that they hit the stats update threshold. See the URL for more details.' AS HowToStopIt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats psComp ON psComp.Pass = 2 AND psComp.object_name = @ServiceName + ':SQL Statistics' AND psComp.counter_name = 'SQL Re-Compilations/sec' AND psComp.value_delta > 0
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':SQL Statistics'
        AND ps.counter_name = 'Batch Requests/sec'
        AND ps.value_delta > (1000 * @Seconds) /* Ignore servers sitting idle */
        AND (psComp.value_delta * 10) > ps.value_delta /* Recompilations are more than 10% of batch requests per second */

    /* Server Info - Batch Requests per Sec - CheckID 19 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, DetailsInt)
    SELECT 19 AS CheckID,
        250 AS Priority,
        'Server Info' AS FindingGroup,
        'Batch Requests per Sec' AS Finding,
        'http://www.BrentOzar.com/go/measure' AS URL,
        CAST(ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS NVARCHAR(20)) AS Details,
        ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS DetailsInt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats ps1 ON ps.object_name = ps1.object_name AND ps.counter_name = ps1.counter_name AND ps1.Pass = 1
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':SQL Statistics'
        AND ps.counter_name = 'Batch Requests/sec';


        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','SQL Compilations/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','SQL Re-Compilations/sec', NULL)

    /* Server Info - SQL Compilations/sec - CheckID 25 */
    IF @ExpertMode = 1
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, DetailsInt)
    SELECT 25 AS CheckID,
        250 AS Priority,
        'Server Info' AS FindingGroup,
        'SQL Compilations per Sec' AS Finding,
        'http://www.BrentOzar.com/go/measure' AS URL,
        CAST(ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS NVARCHAR(20)) AS Details,
        ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS DetailsInt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats ps1 ON ps.object_name = ps1.object_name AND ps.counter_name = ps1.counter_name AND ps1.Pass = 1
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':SQL Statistics'
        AND ps.counter_name = 'SQL Compilations/sec';

    /* Server Info - SQL Re-Compilations/sec - CheckID 26 */
    IF @ExpertMode = 1
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, DetailsInt)
    SELECT 26 AS CheckID,
        250 AS Priority,
        'Server Info' AS FindingGroup,
        'SQL Re-Compilations per Sec' AS Finding,
        'http://www.BrentOzar.com/go/measure' AS URL,
        CAST(ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS NVARCHAR(20)) AS Details,
        ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS DetailsInt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats ps1 ON ps.object_name = ps1.object_name AND ps.counter_name = ps1.counter_name AND ps1.Pass = 1
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':SQL Statistics'
        AND ps.counter_name = 'SQL Re-Compilations/sec';

    /* Server Info - Wait Time per Core per Sec - CheckID 20 */
    IF @Seconds > 0
    BEGIN
        WITH waits1(SampleTime, waits_ms) AS (SELECT SampleTime, SUM(ws1.wait_time_ms) FROM #WaitStats ws1 WHERE ws1.Pass = 1 GROUP BY SampleTime),
        waits2(SampleTime, waits_ms) AS (SELECT SampleTime, SUM(ws2.wait_time_ms) FROM #WaitStats ws2 WHERE ws2.Pass = 2 GROUP BY SampleTime),
        cores(cpu_count) AS (SELECT SUM(1) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE' AND is_online = 1)
        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, DetailsInt)
        SELECT 19 AS CheckID,
            250 AS Priority,
            'Server Info' AS FindingGroup,
            'Wait Time per Core per Sec' AS Finding,
            'http://www.BrentOzar.com/go/measure' AS URL,
            CAST((waits2.waits_ms - waits1.waits_ms) / 1000 / i.cpu_count / DATEDIFF(ss, waits1.SampleTime, waits2.SampleTime) AS NVARCHAR(20)) AS Details,
            (waits2.waits_ms - waits1.waits_ms) / 1000 / i.cpu_count / DATEDIFF(ss, waits1.SampleTime, waits2.SampleTime) AS DetailsInt
        FROM cores i
          CROSS JOIN waits1
          CROSS JOIN waits2;
    END

    /* Server Performance - High CPU Utilization CheckID 24 */
    IF @Seconds >= 30
        BEGIN
        /* If we're waiting 30+ seconds, run this check at the end.
           We get this data from the ring buffers, and it's only updated once per minute, so might
           as well get it now - whereas if we're checking 30+ seconds, it might get updated by the
           end of our sp_BlitzFirst session. */
        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
        SELECT 24, 50, 'Server Performance', 'High CPU Utilization', CAST(100 - SystemIdle AS NVARCHAR(20)) + N'%. Ring buffer details: ' + CAST(record AS NVARCHAR(4000)), 100 - SystemIdle, 'http://www.BrentOzar.com/go/cpu'
            FROM (
                SELECT record,
                    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle
                FROM (
                    SELECT TOP 1 CONVERT(XML, record) AS record
                    FROM sys.dm_os_ring_buffers
                    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                    AND record LIKE '%<SystemHealth>%'
                    ORDER BY timestamp DESC) AS rb
            ) AS y
            WHERE 100 - SystemIdle >= 50

        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
        SELECT 23, 250, 'Server Info', 'CPU Utilization', CAST(100 - SystemIdle AS NVARCHAR(20)) + N'%. Ring buffer details: ' + CAST(record AS NVARCHAR(4000)), 100 - SystemIdle, 'http://www.BrentOzar.com/go/cpu'
            FROM (
                SELECT record,
                    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle
                FROM (
                    SELECT TOP 1 CONVERT(XML, record) AS record
                    FROM sys.dm_os_ring_buffers
                    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                    AND record LIKE '%<SystemHealth>%'
                    ORDER BY timestamp DESC) AS rb
            ) AS y

        END /* IF @Seconds < 30 */

	RAISERROR('Analysis finished, outputting results',10,1) WITH NOWAIT;


    /* If we didn't find anything, apologize. */
    IF NOT EXISTS (SELECT * FROM #BlitzFirstResults WHERE Priority < 250)
    BEGIN

        INSERT  INTO #BlitzFirstResults
                ( CheckID ,
                  Priority ,
                  FindingsGroup ,
                  Finding ,
                  URL ,
                  Details
                )
        VALUES  ( -1 ,
                  1 ,
                  'No Problems Found' ,
                  'From Your Community Volunteers' ,
                  'http://FirstResponderKit.org/' ,
                  'Try running our more in-depth checks with sp_Blitz, or there may not be an unusual SQL Server performance problem. '
                );

    END /*IF NOT EXISTS (SELECT * FROM #BlitzFirstResults) */

        /* Add credits for the nice folks who put so much time into building and maintaining this for free: */
        INSERT  INTO #BlitzFirstResults
                ( CheckID ,
                  Priority ,
                  FindingsGroup ,
                  Finding ,
                  URL ,
                  Details
                )
        VALUES  ( -1 ,
                  255 ,
                  'Thanks!' ,
                  'From Your Community Volunteers' ,
                  'http://FirstResponderKit.org/' ,
                  'To get help or add your own contributions, join us at http://FirstResponderKit.org.'
                );

        INSERT  INTO #BlitzFirstResults
                ( CheckID ,
                  Priority ,
                  FindingsGroup ,
                  Finding ,
                  URL ,
                  Details

                )
        VALUES  ( -1 ,
                  0 ,
                  'sp_BlitzFirst ' + CAST(CONVERT(DATETIMEOFFSET, @VersionDate, 102) AS VARCHAR(100)),
                  'From Your Community Volunteers' ,
                  'http://FirstResponderKit.org/' ,
                  'We hope you found this tool useful.'
                );

                /* Outdated sp_BlitzFirst - sp_BlitzFirst is Over 6 Months Old */
                IF DATEDIFF(MM, @VersionDate, SYSDATETIMEOFFSET()) > 6
                    BEGIN
                        INSERT  INTO #BlitzFirstResults
                                ( CheckID ,
                                    Priority ,
                                    FindingsGroup ,
                                    Finding ,
                                    URL ,
                                    Details
                                )
                                SELECT 27 AS CheckID ,
                                        0 AS Priority ,
                                        'Outdated sp_BlitzFirst' AS FindingsGroup ,
                                        'sp_BlitzFirst is Over 6 Months Old' AS Finding ,
                                        'http://FirstResponderKit.org/' AS URL ,
                                        'Some things get better with age, like fine wine and your T-SQL. However, sp_BlitzFirst is not one of those things - time to go download the current one.' AS Details
                    END



    /* @OutputTableName lets us export the results to a permanent table */
    IF @OutputDatabaseName IS NOT NULL
        AND @OutputSchemaName IS NOT NULL
        AND @OutputTableName IS NOT NULL
        AND @OutputTableName NOT LIKE '#%'
        AND EXISTS ( SELECT *
                     FROM   sys.databases
                     WHERE  QUOTENAME([name]) = @OutputDatabaseName)
    BEGIN
        SET @StringToExecute = 'USE '
            + @OutputDatabaseName
            + '; IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName
            + ''') AND NOT EXISTS (SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.TABLES WHERE QUOTENAME(TABLE_SCHEMA) = '''
            + @OutputSchemaName + ''' AND QUOTENAME(TABLE_NAME) = '''
            + @OutputTableName + ''') CREATE TABLE '
            + @OutputSchemaName + '.'
            + @OutputTableName
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                CheckID INT NOT NULL,
                Priority TINYINT NOT NULL,
                FindingsGroup VARCHAR(50) NOT NULL,
                Finding VARCHAR(200) NOT NULL,
                URL VARCHAR(200) NOT NULL,
                Details NVARCHAR(4000) NULL,
                HowToStopIt [XML] NULL,
                QueryPlan [XML] NULL,
                QueryText NVARCHAR(MAX) NULL,
                StartTime DATETIMEOFFSET NULL,
                LoginName NVARCHAR(128) NULL,
                NTUserName NVARCHAR(128) NULL,
                OriginalLoginName NVARCHAR(128) NULL,
                ProgramName NVARCHAR(128) NULL,
                HostName NVARCHAR(128) NULL,
                DatabaseID INT NULL,
                DatabaseName NVARCHAR(128) NULL,
                OpenTransactionCount INT NULL,
                DetailsInt INT NULL,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'

        EXEC(@StringToExecute);
        SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName + ''') INSERT '
            + @OutputDatabaseName + '.'
            + @OutputSchemaName + '.'
            + @OutputTableName
            + ' (ServerName, CheckDate, CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, StartTime, LoginName, NTUserName, OriginalLoginName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount, DetailsInt) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + (CONVERT(NVARCHAR(100), @StartSampleTime, 127)) + ''', CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, StartTime, LoginName, NTUserName, OriginalLoginName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount, DetailsInt FROM #BlitzFirstResults ORDER BY Priority , FindingsGroup , Finding , Details';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableName, 2, 2) = '##')
    BEGIN
        SET @StringToExecute = N' IF (OBJECT_ID(''tempdb..'
            + @OutputTableName
            + ''') IS NULL) CREATE TABLE '
            + @OutputTableName
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                CheckID INT NOT NULL,
                Priority TINYINT NOT NULL,
                FindingsGroup VARCHAR(50) NOT NULL,
                Finding VARCHAR(200) NOT NULL,
                URL VARCHAR(200) NOT NULL,
                Details NVARCHAR(4000) NULL,
                HowToStopIt [XML] NULL,
                QueryPlan [XML] NULL,
                QueryText NVARCHAR(MAX) NULL,
                StartTime DATETIMEOFFSET NULL,
                LoginName NVARCHAR(128) NULL,
                NTUserName NVARCHAR(128) NULL,
                OriginalLoginName NVARCHAR(128) NULL,
                ProgramName NVARCHAR(128) NULL,
                HostName NVARCHAR(128) NULL,
                DatabaseID INT NULL,
                DatabaseName NVARCHAR(128) NULL,
                OpenTransactionCount INT NULL,
                DetailsInt INT NULL,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
            + ' INSERT '
            + @OutputTableName
            + ' (ServerName, CheckDate, CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, StartTime, LoginName, NTUserName, OriginalLoginName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount, DetailsInt) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 127) + ''', CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, StartTime, LoginName, NTUserName, OriginalLoginName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount, DetailsInt FROM #BlitzFirstResults ORDER BY Priority , FindingsGroup , Finding , Details';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableName, 2, 1) = '#')
    BEGIN
        RAISERROR('Due to the nature of Dymamic SQL, only global (i.e. double pound (##)) temp tables are supported for @OutputTableName', 16, 0)
    END

    /* @OutputTableNameFileStats lets us export the results to a permanent table */
    IF @OutputDatabaseName IS NOT NULL
        AND @OutputSchemaName IS NOT NULL
        AND @OutputTableNameFileStats IS NOT NULL
        AND @OutputTableNameFileStats NOT LIKE '#%'
        AND EXISTS ( SELECT *
                     FROM   sys.databases
                     WHERE  QUOTENAME([name]) = @OutputDatabaseName)
    BEGIN
        /* Create the table */
        SET @StringToExecute = 'USE '
            + @OutputDatabaseName
            + '; IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName
            + ''') AND NOT EXISTS (SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.TABLES WHERE QUOTENAME(TABLE_SCHEMA) = '''
            + @OutputSchemaName + ''' AND QUOTENAME(TABLE_NAME) = '''
            + @OutputTableNameFileStats + ''') CREATE TABLE '
            + @OutputSchemaName + '.'
            + @OutputTableNameFileStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                DatabaseID INT NOT NULL,
                FileID INT NOT NULL,
                DatabaseName NVARCHAR(256) ,
                FileLogicalName NVARCHAR(256) ,
                TypeDesc NVARCHAR(60) ,
                SizeOnDiskMB BIGINT ,
                io_stall_read_ms BIGINT ,
                num_of_reads BIGINT ,
                bytes_read BIGINT ,
                io_stall_write_ms BIGINT ,
                num_of_writes BIGINT ,
                bytes_written BIGINT,
                PhysicalName NVARCHAR(520) ,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
        EXEC(@StringToExecute);

        /* Create the view */
        SET @ObjectFullName = @OutputDatabaseName + N'.' + @OutputSchemaName + N'.' +  @OutputTableNameFileStats_View;
        IF OBJECT_ID(@ObjectFullName) IS NULL
            BEGIN
            SET @StringToExecute = 'USE '
                + @OutputDatabaseName
                + '; EXEC (''CREATE VIEW '
                + @OutputSchemaName + '.'
                + @OutputTableNameFileStats_View + ' AS ' + @LineFeed
                + 'SELECT f.ServerName, f.CheckDate, f.DatabaseID, f.DatabaseName, f.FileID, f.FileLogicalName, f.TypeDesc, f.PhysicalName, f.SizeOnDiskMB' + @LineFeed
                + ', DATEDIFF(ss, fPrior.CheckDate, f.CheckDate) AS ElapsedSeconds' + @LineFeed
                + ', (f.SizeOnDiskMB - fPrior.SizeOnDiskMB) AS SizeOnDiskMBgrowth' + @LineFeed
                + ', (f.io_stall_read_ms - fPrior.io_stall_read_ms) AS io_stall_read_ms' + @LineFeed
                + ', io_stall_read_ms_average = CASE WHEN (f.num_of_reads - fPrior.num_of_reads) = 0 THEN 0 ELSE (f.io_stall_read_ms - fPrior.io_stall_read_ms) / (f.num_of_reads - fPrior.num_of_reads) END' + @LineFeed
                + ', (f.num_of_reads - fPrior.num_of_reads) AS num_of_reads' + @LineFeed
                + ', (f.bytes_read - fPrior.bytes_read) / 1024.0 / 1024.0 AS megabytes_read' + @LineFeed
                + ', (f.io_stall_write_ms - fPrior.io_stall_write_ms) AS io_stall_write_ms' + @LineFeed
                + ', io_stall_write_ms_average = CASE WHEN (f.num_of_writes - fPrior.num_of_writes) = 0 THEN 0 ELSE (f.io_stall_write_ms - fPrior.io_stall_write_ms) / (f.num_of_writes - fPrior.num_of_writes) END' + @LineFeed
                + ', (f.num_of_writes - fPrior.num_of_writes) AS num_of_writes' + @LineFeed
                + ', (f.bytes_written - fPrior.bytes_written) / 1024.0 / 1024.0 AS megabytes_written' + @LineFeed
                + 'FROM ' + @OutputSchemaName + '.' + @OutputTableNameFileStats + ' f' + @LineFeed
                + 'INNER JOIN ' + @OutputSchemaName + '.' + @OutputTableNameFileStats + ' fPrior ON f.ServerName = fPrior.ServerName AND f.DatabaseID = fPrior.DatabaseID AND f.FileID = fPrior.FileID AND f.CheckDate > fPrior.CheckDate' + @LineFeed
                + 'LEFT OUTER JOIN ' + @OutputSchemaName + '.' + @OutputTableNameFileStats + ' fMiddle ON f.ServerName = fMiddle.ServerName AND f.DatabaseID = fMiddle.DatabaseID AND f.FileID = fMiddle.FileID AND f.CheckDate > fMiddle.CheckDate AND fMiddle.CheckDate > fPrior.CheckDate' + @LineFeed
                + 'WHERE fMiddle.ID IS NULL;'')'
            EXEC(@StringToExecute);
            END

        SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName + ''') INSERT '
            + @OutputDatabaseName + '.'
            + @OutputSchemaName + '.'
            + @OutputTableNameFileStats
            + ' (ServerName, CheckDate, DatabaseID, FileID, DatabaseName, FileLogicalName, TypeDesc, SizeOnDiskMB, io_stall_read_ms, num_of_reads, bytes_read, io_stall_write_ms, num_of_writes, bytes_written, PhysicalName) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 127) + ''', '
            + 'DatabaseID, FileID, DatabaseName, FileLogicalName, TypeDesc, SizeOnDiskMB, io_stall_read_ms, num_of_reads, bytes_read, io_stall_write_ms, num_of_writes, bytes_written, PhysicalName FROM #FileStats WHERE Pass = 2';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableNameFileStats, 2, 2) = '##')
    BEGIN
        SET @StringToExecute = N' IF (OBJECT_ID(''tempdb..'
            + @OutputTableNameFileStats
            + ''') IS NULL) CREATE TABLE '
            + @OutputTableNameFileStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                DatabaseID INT NOT NULL,
                FileID INT NOT NULL,
                DatabaseName NVARCHAR(256) ,
                FileLogicalName NVARCHAR(256) ,
                TypeDesc NVARCHAR(60) ,
                SizeOnDiskMB BIGINT ,
                io_stall_read_ms BIGINT ,
                num_of_reads BIGINT ,
                bytes_read BIGINT ,
                io_stall_write_ms BIGINT ,
                num_of_writes BIGINT ,
                bytes_written BIGINT,
                PhysicalName NVARCHAR(520) ,
                DetailsInt INT NULL,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
            + ' INSERT '
            + @OutputTableNameFileStats
            + ' (ServerName, CheckDate, DatabaseID, FileID, DatabaseName, FileLogicalName, TypeDesc, SizeOnDiskMB, io_stall_read_ms, num_of_reads, bytes_read, io_stall_write_ms, num_of_writes, bytes_written, PhysicalName) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 127) + ''', '
            + 'DatabaseID, FileID, DatabaseName, FileLogicalName, TypeDesc, SizeOnDiskMB, io_stall_read_ms, num_of_reads, bytes_read, io_stall_write_ms, num_of_writes, bytes_written, PhysicalName FROM #FileStats WHERE Pass = 2';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableNameFileStats, 2, 1) = '#')
    BEGIN
        RAISERROR('Due to the nature of Dymamic SQL, only global (i.e. double pound (##)) temp tables are supported for @OutputTableName', 16, 0)
    END


    /* @OutputTableNamePerfmonStats lets us export the results to a permanent table */
    IF @OutputDatabaseName IS NOT NULL
        AND @OutputSchemaName IS NOT NULL
        AND @OutputTableNamePerfmonStats IS NOT NULL
        AND @OutputTableNamePerfmonStats NOT LIKE '#%'
        AND EXISTS ( SELECT *
                     FROM   sys.databases
                     WHERE  QUOTENAME([name]) = @OutputDatabaseName)
    BEGIN
        /* Create the table */
        SET @StringToExecute = 'USE '
            + @OutputDatabaseName
            + '; IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName
            + ''') AND NOT EXISTS (SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.TABLES WHERE QUOTENAME(TABLE_SCHEMA) = '''
            + @OutputSchemaName + ''' AND QUOTENAME(TABLE_NAME) = '''
            + @OutputTableNamePerfmonStats + ''') CREATE TABLE '
            + @OutputSchemaName + '.'
            + @OutputTableNamePerfmonStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                [object_name] NVARCHAR(128) NOT NULL,
                [counter_name] NVARCHAR(128) NOT NULL,
                [instance_name] NVARCHAR(128) NULL,
                [cntr_value] BIGINT NULL,
                [cntr_type] INT NOT NULL,
                [value_delta] BIGINT NULL,
                [value_per_second] DECIMAL(18,2) NULL,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
        EXEC(@StringToExecute);

        /* Create the view */
        SET @ObjectFullName = @OutputDatabaseName + N'.' + @OutputSchemaName + N'.' +  @OutputTableNamePerfmonStats_View;
        IF OBJECT_ID(@ObjectFullName) IS NULL
            BEGIN
            SET @StringToExecute = 'USE '
                + @OutputDatabaseName
                + '; EXEC (''CREATE VIEW '
                + @OutputSchemaName + '.'
                + @OutputTableNamePerfmonStats_View + ' AS ' + @LineFeed
                + 'SELECT p.ServerName, p.CheckDate, p.object_name, p.counter_name, p.instance_name' + @LineFeed
                + ', DATEDIFF(ss, pPrior.CheckDate, p.CheckDate) AS ElapsedSeconds' + @LineFeed
                + ', p.cntr_value' + @LineFeed
                + ', p.cntr_type' + @LineFeed
                + ', (p.cntr_value - pPrior.cntr_value) AS cntr_delta' + @LineFeed
                + 'FROM ' + @OutputSchemaName + '.' + @OutputTableNamePerfmonStats + ' p' + @LineFeed
                + 'INNER JOIN ' + @OutputSchemaName + '.' + @OutputTableNamePerfmonStats + ' pPrior ON p.ServerName = pPrior.ServerName AND p.object_name = pPrior.object_name AND p.counter_name = pPrior.counter_name AND p.instance_name = pPrior.instance_name AND p.CheckDate > pPrior.CheckDate' + @LineFeed
                + 'LEFT OUTER JOIN ' + @OutputSchemaName + '.' + @OutputTableNamePerfmonStats + ' pMiddle ON p.ServerName = pMiddle.ServerName AND p.object_name = pMiddle.object_name AND p.counter_name = pMiddle.counter_name AND p.instance_name = pMiddle.instance_name AND p.CheckDate > pMiddle.CheckDate AND pMiddle.CheckDate > pPrior.CheckDate' + @LineFeed
                + 'WHERE pMiddle.ID IS NULL;'')'
            EXEC(@StringToExecute);
            END;

        SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName + ''') INSERT '
            + @OutputDatabaseName + '.'
            + @OutputSchemaName + '.'
            + @OutputTableNamePerfmonStats
            + ' (ServerName, CheckDate, object_name, counter_name, instance_name, cntr_value, cntr_type, value_delta, value_per_second) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 127) + ''', '
            + 'object_name, counter_name, instance_name, cntr_value, cntr_type, value_delta, value_per_second FROM #PerfmonStats WHERE Pass = 2';
        EXEC(@StringToExecute);

    END
    ELSE IF (SUBSTRING(@OutputTableNamePerfmonStats, 2, 2) = '##')
    BEGIN
        SET @StringToExecute = N' IF (OBJECT_ID(''tempdb..'
            + @OutputTableNamePerfmonStats
            + ''') IS NULL) CREATE TABLE '
            + @OutputTableNamePerfmonStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                [object_name] NVARCHAR(128) NOT NULL,
                [counter_name] NVARCHAR(128) NOT NULL,
                [instance_name] NVARCHAR(128) NULL,
                [cntr_value] BIGINT NULL,
                [cntr_type] INT NOT NULL,
                [value_delta] BIGINT NULL,
                [value_per_second] DECIMAL(18,2) NULL,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
            + ' INSERT '
            + @OutputTableNamePerfmonStats
            + ' (ServerName, CheckDate, object_name, counter_name, instance_name, cntr_value, cntr_type, value_delta, value_per_second) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 127) + ''', '
            + 'object_name, counter_name, instance_name, cntr_value, cntr_type, value_delta, value_per_second FROM #PerfmonStats WHERE Pass = 2';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableNamePerfmonStats, 2, 1) = '#')
    BEGIN
        RAISERROR('Due to the nature of Dymamic SQL, only global (i.e. double pound (##)) temp tables are supported for @OutputTableName', 16, 0)
    END


    /* @OutputTableNameWaitStats lets us export the results to a permanent table */
    IF @OutputDatabaseName IS NOT NULL
        AND @OutputSchemaName IS NOT NULL
        AND @OutputTableNameWaitStats IS NOT NULL
        AND @OutputTableNameWaitStats NOT LIKE '#%'
        AND EXISTS ( SELECT *
                     FROM   sys.databases
                     WHERE  QUOTENAME([name]) = @OutputDatabaseName)
    BEGIN
        /* Create the table */
        SET @StringToExecute = 'USE '
            + @OutputDatabaseName
            + '; IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName
            + ''') AND NOT EXISTS (SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.TABLES WHERE QUOTENAME(TABLE_SCHEMA) = '''
            + @OutputSchemaName + ''' AND QUOTENAME(TABLE_NAME) = '''
            + @OutputTableNameWaitStats + ''') CREATE TABLE '
            + @OutputSchemaName + '.'
            + @OutputTableNameWaitStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                wait_type NVARCHAR(60),
                wait_time_ms BIGINT,
                signal_wait_time_ms BIGINT,
                waiting_tasks_count BIGINT ,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
        EXEC(@StringToExecute);

        /* Create the view */
        SET @ObjectFullName = @OutputDatabaseName + N'.' + @OutputSchemaName + N'.' +  @OutputTableNameWaitStats_View;
        IF OBJECT_ID(@ObjectFullName) IS NULL
            BEGIN
            SET @StringToExecute = 'USE '
                + @OutputDatabaseName
                + '; EXEC (''CREATE VIEW '
                + @OutputSchemaName + '.'
                + @OutputTableNameWaitStats_View + ' AS ' + @LineFeed
                + 'SELECT w.ServerName, w.CheckDate, w.wait_type' + @LineFeed
                + ', DATEDIFF(ss, wPrior.CheckDate, w.CheckDate) AS ElapsedSeconds' + @LineFeed
                + ', (w.wait_time_ms - wPrior.wait_time_ms) AS wait_time_ms_delta' + @LineFeed
                + ', (w.signal_wait_time_ms - wPrior.signal_wait_time_ms) AS signal_wait_time_ms_delta' + @LineFeed
                + ', (w.waiting_tasks_count - wPrior.waiting_tasks_count) AS waiting_tasks_count_delta' + @LineFeed
                + 'FROM ' + @OutputSchemaName + '.' + @OutputTableNameWaitStats + ' w' + @LineFeed
                + 'INNER JOIN ' + @OutputSchemaName + '.' + @OutputTableNameWaitStats + ' wPrior ON w.ServerName = wPrior.ServerName AND w.wait_type = wPrior.wait_type AND w.CheckDate > wPrior.CheckDate' + @LineFeed
                + 'LEFT OUTER JOIN ' + @OutputSchemaName + '.' + @OutputTableNameWaitStats + ' wMiddle ON w.ServerName = wMiddle.ServerName AND w.wait_type = wMiddle.wait_type AND w.CheckDate > wMiddle.CheckDate AND wMiddle.CheckDate > wPrior.CheckDate' + @LineFeed
                + 'WHERE wMiddle.ID IS NULL;'')'
            EXEC(@StringToExecute);
            END


        SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName + ''') INSERT '
            + @OutputDatabaseName + '.'
            + @OutputSchemaName + '.'
            + @OutputTableNameWaitStats
            + ' (ServerName, CheckDate, wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 127) + ''', '
            + 'wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count FROM #WaitStats WHERE Pass = 2 AND wait_time_ms > 0 AND waiting_tasks_count > 0';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableNameWaitStats, 2, 2) = '##')
    BEGIN
        SET @StringToExecute = N' IF (OBJECT_ID(''tempdb..'
            + @OutputTableNameWaitStats
            + ''') IS NULL) CREATE TABLE '
            + @OutputTableNameWaitStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                wait_type NVARCHAR(60),
                wait_time_ms BIGINT,
                signal_wait_time_ms BIGINT,
                waiting_tasks_count BIGINT ,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
            + ' INSERT '
            + @OutputTableNameWaitStats
            + ' (ServerName, CheckDate, wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 127) + ''', '
            + 'wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count FROM #WaitStats WHERE Pass = 2 AND wait_time_ms > 0 AND waiting_tasks_count > 0';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableNameWaitStats, 2, 1) = '#')
    BEGIN
        RAISERROR('Due to the nature of Dymamic SQL, only global (i.e. double pound (##)) temp tables are supported for @OutputTableName', 16, 0)
    END




    DECLARE @separator AS VARCHAR(1);
    IF @OutputType = 'RSV'
        SET @separator = CHAR(31);
    ELSE
        SET @separator = ',';

    IF @OutputType = 'COUNT' AND @SinceStartup = 0
    BEGIN
        SELECT  COUNT(*) AS Warnings
        FROM    #BlitzFirstResults
    END
    ELSE
        IF @OutputType = 'Opserver1' AND @SinceStartup = 0
        BEGIN

            SELECT  r.[Priority] ,
                    r.[FindingsGroup] ,
                    r.[Finding] ,
                    r.[URL] ,
                    r.[Details],
                    r.[HowToStopIt] ,
                    r.[CheckID] ,
                    r.[StartTime],
                    r.[LoginName],
                    r.[NTUserName],
                    r.[OriginalLoginName],
                    r.[ProgramName],
                    r.[HostName],
                    r.[DatabaseID],
                    r.[DatabaseName],
                    r.[OpenTransactionCount],
                    r.[QueryPlan],
                    r.[QueryText],
                    qsNow.plan_handle AS PlanHandle,
                    qsNow.sql_handle AS SqlHandle,
                    qsNow.statement_start_offset AS StatementStartOffset,
                    qsNow.statement_end_offset AS StatementEndOffset,
                    [Executions] = qsNow.execution_count - (COALESCE(qsFirst.execution_count, 0)),
                    [ExecutionsPercent] = CAST(100.0 * (qsNow.execution_count - (COALESCE(qsFirst.execution_count, 0))) / (qsTotal.execution_count - qsTotalFirst.execution_count) AS DECIMAL(6,2)),
                    [Duration] = qsNow.total_elapsed_time - (COALESCE(qsFirst.total_elapsed_time, 0)),
                    [DurationPercent] = CAST(100.0 * (qsNow.total_elapsed_time - (COALESCE(qsFirst.total_elapsed_time, 0))) / (qsTotal.total_elapsed_time - qsTotalFirst.total_elapsed_time) AS DECIMAL(6,2)),
                    [CPU] = qsNow.total_worker_time - (COALESCE(qsFirst.total_worker_time, 0)),
                    [CPUPercent] = CAST(100.0 * (qsNow.total_worker_time - (COALESCE(qsFirst.total_worker_time, 0))) / (qsTotal.total_worker_time - qsTotalFirst.total_worker_time) AS DECIMAL(6,2)),
                    [Reads] = qsNow.total_logical_reads - (COALESCE(qsFirst.total_logical_reads, 0)),
                    [ReadsPercent] = CAST(100.0 * (qsNow.total_logical_reads - (COALESCE(qsFirst.total_logical_reads, 0))) / (qsTotal.total_logical_reads - qsTotalFirst.total_logical_reads) AS DECIMAL(6,2)),
                    [PlanCreationTime] = CONVERT(NVARCHAR(100), qsNow.creation_time ,121),
                    [TotalExecutions] = qsNow.execution_count,
                    [TotalExecutionsPercent] = CAST(100.0 * qsNow.execution_count / qsTotal.execution_count AS DECIMAL(6,2)),
                    [TotalDuration] = qsNow.total_elapsed_time,
                    [TotalDurationPercent] = CAST(100.0 * qsNow.total_elapsed_time / qsTotal.total_elapsed_time AS DECIMAL(6,2)),
                    [TotalCPU] = qsNow.total_worker_time,
                    [TotalCPUPercent] = CAST(100.0 * qsNow.total_worker_time / qsTotal.total_worker_time AS DECIMAL(6,2)),
                    [TotalReads] = qsNow.total_logical_reads,
                    [TotalReadsPercent] = CAST(100.0 * qsNow.total_logical_reads / qsTotal.total_logical_reads AS DECIMAL(6,2)),
                    r.[DetailsInt]
            FROM    #BlitzFirstResults r
                LEFT OUTER JOIN #QueryStats qsTotal ON qsTotal.Pass = 0
                LEFT OUTER JOIN #QueryStats qsTotalFirst ON qsTotalFirst.Pass = -1
                LEFT OUTER JOIN #QueryStats qsNow ON r.QueryStatsNowID = qsNow.ID
                LEFT OUTER JOIN #QueryStats qsFirst ON r.QueryStatsFirstID = qsFirst.ID
            ORDER BY r.Priority ,
                    r.FindingsGroup ,
                    CASE
                        WHEN r.CheckID = 6 THEN DetailsInt
                        ELSE 0
                    END DESC,
                    r.Finding,
                    r.ID;
        END
        ELSE IF @OutputType IN ( 'CSV', 'RSV' ) AND @SinceStartup = 0
        BEGIN

            SELECT  Result = CAST([Priority] AS NVARCHAR(100))
                    + @separator + CAST(CheckID AS NVARCHAR(100))
                    + @separator + COALESCE([FindingsGroup],
                                            '(N/A)') + @separator
                    + COALESCE([Finding], '(N/A)') + @separator
                    + COALESCE(DatabaseName, '(N/A)') + @separator
                    + COALESCE([URL], '(N/A)') + @separator
                    + COALESCE([Details], '(N/A)')
            FROM    #BlitzFirstResults
            ORDER BY Priority ,
                    FindingsGroup ,
                    CASE
                        WHEN CheckID = 6 THEN DetailsInt
                        ELSE 0
                    END DESC,
                    Finding,
                    Details;
        END
        ELSE IF @ExpertMode = 0 AND @OutputXMLasNVARCHAR = 0 AND @SinceStartup = 0
        BEGIN
            SELECT  [Priority] ,
                    [FindingsGroup] ,
                    [Finding] ,
                    [URL] ,
                    CAST(@StockDetailsHeader + [Details] + @StockDetailsFooter AS XML) AS Details,
                    CAST(@StockWarningHeader + HowToStopIt + @StockWarningFooter AS XML) AS HowToStopIt,
                    [QueryText],
                    [QueryPlan]
            FROM    #BlitzFirstResults
            WHERE (@Seconds > 0 OR (Priority IN (0, 250, 251, 255))) /* For @Seconds = 0, filter out broken checks for now */
            ORDER BY Priority ,
                    FindingsGroup ,
                    CASE
                        WHEN CheckID = 6 THEN DetailsInt
                        ELSE 0
                    END DESC,
                    Finding,
                    ID;
        END
        ELSE IF @ExpertMode = 0 AND @OutputXMLasNVARCHAR = 1 AND @SinceStartup = 0
        BEGIN
            SELECT  [Priority] ,
                    [FindingsGroup] ,
                    [Finding] ,
                    [URL] ,
                    CAST(@StockDetailsHeader + [Details] + @StockDetailsFooter AS NVARCHAR(MAX)) AS Details,
                    CAST([HowToStopIt] AS NVARCHAR(MAX)) AS HowToStopIt,
                    CAST([QueryText] AS NVARCHAR(MAX)) AS QueryText,
                    CAST([QueryPlan] AS NVARCHAR(MAX)) AS QueryPlan
            FROM    #BlitzFirstResults
            WHERE (@Seconds > 0 OR (Priority IN (0, 250, 251, 255))) /* For @Seconds = 0, filter out broken checks for now */
            ORDER BY Priority ,
                    FindingsGroup ,
                    CASE
                        WHEN CheckID = 6 THEN DetailsInt
                        ELSE 0
                    END DESC,
                    Finding,
                    ID;
        END
        ELSE IF @ExpertMode = 1
        BEGIN
            IF @SinceStartup = 0
                SELECT  r.[Priority] ,
                        r.[FindingsGroup] ,
                        r.[Finding] ,
                        r.[URL] ,
                        CAST(@StockDetailsHeader + r.[Details] + @StockDetailsFooter AS XML) AS Details,
                        CAST(@StockWarningHeader + r.HowToStopIt + @StockWarningFooter AS XML) AS HowToStopIt,
                        r.[CheckID] ,
                        r.[StartTime],
                        r.[LoginName],
                        r.[NTUserName],
                        r.[OriginalLoginName],
                        r.[ProgramName],
                        r.[HostName],
                        r.[DatabaseID],
                        r.[DatabaseName],
                        r.[OpenTransactionCount],
                        r.[QueryPlan],
                        r.[QueryText],
                        qsNow.plan_handle AS PlanHandle,
                        qsNow.sql_handle AS SqlHandle,
                        qsNow.statement_start_offset AS StatementStartOffset,
                        qsNow.statement_end_offset AS StatementEndOffset,
                        [Executions] = qsNow.execution_count - (COALESCE(qsFirst.execution_count, 0)),
                        [ExecutionsPercent] = CAST(100.0 * (qsNow.execution_count - (COALESCE(qsFirst.execution_count, 0))) / (qsTotal.execution_count - qsTotalFirst.execution_count) AS DECIMAL(6,2)),
                        [Duration] = qsNow.total_elapsed_time - (COALESCE(qsFirst.total_elapsed_time, 0)),
                        [DurationPercent] = CAST(100.0 * (qsNow.total_elapsed_time - (COALESCE(qsFirst.total_elapsed_time, 0))) / (qsTotal.total_elapsed_time - qsTotalFirst.total_elapsed_time) AS DECIMAL(6,2)),
                        [CPU] = qsNow.total_worker_time - (COALESCE(qsFirst.total_worker_time, 0)),
                        [CPUPercent] = CAST(100.0 * (qsNow.total_worker_time - (COALESCE(qsFirst.total_worker_time, 0))) / (qsTotal.total_worker_time - qsTotalFirst.total_worker_time) AS DECIMAL(6,2)),
                        [Reads] = qsNow.total_logical_reads - (COALESCE(qsFirst.total_logical_reads, 0)),
                        [ReadsPercent] = CAST(100.0 * (qsNow.total_logical_reads - (COALESCE(qsFirst.total_logical_reads, 0))) / (qsTotal.total_logical_reads - qsTotalFirst.total_logical_reads) AS DECIMAL(6,2)),
                        [PlanCreationTime] = CONVERT(NVARCHAR(100), qsNow.creation_time ,121),
                        [TotalExecutions] = qsNow.execution_count,
                        [TotalExecutionsPercent] = CAST(100.0 * qsNow.execution_count / qsTotal.execution_count AS DECIMAL(6,2)),
                        [TotalDuration] = qsNow.total_elapsed_time,
                        [TotalDurationPercent] = CAST(100.0 * qsNow.total_elapsed_time / qsTotal.total_elapsed_time AS DECIMAL(6,2)),
                        [TotalCPU] = qsNow.total_worker_time,
                        [TotalCPUPercent] = CAST(100.0 * qsNow.total_worker_time / qsTotal.total_worker_time AS DECIMAL(6,2)),
                        [TotalReads] = qsNow.total_logical_reads,
                        [TotalReadsPercent] = CAST(100.0 * qsNow.total_logical_reads / qsTotal.total_logical_reads AS DECIMAL(6,2)),
                        r.[DetailsInt]
                FROM    #BlitzFirstResults r
                    LEFT OUTER JOIN #QueryStats qsTotal ON qsTotal.Pass = 0
                    LEFT OUTER JOIN #QueryStats qsTotalFirst ON qsTotalFirst.Pass = -1
                    LEFT OUTER JOIN #QueryStats qsNow ON r.QueryStatsNowID = qsNow.ID
                    LEFT OUTER JOIN #QueryStats qsFirst ON r.QueryStatsFirstID = qsFirst.ID
                WHERE (@Seconds > 0 OR (Priority IN (0, 250, 251, 255))) /* For @Seconds = 0, filter out broken checks for now */
                ORDER BY r.Priority ,
                        r.FindingsGroup ,
                        CASE
                            WHEN r.CheckID = 6 THEN DetailsInt
                            ELSE 0
                        END DESC,
                        r.Finding,
                        r.ID;

            -------------------------
            --What happened: #WaitStats
            -------------------------
            IF @Seconds = 0
                BEGIN
                /* Measure waits in hours */
                ;WITH max_batch AS (
                    SELECT MAX(SampleTime) AS SampleTime
                    FROM #WaitStats
                )
                SELECT
                    'WAIT STATS' AS Pattern,
                    b.SampleTime AS [Sample Ended],
                    CAST(DATEDIFF(mi,wd1.SampleTime, wd2.SampleTime) / 60.0 AS DECIMAL(18,1)) AS [Hours Sample],
                    wd1.wait_type,
                    CAST(c.[Wait Time (Seconds)] / 60.0 / 60 AS DECIMAL(18,1)) AS [Wait Time (Hours)],
                    CAST((wd2.wait_time_ms - wd1.wait_time_ms) / 1000.0 / 60 / 60 / cores.cpu_count / DATEDIFF(ss, wd1.SampleTime, wd2.SampleTime) AS DECIMAL(18,1)) AS [Per Core Per Hour],
                    CAST(c.[Signal Wait Time (Seconds)] / 60.0 / 60 AS DECIMAL(18,1)) AS [Signal Wait Time (Hours)],
                    CASE WHEN c.[Wait Time (Seconds)] > 0
                     THEN CAST(100.*(c.[Signal Wait Time (Seconds)]/c.[Wait Time (Seconds)]) AS NUMERIC(4,1))
                    ELSE 0 END AS [Percent Signal Waits],
                    (wd2.waiting_tasks_count - wd1.waiting_tasks_count) AS [Number of Waits],
                    CASE WHEN (wd2.waiting_tasks_count - wd1.waiting_tasks_count) > 0
                    THEN
                        CAST((wd2.wait_time_ms-wd1.wait_time_ms)/
                            (1.0*(wd2.waiting_tasks_count - wd1.waiting_tasks_count)) AS NUMERIC(12,1))
                    ELSE 0 END AS [Avg ms Per Wait],
                    N'http://www.brentozar.com/sql/wait-stats/#' + wd1.wait_type AS URL
                FROM  max_batch b
                JOIN #WaitStats wd2 ON
                    wd2.SampleTime =b.SampleTime
                JOIN #WaitStats wd1 ON
                    wd1.wait_type=wd2.wait_type AND
                    wd2.SampleTime > wd1.SampleTime
                CROSS APPLY (SELECT SUM(1) AS cpu_count FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE' AND is_online = 1) AS cores
                CROSS APPLY (SELECT
                    CAST((wd2.wait_time_ms-wd1.wait_time_ms)/1000. AS NUMERIC(12,1)) AS [Wait Time (Seconds)],
                    CAST((wd2.signal_wait_time_ms - wd1.signal_wait_time_ms)/1000. AS NUMERIC(12,1)) AS [Signal Wait Time (Seconds)]) AS c
                WHERE (wd2.waiting_tasks_count - wd1.waiting_tasks_count) > 0
                    AND wd2.wait_time_ms-wd1.wait_time_ms > 0
                ORDER BY [Wait Time (Seconds)] DESC;
                END
            ELSE
                BEGIN
                /* Measure waits in seconds */
                ;WITH max_batch AS (
                    SELECT MAX(SampleTime) AS SampleTime
                    FROM #WaitStats
                )
                SELECT
                    'WAIT STATS' AS Pattern,
                    b.SampleTime AS [Sample Ended],
                    DATEDIFF(ss,wd1.SampleTime, wd2.SampleTime) AS [Seconds Sample],
                    wd1.wait_type,
                    c.[Wait Time (Seconds)],
                    CAST((wd2.wait_time_ms - wd1.wait_time_ms) / 1000.0 / cores.cpu_count / DATEDIFF(ss, wd1.SampleTime, wd2.SampleTime) AS DECIMAL(18,1)) AS [Per Core Per Second],
                    c.[Signal Wait Time (Seconds)],
                    CASE WHEN c.[Wait Time (Seconds)] > 0
                     THEN CAST(100.*(c.[Signal Wait Time (Seconds)]/c.[Wait Time (Seconds)]) AS NUMERIC(4,1))
                    ELSE 0 END AS [Percent Signal Waits],
                    (wd2.waiting_tasks_count - wd1.waiting_tasks_count) AS [Number of Waits],
                    CASE WHEN (wd2.waiting_tasks_count - wd1.waiting_tasks_count) > 0
                    THEN
                        CAST((wd2.wait_time_ms-wd1.wait_time_ms)/
                            (1.0*(wd2.waiting_tasks_count - wd1.waiting_tasks_count)) AS NUMERIC(12,1))
                    ELSE 0 END AS [Avg ms Per Wait],
                    N'http://www.brentozar.com/sql/wait-stats/#' + wd1.wait_type AS URL
                FROM  max_batch b
                JOIN #WaitStats wd2 ON
                    wd2.SampleTime =b.SampleTime
                JOIN #WaitStats wd1 ON
                    wd1.wait_type=wd2.wait_type AND
                    wd2.SampleTime > wd1.SampleTime
                CROSS APPLY (SELECT SUM(1) AS cpu_count FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE' AND is_online = 1) AS cores
                CROSS APPLY (SELECT
                    CAST((wd2.wait_time_ms-wd1.wait_time_ms)/1000. AS NUMERIC(12,1)) AS [Wait Time (Seconds)],
                    CAST((wd2.signal_wait_time_ms - wd1.signal_wait_time_ms)/1000. AS NUMERIC(12,1)) AS [Signal Wait Time (Seconds)]) AS c
                WHERE (wd2.waiting_tasks_count - wd1.waiting_tasks_count) > 0
                    AND wd2.wait_time_ms-wd1.wait_time_ms > 0
                ORDER BY [Wait Time (Seconds)] DESC;
                END;

            -------------------------
            --What happened: #FileStats
            -------------------------
            WITH readstats AS (
                SELECT 'PHYSICAL READS' AS Pattern,
                ROW_NUMBER() OVER (ORDER BY wd2.avg_stall_read_ms DESC) AS StallRank,
                wd2.SampleTime AS [Sample Time],
                DATEDIFF(ss,wd1.SampleTime, wd2.SampleTime) AS [Sample (seconds)],
                wd1.DatabaseName ,
                wd1.FileLogicalName AS [File Name],
                UPPER(SUBSTRING(wd1.PhysicalName, 1, 2)) AS [Drive] ,
                wd1.SizeOnDiskMB ,
                ( wd2.num_of_reads - wd1.num_of_reads ) AS [# Reads/Writes],
                CASE WHEN wd2.num_of_reads - wd1.num_of_reads > 0
                  THEN CAST(( wd2.bytes_read - wd1.bytes_read)/1024./1024. AS NUMERIC(21,1))
                  ELSE 0
                END AS [MB Read/Written],
                wd2.avg_stall_read_ms AS [Avg Stall (ms)],
                wd1.PhysicalName AS [file physical name]
            FROM #FileStats wd2
                JOIN #FileStats wd1 ON wd2.SampleTime > wd1.SampleTime
                  AND wd1.DatabaseID = wd2.DatabaseID
                  AND wd1.FileID = wd2.FileID
            ),
            writestats AS (
                SELECT
                'PHYSICAL WRITES' AS Pattern,
                ROW_NUMBER() OVER (ORDER BY wd2.avg_stall_write_ms DESC) AS StallRank,
                wd2.SampleTime AS [Sample Time],
                DATEDIFF(ss,wd1.SampleTime, wd2.SampleTime) AS [Sample (seconds)],
                wd1.DatabaseName ,
                wd1.FileLogicalName AS [File Name],
                UPPER(SUBSTRING(wd1.PhysicalName, 1, 2)) AS [Drive] ,
                wd1.SizeOnDiskMB ,
                ( wd2.num_of_writes - wd1.num_of_writes ) AS [# Reads/Writes],
                CASE WHEN wd2.num_of_writes - wd1.num_of_writes > 0
                  THEN CAST(( wd2.bytes_written - wd1.bytes_written)/1024./1024. AS NUMERIC(21,1))
                  ELSE 0
                END AS [MB Read/Written],
                wd2.avg_stall_write_ms AS [Avg Stall (ms)],
                wd1.PhysicalName AS [file physical name]
            FROM #FileStats wd2
                JOIN #FileStats wd1 ON wd2.SampleTime > wd1.SampleTime
                  AND wd1.DatabaseID = wd2.DatabaseID
                  AND wd1.FileID = wd2.FileID
            )
            SELECT
                Pattern, [Sample Time], [Sample (seconds)], [File Name], [Drive],  [# Reads/Writes],[MB Read/Written],[Avg Stall (ms)], [file physical name]
            FROM readstats
            WHERE StallRank <=5 AND [MB Read/Written] > 0
            UNION ALL
            SELECT Pattern, [Sample Time], [Sample (seconds)], [File Name], [Drive],  [# Reads/Writes],[MB Read/Written],[Avg Stall (ms)], [file physical name]
            FROM writestats
            WHERE StallRank <=5 AND [MB Read/Written] > 0;


            -------------------------
            --What happened: #PerfmonStats
            -------------------------

            SELECT 'PERFMON' AS Pattern, pLast.[object_name], pLast.counter_name, pLast.instance_name,
                pFirst.SampleTime AS FirstSampleTime, pFirst.cntr_value AS FirstSampleValue,
                pLast.SampleTime AS LastSampleTime, pLast.cntr_value AS LastSampleValue,
                pLast.cntr_value - pFirst.cntr_value AS ValueDelta,
                ((1.0 * pLast.cntr_value - pFirst.cntr_value) / DATEDIFF(ss, pFirst.SampleTime, pLast.SampleTime)) AS ValuePerSecond
                FROM #PerfmonStats pLast
                    INNER JOIN #PerfmonStats pFirst ON pFirst.[object_name] = pLast.[object_name] AND pFirst.counter_name = pLast.counter_name AND (pFirst.instance_name = pLast.instance_name OR (pFirst.instance_name IS NULL AND pLast.instance_name IS NULL))
                    AND pLast.ID > pFirst.ID
				WHERE (pLast.cntr_value - pFirst.cntr_value) > 0
                ORDER BY Pattern, pLast.[object_name], pLast.counter_name, pLast.instance_name


            -------------------------
            --What happened: #FileStats
            -------------------------
            SELECT
                [qsNow].[ID] AS [Now-ID],
                [qsNow].[Pass] AS [Now-Pass],
                [qsNow].[SampleTime] AS [Now-SampleTime],
                [qsNow].[sql_handle] AS [Now-sql_handle],
                [qsNow].[statement_start_offset] AS [Now-statement_start_offset],
                [qsNow].[statement_end_offset] AS [Now-statement_end_offset],
                [qsNow].[plan_generation_num] AS [Now-plan_generation_num],
                [qsNow].[plan_handle] AS [Now-plan_handle],
                [qsNow].[execution_count] AS [Now-execution_count],
                [qsNow].[total_worker_time] AS [Now-total_worker_time],
                [qsNow].[total_physical_reads] AS [Now-total_physical_reads],
                [qsNow].[total_logical_writes] AS [Now-total_logical_writes],
                [qsNow].[total_logical_reads] AS [Now-total_logical_reads],
                [qsNow].[total_clr_time] AS [Now-total_clr_time],
                [qsNow].[total_elapsed_time] AS [Now-total_elapsed_time],
                [qsNow].[creation_time] AS [Now-creation_time],
                [qsNow].[query_hash] AS [Now-query_hash],
                [qsNow].[query_plan_hash] AS [Now-query_plan_hash],
                [qsNow].[Points] AS [Now-Points],
                [qsFirst].[ID] AS [First-ID],
                [qsFirst].[Pass] AS [First-Pass],
                [qsFirst].[SampleTime] AS [First-SampleTime],
                [qsFirst].[sql_handle] AS [First-sql_handle],
                [qsFirst].[statement_start_offset] AS [First-statement_start_offset],
                [qsFirst].[statement_end_offset] AS [First-statement_end_offset],
                [qsFirst].[plan_generation_num] AS [First-plan_generation_num],
                [qsFirst].[plan_handle] AS [First-plan_handle],
                [qsFirst].[execution_count] AS [First-execution_count],
                [qsFirst].[total_worker_time] AS [First-total_worker_time],
                [qsFirst].[total_physical_reads] AS [First-total_physical_reads],
                [qsFirst].[total_logical_writes] AS [First-total_logical_writes],
                [qsFirst].[total_logical_reads] AS [First-total_logical_reads],
                [qsFirst].[total_clr_time] AS [First-total_clr_time],
                [qsFirst].[total_elapsed_time] AS [First-total_elapsed_time],
                [qsFirst].[creation_time] AS [First-creation_time],
                [qsFirst].[query_hash] AS [First-query_hash],
                [qsFirst].[query_plan_hash] AS [First-query_plan_hash],
                [qsFirst].[Points] AS [First-Points]
            FROM #QueryStats qsNow
              INNER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
            WHERE qsNow.Pass = 2
        END

    DROP TABLE #BlitzFirstResults;

    /* What's running right now? This is the first and last result set. */
    IF @SinceStartup = 0 AND @Seconds > 0 AND @ExpertMode = 1 
    BEGIN
		IF OBJECT_ID('dbo.sp_BlitzWho') IS NOT NULL
		BEGIN
			EXEC [dbo].[sp_BlitzWho]
		END
    END /* IF @SinceStartup = 0 AND @Seconds > 0 AND @ExpertMode = 1   -   What's running right now? This is the first and last result set. */

END /* IF @Question IS NULL */
ELSE IF @Question IS NOT NULL

/* We're playing Magic SQL 8 Ball, so give them an answer. */
BEGIN
    IF OBJECT_ID('tempdb..#BlitzFirstAnswers') IS NOT NULL
        DROP TABLE #BlitzFirstAnswers;
    CREATE TABLE #BlitzFirstAnswers(Answer VARCHAR(200) NOT NULL);
    INSERT INTO #BlitzFirstAnswers VALUES ('It sounds like a SAN problem.');
    INSERT INTO #BlitzFirstAnswers VALUES ('You know what you need? Bacon.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Talk to the developers about that.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Let''s post that on StackOverflow.com and find out.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Have you tried adding an index?');
    INSERT INTO #BlitzFirstAnswers VALUES ('Have you tried dropping an index?');
    INSERT INTO #BlitzFirstAnswers VALUES ('You can''t prove anything.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Please phrase the question in the form of an answer.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Outlook not so good. Access even worse.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Did you try asking the rubber duck? http://www.codinghorror.com/blog/2012/03/rubber-duck-problem-solving.html');
    INSERT INTO #BlitzFirstAnswers VALUES ('Oooo, I read about that once.');
    INSERT INTO #BlitzFirstAnswers VALUES ('I feel your pain.');
    INSERT INTO #BlitzFirstAnswers VALUES ('http://LMGTFY.com');
    INSERT INTO #BlitzFirstAnswers VALUES ('No comprende Ingles, senor.');
    INSERT INTO #BlitzFirstAnswers VALUES ('I don''t have that problem on my Mac.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Is Priority Boost on?');
    INSERT INTO #BlitzFirstAnswers VALUES ('Have you tried rebooting your machine?');
    INSERT INTO #BlitzFirstAnswers VALUES ('Try defragging your cursors.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Why are you wearing that? Do you have a job interview later or something?');
    INSERT INTO #BlitzFirstAnswers VALUES ('I''m ashamed that you don''t know the answer to that question.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Duh, Debra.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Have you tried restoring TempDB?');
    SELECT TOP 1 Answer FROM #BlitzFirstAnswers ORDER BY NEWID();
END

END /* ELSE IF @OutputType = 'SCHEMA' */

SET NOCOUNT OFF;
GO



/* How to run it:
EXEC dbo.sp_BlitzFirst

With extra diagnostic info:
EXEC dbo.sp_BlitzFirst @ExpertMode = 1;

In Ask a Question mode:
EXEC dbo.sp_BlitzFirst 'Is this cursor bad?';

Saving output to tables:
EXEC sp_BlitzFirst @Seconds = 60
, @OutputDatabaseName = 'DBAtools'
, @OutputSchemaName = 'dbo'
, @OutputTableName = 'BlitzFirstResults'
, @OutputTableNameFileStats = 'BlitzFirstResults_FileStats'
, @OutputTableNamePerfmonStats = 'BlitzFirstResults_PerfmonStats'
, @OutputTableNameWaitStats = 'BlitzFirstResults_WaitStats'
*/

USE tempdb
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

IF OBJECT_ID('dbo.sp_BlitzIndex') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_BlitzIndex AS RETURN 0;')
GO

ALTER PROCEDURE dbo.sp_BlitzIndex
    @DatabaseName NVARCHAR(128) = NULL, /*Defaults to current DB if not specified*/
    @SchemaName NVARCHAR(128) = NULL, /*Requires table_name as well.*/
    @TableName NVARCHAR(128) = NULL,  /*Requires schema_name as well.*/
    @Mode TINYINT=0, /*0=Diagnose, 1=Summarize, 2=Index Usage Detail, 3=Missing Index Detail, 4=Diagnose Details*/
        /*Note:@Mode doesn't matter if you're specifying schema_name and @TableName.*/
    @Filter TINYINT = 0, /* 0=no filter (default). 1=No low-usage warnings for objects with 0 reads. 2=Only warn for objects >= 500MB */
        /*Note:@Filter doesn't do anything unless @Mode=0*/
	@SkipPartitions BIT	= 0,
	@SkipStatistics BIT	= 1,
    @GetAllDatabases BIT = 0,
    @BringThePain BIT = 0,
    @ThresholdMB INT = 250 /* Number of megabytes that an object must be before we include it in basic results */,
    @OutputServerName NVARCHAR(256) = NULL ,
    @OutputDatabaseName NVARCHAR(256) = NULL ,
    @OutputSchemaName NVARCHAR(256) = NULL ,
    @OutputTableName NVARCHAR(256) = NULL ,
	@Help TINYINT = 0,
	@VersionDate DATETIME = NULL OUTPUT
WITH RECOMPILE
AS
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
DECLARE @Version VARCHAR(30);
SET @Version = '4.6';
SET @VersionDate = '20161210';
IF @Help = 1 PRINT '
/*
sp_BlitzIndex from http://FirstResponderKit.org
	
This script analyzes the design and performance of your indexes.

To learn more, visit http://FirstResponderKit.org where you can download new
versions for free, watch training videos on how it works, get more info on
the findings, contribute your own code, and more.

Known limitations of this version:
 - Only Microsoft-supported versions of SQL Server. Sorry, 2005 and 2000.
 - The @OutputDatabaseName parameters are not functional yet. To check the
   status of this enhancement request, visit:
   https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/issues/221
 - Does not analyze columnstore, spatial, XML, or full text indexes. If you
   would like to contribute code to analyze those, head over to Github and
   check out the issues list: http://FirstResponderKit.org
 - Index create statements are just to give you a rough idea of the syntax. It includes filters and fillfactor.
 --        Example 1: index creates use ONLINE=? instead of ONLINE=ON / ONLINE=OFF. This is because it is important 
           for the user to understand if it is going to be offline and not just run a script.
 --        Example 2: they do not include all the options the index may have been created with (padding, compression
           filegroup/partition scheme etc.)
 --        (The compression and filegroup index create syntax is not trivial because it is set at the partition 
           level and is not trivial to code.)
 - Does not advise you about data modeling for clustered indexes and primary keys (primarily looks for signs of insanity.)

Unknown limitations of this version:
 - We knew them once, but we forgot.

Changes - for the full list of improvements and fixes in this version, see:
https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/milestone/4?closed=1


MIT License

Copyright (c) 2016 Brent Ozar Unlimited

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'


DECLARE @ScriptVersionName NVARCHAR(50);
DECLARE @DaysUptime NUMERIC(23,2);
DECLARE @DatabaseID INT;
DECLARE @ObjectID INT;
DECLARE @dsql NVARCHAR(MAX);
DECLARE @params NVARCHAR(MAX);
DECLARE @msg NVARCHAR(4000);
DECLARE @ErrorSeverity INT;
DECLARE @ErrorState INT;
DECLARE @Rowcount BIGINT;
DECLARE @SQLServerProductVersion NVARCHAR(128);
DECLARE @SQLServerEdition INT;
DECLARE @FilterMB INT;
DECLARE @collation NVARCHAR(256);
DECLARE @NumDatabases INT;
DECLARE @LineFeed NVARCHAR(5);

SET @LineFeed = CHAR(13) + CHAR(10);
SELECT @SQLServerProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128));
SELECT @SQLServerEdition =CAST(SERVERPROPERTY('EngineEdition') AS INT); /* We default to online index creates where EngineEdition=3*/
SET @FilterMB=250;
SELECT @ScriptVersionName = 'sp_BlitzIndex(TM) v' + @Version + ' - ' + DATENAME(MM, @VersionDate) + ' ' + RIGHT('0'+DATENAME(DD, @VersionDate),2) + ', ' + DATENAME(YY, @VersionDate)

RAISERROR(N'Starting run. %s', 0,1, @ScriptVersionName) WITH NOWAIT;

IF OBJECT_ID('tempdb..#IndexSanity') IS NOT NULL 
    DROP TABLE #IndexSanity;

IF OBJECT_ID('tempdb..#IndexPartitionSanity') IS NOT NULL 
    DROP TABLE #IndexPartitionSanity;

IF OBJECT_ID('tempdb..#IndexSanitySize') IS NOT NULL 
    DROP TABLE #IndexSanitySize;

IF OBJECT_ID('tempdb..#IndexColumns') IS NOT NULL 
    DROP TABLE #IndexColumns;

IF OBJECT_ID('tempdb..#MissingIndexes') IS NOT NULL 
    DROP TABLE #MissingIndexes;

IF OBJECT_ID('tempdb..#ForeignKeys') IS NOT NULL 
    DROP TABLE #ForeignKeys;

IF OBJECT_ID('tempdb..#BlitzIndexResults') IS NOT NULL 
    DROP TABLE #BlitzIndexResults;
        
IF OBJECT_ID('tempdb..#IndexCreateTsql') IS NOT NULL    
    DROP TABLE #IndexCreateTsql;

IF OBJECT_ID('tempdb..#DatabaseList') IS NOT NULL 
    DROP TABLE #DatabaseList;

IF OBJECT_ID('tempdb..#Statistics') IS NOT NULL 
    DROP TABLE #Statistics;

IF OBJECT_ID('tempdb..#PartitionCompressionInfo') IS NOT NULL 
    DROP TABLE #PartitionCompressionInfo;

IF OBJECT_ID('tempdb..#ComputedColumns') IS NOT NULL 
    DROP TABLE #ComputedColumns;
	
IF OBJECT_ID('tempdb..#TraceStatus') IS NOT NULL
	DROP TABLE #TraceStatus;

        RAISERROR (N'Create temp tables.',0,1) WITH NOWAIT;
        CREATE TABLE #BlitzIndexResults
            (
              blitz_result_id INT IDENTITY PRIMARY KEY,
              check_id INT NOT NULL,
              index_sanity_id INT NULL,
              Priority INT NULL,
              findings_group VARCHAR(4000) NOT NULL,
              finding VARCHAR(200) NOT NULL,
              [database_name] VARCHAR(200) NULL,
              URL VARCHAR(200) NOT NULL,
              details NVARCHAR(4000) NOT NULL,
              index_definition NVARCHAR(MAX) NOT NULL,
              secret_columns NVARCHAR(MAX) NULL,
              index_usage_summary NVARCHAR(MAX) NULL,
              index_size_summary NVARCHAR(MAX) NULL,
              create_tsql NVARCHAR(MAX) NULL,
              more_info NVARCHAR(MAX)NULL
            );

        CREATE TABLE #IndexSanity
            (
              [index_sanity_id] INT IDENTITY PRIMARY KEY,
              [database_id] SMALLINT NOT NULL ,
              [object_id] INT NOT NULL ,
              [index_id] INT NOT NULL ,
              [index_type] TINYINT NOT NULL,
              [database_name] NVARCHAR(128) NOT NULL ,
              [schema_name] NVARCHAR(128) NOT NULL ,
              [object_name] NVARCHAR(128) NOT NULL ,
              index_name NVARCHAR(128) NULL ,
              key_column_names NVARCHAR(MAX) NULL ,
              key_column_names_with_sort_order NVARCHAR(MAX) NULL ,
              key_column_names_with_sort_order_no_types NVARCHAR(MAX) NULL ,
              count_key_columns INT NULL ,
              include_column_names NVARCHAR(MAX) NULL ,
              include_column_names_no_types NVARCHAR(MAX) NULL ,
              count_included_columns INT NULL ,
              partition_key_column_name NVARCHAR(MAX) NULL,
              filter_definition NVARCHAR(MAX) NOT NULL ,
              is_indexed_view BIT NOT NULL ,
              is_unique BIT NOT NULL ,
              is_primary_key BIT NOT NULL ,
              is_XML BIT NOT NULL,
              is_spatial BIT NOT NULL,
              is_NC_columnstore BIT NOT NULL,
              is_CX_columnstore BIT NOT NULL,
              is_disabled BIT NOT NULL ,
              is_hypothetical BIT NOT NULL ,
              is_padded BIT NOT NULL ,
              fill_factor SMALLINT NOT NULL ,
              user_seeks BIGINT NOT NULL ,
              user_scans BIGINT NOT NULL ,
              user_lookups BIGINT NOT  NULL ,
              user_updates BIGINT NULL ,
              last_user_seek DATETIME NULL ,
              last_user_scan DATETIME NULL ,
              last_user_lookup DATETIME NULL ,
              last_user_update DATETIME NULL ,
              is_referenced_by_foreign_key BIT DEFAULT(0),
              secret_columns NVARCHAR(MAX) NULL,
              count_secret_columns INT NULL,
              create_date DATETIME NOT NULL,
              modify_date DATETIME NOT NULL,
            [db_schema_object_name] AS [schema_name] + '.' + [object_name]  ,
            [db_schema_object_indexid] AS [schema_name] + '.' + [object_name]
                + CASE WHEN [index_name] IS NOT NULL THEN '.' + index_name
                ELSE ''
                END + ' (' + CAST(index_id AS NVARCHAR(20)) + ')' ,
            first_key_column_name AS CASE    WHEN count_key_columns > 1
                THEN LEFT(key_column_names, CHARINDEX(',', key_column_names, 0) - 1)
                ELSE key_column_names
                END ,
            index_definition AS 
            CASE WHEN partition_key_column_name IS NOT NULL 
                THEN N'[PARTITIONED BY:' + partition_key_column_name +  N']' 
                ELSE '' 
                END +
                CASE index_id
                    WHEN 0 THEN N'[HEAP] '
                    WHEN 1 THEN N'[CX] '
                    ELSE N'' END + CASE WHEN is_indexed_view = 1 THEN '[VIEW] '
                    ELSE N'' END + CASE WHEN is_primary_key = 1 THEN N'[PK] '
                    ELSE N'' END + CASE WHEN is_XML = 1 THEN N'[XML] '
                    ELSE N'' END + CASE WHEN is_spatial = 1 THEN N'[SPATIAL] '
                    ELSE N'' END + CASE WHEN is_NC_columnstore = 1 THEN N'[COLUMNSTORE] '
                    ELSE N'' END + CASE WHEN is_disabled = 1 THEN N'[DISABLED] '
                    ELSE N'' END + CASE WHEN is_hypothetical = 1 THEN N'[HYPOTHETICAL] '
                    ELSE N'' END + CASE WHEN is_unique = 1 AND is_primary_key = 0 THEN N'[UNIQUE] '
                    ELSE N'' END + CASE WHEN count_key_columns > 0 THEN 
                        N'[' + CAST(count_key_columns AS VARCHAR(10)) + N' KEY' 
                            + CASE WHEN count_key_columns > 1 THEN  N'S' ELSE N'' END
                            + N'] ' + LTRIM(key_column_names_with_sort_order)
                    ELSE N'' END + CASE WHEN count_included_columns > 0 THEN 
                        N' [' + CAST(count_included_columns AS VARCHAR(10))  + N' INCLUDE' + 
                            + CASE WHEN count_included_columns > 1 THEN  N'S' ELSE N'' END                    
                            + N'] ' + include_column_names
                    ELSE N'' END + CASE WHEN filter_definition <> N'' THEN N' [FILTER] ' + filter_definition
                    ELSE N'' END ,
            [total_reads] AS user_seeks + user_scans + user_lookups,
            [reads_per_write] AS CAST(CASE WHEN user_updates > 0
                THEN ( user_seeks + user_scans + user_lookups )  / (1.0 * user_updates)
                ELSE 0 END AS MONEY) ,
            [index_usage_summary] AS N'Reads: ' + 
                REPLACE(CONVERT(NVARCHAR(30),CAST((user_seeks + user_scans + user_lookups) AS MONEY), 1), '.00', '')
                + CASE WHEN user_seeks + user_scans + user_lookups > 0 THEN
                    N' (' 
                        + RTRIM(
                        CASE WHEN user_seeks > 0 THEN REPLACE(CONVERT(NVARCHAR(30),CAST((user_seeks) AS MONEY), 1), '.00', '') + N' seek ' ELSE N'' END
                        + CASE WHEN user_scans > 0 THEN REPLACE(CONVERT(NVARCHAR(30),CAST((user_scans) AS MONEY), 1), '.00', '') + N' scan '  ELSE N'' END
                        + CASE WHEN user_lookups > 0 THEN  REPLACE(CONVERT(NVARCHAR(30),CAST((user_lookups) AS MONEY), 1), '.00', '') + N' lookup' ELSE N'' END
                        )
                        + N') '
                    ELSE N' ' END 
                + N'Writes:' + 
                REPLACE(CONVERT(NVARCHAR(30),CAST(user_updates AS MONEY), 1), '.00', ''),
            [more_info] AS N'EXEC dbo.sp_BlitzIndex @DatabaseName=' + QUOTENAME([database_name],'''') + 
                N', @SchemaName=' + QUOTENAME([schema_name],'''') + N', @TableName=' + QUOTENAME([object_name],'''') + N';'
		);


        CREATE TABLE #IndexPartitionSanity
            (
              [index_partition_sanity_id] INT IDENTITY PRIMARY KEY ,
              [index_sanity_id] INT NULL ,
              [database_id] INT NOT NULL ,
              [object_id] INT NOT NULL ,
              [index_id] INT NOT NULL ,
              [partition_number] INT NOT NULL ,
              row_count BIGINT NOT NULL ,
              reserved_MB NUMERIC(29,2) NOT NULL ,
              reserved_LOB_MB NUMERIC(29,2) NOT NULL ,
              reserved_row_overflow_MB NUMERIC(29,2) NOT NULL ,
              leaf_insert_count BIGINT NULL ,
              leaf_delete_count BIGINT NULL ,
              leaf_update_count BIGINT NULL ,
              range_scan_count BIGINT NULL ,
              singleton_lookup_count BIGINT NULL , 
              forwarded_fetch_count BIGINT NULL ,
              lob_fetch_in_pages BIGINT NULL ,
              lob_fetch_in_bytes BIGINT NULL ,
              row_overflow_fetch_in_pages BIGINT NULL ,
              row_overflow_fetch_in_bytes BIGINT NULL ,
              row_lock_count BIGINT NULL ,
              row_lock_wait_count BIGINT NULL ,
              row_lock_wait_in_ms BIGINT NULL ,
              page_lock_count BIGINT NULL ,
              page_lock_wait_count BIGINT NULL ,
              page_lock_wait_in_ms BIGINT NULL ,
              index_lock_promotion_attempt_count BIGINT NULL ,
              index_lock_promotion_count BIGINT NULL,
              data_compression_desc VARCHAR(60) NULL
            );

        CREATE TABLE #IndexSanitySize
            (
              [index_sanity_size_id] INT IDENTITY NOT NULL ,
              [index_sanity_id] INT NULL ,
              [database_id] INT NOT NULL,
              partition_count INT NOT NULL ,
              total_rows BIGINT NOT NULL ,
              total_reserved_MB NUMERIC(29,2) NOT NULL ,
              total_reserved_LOB_MB NUMERIC(29,2) NOT NULL ,
              total_reserved_row_overflow_MB NUMERIC(29,2) NOT NULL ,
              total_leaf_delete_count BIGINT NULL,
              total_leaf_update_count BIGINT NULL,
              total_range_scan_count BIGINT NULL,
              total_singleton_lookup_count BIGINT NULL,
              total_forwarded_fetch_count BIGINT NULL,
              total_row_lock_count BIGINT NULL ,
              total_row_lock_wait_count BIGINT NULL ,
              total_row_lock_wait_in_ms BIGINT NULL ,
              avg_row_lock_wait_in_ms BIGINT NULL ,
              total_page_lock_count BIGINT NULL ,
              total_page_lock_wait_count BIGINT NULL ,
              total_page_lock_wait_in_ms BIGINT NULL ,
              avg_page_lock_wait_in_ms BIGINT NULL ,
               total_index_lock_promotion_attempt_count BIGINT NULL ,
              total_index_lock_promotion_count BIGINT NULL ,
              data_compression_desc VARCHAR(8000) NULL,
              index_size_summary AS ISNULL(
                CASE WHEN partition_count > 1
                        THEN N'[' + CAST(partition_count AS NVARCHAR(10)) + N' PARTITIONS] '
                        ELSE N''
                END + REPLACE(CONVERT(NVARCHAR(30),CAST([total_rows] AS MONEY), 1), N'.00', N'') + N' rows; '
                + CASE WHEN total_reserved_MB > 1024 THEN 
                    CAST(CAST(total_reserved_MB/1024. AS NUMERIC(29,1)) AS NVARCHAR(30)) + N'GB'
                ELSE 
                    CAST(CAST(total_reserved_MB AS NUMERIC(29,1)) AS NVARCHAR(30)) + N'MB'
                END
                + CASE WHEN total_reserved_LOB_MB > 1024 THEN 
                    N'; ' + CAST(CAST(total_reserved_LOB_MB/1024. AS NUMERIC(29,1)) AS NVARCHAR(30)) + N'GB LOB'
                WHEN total_reserved_LOB_MB > 0 THEN
                    N'; ' + CAST(CAST(total_reserved_LOB_MB AS NUMERIC(29,1)) AS NVARCHAR(30)) + N'MB LOB'
                ELSE ''
                END
                 + CASE WHEN total_reserved_row_overflow_MB > 1024 THEN
                    N'; ' + CAST(CAST(total_reserved_row_overflow_MB/1024. AS NUMERIC(29,1)) AS NVARCHAR(30)) + N'GB Row Overflow'
                WHEN total_reserved_row_overflow_MB > 0 THEN
                    N'; ' + CAST(CAST(total_reserved_row_overflow_MB AS NUMERIC(29,1)) AS NVARCHAR(30)) + N'MB Row Overflow'
                ELSE ''
                END ,
                    N'Error- NULL in computed column'),
            index_op_stats AS ISNULL(
                (
                    REPLACE(CONVERT(NVARCHAR(30),CAST(total_singleton_lookup_count AS MONEY), 1),N'.00',N'') + N' singleton lookups; '
                    + REPLACE(CONVERT(NVARCHAR(30),CAST(total_range_scan_count AS MONEY), 1),N'.00',N'') + N' scans/seeks; '
                    + REPLACE(CONVERT(NVARCHAR(30),CAST(total_leaf_delete_count AS MONEY), 1),N'.00',N'') + N' deletes; '
                    + REPLACE(CONVERT(NVARCHAR(30),CAST(total_leaf_update_count AS MONEY), 1),N'.00',N'') + N' updates; '
                    + CASE WHEN ISNULL(total_forwarded_fetch_count,0) >0 THEN
                        REPLACE(CONVERT(NVARCHAR(30),CAST(total_forwarded_fetch_count AS MONEY), 1),N'.00',N'') + N' forward records fetched; '
                    ELSE N'' END

                    /* rows will only be in this dmv when data is in memory for the table */
                ), N'Table metadata not in memory'),
            index_lock_wait_summary AS ISNULL(
                CASE WHEN total_row_lock_wait_count = 0 AND  total_page_lock_wait_count = 0 AND
                    total_index_lock_promotion_attempt_count = 0 THEN N'0 lock waits.'
                ELSE
                    CASE WHEN total_row_lock_wait_count > 0 THEN
                        N'Row lock waits: ' + REPLACE(CONVERT(NVARCHAR(30),CAST(total_row_lock_wait_count AS MONEY), 1), N'.00', N'')
                        + N'; total duration: ' + 
                            CASE WHEN total_row_lock_wait_in_ms >= 60000 THEN /*More than 1 min*/
                                REPLACE(CONVERT(NVARCHAR(30),CAST((total_row_lock_wait_in_ms/60000) AS MONEY), 1), N'.00', N'') + N' minutes; '
                            ELSE                         
                                REPLACE(CONVERT(NVARCHAR(30),CAST(ISNULL(total_row_lock_wait_in_ms/1000,0) AS MONEY), 1), N'.00', N'') + N' seconds; '
                            END
                        + N'avg duration: ' + 
                            CASE WHEN avg_row_lock_wait_in_ms >= 60000 THEN /*More than 1 min*/
                                REPLACE(CONVERT(NVARCHAR(30),CAST((avg_row_lock_wait_in_ms/60000) AS MONEY), 1), N'.00', N'') + N' minutes; '
                            ELSE                         
                                REPLACE(CONVERT(NVARCHAR(30),CAST(ISNULL(avg_row_lock_wait_in_ms/1000,0) AS MONEY), 1), N'.00', N'') + N' seconds; '
                            END
                    ELSE N''
                    END +
                    CASE WHEN total_page_lock_wait_count > 0 THEN
                        N'Page lock waits: ' + REPLACE(CONVERT(NVARCHAR(30),CAST(total_page_lock_wait_count AS MONEY), 1), N'.00', N'')
                        + N'; total duration: ' + 
                            CASE WHEN total_page_lock_wait_in_ms >= 60000 THEN /*More than 1 min*/
                                REPLACE(CONVERT(NVARCHAR(30),CAST((total_page_lock_wait_in_ms/60000) AS MONEY), 1), N'.00', N'') + N' minutes; '
                            ELSE                         
                                REPLACE(CONVERT(NVARCHAR(30),CAST(ISNULL(total_page_lock_wait_in_ms/1000,0) AS MONEY), 1), N'.00', N'') + N' seconds; '
                            END
                        + N'avg duration: ' + 
                            CASE WHEN avg_page_lock_wait_in_ms >= 60000 THEN /*More than 1 min*/
                                REPLACE(CONVERT(NVARCHAR(30),CAST((avg_page_lock_wait_in_ms/60000) AS MONEY), 1), N'.00', N'') + N' minutes; '
                            ELSE                         
                                REPLACE(CONVERT(NVARCHAR(30),CAST(ISNULL(avg_page_lock_wait_in_ms/1000,0) AS MONEY), 1), N'.00', N'') + N' seconds; '
                            END
                    ELSE N''
                    END +
                    CASE WHEN total_index_lock_promotion_attempt_count > 0 THEN
                        N'Lock escalation attempts: ' + REPLACE(CONVERT(NVARCHAR(30),CAST(total_index_lock_promotion_attempt_count AS MONEY), 1), N'.00', N'')
                        + N'; Actual Escalations: ' + REPLACE(CONVERT(NVARCHAR(30),CAST(ISNULL(total_index_lock_promotion_count,0) AS MONEY), 1), N'.00', N'') + N'.'
                    ELSE N''
                    END
                END                  
                    ,'Error- NULL in computed column')
            );

        CREATE TABLE #IndexColumns
            (
              [database_id] INT NOT NULL,
              [object_id] INT NOT NULL ,
              [index_id] INT NOT NULL ,
              [key_ordinal] INT NULL ,
              is_included_column BIT NULL ,
              is_descending_key BIT NULL ,
              [partition_ordinal] INT NULL ,
              column_name NVARCHAR(256) NOT NULL ,
              system_type_name NVARCHAR(256) NOT NULL,
              max_length SMALLINT NOT NULL,
              [precision] TINYINT NOT NULL,
              [scale] TINYINT NOT NULL,
              collation_name NVARCHAR(256) NULL,
              is_nullable BIT NULL,
              is_identity BIT NULL,
              is_computed BIT NULL,
              is_replicated BIT NULL,
              is_sparse BIT NULL,
              is_filestream BIT NULL,
              seed_value BIGINT NULL,
              increment_value INT NULL ,
              last_value BIGINT NULL,
              is_not_for_replication BIT NULL
            );

        CREATE TABLE #MissingIndexes
            ([object_id] INT NOT NULL,
            [database_name] NVARCHAR(128) NOT NULL ,
            [schema_name] NVARCHAR(128) NOT NULL ,
            [table_name] NVARCHAR(128),
            [statement] NVARCHAR(512) NOT NULL,
            magic_benefit_number AS (( user_seeks + user_scans ) * avg_total_user_cost * avg_user_impact),
            avg_total_user_cost NUMERIC(29,4) NOT NULL,
            avg_user_impact NUMERIC(29,1) NOT NULL,
            user_seeks BIGINT NOT NULL,
            user_scans BIGINT NOT NULL,
            unique_compiles BIGINT NULL,
            equality_columns NVARCHAR(4000), 
            inequality_columns NVARCHAR(4000),
            included_columns NVARCHAR(4000),
                [index_estimated_impact] AS 
                    REPLACE(CONVERT(NVARCHAR(256),CAST(CAST(
                                    (user_seeks + user_scans)
                                     AS BIGINT) AS MONEY), 1), '.00', '') + N' use' 
                        + CASE WHEN (user_seeks + user_scans) > 1 THEN N's' ELSE N'' END
                         +N'; Impact: ' + CAST(avg_user_impact AS NVARCHAR(30))
                        + N'%; Avg query cost: '
                        + CAST(avg_total_user_cost AS NVARCHAR(30)),
                [missing_index_details] AS
                    CASE WHEN equality_columns IS NOT NULL THEN N'EQUALITY: ' + equality_columns + N' '
                         ELSE N''
                    END + CASE WHEN inequality_columns IS NOT NULL THEN N'INEQUALITY: ' + inequality_columns + N' '
                       ELSE N''
                    END + CASE WHEN included_columns IS NOT NULL THEN N'INCLUDES: ' + included_columns + N' '
                        ELSE N''
                    END,
                [create_tsql] AS N'CREATE INDEX [ix_' + table_name + N'_' 
                    + REPLACE(REPLACE(REPLACE(REPLACE(
                        ISNULL(equality_columns,N'')+ 
                        CASE WHEN equality_columns IS NOT NULL AND inequality_columns IS NOT NULL THEN N'_' ELSE N'' END
                        + ISNULL(inequality_columns,''),',','')
                        ,'[',''),']',''),' ','_') 
                    + CASE WHEN included_columns IS NOT NULL THEN N'_includes' ELSE N'' END + N'] ON ' 
                    + [statement] + N' (' + ISNULL(equality_columns,N'')
                    + CASE WHEN equality_columns IS NOT NULL AND inequality_columns IS NOT NULL THEN N', ' ELSE N'' END
                    + CASE WHEN inequality_columns IS NOT NULL THEN inequality_columns ELSE N'' END + 
                    ') ' + CASE WHEN included_columns IS NOT NULL THEN N' INCLUDE (' + included_columns + N')' ELSE N'' END
                    + N' WITH (' 
                        + N'FILLFACTOR=100, ONLINE=?, SORT_IN_TEMPDB=?' 
                    + N')'
                    + N';'
                    ,
                [more_info] AS N'EXEC dbo.sp_BlitzIndex @DatabaseName=' + QUOTENAME([database_name],'''') + 
                    N', @SchemaName=' + QUOTENAME([schema_name],'''') + N', @TableName=' + QUOTENAME([table_name],'''') + N';'
            );

        CREATE TABLE #ForeignKeys (
            [database_name] NVARCHAR(128) NOT NULL ,
            foreign_key_name NVARCHAR(256),
            parent_object_id INT,
            parent_object_name NVARCHAR(256),
            referenced_object_id INT,
            referenced_object_name NVARCHAR(256),
            is_disabled BIT,
            is_not_trusted BIT,
            is_not_for_replication BIT,
            parent_fk_columns NVARCHAR(MAX),
            referenced_fk_columns NVARCHAR(MAX),
            update_referential_action_desc NVARCHAR(16),
            delete_referential_action_desc NVARCHAR(60)
        )
        
        CREATE TABLE #IndexCreateTsql (
            index_sanity_id INT NOT NULL,
            create_tsql NVARCHAR(MAX) NOT NULL
        )

        CREATE TABLE #DatabaseList (
			DatabaseName NVARCHAR(256)
        )

		CREATE TABLE #PartitionCompressionInfo (
			[index_sanity_id] INT NULL,
			[partition_compression_detail] VARCHAR(8000) NULL
        )

		CREATE TABLE #Statistics (
		  database_name NVARCHAR(256) NOT NULL,
		  table_name NVARCHAR(128) NULL,
		  schema_name NVARCHAR(128) NULL,
		  index_name  NVARCHAR(128) NULL,
		  column_name  NVARCHAR(128) NULL,
		  statistics_name NVARCHAR(128) NULL,
		  last_statistics_update DATETIME NULL,
		  days_since_last_stats_update INT NULL,
		  rows BIGINT NULL,
		  rows_sampled BIGINT NULL,
		  percent_sampled DECIMAL(18, 1) NULL,
		  histogram_steps INT NULL,
		  modification_counter BIGINT NULL,
		  percent_modifications DECIMAL(18, 1) NULL,
		  modifications_before_auto_update INT NULL,
		  index_type_desc NVARCHAR(128) NULL,
		  table_create_date DATETIME NULL,
		  table_modify_date DATETIME NULL,
		  no_recompute BIT NULL,
		  has_filter BIT NULL,
		  filter_definition NVARCHAR(MAX) NULL
		); 

		CREATE TABLE #ComputedColumns
		(
		  index_sanity_id INT IDENTITY(1, 1) NOT NULL,
		  database_name NVARCHAR(128) NULL,
		  table_name NVARCHAR(128) NOT NULL,
		  schema_name NVARCHAR(128) NOT NULL,
		  column_name NVARCHAR(128) NULL,
		  is_nullable BIT NULL,
		  definition NVARCHAR(MAX) NULL,
		  uses_database_collation BIT NOT NULL,
		  is_persisted BIT NOT NULL,
		  is_computed BIT NOT NULL,
		  is_function INT NOT NULL,
		  column_definition NVARCHAR(MAX) NULL
		);
		
		CREATE TABLE #TraceStatus
		(
		 TraceFlag VARCHAR(10) ,
		 status BIT ,
		 Global BIT ,
		 Session BIT
		);


IF @GetAllDatabases = 1
    BEGIN
        INSERT INTO #DatabaseList (DatabaseName)
        SELECT  DB_NAME(database_id)
        FROM    sys.databases
        WHERE user_access_desc='MULTI_USER'
        AND state_desc = 'ONLINE'
        AND database_id > 4
        AND DB_NAME(database_id) NOT IN ('ReportServer','ReportServerTempDB')
        AND is_distributor = 0;
    END
ELSE
    BEGIN
        INSERT INTO #DatabaseList
                ( DatabaseName )
        SELECT CASE WHEN @DatabaseName IS NULL OR @DatabaseName = N'' THEN DB_NAME()
                    ELSE @DatabaseName END
    END

SET @NumDatabases = @@ROWCOUNT;

/* Running on 50+ databases can take a reaaallly long time, so we want explicit permission to do so (and only after warning about it) */

BEGIN TRY
        IF @NumDatabases >= 50 AND @BringThePain != 1
        BEGIN

            INSERT    #BlitzIndexResults ( Priority, check_id, findings_group, finding, URL, details, index_definition,
                                            index_usage_summary, index_size_summary )
            VALUES  ( -1, 0 , 
		            @ScriptVersionName,
                    CASE WHEN @GetAllDatabases = 1 THEN N'All Databases' ELSE N'Database ' + QUOTENAME(@DatabaseName) + N' as of ' + CONVERT(NVARCHAR(16),GETDATE(),121) END, 
                    N'From Your Community Volunteers' ,   N'http://www.BrentOzar.com/BlitzIndex' ,
                    N''
                    , N'',N''
                    );
            INSERT    #BlitzIndexResults ( Priority, check_id, findings_group, finding, database_name, URL, details, index_definition,
                                            index_usage_summary, index_size_summary )
            VALUES  ( 1, 0 , 
		           N'You''re trying to run sp_BlitzIndex on a server with ' + CAST(@NumDatabases AS NVARCHAR(8)) + N' databases. ',
                   N'Running sp_BlitzIndex on a server with 50+ databases may cause temporary insanity for the server and/or user.',
				   N'If you''re sure you want to do this, run again with the parameter @BringThePain = 1.',
                   'http://FirstResponderKit.org', '', '', '', ''
                    );        
		
		SELECT bir.blitz_result_id,
               bir.check_id,
               bir.index_sanity_id,
               bir.Priority,
               bir.findings_group,
               bir.finding,
               bir.database_name,
               bir.URL,
               bir.details,
               bir.index_definition,
               bir.secret_columns,
               bir.index_usage_summary,
               bir.index_size_summary,
               bir.create_tsql,
               bir.more_info 
			   FROM #BlitzIndexResults AS bir

		RETURN;

		END
END TRY
BEGIN CATCH
        RAISERROR (N'Failure to execute due to number of databases.', 0,1) WITH NOWAIT;

        SELECT    @msg = ERROR_MESSAGE(), @ErrorSeverity = ERROR_SEVERITY(), @ErrorState = ERROR_STATE();

        RAISERROR (@msg, 
               @ErrorSeverity, 
               @ErrorState 
               );
        
        WHILE @@trancount > 0 
            ROLLBACK;

        RETURN;
    END CATCH;

/* Permission granted or unnecessary? Ok, let's go! */

DECLARE c1 CURSOR 
LOCAL FAST_FORWARD 
FOR 
SELECT DatabaseName FROM #DatabaseList ORDER BY DatabaseName

OPEN c1
FETCH NEXT FROM c1 INTO @DatabaseName
                WHILE @@FETCH_STATUS = 0
BEGIN
    
    RAISERROR (@LineFeed, 0, 1) WITH NOWAIT;
    RAISERROR (@LineFeed, 0, 1) WITH NOWAIT;
    RAISERROR (@DatabaseName, 0, 1) WITH NOWAIT;

SELECT   @DatabaseID = [database_id]
FROM     sys.databases
         WHERE [name] = @DatabaseName
         AND user_access_desc='MULTI_USER'
         AND state_desc = 'ONLINE';

/* Last startup */
SELECT @DaysUptime = CAST(DATEDIFF(hh,create_date,GETDATE())/24. AS NUMERIC (23,2))
FROM    sys.databases
WHERE   database_id = 2;

IF @DaysUptime = 0 SET @DaysUptime = .01;

----------------------------------------
--STEP 1: OBSERVE THE PATIENT
--This step puts index information into temp tables.
----------------------------------------
BEGIN TRY
    BEGIN

        --Validate SQL Server Verson

        IF (SELECT LEFT(@SQLServerProductVersion,
              CHARINDEX('.',@SQLServerProductVersion,0)-1
              )) <= 9
        BEGIN
            SET @msg=N'sp_BlitzIndex is only supported on SQL Server 2008 and higher. The version of this instance is: ' + @SQLServerProductVersion;
            RAISERROR(@msg,16,1);
        END

        --Short circuit here if database name does not exist.
        IF @DatabaseName IS NULL OR @DatabaseID IS NULL
        BEGIN
            SET @msg='Database does not exist or is not online/multi-user: cannot proceed.'
            RAISERROR(@msg,16,1);
        END    

        --Validate parameters.
        IF (@Mode NOT IN (0,1,2,3,4))
        BEGIN
            SET @msg=N'Invalid @Mode parameter. 0=diagnose, 1=summarize, 2=index detail, 3=missing index detail, 4=diagnose detail';
            RAISERROR(@msg,16,1);
        END

        IF (@Mode <> 0 AND @TableName IS NOT NULL)
        BEGIN
            SET @msg=N'Setting the @Mode doesn''t change behavior if you supply @TableName. Use default @Mode=0 to see table detail.';
            RAISERROR(@msg,16,1);
        END

        IF ((@Mode <> 0 OR @TableName IS NOT NULL) AND @Filter <> 0)
        BEGIN
            SET @msg=N'@Filter only appies when @Mode=0 and @TableName is not specified. Please try again.';
            RAISERROR(@msg,16,1);
        END

        IF (@SchemaName IS NOT NULL AND @TableName IS NULL) 
        BEGIN
            SET @msg='We can''t run against a whole schema! Specify a @TableName, or leave both NULL for diagnosis.'
            RAISERROR(@msg,16,1);
        END


        IF  (@TableName IS NOT NULL AND @SchemaName IS NULL)
        BEGIN
            SET @SchemaName=N'dbo'
            SET @msg='@SchemaName wasn''t specified-- assuming schema=dbo.'
            RAISERROR(@msg,1,1) WITH NOWAIT;
        END

        --If a table is specified, grab the object id.
        --Short circuit if it doesn't exist.
        IF @TableName IS NOT NULL
        BEGIN
            SET @dsql = N'
                    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
                    SELECT    @ObjectID= OBJECT_ID
                    FROM    ' + QUOTENAME(@DatabaseName) + N'.sys.objects AS so
                    JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.schemas AS sc on 
                        so.schema_id=sc.schema_id
                    where so.type in (''U'', ''V'')
                    and so.name=' + QUOTENAME(@TableName,'''')+ N'
                    and sc.name=' + QUOTENAME(@SchemaName,'''')+ N'
                    /*Has a row in sys.indexes. This lets us get indexed views.*/
                    and exists (
                        SELECT si.name
                        FROM ' + QUOTENAME(@DatabaseName) + '.sys.indexes AS si 
                        WHERE so.object_id=si.object_id)
                    OPTION (RECOMPILE);';

            SET @params='@ObjectID INT OUTPUT'                

            IF @dsql IS NULL 
                RAISERROR('@dsql is null',16,1);

            EXEC sp_executesql @dsql, @params, @ObjectID=@ObjectID OUTPUT;
            
            IF @ObjectID IS NULL
                    BEGIN
                        SET @msg=N'Oh, this is awkward. I can''t find the table or indexed view you''re looking for in that database.' + CHAR(10) +
                            N'Please check your parameters.'
                        RAISERROR(@msg,1,1);
                        RETURN;
                    END
        END

        --set @collation
        SELECT @collation=collation_name
        FROM sys.databases
        WHERE database_id=@DatabaseID;

        --insert columns for clustered indexes and heaps
        --collect info on identity columns for this one
        SET @dsql = N'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
                SELECT ' + CAST(@DatabaseID AS NVARCHAR(16)) + ',    
                    si.object_id, 
                    si.index_id, 
                    sc.key_ordinal, 
                    sc.is_included_column, 
                    sc.is_descending_key,
                    sc.partition_ordinal,
                    c.name as column_name, 
                    st.name as system_type_name,
                    c.max_length,
                    c.[precision],
                    c.[scale],
                    c.collation_name,
                    c.is_nullable,
                    c.is_identity,
                    c.is_computed,
                    c.is_replicated,
                    ' + CASE WHEN @SQLServerProductVersion NOT LIKE '9%' THEN N'c.is_sparse' ELSE N'NULL as is_sparse' END + N',
                    ' + CASE WHEN @SQLServerProductVersion NOT LIKE '9%' THEN N'c.is_filestream' ELSE N'NULL as is_filestream' END + N',
                    CAST(ic.seed_value AS BIGINT),
                    CAST(ic.increment_value AS INT),
                    CAST(ic.last_value AS BIGINT),
                    ic.is_not_for_replication
                FROM    ' + QUOTENAME(@DatabaseName) + N'.sys.indexes si
                JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.columns c ON
                    si.object_id=c.object_id
                LEFT JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.index_columns sc ON 
                    sc.object_id = si.object_id
                    and sc.index_id=si.index_id
                    AND sc.column_id=c.column_id
                LEFT JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.identity_columns ic ON
                    c.object_id=ic.object_id and
                    c.column_id=ic.column_id
                JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.types st ON 
                    c.system_type_id=st.system_type_id
                    AND c.user_type_id=st.user_type_id
                WHERE si.index_id in (0,1) ' 
                    + CASE WHEN @ObjectID IS NOT NULL 
                        THEN N' AND si.object_id=' + CAST(@ObjectID AS NVARCHAR(30)) 
                    ELSE N'' END 
                + N'OPTION (RECOMPILE);';

        IF @dsql IS NULL 
            RAISERROR('@dsql is null',16,1);

        RAISERROR (N'Inserting data into #IndexColumns for clustered indexes and heaps',0,1) WITH NOWAIT;
        INSERT    #IndexColumns ( database_id, object_id, index_id, key_ordinal, is_included_column, is_descending_key, partition_ordinal,
            column_name, system_type_name, max_length, precision, scale, collation_name, is_nullable, is_identity, is_computed,
            is_replicated, is_sparse, is_filestream, seed_value, increment_value, last_value, is_not_for_replication )
                EXEC sp_executesql @dsql;

        --insert columns for nonclustered indexes
        --this uses a full join to sys.index_columns
        --We don't collect info on identity columns here. They may be in NC indexes, but we just analyze identities in the base table.
        SET @dsql = N'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
                SELECT ' + CAST(@DatabaseID AS NVARCHAR(16)) + ',    
                    si.object_id, 
                    si.index_id, 
                    sc.key_ordinal, 
                    sc.is_included_column, 
                    sc.is_descending_key,
                    sc.partition_ordinal,
                    c.name as column_name, 
                    st.name as system_type_name,
                    c.max_length,
                    c.[precision],
                    c.[scale],
                    c.collation_name,
                    c.is_nullable,
                    c.is_identity,
                    c.is_computed,
                    c.is_replicated,
                    ' + CASE WHEN @SQLServerProductVersion NOT LIKE '9%' THEN N'c.is_sparse' ELSE N'NULL AS is_sparse' END + N',
                    ' + CASE WHEN @SQLServerProductVersion NOT LIKE '9%' THEN N'c.is_filestream' ELSE N'NULL AS is_filestream' END + N'                
                FROM    ' + QUOTENAME(@DatabaseName) + N'.sys.indexes AS si
                JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.columns AS c ON
                    si.object_id=c.object_id
                JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.index_columns AS sc ON 
                    sc.object_id = si.object_id
                    and sc.index_id=si.index_id
                    AND sc.column_id=c.column_id
                JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.types AS st ON 
                    c.system_type_id=st.system_type_id
                    AND c.user_type_id=st.user_type_id
                WHERE si.index_id not in (0,1) ' 
                    + CASE WHEN @ObjectID IS NOT NULL 
                        THEN N' AND si.object_id=' + CAST(@ObjectID AS NVARCHAR(30)) 
                    ELSE N'' END 
                + N'OPTION (RECOMPILE);';

        IF @dsql IS NULL 
            RAISERROR('@dsql is null',16,1);

        RAISERROR (N'Inserting data into #IndexColumns for nonclustered indexes',0,1) WITH NOWAIT;
        INSERT    #IndexColumns ( database_id, object_id, index_id, key_ordinal, is_included_column, is_descending_key, partition_ordinal,
            column_name, system_type_name, max_length, precision, scale, collation_name, is_nullable, is_identity, is_computed,
            is_replicated, is_sparse, is_filestream )
                EXEC sp_executesql @dsql;
                    
        SET @dsql = N'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
                SELECT    ' + CAST(@DatabaseID AS NVARCHAR(10)) + ' AS database_id, 
                        so.object_id, 
                        si.index_id, 
                        si.type,
                        ' + QUOTENAME(@DatabaseName, '''') + ' AS database_name, 
                        COALESCE(sc.NAME, ''Unknown'') AS [schema_name],
                        COALESCE(so.name, ''Unknown'') AS [object_name], 
                        COALESCE(si.name, ''Unknown'') AS [index_name],
                        CASE    WHEN so.[type] = CAST(''V'' AS CHAR(2)) THEN 1 ELSE 0 END, 
                        si.is_unique, 
                        si.is_primary_key, 
                        CASE when si.type = 3 THEN 1 ELSE 0 END AS is_XML,
                        CASE when si.type = 4 THEN 1 ELSE 0 END AS is_spatial,
                        CASE when si.type = 6 THEN 1 ELSE 0 END AS is_NC_columnstore,
                        CASE when si.type = 5 then 1 else 0 end as is_CX_columnstore,
                        si.is_disabled,
                        si.is_hypothetical, 
                        si.is_padded, 
                        si.fill_factor,'
                        + CASE WHEN @SQLServerProductVersion NOT LIKE '9%' THEN '
                        CASE WHEN si.filter_definition IS NOT NULL THEN si.filter_definition
                             ELSE ''''
                        END AS filter_definition' ELSE ''''' AS filter_definition' END + '
                        , ISNULL(us.user_seeks, 0), ISNULL(us.user_scans, 0),
                        ISNULL(us.user_lookups, 0), ISNULL(us.user_updates, 0), us.last_user_seek, us.last_user_scan,
                        us.last_user_lookup, us.last_user_update,
                        so.create_date, so.modify_date
                FROM    ' + QUOTENAME(@DatabaseName) + '.sys.indexes AS si WITH (NOLOCK)
                        JOIN ' + QUOTENAME(@DatabaseName) + '.sys.objects AS so WITH (NOLOCK) ON si.object_id = so.object_id
                                               AND so.is_ms_shipped = 0 /*Exclude objects shipped by Microsoft*/
                                               AND so.type <> ''TF'' /*Exclude table valued functions*/
                        JOIN ' + QUOTENAME(@DatabaseName) + '.sys.schemas sc ON so.schema_id = sc.schema_id
                        LEFT JOIN sys.dm_db_index_usage_stats AS us WITH (NOLOCK) ON si.[object_id] = us.[object_id]
                                                                       AND si.index_id = us.index_id
                                                                       AND us.database_id = '+ CAST(@DatabaseID AS NVARCHAR(10)) + '
                WHERE    si.[type] IN ( 0, 1, 2, 3, 4, 5, 6 ) 
                /* Heaps, clustered, nonclustered, XML, spatial, Cluster Columnstore, NC Columnstore */ ' +
                CASE WHEN @TableName IS NOT NULL THEN ' and so.name=' + QUOTENAME(@TableName,'''') + ' ' ELSE '' END + 
        'OPTION    ( RECOMPILE );
        ';
        IF @dsql IS NULL 
            RAISERROR('@dsql is null',16,1);

        RAISERROR (N'Inserting data into #IndexSanity',0,1) WITH NOWAIT;
        INSERT    #IndexSanity ( [database_id], [object_id], [index_id], [index_type], [database_name], [schema_name], [object_name],
                                index_name, is_indexed_view, is_unique, is_primary_key, is_XML, is_spatial, is_NC_columnstore, is_CX_columnstore,
                                is_disabled, is_hypothetical, is_padded, fill_factor, filter_definition, user_seeks, user_scans, 
                                user_lookups, user_updates, last_user_seek, last_user_scan, last_user_lookup, last_user_update,
                                create_date, modify_date )
                EXEC sp_executesql @dsql;

        RAISERROR (N'Updating #IndexSanity.key_column_names',0,1) WITH NOWAIT;
        UPDATE    #IndexSanity
        SET        key_column_names = D1.key_column_names
        FROM    #IndexSanity si
                CROSS APPLY ( SELECT    RTRIM(STUFF( (SELECT    N', ' + c.column_name 
                                    + N' {' + system_type_name + N' ' + CAST(max_length AS NVARCHAR(50)) +  N'}'
                                        AS col_definition
                                    FROM    #IndexColumns c
                                    WHERE    c.database_id= si.database_id
                                            AND c.object_id = si.object_id
                                            AND c.index_id = si.index_id
                                            AND c.is_included_column = 0 /*Just Keys*/
                                            AND c.key_ordinal > 0 /*Ignore non-key columns, such as partitioning keys*/
                                    ORDER BY c.object_id, c.index_id, c.key_ordinal    
                            FOR      XML PATH('') ,TYPE).value('.', 'varchar(max)'), 1, 1, ''))
                                        ) D1 ( key_column_names )

        RAISERROR (N'Updating #IndexSanity.partition_key_column_name',0,1) WITH NOWAIT;
        UPDATE    #IndexSanity
        SET        partition_key_column_name = D1.partition_key_column_name
        FROM    #IndexSanity si
                CROSS APPLY ( SELECT    RTRIM(STUFF( (SELECT    N', ' + c.column_name AS col_definition
                                    FROM    #IndexColumns c
                                    WHERE    c.database_id= si.database_id
                                            AND c.object_id = si.object_id
                                            AND c.index_id = si.index_id
                                            AND c.partition_ordinal <> 0 /*Just Partitioned Keys*/
                                    ORDER BY c.object_id, c.index_id, c.key_ordinal    
                            FOR      XML PATH('') , TYPE).value('.', 'varchar(max)'), 1, 1,''))) D1 
                                        ( partition_key_column_name )

        RAISERROR (N'Updating #IndexSanity.key_column_names_with_sort_order',0,1) WITH NOWAIT;
        UPDATE    #IndexSanity
        SET        key_column_names_with_sort_order = D2.key_column_names_with_sort_order
        FROM    #IndexSanity si
                CROSS APPLY ( SELECT    RTRIM(STUFF( (SELECT    N', ' + c.column_name + CASE c.is_descending_key
                                    WHEN 1 THEN N' DESC'
                                    ELSE N''
                                + N' {' + system_type_name + N' ' + CAST(max_length AS NVARCHAR(50)) +  N'}'
                                END AS col_definition
                            FROM    #IndexColumns c
                            WHERE    c.database_id= si.database_id
                                    AND c.object_id = si.object_id
                                    AND c.index_id = si.index_id
                                    AND c.is_included_column = 0 /*Just Keys*/
                                    AND c.key_ordinal > 0 /*Ignore non-key columns, such as partitioning keys*/
                            ORDER BY c.object_id, c.index_id, c.key_ordinal    
                    FOR      XML PATH('') , TYPE).value('.', 'varchar(max)'), 1, 1, ''))
                    ) D2 ( key_column_names_with_sort_order )

        RAISERROR (N'Updating #IndexSanity.key_column_names_with_sort_order_no_types (for create tsql)',0,1) WITH NOWAIT;
        UPDATE    #IndexSanity
        SET        key_column_names_with_sort_order_no_types = D2.key_column_names_with_sort_order_no_types
        FROM    #IndexSanity si
                CROSS APPLY ( SELECT    RTRIM(STUFF( (SELECT    N', ' + QUOTENAME(c.column_name) + CASE c.is_descending_key
                                    WHEN 1 THEN N' [DESC]'
                                    ELSE N''
                                END AS col_definition
                            FROM    #IndexColumns c
                            WHERE    c.database_id= si.database_id
                                    AND c.object_id = si.object_id
                                    AND c.index_id = si.index_id
                                    AND c.is_included_column = 0 /*Just Keys*/
                                    AND c.key_ordinal > 0 /*Ignore non-key columns, such as partitioning keys*/
                            ORDER BY c.object_id, c.index_id, c.key_ordinal    
                    FOR      XML PATH('') , TYPE).value('.', 'varchar(max)'), 1, 1, ''))
                    ) D2 ( key_column_names_with_sort_order_no_types )

        RAISERROR (N'Updating #IndexSanity.include_column_names',0,1) WITH NOWAIT;
        UPDATE    #IndexSanity
        SET        include_column_names = D3.include_column_names
        FROM    #IndexSanity si
                CROSS APPLY ( SELECT    RTRIM(STUFF( (SELECT    N', ' + c.column_name
                                + N' {' + system_type_name + N' ' + CAST(max_length AS NVARCHAR(50)) +  N'}'
                                FROM    #IndexColumns c
                                WHERE    c.database_id= si.database_id
                                        AND c.object_id = si.object_id
                                        AND c.index_id = si.index_id
                                        AND c.is_included_column = 1 /*Just includes*/
                                ORDER BY c.column_name /*Order doesn't matter in includes, 
                                        this is here to make rows easy to compare.*/ 
                        FOR      XML PATH('') ,  TYPE).value('.', 'varchar(max)'), 1, 1, ''))
                        ) D3 ( include_column_names );

        RAISERROR (N'Updating #IndexSanity.include_column_names_no_types (for create tsql)',0,1) WITH NOWAIT;
        UPDATE    #IndexSanity
        SET        include_column_names_no_types = D3.include_column_names_no_types
        FROM    #IndexSanity si
                CROSS APPLY ( SELECT    RTRIM(STUFF( (SELECT    N', ' + QUOTENAME(c.column_name)
                                FROM    #IndexColumns c
                                        WHERE    c.database_id= si.database_id
                                        AND c.object_id = si.object_id
                                        AND c.index_id = si.index_id
                                        AND c.is_included_column = 1 /*Just includes*/
                                ORDER BY c.column_name /*Order doesn't matter in includes, 
                                        this is here to make rows easy to compare.*/ 
                        FOR      XML PATH('') ,  TYPE).value('.', 'varchar(max)'), 1, 1, ''))
                        ) D3 ( include_column_names_no_types );

        RAISERROR (N'Updating #IndexSanity.count_key_columns and count_include_columns',0,1) WITH NOWAIT;
        UPDATE    #IndexSanity
        SET        count_included_columns = D4.count_included_columns,
                count_key_columns = D4.count_key_columns
        FROM    #IndexSanity si
                CROSS APPLY ( SELECT    SUM(CASE WHEN is_included_column = 'true' THEN 1
                                                 ELSE 0
                                            END) AS count_included_columns,
                                        SUM(CASE WHEN is_included_column = 'false' AND c.key_ordinal > 0 THEN 1
                                                 ELSE 0
                                            END) AS count_key_columns
                              FROM        #IndexColumns c
                                    WHERE    c.database_id= si.database_id
                                            AND c.object_id = si.object_id
                                        AND c.index_id = si.index_id 
                                        ) AS D4 ( count_included_columns, count_key_columns );

		 IF (@SkipPartitions = 0)
			BEGIN			
			IF (SELECT LEFT(@SQLServerProductVersion,
			      CHARINDEX('.',@SQLServerProductVersion,0)-1 )) <= 2147483647 --Make change here 			
			BEGIN
            
			RAISERROR (N'Preferring non-2012 syntax with LEFT JOIN to sys.dm_db_index_operational_stats',0,1) WITH NOWAIT;

            --NOTE: If you want to use the newer syntax for 2012+, you'll have to change 2147483647 to 11 on line ~819
			--This change was made because on a table with lots of paritions, the OUTER APPLY was crazy slow.
            SET @dsql = N'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
                        SELECT    ' + CAST(@DatabaseID AS NVARCHAR(10)) + ' AS database_id,
                                ps.object_id, 
                                ps.index_id, 
                                ps.partition_number, 
                                ps.row_count,
                                ps.reserved_page_count * 8. / 1024. AS reserved_MB,
                                ps.lob_reserved_page_count * 8. / 1024. AS reserved_LOB_MB,
                                ps.row_overflow_reserved_page_count * 8. / 1024. AS reserved_row_overflow_MB,
                                os.leaf_insert_count, 
                                os.leaf_delete_count, 
                                os.leaf_update_count, 
                                os.range_scan_count, 
                                os.singleton_lookup_count,  
                                os.forwarded_fetch_count,
                                os.lob_fetch_in_pages, 
                                os.lob_fetch_in_bytes, 
                                os.row_overflow_fetch_in_pages,
                                os.row_overflow_fetch_in_bytes, 
                                os.row_lock_count, 
                                os.row_lock_wait_count,
                                os.row_lock_wait_in_ms, 
                                os.page_lock_count, 
                                os.page_lock_wait_count, 
                                os.page_lock_wait_in_ms,
                                os.index_lock_promotion_attempt_count, 
                                os.index_lock_promotion_count, 
                            ' + CASE WHEN @SQLServerProductVersion NOT LIKE '9%' THEN 'par.data_compression_desc ' ELSE 'null as data_compression_desc' END + '
                    FROM    ' + QUOTENAME(@DatabaseName) + '.sys.dm_db_partition_stats AS ps  
                    JOIN ' + QUOTENAME(@DatabaseName) + '.sys.partitions AS par on ps.partition_id=par.partition_id
                    JOIN ' + QUOTENAME(@DatabaseName) + '.sys.objects AS so ON ps.object_id = so.object_id
                               AND so.is_ms_shipped = 0 /*Exclude objects shipped by Microsoft*/
                               AND so.type <> ''TF'' /*Exclude table valued functions*/
                    LEFT JOIN ' + QUOTENAME(@DatabaseName) + '.sys.dm_db_index_operational_stats('
                + CAST(@DatabaseID AS NVARCHAR(10)) + ', NULL, NULL,NULL) AS os ON
                    ps.object_id=os.object_id and ps.index_id=os.index_id and ps.partition_number=os.partition_number 
                    WHERE 1=1 
                    ' + CASE WHEN @ObjectID IS NOT NULL THEN N'AND so.object_id=' + CAST(@ObjectID AS NVARCHAR(30)) + N' ' ELSE N' ' END + '
                    ' + CASE WHEN @Filter = 2 THEN N'AND ps.reserved_page_count * 8./1024. > ' + CAST(@FilterMB AS NVARCHAR(5)) + N' ' ELSE N' ' END + '
            ORDER BY ps.object_id,  ps.index_id, ps.partition_number
            OPTION    ( RECOMPILE );
            ';
        END
        ELSE
        BEGIN
        RAISERROR (N'Using 2012 syntax to query sys.dm_db_index_operational_stats',0,1) WITH NOWAIT;
		--This is the syntax that will be used if you change 2147483647 to 11 on line ~819.
		--If you have a lot of paritions and this suddenly starts running for a long time, change it back.
         SET @dsql = N'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
                        SELECT  ' + CAST(@DatabaseID AS NVARCHAR(10)) + ' AS database_id,
                                ps.object_id, 
                                ps.index_id, 
                                ps.partition_number, 
                                ps.row_count,
                                ps.reserved_page_count * 8. / 1024. AS reserved_MB,
                                ps.lob_reserved_page_count * 8. / 1024. AS reserved_LOB_MB,
                                ps.row_overflow_reserved_page_count * 8. / 1024. AS reserved_row_overflow_MB,
                                os.leaf_insert_count, 
                                os.leaf_delete_count, 
                                os.leaf_update_count, 
                                os.range_scan_count, 
                                os.singleton_lookup_count,  
                                os.forwarded_fetch_count,
                                os.lob_fetch_in_pages, 
                                os.lob_fetch_in_bytes, 
                                os.row_overflow_fetch_in_pages,
                                os.row_overflow_fetch_in_bytes, 
                                os.row_lock_count, 
                                os.row_lock_wait_count,
                                os.row_lock_wait_in_ms, 
                                os.page_lock_count, 
                                os.page_lock_wait_count, 
                                os.page_lock_wait_in_ms,
                                os.index_lock_promotion_attempt_count, 
                                os.index_lock_promotion_count, 
                                ' + CASE WHEN @SQLServerProductVersion NOT LIKE '9%' THEN N'par.data_compression_desc ' ELSE N'null as data_compression_desc' END + N'
                        FROM    ' + QUOTENAME(@DatabaseName) + N'.sys.dm_db_partition_stats AS ps  
                        JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.partitions AS par on ps.partition_id=par.partition_id
                        JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.objects AS so ON ps.object_id = so.object_id
                                   AND so.is_ms_shipped = 0 /*Exclude objects shipped by Microsoft*/
                                   AND so.type <> ''TF'' /*Exclude table valued functions*/
                        OUTER APPLY ' + QUOTENAME(@DatabaseName) + N'.sys.dm_db_index_operational_stats('
                    + CAST(@DatabaseID AS NVARCHAR(10)) + N', ps.object_id, ps.index_id,ps.partition_number) AS os
                        WHERE 1=1 
                        ' + CASE WHEN @ObjectID IS NOT NULL THEN N'AND so.object_id=' + CAST(@ObjectID AS NVARCHAR(30)) + N' ' ELSE N' ' END + N'
                        ' + CASE WHEN @Filter = 2 THEN N'AND ps.reserved_page_count * 8./1024. > ' + CAST(@FilterMB AS NVARCHAR(5)) + N' ' ELSE N' ' END + '
                ORDER BY ps.object_id,  ps.index_id, ps.partition_number
                OPTION    ( RECOMPILE );
                ';
        END;       

        IF @dsql IS NULL 
            RAISERROR('@dsql is null',16,1);

        RAISERROR (N'Inserting data into #IndexPartitionSanity',0,1) WITH NOWAIT;
        INSERT    #IndexPartitionSanity ( [database_id],
                                          [object_id], 
                                          index_id, 
                                          partition_number, 
                                          row_count, 
                                          reserved_MB,
                                          reserved_LOB_MB, 
                                          reserved_row_overflow_MB, 
                                          leaf_insert_count,
                                          leaf_delete_count, 
                                          leaf_update_count, 
                                          range_scan_count,
                                          singleton_lookup_count,
                                          forwarded_fetch_count, 
                                          lob_fetch_in_pages, 
                                          lob_fetch_in_bytes, 
                                          row_overflow_fetch_in_pages,
                                          row_overflow_fetch_in_bytes, 
                                          row_lock_count, 
                                          row_lock_wait_count,
                                          row_lock_wait_in_ms, 
                                          page_lock_count, 
                                          page_lock_wait_count,
                                          page_lock_wait_in_ms, 
                                          index_lock_promotion_attempt_count,
                                          index_lock_promotion_count, 
                                          data_compression_desc )
                EXEC sp_executesql @dsql;
        
        RAISERROR (N'Updating index_sanity_id on #IndexPartitionSanity',0,1) WITH NOWAIT;
        UPDATE    #IndexPartitionSanity
        SET        index_sanity_id = i.index_sanity_id
        FROM #IndexPartitionSanity ps
                JOIN #IndexSanity i ON ps.[object_id] = i.[object_id]
                                        AND ps.index_id = i.index_id
                                        AND i.database_id = ps.database_id
		END; --End Check For @SkipPartitions = 0


        RAISERROR (N'Inserting data into #IndexSanitySize',0,1) WITH NOWAIT;
        INSERT    #IndexSanitySize ( [index_sanity_id], [database_id], partition_count, total_rows, total_reserved_MB,
                                     total_reserved_LOB_MB, total_reserved_row_overflow_MB, total_range_scan_count,
                                     total_singleton_lookup_count, total_leaf_delete_count, total_leaf_update_count, 
                                     total_forwarded_fetch_count,total_row_lock_count,
                                     total_row_lock_wait_count, total_row_lock_wait_in_ms, avg_row_lock_wait_in_ms,
                                     total_page_lock_count, total_page_lock_wait_count, total_page_lock_wait_in_ms,
                                     avg_page_lock_wait_in_ms, total_index_lock_promotion_attempt_count, 
                                     total_index_lock_promotion_count, data_compression_desc )
                SELECT    index_sanity_id, ipp.database_id, COUNT(*), SUM(row_count), SUM(reserved_MB), SUM(reserved_LOB_MB),
                        SUM(reserved_row_overflow_MB), 
                        SUM(range_scan_count),
                        SUM(singleton_lookup_count),
                        SUM(leaf_delete_count), 
                        SUM(leaf_update_count),
                        SUM(forwarded_fetch_count),
                        SUM(row_lock_count), 
                        SUM(row_lock_wait_count),
                        SUM(row_lock_wait_in_ms), 
                        CASE WHEN SUM(row_lock_wait_in_ms) > 0 THEN
                            SUM(row_lock_wait_in_ms)/(1.*SUM(row_lock_wait_count))
                        ELSE 0 END AS avg_row_lock_wait_in_ms,           
                        SUM(page_lock_count), 
                        SUM(page_lock_wait_count),
                        SUM(page_lock_wait_in_ms), 
                        CASE WHEN SUM(page_lock_wait_in_ms) > 0 THEN
                            SUM(page_lock_wait_in_ms)/(1.*SUM(page_lock_wait_count))
                        ELSE 0 END AS avg_page_lock_wait_in_ms,           
                        SUM(index_lock_promotion_attempt_count),
                        SUM(index_lock_promotion_count),
                        LEFT(MAX(data_compression_info.data_compression_rollup),8000)
                FROM #IndexPartitionSanity ipp
                /* individual partitions can have distinct compression settings, just roll them into a list here*/
                OUTER APPLY (SELECT STUFF((
                    SELECT    N', ' + data_compression_desc
                    FROM #IndexPartitionSanity ipp2
                    WHERE ipp.[object_id]=ipp2.[object_id]
                        AND ipp.[index_id]=ipp2.[index_id]
                        AND ipp.database_id = @DatabaseID
                    ORDER BY ipp2.partition_number
                    FOR      XML PATH(''),TYPE).value('.', 'varchar(max)'), 1, 1, '')) 
                        data_compression_info(data_compression_rollup)
                WHERE ipp.database_id = @DatabaseID
                GROUP BY index_sanity_id, ipp.database_id
                ORDER BY index_sanity_id 
        OPTION    ( RECOMPILE );

        RAISERROR (N'Adding UQ index on #IndexSanity (database_id, object_id, index_id)',0,1) WITH NOWAIT;
        IF NOT EXISTS(SELECT 1 FROM tempdb.sys.indexes WHERE name='uq_database_id_object_id_index_id') 
            CREATE UNIQUE INDEX uq_database_id_object_id_index_id ON #IndexSanity (database_id, object_id, index_id);

        RAISERROR (N'Inserting data into #MissingIndexes',0,1) WITH NOWAIT;
        SET @dsql=N'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
                SELECT    id.object_id, ' + QUOTENAME(@DatabaseName,'''') + N', sc.[name], so.[name], id.statement , gs.avg_total_user_cost, 
                        gs.avg_user_impact, gs.user_seeks, gs.user_scans, gs.unique_compiles,id.equality_columns, 
                        id.inequality_columns,id.included_columns
                FROM    sys.dm_db_missing_index_groups ig
                        JOIN sys.dm_db_missing_index_details id ON ig.index_handle = id.index_handle
                        JOIN sys.dm_db_missing_index_group_stats gs ON ig.index_group_handle = gs.group_handle
                        JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.objects so on 
                            id.object_id=so.object_id
                        JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.schemas sc on 
                            so.schema_id=sc.schema_id
                WHERE    id.database_id = ' + CAST(@DatabaseID AS NVARCHAR(30)) + '
                ' + CASE WHEN @ObjectID IS NULL THEN N'' 
                    ELSE N'and id.object_id=' + CAST(@ObjectID AS NVARCHAR(30)) 
                END +
        N'OPTION (RECOMPILE);'

        IF @dsql IS NULL 
            RAISERROR('@dsql is null',16,1);
        INSERT    #MissingIndexes ( [object_id], [database_name], [schema_name], [table_name], [statement], avg_total_user_cost, 
                                    avg_user_impact, user_seeks, user_scans, unique_compiles, equality_columns, 
                                    inequality_columns,included_columns)
        EXEC sp_executesql @dsql;

        SET @dsql = N'
            SELECT ' + QUOTENAME(@DatabaseName,'''')  + N' AS [database_name],
                fk_object.name AS foreign_key_name,
                parent_object.[object_id] AS parent_object_id,
                parent_object.name AS parent_object_name,
                referenced_object.[object_id] AS referenced_object_id,
                referenced_object.name AS referenced_object_name,
                fk.is_disabled,
                fk.is_not_trusted,
                fk.is_not_for_replication,
                parent.fk_columns,
                referenced.fk_columns,
                [update_referential_action_desc],
                [delete_referential_action_desc]
            FROM ' + QUOTENAME(@DatabaseName) + N'.sys.foreign_keys fk
            JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.objects fk_object ON fk.object_id=fk_object.object_id
            JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.objects parent_object ON fk.parent_object_id=parent_object.object_id
            JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.objects referenced_object ON fk.referenced_object_id=referenced_object.object_id
            CROSS APPLY ( SELECT    STUFF( (SELECT    N'', '' + c_parent.name AS fk_columns
                                            FROM    ' + QUOTENAME(@DatabaseName) + N'.sys.foreign_key_columns fkc 
                                            JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.columns c_parent ON fkc.parent_object_id=c_parent.[object_id]
                                                AND fkc.parent_column_id=c_parent.column_id
                                            WHERE    fk.parent_object_id=fkc.parent_object_id
                                                AND fk.[object_id]=fkc.constraint_object_id
                                            ORDER BY fkc.constraint_column_id 
                                    FOR      XML PATH('''') ,
                                              TYPE).value(''.'', ''varchar(max)''), 1, 1, '''')/*This is how we remove the first comma*/ ) parent ( fk_columns )
            CROSS APPLY ( SELECT    STUFF( (SELECT    N'', '' + c_referenced.name AS fk_columns
                                            FROM    ' + QUOTENAME(@DatabaseName) + N'.sys.    foreign_key_columns fkc 
                                            JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.columns c_referenced ON fkc.referenced_object_id=c_referenced.[object_id]
                                                AND fkc.referenced_column_id=c_referenced.column_id
                                            WHERE    fk.referenced_object_id=fkc.referenced_object_id
                                                and fk.[object_id]=fkc.constraint_object_id
                                            ORDER BY fkc.constraint_column_id  /*order by col name, we don''t have anything better*/
                                    FOR      XML PATH('''') ,
                                              TYPE).value(''.'', ''varchar(max)''), 1, 1, '''') ) referenced ( fk_columns )
            ' + CASE WHEN @ObjectID IS NOT NULL THEN 
                    'WHERE fk.parent_object_id=' + CAST(@ObjectID AS NVARCHAR(30)) + N' OR fk.referenced_object_id=' + CAST(@ObjectID AS NVARCHAR(30)) + N' ' 
                    ELSE N' ' END + '
            ORDER BY parent_object_name, foreign_key_name
			OPTION (RECOMPILE);';
        IF @dsql IS NULL 
            RAISERROR('@dsql is null',16,1);

        RAISERROR (N'Inserting data into #ForeignKeys',0,1) WITH NOWAIT;
        INSERT  #ForeignKeys ( [database_name], foreign_key_name, parent_object_id,parent_object_name, referenced_object_id, referenced_object_name,
                                is_disabled, is_not_trusted, is_not_for_replication, parent_fk_columns, referenced_fk_columns,
                                [update_referential_action_desc], [delete_referential_action_desc] )
                EXEC sp_executesql @dsql;

        RAISERROR (N'Updating #IndexSanity.referenced_by_foreign_key',0,1) WITH NOWAIT;
        UPDATE #IndexSanity
            SET is_referenced_by_foreign_key=1
        FROM #IndexSanity s
        JOIN #ForeignKeys fk ON 
            s.object_id=fk.referenced_object_id
            AND LEFT(s.key_column_names,LEN(fk.referenced_fk_columns)) = fk.referenced_fk_columns

        RAISERROR (N'Update index_secret on #IndexSanity for NC indexes.',0,1) WITH NOWAIT;
        UPDATE nc 
        SET secret_columns=
            N'[' + 
            CASE tb.count_key_columns WHEN 0 THEN '1' ELSE CAST(tb.count_key_columns AS VARCHAR(10)) END +
            CASE nc.is_unique WHEN 1 THEN N' INCLUDE' ELSE N' KEY' END +
            CASE WHEN tb.count_key_columns > 1 THEN  N'S] ' ELSE N'] ' END +
            CASE tb.index_id WHEN 0 THEN '[RID]' ELSE LTRIM(tb.key_column_names) +
                /* Uniquifiers only needed on non-unique clustereds-- not heaps */
                CASE tb.is_unique WHEN 0 THEN ' [UNIQUIFIER]' ELSE N'' END
            END
            , count_secret_columns=
            CASE tb.index_id WHEN 0 THEN 1 ELSE 
                tb.count_key_columns +
                    CASE tb.is_unique WHEN 0 THEN 1 ELSE 0 END
            END
        FROM #IndexSanity AS nc
        JOIN #IndexSanity AS tb ON nc.object_id=tb.object_id
            AND tb.index_id IN (0,1) 
        WHERE nc.index_id > 1;

        RAISERROR (N'Update index_secret on #IndexSanity for heaps and non-unique clustered.',0,1) WITH NOWAIT;
        UPDATE tb
        SET secret_columns=    CASE tb.index_id WHEN 0 THEN '[RID]' ELSE '[UNIQUIFIER]' END
            , count_secret_columns = 1
        FROM #IndexSanity AS tb
        WHERE tb.index_id = 0 /*Heaps-- these have the RID */
            OR (tb.index_id=1 AND tb.is_unique=0); /* Non-unique CX: has uniquifer (when needed) */


        RAISERROR (N'Populate #IndexCreateTsql.',0,1) WITH NOWAIT;
        INSERT #IndexCreateTsql (index_sanity_id, create_tsql)
        SELECT
            index_sanity_id,
            ISNULL (
            /* Script drops for disabled non-clustered indexes*/
            CASE WHEN is_disabled = 1 AND index_id <> 1
                THEN N'--DROP INDEX ' + QUOTENAME([index_name]) + N' ON '
                 + QUOTENAME([schema_name]) + N'.' + QUOTENAME([object_name]) 
            ELSE
                CASE index_id WHEN 0 THEN N'--I''m a Heap!' 
                ELSE 
                    CASE WHEN is_XML = 1 OR is_spatial=1 THEN N'' /* Not even trying for these just yet...*/
                    ELSE 
                        CASE WHEN is_primary_key=1 THEN
                            N'ALTER TABLE ' + QUOTENAME([schema_name]) +
                                N'.' + QUOTENAME([object_name]) + 
                                N' ADD CONSTRAINT [' +
                                index_name + 
                                N'] PRIMARY KEY ' + 
                                CASE WHEN index_id=1 THEN N'CLUSTERED (' ELSE N'(' END +
                                key_column_names_with_sort_order_no_types + N' )' 
                            WHEN is_CX_columnstore= 1 THEN
                                 N'CREATE CLUSTERED COLUMNSTORE INDEX ' + QUOTENAME(index_name) + N' on ' + QUOTENAME([schema_name]) + '.' + QUOTENAME([object_name])
                        ELSE /*Else not a PK or cx columnstore */ 
                            N'CREATE ' + 
                            CASE WHEN is_unique=1 THEN N'UNIQUE ' ELSE N'' END +
                            CASE WHEN index_id=1 THEN N'CLUSTERED ' ELSE N'' END +
                            CASE WHEN is_NC_columnstore=1 THEN N'NONCLUSTERED COLUMNSTORE ' 
                            ELSE N'' END +
                            N'INDEX ['
                                 + index_name + N'] ON ' + 
                                QUOTENAME([schema_name]) + '.' + QUOTENAME([object_name]) + 
                                    CASE WHEN is_NC_columnstore=1 THEN 
                                        N' (' + ISNULL(include_column_names_no_types,'') +  N' )' 
                                    ELSE /*Else not colunnstore */ 
                                        N' (' + ISNULL(key_column_names_with_sort_order_no_types,'') +  N' )' 
                                        + CASE WHEN include_column_names_no_types IS NOT NULL THEN 
                                            N' INCLUDE (' + include_column_names_no_types + N')' 
                                            ELSE N'' 
                                        END
                                    END /*End non-colunnstore case */ 
                                + CASE WHEN filter_definition <> N'' THEN N' WHERE ' + filter_definition ELSE N'' END
                            END /*End Non-PK index CASE */ 
                        + CASE WHEN is_NC_columnstore=0 AND is_CX_columnstore=0 THEN
                            N' WITH (' 
                                + N'FILLFACTOR=' + CASE fill_factor WHEN 0 THEN N'100' ELSE CAST(fill_factor AS NVARCHAR(5)) END + ', '
                                + N'ONLINE=?, SORT_IN_TEMPDB=?'
                            + N')'
                        ELSE N'' END
                        + N';'
                      END /*End non-spatial and non-xml CASE */ 
                END
            END, '[Unknown Error]')
                AS create_tsql
        FROM #IndexSanity
        WHERE database_id = @DatabaseID;
	  
	  RAISERROR (N'Populate #PartitionCompressionInfo.',0,1) WITH NOWAIT;
	 ;WITH    [maps]
			  AS ( SELECT   
							index_sanity_id,
							partition_number,
							data_compression_desc,
							partition_number - ROW_NUMBER() OVER (PARTITION BY ips.index_sanity_id, data_compression_desc ORDER BY partition_number ) AS [rN]
				   FROM     #IndexPartitionSanity ips
					),
			[grps]
			  AS ( SELECT   MIN([maps].[partition_number]) AS [MinKey] ,
							MAX([maps].[partition_number]) AS [MaxKey] ,
							index_sanity_id,
							maps.data_compression_desc
				   FROM     [maps]
				   GROUP BY [maps].[rN], index_sanity_id, maps.data_compression_desc)
		INSERT #PartitionCompressionInfo
				(index_sanity_id, partition_compression_detail)
		SELECT DISTINCT grps.index_sanity_id , SUBSTRING((  STUFF((SELECT ', ' + ' Partition'
													+ CASE WHEN [grps2].[MinKey] < [grps2].[MaxKey]
														   THEN +'s '
																+ CAST([grps2].[MinKey] AS VARCHAR)
																+ ' - '
																+ CAST([grps2].[MaxKey] AS VARCHAR)
																+ ' use ' + grps2.data_compression_desc
														   ELSE ' '
																+ CAST([grps2].[MinKey] AS VARCHAR)
																+ ' uses '  + grps2.data_compression_desc
													  END AS [Partitions]
											 FROM   [grps] AS grps2
											 WHERE grps2.index_sanity_id = grps.index_sanity_id
											 ORDER BY grps2.MinKey, grps2.MaxKey
									FOR     XML PATH('') ,
												TYPE 
							).[value]('.', 'VARCHAR(MAX)'), 1, 1, '') ), 0, 8000) AS [partition_compression_detail]
		FROM grps;
		
		RAISERROR (N'Update #PartitionCompressionInfo.',0,1) WITH NOWAIT;
		UPDATE sz
		SET sz.data_compression_desc = pci.partition_compression_detail
		FROM #IndexSanitySize sz
		JOIN #PartitionCompressionInfo AS pci
		ON pci.index_sanity_id = sz.index_sanity_id;
                  



		IF @SkipStatistics = 0 
			BEGIN
		IF  ((PARSENAME(@SQLServerProductVersion, 4) >= 12)
		OR   (PARSENAME(@SQLServerProductVersion, 4) = 11 AND PARSENAME(@SQLServerProductVersion, 2) >= 3000)
		OR   (PARSENAME(@SQLServerProductVersion, 4) = 10 AND PARSENAME(@SQLServerProductVersion, 3) = 50 AND PARSENAME(@SQLServerProductVersion, 2) >= 2500))
		BEGIN
		RAISERROR (N'Gathering Statistics Info With Newer Syntax.',0,1) WITH NOWAIT;
		SET @dsql=N'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
					SELECT  ' + QUOTENAME(@DatabaseName,'''') + N' AS database_name,
					obj.name AS table_name,
					sch.name AS schema_name,
			        ISNULL(i.name, ''System Or User Statistic'') AS index_name,
			        c.name AS column_name,
			        s.name AS statistics_name,
			        CONVERT(DATETIME, ddsp.last_updated) AS last_statistics_update,
			        DATEDIFF(DAY, ddsp.last_updated, GETDATE()) AS days_since_last_stats_update,
			        ddsp.rows,
			        ddsp.rows_sampled,
			        CAST(ddsp.rows_sampled / ( 1. * NULLIF(ddsp.rows, 0) ) * 100 AS DECIMAL(18, 1)) AS percent_sampled,
			        ddsp.steps AS histogram_steps,
			        ddsp.modification_counter,
			        CASE WHEN ddsp.modification_counter > 0
			             THEN CAST(ddsp.modification_counter / ( 1. * NULLIF(ddsp.rows, 0) ) * 100 AS DECIMAL(18, 1))
			             ELSE ddsp.modification_counter
			        END AS percent_modifications,
			        CASE WHEN ddsp.rows < 500 THEN 500
			             ELSE CAST(( ddsp.rows * .20 ) + 500 AS INT)
			        END AS modifications_before_auto_update,
			        ISNULL(i.type_desc, ''System Or User Statistic - N/A'') AS index_type_desc,
			        CONVERT(DATETIME, obj.create_date) AS table_create_date,
			        CONVERT(DATETIME, obj.modify_date) AS table_modify_date,
					s.no_recompute,
					s.has_filter,
					s.filter_definition
			FROM    ' + QUOTENAME(@DatabaseName) + N'.sys.stats AS s
			JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.stats_columns sc
			ON      sc.object_id = s.object_id
			        AND sc.stats_id = s.stats_id
			JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.columns c
			ON      c.object_id = sc.object_id
			        AND c.column_id = sc.column_id
			JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.objects obj
			ON      s.object_id = obj.object_id
			JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.schemas sch
			ON		sch.schema_id = obj.schema_id
			LEFT JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.indexes AS i
			ON      i.object_id = s.object_id
			        AND i.index_id = s.stats_id
			OUTER APPLY ' + QUOTENAME(@DatabaseName) + N'.sys.dm_db_stats_properties(s.object_id, s.stats_id) AS ddsp
			WHERE obj.is_ms_shipped = 0
			OPTION (RECOMPILE);'
			
			IF @dsql IS NULL 
            RAISERROR('@dsql is null',16,1);

			RAISERROR (N'Inserting data into #Statistics',0,1) WITH NOWAIT;
			INSERT #Statistics ( database_name, table_name, schema_name, index_name, column_name, statistics_name, last_statistics_update, 
								days_since_last_stats_update, rows, rows_sampled, percent_sampled, histogram_steps, modification_counter, 
								percent_modifications, modifications_before_auto_update, index_type_desc, table_create_date, table_modify_date,
								no_recompute, has_filter, filter_definition)
			
			EXEC sp_executesql @dsql;
			END
			ELSE 
			BEGIN
			RAISERROR (N'Gathering Statistics Info With Older Syntax.',0,1) WITH NOWAIT;
			SET @dsql=N'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
						SELECT  ' + QUOTENAME(@DatabaseName,'''') + N' AS database_name,
								obj.name AS table_name,
								sch.name AS schema_name,
						        ISNULL(i.name, ''System Or User Statistic'') AS index_name,
						        c.name AS column_name,
						        s.name AS statistics_name,
						        CONVERT(DATETIME, STATS_DATE(s.object_id, s.stats_id)) AS last_statistics_update,
						        DATEDIFF(DAY, STATS_DATE(s.object_id, s.stats_id), GETDATE()) AS days_since_last_stats_update,
						        si.rowcnt,
						        si.rowmodctr,
						        CASE WHEN si.rowmodctr > 0 THEN CAST(si.rowmodctr / ( 1. * NULLIF(si.rowcnt, 0) ) * 100 AS DECIMAL(18, 1))
						             ELSE si.rowmodctr
						        END AS percent_modifications,
						        CASE WHEN si.rowcnt < 500 THEN 500
						             ELSE CAST(( si.rowcnt * .20 ) + 500 AS INT)
						        END AS modifications_before_auto_update,
						        ISNULL(i.type_desc, ''System Or User Statistic - N/A'') AS index_type_desc,
						        CONVERT(DATETIME, obj.create_date) AS table_create_date,
						        CONVERT(DATETIME, obj.modify_date) AS table_modify_date,
								s.no_recompute,
								'
								+ CASE WHEN @SQLServerProductVersion NOT LIKE '9%' 
								THEN N's.has_filter,
									   s.filter_definition' 
								ELSE N'NULL AS has_filter,
								       NULL AS filter_definition' END 
						+ N'								
						FROM    ' + QUOTENAME(@DatabaseName) + N'.sys.stats AS s
						INNER HASH JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.sysindexes si
						ON      si.name = s.name
						INNER HASH JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.stats_columns sc
						ON      sc.object_id = s.object_id
						        AND sc.stats_id = s.stats_id
						INNER HASH JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.columns c
						ON      c.object_id = sc.object_id
						        AND c.column_id = sc.column_id
						INNER HASH JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.objects obj
						ON      s.object_id = obj.object_id
						INNER HASH JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.schemas sch
						ON		sch.schema_id = obj.schema_id
						LEFT HASH JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.indexes AS i
						ON      i.object_id = s.object_id
						        AND i.index_id = s.stats_id
						WHERE obj.is_ms_shipped = 0
						AND si.rowcnt > 0
						OPTION (RECOMPILE);'

			IF @dsql IS NULL 
            RAISERROR('@dsql is null',16,1);

			RAISERROR (N'Inserting data into #Statistics',0,1) WITH NOWAIT;
			INSERT #Statistics(database_name, table_name, schema_name, index_name, column_name, statistics_name, 
								last_statistics_update, days_since_last_stats_update, rows, modification_counter, 
								percent_modifications, modifications_before_auto_update, index_type_desc, table_create_date, table_modify_date,
								no_recompute, has_filter, filter_definition)
			
			EXEC sp_executesql @dsql;
			END

			END

			IF  (PARSENAME(@SQLServerProductVersion, 4) >= 10)
			BEGIN
			RAISERROR (N'Gathering Computed Column Info.',0,1) WITH NOWAIT;
			SET @dsql=N'SELECT ' + QUOTENAME(@DatabaseName,'''') + N' AS DatabaseName,
   					   		   t.name AS table_name,
   					           s.name AS schema_name,
   					           c.name AS column_name,
   					           cc.is_nullable,
   					           cc.definition,
   					           cc.uses_database_collation,
   					           cc.is_persisted,
   					           cc.is_computed,
   					   		   CASE WHEN cc.definition LIKE ''%.%'' THEN 1 ELSE 0 END AS is_function,
   					   		   ''ALTER TABLE '' + QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) + 
   					   		   '' ADD '' + QUOTENAME(c.name) + '' AS '' + cc.definition  + 
							   CASE WHEN is_persisted = 1 THEN '' PERSISTED'' ELSE '''' END + '';'' COLLATE DATABASE_DEFAULT AS [column_definition]
   					   FROM    ' + QUOTENAME(@DatabaseName) + N'.sys.computed_columns AS cc
   					   JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.columns AS c
   					   ON      cc.object_id = c.object_id
   					   		   AND cc.column_id = c.column_id
   					   JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.tables AS t
   					   ON      t.object_id = cc.object_id
   					   JOIN    ' + QUOTENAME(@DatabaseName) + N'.sys.schemas AS s
   					   ON      s.schema_id = t.schema_id
					   OPTION (RECOMPILE);'

			IF @dsql IS NULL 
            RAISERROR('@dsql is null',16,1);

			INSERT #ComputedColumns
			        ( database_name, table_name, schema_name, column_name, is_nullable, definition, 
					  uses_database_collation, is_persisted, is_computed, is_function, column_definition )			
			EXEC sp_executesql @dsql;

			END 
			
			RAISERROR (N'Gathering Trace Flag Information',0,1) WITH NOWAIT;
			INSERT #TraceStatus
			EXEC ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS')			
			
END                    
END TRY
BEGIN CATCH
        RAISERROR (N'Failure populating temp tables.', 0,1) WITH NOWAIT;

        IF @dsql IS NOT NULL
        BEGIN
            SET @msg= 'Last @dsql: ' + @dsql;
            RAISERROR(@msg, 0, 1) WITH NOWAIT;
        END

        SELECT    @msg = @DatabaseName + N' database failed to process. ' + ERROR_MESSAGE(), @ErrorSeverity = ERROR_SEVERITY(), @ErrorState = ERROR_STATE();
        RAISERROR (@msg,@ErrorSeverity, @ErrorState )WITH NOWAIT;
        
        
        WHILE @@trancount > 0 
            ROLLBACK;

        RETURN;
END CATCH;
 FETCH NEXT FROM c1 INTO @DatabaseName
END
DEALLOCATE c1;

----------------------------------------
--STEP 2: DIAGNOSE THE PATIENT
--EVERY QUERY AFTER THIS GOES AGAINST TEMP TABLES ONLY.
----------------------------------------
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                BEGIN TRY
----------------------------------------
--If @TableName is specified, just return information for that table.
--The @Mode parameter doesn't matter if you're looking at a specific table.
----------------------------------------
IF @TableName IS NOT NULL
BEGIN
    RAISERROR(N'@TableName specified, giving detail only on that table.', 0,1) WITH NOWAIT;

    --We do a left join here in case this is a disabled NC.
    --In that case, it won't have any size info/pages allocated.
 
   	
	   WITH table_mode_cte AS (
        SELECT 
            s.db_schema_object_indexid, 
            s.key_column_names,
            s.index_definition, 
            ISNULL(s.secret_columns,N'') AS secret_columns,
            s.fill_factor,
            s.index_usage_summary, 
            sz.index_op_stats,
            ISNULL(sz.index_size_summary,'') /*disabled NCs will be null*/ AS index_size_summary,
			partition_compression_detail ,
            ISNULL(sz.index_lock_wait_summary,'') AS index_lock_wait_summary,
            s.is_referenced_by_foreign_key,
            (SELECT COUNT(*)
                FROM #ForeignKeys fk WHERE fk.parent_object_id=s.object_id
                AND PATINDEX (fk.parent_fk_columns, s.key_column_names)=1) AS FKs_covered_by_index,
            s.last_user_seek,
            s.last_user_scan,
            s.last_user_lookup,
            s.last_user_update,
            s.create_date,
            s.modify_date,
            ct.create_tsql,
            1 AS display_order
        FROM #IndexSanity s
        LEFT JOIN #IndexSanitySize sz ON 
            s.index_sanity_id=sz.index_sanity_id
        LEFT JOIN #IndexCreateTsql ct ON 
            s.index_sanity_id=ct.index_sanity_id
		LEFT JOIN #PartitionCompressionInfo pci ON 
			pci.index_sanity_id = s.index_sanity_id
        WHERE s.[object_id]=@ObjectID
        UNION ALL
        SELECT     N'Database ' + QUOTENAME(@DatabaseName) + N' as of ' + CONVERT(NVARCHAR(16),GETDATE(),121) +             
                N' (' + @ScriptVersionName + ')' ,   
                N'SQL Server First Responder Kit' ,   
                N'http://FirstResponderKit.org' ,
                N'From Your Community Volunteers',
                NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
                0 AS display_order
    )
    SELECT 
            db_schema_object_indexid AS [Details: db_schema.table.index(indexid)], 
            index_definition AS [Definition: [Property]] ColumnName {datatype maxbytes}], 
            secret_columns AS [Secret Columns],
            fill_factor AS [Fillfactor],
            index_usage_summary AS [Usage Stats], 
            index_op_stats AS [Op Stats],
            index_size_summary AS [Size],
			partition_compression_detail AS [Compression Type],
            index_lock_wait_summary AS [Lock Waits],
            is_referenced_by_foreign_key AS [Referenced by FK?],
            FKs_covered_by_index AS [FK Covered by Index?],
            last_user_seek AS [Last User Seek],
            last_user_scan AS [Last User Scan],
            last_user_lookup AS [Last User Lookup],
            last_user_update AS [Last User Write],
            create_date AS [Created],
            modify_date AS [Last Modified],
            create_tsql AS [Create TSQL]
    FROM table_mode_cte
    ORDER BY display_order ASC, key_column_names ASC
    OPTION    ( RECOMPILE );                        

    IF (SELECT TOP 1 [object_id] FROM    #MissingIndexes mi) IS NOT NULL
    BEGIN  
        SELECT  N'Missing index.' AS Finding ,
                N'http://BrentOzar.com/go/Indexaphobia' AS URL ,
                mi.[statement] + 
                ' Est. Benefit: '
                    + CASE WHEN magic_benefit_number >= 922337203685477 THEN '>= 922,337,203,685,477'
                    ELSE REPLACE(CONVERT(NVARCHAR(256),CAST(CAST(
                                        (magic_benefit_number/@DaysUptime)
                                        AS BIGINT) AS MONEY), 1), '.00', '')
                    END AS [Estimated Benefit],
                missing_index_details AS [Missing Index Request] ,
                index_estimated_impact AS [Estimated Impact],
                create_tsql AS [Create TSQL]
        FROM    #MissingIndexes mi
        WHERE   [object_id] = @ObjectID
                /* Minimum benefit threshold = 100k/day of uptime */
        AND (magic_benefit_number/@DaysUptime) >= 100000
        ORDER BY magic_benefit_number DESC
        OPTION    ( RECOMPILE );
    END       
    ELSE     
    SELECT 'No missing indexes.' AS finding;

    SELECT     
        column_name AS [Column Name],
        (SELECT COUNT(*)  
            FROM #IndexColumns c2 
            WHERE c2.column_name=c.column_name
            AND c2.key_ordinal IS NOT NULL)
        + CASE WHEN c.index_id = 1 AND c.key_ordinal IS NOT NULL THEN
            -1+ (SELECT COUNT(DISTINCT index_id)
            FROM #IndexColumns c3
            WHERE c3.index_id NOT IN (0,1))
            ELSE 0 END
                AS [Found In],
        system_type_name + 
            CASE max_length WHEN -1 THEN N' (max)' ELSE
                CASE  
                    WHEN system_type_name IN (N'char',N'nchar',N'binary',N'varbinary') THEN N' (' + CAST(max_length AS NVARCHAR(20)) + N')' 
                    WHEN system_type_name IN (N'varchar',N'nvarchar') THEN N' (' + CAST(max_length/2 AS NVARCHAR(20)) + N')' 
                    ELSE '' 
                END
            END
            AS [Type],
        CASE is_computed WHEN 1 THEN 'yes' ELSE '' END AS [Computed?],
        max_length AS [Length (max bytes)],
        [precision] AS [Prec],
        [scale] AS [Scale],
        CASE is_nullable WHEN 1 THEN 'yes' ELSE '' END AS [Nullable?],
        CASE is_identity WHEN 1 THEN 'yes' ELSE '' END AS [Identity?],
        CASE is_replicated WHEN 1 THEN 'yes' ELSE '' END AS [Replicated?],
        CASE is_sparse WHEN 1 THEN 'yes' ELSE '' END AS [Sparse?],
        CASE is_filestream WHEN 1 THEN 'yes' ELSE '' END AS [Filestream?],
        collation_name AS [Collation]
    FROM #IndexColumns AS c
    WHERE index_id IN (0,1);

    IF (SELECT TOP 1 parent_object_id FROM #ForeignKeys) IS NOT NULL
    BEGIN
        SELECT [database_name] + N':' + parent_object_name + N': ' + foreign_key_name AS [Foreign Key],
            parent_fk_columns AS [Foreign Key Columns],
            referenced_object_name AS [Referenced Table],
            referenced_fk_columns AS [Referenced Table Columns],
            is_disabled AS [Is Disabled?],
            is_not_trusted AS [Not Trusted?],
            is_not_for_replication [Not for Replication?],
            [update_referential_action_desc] AS [Cascading Updates?],
            [delete_referential_action_desc] AS [Cascading Deletes?]
        FROM #ForeignKeys
        ORDER BY [Foreign Key]
        OPTION    ( RECOMPILE );
    END
    ELSE
    SELECT 'No foreign keys.' AS finding;
END 

--If @TableName is NOT specified...
--Act based on the @Mode and @Filter. (@Filter applies only when @Mode=0 "diagnose")
ELSE
BEGIN;
    IF @Mode IN (0, 4) /* DIAGNOSE*/
    BEGIN;
        RAISERROR(N'@Mode=0 or 4, we are diagnosing.', 0,1) WITH NOWAIT;

        ----------------------------------------
        --Multiple Index Personalities: Check_id 0-10
        ----------------------------------------
        BEGIN;

        --SELECT    [object_id], key_column_names, database_id
        --                   FROM        #IndexSanity
        --                   WHERE  index_type IN (1,2) /* Clustered, NC only*/
        --                        AND is_hypothetical = 0
        --                        AND is_disabled = 0
        --                   GROUP BY    [object_id], key_column_names, database_id
        --                   HAVING    COUNT(*) > 1


        RAISERROR('check_id 1: Duplicate keys', 0,1) WITH NOWAIT;
            WITH    duplicate_indexes
                      AS ( SELECT    [object_id], key_column_names, database_id
                           FROM        #IndexSanity
                           WHERE  index_type IN (1,2) /* Clustered, NC only*/
                                AND is_hypothetical = 0
                                AND is_disabled = 0
								AND is_primary_key = 0
                           GROUP BY    [object_id], key_column_names, database_id
                           HAVING    COUNT(*) > 1)
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    1 AS check_id, 
                                ip.index_sanity_id,
                                50 AS Priority,
                                'Multiple Index Personalities' AS findings_group,
                                'Duplicate keys' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/duplicateindex' AS URL,
                                N'Index Name: ' + ip.index_name + N' Table Name: ' + ip.db_schema_object_name AS details,
                                ip.index_definition, 
                                ip.secret_columns, 
                                ip.index_usage_summary,
                                ips.index_size_summary
                        FROM    duplicate_indexes di
                                JOIN #IndexSanity ip ON di.[object_id] = ip.[object_id]
                                                         AND ip.database_id = di.database_id
                                                         AND di.key_column_names = ip.key_column_names
                                JOIN #IndexSanitySize ips ON ip.index_sanity_id = ips.index_sanity_id AND ip.database_id = ips.database_id
                        /* WHERE clause limits to only @ThresholdMB or larger duplicate indexes when getting all databases or using PainRelief mode */
                        WHERE ips.total_reserved_MB >= CASE WHEN (@GetAllDatabases = 1 OR @Mode = 0) THEN @ThresholdMB ELSE ips.total_reserved_MB END
						AND ip.is_primary_key = 0
                        ORDER BY ip.object_id, ip.key_column_names_with_sort_order    
                OPTION    ( RECOMPILE );

        RAISERROR('check_id 2: Keys w/ identical leading columns.', 0,1) WITH NOWAIT;
            WITH    borderline_duplicate_indexes
                      AS ( SELECT DISTINCT [object_id], first_key_column_name, key_column_names,
                                    COUNT([object_id]) OVER ( PARTITION BY [object_id], first_key_column_name ) AS number_dupes
                           FROM        #IndexSanity
                           WHERE index_type IN (1,2) /* Clustered, NC only*/
                            AND is_hypothetical=0
                            AND is_disabled=0
							AND is_primary_key = 0)
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    2 AS check_id, 
                                ip.index_sanity_id,
                                60 AS Priority,
                                'Multiple Index Personalities' AS findings_group,
                                'Borderline duplicate keys' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/duplicateindex' AS URL,
                                ip.db_schema_object_indexid AS details, 
                                ip.index_definition, 
                                ip.secret_columns,
                                ip.index_usage_summary,
                                ips.index_size_summary
                        FROM    #IndexSanity AS ip 
                        JOIN #IndexSanitySize ips ON ip.index_sanity_id = ips.index_sanity_id
                        WHERE EXISTS (
                            SELECT di.[object_id]
                            FROM borderline_duplicate_indexes AS di
                            WHERE di.[object_id] = ip.[object_id] AND
                                di.first_key_column_name = ip.first_key_column_name AND
                                di.key_column_names <> ip.key_column_names AND
                                di.number_dupes > 1    
                        )
						AND ip.is_primary_key = 0
                        /* WHERE clause skips near-duplicate indexes when getting all databases or using PainRelief mode */
                        AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                                                
                        ORDER BY ip.[schema_name], ip.[object_name], ip.key_column_names, ip.include_column_names
            OPTION    ( RECOMPILE );

        END
        ----------------------------------------
        --Aggressive Indexes: Check_id 10-19
        ----------------------------------------
        BEGIN;

        RAISERROR(N'check_id 11: Total lock wait time > 5 minutes (row + page) with long average waits', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                SELECT    11 AS check_id, 
                        i.index_sanity_id,
                        10 AS Priority,
                        N'Aggressive Indexes' AS findings_group,
                        N'Total lock wait time > 5 minutes (row + page) with long average waits' AS finding, 
                        [database_name] AS [Database Name],
                        N'http://BrentOzar.com/go/AggressiveIndexes' AS URL,
                        i.db_schema_object_indexid + N': ' +
                            sz.index_lock_wait_summary AS details, 
                        i.index_definition,
                        i.secret_columns,
                        i.index_usage_summary,
                        sz.index_size_summary
                FROM    #IndexSanity AS i
                JOIN #IndexSanitySize AS sz ON i.index_sanity_id = sz.index_sanity_id
                WHERE    (total_row_lock_wait_in_ms + total_page_lock_wait_in_ms) > 300000
				AND (sz.avg_page_lock_wait_in_ms + sz.avg_row_lock_wait_in_ms) > 5000
                OPTION    ( RECOMPILE );

        RAISERROR(N'check_id 12: Total lock wait time > 5 minutes (row + page) with short average waits', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                SELECT    12 AS check_id, 
                        i.index_sanity_id,
                        10 AS Priority,
                        N'Aggressive Indexes' AS findings_group,
                        N'Total lock wait time > 5 minutes (row + page) with short average waits' AS finding, 
                        [database_name] AS [Database Name],
                        N'http://BrentOzar.com/go/AggressiveIndexes' AS URL,
                        i.db_schema_object_indexid + N': ' +
                            sz.index_lock_wait_summary AS details, 
                        i.index_definition,
                        i.secret_columns,
                        i.index_usage_summary,
                        sz.index_size_summary
                FROM    #IndexSanity AS i
                JOIN #IndexSanitySize AS sz ON i.index_sanity_id = sz.index_sanity_id
                WHERE    (total_row_lock_wait_in_ms + total_page_lock_wait_in_ms) > 300000
				AND (sz.avg_page_lock_wait_in_ms + sz.avg_row_lock_wait_in_ms) < 5000
                OPTION    ( RECOMPILE );

        END

        ---------------------------------------- 
        --Index Hoarder: Check_id 20-29
        ----------------------------------------
        BEGIN
            RAISERROR(N'check_id 20: >=7 NC indexes on any given table. Yes, 7 is an arbitrary number.', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    20 AS check_id, 
                                MAX(i.index_sanity_id) AS index_sanity_id, 
                                100 AS Priority,
                                'Index Hoarder' AS findings_group,
                                'Many NC indexes on a single table' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/IndexHoarder' AS URL,
                                CAST (COUNT(*) AS NVARCHAR(30)) + ' NC indexes on ' + i.db_schema_object_name AS details,
                                i.db_schema_object_name + ' (' + CAST (COUNT(*) AS NVARCHAR(30)) + ' indexes)' AS index_definition,
                                '' AS secret_columns,
                                REPLACE(CONVERT(NVARCHAR(30),CAST(SUM(total_reads) AS MONEY), 1), N'.00', N'') + N' reads (ALL); '
                                    + REPLACE(CONVERT(NVARCHAR(30),CAST(SUM(user_updates) AS MONEY), 1), N'.00', N'') + N' writes (ALL); ',
                                REPLACE(CONVERT(NVARCHAR(30),CAST(MAX(total_rows) AS MONEY), 1), N'.00', N'') + N' rows (MAX)'
                                    + CASE WHEN SUM(total_reserved_MB) > 1024 THEN 
                                        N'; ' + CAST(CAST(SUM(total_reserved_MB)/1024. AS NUMERIC(29,1)) AS NVARCHAR(30)) + 'GB (ALL)'
                                    WHEN SUM(total_reserved_MB) > 0 THEN
                                        N'; ' + CAST(CAST(SUM(total_reserved_MB) AS NUMERIC(29,1)) AS NVARCHAR(30)) + 'MB (ALL)'
                                    ELSE ''
                                    END AS index_size_summary
                        FROM    #IndexSanity i
                        JOIN #IndexSanitySize ip ON i.index_sanity_id = ip.index_sanity_id
                        WHERE    index_id NOT IN ( 0, 1 )
                        AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                        GROUP BY db_schema_object_name, [i].[database_name]
                        HAVING    COUNT(*) >= 7
                        ORDER BY i.db_schema_object_name DESC  OPTION    ( RECOMPILE );

            IF @Filter = 1 /*@Filter=1 is "ignore unusued" */
            BEGIN
                RAISERROR(N'Skipping checks on unused indexes (21 and 22) because @Filter=1', 0,1) WITH NOWAIT;
            END
            ELSE /*Otherwise, go ahead and do the checks*/
            BEGIN
                RAISERROR(N'check_id 21: >=5 percent of indexes are unused. Yes, 5 is an arbitrary number.', 0,1) WITH NOWAIT;
                    DECLARE @percent_NC_indexes_unused NUMERIC(29,1);
                    DECLARE @NC_indexes_unused_reserved_MB NUMERIC(29,1);

                    SELECT    @percent_NC_indexes_unused =( 100.00 * SUM(CASE    WHEN total_reads = 0 THEN 1
                                                ELSE 0
                                           END) ) / COUNT(*) ,
                            @NC_indexes_unused_reserved_MB = SUM(CASE WHEN total_reads = 0 THEN sz.total_reserved_MB
                                     ELSE 0
                                END) 
                    FROM    #IndexSanity i
                    JOIN    #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE    index_id NOT IN ( 0, 1 ) 
                            AND i.is_unique = 0
							/*Skipping tables created in the last week, or modified in past 2 days*/
							AND	i.create_date >= DATEADD(dd,-7,GETDATE()) 
							AND i.modify_date > DATEADD(dd,-2,GETDATE()) 
                    OPTION    ( RECOMPILE );

                IF @percent_NC_indexes_unused >= 5 
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                            SELECT    21 AS check_id, 
                                    MAX(i.index_sanity_id) AS index_sanity_id, 
                                    150 AS Priority,
                                    N'Index Hoarder' AS findings_group,
                                    N'More than 5 percent NC indexes are unused' AS finding,
                                    [database_name] AS [Database Name],
                                    N'http://BrentOzar.com/go/IndexHoarder' AS URL,
                                    CAST (@percent_NC_indexes_unused AS NVARCHAR(30)) + N' percent NC indexes (' + CAST(COUNT(*) AS NVARCHAR(10)) + N') unused. ' +
                                    N'These take up ' + CAST (@NC_indexes_unused_reserved_MB AS NVARCHAR(30)) + N'MB of space.' AS details,
                                    i.database_name + ' (' + CAST (COUNT(*) AS NVARCHAR(30)) + N' indexes)' AS index_definition,
                                    '' AS secret_columns, 
                                    CAST(SUM(total_reads) AS NVARCHAR(256)) + N' reads (ALL); '
                                        + CAST(SUM([user_updates]) AS NVARCHAR(256)) + N' writes (ALL)' AS index_usage_summary,
                                
                                    REPLACE(CONVERT(NVARCHAR(30),CAST(MAX([total_rows]) AS MONEY), 1), '.00', '') + N' rows (MAX)'
                                        + CASE WHEN SUM(total_reserved_MB) > 1024 THEN 
                                            N'; ' + CAST(CAST(SUM(total_reserved_MB)/1024. AS NUMERIC(29,1)) AS NVARCHAR(30)) + 'GB (ALL)'
                                        WHEN SUM(total_reserved_MB) > 0 THEN
                                            N'; ' + CAST(CAST(SUM(total_reserved_MB) AS NUMERIC(29,1)) AS NVARCHAR(30)) + 'MB (ALL)'
                                        ELSE ''
                                        END AS index_size_summary
                            FROM    #IndexSanity i
                            JOIN    #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                            WHERE    index_id NOT IN ( 0, 1 )
                                    AND i.is_unique = 0
                                    AND total_reads = 0
                                    AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
									/*Skipping tables created in the last week, or modified in past 2 days*/
									AND	i.create_date >= DATEADD(dd,-7,GETDATE()) 
									AND i.modify_date > DATEADD(dd,-2,GETDATE())
                            GROUP BY i.database_name 
                    OPTION    ( RECOMPILE );

                RAISERROR(N'check_id 22: NC indexes with 0 reads. (Borderline)', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    22 AS check_id, 
                                i.index_sanity_id,
                                150 AS Priority,
                                N'Index Hoarder' AS findings_group,
                                N'Unused NC index' AS finding, 
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/IndexHoarder' AS URL,
                                N'0 reads: ' + i.db_schema_object_indexid AS details, 
                                i.index_definition, 
                                i.secret_columns, 
                                i.index_usage_summary,
                                sz.index_size_summary
                        FROM    #IndexSanity AS i
                        JOIN    #IndexSanitySize AS sz ON i.index_sanity_id = sz.index_sanity_id
                        WHERE    i.total_reads=0
                                AND i.index_id NOT IN (0,1) /*NCs only*/
                                AND i.is_unique = 0
                                AND sz.total_reserved_MB >= CASE WHEN (@GetAllDatabases = 1 OR @Mode = 0) THEN @ThresholdMB ELSE sz.total_reserved_MB END
                        ORDER BY i.db_schema_object_indexid
                        OPTION    ( RECOMPILE );
            END /*end checks only run when @Filter <> 1*/

            RAISERROR(N'check_id 23: Indexes with 7 or more columns. (Borderline)', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    23 AS check_id, 
                            i.index_sanity_id,
                            150 AS Priority, 
                            N'Index Hoarder' AS findings_group,
                            N'Borderline: Wide indexes (7 or more columns)' AS finding, 
                            [database_name] AS [Database Name],
                            N'http://BrentOzar.com/go/IndexHoarder' AS URL,
                            CAST(count_key_columns + count_included_columns AS NVARCHAR(10)) + ' columns on '
                            + i.db_schema_object_indexid AS details, i.index_definition, 
                            i.secret_columns, 
                            i.index_usage_summary,
                            sz.index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN    #IndexSanitySize AS sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE    ( count_key_columns + count_included_columns ) >= 7
                            AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                    OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 24: Wide clustered indexes (> 3 columns or > 16 bytes).', 0,1) WITH NOWAIT;
                WITH count_columns AS (
                            SELECT [object_id],
                                SUM(CASE max_length WHEN -1 THEN 0 ELSE max_length END) AS sum_max_length
                            FROM #IndexColumns ic
                            WHERE index_id IN (1,0) /*Heap or clustered only*/
                            AND key_ordinal > 0
                            GROUP BY object_id
                            )
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    24 AS check_id, 
                                i.index_sanity_id, 
                                150 AS Priority,
                                N'Index Hoarder' AS findings_group,
                                N'Wide clustered index (> 3 columns OR > 16 bytes)' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/IndexHoarder' AS URL,
                                CAST (i.count_key_columns AS NVARCHAR(10)) + N' columns with potential size of '
                                    + CAST(cc.sum_max_length AS NVARCHAR(10))
                                    + N' bytes in clustered index:' + i.db_schema_object_name 
                                    + N'. ' + 
                                        (SELECT CAST(COUNT(*) AS NVARCHAR(23)) FROM #IndexSanity i2 
                                        WHERE i2.[object_id]=i.[object_id] AND i2.index_id <> 1
                                        AND i2.is_disabled=0 AND i2.is_hypothetical=0)
                                        + N' NC indexes on the table.'
                                    AS details,
                                i.index_definition,
                                secret_columns, 
                                i.index_usage_summary,
                                ip.index_size_summary
                        FROM    #IndexSanity i
                        JOIN    #IndexSanitySize ip ON i.index_sanity_id = ip.index_sanity_id
                        JOIN    count_columns AS cc ON i.[object_id]=cc.[object_id]    
                        WHERE    index_id = 1 /* clustered only */
                                AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                                AND 
                                    (count_key_columns > 3 /*More than three key columns.*/
                                    OR cc.sum_max_length > 16 /*More than 16 bytes in key */)
									AND i.is_CX_columnstore = 0
                        ORDER BY i.db_schema_object_name DESC OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 25: Addicted to nullable columns.', 0,1) WITH NOWAIT;
                WITH count_columns AS (
                            SELECT [object_id],
                                SUM(CASE is_nullable WHEN 1 THEN 0 ELSE 1 END) AS non_nullable_columns,
                                COUNT(*) AS total_columns
                            FROM #IndexColumns ic
                            WHERE index_id IN (1,0) /*Heap or clustered only*/
                            GROUP BY object_id
                            )
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    25 AS check_id, 
                                i.index_sanity_id, 
                                200 AS Priority,
                                N'Index Hoarder' AS findings_group,
                                N'Addicted to nulls' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/IndexHoarder' AS URL,
                                i.db_schema_object_name 
                                    + N' allows null in ' + CAST((total_columns-non_nullable_columns) AS NVARCHAR(10))
                                    + N' of ' + CAST(total_columns AS NVARCHAR(10))
                                    + N' columns.' AS details,
                                i.index_definition,
                                secret_columns, 
                                ISNULL(i.index_usage_summary,''),
                                ISNULL(ip.index_size_summary,'')
                        FROM    #IndexSanity i
                        JOIN    #IndexSanitySize ip ON i.index_sanity_id = ip.index_sanity_id
                        JOIN    count_columns AS cc ON i.[object_id]=cc.[object_id]
                        WHERE    i.index_id IN (1,0)
                        AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                            AND cc.non_nullable_columns < 2
                            AND cc.total_columns > 3
                        ORDER BY i.db_schema_object_name DESC OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 26: Wide tables (35+ cols or > 2000 non-LOB bytes).', 0,1) WITH NOWAIT;
                WITH count_columns AS (
                            SELECT [object_id],
                                SUM(CASE max_length WHEN -1 THEN 1 ELSE 0 END) AS count_lob_columns,
                                SUM(CASE max_length WHEN -1 THEN 0 ELSE max_length END) AS sum_max_length,
                                COUNT(*) AS total_columns
                            FROM #IndexColumns ic
                            WHERE index_id IN (1,0) /*Heap or clustered only*/
                            GROUP BY object_id
                            )
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    26 AS check_id, 
                                i.index_sanity_id, 
                                150 AS Priority,
                                N'Index Hoarder' AS findings_group,
                                N'Wide tables: 35+ cols or > 2000 non-LOB bytes' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/IndexHoarder' AS URL,
                                i.db_schema_object_name 
                                    + N' has ' + CAST((total_columns) AS NVARCHAR(10))
                                    + N' total columns with a max possible width of ' + CAST(sum_max_length AS NVARCHAR(10))
                                    + N' bytes.' +
                                    CASE WHEN count_lob_columns > 0 THEN CAST((count_lob_columns) AS NVARCHAR(10))
                                        + ' columns are LOB types.' ELSE ''
                                    END
                                        AS details,
                                i.index_definition,
                                secret_columns, 
                                ISNULL(i.index_usage_summary,''),
                                ISNULL(ip.index_size_summary,'')
                        FROM    #IndexSanity i
                        JOIN    #IndexSanitySize ip ON i.index_sanity_id = ip.index_sanity_id
                        JOIN    count_columns AS cc ON i.[object_id]=cc.[object_id]
                        WHERE    i.index_id IN (1,0)
                        AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                            AND 
                            (cc.total_columns >= 35 OR
                            cc.sum_max_length >= 2000)
                        ORDER BY i.db_schema_object_name DESC OPTION    ( RECOMPILE );
                    
            RAISERROR(N'check_id 27: Addicted to strings.', 0,1) WITH NOWAIT;
                WITH count_columns AS (
                            SELECT [object_id],
                                SUM(CASE WHEN system_type_name IN ('varchar','nvarchar','char') OR max_length=-1 THEN 1 ELSE 0 END) AS string_or_LOB_columns,
                                COUNT(*) AS total_columns
                            FROM #IndexColumns ic
                            WHERE index_id IN (1,0) /*Heap or clustered only*/
                            GROUP BY object_id
                            )
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    27 AS check_id, 
                                i.index_sanity_id, 
                                200 AS Priority,
                                N'Index Hoarder' AS findings_group,
                                N'Addicted to strings' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/IndexHoarder' AS URL,
                                i.db_schema_object_name 
                                    + N' uses string or LOB types for ' + CAST((string_or_LOB_columns) AS NVARCHAR(10))
                                    + N' of ' + CAST(total_columns AS NVARCHAR(10))
                                    + N' columns. Check if data types are valid.' AS details,
                                i.index_definition,
                                secret_columns, 
                                ISNULL(i.index_usage_summary,''),
                                ISNULL(ip.index_size_summary,'')
                        FROM    #IndexSanity i
                        JOIN    #IndexSanitySize ip ON i.index_sanity_id = ip.index_sanity_id
                        JOIN    count_columns AS cc ON i.[object_id]=cc.[object_id]
                        CROSS APPLY (SELECT cc.total_columns - string_or_LOB_columns AS non_string_or_lob_columns) AS calc1
                        WHERE    i.index_id IN (1,0)
                        AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                            AND calc1.non_string_or_lob_columns <= 1
                            AND cc.total_columns > 3
                        ORDER BY i.db_schema_object_name DESC OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 28: Non-unique clustered index.', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    28 AS check_id, 
                                i.index_sanity_id, 
                                100 AS Priority,
                                N'Index Hoarder' AS findings_group,
                                N'Non-Unique clustered index' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/IndexHoarder' AS URL,
                                N'Uniquifiers will be required! Clustered index: ' + i.db_schema_object_name 
                                    + N' and all NC indexes. ' + 
                                        (SELECT CAST(COUNT(*) AS NVARCHAR(23)) FROM #IndexSanity i2 
                                        WHERE i2.[object_id]=i.[object_id] AND i2.index_id <> 1
                                        AND i2.is_disabled=0 AND i2.is_hypothetical=0)
                                        + N' NC indexes on the table.'
                                    AS details,
                                i.index_definition,
                                secret_columns, 
                                i.index_usage_summary,
                                ip.index_size_summary
                        FROM    #IndexSanity i
                        JOIN    #IndexSanitySize ip ON i.index_sanity_id = ip.index_sanity_id
                        WHERE    index_id = 1 /* clustered only */
                        AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                                AND is_unique=0 /* not unique */
                                AND is_CX_columnstore=0 /* not a clustered columnstore-- no unique option on those */
                        ORDER BY i.db_schema_object_name DESC OPTION    ( RECOMPILE )



        END
         ----------------------------------------
        --Feature-Phobic Indexes: Check_id 30-39
        ---------------------------------------- 
        BEGIN
            RAISERROR(N'check_id 30: No indexes with includes', 0,1) WITH NOWAIT;

            DECLARE    @number_indexes_with_includes INT;
            DECLARE    @percent_indexes_with_includes NUMERIC(10, 1);

            SELECT    @number_indexes_with_includes = SUM(CASE WHEN count_included_columns > 0 THEN 1 ELSE 0    END),
                    @percent_indexes_with_includes = 100.* 
                        SUM(CASE WHEN count_included_columns > 0 THEN 1 ELSE 0 END) / ( 1.0 * COUNT(*) )
            FROM    #IndexSanity;

            IF @number_indexes_with_includes = 0 AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    30 AS check_id, 
                                NULL AS index_sanity_id, 
                                250 AS Priority,
                                N'Feature-Phobic Indexes' AS findings_group,
                                N'No indexes use includes' AS finding, 'http://BrentOzar.com/go/IndexFeatures' AS URL,
                                N'No indexes use includes' AS details,
                                @DatabaseName + N' (Entire database)' AS index_definition, 
                                N'' AS secret_columns, 
                                N'N/A' AS index_usage_summary, 
                                N'N/A' AS index_size_summary OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 31: < 3 percent of indexes have includes', 0,1) WITH NOWAIT;
            IF @percent_indexes_with_includes <= 3 AND @number_indexes_with_includes > 0 AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    31 AS check_id,
                                NULL AS index_sanity_id, 
                                150 AS Priority,
                                N'Feature-Phobic Indexes' AS findings_group,
                                N'Borderline: Includes are used in < 3% of indexes' AS findings,
                                @DatabaseName AS [Database Name],
                                N'http://BrentOzar.com/go/IndexFeatures' AS URL,
                                N'Only ' + CAST(@percent_indexes_with_includes AS NVARCHAR(10)) + '% of indexes have includes' AS details, 
                                N'Entire database' AS index_definition, 
                                N'' AS secret_columns,
                                N'N/A' AS index_usage_summary, 
                                N'N/A' AS index_size_summary OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 32: filtered indexes and indexed views', 0,1) WITH NOWAIT;
            DECLARE @count_filtered_indexes INT;
            DECLARE @count_indexed_views INT;

                SELECT    @count_filtered_indexes=COUNT(*)
                FROM    #IndexSanity
                WHERE    filter_definition <> '' OPTION    ( RECOMPILE );

                SELECT    @count_indexed_views=COUNT(*)
                FROM    #IndexSanity AS i
                        JOIN #IndexSanitySize AS sz ON i.index_sanity_id = sz.index_sanity_id
                WHERE    is_indexed_view = 1 OPTION    ( RECOMPILE );

            IF @count_filtered_indexes = 0 AND @count_indexed_views=0 AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    32 AS check_id, 
                                NULL AS index_sanity_id,
                                250 AS Priority,
                                N'Feature-Phobic Indexes' AS findings_group,
                                N'Borderline: No filtered indexes or indexed views exist' AS finding, 
                                @DatabaseName AS [Database Name],
                                N'http://BrentOzar.com/go/IndexFeatures' AS URL,
                                N'These are NOT always needed-- but do you know when you would use them?' AS details,
                                @DatabaseName + N' (Entire database)' AS index_definition, 
                                N'' AS secret_columns,
                                N'N/A' AS index_usage_summary, 
                                N'N/A' AS index_size_summary OPTION    ( RECOMPILE );
        END;

        RAISERROR(N'check_id 33: Potential filtered indexes based on column names.', 0,1) WITH NOWAIT;

                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
        SELECT    33 AS check_id, 
                i.index_sanity_id AS index_sanity_id,
                250 AS Priority,
                N'Feature-Phobic Indexes' AS findings_group,
                N'Potential filtered index (based on column name)' AS finding, 
                [database_name] AS [Database Name],
                N'http://BrentOzar.com/go/IndexFeatures' AS URL,
                N'A column name in this index suggests it might be a candidate for filtering (is%, %archive%, %active%, %flag%)' AS details,
                i.index_definition, 
                i.secret_columns,
                i.index_usage_summary, 
                sz.index_size_summary
        FROM #IndexColumns ic 
        JOIN #IndexSanity i ON 
            ic.[object_id]=i.[object_id] AND
            ic.[index_id]=i.[index_id] AND
            i.[index_id] > 1 /* non-clustered index */
        JOIN    #IndexSanitySize AS sz ON i.index_sanity_id = sz.index_sanity_id
        WHERE (column_name LIKE 'is%'
            OR column_name LIKE '%archive%'
            OR column_name LIKE '%active%'
            OR column_name LIKE '%flag%')
            AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
        OPTION    ( RECOMPILE );
        
         ----------------------------------------
        --Self Loathing Indexes : Check_id 40-49
        ----------------------------------------
        BEGIN
        
            RAISERROR(N'check_id 40: Fillfactor in nonclustered 80 percent or less', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    40 AS check_id, 
                            i.index_sanity_id,
                            100 AS Priority,
                            N'Self Loathing Indexes' AS findings_group,
                            N'Low Fill Factor: nonclustered index' AS finding, 
                            [database_name] AS [Database Name],
                            N'http://BrentOzar.com/go/SelfLoathing' AS URL,
                            CAST(fill_factor AS NVARCHAR(10)) + N'% fill factor on ' + db_schema_object_indexid + N'. '+
                                CASE WHEN (last_user_update IS NULL OR user_updates < 1)
                                THEN N'No writes have been made.'
                                ELSE
                                    N'Last write was ' +  CONVERT(NVARCHAR(16),last_user_update,121) + N' and ' + 
                                    CAST(user_updates AS NVARCHAR(25)) + N' updates have been made.'
                                END
                                AS details, 
                            i.index_definition,
                            i.secret_columns,
                            i.index_usage_summary,
                            sz.index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN    #IndexSanitySize AS sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE    index_id > 1
                    AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                    AND    fill_factor BETWEEN 1 AND 80 OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 40: Fillfactor in clustered 80 percent or less', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    40 AS check_id, 
                            i.index_sanity_id,
                            100 AS Priority,
                            N'Self Loathing Indexes' AS findings_group,
                            N'Low Fill Factor: clustered index' AS finding, 
                            [database_name] AS [Database Name],
                            N'http://BrentOzar.com/go/SelfLoathing' AS URL,
                            N'Fill factor on ' + db_schema_object_indexid + N' is ' + CAST(fill_factor AS NVARCHAR(10)) + N'%. '+
                                CASE WHEN (last_user_update IS NULL OR user_updates < 1)
                                THEN N'No writes have been made.'
                                ELSE
                                    N'Last write was ' +  CONVERT(NVARCHAR(16),last_user_update,121) + N' and ' + 
                                    CAST(user_updates AS NVARCHAR(25)) + N' updates have been made.'
                                END
                                AS details, 
                            i.index_definition,
                            i.secret_columns,
                            i.index_usage_summary,
                            sz.index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN #IndexSanitySize AS sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE    index_id = 1
                    AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                    AND fill_factor BETWEEN 1 AND 80 OPTION    ( RECOMPILE );


            RAISERROR(N'check_id 41: Hypothetical indexes ', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    41 AS check_id, 
                            i.index_sanity_id,
                            150 AS Priority,
                            N'Self Loathing Indexes' AS findings_group,
                            N'Hypothetical Index' AS finding,
                            [database_name] AS [Database Name],
                            N'http://BrentOzar.com/go/SelfLoathing' AS URL,
                            N'Hypothetical Index: ' + db_schema_object_indexid AS details, 
                            i.index_definition,
                            i.secret_columns,
                            N'' AS index_usage_summary, 
                            N'' AS index_size_summary
                    FROM    #IndexSanity AS i
                    WHERE    is_hypothetical = 1 
                    AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                    OPTION    ( RECOMPILE );


            RAISERROR(N'check_id 42: Disabled indexes', 0,1) WITH NOWAIT;
            --Note: disabled NC indexes will have O rows in #IndexSanitySize!
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    42 AS check_id, 
                            index_sanity_id,
                            150 AS Priority,
                            N'Self Loathing Indexes' AS findings_group,
                            N'Disabled Index' AS finding, 
                            [database_name] AS [Database Name],
                            N'http://BrentOzar.com/go/SelfLoathing' AS URL,
                            N'Disabled Index:' + db_schema_object_indexid AS details, 
                            i.index_definition,
                            i.secret_columns,
                            i.index_usage_summary,
                            'DISABLED' AS index_size_summary
                    FROM    #IndexSanity AS i
                    WHERE    is_disabled = 1
                    AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                    OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 43: Heaps with forwarded records or deletes', 0,1) WITH NOWAIT;
            WITH    heaps_cte
                      AS ( SELECT    [object_id], 
                                    SUM(forwarded_fetch_count) AS forwarded_fetch_count,
                                    SUM(leaf_delete_count) AS leaf_delete_count
                           FROM        #IndexPartitionSanity
                           GROUP BY    [object_id]
                           HAVING    SUM(forwarded_fetch_count) > 0
                                    OR SUM(leaf_delete_count) > 0)
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    43 AS check_id, 
                                i.index_sanity_id,
                                100 AS Priority,
                                N'Self Loathing Indexes' AS findings_group,
                                N'Heaps with forwarded records or deletes' AS finding, 
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/SelfLoathing' AS URL,
                                CAST(h.forwarded_fetch_count AS NVARCHAR(256)) + ' forwarded fetches, '
                                + CAST(h.leaf_delete_count AS NVARCHAR(256)) + ' deletes against heap:'
                                + db_schema_object_indexid AS details, 
                                i.index_definition, 
                                i.secret_columns,
                                i.index_usage_summary,
                                sz.index_size_summary
                        FROM    #IndexSanity i
                        JOIN heaps_cte h ON i.[object_id] = h.[object_id]
                        JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                        WHERE    i.index_id = 0 
                        AND sz.total_reserved_MB >= CASE WHEN NOT (@GetAllDatabases = 1 OR @Mode = 4) THEN @ThresholdMB ELSE sz.total_reserved_MB END
                OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 44: Large Heaps with reads or writes.', 0,1) WITH NOWAIT;
            WITH    heaps_cte
                      AS ( SELECT    [object_id], SUM(forwarded_fetch_count) AS forwarded_fetch_count,
                                    SUM(leaf_delete_count) AS leaf_delete_count
                           FROM        #IndexPartitionSanity
                           GROUP BY    [object_id]
                           HAVING    SUM(forwarded_fetch_count) > 0
                                    OR SUM(leaf_delete_count) > 0)
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    44 AS check_id, 
                                i.index_sanity_id,
                                100 AS Priority,
                                N'Self Loathing Indexes' AS findings_group,
                                N'Large Active heap' AS finding, 
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/SelfLoathing' AS URL,
                                N'Should this table be a heap? ' + db_schema_object_indexid AS details, 
                                i.index_definition, 
                                'N/A' AS secret_columns,
                                i.index_usage_summary,
                                sz.index_size_summary
                        FROM    #IndexSanity i
                        LEFT JOIN heaps_cte h ON i.[object_id] = h.[object_id]
                        JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                        WHERE    i.index_id = 0 
                                AND 
                                    (i.total_reads > 0 OR i.user_updates > 0)
								AND sz.total_rows >= 100000
                                AND h.[object_id] IS NULL /*don't duplicate the prior check.*/
                                AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 45: Medium Heaps with reads or writes.', 0,1) WITH NOWAIT;
            WITH    heaps_cte
                      AS ( SELECT    [object_id], SUM(forwarded_fetch_count) AS forwarded_fetch_count,
                                    SUM(leaf_delete_count) AS leaf_delete_count
                           FROM        #IndexPartitionSanity
                           GROUP BY    [object_id]
                           HAVING    SUM(forwarded_fetch_count) > 0
                                    OR SUM(leaf_delete_count) > 0)
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    45 AS check_id, 
                                i.index_sanity_id,
                                100 AS Priority,
                                N'Self Loathing Indexes' AS findings_group,
                                N'Medium Active heap' AS finding, 
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/SelfLoathing' AS URL,
                                N'Should this table be a heap? ' + db_schema_object_indexid AS details, 
                                i.index_definition, 
                                'N/A' AS secret_columns,
                                i.index_usage_summary,
                                sz.index_size_summary
                        FROM    #IndexSanity i
                        LEFT JOIN heaps_cte h ON i.[object_id] = h.[object_id]
                        JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                        WHERE    i.index_id = 0 
                                AND 
                                    (i.total_reads > 0 OR i.user_updates > 0)
								AND sz.total_rows >= 10000 AND sz.total_rows < 100000
                                AND h.[object_id] IS NULL /*don't duplicate the prior check.*/
                                AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 46: Small Heaps with reads or writes.', 0,1) WITH NOWAIT;
            WITH    heaps_cte
                      AS ( SELECT    [object_id], SUM(forwarded_fetch_count) AS forwarded_fetch_count,
                                    SUM(leaf_delete_count) AS leaf_delete_count
                           FROM        #IndexPartitionSanity
                           GROUP BY    [object_id]
                           HAVING    SUM(forwarded_fetch_count) > 0
                                    OR SUM(leaf_delete_count) > 0)
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    46 AS check_id, 
                                i.index_sanity_id,
                                100 AS Priority,
                                N'Self Loathing Indexes' AS findings_group,
                                N'Small Active heap' AS finding, 
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/SelfLoathing' AS URL,
                                N'Should this table be a heap? ' + db_schema_object_indexid AS details, 
                                i.index_definition, 
                                'N/A' AS secret_columns,
                                i.index_usage_summary,
                                sz.index_size_summary
                        FROM    #IndexSanity i
                        LEFT JOIN heaps_cte h ON i.[object_id] = h.[object_id]
                        JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                        WHERE    i.index_id = 0 
                                AND 
                                    (i.total_reads > 0 OR i.user_updates > 0)
								AND sz.total_rows < 10000
                                AND h.[object_id] IS NULL /*don't duplicate the prior check.*/
                                AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                OPTION    ( RECOMPILE );

				            RAISERROR(N'check_id 47: Heap with a Nonclustered Primary Key', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT  47 AS check_id, 
                                i.index_sanity_id,
                                100 AS Priority,
                                N'Self Loathing Indexes' AS findings_group,
                                N'Heap with a Nonclustered Primary Key' AS finding, 
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/SelfLoathing' AS URL,
								db_schema_object_indexid + N' is a HEAP with a Nonclustered Primary Key' AS details, 
                                i.index_definition, 
                                i.secret_columns,
                                i.index_usage_summary,
                                sz.index_size_summary
                        FROM    #IndexSanity i
                        JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                        WHERE    i.index_type = 2 AND i.is_primary_key = 1 AND i.secret_columns LIKE '%RID%'
                OPTION    ( RECOMPILE );

            END;
        ----------------------------------------
        --Indexaphobia
        --Missing indexes with value >= 5 million: : Check_id 50-59
        ----------------------------------------
        BEGIN
            RAISERROR(N'check_id 50: Indexaphobia.', 0,1) WITH NOWAIT;
            WITH    index_size_cte
                      AS ( SELECT   i.database_id,
									i.[object_id], 
                                    MAX(i.index_sanity_id) AS index_sanity_id,
                                ISNULL (
                                    CAST(SUM(CASE WHEN index_id NOT IN (0,1) THEN 1 ELSE 0 END)
                                         AS NVARCHAR(30))+ N' NC indexes exist (' + 
                                    CASE WHEN SUM(CASE WHEN index_id NOT IN (0,1) THEN sz.total_reserved_MB ELSE 0 END) > 1024
                                        THEN CAST(CAST(SUM(CASE WHEN index_id NOT IN (0,1) THEN sz.total_reserved_MB ELSE 0 END )/1024. 

                                            AS NUMERIC(29,1)) AS NVARCHAR(30)) + N'GB); ' 
                                        ELSE CAST(SUM(CASE WHEN index_id NOT IN (0,1) THEN sz.total_reserved_MB ELSE 0 END) 
                                            AS NVARCHAR(30)) + N'MB); '
                                    END + 
                                        CASE WHEN MAX(sz.[total_rows]) >= 922337203685477 THEN '>= 922,337,203,685,477'
                                        ELSE REPLACE(CONVERT(NVARCHAR(30),CAST(MAX(sz.[total_rows]) AS MONEY), 1), '.00', '') 
                                        END +
                                    + N' Estimated Rows;' 
                                ,N'') AS index_size_summary
                            FROM    #IndexSanity AS i
                            LEFT    JOIN #IndexSanitySize AS sz ON i.index_sanity_id = sz.index_sanity_id  AND i.database_id = sz.database_id
							WHERE i.is_hypothetical = 0
                                  AND i.is_disabled = 0
                           GROUP BY    i.database_id, i.[object_id])
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               index_usage_summary, index_size_summary, create_tsql, more_info )
                        
                        SELECT check_id, t.index_sanity_id, t.check_id, t.findings_group, t.finding, t.[Database Name], t.URL, t.details, t.[definition],
                                index_estimated_impact, t.index_size_summary, create_tsql, more_info
                        FROM
                        (
                            SELECT  ROW_NUMBER() OVER (ORDER BY magic_benefit_number DESC) AS rownum,
                                50 AS check_id, 
                                sz.index_sanity_id,
                                10 AS Priority,
                                N'Indexaphobia' AS findings_group,
                                N'High value missing index' AS finding, 
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/Indexaphobia' AS URL,
                                mi.[statement] + 
                                N' Est. benefit per day: ' + 
                                    CASE WHEN magic_benefit_number >= 922337203685477 THEN '>= 922,337,203,685,477'
                                    ELSE REPLACE(CONVERT(NVARCHAR(256),CAST(CAST(
                                    (magic_benefit_number/@DaysUptime)
                                     AS BIGINT) AS MONEY), 1), '.00', '') 
                                    END AS details,
                                missing_index_details AS [definition],
                                index_estimated_impact,
                                sz.index_size_summary,
                                mi.create_tsql,
                                mi.more_info,
                                magic_benefit_number
                        FROM    #MissingIndexes mi
                                LEFT JOIN index_size_cte sz ON mi.[object_id] = sz.object_id AND DB_ID(mi.database_name) = sz.database_id
                                        /* Minimum benefit threshold = 100k/day of uptime */
                        WHERE ( @Mode = 4 AND (magic_benefit_number/@DaysUptime) >= 100000 ) OR (magic_benefit_number/@DaysUptime) >= 100000
                        ) AS t
                        WHERE t.rownum <= CASE WHEN (@Mode <> 4) THEN 20 ELSE t.rownum END
                        ORDER BY magic_benefit_number DESC


    END
         ----------------------------------------
        --Abnormal Psychology : Check_id 60-79
        ----------------------------------------
    BEGIN
            RAISERROR(N'check_id 60: XML indexes', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    60 AS check_id, 
                            i.index_sanity_id,
                            150 AS Priority,
                            N'Abnormal Psychology' AS findings_group,
                            N'XML Indexes' AS finding, 
                            [database_name] AS [Database Name],
                            N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                            i.db_schema_object_indexid AS details, 
                            i.index_definition,
                            i.secret_columns,
                            N'' AS index_usage_summary,
                            ISNULL(sz.index_size_summary,'') AS index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE i.is_XML = 1 OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 61: Columnstore indexes', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    61 AS check_id, 
                            i.index_sanity_id,
                            150 AS Priority,
                            N'Abnormal Psychology' AS findings_group,
                            CASE WHEN i.is_NC_columnstore=1
                                THEN N'NC Columnstore Index' 
                                ELSE N'Clustered Columnstore Index' 
                                END AS finding, 
                            [database_name] AS [Database Name],
                            N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                            i.db_schema_object_indexid AS details, 
                            i.index_definition,
                            i.secret_columns,
                            i.index_usage_summary,
                            ISNULL(sz.index_size_summary,'') AS index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE i.is_NC_columnstore = 1 OR i.is_CX_columnstore=1
                    OPTION    ( RECOMPILE );


            RAISERROR(N'check_id 62: Spatial indexes', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    62 AS check_id, 
                            i.index_sanity_id,
                            150 AS Priority,
                            N'Abnormal Psychology' AS findings_group,
                            N'Spatial indexes' AS finding,
                            [database_name] AS [Database Name], 
                            N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                            i.db_schema_object_indexid AS details, 
                            i.index_definition,
                            i.secret_columns,
                            i.index_usage_summary,
                            ISNULL(sz.index_size_summary,'') AS index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE i.is_spatial = 1 OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 63: Compressed indexes', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    63 AS check_id, 
                            i.index_sanity_id,
                            150 AS Priority,
                            N'Abnormal Psychology' AS findings_group,
                            N'Compressed indexes' AS finding,
                            [database_name] AS [Database Name], 
                            N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                            i.db_schema_object_indexid  + N'. COMPRESSION: ' + sz.data_compression_desc AS details, 
                            i.index_definition,
                            i.secret_columns,
                            i.index_usage_summary,
                            ISNULL(sz.index_size_summary,'') AS index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE sz.data_compression_desc LIKE '%PAGE%' OR sz.data_compression_desc LIKE '%ROW%' OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 64: Partitioned', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    64 AS check_id, 
                            i.index_sanity_id,
                            150 AS Priority,
                            N'Abnormal Psychology' AS findings_group,
                            N'Partitioned indexes' AS finding,
                            [database_name] AS [Database Name], 
                            N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                            i.db_schema_object_indexid AS details, 
                            i.index_definition,
                            i.secret_columns,
                            i.index_usage_summary,
                            ISNULL(sz.index_size_summary,'') AS index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE i.partition_key_column_name IS NOT NULL OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 65: Non-Aligned Partitioned', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    65 AS check_id, 
                            i.index_sanity_id,
                            150 AS Priority,
                            N'Abnormal Psychology' AS findings_group,
                            N'Non-Aligned index on a partitioned table' AS finding,
                            i.[database_name] AS [Database Name], 
                            N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                            i.db_schema_object_indexid AS details, 
                            i.index_definition,
                            i.secret_columns,
                            i.index_usage_summary,
                            ISNULL(sz.index_size_summary,'') AS index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN #IndexSanity AS iParent ON
                        i.[object_id]=iParent.[object_id]
                        AND iParent.index_id IN (0,1) /* could be a partitioned heap or clustered table */
                        AND iParent.partition_key_column_name IS NOT NULL /* parent is partitioned*/         
                    JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE i.partition_key_column_name IS NULL 
                        OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 66: Recently created tables/indexes (1 week)', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    66 AS check_id, 
                            i.index_sanity_id,
                            200 AS Priority,
                            N'Abnormal Psychology' AS findings_group,
                            N'Recently created tables/indexes (1 week)' AS finding,
                            [database_name] AS [Database Name], 
                            N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                            i.db_schema_object_indexid + N' was created on ' + 
                                CONVERT(NVARCHAR(16),i.create_date,121) + 
                                N'. Tables/indexes which are dropped/created regularly require special methods for index tuning.'
                                     AS details, 
                            i.index_definition,
                            i.secret_columns,
                            i.index_usage_summary,
                            ISNULL(sz.index_size_summary,'') AS index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE i.create_date >= DATEADD(dd,-7,GETDATE()) 
                    AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                        OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 67: Recently modified tables/indexes (2 days)', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    67 AS check_id, 
                            i.index_sanity_id,
                            200 AS Priority,
                            N'Abnormal Psychology' AS findings_group,
                            N'Recently modified tables/indexes (2 days)' AS finding,
                            [database_name] AS [Database Name], 
                            N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                            i.db_schema_object_indexid + N' was modified on ' + 
                                CONVERT(NVARCHAR(16),i.modify_date,121) + 
                                N'. A large amount of recently modified indexes may mean a lot of rebuilds are occurring each night.'
                                     AS details, 
                            i.index_definition,
                            i.secret_columns,
                            i.index_usage_summary,
                            ISNULL(sz.index_size_summary,'') AS index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE i.modify_date > DATEADD(dd,-2,GETDATE()) 
                    AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                    AND /*Exclude recently created tables.*/
                    i.create_date < DATEADD(dd,-7,GETDATE()) 
                        OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 68: Identity columns within 30 percent of the end of range', 0,1) WITH NOWAIT;
            -- Allowed Ranges: 
                --int -2,147,483,648 to 2,147,483,647
                --smallint -32,768 to 32,768
                --tinyint 0 to 255

                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    68 AS check_id, 
                                i.index_sanity_id, 
                                200 AS Priority,
                                N'Abnormal Psychology' AS findings_group,
                                N'Identity column within ' +                                     
                                    CAST (calc1.percent_remaining AS NVARCHAR(256))
                                    + N' percent  end of range' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                                i.db_schema_object_name + N'.' +  QUOTENAME(ic.column_name)
                                    + N' is an identity with type ' + ic.system_type_name 
                                    + N', last value of ' 
                                        + ISNULL(REPLACE(CONVERT(NVARCHAR(256),CAST(CAST(ic.last_value AS BIGINT) AS MONEY), 1), '.00', ''),N'NULL')
                                    + N', seed of '
                                        + ISNULL(REPLACE(CONVERT(NVARCHAR(256),CAST(CAST(ic.seed_value AS BIGINT) AS MONEY), 1), '.00', ''),N'NULL')
                                    + N', increment of ' + CAST(ic.increment_value AS NVARCHAR(256)) 
                                    + N', and range of ' +
                                        CASE ic.system_type_name WHEN 'int' THEN N'+/- 2,147,483,647'
                                            WHEN 'smallint' THEN N'+/- 32,768'
                                            WHEN 'tinyint' THEN N'0 to 255'
                                        END
                                        AS details,
                                i.index_definition,
                                secret_columns, 
                                ISNULL(i.index_usage_summary,''),
                                ISNULL(ip.index_size_summary,'')
                        FROM    #IndexSanity i
                        JOIN    #IndexColumns ic ON
                            i.object_id=ic.object_id
                            AND i.index_id IN (0,1) /* heaps and cx only */
                            AND ic.is_identity=1
                            AND ic.system_type_name IN ('tinyint', 'smallint', 'int')
                        JOIN    #IndexSanitySize ip ON i.index_sanity_id = ip.index_sanity_id
                        CROSS APPLY (
                            SELECT CAST(CASE WHEN ic.increment_value >= 0
                                    THEN
                                        CASE ic.system_type_name 
                                            WHEN 'int' THEN (2147483647 - (ISNULL(ic.last_value,ic.seed_value) + ic.increment_value)) / 2147483647.*100
                                            WHEN 'smallint' THEN (32768 - (ISNULL(ic.last_value,ic.seed_value) + ic.increment_value)) / 32768.*100
                                            WHEN 'tinyint' THEN ( 255 - (ISNULL(ic.last_value,ic.seed_value) + ic.increment_value)) / 255.*100
                                            ELSE 999
                                        END
                                ELSE --ic.increment_value is negative
                                        CASE ic.system_type_name 
                                            WHEN 'int' THEN ABS(-2147483647 - (ISNULL(ic.last_value,ic.seed_value) + ic.increment_value)) / 2147483647.*100
                                            WHEN 'smallint' THEN ABS(-32768 - (ISNULL(ic.last_value,ic.seed_value) + ic.increment_value)) / 32768.*100
                                            WHEN 'tinyint' THEN ABS( 0 - (ISNULL(ic.last_value,ic.seed_value) + ic.increment_value)) / 255.*100
                                            ELSE -1
                                        END 
                                END AS NUMERIC(5,1)) AS percent_remaining
                                ) AS calc1
                        WHERE    i.index_id IN (1,0)
                            AND calc1.percent_remaining <= 30
                        UNION ALL
                        SELECT    68 AS check_id, 
                                i.index_sanity_id, 
                                200 AS Priority,
                                N'Abnormal Psychology' AS findings_group,
                                N'Identity column using a negative seed or increment other than 1' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                                i.db_schema_object_name + N'.' +  QUOTENAME(ic.column_name)
                                    + N' is an identity with type ' + ic.system_type_name 
                                    + N', last value of ' 
                                        + ISNULL(REPLACE(CONVERT(NVARCHAR(256),CAST(CAST(ic.last_value AS BIGINT) AS MONEY), 1), '.00', ''),N'NULL')
                                    + N', seed of '
                                        + ISNULL(REPLACE(CONVERT(NVARCHAR(256),CAST(CAST(ic.seed_value AS BIGINT) AS MONEY), 1), '.00', ''),N'NULL')
                                    + N', increment of ' + CAST(ic.increment_value AS NVARCHAR(256)) 
                                    + N', and range of ' +
                                        CASE ic.system_type_name WHEN 'int' THEN N'+/- 2,147,483,647'
                                            WHEN 'smallint' THEN N'+/- 32,768'
                                            WHEN 'tinyint' THEN N'0 to 255'
                                        END
                                        AS details,
                                i.index_definition,
                                secret_columns, 
                                ISNULL(i.index_usage_summary,''),
                                ISNULL(ip.index_size_summary,'')
                        FROM    #IndexSanity i
                        JOIN    #IndexColumns ic ON
                            i.object_id=ic.object_id
                            AND i.index_id IN (0,1) /* heaps and cx only */
                            AND ic.is_identity=1
                            AND ic.system_type_name IN ('tinyint', 'smallint', 'int')
                        JOIN    #IndexSanitySize ip ON i.index_sanity_id = ip.index_sanity_id
                        WHERE    i.index_id IN (1,0)
                            AND (ic.seed_value < 0 OR ic.increment_value <> 1)
                        ORDER BY finding, details DESC OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 69: Column collation does not match database collation', 0,1) WITH NOWAIT;
                WITH count_columns AS (
                            SELECT [object_id],
                                COUNT(*) AS column_count
                            FROM #IndexColumns ic
                            WHERE index_id IN (1,0) /*Heap or clustered only*/
                                AND collation_name <> @collation
                            GROUP BY object_id
                            )
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    69 AS check_id, 
                                i.index_sanity_id, 
                                150 AS Priority,
                                N'Abnormal Psychology' AS findings_group,
                                N'Column collation does not match database collation' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                                i.db_schema_object_name 
                                    + N' has ' + CAST(column_count AS NVARCHAR(20))
                                    + N' column' + CASE WHEN column_count > 1 THEN 's' ELSE '' END
                                    + N' with a different collation than the db collation of '
                                    + @collation    AS details,
                                i.index_definition,
                                secret_columns, 
                                ISNULL(i.index_usage_summary,''),
                                ISNULL(ip.index_size_summary,'')
                        FROM    #IndexSanity i
                        JOIN    #IndexSanitySize ip ON i.index_sanity_id = ip.index_sanity_id
                        JOIN    count_columns AS cc ON i.[object_id]=cc.[object_id]
                        WHERE    i.index_id IN (1,0)
                        AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                        ORDER BY i.db_schema_object_name DESC OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 70: Replicated columns', 0,1) WITH NOWAIT;
                WITH count_columns AS (
                            SELECT [object_id],
                                COUNT(*) AS column_count,
                                SUM(CASE is_replicated WHEN 1 THEN 1 ELSE 0 END) AS replicated_column_count
                            FROM #IndexColumns ic
                            WHERE index_id IN (1,0) /*Heap or clustered only*/
                            GROUP BY object_id
                            )
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                        SELECT    70 AS check_id, 
                                i.index_sanity_id,
                                200 AS Priority, 
                                N'Abnormal Psychology' AS findings_group,
                                N'Replicated columns' AS finding,
                                [database_name] AS [Database Name],
                                N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                                i.db_schema_object_name 
                                    + N' has ' + CAST(replicated_column_count AS NVARCHAR(20))
                                    + N' out of ' + CAST(column_count AS NVARCHAR(20))
                                    + N' column' + CASE WHEN column_count > 1 THEN 's' ELSE '' END
                                    + N' in one or more publications.'
                                        AS details,
                                i.index_definition,
                                secret_columns, 
                                ISNULL(i.index_usage_summary,''),
                                ISNULL(ip.index_size_summary,'')
                        FROM    #IndexSanity i
                        JOIN    #IndexSanitySize ip ON i.index_sanity_id = ip.index_sanity_id
                        JOIN    count_columns AS cc ON i.[object_id]=cc.[object_id]
                        WHERE    i.index_id IN (1,0)
                            AND replicated_column_count > 0
                            AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
                        ORDER BY i.db_schema_object_name DESC OPTION    ( RECOMPILE );

            RAISERROR(N'check_id 71: Cascading updates or cascading deletes.', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary, more_info )
            SELECT    71 AS check_id, 
                    NULL AS index_sanity_id,
                    150 AS Priority,
                    N'Abnormal Psychology' AS findings_group,
                    N'Cascading Updates or Deletes' AS finding, 
                    [database_name] AS [Database Name],
                    N'http://BrentOzar.com/go/AbnormalPsychology' AS URL,
                    N'Foreign Key ' + foreign_key_name +
                    N' on ' + QUOTENAME(parent_object_name)  + N'(' + LTRIM(parent_fk_columns) + N')'
                        + N' referencing ' + QUOTENAME(referenced_object_name) + N'(' + LTRIM(referenced_fk_columns) + N')'
                        + N' has settings:'
                        + CASE [delete_referential_action_desc] WHEN N'NO_ACTION' THEN N'' ELSE N' ON DELETE ' +[delete_referential_action_desc] END
                        + CASE [update_referential_action_desc] WHEN N'NO_ACTION' THEN N'' ELSE N' ON UPDATE ' + [update_referential_action_desc] END
                            AS details, 
                    [fk].[database_name] 
                            AS index_definition, 
                    N'N/A' AS secret_columns,
                    N'N/A' AS index_usage_summary,
                    N'N/A' AS index_size_summary,
                    (SELECT TOP 1 more_info FROM #IndexSanity i WHERE i.object_id=fk.parent_object_id)
                        AS more_info
            FROM #ForeignKeys fk
            WHERE ([delete_referential_action_desc] <> N'NO_ACTION'
            OR [update_referential_action_desc] <> N'NO_ACTION')
            AND NOT (@GetAllDatabases = 1 OR @Mode = 0)

			RAISERROR(N'check_id 72: Columnstore indexes with Trace Flag 834', 0,1) WITH NOWAIT;
                IF EXISTS (SELECT * FROM #IndexSanity WHERE index_type IN (5,6))
				AND EXISTS (SELECT * FROM #TraceStatus WHERE TraceFlag = 834 AND status = 1)
				BEGIN
				INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
                    SELECT    72 AS check_id, 
                            i.index_sanity_id,
                            150 AS Priority,
                            N'Abnormal Psychology' AS findings_group,
                            'Columnstore Indexes are being used in conjunction with trace flag 834. Visit the link to see why this can be a bad idea' AS finding, 
                            [database_name] AS [Database Name],
                            N'https://support.microsoft.com/en-us/kb/3210239' AS URL,
                            i.db_schema_object_indexid AS details, 
                            i.index_definition,
                            i.secret_columns,
                            i.index_usage_summary,
                            ISNULL(sz.index_size_summary,'') AS index_size_summary
                    FROM    #IndexSanity AS i
                    JOIN #IndexSanitySize sz ON i.index_sanity_id = sz.index_sanity_id
                    WHERE i.index_type IN (5,6)
                    OPTION    ( RECOMPILE )
				END

    END

         ----------------------------------------
        --Workaholics: Check_id 80-89
        ----------------------------------------
    BEGIN

        RAISERROR(N'check_id 80: Most scanned indexes (index_usage_stats)', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )

        --Workaholics according to index_usage_stats
        --This isn't perfect: it mentions the number of scans present in a plan
        --A "scan" isn't necessarily a full scan, but hey, we gotta do the best with what we've got.
        --in the case of things like indexed views, the operator might be in the plan but never executed
        SELECT TOP 5 
            80 AS check_id,
            i.index_sanity_id AS index_sanity_id,
            200 AS Priority,
            N'Workaholics' AS findings_group,
            N'Scan-a-lots (index_usage_stats)' AS finding,
            [database_name] AS [Database Name],
            N'http://BrentOzar.com/go/Workaholics' AS URL,
            REPLACE(CONVERT( NVARCHAR(50),CAST(i.user_scans AS MONEY),1),'.00','')
                + N' scans against ' + i.db_schema_object_indexid
                + N'. Latest scan: ' + ISNULL(CAST(i.last_user_scan AS NVARCHAR(128)),'?') + N'. ' 
                + N'ScanFactor=' + CAST(((i.user_scans * iss.total_reserved_MB)/1000000.) AS NVARCHAR(256)) AS details,
            ISNULL(i.key_column_names_with_sort_order,'N/A') AS index_definition,
            ISNULL(i.secret_columns,'') AS secret_columns,
            i.index_usage_summary AS index_usage_summary,
            iss.index_size_summary AS index_size_summary
        FROM #IndexSanity i
        JOIN #IndexSanitySize iss ON i.index_sanity_id=iss.index_sanity_id
        WHERE ISNULL(i.user_scans,0) > 0
        AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
        ORDER BY  i.user_scans * iss.total_reserved_MB DESC;

        RAISERROR(N'check_id 81: Top recent accesses (op stats)', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, index_sanity_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
        --Workaholics according to index_operational_stats
        --This isn't perfect either: range_scan_count contains full scans, partial scans, even seeks in nested loop ops
        --But this can help bubble up some most-accessed tables 
        SELECT TOP 5 
            81 AS check_id,
            i.index_sanity_id AS index_sanity_id,
            200 AS Priority,
            N'Workaholics' AS findings_group,
            N'Top recent accesses (index_op_stats)' AS finding,
            [database_name] AS [Database Name],
            N'http://BrentOzar.com/go/Workaholics' AS URL,
            ISNULL(REPLACE(
                    CONVERT(NVARCHAR(50),CAST((iss.total_range_scan_count + iss.total_singleton_lookup_count) AS MONEY),1),
                    N'.00',N'') 
                + N' uses of ' + i.db_schema_object_indexid + N'. '
                + REPLACE(CONVERT(NVARCHAR(50), CAST(iss.total_range_scan_count AS MONEY),1),N'.00',N'') + N' scans or seeks. '
                + REPLACE(CONVERT(NVARCHAR(50), CAST(iss.total_singleton_lookup_count AS MONEY), 1),N'.00',N'') + N' singleton lookups. '
                + N'OpStatsFactor=' + CAST(((((iss.total_range_scan_count + iss.total_singleton_lookup_count) * iss.total_reserved_MB))/1000000.) AS VARCHAR(256)),'') AS details,
            ISNULL(i.key_column_names_with_sort_order,'N/A') AS index_definition,
            ISNULL(i.secret_columns,'') AS secret_columns,
            i.index_usage_summary AS index_usage_summary,
            iss.index_size_summary AS index_size_summary
        FROM #IndexSanity i
        JOIN #IndexSanitySize iss ON i.index_sanity_id=iss.index_sanity_id
        WHERE (ISNULL(iss.total_range_scan_count,0)  > 0 OR ISNULL(iss.total_singleton_lookup_count,0) > 0)
        AND NOT (@GetAllDatabases = 1 OR @Mode = 0)
        ORDER BY ((iss.total_range_scan_count + iss.total_singleton_lookup_count) * iss.total_reserved_MB) DESC;


    END

         ----------------------------------------
        --Statistics Info: Check_id 90-99
        ----------------------------------------
    BEGIN

        RAISERROR(N'check_id 90: Outdated statistics', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
		SELECT  90 AS check_id, 
				200 AS Priority,
				'Functioning Statistaholics' AS findings_group,
				'Statistic Abandonment Issues',
				s.database_name,
				'' AS URL,
				'Statistics on this table were last updated ' + 
					CASE s.last_statistics_update WHEN NULL THEN N' NEVER '
					ELSE CONVERT(NVARCHAR(20), s.last_statistics_update) + 
						' have had ' + CONVERT(NVARCHAR(100), s.modification_counter) +
						' modifications in that time, which is ' +
						CONVERT(NVARCHAR(100), s.percent_modifications) + 
						'% of the table.'
					END,
				QUOTENAME(database_name) + '.' + QUOTENAME(s.schema_name) + '.' + QUOTENAME(s.table_name) + '.' + QUOTENAME(s.index_name) + '.' + QUOTENAME(s.statistics_name) + '.' + QUOTENAME(s.column_name) AS index_definition,
				'N/A' AS secret_columns,
				'N/A' AS index_usage_summary,
				'N/A' AS index_size_summary
		FROM #Statistics AS s
		WHERE s.last_statistics_update <= CONVERT(DATETIME, GETDATE() - 7) 
		AND s.percent_modifications >= 10. 
		AND s.rows >= 10000

        RAISERROR(N'check_id 91: Statistics with a low sample rate', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
		SELECT  91 AS check_id, 
				200 AS Priority,
				'Functioning Statistaholics' AS findings_group,
				'Antisocial Samples',
				s.database_name,
				'' AS URL,
				'Only ' + CONVERT(NVARCHAR(100), s.percent_sampled) + '% of the rows were sampled during the last statistics update. This may lead to poor cardinality estimates.' ,
				QUOTENAME(database_name) + '.' + QUOTENAME(s.schema_name) + '.' + QUOTENAME(s.table_name) + '.' + QUOTENAME(s.index_name) + '.' + QUOTENAME(s.statistics_name) + '.' + QUOTENAME(s.column_name) AS index_definition,
				'N/A' AS secret_columns,
				'N/A' AS index_usage_summary,
				'N/A' AS index_size_summary
		FROM #Statistics AS s
		WHERE s.rows_sampled < 1.
		AND s.rows >= 10000

        RAISERROR(N'check_id 92: Statistics with NO RECOMPUTE', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
		SELECT  92 AS check_id, 
				200 AS Priority,
				'Functioning Statistaholics' AS findings_group,
				'Cyberphobic Samples',
				s.database_name,
				'' AS URL,
				'The statistic ' + QUOTENAME(s.statistics_name) +  ' is set to not recompute. This can be helpful if data is really skewed, but harmful if you expect automatic statistics updates.' ,
				QUOTENAME(database_name) + '.' + QUOTENAME(s.schema_name) + '.' + QUOTENAME(s.table_name) + '.' + QUOTENAME(s.index_name) + '.' + QUOTENAME(s.statistics_name) + '.' + QUOTENAME(s.column_name) AS index_definition,
				'N/A' AS secret_columns,
				'N/A' AS index_usage_summary,
				'N/A' AS index_size_summary
		FROM #Statistics AS s
		WHERE s.no_recompute = 1

        RAISERROR(N'check_id 93: Statistics with filters', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
		SELECT  93 AS check_id, 
				200 AS Priority,
				'Functioning Statistaholics' AS findings_group,
				'Filter Fixation',
				s.database_name,
				'' AS URL,
				'The statistic ' + QUOTENAME(s.statistics_name) +  ' is filtered on [' + s.filter_definition + ']. It could be part of a filtered index, or just a filtered statistic. This is purely informational.' ,
				QUOTENAME(database_name) + '.' + QUOTENAME(s.schema_name) + '.' + QUOTENAME(s.table_name) + '.' + QUOTENAME(s.index_name) + '.' + QUOTENAME(s.statistics_name) + '.' + QUOTENAME(s.column_name) AS index_definition,
				'N/A' AS secret_columns,
				'N/A' AS index_usage_summary,
				'N/A' AS index_size_summary
		FROM #Statistics AS s
		WHERE s.has_filter = 1

		END 

         ----------------------------------------
        --Computed Column Info: Check_id 90-99
        ----------------------------------------
    BEGIN

	     RAISERROR(N'check_id 99: Computed Columns That Reference Functions', 0,1) WITH NOWAIT;
                INSERT    #BlitzIndexResults ( check_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
		SELECT  99 AS check_id, 
				50 AS Priority,
				'Cold Calculators' AS findings_group,
				'Serial Forcer' AS finding,
				cc.database_name,
				'' AS URL,
				'The computed column ' + QUOTENAME(cc.column_name) + ' on ' + QUOTENAME(cc.schema_name) + '.' + QUOTENAME(cc.table_name) + ' is based on ' + cc.definition 
				+ '. That indicates it may reference a scalar function, or a CLR function with data access, which can cause all queries and maintenance to run serially.' AS details,
				cc.column_definition,
				'N/A' AS secret_columns,
				'N/A' AS index_usage_summary,
				'N/A' AS index_size_summary
		FROM #ComputedColumns AS cc
		WHERE cc.is_function = 1

		RAISERROR(N'check_id 100: Computed Columns that are not Persisted.', 0,1) WITH NOWAIT;
        INSERT    #BlitzIndexResults ( check_id, Priority, findings_group, finding, [database_name], URL, details, index_definition,
                                               secret_columns, index_usage_summary, index_size_summary )
		SELECT  100 AS check_id, 
				200 AS Priority,
				'Cold Calculators' AS findings_group,
				'Definition Defeatists' AS finding,
				cc.database_name,
				'' AS URL,
				'The computed column ' + QUOTENAME(cc.column_name) + ' on ' + QUOTENAME(cc.schema_name) + '.' + QUOTENAME(cc.table_name) + ' is not persisted, which means it will be calculated when a query runs.' + 
				'You can change this with the following command, if the definition is deterministic: ALTER TABLE ' + QUOTENAME(cc.schema_name) + '.' + QUOTENAME(cc.table_name) + ' ALTER COLUMN ' + cc.column_name +
				' ADD PERSISTED'  AS details,
				cc.column_definition,
				'N/A' AS secret_columns,
				'N/A' AS index_usage_summary,
				'N/A' AS index_size_summary
		FROM #ComputedColumns AS cc
		WHERE cc.is_persisted = 0

	END 
 
        RAISERROR(N'Insert a row to help people find help', 0,1) WITH NOWAIT;
        IF DATEDIFF(MM, @VersionDate, GETDATE()) > 6
		BEGIN
            INSERT    #BlitzIndexResults ( Priority, check_id, findings_group, finding, URL, details, index_definition,
                                            index_usage_summary, index_size_summary )
            VALUES  ( -1, 0 , 
		           'Outdated sp_BlitzIndex', 'sp_BlitzIndex is Over 6 Months Old', 'http://FirstResponderKit.org/', 
                   'Fine wine gets better with age, but this ' + @ScriptVersionName + ' is more like bad cheese. Time to get a new one.',
                    N'',N'',N''
                    );
        END

        IF EXISTS(SELECT * FROM #BlitzIndexResults)
		BEGIN
            INSERT    #BlitzIndexResults ( Priority, check_id, findings_group, finding, URL, details, index_definition,
                                            index_usage_summary, index_size_summary )
            VALUES  ( -1, 0 , 
		            @ScriptVersionName,
                    CASE WHEN @GetAllDatabases = 1 THEN N'All Databases' ELSE N'Database ' + QUOTENAME(@DatabaseName) + N' as of ' + CONVERT(NVARCHAR(16),GETDATE(),121) END, 
                    N'From Your Community Volunteers' ,   N'http://FirstResponderKit.org' ,
                    N''
                    , N'',N''
                    );
        END
        ELSE IF @Mode = 0 OR (@GetAllDatabases = 1 AND @Mode <> 4)
        BEGIN
            INSERT    #BlitzIndexResults ( Priority, check_id, findings_group, finding, URL, details, index_definition,
                                            index_usage_summary, index_size_summary )
            VALUES  ( -1, 0 , 
		            @ScriptVersionName,
                    CASE WHEN @GetAllDatabases = 1 THEN N'All Databases' ELSE N'Database ' + QUOTENAME(@DatabaseName) + N' as of ' + CONVERT(NVARCHAR(16),GETDATE(),121) END, 
                    N'From Your Community Volunteers' ,   N'http://FirstResponderKit.org' ,
                    N''
                    , N'',N''
                    );
            INSERT    #BlitzIndexResults ( Priority, check_id, findings_group, finding, URL, details, index_definition,
                                            index_usage_summary, index_size_summary )
            VALUES  ( 1, 0 , 
		           'No Major Problems Found',
                   'Nice Work!',
                   'http://FirstResponderKit.org', 'Consider running with @Mode = 4 in individual databases (not all) for more detailed diagnostics.', 'The new default Mode 0 only looks for very serious index issues.', '', ''
                    );

        END
        ELSE
        BEGIN
            INSERT    #BlitzIndexResults ( Priority, check_id, findings_group, finding, URL, details, index_definition,
                                            index_usage_summary, index_size_summary )
            VALUES  ( -1, 0 , 
		            @ScriptVersionName,
                    CASE WHEN @GetAllDatabases = 1 THEN N'All Databases' ELSE N'Database ' + QUOTENAME(@DatabaseName) + N' as of ' + CONVERT(NVARCHAR(16),GETDATE(),121) END, 
                    N'From Your Community Volunteers' ,   N'http://www.BrentOzar.com/BlitzIndex' ,
                    N''
                    , N'',N''
                    );
            INSERT    #BlitzIndexResults ( Priority, check_id, findings_group, finding, URL, details, index_definition,
                                            index_usage_summary, index_size_summary )
            VALUES  ( 1, 0 , 
		           'No Problems Found',
                   'Nice job! Or more likely, you have a nearly empty database.',
                   'http://FirstResponderKit.org', 'Time to go read some blog posts.', '', '', ''
                    );

        END

        RAISERROR(N'Returning results.', 0,1) WITH NOWAIT;
            
        /*Return results.*/
        IF (@Mode = 0)
        BEGIN

            SELECT Priority, ISNULL(br.findings_group,N'') + 
                    CASE WHEN ISNULL(br.finding,N'') <> N'' THEN N': ' ELSE N'' END
                    + br.finding AS [Finding], 
                br.[database_name] AS [Database Name],
                br.details AS [Details: schema.table.index(indexid)], 
                br.index_definition AS [Definition: [Property]] ColumnName {datatype maxbytes}], 
                ISNULL(br.secret_columns,'') AS [Secret Columns],          
                br.index_usage_summary AS [Usage], 
                br.index_size_summary AS [Size],
                COALESCE(br.more_info,sn.more_info,'') AS [More Info],
                br.URL, 
                COALESCE(br.create_tsql,ts.create_tsql,'') AS [Create TSQL]
            FROM #BlitzIndexResults br
            LEFT JOIN #IndexSanity sn ON 
                br.index_sanity_id=sn.index_sanity_id
            LEFT JOIN #IndexCreateTsql ts ON 
                br.index_sanity_id=ts.index_sanity_id
            WHERE br.check_id IN (0, 1, 11, 22, 43, 68, 50, 60, 61, 62, 63, 64, 65, 72)
            ORDER BY br.Priority ASC, br.check_id ASC, br.blitz_result_id ASC, br.findings_group ASC
			OPTION (RECOMPILE);

        END
        ELSE IF (@Mode = 4)
            SELECT Priority, ISNULL(br.findings_group,N'') + 
                    CASE WHEN ISNULL(br.finding,N'') <> N'' THEN N': ' ELSE N'' END
                    + br.finding AS [Finding], 
				br.[database_name] AS [Database Name],
                br.details AS [Details: schema.table.index(indexid)], 
                br.index_definition AS [Definition: [Property]] ColumnName {datatype maxbytes}], 
                ISNULL(br.secret_columns,'') AS [Secret Columns],          
                br.index_usage_summary AS [Usage], 
                br.index_size_summary AS [Size],
                COALESCE(br.more_info,sn.more_info,'') AS [More Info],
                br.URL, 
                COALESCE(br.create_tsql,ts.create_tsql,'') AS [Create TSQL]
            FROM #BlitzIndexResults br
            LEFT JOIN #IndexSanity sn ON 
                br.index_sanity_id=sn.index_sanity_id
            LEFT JOIN #IndexCreateTsql ts ON 
                br.index_sanity_id=ts.index_sanity_id
            ORDER BY br.Priority ASC, br.check_id ASC, br.blitz_result_id ASC, br.findings_group ASC
			OPTION (RECOMPILE);

    END; /* End @Mode=0 or 4 (diagnose)*/
    ELSE IF @Mode=1 /*Summarize*/
    BEGIN
    --This mode is to give some overall stats on the database.
        RAISERROR(N'@Mode=1, we are summarizing.', 0,1) WITH NOWAIT;

        SELECT DB_NAME(i.database_id) AS [Database Name],
            CAST((COUNT(*)) AS NVARCHAR(256)) AS [Number Objects],
            CAST(CAST(SUM(sz.total_reserved_MB)/
                1024. AS NUMERIC(29,1)) AS NVARCHAR(500)) AS [All GB],
            CAST(CAST(SUM(sz.total_reserved_LOB_MB)/
                1024. AS NUMERIC(29,1)) AS NVARCHAR(500)) AS [LOB GB],
            CAST(CAST(SUM(sz.total_reserved_row_overflow_MB)/
                1024. AS NUMERIC(29,1)) AS NVARCHAR(500)) AS [Row Overflow GB],
            CAST(SUM(CASE WHEN index_id=1 THEN 1 ELSE 0 END)AS NVARCHAR(50)) AS [Clustered Tables],
            CAST(SUM(CASE WHEN index_id=1 THEN sz.total_reserved_MB ELSE 0 END)
                /1024. AS NUMERIC(29,1)) AS [Clustered Tables GB],
            SUM(CASE WHEN index_id NOT IN (0,1) THEN 1 ELSE 0 END) AS [NC Indexes],
            CAST(SUM(CASE WHEN index_id NOT IN (0,1) THEN sz.total_reserved_MB ELSE 0 END)
                /1024. AS NUMERIC(29,1)) AS [NC Indexes GB],
            CASE WHEN SUM(CASE WHEN index_id NOT IN (0,1) THEN sz.total_reserved_MB ELSE 0 END)  > 0 THEN
                CAST(SUM(CASE WHEN index_id IN (0,1) THEN sz.total_reserved_MB ELSE 0 END)
                    / SUM(CASE WHEN index_id NOT IN (0,1) THEN sz.total_reserved_MB ELSE 0 END) AS NUMERIC(29,1)) 
                ELSE 0 END AS [ratio table: NC Indexes],
            SUM(CASE WHEN index_id=0 THEN 1 ELSE 0 END) AS [Heaps],
            CAST(SUM(CASE WHEN index_id=0 THEN sz.total_reserved_MB ELSE 0 END)
                /1024. AS NUMERIC(29,1)) AS [Heaps GB],
            SUM(CASE WHEN index_id IN (0,1) AND partition_key_column_name IS NOT NULL THEN 1 ELSE 0 END) AS [Partitioned Tables],
            SUM(CASE WHEN index_id NOT IN (0,1) AND  partition_key_column_name IS NOT NULL THEN 1 ELSE 0 END) AS [Partitioned NCs],
            CAST(SUM(CASE WHEN partition_key_column_name IS NOT NULL THEN sz.total_reserved_MB ELSE 0 END)/1024. AS NUMERIC(29,1)) AS [Partitioned GB],
            SUM(CASE WHEN filter_definition <> '' THEN 1 ELSE 0 END) AS [Filtered Indexes],
            SUM(CASE WHEN is_indexed_view=1 THEN 1 ELSE 0 END) AS [Indexed Views],
            MAX(total_rows) AS [Max Row Count],
            CAST(MAX(CASE WHEN index_id IN (0,1) THEN sz.total_reserved_MB ELSE 0 END)
                /1024. AS NUMERIC(29,1)) AS [Max Table GB],
            CAST(MAX(CASE WHEN index_id NOT IN (0,1) THEN sz.total_reserved_MB ELSE 0 END)
                /1024. AS NUMERIC(29,1)) AS [Max NC Index GB],
            SUM(CASE WHEN index_id IN (0,1) AND sz.total_reserved_MB > 1024 THEN 1 ELSE 0 END) AS [Count Tables > 1GB],
            SUM(CASE WHEN index_id IN (0,1) AND sz.total_reserved_MB > 10240 THEN 1 ELSE 0 END) AS [Count Tables > 10GB],
            SUM(CASE WHEN index_id IN (0,1) AND sz.total_reserved_MB > 102400 THEN 1 ELSE 0 END) AS [Count Tables > 100GB],    
            SUM(CASE WHEN index_id NOT IN (0,1) AND sz.total_reserved_MB > 1024 THEN 1 ELSE 0 END) AS [Count NCs > 1GB],
            SUM(CASE WHEN index_id NOT IN (0,1) AND sz.total_reserved_MB > 10240 THEN 1 ELSE 0 END) AS [Count NCs > 10GB],
            SUM(CASE WHEN index_id NOT IN (0,1) AND sz.total_reserved_MB > 102400 THEN 1 ELSE 0 END) AS [Count NCs > 100GB],
            MIN(create_date) AS [Oldest Create Date],
            MAX(create_date) AS [Most Recent Create Date],
            MAX(modify_date) AS [Most Recent Modify Date],
            1 AS [Display Order]
        FROM #IndexSanity AS i
        --left join here so we don't lose disabled nc indexes
        LEFT JOIN #IndexSanitySize AS sz 
            ON i.index_sanity_id=sz.index_sanity_id
		GROUP BY DB_NAME(i.database_id)	 
        UNION ALL
        SELECT  CASE WHEN @GetAllDatabases = 1 THEN N'All Databases' ELSE N'Database ' + N' as of ' + CONVERT(NVARCHAR(16),GETDATE(),121) END,        
                @ScriptVersionName,   
                N'From Your Community Volunteers' ,   
                N'http://FirstResponderKit.org' ,
                N'',
                NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
                NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
                NULL,NULL,0 AS display_order
        ORDER BY [Display Order] ASC
        OPTION (RECOMPILE);
           
    END /* End @Mode=1 (summarize)*/
    ELSE IF @Mode=2 /*Index Detail*/
    BEGIN
        --This mode just spits out all the detail without filters.
        --This supports slicing AND dicing in Excel
        RAISERROR(N'@Mode=2, here''s the details on existing indexes.', 0,1) WITH NOWAIT;

        SELECT  [database_name] AS [Database Name], 
                [schema_name] AS [Schema Name], 
                [object_name] AS [Object Name], 
                ISNULL(index_name, '') AS [Index Name], 
                CAST(index_id AS VARCHAR(10))AS [Index ID],
                db_schema_object_indexid AS [Details: schema.table.index(indexid)], 
                CASE    WHEN index_id IN ( 1, 0 ) THEN 'TABLE'
                    ELSE 'NonClustered'
                    END AS [Object Type], 
                index_definition AS [Definition: [Property]] ColumnName {datatype maxbytes}],
                ISNULL(LTRIM(key_column_names_with_sort_order), '') AS [Key Column Names With Sort],
                ISNULL(count_key_columns, 0) AS [Count Key Columns],
                ISNULL(include_column_names, '') AS [Include Column Names], 
                ISNULL(count_included_columns,0) AS [Count Included Columns],
                ISNULL(secret_columns,'') AS [Secret Column Names], 
                ISNULL(count_secret_columns,0) AS [Count Secret Columns],
                ISNULL(partition_key_column_name, '') AS [Partition Key Column Name],
                ISNULL(filter_definition, '') AS [Filter Definition], 
                is_indexed_view AS [Is Indexed View], 
                is_primary_key AS [Is Primary Key],
                is_XML AS [Is XML],
                is_spatial AS [Is Spatial],
                is_NC_columnstore AS [Is NC Columnstore],
                is_CX_columnstore AS [Is CX Columnstore],
                is_disabled AS [Is Disabled], 
                is_hypothetical AS [Is Hypothetical],
                is_padded AS [Is Padded], 
                fill_factor AS [Fill Factor], 
                is_referenced_by_foreign_key AS [Is Reference by Foreign Key], 
                last_user_seek AS [Last User Seek], 
                last_user_scan AS [Last User Scan], 
                last_user_lookup AS [Last User Lookup],
                last_user_update AS [Last User Update], 
                total_reads AS [Total Reads], 
                user_updates AS [User Updates], 
                reads_per_write AS [Reads Per Write], 
                index_usage_summary AS [Index Usage], 
                sz.partition_count AS [Partition Count],
                sz.total_rows AS [Rows], 
                sz.total_reserved_MB AS [Reserved MB], 
                sz.total_reserved_LOB_MB AS [Reserved LOB MB], 
                sz.total_reserved_row_overflow_MB AS [Reserved Row Overflow MB],
                sz.index_size_summary AS [Index Size], 
                sz.total_row_lock_count AS [Row Lock Count],
                sz.total_row_lock_wait_count AS [Row Lock Wait Count],
                sz.total_row_lock_wait_in_ms AS [Row Lock Wait ms],
                sz.avg_row_lock_wait_in_ms AS [Avg Row Lock Wait ms],
                sz.total_page_lock_count AS [Page Lock Count],
                sz.total_page_lock_wait_count AS [Page Lock Wait Count],
                sz.total_page_lock_wait_in_ms AS [Page Lock Wait ms],
                sz.avg_page_lock_wait_in_ms AS [Avg Page Lock Wait ms],
                sz.total_index_lock_promotion_attempt_count AS [Lock Escalation Attempts],
                sz.total_index_lock_promotion_count AS [Lock Escalations],
                sz.data_compression_desc AS [Data Compression],
                i.create_date AS [Create Date],
                i.modify_date AS [Modify Date],
                more_info AS [More Info],
                1 AS [Display Order]
        FROM    #IndexSanity AS i --left join here so we don't lose disabled nc indexes
                LEFT JOIN #IndexSanitySize AS sz ON i.index_sanity_id = sz.index_sanity_id
        ORDER BY [Database Name], [Schema Name], [Object Name], [Index ID]
        OPTION (RECOMPILE);



    END /* End @Mode=2 (index detail)*/
    ELSE IF @Mode=3 /*Missing index Detail*/
    BEGIN
        SELECT 
            database_name AS [Database Name], 
            [schema_name] AS [Schema], 
            table_name AS [Table], 
            CAST((magic_benefit_number/@DaysUptime) AS BIGINT)
                AS [Magic Benefit Number], 
            missing_index_details AS [Missing Index Details], 
            avg_total_user_cost AS [Avg Query Cost], 
            avg_user_impact AS [Est Index Improvement], 
            user_seeks AS [Seeks], 
            user_scans AS [Scans],
            unique_compiles AS [Compiles], 
            equality_columns AS [Equality Columns], 
            inequality_columns AS [Inequality Columns], 
            included_columns AS [Included Columns], 
            index_estimated_impact AS [Estimated Impact], 
            create_tsql AS [Create TSQL], 
            more_info AS [More Info],
            1 AS [Display Order]
        FROM #MissingIndexes
        /* Minimum benefit threshold = 100k/day of uptime */
        WHERE (magic_benefit_number/@DaysUptime) >= 100000
        UNION ALL
        SELECT                 
            @ScriptVersionName,   
            N'From Your Community Volunteers' ,   
            N'http://FirstResponderKit.org' ,
            100000000000,
            N'',
            NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
            NULL, 0 AS display_order
        ORDER BY [Display Order] ASC, [Magic Benefit Number] DESC
		OPTION (RECOMPILE);

    END /* End @Mode=3 (index detail)*/
END
END TRY

BEGIN CATCH
        RAISERROR (N'Failure analyzing temp tables.', 0,1) WITH NOWAIT;

        SELECT    @msg = ERROR_MESSAGE(), @ErrorSeverity = ERROR_SEVERITY(), @ErrorState = ERROR_STATE();

        RAISERROR (@msg, 
               @ErrorSeverity, 
               @ErrorState 
               );
        
        WHILE @@trancount > 0 
            ROLLBACK;

        RETURN;
    END CATCH;
GO
