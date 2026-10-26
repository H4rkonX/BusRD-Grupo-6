/* =========================================================
   BusRD - E5. Respaldo y recuperación (Unidad III)
   Carpeta de respaldos: C:\Backups\BusRD\

   Ejecutar cada PASO completo (seleccionar y F5), en orden. NO saltar pasos ni
   cambiar el orden: la restauración depende de la secuencia exacta.

     PASO 0  Carpeta y modelo de recuperación FULL
     PASO A  Tabla de control + backup FULL
     PASO B  Vender 5 boletos
     PASO C  Backup DIFERENCIAL
     PASO D  Vender 3 boletos
     PASO E  Backup de LOG
     PASO F  Anotar la hora exacta
     PASO G  Simular el error: DELETE de los boletos del viaje asignado
     PASO H  Backup de LOG de cola
     PASO I  Restaurar en BusRD_Recuperada hasta un momento antes del DELETE
     PASO J  Verificación
     PASO K  Historial de respaldos (evidencia)
   ========================================================= */


/* =========================================================
   PASO 0 - CARPETA Y MODELO DE RECUPERACIÓN FULL
   Justificación: en SIMPLE el log se trunca solo y NO se pueden hacer
   backups de log ni restaurar a un punto en el tiempo (STOPAT); solo se
   puede volver al último full/diferencial. En FULL el log se conserva
   hasta que se respalda, lo que permite recuperar hasta justo antes de un
   error (como un DELETE accidental) y limita la pérdida de datos al
   intervalo entre backups de log.
   ========================================================= */
USE master;
GO
-- Crea la carpeta con los permisos del servicio de SQL Server
-- (si falla, crearla a mano: C:\Backups\BusRD)
BEGIN TRY
    EXEC master.dbo.xp_create_subdir N'C:\Backups\BusRD';
    PRINT 'Carpeta C:\Backups\BusRD lista.';
END TRY
BEGIN CATCH
    PRINT CONCAT('No se pudo crear la carpeta automáticamente: ', ERROR_MESSAGE());
    PRINT 'Crearla a mano y dar control total a la cuenta del servicio de SQL Server.';
END CATCH
GO
ALTER DATABASE BusRD SET RECOVERY FULL;
GO
SELECT name AS BaseDeDatos, recovery_model_desc AS ModeloRecuperacion
FROM sys.databases WHERE name = 'BusRD';
GO


/* =========================================================
   PASO A - TABLA DE CONTROL + BACKUP FULL
   dbo.Prueba_Respaldo guarda los datos de la prueba (IDs vendidos, hora,
   conteos) para usarlos luego en la restauración y la verificación.
   ========================================================= */
USE BusRD;
GO
DROP TABLE IF EXISTS dbo.Prueba_Respaldo;
CREATE TABLE dbo.Prueba_Respaldo(
    Id       INT IDENTITY PRIMARY KEY,
    Paso     VARCHAR(30) NOT NULL,
    BoletoID INT         NULL,
    Hora     DATETIME    NULL,
    Cantidad INT         NULL
);
GO
BACKUP DATABASE BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_FULL.bak'
WITH INIT, FORMAT, CHECKSUM, STATS = 25, NAME = N'BusRD - Full';
GO


/* =========================================================
   PASO B - VENDER 5 BOLETOS (con sp_VenderBoleto)
   ========================================================= */
USE BusRD;
GO
SET NOCOUNT ON;
DECLARE @v INT, @a INT, @id INT, @i INT = 1;
SELECT TOP (1) @v = ViajeID FROM dbo.Viajes WHERE Estado = 'Programado' ORDER BY ViajeID;

