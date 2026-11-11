/*
   BIBLIOTECA - CONSULTAS, DELETE Y UPDATE
   Migrado a T-SQL para SQL Server 2025
   Ejecutar después de 01_esquema_y_datos.sql.
*/
USE BibliotecaDB;
GO

-- 5.1 Consultas básicas
-- Consulta 1: Libros publicados después del año 2000
SELECT titulo, anio_publicacion FROM dbo.libros
WHERE anio_publicacion > 2000 ORDER BY anio_publicacion;

-- Consulta 2: Socios no solventes
SELECT nombre, correo FROM dbo.socios WHERE esta_solvente = 0;

-- Consulta 3: Ejemplares disponibles
SELECT id_ejemplar, isbn, estado FROM dbo.ejemplares WHERE estado = 'Disponible';

-- Consulta 4: Empleados con cargo Encargado
SELECT nombre, cargo FROM dbo.empleados WHERE cargo = 'Encargado';

-- Consulta 5: Total de libros en catálogo
SELECT COUNT(*) AS total_libros FROM dbo.libros;
GO

-- 5.2 Consultas con JOIN y agrupación
-- Consulta 6: Título y editorial de cada libro
SELECT l.titulo, e.nombre_editorial
FROM dbo.libros l JOIN dbo.editoriales e ON l.id_editorial = e.id_editorial
ORDER BY l.titulo;

-- Consulta 7: Título y categoría de cada libro
SELECT l.titulo, c.nombre_categoria
FROM dbo.libros l JOIN dbo.categorias c ON l.id_categoria = c.id_categoria;

-- Consulta 8: Cantidad de libros por categoría
SELECT c.nombre_categoria, COUNT(l.isbn) AS total_libros
FROM dbo.categorias c LEFT JOIN dbo.libros l ON c.id_categoria = l.id_categoria
GROUP BY c.nombre_categoria ORDER BY total_libros DESC;

-- Consulta 9: Promedio del monto de las multas
SELECT ROUND(AVG(monto), 2) AS promedio_multa FROM dbo.multas;

-- Consulta 10: Editorial con más libros publicados
SELECT TOP (1) e.nombre_editorial, COUNT(l.isbn) AS total
FROM dbo.editoriales e JOIN dbo.libros l ON e.id_editorial = l.id_editorial
GROUP BY e.nombre_editorial ORDER BY total DESC;

-- Consulta 11: Préstamos por socio
SELECT s.nombre, COUNT(p.id_prestamo) AS total_prestamos
FROM dbo.socios s JOIN dbo.prestamos p ON s.id_socio = p.id_socio
GROUP BY s.nombre ORDER BY total_prestamos DESC;

-- Consulta 12: Socios con más de 3 préstamos
SELECT s.nombre, COUNT(p.id_prestamo) AS total_prestamos
FROM dbo.socios s JOIN dbo.prestamos p ON s.id_socio = p.id_socio
GROUP BY s.nombre HAVING COUNT(p.id_prestamo) > 3;

-- Consulta 13: Autor, título y nacionalidad
SELECT a.nombre_autor, a.nacionalidad, l.titulo
FROM dbo.autores a
JOIN dbo.libro_autor la ON a.id_autor = la.id_autor
JOIN dbo.libros l ON la.isbn = l.isbn
ORDER BY a.nombre_autor;

-- Consulta 14: Total de multas por socio
SELECT s.nombre, SUM(m.monto) AS total_adeudado
FROM dbo.socios s JOIN dbo.multas m ON s.id_socio = m.id_socio
GROUP BY s.nombre ORDER BY total_adeudado DESC;

-- Consulta 15: Empleados que gestionaron más de 5 préstamos
SELECT emp.nombre, COUNT(p.id_prestamo) AS prestamos_gestionados
FROM dbo.empleados emp JOIN dbo.prestamos p ON emp.id_empleado = p.id_empleado
GROUP BY emp.nombre HAVING COUNT(p.id_prestamo) > 5;
GO

