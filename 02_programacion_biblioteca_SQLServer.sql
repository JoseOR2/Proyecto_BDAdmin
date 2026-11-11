/* 
   BIBLIOTECA - PROGRAMACIÓN EN BASE DE DATOS
   Migrado de PostgreSQL PL/pgSQL a T-SQL (SQL Server 2025)
   Ejecutar DESPUÉS de 01_esquema_y_datos.sql
    */
USE BibliotecaDB;
GO

/* SECCIÓN 1: FUNCIÓN AUXILIAR */
CREATE OR ALTER FUNCTION dbo.calcular_multa
(
    @p_fecha_limite DATE,
    @p_fecha_entrega DATE
)
RETURNS DECIMAL(10,2)
AS
BEGIN
    DECLARE @dias INT = DATEDIFF(DAY, @p_fecha_limite, @p_fecha_entrega);
    RETURN CASE WHEN @dias > 0 THEN CONVERT(DECIMAL(10,2), @dias * 5.00)
                ELSE CONVERT(DECIMAL(10,2), 0.00) END;
END;
GO

-- Comprobaciones de la función
SELECT dbo.calcular_multa('2025-06-01', '2025-05-30') AS sin_retraso;
SELECT dbo.calcular_multa('2025-06-01', '2025-06-05') AS retraso_4_dias;
SELECT dbo.calcular_multa('2025-06-01', '2025-06-11') AS retraso_10_dias;
GO

/* SECCIÓN 2: TRIGGER
   En SQL Server el trigger es por sentencia y usa inserted.
   Se soportan inserciones de varias devoluciones a la vez. */
CREATE OR ALTER TRIGGER dbo.trg_multa
ON dbo.devoluciones
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.multas (id_socio, id_prestamo, monto, estado_pago)
    SELECT p.id_socio, i.id_prestamo,
           dbo.calcular_multa(p.fecha_limite, i.fecha_entrega_real), 0
    FROM inserted AS i
    INNER JOIN dbo.prestamos AS p ON p.id_prestamo = i.id_prestamo
    WHERE i.fecha_entrega_real > p.fecha_limite;

    UPDATE s
       SET esta_solvente = 0
    FROM dbo.socios AS s
    INNER JOIN dbo.prestamos AS p ON p.id_socio = s.id_socio
    INNER JOIN inserted AS i ON i.id_prestamo = p.id_prestamo
    WHERE i.fecha_entrega_real > p.fecha_limite;

    UPDATE e
       SET estado = 'Disponible'
    FROM dbo.ejemplares AS e
    INNER JOIN dbo.prestamos AS p ON p.id_ejemplar = e.id_ejemplar
    INNER JOIN inserted AS i ON i.id_prestamo = p.id_prestamo;
END;
GO

-- Comprobación: préstamos activos candidatos
SELECT TOP (5) p.id_prestamo, s.nombre AS socio, s.esta_solvente AS solvente_antes,
       p.fecha_limite, e.estado AS estado_ejemplar_antes
FROM dbo.prestamos p
JOIN dbo.socios s ON p.id_socio = s.id_socio
JOIN dbo.ejemplares e ON p.id_ejemplar = e.id_ejemplar
WHERE NOT EXISTS (SELECT 1 FROM dbo.devoluciones d WHERE d.id_prestamo = p.id_prestamo)
ORDER BY p.id_prestamo;
GO

