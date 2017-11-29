use uhtdba
go

select * from InfrastructureRunLog l
	where l.jobStartDTS > '2017-04-05'
	and	l.jobName = 'DBA - Backup All Tranlogs'
order by logDTS DESC
go

--select * from INFORMATION_SCHEMA.TABLES --

select * from backup_history h inner join backup_history_file f on f.backup_id = h.backup_id
	order by backup_start_date desc