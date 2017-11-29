--	Begin: One-time code for execution
	-- 01) Create login [etransn]
	-- 02) Create user [etransn] for [NeonCab] db
/*
USE [master]
GO
CREATE LOGIN [etransn] WITH PASSWORD=N'transport@123', DEFAULT_DATABASE=[NeonCab], CHECK_EXPIRATION=OFF, CHECK_POLICY=ON
GO

USE [NeonCab]
GO
CREATE USER [etransn] FOR LOGIN [etransn]
GO
*/
--	End: One-time code for execution
--	====================================================================================================================

--	Begin: Code for cleansing
	-- 01) Drop certificate created in [NeonCab] db
	-- 02) Remove old certificate from backup path '\\10.184.57.22\NEON_UPLOAD_Docs\ranjeet\Certificate_getCabStatus.CER'
	-- 03) Drop login mapped to certificate prior to droppping certificate from master
	-- 04) Drop certificate created in [master] db
USE [NeonCab]
GO
DROP SIGNATURE FROM OBJECT::[usp_getCabStatus]
    BY CERTIFICATE [Certificate_NeonCab_Transport];  
GO 

USE [NeonCab]
GO
DROP SIGNATURE FROM OBJECT::[usp_setSingleOccupencyApprovals]
    BY CERTIFICATE [Certificate_NeonCab_Transport];  
GO 

USE [NeonCab]
GO
DROP CERTIFICATE [Certificate_NeonCab_Transport]
--DROP CERTIFICATE [Certificate_getCabStatus]
GO

--	Remove old certificate from backup path '\\10.184.57.22\NEON_UPLOAD_Docs\ranjeet\Certificate_getCabStatus.CER'
	--									or	'C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\Backup\Certificate_getCabStatus.CER';

USE master
GO
DROP LOGIN [Certificate_NeonCab_Transport] --[Certificate_getCabStatus]
--DROP LOGIN [Certificate_getCabStatus]
GO

USE master
GO
DROP CERTIFICATE [Certificate_NeonCab_Transport]-- [Certificate_getCabStatus]
--DROP CERTIFICATE [Certificate_getCabStatus]
GO
--	End: Code for cleansing
--	====================================================================================================================


--	!~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
--	Begin: Module signing for freshly created procedures [dbo].[usp_getCabStatus] & [dbo].[usp_setSingleOccupencyApprovals]
--	!~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
-- 01) Create procedure with option (EXECUTE AS OWNER)
-- 02) Create a certificate with a private key in the [NeonCab] database
-- 03) Sign the procedure with the private key of the certificate you created
-- 04) Drop the private key of the certificate (to prevent it from ever being used again)
-- 05) Copy the certificate into the master database
-- 06) Create a login (etransn) from the certificate
-- 07) Grant AUTHENTICATE SERVER to the certificate derived login
-- 08) Grant any additional priviledge required by the procedure (e.g. VIEW SERVER STATE) to the certificate derived login
-- 09) Grant EXECUTE permission to [etransn] for procedures [dbo].[usp_getCabStatus] & [dbo].[usp_setSingleOccupencyApprovals]

USE [NeonCab]
GO
CREATE CERTIFICATE [Certificate_NeonCab_Transport]
ENCRYPTION BY PASSWORD = 'Pa$$w0rd'
WITH SUBJECT = 'Transport Signing certificate';
GO

USE [NeonCab]
GO
ADD SIGNATURE TO OBJECT::[usp_getCabStatus]
BY CERTIFICATE [Certificate_NeonCab_Transport]
WITH PASSWORD = 'Pa$$w0rd';
GO --	The module being signed is marked to execute as owner. If the owner changes the signature will not be valid.

USE [NeonCab]
GO
ADD SIGNATURE TO OBJECT::[usp_setSingleOccupencyApprovals]
BY CERTIFICATE [Certificate_NeonCab_Transport]
WITH PASSWORD = 'Pa$$w0rd';
GO --	The module being signed is marked to execute as owner. If the owner changes the signature will not be valid.

-- Remove Private key only incase you don't need to add another procedure or functionality like this again
/*
USE [NeonCab]
GO
ALTER CERTIFICATE [Certificate_NeonCab_Transport]
REMOVE PRIVATE KEY;
GO
*/
USE [NeonCab]
GO
BACKUP CERTIFICATE [Certificate_NeonCab_Transport]
TO FILE = '\\10.184.57.22\NEON_UPLOAD_Docs\ranjeet\Certificate_NeonCab_Transport.CER';
--TO FILE = 'C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\Backup\Certificate_NeonCab_Transport.CER';
GO

USE master
GO
CREATE CERTIFICATE [Certificate_NeonCab_Transport]
FROM FILE = '\\10.184.57.22\NEON_UPLOAD_Docs\ranjeet\Certificate_NeonCab_Transport.CER';
GO

USE master
GO
CREATE LOGIN [Certificate_NeonCab_Transport]
FROM CERTIFICATE [Certificate_NeonCab_Transport];
GO

USE master
GO
GRANT AUTHENTICATE SERVER TO [Certificate_NeonCab_Transport];
GO

USE NeonCab
GO
GRANT EXECUTE ON dbo.usp_getCabStatus to [ETRANSN]
GO
GRANT EXECUTE ON dbo.usp_setSingleOccupencyApprovals to [ETRANSN]
GO

------------------------------------------------------

EXEC neoncab.dbo.usp_getCabStatus @Signum = 'EVIKWAT'
	,@Suspected_Date = '2016-07-04'

------------------------------------------------------
	

