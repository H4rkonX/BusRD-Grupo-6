/* =========================================================
   BusRD - E1. Integridad del modelo (Unidad I)
   Ejecutar sobre una base recién creada con 01_BusRD_base.sql
   Orden: 1) Detección  2) Limpieza  3) Restricciones  4) Verificación
   ========================================================= */
USE BusRD;
GO
SET NOCOUNT ON;
GO

/* =========================================================
   PARTE 1. DETECCIÓN DE DATOS SUCIOS
   ========================================================= */

/* 1.1 Boletos activos duplicados (mismo viaje y mismo asiento)
       Esperado: 60 pares */
SELECT b.ViajeID, b.NumeroAsiento,
       COUNT(*)                                   AS VecesVendido,
       MIN(b.BoletoID)                            AS BoletoOriginal,
       MAX(b.BoletoID)                            AS BoletoDuplicado,
       MIN(b.FechaVenta)                          AS PrimeraVenta,
       MAX(b.FechaVenta)                          AS UltimaVenta
FROM dbo.Boletos b
WHERE b.Estado = 'Activo'
GROUP BY b.ViajeID, b.NumeroAsiento
HAVING COUNT(*) > 1
ORDER BY b.ViajeID, b.NumeroAsiento;

SELECT COUNT(*) AS GruposDuplicados
FROM (SELECT 1 AS x
      FROM dbo.Boletos
      WHERE Estado = 'Activo'
      GROUP BY ViajeID, NumeroAsiento
      HAVING COUNT(*) > 1) t;
GO

/* 1.2 Pagos huérfanos (BoletoID inexistente). Esperado: 15 */
SELECT p.PagoID, p.BoletoID, p.Monto, p.Metodo, p.FechaPago
FROM dbo.Pagos p
WHERE NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID)
ORDER BY p.PagoID;
GO

/* 1.3 Otras verificaciones previas a las llaves foráneas.
       Todas deben devolver 0 filas; si no, hay que limpiarlas antes. */
SELECT 'Boletos sin viaje'      AS Problema, COUNT(*) AS Filas
FROM dbo.Boletos b WHERE NOT EXISTS (SELECT 1 FROM dbo.Viajes v WHERE v.ViajeID = b.ViajeID)
UNION ALL
SELECT 'Boletos sin cliente', COUNT(*)
FROM dbo.Boletos b WHERE NOT EXISTS (SELECT 1 FROM dbo.Clientes c WHERE c.ClienteID = b.ClienteID)
UNION ALL
SELECT 'Boletos con asiento inexistente en el autobús del viaje', COUNT(*)
FROM dbo.Boletos b
JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID
WHERE NOT EXISTS (SELECT 1 FROM dbo.Asientos s
                  WHERE s.AutobusID = v.AutobusID AND s.NumeroAsiento = b.NumeroAsiento)
UNION ALL
SELECT 'Viajes sin ruta', COUNT(*)
FROM dbo.Viajes v WHERE NOT EXISTS (SELECT 1 FROM dbo.Rutas r WHERE r.RutaID = v.RutaID)
UNION ALL
SELECT 'Viajes sin autobús', COUNT(*)
FROM dbo.Viajes v WHERE NOT EXISTS (SELECT 1 FROM dbo.Autobuses a WHERE a.AutobusID = v.AutobusID)
UNION ALL
SELECT 'Asientos sin autobús', COUNT(*)
FROM dbo.Asientos s WHERE NOT EXISTS (SELECT 1 FROM dbo.Autobuses a WHERE a.AutobusID = s.AutobusID)
UNION ALL
SELECT 'Cédulas duplicadas', COUNT(*)
FROM (SELECT Cedula FROM dbo.Clientes GROUP BY Cedula HAVING COUNT(*) > 1) t
UNION ALL
SELECT 'Placas duplicadas', COUNT(*)
FROM (SELECT Placa FROM dbo.Autobuses GROUP BY Placa HAVING COUNT(*) > 1) t
UNION ALL
SELECT 'Valores fuera de dominio (Estado/Canal/Metodo/Tipo)',
       (SELECT COUNT(*) FROM dbo.Boletos   WHERE Estado NOT IN ('Activo','Anulado'))
     + (SELECT COUNT(*) FROM dbo.Boletos   WHERE Canal  NOT IN ('Taquilla','Web'))
     + (SELECT COUNT(*) FROM dbo.Pagos     WHERE Metodo NOT IN ('Efectivo','Tarjeta','Transferencia'))
     + (SELECT COUNT(*) FROM dbo.Autobuses WHERE Tipo   NOT IN ('Estandar','Ejecutivo'))
     + (SELECT COUNT(*) FROM dbo.Viajes    WHERE Estado NOT IN ('Programado','Completado','Cancelado'))