-- 5.3 Consultas avanzadas
-- Consulta 16: Libros que nunca se han prestado
SELECT l.titulo FROM dbo.libros l
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.ejemplares e
    JOIN dbo.prestamos p ON e.id_ejemplar = p.id_ejemplar
    WHERE e.isbn = l.isbn
);

-- Consulta 17: Socios con multas sobre el promedio
SELECT s.nombre, SUM(m.monto) AS total_multas
FROM dbo.socios s JOIN dbo.multas m ON s.id_socio = m.id_socio
GROUP BY s.nombre
HAVING SUM(m.monto) > (
    SELECT AVG(monto_total)
    FROM (SELECT SUM(monto) AS monto_total FROM dbo.multas GROUP BY id_socio) sub
);

-- Consulta 18: Libros con más ejemplares registrados
SELECT l.titulo, conteo.total_ejemplares
FROM dbo.libros l
JOIN (SELECT isbn, COUNT(*) AS total_ejemplares FROM dbo.ejemplares GROUP BY isbn) conteo
  ON l.isbn = conteo.isbn
WHERE conteo.total_ejemplares = (
    SELECT MAX(cnt) FROM (SELECT COUNT(*) AS cnt FROM dbo.ejemplares GROUP BY isbn) m
);

-- Consulta 19: Autores con más libros que el promedio
SELECT a.nombre_autor, COUNT(la.isbn) AS total_libros
FROM dbo.autores a JOIN dbo.libro_autor la ON a.id_autor = la.id_autor
GROUP BY a.nombre_autor
HAVING COUNT(la.isbn) > (
    SELECT AVG(cnt) FROM (SELECT COUNT(*) AS cnt FROM dbo.libro_autor GROUP BY id_autor) avg_sub
);

-- Consulta 20: Socios con préstamos pero sin devoluciones
SELECT s.nombre FROM dbo.socios s
WHERE EXISTS (SELECT 1 FROM dbo.prestamos p WHERE p.id_socio = s.id_socio)
AND NOT EXISTS (
    SELECT 1 FROM dbo.prestamos p2
    JOIN dbo.devoluciones d ON p2.id_prestamo = d.id_prestamo
    WHERE p2.id_socio = s.id_socio
);

-- Consulta 21: Ranking de socios por monto de multas (ventana)
SELECT s.nombre, SUM(m.monto) AS total_multas,
       RANK() OVER (ORDER BY SUM(m.monto) DESC) AS posicion
FROM dbo.socios s JOIN dbo.multas m ON s.id_socio = m.id_socio
GROUP BY s.nombre;

-- Consulta 22: Top 5 libros más prestados con autor (CTE)
WITH conteo_prestamos AS (
    SELECT e.isbn, COUNT(p.id_prestamo) AS veces_prestado
    FROM dbo.ejemplares e JOIN dbo.prestamos p ON e.id_ejemplar = p.id_ejemplar
    GROUP BY e.isbn
)
SELECT TOP (5) l.titulo, a.nombre_autor, cp.veces_prestado
FROM conteo_prestamos cp
JOIN dbo.libros l ON cp.isbn = l.isbn
JOIN dbo.libro_autor la ON l.isbn = la.isbn
JOIN dbo.autores a ON la.id_autor = a.id_autor
ORDER BY cp.veces_prestado DESC;

-- Consulta 23: Días de retraso promedio por empleado
SELECT emp.nombre,
       ROUND(AVG(CONVERT(DECIMAL(10,2),
           DATEDIFF(DAY, p.fecha_limite, COALESCE(d.fecha_entrega_real, CONVERT(date, GETDATE()))))), 2)
           AS retraso_promedio_dias
FROM dbo.empleados emp
JOIN dbo.prestamos p ON emp.id_empleado = p.id_empleado
LEFT JOIN dbo.devoluciones d ON p.id_prestamo = d.id_prestamo
GROUP BY emp.nombre ORDER BY retraso_promedio_dias DESC;

