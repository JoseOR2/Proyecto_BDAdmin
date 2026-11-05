
-- BIBLIOTECA - PROGRAMACIÓN EN BASE DE DATOS
-- Funciones, Trigger, Procedimientos, Vistas, Índices
-- y Transacciones con bloques de comprobación
-- Ejecutar DESPUÉS de biblioteca_schema_datos.sql




-- SECCIÓN 1: FUNCIÓN AUXILIAR — calcular_multa()
-- Calcula el monto de multa según días de retraso ($5.00/día).
-- Retorna 0.00 si la entrega fue a tiempo o anticipada.

CREATE OR REPLACE FUNCTION calcular_multa(
    p_fecha_limite  DATE,
    p_fecha_entrega DATE
)
RETURNS DECIMAL(10,2)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN GREATEST((p_fecha_entrega - p_fecha_limite) * 5.00, 0.00);
END;
$$;

-- ── COMPROBACIÓN 1 ───────────────────────────────────────────
-- Sin retraso → debe retornar 0.00
SELECT calcular_multa('2025-06-01', '2025-05-30') AS sin_retraso;
-- 4 días de retraso → debe retornar 20.00
SELECT calcular_multa('2025-06-01', '2025-06-05') AS retraso_4_dias;
-- 10 días de retraso → debe retornar 50.00
SELECT calcular_multa('2025-06-01', '2025-06-11') AS retraso_10_dias;


-- SECCIÓN 2: TRIGGER — trg_multa

-- Se ejecuta automáticamente después de cada INSERT en
-- devoluciones. Si hay retraso: inserta la multa y marca al
-- socio como insolvente. En cualquier caso libera el ejemplar.

CREATE OR REPLACE FUNCTION fn_trigger_multa_devolucion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_fecha_limite DATE;
    v_id_socio     INT;
    v_id_ejemplar  INT;
BEGIN
    -- Obtener datos del préstamo vinculado
    SELECT fecha_limite, id_socio, id_ejemplar
    INTO v_fecha_limite, v_id_socio, v_id_ejemplar
    FROM prestamos
    WHERE id_prestamo = NEW.id_prestamo;

    -- Si hay retraso: insertar multa y marcar socio insolvente
    IF NEW.fecha_entrega_real > v_fecha_limite THEN
        INSERT INTO multas (id_socio, id_prestamo, monto, estado_pago)
        VALUES (
            v_id_socio,
            NEW.id_prestamo,
            calcular_multa(v_fecha_limite, NEW.fecha_entrega_real),
            FALSE
        );

        UPDATE socios
        SET esta_solvente = FALSE
        WHERE id_socio = v_id_socio;
    END IF;

    -- Liberar el ejemplar en cualquier caso
    UPDATE ejemplares
    SET estado = 'Disponible'
    WHERE id_ejemplar = v_id_ejemplar;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_multa ON devoluciones;

CREATE TRIGGER trg_multa
AFTER INSERT ON devoluciones
FOR EACH ROW
EXECUTE FUNCTION fn_trigger_multa_devolucion();

-- ── COMPROBACIÓN 2 ───────────────────────────────────────────
-- Ver préstamos activos candidatos para probar el trigger
SELECT
    p.id_prestamo,
    s.nombre          AS socio,
    s.esta_solvente   AS solvente_antes,
    p.fecha_limite,
    e.estado          AS estado_ejemplar_antes
FROM prestamos p
JOIN socios     s ON p.id_socio    = s.id_socio
JOIN ejemplares e ON p.id_ejemplar = e.id_ejemplar
WHERE NOT EXISTS (
    SELECT 1 FROM devoluciones d WHERE d.id_prestamo = p.id_prestamo
)
ORDER BY p.id_prestamo
LIMIT 5;

-- Para disparar el trigger con retraso, ejecuta (cambia el id):
-- INSERT INTO devoluciones (id_prestamo, fecha_entrega_real, observaciones)
-- VALUES (<id_prestamo>, CURRENT_DATE + 5, 'prueba trigger con retraso');

-- Verificar que se generó la multa y el socio quedó insolvente:
-- SELECT * FROM multas ORDER BY id_multa DESC LIMIT 1;
-- SELECT id_socio, nombre, esta_solvente FROM socios WHERE id_socio = <id_socio>;



-- SECCIÓN 3: PROCEDIMIENTO PRINCIPAL — procesar_prestamo()

