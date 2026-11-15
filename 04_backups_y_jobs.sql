/*
   BIBLIOTECA - BACKUP, JOBS y RESTAURACIÓN (versión corregida)
   Ejecutar después de 01_esquema_y_datos.sql.
*/

-- 0. PRERREQUISITOS
USE master;
GO
EXEC master.dbo.xp_create_subdir N'C:\Backups\BibliotecaDB\';
GO
IF DATABASEPROPERTYEX('BibliotecaDB','Recovery') <> 'FULL'
    ALTER DATABASE BibliotecaDB SET RECOVERY FULL;
GO
-- Debe decir Running para SQL Server Agent
SELECT servicename, status_desc FROM sys.dm_server_services;
GO

/* ============================================================
   1. PROCEDIMIENTO DE BACKUP
   ============================================================ */
USE master;
GO
CREATE OR ALTER PROCEDURE dbo.usp_BackupBiblioteca
    @Tipo VARCHAR(4)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ruta NVARCHAR(260) = N'C:\Backups\BibliotecaDB\',
            @ts   CHAR(15)      = FORMAT(GETDATE(),'yyyyMMdd_HHmmss'),
            @arch NVARCHAR(400);

    IF @Tipo = 'FULL'
    BEGIN
        SET @arch = @ruta + N'BibliotecaDB_FULL_' + @ts + N'.bak';
        BACKUP DATABASE BibliotecaDB TO DISK = @arch
            WITH COMPRESSION, CHECKSUM, STATS = 10;
    END
    ELSE IF @Tipo = 'DIFF'
    BEGIN
        SET @arch = @ruta + N'BibliotecaDB_DIFF_' + @ts + N'.bak';
        BACKUP DATABASE BibliotecaDB TO DISK = @arch
            WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, STATS = 10;
    END
    ELSE IF @Tipo = 'LOG'
    BEGIN
        SET @arch = @ruta + N'BibliotecaDB_LOG_' + @ts + N'.trn';
        BACKUP LOG BibliotecaDB TO DISK = @arch
            WITH COMPRESSION, CHECKSUM, STATS = 10;
    END
    ELSE
    BEGIN
        RAISERROR('Tipo inválido. Use FULL, DIFF o LOG.',16,1);
        RETURN;
    END

    RESTORE VERIFYONLY FROM DISK = @arch WITH CHECKSUM;
END;
GO

-- Backup FULL inicial (base necesaria para LOG y DIFF)
EXEC master.dbo.usp_BackupBiblioteca @Tipo = 'FULL';
GO

/* ============================================================
   2. JOBS EN SQL SERVER AGENT
   ============================================================ */
USE msdb;
GO
DECLARE @jobs TABLE (id INT IDENTITY, nombre SYSNAME, tipo VARCHAR(4),
                     freq_type INT, freq_interval INT,
                     subday_type INT, subday_interval INT, hora INT);
INSERT @jobs (nombre, tipo, freq_type, freq_interval, subday_type, subday_interval, hora) VALUES
 (N'Job_Backup_Full_Biblioteca','FULL', 8,   1, 1,  0,      0),   -- domingo 00:00
 (N'Job_Backup_Diff_Biblioteca','DIFF', 8, 126, 1,  0,  10000),   -- lunes a sábado 01:00
 (N'Job_Backup_Log_Biblioteca', 'LOG',  4,   1, 4, 15,      0);   -- cada 15 minutos

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @jobs),
        @nom SYSNAME, @tipo VARCHAR(4), @ft INT, @fi INT, @st INT, @si INT, @hr INT,
        @cmd NVARCHAR(200), @sch SYSNAME;

