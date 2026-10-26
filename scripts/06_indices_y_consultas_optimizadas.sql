/* =========================================================
   BusRD - E3. Optimización (Unidad II) - GRUPO 6
   Ejecutar cada SECCIÓN completa (seleccionarla y F5), en orden.
   Antes de las secciones 2 y 4 activar "Include Actual Execution Plan"
   (Ctrl+M) para capturar los planes.

   Configuración del grupo (repetida en cada sección, cambiar si hace falta):
     @Grupo   = 6        -> C2 usa el cliente 6 x 1000 = 6000
                            cédula = '40200006000'
     @ViajeID = 16000    -> <<< PROVISIONAL: Dado qyu no ha sido proveido por el maestro aun

   Secciones:
     1. Línea base: dejar la BD sin índices secundarios (estado original)
     2. Consultas ORIGINALES (métricas y plan "antes")
     3. Crear índices
     4. Consultas REESCRITAS (métricas y plan "después")
     5. Comprobar que devuelven exactamente el mismo resultado
     6. Impacto de los índices sobre sp_VenderBoleto (lecturas vs escrituras)
     7. Inventario final de índices
   ========================================================= */


/* =========================================================
   SECCIÓN 1 - LÍNEA BASE (sin índices secundarios)
   Se quitan temporalmente el índice único filtrado de boletos (E1.4) y la
   unicidad de Cedula (E1.3), porque ambos son índices que ayudan a las
   consultas. Se restauran en la sección 3.
   ========================================================= */
USE BusRD;
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_Boletos_Viaje_Asiento_Activo'
                                       AND object_id = OBJECT_ID('dbo.Boletos'))
    DROP INDEX UX_Boletos_Viaje_Asiento_Activo ON dbo.Boletos;

IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_Clientes_Cedula')
    ALTER TABLE dbo.Clientes DROP CONSTRAINT UQ_Clientes_Cedula;

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Boletos_ClienteID'
                                       AND object_id = OBJECT_ID('dbo.Boletos'))
    DROP INDEX IX_Boletos_ClienteID ON dbo.Boletos;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Boletos_FechaVenta_Activo'
                                       AND object_id = OBJECT_ID('dbo.Boletos'))
    DROP INDEX IX_Boletos_FechaVenta_Activo ON dbo.Boletos;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Pagos_BoletoID'
                                       AND object_id = OBJECT_ID('dbo.Pagos'))
    DROP INDEX IX_Pagos_BoletoID ON dbo.Pagos;
GO

-- Verificar: solo deben quedar los índices de las llaves primarias
SELECT OBJECT_NAME(object_id) AS Tabla, name AS Indice, type_desc
FROM sys.indexes
WHERE object_id IN (OBJECT_ID('dbo.Boletos'), OBJECT_ID('dbo.Pagos'),
                    OBJECT_ID('dbo.Clientes'), OBJECT_ID('dbo.Viajes'))
ORDER BY Tabla, Indice;
GO


/* =========================================================
   SECCIÓN 2 - CONSULTAS ORIGINALES ("ANTES")
   Ejecutar C1, C2 y C3 con el plan real activado (Ctrl+M).
   Anotar de la pestaña Messages: lecturas lógicas por tabla y CPU time /
   elapsed time. Capturar cada plan.
   ========================================================= */
USE BusRD;
GO
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

/* C1 original */
DECLARE @ViajeID INT = 16000;          -- <<< viaje asignado al grupo
SELECT s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND s.NumeroAsiento NOT IN (SELECT b.NumeroAsiento
                              FROM dbo.Boletos b
                              WHERE b.ViajeID = @ViajeID
                                AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento;
GO

/* C2 original */
DECLARE @Grupo INT = 6;                -- <<< número de grupo
DECLARE @Cedula CHAR(11) = '402' + RIGHT('00000000' + CAST(@Grupo * 1000 AS VARCHAR(8)), 8);
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino,
       v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE LTRIM(RTRIM(c.Cedula)) = @Cedula
ORDER BY v.FechaSalida DESC;
GO

/* C3 original */
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes,
       COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE YEAR(b.FechaVenta) = 2025
  AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta)
ORDER BY r.Origen, r.Destino, Mes;
GO


/* =========================================================
   SECCIÓN 3 - CREAR ÍNDICES
   ========================================================= */
USE BusRD;
GO
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

/* C1: asientos ocupados de un viaje.
   Es el mismo índice único filtrado de E1.4. Clave (ViajeID, NumeroAsiento):
   ViajeID para localizar el viaje (igualdad) y NumeroAsiento para comparar
   contra los asientos del autobús. El filtro Estado='Activo' lo hace pequeño
   y cubre la consulta sin INCLUDE. */
