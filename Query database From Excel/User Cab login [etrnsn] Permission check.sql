PRINT 'Server Name: '+ CAST(CONNECTIONPROPERTY('local_net_address') AS VARCHAR(20))
PRINT 'Database: '+ DB_NAME()
PRINT 'Login: '+ SUSER_SNAME()
PRINT ''
-- Check security for above login in context of above server & database
SELECT * FROM DBIRTC.dbo.Employees
GO
SELECT * FROM NeonCab.dbo.Cab_Request_Admin
GO


EXEC neoncab.dbo.usp_getCabStatus @Signum = 'EVIKWAT'
	,@Suspected_Date = '2016-07-04'
EXEC neoncab.dbo.usp_setSingleOccupencyApprovals @Signum = 'EVIKWAT', @CabDate = '2016-07-04', @ApprovalType='First Line'
	,@DeferredDate = '2016-07-04'
