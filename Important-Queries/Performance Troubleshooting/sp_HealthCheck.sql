USE [master]
GO
/* - - - - - - - - - - - - - - - - - - - - - - - -  - - - - - - - - - - - - - - - - - - - - - - - - 

	Sproc Name: dbo.sp_HealthCheck
    Author: Chandu Rayalla
    Date:	August 15, 2014
	Description: 1. Checks the Active connections
				 2. CPU and Memory Usage
				 3. Displays the capacity on the server and databases space used and availability just as sp_helpdb
				 4. Lead Blocker connection(s)
				 5. Long running connection(s): Backup/Rollback, DBCC TABLE CHECK/Shrinkfile status with estimation time of completion with percentage
				 6. AlwaysOn availability Group status
				 7. Mirroring status

		Store Procedure Parameters:
				sp_HealthCheck 
						@Option			varchar(1)
						@Status			varchar(10)
						@Orderby		varchar(1)

		usage:  exec sp_HealthCheck -- This display the Active connections by default with order by Logical_Reads and CPU%, Diskspace, Lead Blocker, Long runngin connections
				Select parameters with values as below:
				exec sp_HealthCheck @Option = 0 - All, 1 - Connections, 2 - CPU %, 3 - Diskspace, 4 - Lead Blocker, 5 - Backup/Rollback status.
									, @Status = 'All' or 'ACTIVE' or 'SLEEPING'
									, @Orderby =  1 - 'Logical_Reads desc'
												  2 - 'Order by CPUTime desc'
												  3 - 'Order by SPID'
		Example:									
			exec sp_HealthCheck '?' 
			exec sp_HealthCheck -- This display the Active connections by default with order by Logical_Reads and CPU%, Diskspace, Lead Blocker, Long runngin connections
			exec sp_HealthCheck @Option = 0  -- This display the Active connections by default with order by Logical_Reads and CPU%, Diskspace, Lead Blocker, Long running connections
			exec sp_HealthCheck @Option = 1	 -- Active connections

			exec sp_HealthCheck @Option = 1, @status = 'All', @Orderby = 3		-- Connection with Active and Sleeping and Order by SPID
			exec sp_HealthCheck @Option = 1, @status = 'ACTIVE', @Orderby = 1	-- Connection with Active and Order by Logical_Reads desc
			exec sp_HealthCheck @Option = 1, @status = 'SLEEPING', @Orderby = 1	-- Connection with Sleeping and Order by Logical_Reads desc
			exec sp_HealthCheck @Option = 2  -- CPU usage % and Memory Usage %
												( This feature is applies to SQL Server 2008 plus higher version )
			exec sp_HealthCheck @Option = 3  --	Displays the capacity on the server and databases free and used
												( The Server Capacity feature is applies to SQL Server 2008 plus higher version to avoid using xp_cmdshell due to Security reasons: )
			exec sp_HealthCheck @Option = 4	 --	Lead Blocker list only the waittime greater than 60 seconds 
			exec sp_HealthCheck @Option = 5	 -- Long running connections: just ass Backup/Rollback, DBCC TABLE CHECK/Shrinkfile status with estimation time of completion with percentage'
			exec sp_HealthCheck @Option = 6	 -- AlwaysOn availability Group status
			exec sp_HealthCheck @Option = 7	 -- Mirroring status

- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */
create procedure [dbo].[sp_HealthCheck] ( 
						@Option		varchar(1) = 0
						, @Status	varchar(10) = 'ACTIVE'
						, @Orderby	varchar(1) = 1 )
