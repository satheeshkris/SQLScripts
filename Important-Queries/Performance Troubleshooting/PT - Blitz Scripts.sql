/*	****	Powershell method to import Blitz Scripts	*****
Import-Module "C:\Users\ADwived8\Desktop\Ajay\Study\Powershell Exercises\Assignments\SQL-Server-First-Responder-Kit-dev\FirstResponderKit.ps1" -Force
Apply-FirstResponderKit -ServerName instanceName
Remove-FirstResponderKit -ServerName instanceName
*/

--	1) SQL Server Health Checkup
	--	https://www.brentozar.com/blitz/documentation/
	--	https://www.brentozar.com/blitz/
	EXEC tempdb..sp_Blitz
	EXEC tempdb..sp_Blitz @BringThePain=1 -- Bring out the pain

--	2) Find out what's going on with queries on server
	--	https://www.brentozar.com/archive/2014/05/introducing-sp_blitzcache/
	--	https://www.brentozar.com/archive/2014/11/using-sp_blitzcache-advanced-features/
	EXEC tempdb..sp_BlitzCache
	EXEC tempdb..sp_BlitzCache @top=10, @SortOrder='CPU' --CPU, reads, writes, etc. This controls collection and display.
	EXEC tempdb..sp_BlitzCache @Top = 10, @SortOrder = 'read' -- logical reads
	EXEC tempdb..sp_BlitzCache @ExpertMode=1, @BringThePain=1 ,@ExportToExcel=1 --@ExportToExcel - excludes result set columns that would make Excel blow chunks when you copy/paste the results into Excel, like the execution plans. Good for sharing the plan cache metrics with other folks on your team.


--	3) Analyze all about Index
	EXEC tempdb..sp_BlitzIndex @DatabaseName = 'CIDB' ,@BringThePain = 1 -- Bring only main issues
	EXEC tempdb..sp_BlitzIndex @DatabaseName = 'CIDB', @Mode=1 -- Summarize database metrics
	EXEC tempdb..sp_BlitzIndex @DatabaseName = 'CIDB', @Mode=2 -- Index usage detail only
	EXEC tempdb..sp_BlitzIndex @DatabaseName = 'CIDB', @Mode=4 -- in-depth diagnostics, including low-priority issues and small objects
	EXEC tempdb..sp_BlitzIndex @DatabaseName = 'CIDB', @Mode=3 -- Missing Index only


--	4) Analyze at the moment activities of the server
	exec tempdb..sp_BlitzFirst @ExpertMode = 1, @Seconds = 300

	--	https://www.brentozar.com/archive/2016/07/sp_blitzfirst-sincestartup-1-shows-waits-since-uh-startup/
	EXEC tempdb..sp_BlitzFirst @SinceStartup = 1 -- Wait Stats since Startup

--	5) Find out what's happening with your queries.
	EXEC tempdb..sp_BlitzWho
	EXEC tempdb..sp_HealthCheck
	EXEC tempdb..sp_WhoIsActive @get_plans=1, @get_full_inner_text=1, @get_transaction_info=1, @get_task_info=2, @get_locks=1, @get_avg_time=1, @get_additional_info=1,@find_block_leaders=1

--	6) Measure SQL Server Workloads
	--	https://www.brentozar.com/archive/2015/03/how-to-measure-sql-server-workloads-wait-time-core-second/

--	7) High Virtual Log File (VLF) Count
	--	http://blog.rdx.com/blog/dba_tips/2014/05/fixing-high-vlf-counts
	DBCC loginfo -- No of rows returned = No of VLFs


/*	****************************************************************************
****	Parameter Sniffing	-	Sample 01
*******************************************************************************/
use StackOverflow

--	Find users by Age group
select age, count(1) as counts from dbo.Users u
group by Age
ORDER BY counts

--	Analyze Plan_Handle, SQL_Handle, Query_Hash & Query_Plan_Hash of below 3 selects
	-- Analyze Execution plans
--	01
SELECT	*
FROM	dbo.Users as u
WHERE	u.Age = 13
--	02
SELECT	*
FROM	dbo.Users as u
WHERE	u.Age = 57
--	03
SELECT	*
FROM	dbo.Users as u
WHERE	u.Age = 26

--	Create Non-clustered index for Age column
CREATE NONCLUSTERED INDEX NCI_Users_Age ON dbo.Users (Age)
GO

--	Create procedure for Parameter Sniffing Analysis
IF OBJECT_ID('dbo.uspGetUsersByAge') IS NOT NULL
	DROP PROCEDURE dbo.uspGetUsersByAge
GO
CREATE PROCEDURE dbo.uspGetUsersByAge (@age TINYINT)
AS 
BEGIN
	SELECT	*
	FROM	dbo.Users as u
	WHERE	u.Age = @age
END
GO

--	Set metrics ON;
SET STATISTICS IO ON;
--SET STATISTICS TIME ON;
EXEC dbo.uspGetUsersByAge @age = 13
PRINT '--==========================================================================='
EXEC dbo.uspGetUsersByAge @age = 26

--	Analyze Histogram for Cardinality Estimation
DBCC SHOW_STATISTICS ('dbo.Users','NCI_Users_Age')

--	User below script for SQLQueryStress Parameter generation
	--	Generate random age between 1 and 100
	SELECT ABS(CAST(NEWID() AS binary(6)) %100) + 1 randomNumber
	FROM sysobjects
	
	SELECT @@SERVERNAME

--	Analyze using Procedure Name
exec tempdb..sp_BlitzCache @StoredProcName = 'uspGetUsersByAge'

--	Analyze using Query Hash in case SQL Code is not procedure
exec tempdb..sp_BlitzCache @OnlyQueryHashes = '0x998533A642130191'

use StackOverflow
--	Run sp_recompile for one table or proc 
exec sp_recompile 'uspGetUsersByAge'
--	Run DBCC FREEPROCCACHE for a single query using SQL Handle or Plan Handle
DBCC FREEPROCCACHE (0x050007005D05B621303D11020200000001000000000000000000000000000000000000000000000000000000)

/*	****************************************************************************
****	Checking the Cached Parameters
*******************************************************************************/

SELECT databases.name,
 dm_exec_sql_text.text AS TSQL_Text,
 dm_exec_query_stats.creation_time, 
 dm_exec_query_stats.execution_count,
 dm_exec_query_plan.query_plan
FROM sys.dm_exec_query_stats 
CROSS APPLY sys.dm_exec_sql_text(dm_exec_query_stats.plan_handle)
CROSS APPLY sys.dm_exec_query_plan(dm_exec_query_stats.plan_handle)
INNER JOIN sys.databases
ON dm_exec_sql_text.dbid = databases.database_id
WHERE dm_exec_sql_text.text LIKE '%spGetSalesOrderDetailByModifiedDate%'

/*	****************************************************************************
****	Top Queries by CPU and IO
--	http://blog.sqlauthority.com/2014/07/29/sql-server-ssms-top-queries-by-cpu-and-io/
--	https://blogs.msdn.microsoft.com/seema/2008/10/09/xperf-a-cpu-sampler-for-silverlight/
--	Reports
	--	http://www.sqlshack.com/performance-dashboard-reports-sql-server-2014/

*******************************************************************************/


