USE BusRD;
GO
DECLARE @v INT, @a INT, @id INT, @rev INT;

SELECT TOP (1) @v = v.ViajeID, @a = s.NumeroAsiento
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.Estado = 'Programado'
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = v.ViajeID AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo')
ORDER BY v.ViajeID, s.NumeroAsiento DESC;

-- 1) Vender
EXEC dbo.sp_VenderBoleto @ViajeID=@v, @NumeroAsiento=@a, @ClienteID=1,
     @Canal='Taquilla', @Metodo='Efectivo', @BoletoID=@id OUTPUT;
PRINT CONCAT('1) Vendido. BoletoID = ', @id);

-- 2) Anular
EXEC dbo.sp_AnularBoleto @BoletoID=@id, @PagoReversoID=@rev OUTPUT;
PRINT CONCAT('2) Anulado. PagoReversoID = ', @rev);

-- 3) Anular otra vez -> 50011
BEGIN TRY
    EXEC dbo.sp_AnularBoleto @BoletoID=@id;
END TRY
BEGIN CATCH PRINT CONCAT('3) Error ', ERROR_NUMBER(), ': ', ERROR_MESSAGE()); END CATCH

-- 4) Boleto inexistente -> 50010
BEGIN TRY
    EXEC dbo.sp_AnularBoleto @BoletoID=99999999;
END TRY
BEGIN CATCH PRINT CONCAT('4) Error ', ERROR_NUMBER(), ': ', ERROR_MESSAGE()); END CATCH

-- 5) El asiento quedó libre: se puede vender de nuevo
DECLARE @id2 INT;
EXEC dbo.sp_VenderBoleto @ViajeID=@v, @NumeroAsiento=@a, @ClienteID=2,
     @Canal='Web', @Metodo='Tarjeta', @BoletoID=@id2 OUTPUT;
PRINT CONCAT('5) Asiento revendido. BoletoID = ', @id2);

-- Evidencia: boleto anulado con pago y reverso, y el nuevo boleto activo
SELECT b.BoletoID, b.NumeroAsiento, b.Estado, p.PagoID, p.Monto, p.Metodo
FROM dbo.Boletos b
LEFT JOIN dbo.Pagos p ON p.BoletoID = b.BoletoID
WHERE b.BoletoID IN (@id, @id2)
ORDER BY b.BoletoID, p.PagoID;
GO