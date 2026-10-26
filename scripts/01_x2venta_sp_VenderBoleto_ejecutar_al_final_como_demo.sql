
-- Seleccionar la base de datos del sistema de autobuses
USE BusRD;
GO

-- Intentar vender un boleto por medio de la página web
EXEC dbo.sp_VenderBoleto_v0
    @ViajeID = 16000,
    @NumeroAsiento = 43,
    @ClienteID = 6585,
    @Canal = 'Web',
    @Metodo = 'Tarjeta';
GO

-- Intentar vender el mismo asiento en la taquilla
USE BusRD;
GO

EXEC dbo.sp_VenderBoleto_v0
    @ViajeID = 16000,
    @NumeroAsiento = 43,
    @ClienteID = 6585,
    @Canal = 'Taquilla',
    @Metodo = 'Efectivo';
GO

-- Consultar los datos del boleto correspondiente al viaje y asiento indicados
SELECT
    BoletoID,
    ViajeID,
    NumeroAsiento,
    ClienteID,
    Canal,
    Estado,
    FechaVenta
FROM dbo.Boletos
WHERE ViajeID = 16000
  AND NumeroAsiento = 43;
GO
