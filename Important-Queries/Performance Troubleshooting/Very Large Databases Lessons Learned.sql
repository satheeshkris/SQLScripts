/*	Very Large Databases Lessons Learned
	--	https://www.youtube.com/watch?v=cN30SRgPkTk&t=1301s
	--	https://blogs.msdn.microsoft.com/sqlserverstorageengine/2007/01/24/checkdb-part-7-how-long-will-checkdb-take-to-run/
	--	https://msdn.microsoft.com/en-us/library/ms176064.aspx
	
1) What is very large database?
	-> VLDB is a database large enough that your standard DBA tasks need to change

2) Backup/Restore Tuning
	--	https://www.brentozar.com/archive/2014/01/improving-the-performance-of-backups/

	a) Timing
		i) Avoid schedule in duration of High Writes
		ii) Sometimes maintainence activities (checkdb, index rebuild) that cause high Read/Write create problem for backup. So schedule job when there are only Reads on database
	
	b) Backup Compression
		> compress compression cuts the backup time significantly. Came in SQL 2008

	c) Fast File Initialization
		> Will reduce the Restore time by significant amount of time
		> TLog was not considered in it by SQL Server

	d) Multiple Backup Files
		> Backup can be written to multiple files (64). More files means more resources (CPU/Memory) for backup activity, So faster backup. 

	--	http://dba.stackexchange.com/questions/128437/setting-buffercount-blocksize-and-maxtransfersize-for-backup-command
	e) BUFFERCOUNT
	f) MAXTRANSFERSIZE
	
3) IO Errors
	a)	823 - OS I/O operation failed (4 retries)
	b)	824	- OS I/O operation succeeded
			  SQL Server determined data is corrupt (4 retries)
	c)	825	- An 823/824 Error Occurred
			  BUT it succeeded in one of the retries
			  AND no error gets raised

4)	Integrity Checks
	These are slow in VLDSs
	a)	Primary Server
		DBCC CHECKDB <DB Name> WITH PHYSICAL_ONLY; -- get away without logical checks
	b)	Replica Server
		DBCC CHECKDB <DB Name>;

5)	Index Maintainence
	a) This also takes longer
	b) Determine true thresholds for Fragmentation
		Segregate Old/less frequently accessed data 
	c) Test Fragmentation before running maintainence jobs

6)	FileGroups
	a) More than 1 = a great idea
	b) Why?
		i) Tier data by performance
		ii) Backup performance
		iii) Restore performance
		iv) Partial Restores
		v) Read only filegroups
	c) Enforcing correct filegroup usage
	d) Moving data between filegroups
		a) Clustered Index/Non-clustered Index -- Rebuild
		b) Heap - Create clustered index/drop index
		c) LOB - 

7)	Restores
	a) Partial restore = good

8)	Partitioning
	a) Partitioned Table - Partition swapping for moving data in/out of system
	b) Partitioned View - tables with Check constraint, and view with UNION ALL of all underlying tables
	c) Really only good if you are always filtering on partition key
	d) May end being more work to merge results together from different partitions

9)	Data Compression
	a) Since 2008 - Compression both on disk & in Memory
	b) no cacheing of De-compressed data
	c) 2 flavors: Data & Page

10)	Statistics
	a) Bigger tables - less frequent automatic updates
	b) Trace Flag 2371 can fix this
	c) Run statistics more frequently 

11)	Parallelism
	a) Are you getting all the CPU you've paid for?
	b) Scaler UDF kill parallelism
		http://tinyurl.com/PaulWhiteParallelExecution
		http://sqlblog.com/blogs/paul_white/archive/2011/12/23/forcing-a-parallel-query-execution-plan.aspx
	c)  

12)	Security
	a) Roles
	b) Event Notifications - SELECT from a table/Delete/Update of data
	c) Auditing
	d) AD Notifications! - members added/removed in AD groups

13)	Read-Only Mode
	a) No concurrency issues
	b) stats stored in TempDB
	c) Disruptive to switch between RO & RW





*/