/* SECCIÓN 3: PROCEDIMIENTO PRINCIPAL */
CREATE OR ALTER PROCEDURE dbo.procesar_prestamo
    @p_id_ejemplar INT,
    @p_id_socio INT,
    @p_id_empleado INT,
    @p_dias INT = 15
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @v_estado_ejemplar VARCHAR(20), @v_solvente BIT, @v_activos INT;

        SELECT @v_estado_ejemplar = estado
        FROM dbo.ejemplares WITH (UPDLOCK, HOLDLOCK)
        WHERE id_ejemplar = @p_id_ejemplar;
        IF @v_estado_ejemplar IS NULL
            THROW 50001, 'El ejemplar indicado no existe.', 1;
        IF @v_estado_ejemplar <> 'Disponible'
            THROW 50002, 'El ejemplar no está disponible.', 1;

        SELECT @v_solvente = esta_solvente
        FROM dbo.socios WHERE id_socio = @p_id_socio;
        IF @v_solvente IS NULL
            THROW 50003, 'El socio indicado no existe.', 1;
        IF @v_solvente = 0
            THROW 50004, 'El socio tiene multas pendientes.', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.empleados WHERE id_empleado = @p_id_empleado)
            THROW 50005, 'El empleado indicado no existe.', 1;

        SELECT @v_activos = COUNT(*)
        FROM dbo.prestamos p
        WHERE p.id_socio = @p_id_socio
          AND NOT EXISTS (SELECT 1 FROM dbo.devoluciones d WHERE d.id_prestamo = p.id_prestamo);
        IF @v_activos >= 3
            THROW 50006, 'El socio ya tiene 3 préstamos activos.', 1;

        INSERT INTO dbo.prestamos (id_ejemplar, id_socio, id_empleado, fecha_salida, fecha_limite)
        VALUES (@p_id_ejemplar, @p_id_socio, @p_id_empleado, CONVERT(date, GETDATE()),
                DATEADD(DAY, @p_dias, CONVERT(date, GETDATE())));
        UPDATE dbo.ejemplares SET estado = 'Prestado' WHERE id_ejemplar = @p_id_ejemplar;
        COMMIT TRANSACTION;
        PRINT N'Préstamo registrado correctamente.';
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* SECCIÓN 4: PROCEDIMIENTOS ADICIONALES */
CREATE OR ALTER PROCEDURE dbo.sp_registrar_devolucion
    @p_id_prestamo INT,
    @p_fecha_entrega DATE = NULL,
    @p_observaciones NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.prestamos WHERE id_prestamo = @p_id_prestamo)
        THROW 50011, 'El préstamo indicado no existe.', 1;
    IF EXISTS (SELECT 1 FROM dbo.devoluciones WHERE id_prestamo = @p_id_prestamo)
        THROW 50012, 'El préstamo ya tiene una devolución registrada.', 1;
    INSERT INTO dbo.devoluciones (id_prestamo, fecha_entrega_real, observaciones)
    VALUES (@p_id_prestamo, COALESCE(@p_fecha_entrega, CONVERT(date, GETDATE())), @p_observaciones);
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_pagar_multa
    @p_id_multa INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v_id_socio INT, @v_ya_pagada BIT, @v_pendientes INT;
    SELECT @v_id_socio = id_socio, @v_ya_pagada = estado_pago
    FROM dbo.multas WHERE id_multa = @p_id_multa;
    IF @v_id_socio IS NULL
        THROW 50013, 'La multa indicada no existe.', 1;
    IF @v_ya_pagada = 1
        THROW 50014, 'La multa ya fue pagada anteriormente.', 1;
    UPDATE dbo.multas SET estado_pago = 1 WHERE id_multa = @p_id_multa;
    SELECT @v_pendientes = COUNT(*) FROM dbo.multas
    WHERE id_socio = @v_id_socio AND estado_pago = 0;
    IF @v_pendientes = 0
        UPDATE dbo.socios SET esta_solvente = 1 WHERE id_socio = @v_id_socio;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_registrar_socio
    @p_nombre VARCHAR(100),
    @p_correo VARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SET @p_nombre = LTRIM(RTRIM(@p_nombre));
    SET @p_correo = LTRIM(RTRIM(@p_correo));
    IF @p_nombre IS NULL OR @p_nombre = ''
        THROW 50015, 'El nombre no puede estar vacío.', 1;
    IF @p_correo IS NULL OR @p_correo = ''
        THROW 50016, 'El correo no puede estar vacío.', 1;
    IF EXISTS (SELECT 1 FROM dbo.socios WHERE correo = @p_correo)
        THROW 50017, 'El correo ya está registrado en el sistema.', 1;
    INSERT INTO dbo.socios (nombre, correo, esta_solvente) VALUES (@p_nombre, @p_correo, 1);
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_cambiar_estado_ejemplar
    @p_id_ejemplar INT,
    @p_nuevo_estado VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v_estado_actual VARCHAR(20);
    SELECT @v_estado_actual = estado FROM dbo.ejemplares WHERE id_ejemplar = @p_id_ejemplar;
    IF @v_estado_actual IS NULL
        THROW 50018, 'El ejemplar indicado no existe.', 1;
    IF @p_nuevo_estado NOT IN ('Disponible','Prestado','Reservado','Mantenimiento')
        THROW 50019, 'Estado inválido.', 1;
    IF @v_estado_actual = @p_nuevo_estado
        THROW 50020, 'El ejemplar ya tiene ese estado.', 1;
    UPDATE dbo.ejemplares SET estado = @p_nuevo_estado WHERE id_ejemplar = @p_id_ejemplar;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_renovar_prestamo
    @p_id_prestamo INT,
    @p_dias_extra INT = 7
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v_fecha_limite DATE;
    SELECT @v_fecha_limite = fecha_limite FROM dbo.prestamos WHERE id_prestamo = @p_id_prestamo;
    IF @v_fecha_limite IS NULL
        THROW 50021, 'El préstamo indicado no existe.', 1;
    IF EXISTS (SELECT 1 FROM dbo.devoluciones WHERE id_prestamo = @p_id_prestamo)
        THROW 50022, 'El préstamo ya fue devuelto y no se puede renovar.', 1;
    IF EXISTS (SELECT 1 FROM dbo.multas WHERE id_prestamo = @p_id_prestamo AND estado_pago = 0)
        THROW 50023, 'El préstamo tiene multas pendientes.', 1;
    UPDATE dbo.prestamos SET fecha_limite = DATEADD(DAY, @p_dias_extra, fecha_limite)
    WHERE id_prestamo = @p_id_prestamo;
