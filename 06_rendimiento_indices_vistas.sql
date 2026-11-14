/* 
   BIBLIOTECA RENDIMIENTO: CONSULTAS CON FUNCIONES VENTANA, ÍNDICES
   Y VISTAS PARA EL DASHBOARD     
 */

USE BibliotecaDB;
GO

SET QUOTED_IDENTIFIER ON;   -- requerido por el índice filtrado
GO

-----------------------------------------------------------------------------------------------------------

/*
   SECCIÓN 1 - ÍNDICES PARA LAS 3 CONSULTAS
   Los que ya existen en 02_programacion (sección 6) conservan su nombre
   para no duplicarlos.
 */

--Consulta 1: filtro por rango de fechas + agrupación por socio
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'idx_prestamos_fecha_salida' AND object_id = OBJECT_ID(N'dbo.prestamos'))
    CREATE NONCLUSTERED INDEX idx_prestamos_fecha_salida
        ON dbo.prestamos (fecha_salida) INCLUDE (id_socio);

--Consulta 2: solo multas pendientes (índice filtrado, más pequeño)
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'idx_multas_pendientes' AND object_id = OBJECT_ID(N'dbo.multas'))
    CREATE NONCLUSTERED INDEX idx_multas_pendientes
        ON dbo.multas (id_socio) INCLUDE (id_prestamo, monto)
        WHERE estado_pago = 0;

--Consulta 3: cadena de JOIN prestamos -> ejemplares -> libros -> categorias
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'idx_prestamos_ejemplar' AND object_id = OBJECT_ID(N'dbo.prestamos'))
    CREATE NONCLUSTERED INDEX idx_prestamos_ejemplar ON dbo.prestamos (id_ejemplar);

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'idx_ejemplares_isbn' AND object_id = OBJECT_ID(N'dbo.ejemplares'))
    CREATE NONCLUSTERED INDEX idx_ejemplares_isbn ON dbo.ejemplares (isbn);

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'idx_libros_categoria_titulo' AND object_id = OBJECT_ID(N'dbo.libros'))
    CREATE NONCLUSTERED INDEX idx_libros_categoria_titulo
        ON dbo.libros (id_categoria) INCLUDE (titulo);   -- "cubre" la consulta: evita Key Lookup
GO

-----------------------------------------------------------------------------------------------------------

/*
   SECCIÓN 2 - LAS 3 CONSULTAS CON FUNCIONES VENTANA
   Ejecutar una por una con el plan de ejecución real
   activado (Ctrl+M) para capturar plan y STATISTICS IO/TIME.
*/

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

/* ----Consulta 1: Top 5 socios con más préstamos en cada mes ---------
   Ventana: RANK() OVER (PARTITION BY año, mes ORDER BY total DESC)
   El rango se calcula sobre el último año de datos disponible. */
DECLARE @hasta DATE = DATEADD(DAY, 1, (SELECT MAX(fecha_salida) FROM dbo.prestamos));
DECLARE @desde DATE = DATEADD(YEAR, -1, @hasta);

SELECT anio, mes, id_socio, nombre, total_prestamos, ranking
FROM (
    SELECT YEAR(p.fecha_salida)  AS anio,
           MONTH(p.fecha_salida) AS mes,
           s.id_socio, s.nombre,
           COUNT(*) AS total_prestamos,
           RANK() OVER (PARTITION BY YEAR(p.fecha_salida), MONTH(p.fecha_salida)
                        ORDER BY COUNT(*) DESC) AS ranking
    FROM dbo.prestamos p
    JOIN dbo.socios s ON s.id_socio = p.id_socio
    WHERE p.fecha_salida >= @desde AND p.fecha_salida < @hasta   -- rango: permite Index Seek
    GROUP BY YEAR(p.fecha_salida), MONTH(p.fecha_salida), s.id_socio, s.nombre
) t
WHERE ranking <= 5
ORDER BY anio, mes, ranking;

/* ----Consulta 2: Deuda acumulada de multas pendientes por socio -----
   Ventana: SUM() OVER (PARTITION BY socio ORDER BY fecha ... ROWS ...) */
SELECT m.id_socio, s.nombre, p.fecha_limite, m.monto,
       SUM(m.monto) OVER (PARTITION BY m.id_socio
                          ORDER BY p.fecha_limite, m.id_multa
                          ROWS UNBOUNDED PRECEDING) AS deuda_acumulada
