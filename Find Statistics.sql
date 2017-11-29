SELECT stat.name AS 'Statistics',
 OBJECT_NAME(stat.object_id) AS 'Object',
 COL_NAME(scol.object_id, scol.column_id) AS 'Column'
FROM sys.stats AS stat (NOLOCK) Join sys.stats_columns AS scol (NOLOCK)
 ON stat.stats_id = scol.stats_id AND stat.object_id = scol.object_id
 INNER JOIN sys.tables AS tab (NOLOCK) on tab.object_id = stat.object_id
WHERE stat.name like '_WA%'
and  OBJECT_NAME(stat.object_id) = 'users'
ORDER BY stat.name

dbcc dropcleanbuffers
dbcc freeproccache