with execute as 'dbo'
as
begin
	set nocount on
	set transaction isolation level read uncommitted
	
	declare @UsageClause varchar(max)
	set @UsageClause = '
		This stored procedure gives the following reports:
			1. Connection details just as sp_who2 with selection criteria
			2. CPU and Memory Usage % ( This feature is applies to SQL Server 2008 plus higher version )
			3. Displays the capacity on the server and databases space used and availability
			   ( The Server Capacity feature is applies to SQL Server 2008 plus higher version )
			4. Lead Blocker Connection(s)
			5. Long running connection(s): Just as Backup/Rollback status with estimation time of completion with percentage
			6. AlwaysOn availability Group status
			7. Mirroring status
		** Note:
		CPU and Memory Usage and Server Capacity feature is applies to SQL Server 2008 plus higher version
		AlwaysOn availability feature is applies to SQL Server 2012 plus higher version
		Store Procedure Parameters:
			sp_HealthCheck 
					@Option			varchar(1)
					@Status			varchar(10)
					@Orderby		varchar(1)
		usage:
			exec sp_HealthCheck -- This display the Active connections by default with order by Logical_Reads and CPU%, Diskspace, 
								   Lead Blocker, Long running connections, AlwaysOn availability status and Mirroring status
			Select parameters with values as below:
			exec sp_HealthCheck 
					@Option		= 0 - Display Connections, CPU%, Diskspace, Lead Blocker, Long running connections with status, AlwaysOn availability status and Mirroring status
								  1 - Connections ( default active )
								  2 - CPU and Memory Usage % ( This feature is applies to SQL Server 2008 plus higher version )
								  3 - Displays the capacity on the server and databases space used and availability
									  ( The Server Capacity feature is applies to SQL Server 2008 plus higher version )								  
								  4 - Lead Blocker connection(s)
								  5 - Long running connection(s): Just as Backup/Rollback status with estimation time of completion with percentage
								  6	- This displays the AlwaysOn availability Group status
								  7 - This displays the Mirroring status
					, @Status	= ''All'' ( Active & Sleeping )
								  ''ACTIVE'' ( default )
								  ''SLEEPING'' 
					, @Orderby	= 1 - ''Logical_Reads desc'' ( default )
								  2 - ''Order by CPUTime desc''
								  3 - ''Order by SPID''
		Example:									
			exec sp_HealthCheck ''?''  -- Help
			exec sp_HealthCheck -- This display the Active connections by default with order by Logical_Reads and CPU%, Diskspace, 
								   Lead Blocker, Long running connections, AlwaysOn availability status and Mirroring status
			exec sp_HealthCheck @Option = 0  -- This display the Active connections by default with order by Logical_Reads and CPU%, Diskspace, 
												Lead Blocker, Long running connections, AlwaysOn availability status and Mirroring status
			exec sp_HealthCheck @Option = 1	 -- Active connections

			exec sp_HealthCheck @Option = 1, @Status = ''All'', @Orderby = 3      -- Connection with Active and Sleeping and Order by SPID
			exec sp_HealthCheck @Option = 1, @Status = ''ACTIVE'', @Orderby = 1   -- Connection with Active and Order by Logical_Reads desc
			exec sp_HealthCheck @Option = 1, @Status = ''SLEEPING'', @Orderby = 1 -- Connection with Sleeping and Order by Logical_Reads desc

			exec sp_HealthCheck @Option = 2  -- CPU and Memory Usage % ( This feature is applies to SQL Server 2008 plus higher version )
			exec sp_HealthCheck @Option = 3  --	Displays the capacity on the server and databases space used and availability 
												( The Server Capacity feature is applies to SQL Server 2008 plus higher version )
			exec sp_HealthCheck @Option = 4	 --	Lead Blocker connection(s) only the waittime greater than 60 seconds 
			exec sp_HealthCheck @Option = 5	 -- Long running connections: Just as Backup/Rollback status with estimation time of completion with percentage
			exec sp_HealthCheck @Option = 6	 -- This displays the AlwaysOn availability Group status
			exec sp_HealthCheck @Option = 7	 -- This displays the Mirroring status
						
			exec sp_HealthCheck
			exec sp_HealthCheck 1
			exec sp_HealthCheck 2
			exec sp_HealthCheck 3
			exec sp_HealthCheck 4
			exec sp_HealthCheck 5
			exec sp_HealthCheck 6
			exec sp_HealthCheck 7'

	begin try
		if ( @Option not in ('0','1','2','3','4','5','6','7'))
		begin
			print @UsageClause
			return
		end