WHILE @i <= @n
BEGIN
    SELECT @nom=nombre, @tipo=tipo, @ft=freq_type, @fi=freq_interval,
           @st=subday_type, @si=subday_interval, @hr=hora
    FROM @jobs WHERE id = @i;

    SET @cmd = N'EXEC master.dbo.usp_BackupBiblioteca @Tipo = ''' + @tipo + N''';';
    SET @sch = @nom + N'_Sch';

    IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = @nom)
        EXEC dbo.sp_delete_job @job_name = @nom, @delete_unused_schedule = 1;

    EXEC dbo.sp_add_job @job_name = @nom, @enabled = 0,
         @description = N'Backup automático de BibliotecaDB';
    EXEC dbo.sp_add_jobstep @job_name = @nom, @step_name = N'Ejecutar backup',
         @subsystem = N'TSQL', @database_name = N'master', @command = @cmd,
         @retry_attempts = 0, @retry_interval = 0;
    EXEC dbo.sp_add_schedule @schedule_name = @sch,
         @freq_type = @ft, @freq_interval = @fi,
         @freq_subday_type = @st, @freq_subday_interval = @si,
         @freq_recurrence_factor = 1, @active_start_time = @hr;
    EXEC dbo.sp_attach_schedule @job_name = @nom, @schedule_name = @sch;
    EXEC dbo.sp_add_jobserver @job_name = @nom;

    SET @i += 1;
END;
GO

--3. EJECUTAR LOS JOBS (esperando a que cada uno termine)
USE msdb;
GO
DECLARE @jobs TABLE (id INT IDENTITY, nombre SYSNAME);
INSERT @jobs (nombre) VALUES
  (N'Job_Backup_Full_Biblioteca'),
  (N'Job_Backup_Diff_Biblioteca'),
  (N'Job_Backup_Log_Biblioteca');

DECLARE @i INT = 1, @nom SYSNAME;
WHILE @i <= 3
BEGIN
    SELECT @nom = nombre FROM @jobs WHERE id = @i;

    EXEC dbo.sp_start_job @job_name = @nom;
    WAITFOR DELAY '00:00:03'; 

    WHILE EXISTS (
        SELECT 1
        FROM dbo.sysjobactivity ja
        JOIN dbo.sysjobs j ON j.job_id = ja.job_id
        WHERE j.name = @nom
          AND ja.session_id = (SELECT MAX(session_id) FROM dbo.syssessions)
          AND ja.start_execution_date IS NOT NULL
          AND ja.stop_execution_date  IS NULL)
        WAITFOR DELAY '00:00:02';

    SET @i += 1;
END;
GO

-- Historial de ejecución de los tres jobs
SELECT j.name AS job,
       msdb.dbo.agent_datetime(h.run_date, h.run_time) AS inicio,
       h.run_duration AS duracion_hhmmss,
       CASE h.run_status WHEN 1 THEN 'Exitoso' WHEN 0 THEN 'Fallido' ELSE 'Otro' END AS estado
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY instance_id DESC) AS rn
      FROM msdb.dbo.sysjobhistory
      WHERE step_id = 0) h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name LIKE 'Job_Backup_%_Biblioteca' AND h.rn = 1
ORDER BY j.name;
GO

/* Si algún job sale Fallido, este query muestra el motivo:
SELECT j.name, h.step_id, msdb.dbo.agent_datetime(h.run_date, h.run_time) AS cuando, h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.run_status = 0 AND j.name LIKE 'Job_Backup_%_Biblioteca'
ORDER BY h.instance_id DESC;
*/

-- 4. PRUEBA DE RESTAURACIÓN (FULL, DIFF y LOG)

-- 4.0 Eliminar la base de prueba si existe
USE master;
GO
IF DB_ID('BibliotecaDB_Test') IS NOT NULL
BEGIN
    IF (SELECT state_desc FROM sys.databases WHERE name = 'BibliotecaDB_Test') = 'ONLINE'
        ALTER DATABASE BibliotecaDB_Test SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BibliotecaDB_Test;
END
GO

-- 4.1 Cadena limpia: FULL -> María -> DIFF -> Julio -> LOG
EXEC master.dbo.usp_BackupBiblioteca @Tipo = 'FULL';
GO
USE BibliotecaDB;
INSERT dbo.socios (nombre, correo) VALUES ('María López','maria@mail.com');
GO
EXEC master.dbo.usp_BackupBiblioteca @Tipo = 'DIFF';
GO
USE BibliotecaDB;
INSERT dbo.autores (nombre_autor, nacionalidad) VALUES ('Julio Cortázar','Argentina');
GO
EXEC master.dbo.usp_BackupBiblioteca @Tipo = 'LOG';
GO

-- 4.2 Restaurar como BibliotecaDB_Test y medir RTO
USE master;
GO
DECLARE @inicio DATETIME2 = SYSDATETIME(),
        @full NVARCHAR(400), @diff NVARCHAR(400), @file NVARCHAR(400),
        @full_uuid UNIQUEIDENTIFIER, @full_fecha DATETIME, @diff_lsn NUMERIC(25,0),
        @lg_datos SYSNAME, @lg_log SYSNAME,
        @datos NVARCHAR(260) = CONVERT(NVARCHAR(260), SERVERPROPERTY('InstanceDefaultDataPath')),
        @logp  NVARCHAR(260) = CONVERT(NVARCHAR(260), SERVERPROPERTY('InstanceDefaultLogPath')),
        @sql NVARCHAR(MAX);

-- Rutas por defecto
IF @datos IS NULL
    SELECT @datos = LEFT(physical_name, LEN(physical_name) - CHARINDEX('\', REVERSE(physical_name)) + 1)
    FROM master.sys.database_files WHERE file_id = 1;
IF @logp IS NULL
    SELECT @logp = LEFT(physical_name, LEN(physical_name) - CHARINDEX('\', REVERSE(physical_name)) + 1)
    FROM master.sys.database_files WHERE file_id = 2;

-- Nombres lógicos tomados de la base original
SELECT @lg_datos = name FROM sys.master_files WHERE database_id = DB_ID('BibliotecaDB') AND type = 0;
SELECT @lg_log   = name FROM sys.master_files WHERE database_id = DB_ID('BibliotecaDB') AND type = 1;
-- FULL más reciente
SELECT TOP 1 @full = mf.physical_device_name, @full_uuid = bs.backup_set_uuid,
             @full_fecha = bs.backup_finish_date
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
WHERE bs.database_name = 'BibliotecaDB' AND bs.type = 'D'
ORDER BY bs.backup_finish_date DESC;
-- DIFF más reciente basado en ESE FULL
SELECT TOP 1 @diff = mf.physical_device_name, @diff_lsn = bs.last_lsn
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
WHERE bs.database_name = 'BibliotecaDB' AND bs.type = 'I'
  AND bs.differential_base_guid = @full_uuid
ORDER BY bs.backup_finish_date DESC;

IF @full IS NULL OR @diff IS NULL
BEGIN
    RAISERROR('No hay un DIFF basado en el FULL más reciente. Regenera la cadena (sección 4.1).',16,1);
    RETURN;
END

-- Restaurar FULL y DIFF
SET @sql = N'RESTORE DATABASE BibliotecaDB_Test FROM DISK=N''' + @full + N'''
  WITH MOVE N''' + @lg_datos + N''' TO N''' + @datos + N'BibliotecaDB_Test.mdf'',
       MOVE N''' + @lg_log   + N''' TO N''' + @logp  + N'BibliotecaDB_Test_log.ldf'',
       NORECOVERY, REPLACE, CHECKSUM;
  RESTORE DATABASE BibliotecaDB_Test FROM DISK=N''' + @diff + N''' WITH NORECOVERY, CHECKSUM;';
EXEC sys.sp_executesql @sql;

-- Aplicar TODOS los LOG posteriores al DIFF, en orden de LSN
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT mf.physical_device_name
    FROM msdb.dbo.backupset bs
    JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
    WHERE bs.database_name = 'BibliotecaDB' AND bs.type = 'L'
      AND bs.last_lsn > @diff_lsn
      AND bs.backup_finish_date >= @full_fecha
    ORDER BY bs.first_lsn;
OPEN c; FETCH NEXT FROM c INTO @file;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'RESTORE LOG BibliotecaDB_Test FROM DISK=N''' + @file + N''' WITH NORECOVERY, CHECKSUM;';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM c INTO @file;
END
CLOSE c; DEALLOCATE c;

-- Dejar la base disponible
RESTORE DATABASE BibliotecaDB_Test WITH RECOVERY;

-- Salida de la restauración y RTO
SELECT DATEDIFF(SECOND, @inicio, SYSDATETIME()) AS RTO_real_segundos;
GO

-- 4.3 Verificación de integridad
SELECT 'Original' AS base, (SELECT COUNT(*) FROM BibliotecaDB.dbo.socios)      AS socios,
                           (SELECT COUNT(*) FROM BibliotecaDB.dbo.autores)     AS autores,
                           (SELECT COUNT(*) FROM BibliotecaDB.dbo.prestamos)   AS prestamos
UNION ALL
SELECT 'Restaurada',       (SELECT COUNT(*) FROM BibliotecaDB_Test.dbo.socios),
                           (SELECT COUNT(*) FROM BibliotecaDB_Test.dbo.autores),
                           (SELECT COUNT(*) FROM BibliotecaDB_Test.dbo.prestamos);
GO

-- DBCC CHECKDB sin errores
DBCC CHECKDB (BibliotecaDB_Test) WITH NO_INFOMSGS;
SELECT 'CHECKDB sin errores' AS resultado;
GO

-- 5. CONSULTA DE CONTROL
SELECT TOP 15 bs.database_name, bs.backup_finish_date,
       CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' END AS tipo,
       CAST(bs.compressed_backup_size/1048576.0 AS DECIMAL(10,2)) AS MB, mf.physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
WHERE bs.database_name = 'BibliotecaDB'
ORDER BY bs.backup_finish_date DESC;
GO

--   6. HABILITAR LOS JOBS
USE msdb;
GO
EXEC dbo.sp_update_job @job_name = N'Job_Backup_Full_Biblioteca', @enabled = 1;
EXEC dbo.sp_update_job @job_name = N'Job_Backup_Diff_Biblioteca', @enabled = 1;
EXEC dbo.sp_update_job @job_name = N'Job_Backup_Log_Biblioteca',  @enabled = 1;
SELECT name, enabled FROM dbo.sysjobs WHERE name LIKE 'Job_Backup_%_Biblioteca';
GO