CREATE UNIQUE NONCLUSTERED INDEX UX_Boletos_Viaje_Asiento_Activo
    ON dbo.Boletos(ViajeID, NumeroAsiento)
    WHERE Estado = 'Activo';

/* C2: buscar el cliente por cédula (también es la unicidad de E1.3). */
ALTER TABLE dbo.Clientes ADD CONSTRAINT UQ_Clientes_Cedula UNIQUE (Cedula);

/* C2: boletos de un cliente. Clave ClienteID (igualdad); INCLUDE con las
   columnas que la consulta devuelve o usa para unir, para evitar key lookups. */
CREATE NONCLUSTERED INDEX IX_Boletos_ClienteID
    ON dbo.Boletos(ClienteID)
    INCLUDE (ViajeID, NumeroAsiento, Precio, Estado);

/* C3: boletos activos por rango de fecha de venta. Índice filtrado
   (Estado='Activo'); la clave FechaVenta permite el seek por rango y
   ViajeID va en INCLUDE para unir con Viajes. BoletoID (clave del clustered)
   se incluye automáticamente para unir con Pagos. */
CREATE NONCLUSTERED INDEX IX_Boletos_FechaVenta_Activo
    ON dbo.Boletos(FechaVenta)
    INCLUDE (ViajeID)
    WHERE Estado = 'Activo';

/* C3: pagos de un boleto. Clave BoletoID (columna de unión); INCLUDE Monto
   para sumar sin ir a la tabla. También acelera la FK Pagos -> Boletos. */
CREATE NONCLUSTERED INDEX IX_Pagos_BoletoID
    ON dbo.Pagos(BoletoID)
    INCLUDE (Monto);
GO


/* =========================================================
   SECCIÓN 4 - CONSULTAS REESCRITAS ("DESPUÉS")
   Plan real activado (Ctrl+M). Anotar las mismas métricas.
   ========================================================= */
USE BusRD;
GO
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

/* C1 reescrita: NOT EXISTS en lugar de NOT IN (equivalente porque
   Boletos.NumeroAsiento es NOT NULL) */
DECLARE @ViajeID INT = 16000;          -- <<< viaje asignado al grupo
SELECT s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND NOT EXISTS (SELECT 1
                  FROM dbo.Boletos b
                  WHERE b.ViajeID = @ViajeID
                    AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento;
GO

/* C2 reescrita: sin funciones sobre la columna (sargable) */
DECLARE @Grupo INT = 6;                -- <<< número de grupo
DECLARE @Cedula CHAR(11) = '402' + RIGHT('00000000' + CAST(@Grupo * 1000 AS VARCHAR(8)), 8);
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino,
       v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE c.Cedula = @Cedula
ORDER BY v.FechaSalida DESC;
GO

/* C3 reescrita: rango de fechas en lugar de YEAR() (sargable) */
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes,
       COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE b.FechaVenta >= '20250101'
  AND b.FechaVenta <  '20260101'
  AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta)
ORDER BY r.Origen, r.Destino, Mes;
GO


/* =========================================================
   SECCIÓN 5 - MISMO RESULTADO (original vs reescrita)
   Compara filas con EXCEPT en ambos sentidos y cuenta filas.
   Debe decir IGUAL en las tres consultas.
   ========================================================= */
USE BusRD;
GO
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
DECLARE @ViajeID INT = 16000;          -- <<< viaje asignado al grupo
DECLARE @Grupo INT = 6;                -- <<< número de grupo
DECLARE @Cedula CHAR(11) = '402' + RIGHT('00000000' + CAST(@Grupo * 1000 AS VARCHAR(8)), 8);

IF OBJECT_ID('tempdb..#C1o') IS NOT NULL DROP TABLE #C1o;
IF OBJECT_ID('tempdb..#C1n') IS NOT NULL DROP TABLE #C1n;
IF OBJECT_ID('tempdb..#C2o') IS NOT NULL DROP TABLE #C2o;
IF OBJECT_ID('tempdb..#C2n') IS NOT NULL DROP TABLE #C2n;
IF OBJECT_ID('tempdb..#C3o') IS NOT NULL DROP TABLE #C3o;
IF OBJECT_ID('tempdb..#C3n') IS NOT NULL DROP TABLE #C3n;

/* C1 */
SELECT s.NumeroAsiento, s.Ubicacion INTO #C1o
FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND s.NumeroAsiento NOT IN (SELECT b.NumeroAsiento FROM dbo.Boletos b
                              WHERE b.ViajeID = @ViajeID AND b.Estado = 'Activo');
