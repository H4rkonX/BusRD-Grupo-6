/* =========================================================
   BusRD - E2.4 Prueba de concurrencia con sp_VenderBoleto
   SESIÓN B (ventana 2)

   Ejecutar DESPUÉS de lanzar la sección 2 del archivo 04 (sesión A),
   con menos de 10 segundos de diferencia.
   Usar el MISMO viaje y el MISMO asiento que la sesión A.

   Resultado esperado: la sesión B queda esperando (bloqueada por A)
   y cuando A confirma, B recibe el error 50007 "El asiento ya está vendido".
   ========================================================= */
USE BusRD;
DECLARE @ViajeID INT = 6585,      -- <<< el MISMO viaje de la sesión A
        @Asiento INT = 43,     -- <<< el MISMO asiento de la sesión A
        @BoletoID INT,
        @t0 DATETIME2(3) = SYSDATETIME();

PRINT CONCAT('Sesión B inicia: ', CONVERT(VARCHAR(23), @t0, 121));

BEGIN TRY
    EXEC dbo.sp_VenderBoleto
         @ViajeID = @ViajeID, @NumeroAsiento = @Asiento,
         @ClienteID = 2, @Canal = 'Web', @Metodo = 'Tarjeta',
         @BoletoID = @BoletoID OUTPUT, @SimularDemora = 1;

    PRINT CONCAT('Sesión B: ERROR, la venta se completó. BoletoID = ', @BoletoID);
END TRY
BEGIN CATCH
    PRINT CONCAT('Sesión B RECHAZADA - Error ', ERROR_NUMBER(), ': ', ERROR_MESSAGE());
END CATCH

PRINT CONCAT('Sesión B termina: ', CONVERT(VARCHAR(23), SYSDATETIME(), 121),
             ' | Tiempo esperando (ms) = ', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
GO