UNION ALL
SELECT 'Precio/Monto/Capacidad fuera de rango',
       (SELECT COUNT(*) FROM dbo.Boletos   WHERE Precio <= 0)
     + (SELECT COUNT(*) FROM dbo.Pagos     WHERE Monto = 0)
     + (SELECT COUNT(*) FROM dbo.Autobuses WHERE Capacidad NOT BETWEEN 1 AND 60);
GO

/* =========================================================
   PARTE 2. LIMPIEZA
   Regla 1 (boletos duplicados): se conserva el boleto vendido primero
          (FechaVenta, luego BoletoID) y se ANULA el vendido más tarde.
          Justificación: el primer pasajero tiene prioridad sobre el asiento.
          Se anula en vez de borrar para conservar la trazabilidad.
   Regla 2 (pago del boleto anulado): NO se borra; se registra un reverso
          con monto negativo (misma mecánica que sp_AnularBoleto), de modo
          que el neto del boleto anulado queda en 0 y hay rastro contable.
   Regla 3 (pagos huérfanos): no se pueden asociar a ningún boleto, por lo
          que impiden crear la FK. Se mueven a una tabla de cuarentena
          (dbo.Pagos_Cuarentena) y luego se eliminan de dbo.Pagos.
   Todo queda registrado en dbo.Auditoria_Limpieza.
   ========================================================= */

IF OBJECT_ID('dbo.Auditoria_Limpieza') IS NULL
CREATE TABLE dbo.Auditoria_Limpieza(
    AuditoriaID INT IDENTITY PRIMARY KEY,
    Fecha       DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    Tabla       VARCHAR(30)   NOT NULL,
    Registro    INT           NOT NULL,
    Accion      VARCHAR(60)   NOT NULL,
    Detalle     VARCHAR(200)  NULL
);

IF OBJECT_ID('dbo.Pagos_Cuarentena') IS NULL
CREATE TABLE dbo.Pagos_Cuarentena(
    PagoID     INT           NOT NULL PRIMARY KEY,
    BoletoID   INT           NOT NULL,
    Monto      DECIMAL(10,2) NOT NULL,
    Metodo     VARCHAR(15)   NOT NULL,
    FechaPago  DATETIME2(0)  NOT NULL,
    MotivoCuarentena VARCHAR(100) NOT NULL,
    FechaCuarentena  DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO

BEGIN TRY
    BEGIN TRAN;

    /* --- Regla 1: boletos duplicados --- */
    IF OBJECT_ID('tempdb..#Dup') IS NOT NULL DROP TABLE #Dup;

    ;WITH d AS (
        SELECT BoletoID, ViajeID, NumeroAsiento,
               ROW_NUMBER() OVER (PARTITION BY ViajeID, NumeroAsiento
                                  ORDER BY FechaVenta, BoletoID) AS rn
        FROM dbo.Boletos
        WHERE Estado = 'Activo'
    )
    SELECT BoletoID, ViajeID, NumeroAsiento
    INTO #Dup
    FROM d
    WHERE rn > 1;

    UPDATE b
    SET    b.Estado = 'Anulado'
    FROM   dbo.Boletos b
    JOIN   #Dup d ON d.BoletoID = b.BoletoID;

    /* --- Regla 2: reverso del pago de cada boleto anulado --- */
    INSERT dbo.Pagos(BoletoID, Monto, Metodo, FechaPago)
    SELECT p.BoletoID, -p.Monto, p.Metodo, SYSDATETIME()
    FROM   dbo.Pagos p
    JOIN   #Dup d ON d.BoletoID = p.BoletoID
    WHERE  p.Monto > 0;

    INSERT dbo.Auditoria_Limpieza(Tabla, Registro, Accion, Detalle)
    SELECT 'Boletos', d.BoletoID, 'Anulado por duplicado',
           CONCAT('Viaje ', d.ViajeID, ' asiento ', d.NumeroAsiento,
                  '; se registró reverso del pago')
    FROM #Dup d;

    /* --- Regla 3: pagos huérfanos a cuarentena --- */
    INSERT dbo.Pagos_Cuarentena(PagoID, BoletoID, Monto, Metodo, FechaPago, MotivoCuarentena)
    SELECT p.PagoID, p.BoletoID, p.Monto, p.Metodo, p.FechaPago,
           'BoletoID inexistente en dbo.Boletos'
    FROM   dbo.Pagos p
    WHERE  NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID)
      AND  NOT EXISTS (SELECT 1 FROM dbo.Pagos_Cuarentena q WHERE q.PagoID = p.PagoID);

    INSERT dbo.Auditoria_Limpieza(Tabla, Registro, Accion, Detalle)
    SELECT 'Pagos', p.PagoID, 'Movido a cuarentena y eliminado',
           CONCAT('Huérfano: BoletoID ', p.BoletoID, ' no existe')
    FROM   dbo.Pagos p
    WHERE  NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID);

    DELETE p
    FROM   dbo.Pagos p
    WHERE  NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID);

    COMMIT TRAN;

    SELECT Tabla, Accion, COUNT(*) AS Filas
    FROM dbo.Auditoria_Limpieza
    GROUP BY Tabla, Accion;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    THROW;