-- Consulta 24: Porcentaje de ejemplares por estado
SELECT estado, COUNT(*) AS cantidad,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS porcentaje
FROM dbo.ejemplares GROUP BY estado ORDER BY cantidad DESC;

-- Consulta 25: Socios morosos: multas pendientes Y préstamos vencidos
SELECT DISTINCT s.nombre, s.correo
FROM dbo.socios s
WHERE EXISTS (SELECT 1 FROM dbo.multas m WHERE m.id_socio = s.id_socio AND m.estado_pago = 0)
AND EXISTS (
    SELECT 1 FROM dbo.prestamos p
    WHERE p.id_socio = s.id_socio AND p.fecha_limite < CONVERT(date, GETDATE())
      AND NOT EXISTS (SELECT 1 FROM dbo.devoluciones d WHERE d.id_prestamo = p.id_prestamo)
);
GO

/* 6. SENTENCIAS DELETE Y UPDATE
   IMPORTANTE: son ejemplos que modifican o eliminan datos.
   Se dejan comentados para que no se ejecuten accidentalmente.
   Descomenta y ejecuta UNA por UNA si corresponde al ejercicio. */

-- 6.1 DELETE - progresión de dificultad
-- DELETE 1 - Simple por PK
-- DELETE FROM dbo.autores WHERE id_autor = 69;

-- DELETE 2 - Con subconsulta NOT IN
-- DELETE FROM dbo.ejemplares
-- WHERE estado = 'Mantenimiento'
--   AND id_ejemplar NOT IN (SELECT id_ejemplar FROM dbo.prestamos WHERE id_ejemplar IS NOT NULL);

-- DELETE 3 - Con condición compuesta
-- DELETE FROM dbo.multas WHERE estado_pago = 1 AND monto < 10;

-- DELETE 4 - Con NOT EXISTS correlacionado
-- DELETE FROM dbo.libros
-- WHERE NOT EXISTS (SELECT 1 FROM dbo.ejemplares e WHERE e.isbn = dbo.libros.isbn);

-- DELETE 5 - En cascada controlada
-- DELETE FROM dbo.socios
-- WHERE id_socio = 6 AND esta_solvente = 0
--   AND NOT EXISTS (SELECT 1 FROM dbo.prestamos p WHERE p.id_socio = dbo.socios.id_socio);

-- 6.2 UPDATE - progresión de dificultad
-- UPDATE 1 - Simple
-- UPDATE dbo.socios SET esta_solvente = 1 WHERE id_socio = 3;

-- UPDATE 2 - Masivo
-- UPDATE dbo.ejemplares SET estado = 'Disponible' WHERE estado = 'Mantenimiento';

-- UPDATE 3 - Con CASE
-- La tabla original no define la columna severidad; se agrega si aún no existe.
IF COL_LENGTH('dbo.multas', 'severidad') IS NULL
    ALTER TABLE dbo.multas ADD severidad VARCHAR(20) NULL;
GO
-- Descomentar para ejecutar:
-- UPDATE dbo.multas
-- SET severidad = CASE
--     WHEN monto < 20 THEN 'Leve'
--     WHEN monto BETWEEN 20 AND 60 THEN 'Moderada'
--     ELSE 'Grave'
-- END;

-- UPDATE 4 - Con subconsulta
-- UPDATE dbo.socios SET esta_solvente = 0
-- WHERE id_socio IN (SELECT id_socio FROM dbo.multas WHERE estado_pago = 0);

-- UPDATE 5 - Con subconsulta y agregación
-- UPDATE dbo.multas SET monto = monto * 1.10
-- WHERE id_socio IN (
--     SELECT id_socio FROM dbo.multas WHERE estado_pago = 0
--     GROUP BY id_socio HAVING COUNT(*) > 2
-- ) AND estado_pago = 0;
GO