FROM dbo.multas m
JOIN dbo.prestamos p ON p.id_prestamo = m.id_prestamo
JOIN dbo.socios    s ON s.id_socio    = m.id_socio
WHERE m.estado_pago = 0                     -- coincide con el índice filtrado
ORDER BY m.id_socio, p.fecha_limite;

/* ----Consulta 3: Top 3 libros más prestados de cada categoría -------
   Ventana: ROW_NUMBER() OVER (PARTITION BY categoría ORDER BY veces DESC) */
SELECT categoria, isbn, titulo, total_prestamos, posicion
FROM (
    SELECT c.nombre_categoria AS categoria, l.isbn, l.titulo,
           COUNT(*) AS total_prestamos,
           ROW_NUMBER() OVER (PARTITION BY c.id_categoria
                              ORDER BY COUNT(*) DESC, l.titulo) AS posicion
    FROM dbo.prestamos  p
    JOIN dbo.ejemplares e ON e.id_ejemplar  = p.id_ejemplar
    JOIN dbo.libros     l ON l.isbn         = e.isbn
    JOIN dbo.categorias c ON c.id_categoria = l.id_categoria
    GROUP BY c.id_categoria, c.nombre_categoria, l.isbn, l.titulo
) t
WHERE posicion <= 3
ORDER BY categoria, posicion
OPTION (HASH JOIN);   -- Sin este hint, con los índices el optimizador elegía Nested Loops
                      -- (6 000 Index Seek, 13 009 lecturas en prestamos). Con el hint:
                      -- un Index Scan y 177 lecturas. Las vistas no admiten OPTION.

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-----------------------------------------------------------------------------------------------------------

/* 
   SECCIÓN 3 - VISTAS PARA EL DASHBOARD DE POWER BI
   Sin filtros fijos ni TOP: Power BI filtra con segmentadores.
*/

CREATE OR ALTER VIEW dbo.v_ranking_socios_mes AS
SELECT YEAR(p.fecha_salida) AS anio, MONTH(p.fecha_salida) AS mes,
       s.id_socio, s.nombre, COUNT(*) AS total_prestamos,
       RANK() OVER (PARTITION BY YEAR(p.fecha_salida), MONTH(p.fecha_salida)
                    ORDER BY COUNT(*) DESC) AS ranking
FROM dbo.prestamos p
JOIN dbo.socios s ON s.id_socio = p.id_socio
GROUP BY YEAR(p.fecha_salida), MONTH(p.fecha_salida), s.id_socio, s.nombre;
GO

--
CREATE OR ALTER VIEW dbo.v_multas_acumuladas AS
SELECT m.id_socio, s.nombre, p.fecha_limite, m.monto, m.estado_pago,
       SUM(CASE WHEN m.estado_pago = 0 THEN m.monto ELSE 0 END)
           OVER (PARTITION BY m.id_socio
                 ORDER BY p.fecha_limite, m.id_multa
                 ROWS UNBOUNDED PRECEDING) AS deuda_acumulada,
       SUM(m.monto)
           OVER (PARTITION BY m.id_socio
                 ORDER BY p.fecha_limite, m.id_multa
                 ROWS UNBOUNDED PRECEDING) AS multas_acumuladas_total
FROM dbo.multas m
JOIN dbo.prestamos p ON p.id_prestamo = m.id_prestamo
JOIN dbo.socios    s ON s.id_socio    = m.id_socio;
GO

--
CREATE OR ALTER VIEW dbo.v_top_libros_categoria AS
SELECT c.nombre_categoria AS categoria, l.isbn, l.titulo,
       COUNT(*) AS total_prestamos,
       ROW_NUMBER() OVER (PARTITION BY c.id_categoria
                          ORDER BY COUNT(*) DESC, l.titulo) AS posicion
FROM dbo.prestamos  p
JOIN dbo.ejemplares e ON e.id_ejemplar  = p.id_ejemplar
JOIN dbo.libros     l ON l.isbn         = e.isbn
JOIN dbo.categorias c ON c.id_categoria = l.id_categoria
GROUP BY c.id_categoria, c.nombre_categoria, l.isbn, l.titulo;
GO