--		declare @current_dbname varchar(200)
--		select @current_dbname = upper(db_name())

		-- - - - - - - - - - - - - - - - - - - - - - - -  - - - - - - - - - - - - - - - - - - - - - - - - 
		--	1. Shows connection details
		--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
		if ( @Option = '0' or @Option = '1' )
		begin 
			declare @Status_stmt nvarchar(100)
			declare @sql nvarchar(max)
			
			select @Status_stmt = case @Status when 'ACTIVE' then 'and upper(coalesce(r.status, s.status)) not in (''SLEEPING'', ''BACKGROUND'')' 
											   when 'SLEEPING' then 'and upper(coalesce(r.status, s.status)) in (''SLEEPING'')' 
											   when 'ALL' then ' ' end
			
			select @sql = '
			select distinct SPID = convert(bigint, s.session_id)
				, [Status] = convert(nvarchar(50), upper(coalesce(r.status, s.status)))
				, [Login] = s.login_name
				, Host_Name = convert(nvarchar(128), coalesce(s.host_name, '' ''))
				, BlkBy = convert(nvarchar(12), coalesce(rtrim(nullif(r.blocking_session_id, 0)), ''.''))
				, DBName = coalesce(db_name(r.database_id), '' '')
				, Command = convert(nvarchar(128), coalesce(r.command, '' ''))
				, CPUTime = convert(bigint, coalesce(s.cpu_time,0) + coalesce(r.cpu_time,0))
				, Reads = convert(bigint, coalesce(s.reads,0) + coalesce(r.reads,0))
				, Writes = convert(bigint, coalesce(s.writes,0) + coalesce(r.writes,0)) 
				, Logical_Reads = convert(bigint, coalesce(s.logical_reads,0) + coalesce(r.logical_reads,0))
				, Login_Time = s.login_time
				, LastBatch = s.last_request_end_time
				, total_elapsed_time_Sec = convert(bigint, coalesce((r.total_elapsed_time/1000),0))
				, ProgramName = s.program_name
				, Current_Query = substring(	t.text, 
							r.statement_start_offset / 2 + 1,
							(	case when r.statement_end_offset = -1 then len( convert( nvarchar( max ), t.text ) ) * 2 
									 else r.statement_end_offset 
								end - r.statement_start_offset ) / 2 )
				, Complete_Statement = t.text
			from master.sys.dm_exec_sessions s ( nolock )
			left join master.sys.dm_exec_requests r ( nolock ) on
				 s.session_id = r.session_id
			outer apply sys.dm_exec_sql_text (r.sql_handle) t
			where s.session_id > 50 ' + @Status_stmt + 
			' order by ' +
			( case @Orderby when 1 then 'Logical_Reads desc' 
							when 2 then 'CPUTime desc' 
							when 3 then 'SPID' 
			  else 'Logical_Reads desc' end )

			execute sp_executesql @sql
		end

		-- - - - - - - - - - - - - - - - - - - - - - - -  - - - - - - - - - - - - - - - - - - - - - - - - 
		--	2. CPU and Memory Usage % ( This feature is applies to SQL Server 2008 through current version )
		--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
		if ( @Option = '0' or @Option = '2' )
		begin 
			if object_id (N'master.sys.dm_os_sys_memory') is null or object_id (N'master.sys.dm_os_ring_buffers') is null
			begin
				select [CPU & Memory Usage] = '*** This feature is applies to SQL Server 2008 plus higher version ***'
			end
			else
			begin
				declare @cpuUsage float
	    
				select top 1 @cpuUsage = 100 - r.SystemIdle
				from (  select rx.record.value('(./Record/@id)[1]', 'int') AS record_id
						, rx.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle
						from (  select convert(xml, record) as record
								from sys.dm_os_ring_buffers ( nolock )
								where ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' 
								  and record like '%<SystemHealth>%') as rx
						) as r
				order by r.record_id desc

				select [CPU Usage %] = @cpuUsage
					, [Memory Usage %]  = convert(decimal(12,2),((total_physical_memory_kb - available_physical_memory_kb) / convert(float,total_physical_memory_kb )) * 100.0 )
					, PhysicalMemoryGB  = convert(decimal(12,2),convert(float,total_physical_memory_kb) / ( 1024 * 1024 ))
					, AvailableMemoryGB = convert(decimal(12,2),convert(float,available_physical_memory_kb) / ( 1024 * 1024 ))
				from master.sys.dm_os_sys_memory 
			end
		end

		-- - - - - - - - - - - - - - - - - - - - - - - -  - - - - - - - - - - - - - - - - - - - - - - - - 
		--	3. Displays the capacity on the server space used and availablity
		--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
		if ( @Option = '0' or @Option = '3' )
		begin 
			if object_id (N'master.sys.dm_os_volume_stats') is null or object_id (N'sys.dm_db_file_space_usage') is null
			begin
				select [Server Capacity] = '*** This feature is applies to SQL Server 2008 plus higher version ***'
			end
			else
			begin
				declare @tLabel varchar(100) 
					, @tVolume  varchar(100) 
				select @tLabel = upper(logical_volume_name)
					, @tVolume = upper(volume_mount_point)
				from master.sys.dm_os_volume_stats(2, 1) 

				select distinct 
					Label = upper(vs.logical_volume_name)
					, [Volume] = upper(vs.volume_mount_point)
					, [Total (GB)] = convert(decimal(20,2), vs.total_bytes / 1024. /1024. / 1024. )
					, [Used (GB)] = convert(decimal(20,2), (vs.total_bytes - vs.available_bytes) / 1024. /1024. / 1024. )
					, [Free (GB)] = convert(decimal(20,2), vs.available_bytes / 1024. /1024. / 1024. )
					, [Used (%)] = convert(decimal(20,2), convert(decimal(20,2), (vs.total_bytes - vs.available_bytes) / 1024. /1024. / 1024. ) /
									convert(decimal(20,2), vs.total_bytes / 1024. /1024. / 1024. ) * 100.0)
					, [Free (%)] =  convert(decimal(20,2), convert(decimal(20,2), vs.available_bytes / 1024. /1024. / 1024. ) / 
									convert(decimal(20,2), vs.total_bytes / 1024. /1024. / 1024. ) * 100.0 )
				from sys.master_files mf 
				cross apply master.sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
				where upper(vs.logical_volume_name) != @tLabel
				union all 
				select Label = @tLabel
					, [Volume] = @tVolume
					, [Total (GB)] = a.totalFileSizeGB
					, [Used (GB)] = cast( ( a.totalFileSizeGB - a.freeSpaceGB ) as decimal( 20, 2 ) )
					, [Free (GB)] = a.freeSpaceGB
					, [Used (%)] = cast( ( a.totalFileSizeGB - freeSpaceGB ) / totalFileSizeGB * 100 as decimal( 20, 2 ) )
					, [Free (%)] = cast(  freeSpaceGB / totalFileSizeGB * 100 as decimal( 20, 2 ) )
				from  ( select	totalFileSizeGB = cast( sum(	unallocated_extent_page_count +
										version_store_reserved_page_count +
										user_object_reserved_page_count +
										internal_object_reserved_page_count +
										mixed_extent_page_count ) * 8. / 1024. / 1024.  as decimal( 20, 2 ) ) 
							, freeSpaceGB = cast( sum( unallocated_extent_page_count ) * 8. / 1024. / 1024. as decimal( 20, 2 ) ) 
						from tempdb.sys.dm_db_file_space_usage ) a
				order by [Volume]
			end

		-- - - - - - - - - - - - - - - - - - - - - - - -  - - - - - - - - - - - - - - - - - - - - - - - - 
		--	3.1. Displays the capacity on the databases space used and availablity just as sp_helpdb details 
		--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 

			declare @FileSpaceDetails TABLE (
				DatabaseId			integer
				, DatabaseName		sysname
				, LogicalFileName	varchar(100)
				, FileName			varchar(250)
				, FileSizeMB		decimal(20,2)
				, SpaceUsedMB		decimal(20,2)
				, FreeSpaceMB		decimal(20,2) )

			if object_id (N'master.sys.sp_msforeachdb') is not null
			begin
				insert into @FileSpaceDetails
				exec sp_msforeachdb 'use [?]; 
				select DatabaseId = db_id(''?'')
					, DatabaseName = ''?''
					, LogicalFileName = a.name
					, a.Filename
					, round(convert(float,a.size/128.000),2) as FileSizeMB     
					, round(convert(float,fileproperty(a.name,''SpaceUsed'')/128.000),2) as SpaceUsedMB     
					, round(convert(float,(a.size-fileproperty(a.name,''SpaceUsed''))/128.000),2) as FreeSpaceMB 
				from sys.sysfiles a ( nolock )'
			end

			if object_id (N'master.sys.sp_msforeachdb') is null 
			begin
				declare @dbnm varchar(200) 
				declare @dbtmp table ( dbname varchar(200))
				insert into @dbtmp
				select name from sys.databases 
				select @dbnm = ''
				select top 1 @dbnm = dbname from @dbtmp
				while @dbnm != ''
				begin
					select @sql = ''
					select @sql = ' use [' + @dbnm + '] ; 
						select DatabaseId = db_id(''' + @dbnm + ''')
							, DatabaseName = ''' + @dbnm + ''' 
							, LogicalFileName = a.name
							, a.Filename
							, round(convert(float,a.size/128.000),2) as FileSizeMB     
							, round(convert(float,fileproperty(a.name,''SpaceUsed'')/128.000),2) as SpaceUsedMB     
							, round(convert(float,(a.size-fileproperty(a.name,''SpaceUsed''))/128.000),2) as FreeSpaceMB 
						from sys.sysfiles a ( nolock )'
				
					insert into @FileSpaceDetails				
					execute sp_executesql @sql
				
					delete from @dbtmp where dbname = @dbnm
					select @dbnm = ''
					select top 1 @dbnm = dbname from @dbtmp
				end
			end
			select * from @FileSpaceDetails
			where DatabaseId > 4
			order by DatabaseId, FileName 
		end

		-- - - - - - - - - - - - - - - - - - - - - - - -  - - - - - - - - - - - - - - - - - - - - - - - - 
		--	4. Lead Blocker connection(s)
		--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
		if ( @Option = '0' or @Option = '4' )
		begin 
			declare @sp_id int
			select @sp_id = p.spid from master.sys.sysprocesses p (nolock)
			where p.spid in ( select distinct blocked from master.sys.sysprocesses s (nolock) 
							  where s.waittime > 60000 
							    and s.blocked > 0 )

			if ( @sp_id is null or @sp_id = 0 )
			begin
				select Lead_Blocker = '*** No results for Lead Blocker ***'
			end
			else
			begin
				select distinct Lead_Blocker = p.spid
