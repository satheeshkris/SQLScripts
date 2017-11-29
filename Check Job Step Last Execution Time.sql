select j.name as 'JobName',h.step_name,h.step_id,
run_date, run_time, msdb.dbo.agent_datetime(run_date, run_time) as 'RunDateTime',
run_duration,
((run_duration/10000*3600 + (run_duration/100)%100*60 + run_duration%100 + 31 ) / 60) 
          as 'RunDurationMinutes'
From msdb.dbo.sysjobs j 
INNER JOIN msdb.dbo.sysjobhistory h 
 ON j.job_id = h.job_id 
where j.enabled = 1  and Step_id<> '0'   --Only Enabled Jobs
AND j.name = 'Neon_Report_Hourly'  and h.step_id = '1'
/*Change the job name and step id in above line, run_duration is in HHMMSS   */
order by RunDateTime desc,  JobName, step_id 
