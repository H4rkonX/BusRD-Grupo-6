USE BusRD;
GO
DECLARE @v INT, @a INT, @vc INT, @id INT;

-- Un viaje Programado con un asiento libre (puedes poner el de tu grupo en @v)
SELECT TOP (1) @v = v.ViajeID, @a = s.NumeroAsiento
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.Estado = 'Programado'
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = v.ViajeID
                    AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo')
ORDER BY v.ViajeID, s.NumeroAsiento;

-- Un viaje que NO está Programado
SELECT TOP (1) @vc = ViajeID FROM dbo.Viajes WHERE Estado = 'Completado';

PRINT CONCAT('Viaje de prueba ', @v, '  Asiento ', @a, '  Viaje completado ', @vc);

-- 1) Venta correcta
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @v, @a, 1, 'Taquilla', 'Efectivo', @id OUTPUT;
    PRINT CONCAT('1) OK. BoletoID = ', @id);
END TRY
BEGIN CATCH PRINT CONCAT('1) Error ', ERROR_NUMBER(), ' ', ERROR_MESSAGE()); END CATCH

-- 2) Mismo asiento otra vez - 50007
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @v, @a, 2, 'Web', 'Tarjeta', @id OUTPUT;
    PRINT '2) ERROR permitió la doble venta';
END TRY
BEGIN CATCH PRINT CONCAT('2) Error ', ERROR_NUMBER(), ' ', ERROR_MESSAGE()); END CATCH

-- 3) Viaje inexistente - 50003
BEGIN TRY
    EXEC dbo.sp_VenderBoleto 99999999, 1, 1, 'Web', 'Tarjeta', @id OUTPUT;
END TRY
BEGIN CATCH PRINT CONCAT('3) Error ', ERROR_NUMBER(), ' ', ERROR_MESSAGE()); END CATCH

-- 4) Viaje no Programado - 50004
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @vc, 1, 1, 'Web', 'Tarjeta', @id OUTPUT;
END TRY
BEGIN CATCH PRINT CONCAT('4) Error ', ERROR_NUMBER(), ' ', ERROR_MESSAGE()); END CATCH

-- 5) Asiento inexistente - 50005
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @v, 999, 1, 'Web', 'Tarjeta', @id OUTPUT;
END TRY
BEGIN CATCH PRINT CONCAT('5) Error ', ERROR_NUMBER(), ' ', ERROR_MESSAGE()); END CATCH

-- 6) Cliente inexistente - 50006
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @v, 1, 99999999, 'Web', 'Tarjeta', @id OUTPUT;
END TRY
BEGIN CATCH PRINT CONCAT('6) Error ', ERROR_NUMBER(), ' ', ERROR_MESSAGE()); END CATCH

-- 7) Canal inválido - 50001
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @v, 1, 1, 'Fax', 'Tarjeta', @id OUTPUT;
END TRY
BEGIN CATCH PRINT CONCAT('7) Error ', ERROR_NUMBER(), ' ', ERROR_MESSAGE()); END CATCH

-- 8) Método inválido - 50002
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @v, 1, 1, 'Web', 'Cheque', @id OUTPUT;
END TRY
BEGIN CATCH PRINT CONCAT('8) Error ', ERROR_NUMBER(), ' ', ERROR_MESSAGE()); END CATCH

-- Evidencia el boleto y su pago de la prueba 1
SELECT b.BoletoID, b.ViajeID, b.NumeroAsiento, b.Estado, p.Monto, p.Metodo
FROM dbo.Boletos b JOIN dbo.Pagos p ON p.BoletoID = b.BoletoID
WHERE b.BoletoID = @id OR (b.ViajeID = @v AND b.NumeroAsiento = @a AND b.Estado = 'Activo');
GO