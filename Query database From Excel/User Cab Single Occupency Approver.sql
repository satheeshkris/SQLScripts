USE NeonCab
GO
--DROP PROCEDURE usp_setSingleOccupencyApprovals
--GO

CREATE PROCEDURE usp_setSingleOccupencyApprovals @ApprovalType CHAR(11), @Signum CHAR(8), @CabDate DATE, @DeferredDate DATE = NULL
	WITH EXECUTE AS OWNER
AS
BEGIN --Begin Proc
	/*	Created By:			AJAY DWIVEDI
		Created Date:		3rd July 2016
		Purpose:			To provide single occupency to user on particular date
	*/
	SET NOCOUNT ON;

	DECLARE @MessageTable TABLE (ID INT IDENTITY(1,1), [Message Type] VARCHAR(20), [Message Text] VARCHAR(200));
	DECLARE @ErrorOccurred TINYINT

	-- Validate inputs here
	IF NOT EXISTS (SELECT 1 FROM dbirtc.dbo.Employees E WHERE E.signum = @Signum)
	BEGIN
		INSERT INTO @MessageTable
		VALUES ('Error','Invalid Signum');

		SET @ErrorOccurred = 1;
		GOTO ProcEnd;
	END
	
	IF (@CabDate <= CAST(GETDATE() AS DATE))
	BEGIN
		INSERT INTO @MessageTable
		VALUES ('Error','Invalid Cab Date. Cab date should be greater than today''s date.');

		SET @ErrorOccurred = 1;
		GOTO ProcEnd;
	END 
	

	INSERT INTO @MessageTable
	VALUES ('Information', 'Checking single occupency approvals of '+(dbirtc.dbo.getName(@Signum))+' ('+@Signum+') for '+CAST(@CabDate AS VARCHAR(20)));

	SET @DeferredDate = ISNULL(@DeferredDate,@CabDate);

	IF (@ApprovalType='First Line')
	BEGIN
		UPDATE	dbo.Cab_SingleOccupancy_admin
		SET		approved	= 1
				,approvedOn = getdate()
				,approvalComment = 'Approval from Transport Team'
				,deferredDate = @DeferredDate
				,approvedBy = 'Transport'
		WHERE	APPROVED IS NULL
		AND		approvalType = 'First Line'
		AND		Signum = @Signum
		AND		dated = @CabDate -- CabDate is not today or back date

		IF (@@ROWCOUNT = 0)
		BEGIN
			INSERT INTO @MessageTable
			VALUES ('Error','No record found to update.');
			INSERT INTO @MessageTable
			VALUES ('Advice','Kindly check Cab status first.');
		END
		ELSE
		BEGIN
			INSERT INTO @MessageTable
			VALUES ('Success','Single Occupency first line approval has been provided till '+CAST(@DeferredDate AS VARCHAR(20)));
			INSERT INTO @MessageTable
			VALUES ('Advice','Kindly verify cab status once again.');
		END
	END
	IF (@ApprovalType='Second Line')
	BEGIN
		IF EXISTS (SELECT 1 FROM dbo.Cab_SingleOccupancy_admin A 
					WHERE A.Signum = @Signum AND dated = @CabDate AND approvalType = 'First Line' 
						AND (A.approved IS NULL OR A.approved = 0))
		BEGIN
			INSERT INTO @MessageTable
			VALUES ('Error','First line approval is either pending or not approved yet.');
			INSERT INTO @MessageTable
			VALUES ('Advice','Kindly check Cab status first.');
			GOTO ProcEnd;
		END

		UPDATE	dbo.Cab_SingleOccupancy_admin
		SET		approved	= 1
				,approvedOn = getdate()
				,approvalComment = 'Approval from Transport Team'
				,deferredDate = @DeferredDate
				,approvedBy = 'Transport'
		WHERE	APPROVED IS NULL
		AND		approvalType = 'Second Line'
		AND		Signum = @Signum
		AND		dated = @CabDate -- CabDate is not today or back date

		IF (@@ROWCOUNT = 0)
		BEGIN
			INSERT INTO @MessageTable
			VALUES ('Error','No record found to update.');
			INSERT INTO @MessageTable
			VALUES ('Advice','Kindly check Cab status first.');
		END
		ELSE
		BEGIN
			INSERT INTO @MessageTable
			VALUES ('Success','Single Occupency Second line approval has been provided till '+CAST(@DeferredDate AS VARCHAR(20)));
			INSERT INTO @MessageTable
			VALUES ('Advice','Kindly verify cab status once again.');
		END
	END

	ProcEnd:
	SELECT * FROM @MessageTable;
END