END CATCH
GO

/* =========================================================
   PARTE 3. RESTRICCIONES
   ========================================================= */

/* ---------- 3.1 Llaves foráneas ----------
   Nota: Boletos no puede tener FK hacia Asientos porque Boletos no guarda
   AutobusID (el autobús se deduce del viaje). Que el asiento exista en el
   autobús del viaje se valida en sp_VenderBoleto. */
ALTER TABLE dbo.Viajes  WITH CHECK ADD CONSTRAINT FK_Viajes_Rutas
    FOREIGN KEY (RutaID)    REFERENCES dbo.Rutas(RutaID);
ALTER TABLE dbo.Viajes  WITH CHECK ADD CONSTRAINT FK_Viajes_Autobuses
    FOREIGN KEY (AutobusID) REFERENCES dbo.Autobuses(AutobusID);
ALTER TABLE dbo.Asientos WITH CHECK ADD CONSTRAINT FK_Asientos_Autobuses
    FOREIGN KEY (AutobusID) REFERENCES dbo.Autobuses(AutobusID);
ALTER TABLE dbo.Boletos WITH CHECK ADD CONSTRAINT FK_Boletos_Viajes
    FOREIGN KEY (ViajeID)   REFERENCES dbo.Viajes(ViajeID);
ALTER TABLE dbo.Boletos WITH CHECK ADD CONSTRAINT FK_Boletos_Clientes
    FOREIGN KEY (ClienteID) REFERENCES dbo.Clientes(ClienteID);
ALTER TABLE dbo.Pagos   WITH CHECK ADD CONSTRAINT FK_Pagos_Boletos
    FOREIGN KEY (BoletoID)  REFERENCES dbo.Boletos(BoletoID);
GO

/* ---------- 3.2 CHECK de dominio ---------- */
ALTER TABLE dbo.Viajes WITH CHECK ADD CONSTRAINT CK_Viajes_Estado
    CHECK (Estado IN ('Programado','Completado','Cancelado'));
ALTER TABLE dbo.Boletos WITH CHECK ADD CONSTRAINT CK_Boletos_Estado
    CHECK (Estado IN ('Activo','Anulado'));
ALTER TABLE dbo.Boletos WITH CHECK ADD CONSTRAINT CK_Boletos_Canal
    CHECK (Canal IN ('Taquilla','Web'));
ALTER TABLE dbo.Pagos WITH CHECK ADD CONSTRAINT CK_Pagos_Metodo
    CHECK (Metodo IN ('Efectivo','Tarjeta','Transferencia'));
ALTER TABLE dbo.Autobuses WITH CHECK ADD CONSTRAINT CK_Autobuses_Tipo
    CHECK (Tipo IN ('Estandar','Ejecutivo'));
ALTER TABLE dbo.Asientos WITH CHECK ADD CONSTRAINT CK_Asientos_Ubicacion
    CHECK (Ubicacion IN ('Ventana','Pasillo'));
GO

/* ---------- 3.3 CHECK de rango ----------
   Monto permite valores negativos porque los reversos de sp_AnularBoleto
   se registran con monto negativo; solo se prohíbe 0. */
ALTER TABLE dbo.Boletos WITH CHECK ADD CONSTRAINT CK_Boletos_Precio
    CHECK (Precio > 0 AND Precio <= 50000);
ALTER TABLE dbo.Pagos WITH CHECK ADD CONSTRAINT CK_Pagos_Monto
    CHECK (Monto <> 0 AND Monto BETWEEN -50000 AND 50000);
ALTER TABLE dbo.Autobuses WITH CHECK ADD CONSTRAINT CK_Autobuses_Capacidad
    CHECK (Capacidad BETWEEN 1 AND 60);
ALTER TABLE dbo.Rutas WITH CHECK ADD CONSTRAINT CK_Rutas_PrecioBase
    CHECK (PrecioBase > 0);
