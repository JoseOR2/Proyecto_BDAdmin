--5.1 Consultas Básicas 
--Consulta 1: Libros publicados después del año 2000 
SELECT titulo, anio_publicacion 
FROM libros 
WHERE anio_publicacion > 2000 
ORDER BY anio_publicacion; 
--Consulta 2: Socios no solventes 
SELECT nombre, correo 
FROM socios 
WHERE esta_solvente = FALSE; 
--Consulta 3: Ejemplares disponibles 
SELECT id_ejemplar, isbn, estado 
FROM ejemplares 
WHERE estado = 'Disponible'; 
--Consulta 4: Empleados con cargo Encargado 

SELECT nombre, cargo FROM empleados WHERE cargo = 'Encargado'; 
--Consulta 5: Total de libros en catálogo 
SELECT COUNT(*) AS total_libros FROM libros; 
--5.2 Consultas con JOIN y Agrupación 

--Consulta 6: Título y editorial de cada libro 
SELECT l.titulo, e.nombre_editorial 
FROM libros l 
JOIN editoriales e ON l.id_editorial = e.id_editorial 
ORDER BY l.titulo; 
--Consulta 7: Título y categoría de cada libro 
SELECT l.titulo, c.nombre_categoria 
FROM libros l JOIN categorias c ON l.id_categoria = c.id_categoria;  
--Consulta 8: Cantidad de libros por categoría 
SELECT c.nombre_categoria, COUNT(l.isbn) AS total_libros 
FROM categorias c
LEFT JOIN libros l ON c.id_categoria = l.id_categoria 
GROUP BY c.nombre_categoria 
ORDER BY total_libros DESC; 
--Consulta 9: Promedio del monto de las multas . 
SELECT ROUND(AVG(monto), 2) AS promedio_multa FROM multas; 
--Consulta 10: Editorial con más libros publicados 
SELECT e.nombre_editorial, COUNT(l.isbn) AS total 
FROM editoriales e JOIN libros l ON e.id_editorial = l.id_editorial 
GROUP BY e.nombre_editorial 
ORDER BY total DESC LIMIT 1; 
--Consulta 11: Préstamos por socio 
SELECT s.nombre, COUNT(p.id_prestamo) AS total_prestamos 
FROM socios s JOIN prestamos p ON s.id_socio = p.id_socio 
GROUP BY s.nombre ORDER BY total_prestamos DESC; 
--Consulta 12: Socios con más de 3 préstamos 
SELECT s.nombre, COUNT(p.id_prestamo) AS total_prestamos 
FROM socios s JOIN prestamos p ON s.id_socio = p.id_socio 
GROUP BY s.nombre 
HAVING COUNT(p.id_prestamo) > 3; 
 
--Consulta 13: Autor, título y nacionalidad 
SELECT a.nombre_autor, a.nacionalidad, l.titulo 
FROM autores a 
JOIN libro_autor la ON a.id_autor = la.id_autor 
JOIN libros l ON la.isbn = l.isbn 
ORDER BY a.nombre_autor; 
--Consulta 14: Total de multas por socio  
SELECT s.nombre, SUM(m.monto) AS total_adeudado 
FROM socios s JOIN multas m ON s.id_socio = m.id_socio 
GROUP BY s.nombre ORDER BY total_adeudado DESC; 
--Consulta 15: Empleados que gestionaron más de 5 préstamos 

SELECT emp.nombre, COUNT(p.id_prestamo) AS prestamos_gestionados 
FROM empleados emp JOIN prestamos p ON emp.id_empleado = p.id_empleado 
GROUP BY emp.nombre 
HAVING COUNT(p.id_prestamo) > 5; 
--5.3 Consultas Avanzadas 

--Consulta 16: Libros que nunca se han prestado 
SELECT l.titulo FROM libros l 
WHERE l.isbn NOT IN ( 
  SELECT e.isbn FROM ejemplares e 
  JOIN prestamos p ON e.id_ejemplar = p.id_ejemplar 
); 

--Consulta 17: Socios con multas sobre el promedio 

SELECT s.nombre, SUM(m.monto) AS total_multas 
FROM socios s JOIN multas m ON s.id_socio = m.id_socio 
GROUP BY s.nombre 
HAVING SUM(m.monto) > ( 
  SELECT AVG(monto_total) FROM ( 
    SELECT SUM(monto) AS monto_total FROM multas GROUP BY id_socio 
  ) sub 
); 

--Consulta 18: Libros con más ejemplares registrados 
SELECT l.titulo, conteo.total_ejemplares 
FROM libros l JOIN ( 
  SELECT isbn, COUNT(*) AS total_ejemplares FROM ejemplares GROUP BY isbn 
) conteo ON l.isbn = conteo.isbn 
WHERE conteo.total_ejemplares = ( 
  SELECT MAX(cnt) FROM (SELECT COUNT(*) AS cnt FROM ejemplares GROUP BY isbn) m 
);  
--Consulta 19: Autores con más libros que el promedio 
SELECT a.nombre_autor, COUNT(la.isbn) AS total_libros 
FROM autores a JOIN libro_autor la ON a.id_autor = la.id_autor 
GROUP BY a.nombre_autor 
HAVING COUNT(la.isbn) > ( 
  SELECT AVG(cnt) FROM 
  (SELECT COUNT(*) AS cnt FROM libro_autor GROUP BY id_autor) avg_sub 
); 

