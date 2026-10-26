/* =========================================================
   BusRD - E2.3 dbo.sp_VenderBoleto (versión corregida)
   Requisitos cubiertos:
     - Validaciones: viaje existe y Programado, asiento existe en el
       autobús del viaje, cliente existe, canal y método válidos
     - Atomicidad: boleto + pago en una sola transacción
     - Concurrencia: UPDLOCK + HOLDLOCK sobre la verificación del asiento
     - Errores: TRY...CATCH con ROLLBACK y THROW
     - Salida: @BoletoID OUTPUT
     - Demo: @SimularDemora BIT = 0 (WAITFOR 10 s DENTRO de la transacción)
   ========================================================= */
USE BusRD;
GO

CREATE OR ALTER PROCEDURE dbo.sp_VenderBoleto
    @ViajeID        INT,
    @NumeroAsiento  INT,
    @ClienteID      INT,
    @Canal          VARCHAR(10),
    @Metodo         VARCHAR(15),
    @BoletoID       INT OUTPUT,
    @SimularDemora  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- cualquier error de ejecución aborta y revierte la transacción

    DECLARE @Precio     DECIMAL(10,2),
            @AutobusID  INT,
            @EstadoViaje VARCHAR(15);

    SET @BoletoID = NULL;

    BEGIN TRY
        /* ---------- Validaciones de parámetros (no requieren BD) ---------- */
        IF @Canal IS NULL OR @Canal NOT IN ('Taquilla','Web')
            THROW 50001, 'Canal inválido. Use Taquilla o Web.', 1;

        IF @Metodo IS NULL OR @Metodo NOT IN ('Efectivo','Tarjeta','Transferencia')
            THROW 50002, 'Método de pago inválido. Use Efectivo, Tarjeta o Transferencia.', 1;

        BEGIN TRAN;

        /* ---------- Viaje: existe y está Programado ----------
           HOLDLOCK mantiene un bloqueo compartido hasta el COMMIT, así el
           viaje no puede cancelarse ni cambiar de estado mientras vendemos. */
        SELECT @AutobusID   = v.AutobusID,
               @EstadoViaje = v.Estado,
               @Precio      = r.PrecioBase
        FROM dbo.Viajes v WITH (HOLDLOCK)
        JOIN dbo.Rutas  r ON r.RutaID = v.RutaID
        WHERE v.ViajeID = @ViajeID;

        IF @AutobusID IS NULL
            THROW 50003, 'El viaje no existe.', 1;

        IF @EstadoViaje <> 'Programado'
            THROW 50004, 'El viaje no está Programado; no se pueden vender boletos.', 1;

        /* ---------- Asiento: existe en el autobús del viaje ---------- */
        IF NOT EXISTS (SELECT 1 FROM dbo.Asientos
                       WHERE AutobusID = @AutobusID
                         AND NumeroAsiento = @NumeroAsiento)
            THROW 50005, 'El asiento no existe en el autobús de este viaje.', 1;

        /* ---------- Cliente existe ---------- */
        IF NOT EXISTS (SELECT 1 FROM dbo.Clientes WHERE ClienteID = @ClienteID)
            THROW 50006, 'El cliente no existe.', 1;

        /* ---------- Asiento libre (PUNTO CRÍTICO DE CONCURRENCIA) ----------
           UPDLOCK : la lectura toma un bloqueo de actualización. Dos sesiones
                     no pueden tenerlo a la vez sobre el mismo rango, por lo que
                     la segunda ESPERA en vez de leer "libre" al mismo tiempo.
                     Evita además el deadlock típico de dos lectores compartidos
                     que luego quieren insertar.
           HOLDLOCK: equivale a SERIALIZABLE para esta lectura. Mantiene bloqueos
                     de RANGO hasta el COMMIT, protegiendo incluso la fila que
                     todavía no existe (evita el fantasma). */
        IF EXISTS (SELECT 1
                   FROM dbo.Boletos WITH (UPDLOCK, HOLDLOCK)
                   WHERE ViajeID = @ViajeID
                     AND NumeroAsiento = @NumeroAsiento
                     AND Estado = 'Activo')
            THROW 50007, 'El asiento ya está vendido.', 1;

        /* ---------- Demo: simula el tiempo del cobro CON los bloqueos tomados ---------- */
        IF @SimularDemora = 1
            WAITFOR DELAY '00:00:10';

        /* ---------- Boleto y pago: una sola transacción ---------- */
        INSERT dbo.Boletos(ViajeID, NumeroAsiento, ClienteID, FechaVenta, Canal, Precio, Estado)
        VALUES (@ViajeID, @NumeroAsiento, @ClienteID, SYSDATETIME(), @Canal, @Precio, 'Activo');

        SET @BoletoID = SCOPE_IDENTITY();

        INSERT dbo.Pagos(BoletoID, Monto, Metodo, FechaPago)
        VALUES (@BoletoID, @Precio, @Metodo, SYSDATETIME());

        COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRAN;
        SET @BoletoID = NULL;
        THROW;   -- relanza el error original al llamador
    END CATCH
END
GO

/* =========================================================
   PRUEBAS RÁPIDAS (opcional, ejecutar seleccionando cada bloque)
   Cambiar @v y @a por un viaje Programado y un asiento libre.
   =========================================================

-- 1) Venta correcta
DECLARE @id INT, @v INT = 16000, @a INT = 44;
EXEC dbo.sp_VenderBoleto @v, @a, 1, 'Taquilla', 'Efectivo', @id OUTPUT;
SELECT @id AS BoletoID;

-- 2) Mismo asiento otra vez -> error 50007
DECLARE @id2 INT;
EXEC dbo.sp_VenderBoleto 16000, 44, 2, 'Web', 'Tarjeta', @id2 OUTPUT;

-- 3) Otras validaciones
DECLARE @x INT;
EXEC dbo.sp_VenderBoleto 99999999, 1, 1, 'Web', 'Tarjeta', @x OUTPUT;  -- viaje no existe (50003)
EXEC dbo.sp_VenderBoleto 1, 1, 1, 'Web', 'Tarjeta', @x OUTPUT;         -- viaje Completado (50004)
EXEC dbo.sp_VenderBoleto 16000, 999, 1, 'Web', 'Tarjeta', @x OUTPUT;   -- asiento inexistente (50005)
EXEC dbo.sp_VenderBoleto 16000, 1, 99999999, 'Web', 'Tarjeta', @x OUTPUT; -- cliente inexistente (50006)
EXEC dbo.sp_VenderBoleto 16000, 1, 1, 'Fax', 'Tarjeta', @x OUTPUT;     -- canal inválido (50001)
EXEC dbo.sp_VenderBoleto 16000, 1, 1, 'Web', 'Cheque', @x OUTPUT;      -- método inválido (50002)
*/
