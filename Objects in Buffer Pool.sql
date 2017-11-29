SELECT	OBJECT_NAME(P.object_id) AS TABLE_NAME, COUNT(1) AS Page_Counts
FROM	sys.dm_os_buffer_descriptors AS BP
JOIN	sys.allocation_units AS ALC
	ON	ALC.allocation_unit_id = BP.allocation_unit_id
JOIN	sys.partitions AS P
	ON	P.partition_id = ALC.container_id
JOIN	sys.objects AS OBJ
	ON	OBJ.object_id = P.object_id
WHERE	database_id = DB_ID()
	AND	OBJ.type_desc = 'USER_TABLE'
GROUP BY OBJECT_NAME(P.object_id)
ORDER BY Page_Counts DESC