WHILE @i <= 5
BEGIN
    SELECT TOP (1) @a = s.NumeroAsiento
    FROM dbo.Viajes v
    JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
    WHERE v.ViajeID = @v
      AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                      WHERE b.ViajeID = @v AND b.NumeroAsiento = s.NumeroAsiento
                        AND b.Estado = 'Activo')
    ORDER BY s.NumeroAsiento DESC;

    EXEC dbo.sp_VenderBoleto @ViajeID = @v, @NumeroAsiento = @a, @ClienteID = 6000,
         @Canal = 'Taquilla', @Metodo = 'Efectivo', @BoletoID = @id OUTPUT;
    INSERT dbo.Prueba_Respaldo(Paso, BoletoID, Hora) VALUES ('Venta', @id, GETDATE());
    SET @i += 1;
END

SELECT BoletoID, ViajeID, NumeroAsiento, ClienteID, FechaVenta, Estado
FROM dbo.Boletos
WHERE BoletoID IN (SELECT BoletoID FROM dbo.Prueba_Respaldo WHERE Paso = 'Venta');
GO


/* =========================================================
   PASO C - BACKUP DIFERENCIAL
   ========================================================= */
BACKUP DATABASE BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_DIFF.bak'
WITH DIFFERENTIAL, INIT, FORMAT, CHECKSUM, STATS = 25, NAME = N'BusRD - Diferencial';
GO


/* =========================================================
   PASO D - VENDER 3 BOLETOS MÁS
   ========================================================= */
USE BusRD;
GO
SET NOCOUNT ON;
DECLARE @v INT, @a INT, @id INT, @i INT = 1;
SELECT TOP (1) @v = ViajeID FROM dbo.Viajes WHERE Estado = 'Programado' ORDER BY ViajeID;

WHILE @i <= 3
BEGIN
    SELECT TOP (1) @a = s.NumeroAsiento
    FROM dbo.Viajes v
    JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
    WHERE v.ViajeID = @v
      AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                      WHERE b.ViajeID = @v AND b.NumeroAsiento = s.NumeroAsiento
                        AND b.Estado = 'Activo')
    ORDER BY s.NumeroAsiento DESC;

    EXEC dbo.sp_VenderBoleto @ViajeID = @v, @NumeroAsiento = @a, @ClienteID = 6000,
         @Canal = 'Web', @Metodo = 'Tarjeta', @BoletoID = @id OUTPUT;
    INSERT dbo.Prueba_Respaldo(Paso, BoletoID, Hora) VALUES ('Venta', @id, GETDATE());
    SET @i += 1;
END

SELECT COUNT(*) AS BoletosVendidosEnLaPrueba   -- debe ser 8
FROM dbo.Prueba_Respaldo WHERE Paso = 'Venta';
GO


/* =========================================================
   PASO E - BACKUP DE LOG
   ========================================================= */
BACKUP LOG BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_LOG1.trn'
WITH INIT, FORMAT, CHECKSUM, STATS = 25, NAME = N'BusRD - Log 1';
GO


/* =========================================================
   PASO F - ANOTAR LA HORA EXACTA (y los datos de referencia)
   Se guarda la hora de referencia y, 2 segundos después, el PASO G
   ejecuta el DELETE, de modo que STOPAT = esta hora queda
   estrictamente ANTES del borrado.
   ========================================================= */
USE BusRD;
GO
DECLARE @ViajeAsignado INT = 16000;   -- <<< viaje asignado al grupo (PROVISIONAL)

DELETE FROM dbo.Prueba_Respaldo WHERE Paso IN ('ViajeAsignado','BoletosViaje','PagosViaje','HoraAntesDelete');

INSERT dbo.Prueba_Respaldo(Paso, Cantidad) VALUES ('ViajeAsignado', @ViajeAsignado);
INSERT dbo.Prueba_Respaldo(Paso, Cantidad)
    SELECT 'BoletosViaje', COUNT(*) FROM dbo.Boletos WHERE ViajeID = @ViajeAsignado;
INSERT dbo.Prueba_Respaldo(Paso, Cantidad)
    SELECT 'PagosViaje', COUNT(*)
    FROM dbo.Pagos p JOIN dbo.Boletos b ON b.BoletoID = p.BoletoID
    WHERE b.ViajeID = @ViajeAsignado;

