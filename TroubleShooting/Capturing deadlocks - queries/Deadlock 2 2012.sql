/* 
--In a second session, start Query #2 
--It will be blocked 
*/

/* 
Query #2: 
*/

USE AdventureWorks2012; 
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE 

--SET DEADLOCK_PRIORITY HIGH 
SELECT BusinessEntityID, FirstName, MiddleName, LastName 
FROM Person.Person 
WHERE LastName=N'Evans' 
ORDER BY BusinessEntityID; 
GO 

/*
Go back to Deadlock query 1.sql to finish 
*/