END;
GO

/* SECCIÓN 5: VISTAS */
CREATE OR ALTER VIEW dbo.v_libros_disponibles
AS
SELECT e.id_ejemplar, l.isbn, l.titulo,
       au.autores, ed.nombre_editorial, c.nombre_categoria, l.anio_publicacion, e.estado
FROM dbo.ejemplares e
JOIN dbo.libros l ON e.isbn = l.isbn
LEFT JOIN dbo.editoriales ed ON l.id_editorial = ed.id_editorial
LEFT JOIN dbo.categorias c ON l.id_categoria = c.id_categoria
OUTER APPLY (
    SELECT STRING_AGG(x.nombre_autor, ', ') AS autores
    FROM (SELECT DISTINCT a.nombre_autor
          FROM dbo.libro_autor la JOIN dbo.autores a ON a.id_autor = la.id_autor
          WHERE la.isbn = l.isbn) x
) au
WHERE e.estado = 'Disponible';
GO

CREATE OR ALTER VIEW dbo.v_socios_morosos
AS
SELECT s.id_socio, s.nombre, s.correo, s.esta_solvente,
       COALESCE(deuda.total_adeudado, 0.00) AS total_multas_pendientes,
       COALESCE(vencidos.cant_vencidos, 0) AS prestamos_vencidos
FROM dbo.socios s
LEFT JOIN (
    SELECT id_socio, SUM(monto) AS total_adeudado
    FROM dbo.multas WHERE estado_pago = 0 GROUP BY id_socio
) deuda ON s.id_socio = deuda.id_socio
LEFT JOIN (
    SELECT p.id_socio, COUNT(*) AS cant_vencidos
    FROM dbo.prestamos p
    WHERE p.fecha_limite < CONVERT(date, GETDATE())
      AND NOT EXISTS (SELECT 1 FROM dbo.devoluciones d WHERE d.id_prestamo = p.id_prestamo)
    GROUP BY p.id_socio
) vencidos ON s.id_socio = vencidos.id_socio
WHERE deuda.id_socio IS NOT NULL OR vencidos.id_socio IS NOT NULL;
GO

CREATE OR ALTER VIEW dbo.v_historial_prestamos
AS
SELECT p.id_prestamo, s.nombre AS socio, l.titulo AS libro, emp.nombre AS empleado_gestor,
       p.fecha_salida, p.fecha_limite, d.fecha_entrega_real,
       CASE WHEN d.id_devolucion IS NULL AND p.fecha_limite < CONVERT(date, GETDATE()) THEN 'Vencido sin devolver'
            WHEN d.id_devolucion IS NULL THEN 'Activo'
            WHEN d.fecha_entrega_real > p.fecha_limite THEN 'Devuelto con retraso'
            ELSE 'Devuelto a tiempo' END AS estado_prestamo,
       CASE WHEN DATEDIFF(DAY, p.fecha_limite, COALESCE(d.fecha_entrega_real, CONVERT(date, GETDATE()))) > 0
            THEN DATEDIFF(DAY, p.fecha_limite, COALESCE(d.fecha_entrega_real, CONVERT(date, GETDATE())))
            ELSE 0 END AS dias_retraso
