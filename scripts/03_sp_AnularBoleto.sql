/* =========================================================
   BusRD - E2.5 dbo.sp_AnularBoleto
   Anula un boleto activo y registra el reverso de su pago
   (monto negativo) en una sola transacción.
   Al pasar a 'Anulado', el boleto sale del índice único filtrado
   UX_Boletos_Viaje_Asiento_Activo, por lo que el asiento queda libre.
   ========================================================= */
USE BusRD;
GO

CREATE OR ALTER PROCEDURE dbo.sp_AnularBoleto
    @BoletoID       INT,
    @PagoReversoID  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Estado VARCHAR(10),
            @NetoPagado DECIMAL(10,2),
            @Metodo VARCHAR(15);

    SET @PagoReversoID = NULL;

    BEGIN TRY
        BEGIN TRAN;

        /* Bloquea la fila del boleto hasta el COMMIT: si dos sesiones intentan
           anular el mismo boleto a la vez, la segunda espera y luego lo ve
           ya anulado (no se generan dos reversos). */
        SELECT @Estado = Estado
        FROM dbo.Boletos WITH (UPDLOCK, HOLDLOCK)
        WHERE BoletoID = @BoletoID;

        IF @Estado IS NULL
            THROW 50010, 'El boleto no existe.', 1;

        IF @Estado <> 'Activo'
            THROW 50011, 'El boleto ya está anulado.', 1;

        /* Neto pagado = pagos menos reversos previos (si los hubiera) */
        SELECT @NetoPagado = SUM(Monto),
               @Metodo     = MAX(CASE WHEN Monto > 0 THEN Metodo END)
        FROM dbo.Pagos
        WHERE BoletoID = @BoletoID;

        IF @NetoPagado IS NULL OR @NetoPagado <= 0
            THROW 50012, 'El boleto no tiene un pago pendiente de reversar.', 1;

        UPDATE dbo.Boletos
        SET    Estado = 'Anulado'
        WHERE  BoletoID = @BoletoID;

        INSERT dbo.Pagos(BoletoID, Monto, Metodo, FechaPago)
        VALUES (@BoletoID, -@NetoPagado, @Metodo, SYSDATETIME());

        SET @PagoReversoID = SCOPE_IDENTITY();

        COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRAN;
        SET @PagoReversoID = NULL;
        THROW;
    END CATCH
END
GO