-- Valida: ejemplar disponible, socio solvente, empleado existe,
-- límite de 3 préstamos activos. Registra el préstamo y
-- actualiza el estado del ejemplar a Prestado.

CREATE OR REPLACE PROCEDURE procesar_prestamo(
    p_id_ejemplar INT,
    p_id_socio    INT,
    p_id_empleado INT,
    p_dias        INT DEFAULT 15
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_ejemplar   VARCHAR(20);
    v_solvente          BOOLEAN;
    v_prestamos_activos INT;
BEGIN
    -- 1. Verificar que el ejemplar existe y está Disponible
    SELECT estado INTO v_estado_ejemplar
    FROM ejemplares WHERE id_ejemplar = p_id_ejemplar;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El ejemplar % no existe.', p_id_ejemplar;
    END IF;

    IF v_estado_ejemplar <> 'Disponible' THEN
        RAISE EXCEPTION 'El ejemplar % no está disponible. Estado actual: %.',
            p_id_ejemplar, v_estado_ejemplar;
    END IF;

    -- 2. Verificar solvencia del socio
    SELECT esta_solvente INTO v_solvente
    FROM socios WHERE id_socio = p_id_socio;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El socio % no existe.', p_id_socio;
    END IF;

    IF NOT v_solvente THEN
        RAISE EXCEPTION 'El socio % tiene multas pendientes.', p_id_socio;
    END IF;

    -- 3. Verificar que el empleado existe
    IF NOT EXISTS (SELECT 1 FROM empleados WHERE id_empleado = p_id_empleado) THEN
        RAISE EXCEPTION 'El empleado % no existe.', p_id_empleado;
    END IF;

    -- 4. Verificar límite de 3 préstamos activos
    SELECT COUNT(*) INTO v_prestamos_activos
    FROM prestamos p
    WHERE p.id_socio = p_id_socio
      AND NOT EXISTS (
          SELECT 1 FROM devoluciones d WHERE d.id_prestamo = p.id_prestamo
      );

    IF v_prestamos_activos >= 3 THEN
        RAISE EXCEPTION 'El socio % ya tiene 3 préstamos activos.', p_id_socio;
    END IF;

    -- 5. Registrar el préstamo
    INSERT INTO prestamos (id_ejemplar, id_socio, id_empleado, fecha_salida, fecha_limite)
    VALUES (
        p_id_ejemplar, p_id_socio, p_id_empleado,
        CURRENT_DATE,
        CURRENT_DATE + (p_dias || ' days')::INTERVAL
    );

    -- 6. Marcar ejemplar como Prestado
    UPDATE ejemplares SET estado = 'Prestado'
    WHERE id_ejemplar = p_id_ejemplar;

    RAISE NOTICE 'Préstamo registrado. Ejemplar: %, Socio: %, Días: %.',
        p_id_ejemplar, p_id_socio, p_dias;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error en procesar_prestamo: %', SQLERRM;
END;
$$;

-- ── COMPROBACIÓN 3 ───────────────────────────────────────────
-- Buscar un ejemplar disponible y un socio solvente para la prueba
SELECT id_ejemplar, isbn, estado FROM ejemplares
WHERE estado = 'Disponible' ORDER BY id_ejemplar LIMIT 5;

SELECT id_socio, nombre, esta_solvente FROM socios
WHERE esta_solvente = TRUE ORDER BY id_socio LIMIT 5;

-- Llamada exitosa (ajusta los IDs con los resultados anteriores):
-- CALL procesar_prestamo(7, 1, 1, 15);

-- Confirmar que el ejemplar quedó Prestado:
-- SELECT id_ejemplar, estado FROM ejemplares WHERE id_ejemplar = 7;

-- Llamada que debe fallar (mismo ejemplar ya está Prestado):
-- CALL procesar_prestamo(7, 1, 1, 15);



-- SECCIÓN 4: STORED PROCEDURES ADICIONALES


-- ── SP 1: sp_registrar_devolucion() ─────────────────────────
-- Registra la devolución de un préstamo validando que exista
-- y no haya sido devuelto ya. El trigger trg_multa se ejecuta
-- automáticamente si hay retraso.

CREATE OR REPLACE PROCEDURE sp_registrar_devolucion(
    p_id_prestamo   INT,
    p_fecha_entrega DATE DEFAULT CURRENT_DATE,
    p_observaciones TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM prestamos WHERE id_prestamo = p_id_prestamo) THEN
        RAISE EXCEPTION 'El préstamo % no existe.', p_id_prestamo;
    END IF;

    IF EXISTS (SELECT 1 FROM devoluciones WHERE id_prestamo = p_id_prestamo) THEN
        RAISE EXCEPTION 'El préstamo % ya tiene una devolución registrada.', p_id_prestamo;
    END IF;

    INSERT INTO devoluciones (id_prestamo, fecha_entrega_real, observaciones)
    VALUES (p_id_prestamo, p_fecha_entrega, p_observaciones);

    RAISE NOTICE 'Devolución registrada para el préstamo %.', p_id_prestamo;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error en sp_registrar_devolucion: %', SQLERRM;
END;
$$;


-- ── SP 2: sp_pagar_multa() ──────────────────────────────────
-- Marca una multa como pagada. Si el socio ya no tiene más
-- multas pendientes, lo restaura como solvente automáticamente.

CREATE OR REPLACE PROCEDURE sp_pagar_multa(
    p_id_multa INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_socio          INT;
    v_ya_pagada         BOOLEAN;
    v_multas_pendientes INT;
BEGIN
    SELECT id_socio, estado_pago INTO v_id_socio, v_ya_pagada
    FROM multas WHERE id_multa = p_id_multa;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La multa % no existe.', p_id_multa;
    END IF;

    IF v_ya_pagada THEN
        RAISE EXCEPTION 'La multa % ya fue pagada anteriormente.', p_id_multa;
    END IF;

    UPDATE multas SET estado_pago = TRUE WHERE id_multa = p_id_multa;

    SELECT COUNT(*) INTO v_multas_pendientes
    FROM multas WHERE id_socio = v_id_socio AND estado_pago = FALSE;

    IF v_multas_pendientes = 0 THEN
        UPDATE socios SET esta_solvente = TRUE WHERE id_socio = v_id_socio;
        RAISE NOTICE 'Multa % pagada. Socio % ahora está solvente.', p_id_multa, v_id_socio;
    ELSE
        RAISE NOTICE 'Multa % pagada. Socio % aún tiene % multa(s) pendiente(s).',
            p_id_multa, v_id_socio, v_multas_pendientes;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error en sp_pagar_multa: %', SQLERRM;
END;
$$;


-- ── SP 3: sp_registrar_socio() ──────────────────────────────
-- Inserta un nuevo socio con validación de nombre y correo único.

CREATE OR REPLACE PROCEDURE sp_registrar_socio(
    p_nombre VARCHAR(100),
    p_correo VARCHAR(100)
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RAISE EXCEPTION 'El nombre no puede estar vacío.';
    END IF;

    IF p_correo IS NULL OR TRIM(p_correo) = '' THEN
        RAISE EXCEPTION 'El correo no puede estar vacío.';
    END IF;

    IF EXISTS (SELECT 1 FROM socios WHERE correo = TRIM(p_correo)) THEN
        RAISE EXCEPTION 'El correo % ya está registrado en el sistema.', p_correo;
    END IF;

    INSERT INTO socios (nombre, correo, esta_solvente)
    VALUES (TRIM(p_nombre), TRIM(p_correo), TRUE);

    RAISE NOTICE 'Socio "%" registrado exitosamente.', p_nombre;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error en sp_registrar_socio: %', SQLERRM;
END;
$$;


-- ── SP 4: sp_cambiar_estado_ejemplar() ──────────────────────
-- Cambia el estado de un ejemplar validando contra el CHECK
-- constraint: Disponible, Prestado, Reservado, Mantenimiento.

CREATE OR REPLACE PROCEDURE sp_cambiar_estado_ejemplar(
    p_id_ejemplar  INT,
    p_nuevo_estado VARCHAR(20)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_actual VARCHAR(20);
BEGIN
    SELECT estado INTO v_estado_actual
    FROM ejemplares WHERE id_ejemplar = p_id_ejemplar;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El ejemplar % no existe.', p_id_ejemplar;
    END IF;

    IF p_nuevo_estado NOT IN ('Disponible','Prestado','Reservado','Mantenimiento') THEN
        RAISE EXCEPTION 'Estado inválido: %. Valores: Disponible, Prestado, Reservado, Mantenimiento.',
            p_nuevo_estado;
    END IF;

    IF v_estado_actual = p_nuevo_estado THEN
        RAISE EXCEPTION 'El ejemplar % ya tiene el estado "%".', p_id_ejemplar, p_nuevo_estado;
    END IF;

    UPDATE ejemplares SET estado = p_nuevo_estado WHERE id_ejemplar = p_id_ejemplar;

    RAISE NOTICE 'Ejemplar % cambiado de "%" a "%".',
        p_id_ejemplar, v_estado_actual, p_nuevo_estado;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error en sp_cambiar_estado_ejemplar: %', SQLERRM;
END;
$$;


-- ── SP 5: sp_renovar_prestamo() ─────────────────────────────
-- Extiende la fecha límite de un préstamo activo N días más.
-- Falla si ya fue devuelto o tiene multas pendientes.

CREATE OR REPLACE PROCEDURE sp_renovar_prestamo(
    p_id_prestamo INT,
    p_dias_extra  INT DEFAULT 7
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fecha_limite DATE;
BEGIN
    SELECT fecha_limite INTO v_fecha_limite
    FROM prestamos WHERE id_prestamo = p_id_prestamo;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El préstamo % no existe.', p_id_prestamo;
    END IF;

    IF EXISTS (SELECT 1 FROM devoluciones WHERE id_prestamo = p_id_prestamo) THEN
        RAISE EXCEPTION 'El préstamo % ya fue devuelto, no se puede renovar.', p_id_prestamo;
    END IF;

    IF EXISTS (
        SELECT 1 FROM multas
        WHERE id_prestamo = p_id_prestamo AND estado_pago = FALSE
    ) THEN
        RAISE EXCEPTION 'El préstamo % tiene multas pendientes. Páguelas antes de renovar.',
            p_id_prestamo;
    END IF;

    UPDATE prestamos
    SET fecha_limite = fecha_limite + (p_dias_extra || ' days')::INTERVAL
    WHERE id_prestamo = p_id_prestamo;

    RAISE NOTICE 'Préstamo % renovado % días. Nueva fecha límite: %.',
        p_id_prestamo, p_dias_extra,
        v_fecha_limite + (p_dias_extra || ' days')::INTERVAL;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error en sp_renovar_prestamo: %', SQLERRM;
END;
$$;

-- ── COMPROBACIÓN 4 (SPs) ─────────────────────────────────────

-- SP1: Ver préstamos activos disponibles para devolver
SELECT id_prestamo, id_socio, id_ejemplar, fecha_limite
FROM prestamos
WHERE NOT EXISTS (SELECT 1 FROM devoluciones d WHERE d.id_prestamo = prestamos.id_prestamo)
ORDER BY id_prestamo LIMIT 5;
-- CALL sp_registrar_devolucion(<id_prestamo>, CURRENT_DATE, 'Prueba SP1');
-- SELECT * FROM devoluciones ORDER BY id_devolucion DESC LIMIT 1;

-- SP2: Ver multas pendientes para pagar
SELECT id_multa, id_socio, monto, estado_pago FROM multas
WHERE estado_pago = FALSE ORDER BY id_multa LIMIT 5;
-- CALL sp_pagar_multa(<id_multa>);
-- SELECT id_multa, estado_pago FROM multas WHERE id_multa = <id_multa>;

-- SP3: Registrar nuevo socio (exitoso)
-- CALL sp_registrar_socio('Socio Prueba', 'socio_prueba@test.com');
-- SELECT id_socio, nombre, correo FROM socios ORDER BY id_socio DESC LIMIT 1;
-- Mismo correo (debe fallar con excepción controlada):
-- CALL sp_registrar_socio('Otro Nombre', 'socio_prueba@test.com');

-- SP4: Cambiar estado de un ejemplar
-- CALL sp_cambiar_estado_ejemplar(1, 'Reservado');
-- SELECT id_ejemplar, estado FROM ejemplares WHERE id_ejemplar = 1;
-- Estado inválido (debe fallar):
-- CALL sp_cambiar_estado_ejemplar(1, 'Perdido');

-- SP5: Renovar un préstamo activo
SELECT id_prestamo, fecha_limite FROM prestamos
WHERE NOT EXISTS (SELECT 1 FROM devoluciones d WHERE d.id_prestamo = prestamos.id_prestamo)
ORDER BY id_prestamo LIMIT 3;
-- CALL sp_renovar_prestamo(<id_prestamo>, 7);
-- SELECT id_prestamo, fecha_limite FROM prestamos WHERE id_prestamo = <id_prestamo>;



-- SECCIÓN 5: VISTAS


-- ── VISTA 1: v_libros_disponibles ───────────────────────────
-- Ejemplares disponibles con datos completos del libro.
CREATE OR REPLACE VIEW v_libros_disponibles AS
SELECT
    e.id_ejemplar,
    l.isbn,
    l.titulo,
    STRING_AGG(DISTINCT a.nombre_autor, ', ' ORDER BY a.nombre_autor) AS autores,
    ed.nombre_editorial,
    c.nombre_categoria,
    l.anio_publicacion,
    e.estado
FROM ejemplares e
JOIN libros      l  ON e.isbn         = l.isbn
JOIN editoriales ed ON l.id_editorial = ed.id_editorial
JOIN categorias  c  ON l.id_categoria = c.id_categoria
LEFT JOIN libro_autor la ON l.isbn    = la.isbn
LEFT JOIN autores     a  ON la.id_autor = a.id_autor
WHERE e.estado = 'Disponible'
GROUP BY
    e.id_ejemplar, l.isbn, l.titulo,
    ed.nombre_editorial, c.nombre_categoria,
    l.anio_publicacion, e.estado
ORDER BY l.titulo;

-- ── VISTA 2: v_socios_morosos ───────────────────────────────
-- Socios con multas sin pagar o préstamos vencidos sin devolver.
CREATE OR REPLACE VIEW v_socios_morosos AS
SELECT
    s.id_socio,
    s.nombre,
    s.correo,
    s.esta_solvente,
    COALESCE(deuda.total_adeudado, 0.00) AS total_multas_pendientes,
    COALESCE(vencidos.cant_vencidos, 0)  AS prestamos_vencidos
FROM socios s
LEFT JOIN (
    SELECT id_socio, SUM(monto) AS total_adeudado
    FROM multas WHERE estado_pago = FALSE
    GROUP BY id_socio
) deuda ON s.id_socio = deuda.id_socio
LEFT JOIN (
    SELECT p.id_socio, COUNT(*) AS cant_vencidos
    FROM prestamos p
    WHERE p.fecha_limite < CURRENT_DATE
      AND NOT EXISTS (
          SELECT 1 FROM devoluciones d WHERE d.id_prestamo = p.id_prestamo
      )
    GROUP BY p.id_socio
) vencidos ON s.id_socio = vencidos.id_socio
WHERE deuda.id_socio IS NOT NULL OR vencidos.id_socio IS NOT NULL
ORDER BY total_multas_pendientes DESC;

-- ── VISTA 3: v_historial_prestamos ──────────────────────────
-- Historial completo con estado calculado y días de retraso.
CREATE OR REPLACE VIEW v_historial_prestamos AS
SELECT
    p.id_prestamo,
    s.nombre    AS socio,
    l.titulo    AS libro,
    emp.nombre  AS empleado_gestor,
    p.fecha_salida,
    p.fecha_limite,
    d.fecha_entrega_real,
    CASE
        WHEN d.id_devolucion IS NULL AND p.fecha_limite < CURRENT_DATE
            THEN 'Vencido sin devolver'
        WHEN d.id_devolucion IS NULL
            THEN 'Activo'
        WHEN d.fecha_entrega_real > p.fecha_limite
            THEN 'Devuelto con retraso'
        ELSE 'Devuelto a tiempo'
    END AS estado_prestamo,
    GREATEST(
        COALESCE(d.fecha_entrega_real, CURRENT_DATE) - p.fecha_limite, 0
    ) AS dias_retraso
FROM prestamos p
JOIN socios     s   ON p.id_socio    = s.id_socio
JOIN empleados  emp ON p.id_empleado = emp.id_empleado
JOIN ejemplares e   ON p.id_ejemplar = e.id_ejemplar
JOIN libros     l   ON e.isbn        = l.isbn
LEFT JOIN devoluciones d ON p.id_prestamo = d.id_prestamo
ORDER BY p.fecha_salida DESC;

-- ── VISTA 4: v_estadisticas_libros ──────────────────────────
-- Inventario y popularidad por libro.
CREATE OR REPLACE VIEW v_estadisticas_libros AS
SELECT
    l.isbn,
    l.titulo,
    STRING_AGG(DISTINCT a.nombre_autor, ', ' ORDER BY a.nombre_autor) AS autores,
    c.nombre_categoria,
    ed.nombre_editorial,
    COUNT(DISTINCT e.id_ejemplar)                                          AS total_ejemplares,
    COUNT(DISTINCT CASE WHEN e.estado = 'Disponible' THEN e.id_ejemplar END) AS ejemplares_disponibles,
    COUNT(DISTINCT p.id_prestamo)                                          AS veces_prestado
FROM libros l
JOIN categorias  c  ON l.id_categoria = c.id_categoria
JOIN editoriales ed ON l.id_editorial = ed.id_editorial
LEFT JOIN libro_autor la ON l.isbn    = la.isbn
LEFT JOIN autores     a  ON la.id_autor = a.id_autor
LEFT JOIN ejemplares  e  ON l.isbn    = e.isbn
LEFT JOIN prestamos   p  ON e.id_ejemplar = p.id_ejemplar
GROUP BY l.isbn, l.titulo, c.nombre_categoria, ed.nombre_editorial
ORDER BY veces_prestado DESC;

-- ── VISTA 5: v_multas_pendientes_detalle ────────────────────
-- Detalle completo de multas sin pagar para cobro en caja.
CREATE OR REPLACE VIEW v_multas_pendientes_detalle AS
SELECT
    m.id_multa,
    s.id_socio,
    s.nombre  AS socio,
    s.correo,
    l.titulo  AS libro_prestado,
    p.fecha_salida,
    p.fecha_limite,
    d.fecha_entrega_real,
    GREATEST(
        COALESCE(d.fecha_entrega_real, CURRENT_DATE) - p.fecha_limite, 0
    ) AS dias_retraso,
    m.monto,
    m.estado_pago
FROM multas m
JOIN socios     s  ON m.id_socio    = s.id_socio
JOIN prestamos  p  ON m.id_prestamo = p.id_prestamo
JOIN ejemplares e  ON p.id_ejemplar = e.id_ejemplar
JOIN libros     l  ON e.isbn        = l.isbn
LEFT JOIN devoluciones d ON p.id_prestamo = d.id_prestamo
WHERE m.estado_pago = FALSE
ORDER BY m.monto DESC;

-- ── COMPROBACIÓN 5 (VISTAS) ──────────────────────────────────
-- Conteo general de cada vista
SELECT COUNT(*) AS ejemplares_disponibles  FROM v_libros_disponibles;
SELECT COUNT(*) AS socios_morosos          FROM v_socios_morosos;
SELECT COUNT(*) AS registros_historial     FROM v_historial_prestamos;
SELECT COUNT(*) AS libros_con_estadisticas FROM v_estadisticas_libros;
SELECT COUNT(*) AS multas_pendientes       FROM v_multas_pendientes_detalle;

-- Top 5 socios morosos
SELECT nombre, total_multas_pendientes, prestamos_vencidos
FROM v_socios_morosos LIMIT 5;

-- Top 5 libros más prestados
SELECT titulo, veces_prestado, total_ejemplares, ejemplares_disponibles
FROM v_estadisticas_libros LIMIT 5;

-- Préstamos vencidos sin devolver
SELECT socio, libro, fecha_limite, dias_retraso, estado_prestamo
FROM v_historial_prestamos
WHERE estado_prestamo = 'Vencido sin devolver'
ORDER BY dias_retraso DESC LIMIT 5;

-- SECCIÓN 6: ÍNDICES

-- socios
CREATE INDEX IF NOT EXISTS idx_socios_correo   ON socios (correo);
CREATE INDEX IF NOT EXISTS idx_socios_nombre   ON socios (nombre);
CREATE INDEX IF NOT EXISTS idx_socios_solvente ON socios (esta_solvente);

-- libros
CREATE INDEX IF NOT EXISTS idx_libros_titulo    ON libros (titulo);
CREATE INDEX IF NOT EXISTS idx_libros_editorial ON libros (id_editorial);
CREATE INDEX IF NOT EXISTS idx_libros_categoria ON libros (id_categoria);
CREATE INDEX IF NOT EXISTS idx_libros_anio      ON libros (anio_publicacion);

-- ejemplares
CREATE INDEX IF NOT EXISTS idx_ejemplares_isbn        ON ejemplares (isbn);
CREATE INDEX IF NOT EXISTS idx_ejemplares_estado      ON ejemplares (estado);
CREATE INDEX IF NOT EXISTS idx_ejemplares_isbn_estado ON ejemplares (isbn, estado);

-- prestamos
CREATE INDEX IF NOT EXISTS idx_prestamos_socio        ON prestamos (id_socio);
CREATE INDEX IF NOT EXISTS idx_prestamos_empleado     ON prestamos (id_empleado);
CREATE INDEX IF NOT EXISTS idx_prestamos_ejemplar     ON prestamos (id_ejemplar);
CREATE INDEX IF NOT EXISTS idx_prestamos_fecha_limite ON prestamos (fecha_limite);
CREATE INDEX IF NOT EXISTS idx_prestamos_socio_fecha  ON prestamos (id_socio, fecha_limite);

-- devoluciones
CREATE INDEX IF NOT EXISTS idx_devoluciones_prestamo ON devoluciones (id_prestamo);
CREATE INDEX IF NOT EXISTS idx_devoluciones_fecha    ON devoluciones (fecha_entrega_real);

-- multas
CREATE INDEX IF NOT EXISTS idx_multas_socio        ON multas (id_socio);
CREATE INDEX IF NOT EXISTS idx_multas_prestamo     ON multas (id_prestamo);
CREATE INDEX IF NOT EXISTS idx_multas_estado_pago  ON multas (estado_pago);
CREATE INDEX IF NOT EXISTS idx_multas_socio_estado ON multas (id_socio, estado_pago);

-- libro_autor
CREATE INDEX IF NOT EXISTS idx_libro_autor_autor ON libro_autor (id_autor);
CREATE INDEX IF NOT EXISTS idx_libro_autor_isbn  ON libro_autor (isbn);

-- ── COMPROBACIÓN 6 (ÍNDICES) ─────────────────────────────────
SELECT indexname, tablename
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname LIKE 'idx_%'
ORDER BY tablename, indexname;


-- ============================================================
-- SECCIÓN 7: TRANSACCIONES
-- TIPO A — Explícita exitosa (BEGIN implícito en DO $$ / COMMIT)
-- TIPO B — Con SAVEPOINT y ROLLBACK TO (reversión parcial)
-- Cada bloque reporta resultado con RAISE NOTICE.
-- ============================================================

-- ── T1: DEVOLUCIÓN CON ACTIVACIÓN DE TRIGGER (TIPO A) ────────
-- Registra la devolución del préstamo activo más antiguo.
-- El trigger trg_multa se activa automáticamente.
DO $$
DECLARE
    v_id_prestamo INT;
BEGIN
    SELECT p.id_prestamo INTO v_id_prestamo
    FROM prestamos p
    WHERE NOT EXISTS (
        SELECT 1 FROM devoluciones d WHERE d.id_prestamo = p.id_prestamo
    )
    ORDER BY p.id_prestamo
    LIMIT 1;

    IF v_id_prestamo IS NULL THEN
        RAISE EXCEPTION 'No hay préstamos activos para devolver.';
    END IF;

    INSERT INTO devoluciones (id_prestamo, fecha_entrega_real, observaciones)
    VALUES (v_id_prestamo, CURRENT_DATE, 'Devolución automática T1');

    RAISE NOTICE 'T1 OK: Devolución del préstamo % registrada. Trigger ejecutado.',
        v_id_prestamo;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'T1 ERROR: %', SQLERRM;
END;
$$;

-- Comprobación T1: devolución generada y multa si hubo retraso
SELECT d.id_devolucion, d.id_prestamo, d.fecha_entrega_real
FROM devoluciones d ORDER BY id_devolucion DESC LIMIT 1;

SELECT id_multa, id_socio, id_prestamo, monto, estado_pago
FROM multas ORDER BY id_multa DESC LIMIT 1;


-- ── T2: EJEMPLAR A MANTENIMIENTO (TIPO A) ────────────────────
-- Mueve a Mantenimiento el primer ejemplar Disponible
-- que no tenga un préstamo activo asociado.
DO $$
DECLARE
    v_id_ejemplar INT;
BEGIN
    SELECT e.id_ejemplar INTO v_id_ejemplar
    FROM ejemplares e
    WHERE e.estado = 'Disponible'
      AND NOT EXISTS (
          SELECT 1 FROM prestamos p
          WHERE p.id_ejemplar = e.id_ejemplar
            AND NOT EXISTS (
                SELECT 1 FROM devoluciones d WHERE d.id_prestamo = p.id_prestamo
            )
      )
    ORDER BY e.id_ejemplar
    LIMIT 1;

    IF v_id_ejemplar IS NULL THEN
        RAISE EXCEPTION 'No hay ejemplares disponibles sin préstamos activos.';
    END IF;

    UPDATE ejemplares SET estado = 'Mantenimiento'
    WHERE id_ejemplar = v_id_ejemplar;

    RAISE NOTICE 'T2 OK: Ejemplar % enviado a Mantenimiento.', v_id_ejemplar;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'T2 ERROR: %', SQLERRM;
END;
$$;

-- Comprobación T2
SELECT id_ejemplar, isbn, estado FROM ejemplares
WHERE estado = 'Mantenimiento' ORDER BY id_ejemplar DESC LIMIT 3;


-- ── T3: RESTAURAR SOLVENCIA (TIPO A) ─────────────────────────
-- Marca como solventes a todos los socios que no tengan
-- ninguna multa pendiente de pago.
DO $$
DECLARE
    v_actualizados INT;
BEGIN
    UPDATE socios
    SET esta_solvente = TRUE
    WHERE esta_solvente = FALSE
      AND NOT EXISTS (
          SELECT 1 FROM multas m
          WHERE m.id_socio = socios.id_socio AND m.estado_pago = FALSE
      );

    GET DIAGNOSTICS v_actualizados = ROW_COUNT;

    RAISE NOTICE 'T3 OK: % socio(s) restaurado(s) como solventes.', v_actualizados;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'T3 ERROR: %', SQLERRM;
END;
$$;

-- Comprobación T3
SELECT COUNT(*) AS solventes   FROM socios WHERE esta_solvente = TRUE;
SELECT COUNT(*) AS insolventes FROM socios WHERE esta_solvente = FALSE;


-- ── T4: PAGAR MAYOR DEUDA (TIPO A) ───────────────────────────
-- Paga todas las multas del socio con mayor deuda acumulada
-- y lo restaura como solvente.
DO $$
DECLARE
    v_id_socio       INT;
    v_total_deuda    DECIMAL(10,2);
    v_multas_pagadas INT;
BEGIN
    SELECT id_socio, SUM(monto)
    INTO v_id_socio, v_total_deuda
    FROM multas
    WHERE estado_pago = FALSE
    GROUP BY id_socio
    ORDER BY SUM(monto) DESC
    LIMIT 1;

    IF v_id_socio IS NULL THEN
        RAISE EXCEPTION 'No hay multas pendientes de pago.';
    END IF;

    UPDATE multas SET estado_pago = TRUE
    WHERE id_socio = v_id_socio AND estado_pago = FALSE;

    GET DIAGNOSTICS v_multas_pagadas = ROW_COUNT;

    UPDATE socios SET esta_solvente = TRUE WHERE id_socio = v_id_socio;

    RAISE NOTICE 'T4 OK: Socio % pagó % multa(s) por $%. Ahora solvente.',
        v_id_socio, v_multas_pagadas, v_total_deuda;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'T4 ERROR: %', SQLERRM;
END;
$$;

-- Comprobación T4
SELECT id_socio, nombre, esta_solvente FROM socios
WHERE id_socio = (
    SELECT id_socio FROM multas
    WHERE estado_pago = TRUE
    GROUP BY id_socio
    ORDER BY SUM(monto) DESC LIMIT 1
);


-- ── T5: AJUSTE DE MULTAS CON SAVEPOINT (TIPO B) ──────────────
-- Demuestra rollback PARCIAL:
--   Paso 1 → aumenta 15% multas > $50       ← se CONSERVA
--   SAVEPOINT sp_ajuste_inicial              ← punto de control
--   Paso 2 → aplica techo de $150           ← se REVIERTE
--   ROLLBACK TO SAVEPOINT sp_ajuste_inicial ← deshace solo paso 2
--   COMMIT                                  ← guarda solo paso 1
-- Resultado: el aumento del 15% queda aplicado pero el techo no.

BEGIN;

UPDATE multas
SET monto = ROUND(monto * 1.15, 2)
WHERE estado_pago = FALSE AND monto > 50;

SAVEPOINT sp_ajuste_inicial;

UPDATE multas
SET monto = 150.00
WHERE estado_pago = FALSE AND monto > 150;

-- Deshacer SOLO el techo, conservar el aumento del 15%
ROLLBACK TO SAVEPOINT sp_ajuste_inicial;

COMMIT;

-- Comprobación T5: el 15% se aplicó, el techo fue revertido
-- (pueden existir multas > $150 como resultado del aumento)
SELECT
    COUNT(*)                                AS multas_pendientes,
    ROUND(AVG(monto), 2)                    AS promedio_monto,
    MAX(monto)                              AS monto_maximo,
    COUNT(*) FILTER (WHERE monto > 150)     AS multas_sobre_150_tras_aumento
FROM multas
WHERE estado_pago = FALSE;