FROM dbo.prestamos p
JOIN dbo.socios s ON p.id_socio = s.id_socio
JOIN dbo.empleados emp ON p.id_empleado = emp.id_empleado
JOIN dbo.ejemplares e ON p.id_ejemplar = e.id_ejemplar
JOIN dbo.libros l ON e.isbn = l.isbn
LEFT JOIN dbo.devoluciones d ON p.id_prestamo = d.id_prestamo;
GO

CREATE OR ALTER VIEW dbo.v_estadisticas_libros
AS
SELECT l.isbn, l.titulo, au.autores, c.nombre_categoria, ed.nombre_editorial,
       COUNT(DISTINCT e.id_ejemplar) AS total_ejemplares,
       COUNT(DISTINCT CASE WHEN e.estado = 'Disponible' THEN e.id_ejemplar END) AS ejemplares_disponibles,
       COUNT(DISTINCT p.id_prestamo) AS veces_prestado
FROM dbo.libros l
LEFT JOIN dbo.categorias c ON l.id_categoria = c.id_categoria
LEFT JOIN dbo.editoriales ed ON l.id_editorial = ed.id_editorial
LEFT JOIN dbo.ejemplares e ON l.isbn = e.isbn
LEFT JOIN dbo.prestamos p ON e.id_ejemplar = p.id_ejemplar
OUTER APPLY (
    SELECT STRING_AGG(x.nombre_autor, ', ') AS autores
    FROM (SELECT DISTINCT a.nombre_autor
          FROM dbo.libro_autor la JOIN dbo.autores a ON a.id_autor = la.id_autor
          WHERE la.isbn = l.isbn) x
) au
GROUP BY l.isbn, l.titulo, au.autores, c.nombre_categoria, ed.nombre_editorial;
GO

CREATE OR ALTER VIEW dbo.v_multas_pendientes_detalle
AS
SELECT m.id_multa, s.id_socio, s.nombre AS socio, s.correo, l.titulo AS libro_prestado,
       p.fecha_salida, p.fecha_limite, d.fecha_entrega_real,
       CASE WHEN DATEDIFF(DAY, p.fecha_limite, COALESCE(d.fecha_entrega_real, CONVERT(date, GETDATE()))) > 0
            THEN DATEDIFF(DAY, p.fecha_limite, COALESCE(d.fecha_entrega_real, CONVERT(date, GETDATE())))
            ELSE 0 END AS dias_retraso,
       m.monto, m.estado_pago
FROM dbo.multas m
JOIN dbo.socios s ON m.id_socio = s.id_socio
JOIN dbo.prestamos p ON m.id_prestamo = p.id_prestamo
JOIN dbo.ejemplares e ON p.id_ejemplar = e.id_ejemplar
JOIN dbo.libros l ON e.isbn = l.isbn
LEFT JOIN dbo.devoluciones d ON p.id_prestamo = d.id_prestamo
WHERE m.estado_pago = 0;
GO

-- Comprobación de vistas
SELECT COUNT(*) AS ejemplares_disponibles FROM dbo.v_libros_disponibles;
SELECT COUNT(*) AS socios_morosos FROM dbo.v_socios_morosos;
SELECT COUNT(*) AS registros_historial FROM dbo.v_historial_prestamos;
SELECT COUNT(*) AS libros_con_estadisticas FROM dbo.v_estadisticas_libros;
SELECT COUNT(*) AS multas_pendientes FROM dbo.v_multas_pendientes_detalle;
GO

/* SECCIÓN 6: ÍNDICES
   Se crean de forma condicional para permitir reejecutar el archivo. */