--					, spid = coalesce(x.session_id, 0)
					, p.status
					, p.loginame
					, p.hostname
					, dbname = db_name (p.dbid)
					, p.cmd
--					, waittimeInSeconds = coalesce(x.wait_time / 1000, 0)
					, p.last_batch
					, programName = p.program_name
					, Current_Query = coalesce(Current_Query, 'Query no more exists to display')
					, Complete_Statement = coalesce(Complete_Statement,'Query no more exists to display')
				from master.sys.sysprocesses p  ( nolock )
				left join ( select distinct r.session_id
								--, r.blocking_session_id
								, r.wait_time
								, Current_Query = substring( t.text, r.statement_start_offset / 2 + 1,
										( case when r.statement_end_offset = -1 then len( convert( nvarchar( max ), t.text ) ) * 2 
										  else r.statement_end_offset 
										  end - r.statement_start_offset ) / 2 )
								, Complete_Statement = t.text
							from master.sys.dm_exec_requests r ( nolock )
							cross apply sys.dm_exec_sql_text ( r.sql_handle ) t ) x on
					p.spid = x.session_id
				where p.spid in ( select distinct blocked from master.sys.sysprocesses s (nolock) 
								  where s.waittime > 60000 
								    and s.blocked > 0 )
				  and p.blocked = 0	
			end
		end

		-- - - - - - - - - - - - - - - - - - - - - - - -  - - - - - - - - - - - - - - - - - - - - - - - - 
		--	5. Long running connections: Backup/Rollback, DBCC TABLE CHECK/Shrinkfile status with 
		--		estimation time of completion with percentage
		--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
		if ( @Option = '0' or @Option = '5' )
		begin 
			if not exists ( select 1 from master.sys.dm_exec_requests r 
						where r.percent_complete <> 0
						union
						select 1 from master.sys.dm_exec_requests r 
						where upper(r.command) like '%ROLLBACK%' )
			begin
				 select BackupOrRollbackStatus = '*** No results for Long running queries, just as Backup/Rollback  ***' 
			end
			else
			begin 
				select LongRunningSPID = r.session_id
					, dbname = db_name(r.database_id) 
					, r.start_time
					, r.percent_complete
					, estimated_completion_time = dateadd(millisecond, r.estimated_completion_time, getdate())
					, total_process_time_minutes = datediff(minute, r.start_time, dateadd(millisecond, r.estimated_completion_time, getdate())) 
					, currentQuery = substring(	t.text, r.statement_start_offset / 2 + 1,
								( case when r.statement_end_offset = -1 then len( convert( nvarchar( max ), t.text ) ) * 2 
								  else r.statement_end_offset 
								  end - r.statement_start_offset ) / 2 )
					, Complete_Statement = t.text
					, r.command		
				from master.sys.dm_exec_requests r 
				outer apply master.sys.dm_exec_sql_text(r.sql_handle) t
				where r.percent_complete <> 0
				union
				select r.session_id
					, dbname = db_name(r.database_id) 
					, r.start_time
					, r.percent_complete
					, estimated_completion_time = dateadd(millisecond, r.estimated_completion_time, getdate())
					, total_process_time_minutes = datediff(minute, r.start_time, dateadd(millisecond, r.estimated_completion_time, getdate())) 
					, currentQuery = substring(	t.text, r.statement_start_offset / 2 + 1,
								( case when r.statement_end_offset = -1 then len( convert( nvarchar( max ), t.text ) ) * 2 
								  else r.statement_end_offset 
								  end - r.statement_start_offset ) / 2 )
					, Complete_Statement = t.text
					, r.command		
				from master.sys.dm_exec_requests r 
				outer apply master.sys.dm_exec_sql_text(r.sql_handle) t
				where upper(r.command) like '%ROLLBACK%'				 
			end
		end

		-- - - - - - - - - - - - - - - - - - - - - - - -  - - - - - - - - - - - - - - - - - - - - - - - - 
		--	6. AlwaysOn availability Group status
		--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
		if ( @Option = '0' or @Option = '6' )
		begin 
			if object_id (N'master.sys.availability_groups') is not null 
			   and exists ( select port from sys.tcp_endpoints where type_desc = 'DATABASE_MIRRORING' ) 
			begin
				if exists ( select group_id from sys.availability_groups )
				begin
					select 
 						AlwaysOn_dsn_name = agl.dns_name
						, ar.replica_server_name
						, ars.role_desc
						, dr.database_name
						, ar.create_date	
						, ars.operational_state_desc
						, ars.connected_state_desc
						, ars.recovery_health_desc
						, ars.synchronization_health_desc
						, ar.availability_mode_desc
						, ars.last_connect_error_number
						, ars.last_connect_error_description
						, ars.last_connect_error_timestamp
					from sys.availability_groups ag (nolock)
					join sys.dm_hadr_availability_group_states ags (nolock) on
						 ags.group_id = ag.group_id
					join sys.availability_replicas ar (nolock) on
						 ar.group_id = ag.group_id
					join sys.dm_hadr_availability_replica_states ars (nolock) on
						 ars.replica_id = ar.replica_id
					 and ars.group_id = ag.group_id
					join sys.dm_hadr_database_replica_cluster_states dr (nolock) on
						 dr.replica_id = ar.replica_id
					join sys.availability_group_listeners agl (nolock) on
						 agl.group_id = ag.group_id
					order by role_desc
				end
			end
		end
		-- - - - - - - - - - - - - - - - - - - - - - - -  - - - - - - - - - - - - - - - - - - - - - - - - 
		--	7. Mirroring status
		--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
		if ( @Option = '0' or @Option = '7' )
		begin 
			if object_id (N'master.sys.tcp_endpoints') is not null 
			begin
				if exists ( select port from master.sys.tcp_endpoints where type_desc = 'DATABASE_MIRRORING' ) 
					and exists ( select mirroring_role_desc from sys.database_mirroring where mirroring_role_desc is not null )
				begin
					select Mirroring_DatabaseName = d.name
						, m.mirroring_role_desc
						, m.mirroring_partner_instance
						, m.mirroring_state_desc
						, mirroring_safety_level_desc = case m.mirroring_safety_level 
														when 0 then 'Unknown state'
														when 1 then 'Off [asynchronous]'
														when 2 then 'Full [synchronous]' 
														else 'Not mirrored' end
						, m.mirroring_witness_state_desc
					from sys.database_mirroring m 
					join sys.databases d on
						 m.database_id = d.database_id
					where m.mirroring_role_desc is not null 
					order by m.mirroring_role_desc desc, d.name
				end
			end
		end
	end try

	begin catch
		declare @errorNumber int
			, @errorSeverity int
			, @errorState int
			, @errorLine int
			, @errorMessage varchar(4000)

		select @errorNumber	 = Error_Number()
			, @errorSeverity = Error_Severity()
			, @errorState	 = Error_State()
			, @errorLine	 = Error_Line()
			, @errorMessage	 = Error_Message()
		
		set @errorMessage = 'Error Number: ' + convert(varchar, @errorNumber) + '; ' + 
							'Line: ' + convert(varchar, @errorLine) + '; ' + 
							'Message: "' + @errorMessage + '"';
		raiserror (@errorMessage, @errorSeverity, @errorState);
	end catch
end

GO
