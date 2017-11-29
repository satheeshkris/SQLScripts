SELECT	p.max_elapsed_time/1000000/60 as [max_elapsed_time_in_Minutes], p.max_physical_reads, p.max_logical_reads, p.max_logical_writes,
		cp.objtype AS ObjectType, OBJECT_NAME(st.objectid, st.dbid) AS ObjectName, 
		cp.usecounts AS ExecutionCount, st.TEXT AS QueryText, qp.query_plan AS QueryPlan
FROM	sys.dm_exec_procedure_stats as  p
inner join
		sys.dm_exec_cached_plans AS cp
	on	p.plan_handle = cp.plan_handle
	CROSS APPLY
		sys.dm_exec_query_plan( cp.plan_handle ) AS qp 
	 CROSS APPLY
		sys.dm_exec_sql_text( cp.plan_handle ) AS st
WHERE p.object_id = OBJECT_ID('usp_Upload_exceldump_DTRA_R2_WP_VOLUME_REPORT')