DECLARE @indices TABLE (nombre SYSNAME, tabla SYSNAME, columnas NVARCHAR(300));
INSERT INTO @indices VALUES
('idx_socios_correo','socios','correo'),('idx_socios_nombre','socios','nombre'),('idx_socios_solvente','socios','esta_solvente'),
('idx_libros_titulo','libros','titulo'),('idx_libros_editorial','libros','id_editorial'),('idx_libros_categoria','libros','id_categoria'),('idx_libros_anio','libros','anio_publicacion'),
('idx_ejemplares_isbn','ejemplares','isbn'),('idx_ejemplares_estado','ejemplares','estado'),('idx_ejemplares_isbn_estado','ejemplares','isbn, estado'),
('idx_prestamos_socio','prestamos','id_socio'),('idx_prestamos_empleado','prestamos','id_empleado'),('idx_prestamos_ejemplar','prestamos','id_ejemplar'),('idx_prestamos_fecha_limite','prestamos','fecha_limite'),('idx_prestamos_socio_fecha','prestamos','id_socio, fecha_limite'),
('idx_devoluciones_prestamo','devoluciones','id_prestamo'),('idx_devoluciones_fecha','devoluciones','fecha_entrega_real'),
('idx_multas_socio','multas','id_socio'),('idx_multas_prestamo','multas','id_prestamo'),('idx_multas_estado_pago','multas','estado_pago'),('idx_multas_socio_estado','multas','id_socio, estado_pago'),
('idx_libro_autor_autor','libro_autor','id_autor'),('idx_libro_autor_isbn','libro_autor','isbn');
DECLARE @sql NVARCHAR(MAX), @nombre SYSNAME, @tabla SYSNAME, @columnas NVARCHAR(300);
DECLARE c_idx CURSOR LOCAL FAST_FORWARD FOR SELECT nombre, tabla, columnas FROM @indices;
OPEN c_idx;
FETCH NEXT FROM c_idx INTO @nombre, @tabla, @columnas;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = @nombre AND object_id = OBJECT_ID(N'dbo.' + @tabla))
    BEGIN
        SET @sql = N'CREATE INDEX ' + QUOTENAME(@nombre) + N' ON dbo.' + QUOTENAME(@tabla) + N' (' + @columnas + N');';
        EXEC sys.sp_executesql @sql;
    END;
    FETCH NEXT FROM c_idx INTO @nombre, @tabla, @columnas;
END;
CLOSE c_idx;
DEALLOCATE c_idx;
GO

SELECT i.name AS nombre_indice, OBJECT_NAME(i.object_id) AS tabla
FROM sys.indexes i
WHERE i.name LIKE 'idx_%'
ORDER BY tabla, nombre_indice;
GO

/* SECCIÓN 7: TRANSACCIONES DE DEMOSTRACIÓN
   Se dejan como ejemplos ejecutables manualmente para evitar que
   la instalación altere los datos automáticamente.

   T1 - Devolución: descomentar y elegir un préstamo activo.
   INSERT INTO dbo.devoluciones (id_prestamo, fecha_entrega_real, observaciones)
   VALUES (<ID_PRESTAMO>, CONVERT(date, GETDATE()), N'Devolución de prueba');
   El trigger crea multa si hay retraso y libera el ejemplar.

   T2 - Cambio de estado dentro de transacción:
   BEGIN TRANSACTION;
   UPDATE dbo.ejemplares SET estado = 'Mantenimiento' WHERE id_ejemplar = <ID_EJEMPLAR>;
   COMMIT TRANSACTION;

   T3 - Restaurar solvencia:
   BEGIN TRANSACTION;
   UPDATE s SET esta_solvente = 1
   FROM dbo.socios s
   WHERE esta_solvente = 0
     AND NOT EXISTS (SELECT 1 FROM dbo.multas m WHERE m.id_socio=s.id_socio AND m.estado_pago=0);
   COMMIT TRANSACTION;

   T4 - Pago de multas del socio con mayor deuda:
   BEGIN TRANSACTION;
   DECLARE @id_socio_pago INT =
       (SELECT TOP (1) id_socio FROM dbo.multas WHERE estado_pago=0
        GROUP BY id_socio ORDER BY SUM(monto) DESC);
   UPDATE dbo.multas SET estado_pago=1 WHERE id_socio=@id_socio_pago AND estado_pago=0;
   UPDATE dbo.socios SET esta_solvente=1 WHERE id_socio=@id_socio_pago;
   COMMIT TRANSACTION;

   T5 - SAVEPOINT / rollback parcial:
   BEGIN TRANSACTION;
   UPDATE dbo.multas SET monto=ROUND(monto*1.15,2) WHERE estado_pago=0 AND monto>50;
   SAVE TRANSACTION sp_ajuste_inicial;
   UPDATE dbo.multas SET monto=150.00 WHERE estado_pago=0 AND monto>150;
   ROLLBACK TRANSACTION sp_ajuste_inicial;
   COMMIT TRANSACTION;
*/
PRINT N'Programación de base de datos instalada.';
GO