WAITFOR DELAY '00:00:02';

DECLARE @Hora DATETIME = GETDATE();
INSERT dbo.Prueba_Respaldo(Paso, Hora) VALUES ('HoraAntesDelete', @Hora);

SELECT CONVERT(VARCHAR(23), @Hora, 121) AS HoraExacta_ANOTAR_para_STOPAT;
SELECT Paso, Cantidad FROM dbo.Prueba_Respaldo
WHERE Paso IN ('ViajeAsignado','BoletosViaje','PagosViaje');
GO


/* =========================================================
   PASO G - SIMULAR EL ERROR: borrar TODOS los boletos del viaje asignado
   Como Pagos tiene llave foránea a Boletos, primero se borran los pagos
   de esos boletos y luego los boletos (en una sola transacción), tal como
   haría alguien que borra "por error" los boletos de un viaje.
   ========================================================= */
USE BusRD;
GO
WAITFOR DELAY '00:00:02';

DECLARE @v INT = (SELECT Cantidad FROM dbo.Prueba_Respaldo WHERE Paso = 'ViajeAsignado');

BEGIN TRAN;
    DELETE p FROM dbo.Pagos p JOIN dbo.Boletos b ON b.BoletoID = p.BoletoID WHERE b.ViajeID = @v;
    DELETE FROM dbo.Boletos WHERE ViajeID = @v;
COMMIT TRAN;

SELECT COUNT(*) AS BoletosDelViajeDespuesDelDelete   -- debe ser 0
FROM dbo.Boletos WHERE ViajeID = @v;
GO


/* =========================================================
   PASO H - BACKUP DE LOG DE COLA
   Captura todo lo ocurrido desde el último log, incluido el DELETE.
   ========================================================= */
BACKUP LOG BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_LOG_COLA.trn'
WITH INIT, FORMAT, CHECKSUM, STATS = 25, NAME = N'BusRD - Log de cola';
GO


/* =========================================================
   PASO I - RESTAURAR EN BusRD_Recuperada HASTA ANTES DEL DELETE (STOPAT)
   Secuencia: FULL (NORECOVERY) -> DIFF (NORECOVERY) -> LOG1 (NORECOVERY)
              -> LOG DE COLA con STOPAT y RECOVERY
   La hora se toma de la tabla de control (PASO F). No se toca BusRD.
   ========================================================= */
USE master;
GO
SET NOCOUNT ON;
DECLARE @t DATETIME = (SELECT Hora FROM BusRD.dbo.Prueba_Respaldo WHERE Paso = 'HoraAntesDelete');
IF @t IS NULL THROW 50020, 'No se encontró la hora del PASO F en BusRD.dbo.Prueba_Respaldo.', 1;

DECLARE @dat NVARCHAR(128), @log NVARCHAR(128), @pd NVARCHAR(260), @pl NVARCHAR(260), @sql NVARCHAR(MAX);
SELECT @dat = name FROM sys.master_files WHERE database_id = DB_ID('BusRD') AND type = 0;
SELECT @log = name FROM sys.master_files WHERE database_id = DB_ID('BusRD') AND type = 1;
SET @pd = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(260));
SET @pl = CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS NVARCHAR(260));

IF DB_ID('BusRD_Recuperada') IS NOT NULL
BEGIN
    ALTER DATABASE BusRD_Recuperada SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BusRD_Recuperada;
END

PRINT CONCAT('STOPAT = ', CONVERT(VARCHAR(23), @t, 121));

SET @sql = CONCAT(N'RESTORE DATABASE BusRD_Recuperada FROM DISK = N''C:\Backups\BusRD\BusRD_FULL.bak'' ',
                  N'WITH MOVE N''', @dat, N''' TO N''', @pd, N'BusRD_Recuperada.mdf'', ',
                  N'MOVE N''', @log, N''' TO N''', @pl, N'BusRD_Recuperada_log.ldf'', NORECOVERY, STATS = 25;');
