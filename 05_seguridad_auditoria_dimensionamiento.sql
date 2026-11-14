\xef\xbb\xbf/*
   PROYECTO DE CÁTEDRA - INTEGRANTE 2
   SEGURIDAD, ESQUEMAS, AUDITORÍA Y DIMENSIONAMIENTO

   Ejecutar DESPUÉS de 01, 02, 03 y 04. Ejecutar sección por sección (seleccionar y F5).

   OJO: hoy la base es BibliotecaDB. Cuando el Integrante 1 entregue las tablas del
   gimnasio, solo hay que cambiar los nombres en 3 lugares:
     - 05.1  tabla @mapa (tabla -> esquema)
     - 05.3  nombres de procedimientos y vistas en los GRANT
     - 05.7  tabla @crec (crecimiento de filas por mes)
*/

/* ============================================================
   05.0  CARPETAS (SQL Server en Linux: se crean con mkdir en Ubuntu)
   ============================================================ */
USE master;
GO
-- SQL Server en Linux: crear las carpetas desde la terminal de Ubuntu (ver instrucciones), no desde T-SQL.
GO

/* ============================================================
   05.1  ESQUEMAS
   Catalogo     : datos maestros de libros (consulta frecuente, cambio poco frecuente)
   Circulacion  : operación diaria (préstamos y devoluciones)
   Finanzas     : dinero (multas) -> acceso muy restringido
   Personas     : datos personales (socios, empleados) -> datos sensibles
   Reportes     : vistas para Power BI (solo lectura)
   Todos con AUTHORIZATION dbo para mantener la cadena de propiedad (ownership chaining):
   así un usuario con EXECUTE sobre un procedimiento no necesita permisos directos sobre las tablas.
   ============================================================ */
USE BibliotecaDB;
GO
IF SCHEMA_ID(N'Catalogo')    IS NULL EXEC (N'CREATE SCHEMA Catalogo    AUTHORIZATION dbo');
IF SCHEMA_ID(N'Circulacion') IS NULL EXEC (N'CREATE SCHEMA Circulacion AUTHORIZATION dbo');
IF SCHEMA_ID(N'Finanzas')    IS NULL EXEC (N'CREATE SCHEMA Finanzas    AUTHORIZATION dbo');
IF SCHEMA_ID(N'Personas')    IS NULL EXEC (N'CREATE SCHEMA Personas    AUTHORIZATION dbo');
IF SCHEMA_ID(N'Reportes')    IS NULL EXEC (N'CREATE SCHEMA Reportes    AUTHORIZATION dbo');
GO

-- Mover las tablas a su esquema + sinónimo en dbo para que los scripts 02/03/04 sigan funcionando
DECLARE @mapa TABLE (tabla SYSNAME, esquema SYSNAME);
INSERT @mapa VALUES
 (N'autores',N'Catalogo'),(N'editoriales',N'Catalogo'),(N'categorias',N'Catalogo'),
 (N'libros',N'Catalogo'),(N'libro_autor',N'Catalogo'),(N'ejemplares',N'Catalogo'),
 (N'prestamos',N'Circulacion'),(N'devoluciones',N'Circulacion'),
 (N'multas',N'Finanzas'),
 (N'socios',N'Personas'),(N'empleados',N'Personas');

DECLARE @t SYSNAME, @e SYSNAME, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT tabla, esquema FROM @mapa;
OPEN c;
FETCH NEXT FROM c INTO @t, @e;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(N'dbo.' + QUOTENAME(@t), N'U') IS NOT NULL
    BEGIN
        SET @sql = N'ALTER SCHEMA ' + QUOTENAME(@e) + N' TRANSFER dbo.' + QUOTENAME(@t) + N';';
        EXEC sys.sp_executesql @sql;
    END;
    IF OBJECT_ID(N'dbo.' + QUOTENAME(@t)) IS NULL
    BEGIN
        SET @sql = N'CREATE SYNONYM dbo.' + QUOTENAME(@t) + N' FOR ' + QUOTENAME(@e) + N'.' + QUOTENAME(@t) + N';';
        EXEC sys.sp_executesql @sql;
    END;
    FETCH NEXT FROM c INTO @t, @e;
END;
CLOSE c; DEALLOCATE c;
GO