SELECT s.NumeroAsiento, s.Ubicacion INTO #C1n
FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = @ViajeID AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo');

/* C2 */
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino, v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
INTO #C2o
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE LTRIM(RTRIM(c.Cedula)) = @Cedula;
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino, v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
INTO #C2n
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE c.Cedula = @Cedula;

/* C3 */
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes, COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
INTO #C3o
FROM dbo.Boletos b
JOIN dbo.Pagos p  ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas r  ON r.RutaID   = v.RutaID
WHERE YEAR(b.FechaVenta) = 2025 AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta);
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes, COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
INTO #C3n
FROM dbo.Boletos b
JOIN dbo.Pagos p  ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas r  ON r.RutaID   = v.RutaID
WHERE b.FechaVenta >= '20250101' AND b.FechaVenta < '20260101' AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta);

SELECT 'C1' AS Consulta,
       (SELECT COUNT(*) FROM #C1o) AS FilasOriginal,
       (SELECT COUNT(*) FROM #C1n) AS FilasReescrita,
       CASE WHEN (SELECT COUNT(*) FROM #C1o) = (SELECT COUNT(*) FROM #C1n)
             AND NOT EXISTS (SELECT * FROM #C1o EXCEPT SELECT * FROM #C1n)
             AND NOT EXISTS (SELECT * FROM #C1n EXCEPT SELECT * FROM #C1o)
            THEN 'IGUAL' ELSE 'DIFERENTE' END AS Resultado
UNION ALL
SELECT 'C2',
       (SELECT COUNT(*) FROM #C2o), (SELECT COUNT(*) FROM #C2n),
       CASE WHEN (SELECT COUNT(*) FROM #C2o) = (SELECT COUNT(*) FROM #C2n)
             AND NOT EXISTS (SELECT * FROM #C2o EXCEPT SELECT * FROM #C2n)
             AND NOT EXISTS (SELECT * FROM #C2n EXCEPT SELECT * FROM #C2o)
            THEN 'IGUAL' ELSE 'DIFERENTE' END
UNION ALL
SELECT 'C3',
       (SELECT COUNT(*) FROM #C3o), (SELECT COUNT(*) FROM #C3n),
       CASE WHEN (SELECT COUNT(*) FROM #C3o) = (SELECT COUNT(*) FROM #C3n)
             AND NOT EXISTS (SELECT * FROM #C3o EXCEPT SELECT * FROM #C3n)
             AND NOT EXISTS (SELECT * FROM #C3n EXCEPT SELECT * FROM #C3o)
            THEN 'IGUAL' ELSE 'DIFERENTE' END;

-- Dato de apoyo: ninguna cédula tiene espacios a la izquierda (por eso
-- quitar LTRIM/RTRIM no cambia el resultado). Debe dar 0.
SELECT COUNT(*) AS CedulasConEspaciosIzquierda
FROM dbo.Clientes WHERE LTRIM(Cedula) <> Cedula;
GO


/* =========================================================
   SECCIÓN 6 - IMPACTO DE LOS ÍNDICES SOBRE sp_VenderBoleto
   Vende 300 boletos con los índices nuevos y otros 300 sin ellos (se
   conserva el índice único de E1.4, que es una restricción), compara el
   tiempo y deja la base como estaba (borra los boletos de prueba).
   ========================================================= */
USE BusRD;
GO
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Combos')   IS NOT NULL DROP TABLE #Combos;
IF OBJECT_ID('tempdb..#Vendidos') IS NOT NULL DROP TABLE #Vendidos;
CREATE TABLE #Vendidos(BoletoID INT);

/* Pares (viaje programado, asiento libre) distintos para las 3 tandas */
;WITH c AS (
    SELECT ROW_NUMBER() OVER (ORDER BY v.ViajeID, s.NumeroAsiento) AS rn,
           v.ViajeID, s.NumeroAsiento
    FROM dbo.Viajes v
    JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
    WHERE v.Estado = 'Programado'
      AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                      WHERE b.ViajeID = v.ViajeID
                        AND b.NumeroAsiento = s.NumeroAsiento
                        AND b.Estado = 'Activo')
)
SELECT rn, ViajeID, NumeroAsiento INTO #Combos FROM c WHERE rn <= 650;

DECLARE @i INT, @id INT, @v INT, @a INT, @t0 DATETIME2(3),
        @msCon INT, @msSin INT;

BEGIN TRY
    /* Calentamiento (50 ventas, no se mide) */
    SET @i = 1;
    WHILE @i <= 50
    BEGIN
        SELECT @v = ViajeID, @a = NumeroAsiento FROM #Combos WHERE rn = @i;
        EXEC dbo.sp_VenderBoleto @v, @a, @i, 'Taquilla', 'Efectivo', @id OUTPUT;
        INSERT #Vendidos VALUES (@id);
        SET @i += 1;
    END

    /* Tanda A: CON los índices nuevos (rn 51..350) */
    SET @t0 = SYSDATETIME();
    SET @i = 51;
    WHILE @i <= 350
    BEGIN
        SELECT @v = ViajeID, @a = NumeroAsiento FROM #Combos WHERE rn = @i;
        EXEC dbo.sp_VenderBoleto @v, @a, @i, 'Taquilla', 'Efectivo', @id OUTPUT;
        INSERT #Vendidos VALUES (@id);
        SET @i += 1;
    END
    SET @msCon = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());

    /* Quitar los 3 índices nuevos (no los de restricciones) */
    DROP INDEX IX_Boletos_ClienteID       ON dbo.Boletos;
    DROP INDEX IX_Boletos_FechaVenta_Activo ON dbo.Boletos;
    DROP INDEX IX_Pagos_BoletoID          ON dbo.Pagos;

    /* Tanda B: SIN los índices nuevos (rn 351..650) */
    SET @t0 = SYSDATETIME();
    SET @i = 351;
    WHILE @i <= 650
    BEGIN
        SELECT @v = ViajeID, @a = NumeroAsiento FROM #Combos WHERE rn = @i;
        EXEC dbo.sp_VenderBoleto @v, @a, @i, 'Taquilla', 'Efectivo', @id OUTPUT;
        INSERT #Vendidos VALUES (@id);
        SET @i += 1;
    END
    SET @msSin = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());

    SELECT 'Con índices nuevos' AS Escenario, @msCon AS TotalMs_300_ventas,
           CAST(@msCon / 300.0 AS DECIMAL(8,2)) AS MsPorVenta
    UNION ALL
    SELECT 'Sin índices nuevos', @msSin, CAST(@msSin / 300.0 AS DECIMAL(8,2));
END TRY
BEGIN CATCH
    PRINT CONCAT('Error en la prueba: ', ERROR_MESSAGE());
END CATCH

/* Restaurar los índices (siempre, haya o no error) */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Boletos_ClienteID'
                                           AND object_id = OBJECT_ID('dbo.Boletos'))
    CREATE NONCLUSTERED INDEX IX_Boletos_ClienteID
        ON dbo.Boletos(ClienteID) INCLUDE (ViajeID, NumeroAsiento, Precio, Estado);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Boletos_FechaVenta_Activo'
                                           AND object_id = OBJECT_ID('dbo.Boletos'))
    CREATE NONCLUSTERED INDEX IX_Boletos_FechaVenta_Activo
        ON dbo.Boletos(FechaVenta) INCLUDE (ViajeID) WHERE Estado = 'Activo';
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Pagos_BoletoID'
                                           AND object_id = OBJECT_ID('dbo.Pagos'))
    CREATE NONCLUSTERED INDEX IX_Pagos_BoletoID
        ON dbo.Pagos(BoletoID) INCLUDE (Monto);

/* Borrar los boletos y pagos de prueba para dejar la base limpia */
DELETE p FROM dbo.Pagos   p JOIN #Vendidos x ON x.BoletoID = p.BoletoID;
DELETE b FROM dbo.Boletos b JOIN #Vendidos x ON x.BoletoID = b.BoletoID;
DECLARE @NEliminados INT = (SELECT COUNT(*) FROM #Vendidos);
PRINT CONCAT('Boletos de prueba eliminados: ', @NEliminados);
GO


/* =========================================================
   SECCIÓN 7 - INVENTARIO FINAL DE ÍNDICES (evidencia)
   ========================================================= */
USE BusRD;
GO
SELECT OBJECT_NAME(i.object_id) AS Tabla, i.name AS Indice, i.type_desc,
       i.is_unique, i.has_filter, i.filter_definition,
       STUFF((SELECT ', ' + c.name
              FROM sys.index_columns ic JOIN sys.columns c
                   ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                AND ic.is_included_column = 0
              ORDER BY ic.key_ordinal FOR XML PATH('')), 1, 2, '') AS Clave,
       STUFF((SELECT ', ' + c.name
              FROM sys.index_columns ic JOIN sys.columns c
                   ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                AND ic.is_included_column = 1
              FOR XML PATH('')), 1, 2, '') AS Incluidas
FROM sys.indexes i
WHERE i.object_id IN (OBJECT_ID('dbo.Boletos'), OBJECT_ID('dbo.Pagos'), OBJECT_ID('dbo.Clientes'))
  AND i.type > 0
ORDER BY Tabla, Indice;
GO