EXEC (@sql);

EXEC (N'RESTORE DATABASE BusRD_Recuperada FROM DISK = N''C:\Backups\BusRD\BusRD_DIFF.bak'' WITH NORECOVERY, STATS = 25;');

EXEC (N'RESTORE LOG BusRD_Recuperada FROM DISK = N''C:\Backups\BusRD\BusRD_LOG1.trn'' WITH NORECOVERY, STATS = 25;');

SET @sql = CONCAT(N'RESTORE LOG BusRD_Recuperada FROM DISK = N''C:\Backups\BusRD\BusRD_LOG_COLA.trn'' ',
                  N'WITH STOPAT = ''', CONVERT(VARCHAR(23), @t, 121), N''', RECOVERY, STATS = 25;');
EXEC (@sql);
GO


/* =========================================================
   PASO J - VERIFICACIÓN
   - Los 8 boletos vendidos existen en la base recuperada
   - Los boletos borrados del viaje asignado se recuperaron
   - En BusRD (producción) siguen borrados
   ========================================================= */
USE master;
GO
DECLARE @v INT   = (SELECT Cantidad FROM BusRD.dbo.Prueba_Respaldo WHERE Paso = 'ViajeAsignado');
DECLARE @bEsp INT = (SELECT Cantidad FROM BusRD.dbo.Prueba_Respaldo WHERE Paso = 'BoletosViaje');
DECLARE @pEsp INT = (SELECT Cantidad FROM BusRD.dbo.Prueba_Respaldo WHERE Paso = 'PagosViaje');

DECLARE @vendidos INT = (SELECT COUNT(*) FROM BusRD_Recuperada.dbo.Boletos
                         WHERE BoletoID IN (SELECT BoletoID FROM BusRD.dbo.Prueba_Respaldo WHERE Paso = 'Venta'));
DECLARE @recB INT = (SELECT COUNT(*) FROM BusRD_Recuperada.dbo.Boletos WHERE ViajeID = @v);
DECLARE @recP INT = (SELECT COUNT(*) FROM BusRD_Recuperada.dbo.Pagos p
                     JOIN BusRD_Recuperada.dbo.Boletos b ON b.BoletoID = p.BoletoID
                     WHERE b.ViajeID = @v);
DECLARE @prodB INT = (SELECT COUNT(*) FROM BusRD.dbo.Boletos WHERE ViajeID = @v);

SELECT 'Boletos vendidos presentes en BusRD_Recuperada (esperado 8)' AS Verificacion,
       @vendidos AS Obtenido, 8 AS Esperado,
       CASE WHEN @vendidos = 8 THEN 'OK' ELSE 'FALLA' END AS Resultado
UNION ALL
SELECT 'Boletos del viaje asignado en BusRD_Recuperada', @recB, @bEsp,
       CASE WHEN @recB = @bEsp AND @bEsp > 0 THEN 'OK' ELSE 'FALLA' END
UNION ALL
SELECT 'Pagos de esos boletos en BusRD_Recuperada', @recP, @pEsp,
       CASE WHEN @recP = @pEsp AND @pEsp > 0 THEN 'OK' ELSE 'FALLA' END
UNION ALL
SELECT 'Boletos del viaje asignado en BusRD (siguen borrados)', @prodB, 0,
       CASE WHEN @prodB = 0 THEN 'OK' ELSE 'REVISAR' END;
GO


/* =========================================================
   PASO K - HISTORIAL DE RESPALDOS (evidencia de la secuencia)
   ========================================================= */
SELECT bs.backup_start_date AS Inicio,
       CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFERENCIAL' WHEN 'L' THEN 'LOG' END AS Tipo,
       bmf.physical_device_name AS Archivo
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.database_name = 'BusRD'
  AND bmf.physical_device_name LIKE 'C:\Backups\BusRD\%'
ORDER BY bs.backup_start_date;
GO
