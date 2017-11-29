select a.name, case b.type
when 'D' then 'Full Database Backup'
when 'I' THEN 'Differential Backup'
WHEN 'L' THEN 'Log Backup'
END AS Backup_Type,
max(b.backup_finish_date) LastSuccessfulBackup,
cast((getdate() - max(b.backup_finish_date)) as numeric(5, 2)) as 'IntervalInDays',
case
--when cast((getdate() - max(b.backup_finish_date)) as numeric(5, 2)) > 1 then cast('Completed' as varchar(10))
--when cast((getdate() - max(b.backup_finish_date)) as numeric(5, 2)) > 7 then cast('Failed' as varchar(10))
when datediff(hh,max(b.backup_finish_date),getdate()) > 1 then cast('Completed Full BKP' as varchar(30))
when datediff(hh,max(b.backup_finish_date),getdate()) < 1 then cast('Failed Diff BKP' as varchar(30))
End as completion_Status,
case
when (max(b.backup_finish_date) is NULL )then 'Backup Failed-no Data Found'
end as backup_status_data_not_found
from master..sysdatabases a
LEFT OUTER JOIN msdb..backupset b
ON a.name = b.database_name
where a.name not in ('tempdb') and b.type = 'D'
group by a.name, b.type
order by a.name, b.type