-- Evidencia: qué tabla quedó en qué esquema
SELECT s.name AS esquema, t.name AS tabla
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
ORDER BY s.name, t.name;
GO

/* ============================================================
   05.2  LOGINS, USUARIOS Y ROLES
   Cambiar las contraseñas antes de usarlas y NO subirlas a GitHub.
   Requiere modo de autenticación mixto para conectarse con estos logins.
   ============================================================ */
USE BibliotecaDB;
GO
DECLARE @cuentas TABLE (lg SYSNAME, pwd NVARCHAR(128), usr SYSNAME, rol SYSNAME);
INSERT @cuentas VALUES
 (N'lg_atencion',    N'Cambiar#Atencion2026',  N'u_atencion',    N'rol_atencion'),
 (N'lg_catalogador', N'Cambiar#Catalogo2026',  N'u_catalogador', N'rol_catalogacion'),
 (N'lg_finanzas',    N'Cambiar#Finanzas2026',  N'u_finanzas',    N'rol_finanzas'),
 (N'lg_reportes',    N'Cambiar#Reportes2026',  N'u_reportes',    N'rol_reportes'),
 (N'lg_admin_bd',    N'Cambiar#AdminBD2026',   N'u_admin_bd',    N'rol_admin_biblioteca');

DECLARE @lg SYSNAME, @pwd NVARCHAR(128), @usr SYSNAME, @rol SYSNAME, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT lg, pwd, usr, rol FROM @cuentas;
OPEN c;
FETCH NEXT FROM c INTO @lg, @pwd, @usr, @rol;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- Login (nivel servidor)
    IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @lg)
    BEGIN
        SET @sql = N'CREATE LOGIN ' + QUOTENAME(@lg) + N' WITH PASSWORD = ' + QUOTENAME(@pwd, '''')
                 + N', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = BibliotecaDB;';
        EXEC sys.sp_executesql @sql;
    END;
    -- Usuario (nivel base de datos)
    IF DATABASE_PRINCIPAL_ID(@usr) IS NULL
    BEGIN
        SET @sql = N'CREATE USER ' + QUOTENAME(@usr) + N' FOR LOGIN ' + QUOTENAME(@lg) + N';';
        EXEC sys.sp_executesql @sql;
    END;
    -- Rol por función
    IF DATABASE_PRINCIPAL_ID(@rol) IS NULL
    BEGIN
        SET @sql = N'CREATE ROLE ' + QUOTENAME(@rol) + N' AUTHORIZATION dbo;';
        EXEC sys.sp_executesql @sql;
    END;
    SET @sql = N'ALTER ROLE ' + QUOTENAME(@rol) + N' ADD MEMBER ' + QUOTENAME(@usr) + N';';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM c INTO @lg, @pwd, @usr, @rol;
END;
CLOSE c; DEALLOCATE c;
GO

/* ============================================================
   05.3  PERMISOS (mínimo privilegio)
   Idea: los roles operativos NO tocan tablas directamente; usan procedimientos y vistas.
   ============================================================ */
USE BibliotecaDB;
GO
-- ---- rol_atencion: mostrador (préstamos, devoluciones, altas de socios)
GRANT SELECT  ON SCHEMA::Catalogo TO rol_atencion;
GRANT EXECUTE ON OBJECT::dbo.procesar_prestamo        TO rol_atencion;
GRANT EXECUTE ON OBJECT::dbo.sp_registrar_devolucion  TO rol_atencion;
GRANT EXECUTE ON OBJECT::dbo.sp_renovar_prestamo      TO rol_atencion;
GRANT EXECUTE ON OBJECT::dbo.sp_registrar_socio       TO rol_atencion;
GRANT SELECT  ON OBJECT::dbo.v_libros_disponibles     TO rol_atencion;
GRANT SELECT  ON OBJECT::dbo.v_historial_prestamos    TO rol_atencion;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::Finanzas TO rol_atencion;
DENY  SELECT ON OBJECT::Personas.empleados            TO rol_atencion;

-- ---- rol_catalogacion: altas y cambios del catálogo, sin borrar
GRANT SELECT, INSERT, UPDATE ON SCHEMA::Catalogo      TO rol_catalogacion;
DENY  DELETE ON SCHEMA::Catalogo                      TO rol_catalogacion;
GRANT EXECUTE ON OBJECT::dbo.sp_cambiar_estado_ejemplar TO rol_catalogacion;
GRANT SELECT  ON OBJECT::dbo.v_libros_disponibles     TO rol_catalogacion;
GRANT SELECT  ON OBJECT::dbo.v_estadisticas_libros    TO rol_catalogacion;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::Finanzas  TO rol_catalogacion;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::Personas  TO rol_catalogacion;

-- ---- rol_finanzas: lee multas y las cobra solo mediante el procedimiento
GRANT SELECT  ON SCHEMA::Finanzas                     TO rol_finanzas;
DENY  INSERT, UPDATE, DELETE ON SCHEMA::Finanzas      TO rol_finanzas;
GRANT EXECUTE ON OBJECT::dbo.sp_pagar_multa           TO rol_finanzas;
GRANT SELECT  ON OBJECT::dbo.v_multas_pendientes_detalle TO rol_finanzas;
GRANT SELECT  ON OBJECT::dbo.v_socios_morosos         TO rol_finanzas;
DENY  SELECT  ON OBJECT::Personas.empleados           TO rol_finanzas;

-- ---- rol_reportes: usuario de Power BI, solo vistas
GRANT SELECT  ON SCHEMA::Reportes                     TO rol_reportes;
GRANT SELECT  ON OBJECT::dbo.v_libros_disponibles        TO rol_reportes;
GRANT SELECT  ON OBJECT::dbo.v_socios_morosos            TO rol_reportes;
GRANT SELECT  ON OBJECT::dbo.v_historial_prestamos       TO rol_reportes;
GRANT SELECT  ON OBJECT::dbo.v_estadisticas_libros       TO rol_reportes;
GRANT SELECT  ON OBJECT::dbo.v_multas_pendientes_detalle TO rol_reportes;
DENY  INSERT, UPDATE, DELETE ON SCHEMA::Catalogo      TO rol_reportes;
DENY  INSERT, UPDATE, DELETE ON SCHEMA::Circulacion   TO rol_reportes;
DENY  INSERT, UPDATE, DELETE ON SCHEMA::Finanzas      TO rol_reportes;
DENY  INSERT, UPDATE, DELETE ON SCHEMA::Personas      TO rol_reportes;

-- ---- rol_admin_biblioteca: administra la BD sin ser sysadmin
GRANT CONTROL ON SCHEMA::dbo         TO rol_admin_biblioteca;
GRANT CONTROL ON SCHEMA::Catalogo    TO rol_admin_biblioteca;
GRANT CONTROL ON SCHEMA::Circulacion TO rol_admin_biblioteca;
GRANT CONTROL ON SCHEMA::Finanzas    TO rol_admin_biblioteca;
GRANT CONTROL ON SCHEMA::Personas    TO rol_admin_biblioteca;
GRANT CONTROL ON SCHEMA::Reportes    TO rol_admin_biblioteca;
GRANT CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE FUNCTION TO rol_admin_biblioteca;
GRANT BACKUP DATABASE, BACKUP LOG, VIEW DEFINITION TO rol_admin_biblioteca;
GO

/* ============================================================
   05.4  PRUEBAS DE SEGURIDAD (tomar captura)
   Cada prueba usa WHERE 1=0 para no modificar datos.
   ============================================================ */
USE BibliotecaDB;
GO
-- u_atencion: puede leer catálogo, NO puede leer multas
EXECUTE AS USER = N'u_atencion';
    SELECT USER_NAME() AS usuario_actual;
    SELECT TOP (3) isbn, titulo FROM Catalogo.libros;
    BEGIN TRY SELECT TOP (3) * FROM Finanzas.multas; END TRY
    BEGIN CATCH PRINT N'DENEGADO (esperado) u_atencion -> Finanzas.multas: ' + ERROR_MESSAGE(); END CATCH;
REVERT;
GO
-- u_catalogador: puede actualizar libros, NO puede borrar autores ni ver socios
EXECUTE AS USER = N'u_catalogador';
    SELECT USER_NAME() AS usuario_actual;
    UPDATE Catalogo.libros SET titulo = titulo WHERE 1 = 0;
    BEGIN TRY DELETE FROM Catalogo.autores WHERE 1 = 0; END TRY
    BEGIN CATCH PRINT N'DENEGADO (esperado) u_catalogador -> DELETE autores: ' + ERROR_MESSAGE(); END CATCH;
    BEGIN TRY SELECT TOP (1) * FROM Personas.socios; END TRY
    BEGIN CATCH PRINT N'DENEGADO (esperado) u_catalogador -> Personas.socios: ' + ERROR_MESSAGE(); END CATCH;
REVERT;
GO
-- u_finanzas: puede leer multas y la vista, NO puede modificar multas directamente
EXECUTE AS USER = N'u_finanzas';
    SELECT USER_NAME() AS usuario_actual;
    SELECT COUNT(*) AS multas_pendientes FROM dbo.v_multas_pendientes_detalle;
    BEGIN TRY UPDATE Finanzas.multas SET monto = monto WHERE 1 = 0; END TRY
    BEGIN CATCH PRINT N'DENEGADO (esperado) u_finanzas -> UPDATE multas: ' + ERROR_MESSAGE(); END CATCH;
REVERT;
GO
-- u_reportes (Power BI): solo vistas
EXECUTE AS USER = N'u_reportes';
    SELECT USER_NAME() AS usuario_actual;
    SELECT COUNT(*) AS filas_vista FROM dbo.v_estadisticas_libros;
    BEGIN TRY SELECT TOP (1) * FROM Catalogo.libros; END TRY
    BEGIN CATCH PRINT N'DENEGADO (esperado) u_reportes -> Catalogo.libros: ' + ERROR_MESSAGE(); END CATCH;
REVERT;
GO

-- Matriz de permisos (evidencia para el informe)
SELECT dp.name AS rol_o_usuario,
       p.state_desc AS estado,
       p.permission_name AS permiso,
       p.class_desc AS clase,
       CASE p.class WHEN 3 THEN SCHEMA_NAME(p.major_id)
                    WHEN 1 THEN SCHEMA_NAME(o.schema_id) + N'.' + o.name END AS objeto
FROM sys.database_permissions p
JOIN sys.database_principals dp ON dp.principal_id = p.grantee_principal_id
LEFT JOIN sys.objects o ON p.class = 1 AND o.object_id = p.major_id
WHERE dp.name LIKE N'rol[_]%'
ORDER BY dp.name, p.state_desc, objeto;

-- Membresías (usuario -> rol)
SELECT r.name AS rol, m.name AS usuario
FROM sys.database_role_members rm
JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
WHERE r.name LIKE N'rol[_]%'
ORDER BY r.name;
GO

/* ============================================================
   05.5  AUDITORÍA (SQL Server Audit)
   ============================================================ */
-- Limpieza para poder re-ejecutar
USE BibliotecaDB;
GO
IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = N'spec_db_Biblioteca')
BEGIN
    ALTER DATABASE AUDIT SPECIFICATION spec_db_Biblioteca WITH (STATE = OFF);
    DROP DATABASE AUDIT SPECIFICATION spec_db_Biblioteca;
END;
GO
USE master;
GO
IF EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = N'spec_srv_Biblioteca')
BEGIN
    ALTER SERVER AUDIT SPECIFICATION spec_srv_Biblioteca WITH (STATE = OFF);
    DROP SERVER AUDIT SPECIFICATION spec_srv_Biblioteca;
END;
IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = N'aud_Biblioteca')
BEGIN
    ALTER SERVER AUDIT aud_Biblioteca WITH (STATE = OFF);
    DROP SERVER AUDIT aud_Biblioteca;
END;
GO

-- 5.1 Destino de la auditoría: archivo
CREATE SERVER AUDIT aud_Biblioteca
TO FILE (FILEPATH = N'/var/opt/mssql/audit/BibliotecaDB/', MAXSIZE = 20 MB, MAX_ROLLOVER_FILES = 10, RESERVE_DISK_SPACE = OFF)
WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);
GO

-- 5.2 Especificación a nivel servidor: accesos y cambios de seguridad
CREATE SERVER AUDIT SPECIFICATION spec_srv_Biblioteca
FOR SERVER AUDIT aud_Biblioteca
    ADD (FAILED_LOGIN_GROUP),
    ADD (LOGIN_CHANGE_PASSWORD_GROUP),
    ADD (SERVER_PRINCIPAL_CHANGE_GROUP),
    ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP)
    -- , ADD (SUCCESSFUL_LOGIN_GROUP)   -- muy ruidoso (incluye SQL Agent); activar solo para demostrar
WITH (STATE = ON);
GO
ALTER SERVER AUDIT aud_Biblioteca WITH (STATE = ON);
GO

-- 5.3 Especificación a nivel base de datos: cambios de datos, datos sensibles y cambios de seguridad/estructura
USE BibliotecaDB;
GO
CREATE DATABASE AUDIT SPECIFICATION spec_db_Biblioteca
FOR SERVER AUDIT aud_Biblioteca
    ADD (INSERT, UPDATE, DELETE ON SCHEMA::Circulacion BY public),
    ADD (INSERT, UPDATE, DELETE ON SCHEMA::Finanzas    BY public),
    ADD (INSERT, UPDATE, DELETE ON SCHEMA::Personas    BY public),
    ADD (SELECT ON OBJECT::Personas.empleados BY public),
    ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
    ADD (SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP),
    ADD (SCHEMA_OBJECT_CHANGE_GROUP)
WITH (STATE = ON);
GO

/* ============================================================
   05.6  GENERAR ACTIVIDAD Y CONSULTAR LOS LOGS (tomar captura)
   ============================================================ */
USE BibliotecaDB;
GO
-- Cambios "neutros" (no alteran valores) hechos por el administrador
UPDATE Finanzas.multas SET monto = monto WHERE id_multa = (SELECT MIN(id_multa) FROM Finanzas.multas);
UPDATE Personas.socios SET nombre = nombre WHERE id_socio = 1;
SELECT TOP (1) * FROM Personas.empleados;
-- Cambio de membresía de rol (queda auditado)
ALTER ROLE rol_reportes DROP MEMBER u_reportes;
ALTER ROLE rol_reportes ADD MEMBER u_reportes;
GO
-- Intento NO autorizado (queda auditado con succeeded = 0)
EXECUTE AS USER = N'u_finanzas';
    BEGIN TRY SELECT TOP (1) * FROM Personas.empleados; END TRY
    BEGIN CATCH PRINT N'DENEGADO (esperado): ' + ERROR_MESSAGE(); END CATCH;
REVERT;
GO
/* Login fallido: en SSMS, File > Connect Object Explorer, usar lg_atencion con una
   contraseña incorrecta. Luego volver aquí y ejecutar la consulta de abajo. */
WAITFOR DELAY '00:00:03';   -- da tiempo a que se escriba el archivo
GO

-- LECTURA DE LOS LOGS
SELECT event_time, action_id, succeeded,
       server_principal_name, database_principal_name,
       schema_name, object_name, LEFT(statement, 150) AS sentencia
FROM sys.fn_get_audit_file(N'/var/opt/mssql/audit/BibliotecaDB/*.sqlaudit', DEFAULT, DEFAULT)
ORDER BY event_time DESC;
GO
-- Resumen por acción
SELECT action_id, succeeded, COUNT(*) AS eventos
FROM sys.fn_get_audit_file(N'/var/opt/mssql/audit/BibliotecaDB/*.sqlaudit', DEFAULT, DEFAULT)
GROUP BY action_id, succeeded
ORDER BY eventos DESC;
GO

/* ============================================================
   05.7  DIMENSIONAMIENTO
   Método: tamaño de fila (fórmula de Microsoft) -> filas por página (8 096 B útiles)
           -> páginas -> KB; luego factor por índices y holgura.
   Para validar el modelo: poner @meses = 0 y comparar con la consulta 7.1 (tamaño real).
   ============================================================ */
USE BibliotecaDB;
GO
-- 7.1 Tamaño REAL actual por tabla (datos vs índices)
SELECT s.name AS esquema, t.name AS tabla,
       ISNULL(SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count END), 0)              AS filas,
       CAST(ISNULL(SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.used_page_count END), 0) * 8.0 AS DECIMAL(12,2)) AS datos_KB,
       CAST(ISNULL(SUM(CASE WHEN ps.index_id > 1      THEN ps.used_page_count END), 0) * 8.0 AS DECIMAL(12,2)) AS indices_KB
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.dm_db_partition_stats ps ON ps.object_id = t.object_id
GROUP BY s.name, t.name
ORDER BY s.name, t.name;
GO

-- 7.2 ESTIMACIÓN con proyección de crecimiento (ejecutar todo este bloque junto)
DECLARE @meses        INT          = 36;    -- horizonte de proyección
DECLARE @pct_var      DECIMAL(4,2) = 0.60;  -- ocupación promedio de columnas variables (60 % del máximo)
DECLARE @len_max      INT          = 200;   -- bytes asumidos para columnas MAX
DECLARE @holgura      DECIMAL(4,2) = 1.25;  -- 25 % extra por fragmentación y crecimiento

DECLARE @crec TABLE (tabla SYSNAME PRIMARY KEY, filas_por_mes INT);
INSERT @crec VALUES
 (N'socios',20),(N'prestamos',300),(N'devoluciones',280),(N'multas',40),(N'ejemplares',10),
 (N'libros',5),(N'libro_autor',5),(N'autores',3),(N'editoriales',1),(N'categorias',0),(N'empleados',0);

IF OBJECT_ID('tempdb..#dim') IS NOT NULL DROP TABLE #dim;
IF OBJECT_ID('tempdb..#idx') IS NOT NULL DROP TABLE #idx;

-- Tamaño de fila por tabla
;WITH cols AS (
    SELECT t.object_id, s.name AS esquema, t.name AS tabla, c.max_length,
           CASE WHEN c.system_type_id IN (167,231,165) THEN 1 ELSE 0 END AS es_var,
           CASE WHEN c.system_type_id = 104 THEN 1 ELSE 0 END            AS es_bit
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    JOIN sys.columns c ON c.object_id = t.object_id
), res AS (
    SELECT object_id, esquema, tabla,
           COUNT(*) AS n_cols,
           SUM(CASE WHEN es_var = 0 AND es_bit = 0 THEN max_length ELSE 0 END) + CEILING(SUM(es_bit) / 8.0) AS fijo_bytes,
           SUM(es_var) AS n_var,
           SUM(CASE WHEN es_var = 1 THEN (CASE WHEN max_length = -1 THEN @len_max ELSE max_length * @pct_var END) ELSE 0 END) AS var_prom_bytes
    FROM cols GROUP BY object_id, esquema, tabla
), fila AS (
    SELECT r.*,
           2 + ((n_cols + 7) / 8) AS null_bitmap,
           CASE WHEN n_var > 0 THEN 2 + (n_var * 2) + var_prom_bytes ELSE 0 END AS var_bytes
    FROM res r
), tam AS (
    SELECT f.*, f.fijo_bytes + f.var_bytes + f.null_bitmap + 4 AS bytes_fila   -- +4 = encabezado de fila
    FROM fila f
)
SELECT x.esquema, x.tabla, x.object_id, x.n_cols, x.fijo_bytes, x.n_var, x.var_bytes, x.null_bitmap, x.bytes_fila,
       FLOOR(8096.0 / (x.bytes_fila + 2)) AS filas_por_pagina,                  -- +2 = ranura en la página
       a.filas_actuales,
       a.filas_actuales + ISNULL(g.filas_por_mes, 0) * @meses AS filas_proy
INTO #dim
FROM tam x
CROSS APPLY (SELECT ISNULL(SUM(ps.row_count), 0) AS filas_actuales
             FROM sys.dm_db_partition_stats ps
             WHERE ps.object_id = x.object_id AND ps.index_id IN (0,1)) a
LEFT JOIN @crec g ON g.tabla = x.tabla;

ALTER TABLE #dim ADD paginas_datos BIGINT, datos_KB DECIMAL(14,2);
UPDATE #dim SET paginas_datos = CEILING(filas_proy / filas_por_pagina),
                datos_KB      = CEILING(filas_proy / filas_por_pagina) * 8.0;

-- Factor por índices: tamaño de cada índice no agrupado
;WITH k AS (
    SELECT c.object_id, c.column_id,
           CASE WHEN c.system_type_id IN (167,231,165)
                THEN (CASE WHEN c.max_length = -1 THEN @len_max ELSE c.max_length * @pct_var END) + 2
                ELSE c.max_length END AS bytes_col
    FROM sys.columns c
), pk AS (
    SELECT ic.object_id, SUM(k.bytes_col) AS bytes_pk
    FROM sys.indexes i
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    JOIN k ON k.object_id = ic.object_id AND k.column_id = ic.column_id
    WHERE i.index_id = 1
    GROUP BY ic.object_id
), nci AS (
    SELECT i.object_id, i.index_id, i.name AS indice, SUM(k.bytes_col) AS bytes_llave
    FROM sys.indexes i
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
    JOIN k ON k.object_id = ic.object_id AND k.column_id = ic.column_id
    WHERE i.index_id > 1 AND i.is_hypothetical = 0
    GROUP BY i.object_id, i.index_id, i.name
)
SELECT d.esquema, d.tabla, n.indice,
       n.bytes_llave + ISNULL(pk.bytes_pk, 8) + 7 AS bytes_fila_indice,        -- llave + PK agrupada + 7 B de encabezado
       CEILING(d.filas_proy / FLOOR(8096.0 / (n.bytes_llave + ISNULL(pk.bytes_pk, 8) + 7 + 2))) * 8.0 AS indice_KB
INTO #idx
FROM nci n
JOIN #dim d ON d.object_id = n.object_id
LEFT JOIN pk ON pk.object_id = n.object_id;

-- Resultado 1: detalle del cálculo por tabla (para el informe)
SELECT esquema, tabla, n_cols, fijo_bytes, n_var, var_bytes, null_bitmap, bytes_fila, filas_por_pagina,
       filas_actuales, filas_proy, paginas_datos, datos_KB
FROM #dim ORDER BY esquema, tabla;

-- Resultado 2: tamaño de cada índice
SELECT * FROM #idx ORDER BY tabla, indice;

-- Resultado 3: factor por índices y total con holgura, por tabla
SELECT d.esquema, d.tabla, d.filas_proy, d.datos_KB,
       ISNULL(SUM(i.indice_KB), 0) AS indices_KB,
       CAST(ISNULL(SUM(i.indice_KB), 0) / NULLIF(d.datos_KB, 0) AS DECIMAL(6,2)) AS factor_indices,
       d.datos_KB + ISNULL(SUM(i.indice_KB), 0) AS total_KB,
       CAST((d.datos_KB + ISNULL(SUM(i.indice_KB), 0)) * @holgura AS DECIMAL(14,2)) AS total_con_holgura_KB
FROM #dim d
LEFT JOIN #idx i ON i.tabla = d.tabla AND i.esquema = d.esquema
GROUP BY d.esquema, d.tabla, d.filas_proy, d.datos_KB
ORDER BY total_con_holgura_KB DESC;

-- Resultado 4: total de la base (datos + índices + holgura) y sugerencia para el archivo de log (25 % de datos)
SELECT CAST(SUM(d.datos_KB) / 1024.0 AS DECIMAL(10,2)) AS datos_MB,
       CAST(ISNULL((SELECT SUM(indice_KB) FROM #idx), 0) / 1024.0 AS DECIMAL(10,2)) AS indices_MB,
       CAST((SUM(d.datos_KB) + ISNULL((SELECT SUM(indice_KB) FROM #idx), 0)) * @holgura / 1024.0 AS DECIMAL(10,2)) AS archivo_datos_recomendado_MB,
       CAST(SUM(d.datos_KB) * 0.25 / 1024.0 AS DECIMAL(10,2)) AS archivo_log_sugerido_MB
FROM #dim d;
GO

-- 7.3 Archivos actuales de la base (para comparar con la recomendación)
SELECT name AS archivo, type_desc AS tipo,
       CAST(size * 8.0 / 1024 AS DECIMAL(10,2)) AS tamano_MB,
       CASE WHEN is_percent_growth = 1 THEN CAST(growth AS VARCHAR(10)) + ' %'
            ELSE CAST(growth * 8 / 1024 AS VARCHAR(10)) + ' MB' END AS crecimiento,
       physical_name
FROM sys.database_files;
GO
/* Ajuste sugerido (descomentar y adaptar a lo que arroje 7.2). SIZE debe ser >= al actual.
   Crecimiento en MB fijos, no en %, para evitar autogrowth cada vez más grandes.
ALTER DATABASE BibliotecaDB MODIFY FILE (NAME = N'BibliotecaDB',     SIZE = 64MB, FILEGROWTH = 32MB);
ALTER DATABASE BibliotecaDB MODIFY FILE (NAME = N'BibliotecaDB_log', SIZE = 32MB, FILEGROWTH = 16MB);
*/
