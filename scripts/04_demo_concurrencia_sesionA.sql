/* =========================================================
   BusRD - E2.4 Prueba de concurrencia con sp_VenderBoleto
   SESIÓN A (ventana 1)

   Ejecutar cada sección SELECCIONÁNDOLA y presionando F5.
     SECCIÓN 1 -> preparación: muestra un viaje Programado y asientos libres
     SECCIÓN 2 -> venta de la sesión A (tarda ~10 s por @SimularDemora = 1)
                  Lanzar la sesión B (archivo 05) inmediatamente después.
     SECCIÓN 3 -> evidencia, cuando A y B hayan terminado
     SECCIÓN 4 -> reiniciar la demo (anula el boleto y libera el asiento)

   IMPORTANTE: sp_VenderBoleto solo vende en viajes en estado 'Programado'.
   Usar en las secciones 2, 3 y 4 (y en el archivo 05) el viaje y asiento
   que muestre la sección 1. Si el viaje asignado al grupo está
   Programado, usar ese.
   ========================================================= */


/* =========================================================
   SECCIÓN 1 - PREPARACIÓN
   ========================================================= */
USE BusRD;
GO
DECLARE @ViajeID INT = NULL;   -- <<< poner aquí el viaje del grupo, o dejar NULL para elegir uno automático

IF @ViajeID IS NULL
    SELECT TOP (1) @ViajeID = ViajeID FROM dbo.Viajes WHERE Estado = 'Programado' ORDER BY ViajeID;

SELECT v.ViajeID, v.Estado, v.FechaSalida
FROM dbo.Viajes v WHERE v.ViajeID = @ViajeID;

SELECT TOP (5) s.NumeroAsiento AS AsientoLibre
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = @ViajeID
                    AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento DESC;
GO


/* =========================================================
   SECCIÓN 2 - SESIÓN A: venta con @SimularDemora = 1
   ========================================================= */
USE BusRD;
DECLARE @ViajeID INT = 6585,      -- <<< viaje de la sección 1
        @Asiento INT = 43,     -- <<< asiento libre de la sección 1
        @BoletoID INT,
        @t0 DATETIME2(3) = SYSDATETIME();

PRINT CONCAT('Sesión A inicia: ', CONVERT(VARCHAR(23), @t0, 121));

EXEC dbo.sp_VenderBoleto
     @ViajeID = @ViajeID, @NumeroAsiento = @Asiento,
     @ClienteID = 1, @Canal = 'Taquilla', @Metodo = 'Efectivo',
     @BoletoID = @BoletoID OUTPUT, @SimularDemora = 1;

PRINT CONCAT('Sesión A termina: ', CONVERT(VARCHAR(23), SYSDATETIME(), 121),
             ' | BoletoID = ', @BoletoID,
             ' | Duración (ms) = ', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
GO


/* =========================================================
   SECCIÓN 3 - EVIDENCIA (cuando ambas sesiones hayan terminado)
   Resultado esperado: UN solo boleto activo para ese asiento
   ========================================================= */
USE BusRD;
DECLARE @ViajeID INT = 6585, @Asiento INT = 43;   -- <<< los mismos

SELECT b.BoletoID, b.ViajeID, b.NumeroAsiento, b.ClienteID, b.Canal,
       b.FechaVenta, b.Estado, p.Monto, p.Metodo
FROM dbo.Boletos b
LEFT JOIN dbo.Pagos p ON p.BoletoID = b.BoletoID
WHERE b.ViajeID = @ViajeID AND b.NumeroAsiento = @Asiento
ORDER BY b.BoletoID;

SELECT COUNT(*) AS BoletosActivosMismoAsiento   -- debe ser 1
FROM dbo.Boletos
WHERE ViajeID = @ViajeID AND NumeroAsiento = @Asiento AND Estado = 'Activo';
GO


/* =========================================================
   SECCIÓN 4 - REINICIAR LA DEMO (opcional)
   Anula el boleto de la prueba para poder repetirla con el mismo asiento
   ========================================================= */
USE BusRD;
DECLARE @ViajeID INT = 6585, @Asiento INT = 43;   -- <<< los mismos
DECLARE @id INT = (SELECT BoletoID FROM dbo.Boletos
                   WHERE ViajeID = @ViajeID AND NumeroAsiento = @Asiento AND Estado = 'Activo');
IF @id IS NOT NULL
    EXEC dbo.sp_AnularBoleto @BoletoID = @id;
GO
