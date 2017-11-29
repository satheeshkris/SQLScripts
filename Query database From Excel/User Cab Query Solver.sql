USE [NeonCab]
GO

--DROP PROCEDURE [dbo].[usp_getCabStatus]
--GO

CREATE PROCEDURE [dbo].[usp_getCabStatus] @Signum CHAR(8), @Suspected_Date DATE = NULL
	WITH EXECUTE AS OWNER
AS
BEGIN --Begin Proc
	/*	Created By:			AJAY DWIVEDI
		Created Date:		1st July 2016
		Purpose:			To get user cab request status for particular date
	*/
	SET NOCOUNT ON;
	-- Create variables
	DECLARE @Ideal_General_approval_DateTime DATETIME2
			,@Ideal_SingleOccupency_approval_DateTime DATETIME2

			,@LatestApprovedCabRequestID_admin INT 
			,@CabRequestID_Roaster INT
			,@SingleOccupencyID_FirstLine INT
			,@SingleOccupencyID_SecondLine INT

			,@Approvedon DATETIME2
			,@Approvedon_FirstLine DATETIME2
			,@DeferredDate_FirstLine DATE
			,@Approvedon_SecondLine DATETIME2
			,@DeferredDate_SecondLine DATE
			,@ApprovalStatus_FirstLine VARCHAR(20)
			,@ApprovalStatus_SecondLine VARCHAR(20)
			,@mSignum_FirstLine CHAR(8)
			,@mSignum_SecondLine CHAR(8)

	DECLARE @CabStatusTable TABLE (ID INT IDENTITY(1,1),[Message Type] VARCHAR(20),[Message Text] VARCHAR(500))
	
	-- If no suspect date is provided, then set it to next working day
	SELECT  @Suspected_Date=ISNULL(@Suspected_Date,IIF(DATENAME(DW,GETDATE()) NOT IN('Friday','Saturday','Sunday'),DATEADD(DD,1,GETDATE()),DATEADD(DAY,(9-datepart(weekday,getdate())),GETDATE())))
	SELECT  @Ideal_General_approval_DateTime = IIF(datename(dw,@Suspected_Date)<>'Monday',DATEADD(DAY,-1,DATEADD(HOUR,16,CAST(@Suspected_Date AS DATETIME2))),DATEADD(DAY,-3,DATEADD(HOUR,16,CAST(@Suspected_Date AS DATETIME2))))
			,@Ideal_SingleOccupency_approval_DateTime = IIF(datename(dw,@Suspected_Date)<>'Monday',DATEADD(DAY,-1,DATEADD(HOUR,18,CAST(@Suspected_Date AS DATETIME2))),DATEADD(DAY,-3,DATEADD(HOUR,18,CAST(@Suspected_Date AS DATETIME2))))

	IF NOT EXISTS (SELECT 1 FROM dbirtc.dbo.Employees E WHERE E.signum = @Signum)
		THROW 51000, 'Invalid Signum.', 1;  

	INSERT INTO @CabStatusTable ([Message Type],[Message Text])
	VALUES ('Information', 'Getting cab request status of '+(dbirtc.dbo.getName(@Signum))+' ('+@Signum+') for '+CAST(@Suspected_Date AS VARCHAR(20)));

	IF OBJECT_ID('tempdb..#CabRequests') IS NOT NULL
		DROP TABLE #CabRequests;
	SELECT	ID, RequestType, Signum, mSignum, Name, Emailid, Pnumber, City, ReportingTime, DropTime, EffectiveDate, EndDate, SubmittedOn, Approved, Approvedon
	INTO	#CabRequests
	FROM	dbo.cab_request_admin 
	WHERE	signum = @Signum 
		AND	@Suspected_Date BETWEEN EffectiveDate AND EndDate;

	IF (@@ROWCOUNT=0)
		INSERT INTO @CabStatusTable ([Message Type],[Message Text])
		VALUES ('Issue', 'There is no general cab request in place covering suspected date');
	ELSE
	BEGIN --Begin : Check if general cab request exist for suspected date
		INSERT INTO @CabStatusTable ([Message Type],[Message Text])
		VALUES ('Information', 'A general cab request is in place covering suspected date');
 
		--	The lastest cab request is approved
		SELECT @LatestApprovedCabRequestID_admin = MAX(ID) FROM #CabRequests R1 WHERE R1.Approved = 1
		IF @LatestApprovedCabRequestID_admin IS NULL
			INSERT INTO @CabStatusTable ([Message Type],[Message Text])
			VALUES ('Issue', 'There is no approved general cab request covering suspected date');

		IF (SELECT MAX(ID) FROM #CabRequests)<>@LatestApprovedCabRequestID_admin
			INSERT INTO @CabStatusTable ([Message Type],[Message Text])
			VALUES ('Warning', 'Lastest general cab request of user is not approved.');

		SELECT @CabRequestID_Roaster = ID FROM dbo.cab_request r WHERE r.Refid = @LatestApprovedCabRequestID_admin;
		SELECT @Approvedon = Approvedon FROM #CabRequests R WHERE R.ID = @LatestApprovedCabRequestID_admin;

		IF (@Approvedon>=@Ideal_General_approval_DateTime)
			INSERT INTO @CabStatusTable ([Message Type],[Message Text])
			VALUES ('Issue', 'General cab request is not approved on time. '+'Approval time ('+cast(@Approvedon as varchar(20))+') has crossed the threshold time ('+cast(@Ideal_General_approval_DateTime as varchar(20))+')');
		ELSE
			INSERT INTO @CabStatusTable ([Message Type],[Message Text])
			VALUES ('Information', 'General approval is obtained on time prior to threshold time ('+cast(@Ideal_General_approval_DateTime as varchar(20))+')');


		IF OBJECT_ID('tempdb..#CabRequests_SingleOccupency') IS NOT NULL
			DROP TABLE #CabRequests_SingleOccupency	
		SELECT	*
		INTO	#CabRequests_SingleOccupency
		FROM	Cab_SingleOccupancy_admin AS S
		WHERE	S.reqID = @CabRequestID_Roaster
			AND @Suspected_Date = S.dated
			--AND	@Suspected_Date BETWEEN S.dated AND ISNULL(S.deferredDate,S.dated);
		
		IF(@@ROWCOUNT=0)
			INSERT INTO @CabStatusTable ([Message Type],[Message Text])
			VALUES ('Information', 'No single occupency is generated for suspected date');
		ELSE
		BEGIN -- Begin: Single occupency is generated for suspected date
			INSERT INTO @CabStatusTable ([Message Type],[Message Text])
			VALUES ('Information', 'Single occupency is generated for suspected date');

			SELECT	@SingleOccupencyID_FirstLine = ID, @Approvedon_FirstLine = ApprovedOn,
					@ApprovalStatus_FirstLine = IIF(Approved IS NULL,'Yet to Approve',IIF(Approved=0,'Rejected','Approved')), 
					@DeferredDate_FirstLine = deferredDate, @mSignum_FirstLine = mSignum
			FROM	#CabRequests_SingleOccupency S 
			WHERE	S.dated = @Suspected_Date AND S.approvalType = 'First Line';
			
			SELECT	@SingleOccupencyID_SecondLine = ID, @Approvedon_SecondLine = ApprovedOn, 
					@ApprovalStatus_SecondLine = IIF(Approved IS NULL,'Yet to Approve',IIF(Approved=0,'Rejected','Approved')), 
					@DeferredDate_SecondLine = deferredDate, @mSignum_SecondLine = mSignum
			FROM	#CabRequests_SingleOccupency S 
			WHERE	S.approvalType = 'Second Line' AND S.refID = @SingleOccupencyID_FirstLine;

			IF (@ApprovalStatus_FirstLine='Yet to Approve')
				INSERT INTO @CabStatusTable ([Message Type],[Message Text])
				VALUES ('Issue', 'Your single occupency first line approval is pending for suspected date')
					   ,('Advice','Kindly get First line approval with maximum Deferred Date');
			ELSE
			IF (@ApprovalStatus_FirstLine='Rejected')
				INSERT INTO @CabStatusTable ([Message Type],[Message Text])
				VALUES ('Issue', 'Your single occupency first line approval is rejected')
					  ,('Advice', 'Kindly get in touch with your grand manager ('+(dbirtc.dbo.getName(@mSignum_FirstLine))+')');
			ELSE
			IF ( (@ApprovalStatus_FirstLine='Approved') AND (@Approvedon_FirstLine >= @Ideal_SingleOccupency_approval_DateTime) )
				INSERT INTO @CabStatusTable ([Message Type],[Message Text])
				VALUES ('Issue', 'Your single occupency first line approval is not approved on time. '+'Approval time ('+CAST(@Approvedon_FirstLine AS VARCHAR(20))+') has crossed the threshold time ('+CAST(@Ideal_SingleOccupency_approval_DateTime AS VARCHAR(20))+') ');
			ELSE
			BEGIN
				INSERT INTO @CabStatusTable ([Message Type],[Message Text])
				VALUES ('Information', 'Your single occupency first line approval is obtained on time prior to threshold time ('+cast(@Ideal_SingleOccupency_approval_DateTime as varchar(20))+')')
				IF (DATEDIFF(DD,@Suspected_Date,@DeferredDate_FirstLine)=0)
					INSERT INTO @CabStatusTable ([Message Type],[Message Text])
					VALUES ('Advice', 'Next time, kindly get first line approval Deferred date set to maximum available date in order to avoid re-approvals')
			END

			IF (@ApprovalStatus_SecondLine IS NOT NULL)
			BEGIN --Begin: Check if 2nd line approval is obtained
				IF (@ApprovalStatus_SecondLine='Yet to Approve')
					INSERT INTO @CabStatusTable ([Message Type],[Message Text])
					VALUES ('Issue', 'Your single occupency Second line approval is pending for suspected date')
						  ,('Advice','Kindly get Second line approval with maximum Deferred Date');
				ELSE
				IF (@ApprovalStatus_SecondLine='Rejected')
				BEGIN
					INSERT INTO @CabStatusTable ([Message Type],[Message Text])
					VALUES ('Issue', 'Your single occupency Second line approval is rejected');
					INSERT INTO @CabStatusTable ([Message Type],[Message Text])
					VALUES ('Advice', 'Kindly get in touch with your grand manager ('+(dbirtc.dbo.getName(@mSignum_SecondLine))+')');
					
				END
				ELSE
				IF ( (@ApprovalStatus_SecondLine='Approved') AND (@Approvedon_SecondLine >= @Ideal_SingleOccupency_approval_DateTime) )
					INSERT INTO @CabStatusTable ([Message Type],[Message Text])
					VALUES ('Issue', 'Your single occupency Second line approval is not approved on time. '+'Approval time ('+CAST(@Approvedon_SecondLine AS VARCHAR(20))+') has crossed the threshold time ('+CAST(@Ideal_SingleOccupency_approval_DateTime AS VARCHAR(20))+') ');
				ELSE
				BEGIN
					print 'Suspected_Date: '+cast(@Suspected_Date as varchar(10));
					print 'Deferred_Date: '+cast(@DeferredDate_SecondLine as varchar(10));
					INSERT INTO @CabStatusTable ([Message Type],[Message Text])
					VALUES ('Information', 'Your single occupency Second line approval is obtained on time prior to threshold time ('+cast(@Ideal_SingleOccupency_approval_DateTime as varchar(20))+')');
					IF (DATEDIFF(DD,@Suspected_Date,@DeferredDate_SecondLine)=0)
						INSERT INTO @CabStatusTable ([Message Type],[Message Text])
						VALUES ('Advice', 'Next time, kindly get second line approval Deferred date set to maximum available date in order to avoid re-approvals')
				END
			END --End: Check if 2nd line approval is obtained
		END -- End: Single occupency is generated for suspected date
	END --End : Check if general cab request exist for suspected date

	IF NOT EXISTS (SELECT 1 FROM @CabStatusTable S WHERE S.[Message Type] = 'Issue')
		INSERT INTO @CabStatusTable ([Message Type],[Message Text])
		VALUES ('Conclusion', 'No issue found. So user should get a regular cab on suspected date.');

	SELECT * FROM @CabStatusTable;

END -- End proc
GO