ALTER TABLE dbo.Rutas WITH CHECK ADD CONSTRAINT CK_Rutas_Distancia
    CHECK (DistanciaKm > 0);
ALTER TABLE dbo.Rutas WITH CHECK ADD CONSTRAINT CK_Rutas_OrigenDestino
    CHECK (Origen <> Destino);
ALTER TABLE dbo.Asientos WITH CHECK ADD CONSTRAINT CK_Asientos_Numero
    CHECK (NumeroAsiento > 0);
GO

/* ---------- 3.4 Unicidad ---------- */
ALTER TABLE dbo.Clientes  ADD CONSTRAINT UQ_Clientes_Cedula UNIQUE (Cedula);
ALTER TABLE dbo.Autobuses ADD CONSTRAINT UQ_Autobuses_Placa UNIQUE (Placa);
GO

/* ---------- 3.5 Un solo boleto ACTIVO por asiento y viaje ----------
   Índice único filtrado: solo los boletos 'Activo' participan en la
   unicidad, por lo que anular un boleto libera el asiento. */
CREATE UNIQUE NONCLUSTERED INDEX UX_Boletos_Viaje_Asiento_Activo
    ON dbo.Boletos(ViajeID, NumeroAsiento)
    WHERE Estado = 'Activo';
GO

/* =========================================================
   PARTE 4. VERIFICACIÓN
   ========================================================= */

/* 4.1 Ya no deben existir duplicados ni huérfanos (ambas = 0) */
SELECT
  (SELECT COUNT(*) FROM (SELECT 1 x FROM dbo.Boletos WHERE Estado='Activo'
                         GROUP BY ViajeID, NumeroAsiento HAVING COUNT(*)>1) t) AS DuplicadosActivos,
  (SELECT COUNT(*) FROM dbo.Pagos p
   WHERE NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID)) AS PagosHuerfanos;
GO

/* 4.2 Prueba de que la BD rechaza la doble venta (se revierte siempre) */
BEGIN TRY
    BEGIN TRAN;
    DECLARE @v INT, @a INT, @c INT;
    SELECT TOP (1) @v = ViajeID, @a = NumeroAsiento, @c = ClienteID
    FROM dbo.Boletos WHERE Estado = 'Activo';

    INSERT dbo.Boletos(ViajeID,NumeroAsiento,ClienteID,FechaVenta,Canal,Precio,Estado)
    VALUES (@v,@a,@c,SYSDATETIME(),'Web',100,'Activo');

    PRINT 'ERROR: la BD permitió la doble venta.';
    ROLLBACK TRAN;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    PRINT 'OK - Doble venta rechazada: ' + ERROR_MESSAGE();
END CATCH
GO

/* 4.3 Prueba de que anular libera el asiento (se revierte siempre) */
BEGIN TRY
    BEGIN TRAN;
    DECLARE @id INT, @v2 INT, @a2 INT, @c2 INT;
    SELECT TOP (1) @id = BoletoID, @v2 = ViajeID, @a2 = NumeroAsiento, @c2 = ClienteID
    FROM dbo.Boletos WHERE Estado = 'Activo';

    UPDATE dbo.Boletos SET Estado = 'Anulado' WHERE BoletoID = @id;

    INSERT dbo.Boletos(ViajeID,NumeroAsiento,ClienteID,FechaVenta,Canal,Precio,Estado)
    VALUES (@v2,@a2,@c2,SYSDATETIME(),'Web',100,'Activo');

    PRINT 'OK - Tras anular, el asiento pudo venderse de nuevo.';
    ROLLBACK TRAN;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    PRINT 'ERROR: ' + ERROR_MESSAGE();
END CATCH
GO

/* 4.4 Inventario de restricciones creadas (evidencia para el informe) */
SELECT 'FK'    AS Tipo, name AS Restriccion, OBJECT_NAME(parent_object_id) AS Tabla, is_not_trusted
FROM sys.foreign_keys
UNION ALL
SELECT 'CHECK', name, OBJECT_NAME(parent_object_id), is_not_trusted
FROM sys.check_constraints
UNION ALL
SELECT 'UNIQUE', name, OBJECT_NAME(parent_object_id), 0
FROM sys.key_constraints WHERE type = 'UQ'
UNION ALL
SELECT 'UNIQUE FILTRADO', name, OBJECT_NAME(object_id), 0
FROM sys.indexes WHERE name = 'UX_Boletos_Viaje_Asiento_Activo'
ORDER BY Tipo, Tabla, Restriccion;
GO