--Consulta 20: Socios con préstamos pero sin devoluciones 

SELECT s.nombre FROM socios s 
WHERE s.id_socio IN (SELECT p.id_socio FROM prestamos p) 
AND NOT EXISTS ( 
  SELECT 1 FROM prestamos p2 
  JOIN devoluciones d ON p2.id_prestamo = d.id_prestamo 
  WHERE p2.id_socio = s.id_socio 
); 

--Consulta 21: Ranking de socios por monto de multas (ventana) 
SELECT s.nombre, SUM(m.monto) AS total_multas, 
  RANK() OVER (ORDER BY SUM(m.monto) DESC) AS posicion 
FROM socios s JOIN multas m ON s.id_socio = m.id_socio 
GROUP BY s.nombre; 
--Consulta 22: Top 5 libros más prestados con autor (CTE) 

WITH conteo_prestamos AS ( 
  SELECT e.isbn, COUNT(p.id_prestamo) AS veces_prestado 
  FROM ejemplares e JOIN prestamos p ON e.id_ejemplar = p.id_ejemplar 
  GROUP BY e.isbn 
) 
SELECT l.titulo, a.nombre_autor, cp.veces_prestado 
FROM conteo_prestamos cp 
JOIN libros l ON cp.isbn = l.isbn 
JOIN libro_autor la ON l.isbn = la.isbn 
JOIN autores a ON la.id_autor = a.id_autor 
ORDER BY cp.veces_prestado DESC LIMIT 5; 
--Consulta 23: Días de retraso promedio por empleado (COALESCE) 
SELECT emp.nombre, 
ROUND(AVG(COALESCE(d.fecha_entrega_real, CURRENT_DATE)
- p.fecha_limite), 2) AS retraso_promedio_dias 
FROM empleados emp 
JOIN prestamos p ON emp.id_empleado = p.id_empleado 
LEFT JOIN devoluciones d ON p.id_prestamo = d.id_prestamo 
GROUP BY emp.nombre ORDER BY retraso_promedio_dias DESC; 

--Consulta 24: Porcentaje de ejemplares por estado 
SELECT estado, COUNT(*) AS cantidad, 
ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS porcentaje 
FROM ejemplares GROUP BY estado ORDER BY cantidad DESC; 
--Consulta 25: Socios morosos: multas pendientes Y préstamos vencidos 
SELECT DISTINCT s.nombre, s.correo FROM socios s 
WHERE EXISTS ( 
  SELECT 1
  FROM multas m WHERE m.id_socio = s.id_socio AND m.estado_pago = FALSE 
) 
AND EXISTS ( 
  SELECT 1 FROM prestamos p WHERE p.id_socio = s.id_socio 
  AND p.fecha_limite < CURRENT_DATE 
  AND NOT exists
  (SELECT 1 FROM devoluciones d WHERE d.id_prestamo = p.id_prestamo) 
); 

 --6. Sentencias DELETE y UPDATE 
--6.1 DELETE — Progresión de Dificultad 

--DELETE 1 — Simple por PK 

DELETE FROM autores WHERE id_autor = 69; 

--DELETE 2 — Con subconsulta NOT IN 

DELETE FROM ejemplares 
WHERE estado = 'Mantenimiento' 
  AND id_ejemplar NOT IN (SELECT id_ejemplar FROM prestamos); 
--DELETE 3 — Con condición compuesta 
 
DELETE FROM multas WHERE estado_pago = TRUE AND monto < 10; 

--DELETE 4 — Con NOT EXISTS correlacionado 
 
DELETE FROM libros 
WHERE NOT EXISTS ( 
  SELECT 1 FROM ejemplares e WHERE e.isbn = libros.isbn 
); 

--DELETE 5 — En cascada controlada 

DELETE FROM socios WHERE id_socio = 6 AND esta_solvente = FALSE 
  AND NOT EXISTS ( 
    SELECT 1 FROM prestamos p WHERE p.id_socio = socios.id_socio 
  ); 


--6.2 UPDATE — Progresión de Dificultad 

--UPDATE 1 — Simple 
UPDATE socios SET esta_solvente = TRUE WHERE id_socio = 3; 

--UPDATE 2 — Masivo 

UPDATE ejemplares SET estado = 'Disponible' WHERE estado = 'Mantenimiento'; 

--UPDATE 3 — Con CASE 
UPDATE multas SET severidad = CASE 
  WHEN monto < 20 THEN 'Leve' 
  WHEN monto BETWEEN 20 AND 60 THEN 'Moderada' 
  ELSE 'Grave' 
END; 
--UPDATE 4 — Con subconsulta 

UPDATE socios SET esta_solvente = FALSE 
WHERE id_socio IN ( 
  SELECT id_socio FROM multas WHERE estado_pago = FALSE 
); 

--UPDATE 5 — Con subconsulta y agregación 
UPDATE multas SET monto = monto * 1.10 
WHERE id_socio IN ( 
  SELECT id_socio FROM multas WHERE estado_pago = FALSE 
  GROUP BY id_socio HAVING COUNT(*) > 2 
) AND estado_pago = FALSE; 

 

 
