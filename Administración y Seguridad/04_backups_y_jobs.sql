/*
   BIBLIOTECA - BACKUP, JOBS y RESTAURACIÓN
   Ejecutar después de 01_esquema_y_datos.sql.
*/
USE master;
GO
  
CREATE OR ALTER PROCEDURE dbo.usp_BackupBiblioteca
    @Tipo VARCHAR(4)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ruta NVARCHAR(260) = N'C:\Backups\BibliotecaDB\',
            @ts   CHAR(15)      = FORMAT(GETDATE(),'yyyyMMdd_HHmmss'),
            @arch NVARCHAR(400),
            @corte DATETIME     = DATEADD(DAY,-14,GETDATE());

    IF @Tipo = 'FULL'
    BEGIN
        SET @arch = @ruta + N'BibliotecaDB_FULL_' + @ts + N'.bak';
        BACKUP DATABASE BibliotecaDB TO DISK = @arch
            WITH COMPRESSION, CHECKSUM, STATS = 10;
        EXEC master.dbo.xp_delete_file 0, @ruta, N'bak', @corte;
    END
    ELSE IF @Tipo = 'DIFF'
    BEGIN
        SET @arch = @ruta + N'BibliotecaDB_DIFF_' + @ts + N'.bak';
        BACKUP DATABASE BibliotecaDB TO DISK = @arch
            WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, STATS = 10;
        EXEC master.dbo.xp_delete_file 0, @ruta, N'bak', @corte;
    END
    ELSE IF @Tipo = 'LOG'
    BEGIN
        SET @arch = @ruta + N'BibliotecaDB_LOG_' + @ts + N'.trn';
        BACKUP LOG BibliotecaDB TO DISK = @arch
            WITH COMPRESSION, CHECKSUM, STATS = 10;
        EXEC master.dbo.xp_delete_file 0, @ruta, N'trn', @corte;
    END
    ELSE
    BEGIN
        RAISERROR('Tipo inválido. Use FULL, DIFF o LOG.',16,1);
        RETURN;
    END

    RESTORE VERIFYONLY FROM DISK = @arch WITH CHECKSUM;
END;
GO

-- Backup FULL inicial
EXEC master.dbo.usp_BackupBiblioteca @Tipo = 'FULL';
GO

-- 4. JOBS EN SQL SERVER AGENT (idempotentes)
USE msdb;
GO
DECLARE @jobs TABLE (id INT IDENTITY, nombre SYSNAME, tipo VARCHAR(4),
                     freq_type INT, freq_interval INT,
                     subday_type INT, subday_interval INT, hora INT);
INSERT @jobs (nombre, tipo, freq_type, freq_interval, subday_type, subday_interval, hora) VALUES
 (N'Job_Backup_Full_Biblioteca','FULL', 8,   1, 1,  0,      0),
 (N'Job_Backup_Diff_Biblioteca','DIFF', 8, 126, 1,  0,  10000),
 (N'Job_Backup_Log_Biblioteca', 'LOG',  4,   1, 4, 15,      0);

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

    EXEC dbo.sp_add_job @job_name = @nom,
         @description = N'Backup automático de BibliotecaDB';
    EXEC dbo.sp_add_jobstep @job_name = @nom, @step_name = N'Ejecutar backup',
         @subsystem = N'TSQL', @database_name = N'master', @command = @cmd,
         @retry_attempts = 1, @retry_interval = 1;
    EXEC dbo.sp_add_schedule @schedule_name = @sch,
         @freq_type = @ft, @freq_interval = @fi,
         @freq_subday_type = @st, @freq_subday_interval = @si,
         @freq_recurrence_factor = 1, @active_start_time = @hr;
    EXEC dbo.sp_attach_schedule @job_name = @nom, @schedule_name = @sch;
    EXEC dbo.sp_add_jobserver @job_name = @nom;

    SET @i += 1;
END;
GO

-- Ejecutar los jobs para generar historial
EXEC dbo.sp_start_job N'Job_Backup_Full_Biblioteca';
WAITFOR DELAY '00:00:10';
EXEC dbo.sp_start_job N'Job_Backup_Diff_Biblioteca';
WAITFOR DELAY '00:00:10';
EXEC dbo.sp_start_job N'Job_Backup_Log_Biblioteca';
GO

-- Historial de ejecución de los jobs
SELECT j.name AS job, h.run_date, h.run_time, h.run_duration,
       CASE h.run_status WHEN 1 THEN 'Exitoso' WHEN 0 THEN 'Fallido' ELSE 'Otro' END AS estado
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.step_id = 0 AND j.name LIKE 'Job_Backup_%_Biblioteca'
ORDER BY h.run_date DESC, h.run_time DESC;
GO

-- 5. PRUEBA DE RESTAURACIÓN (FULL, DIFF y LOG)
USE master;
GO
  
-- 5.1 Generar cadena con cambios intermedios
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

-- 5.2 Restaurar como BibliotecaDB_Test y medir RTO 
USE master;
GO
DECLARE @inicio DATETIME2 = SYSDATETIME(),
        @full NVARCHAR(400), @diff NVARCHAR(400), @log NVARCHAR(400),
        @datos NVARCHAR(260) = CONVERT(NVARCHAR(260), SERVERPROPERTY('InstanceDefaultDataPath')),
        @logp  NVARCHAR(260) = CONVERT(NVARCHAR(260), SERVERPROPERTY('InstanceDefaultLogPath')),
        @sql NVARCHAR(MAX);
SELECT TOP 1 @full = mf.physical_device_name FROM msdb.dbo.backupset bs
  JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
  WHERE bs.database_name='BibliotecaDB' AND bs.type='D' ORDER BY bs.backup_finish_date DESC;
SELECT TOP 1 @diff = mf.physical_device_name FROM msdb.dbo.backupset bs
  JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
  WHERE bs.database_name='BibliotecaDB' AND bs.type='I' ORDER BY bs.backup_finish_date DESC;
SELECT TOP 1 @log  = mf.physical_device_name FROM msdb.dbo.backupset bs
  JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
  WHERE bs.database_name='BibliotecaDB' AND bs.type='L' ORDER BY bs.backup_finish_date DESC;

SET @sql = N'RESTORE DATABASE BibliotecaDB_Test FROM DISK=N''' + @full + N'''
  WITH MOVE N''BibliotecaDB''     TO N''' + @datos + N'BibliotecaDB_Test.mdf'',
       MOVE N''BibliotecaDB_log'' TO N''' + @logp  + N'BibliotecaDB_Test_log.ldf'',
       NORECOVERY, REPLACE, CHECKSUM;
  RESTORE DATABASE BibliotecaDB_Test FROM DISK=N''' + @diff + N''' WITH NORECOVERY, CHECKSUM;
  RESTORE LOG      BibliotecaDB_Test FROM DISK=N''' + @log  + N''' WITH RECOVERY,  CHECKSUM;';
EXEC sys.sp_executesql @sql;

SELECT DATEDIFF(SECOND, @inicio, SYSDATETIME()) AS RTO_real_segundos;
GO

-- 5.3 Verificación de integridad
SELECT 'Original' AS base, (SELECT COUNT(*) FROM BibliotecaDB.dbo.socios)      AS socios,
                           (SELECT COUNT(*) FROM BibliotecaDB.dbo.autores)     AS autores,
                           (SELECT COUNT(*) FROM BibliotecaDB.dbo.prestamos)   AS prestamos
UNION ALL
SELECT 'Restaurada',       (SELECT COUNT(*) FROM BibliotecaDB_Test.dbo.socios),
                           (SELECT COUNT(*) FROM BibliotecaDB_Test.dbo.autores),
                           (SELECT COUNT(*) FROM BibliotecaDB_Test.dbo.prestamos);
DBCC CHECKDB (BibliotecaDB_Test) WITH NO_INFOMSGS;
GO

-- 6. INTEGRACIÓN: CONSULTA DE CONTROL
SELECT bs.database_name, bs.backup_finish_date,
       CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' END AS tipo,
       CAST(bs.compressed_backup_size/1048576.0 AS DECIMAL(10,2)) AS MB, mf.physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
WHERE bs.database_name = 'BibliotecaDB'
ORDER BY bs.backup_finish_date DESC;
GO
