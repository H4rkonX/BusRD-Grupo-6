/* =========================================================
   BusRD - Script base del Trabajo Final ISW-323
   Crea la BD, las tablas y genera los datos de prueba.
   ========================================================= */
USE master;
GO
IF DB_ID('BusRD') IS NOT NULL
BEGIN
    ALTER DATABASE BusRD SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BusRD;
END
GO
CREATE DATABASE BusRD;
GO
ALTER DATABASE BusRD SET RECOVERY SIMPLE;
GO
USE BusRD;
GO

/* ---------- Tablas (solo PK, sin FK ni CHECK) ---------- */
CREATE TABLE dbo.Rutas(
    RutaID       INT IDENTITY PRIMARY KEY,
    Origen       VARCHAR(50)   NOT NULL,
    Destino      VARCHAR(50)   NOT NULL,
    DistanciaKm  INT           NOT NULL,
    PrecioBase   DECIMAL(10,2) NOT NULL
);

CREATE TABLE dbo.Autobuses(
    AutobusID  INT IDENTITY PRIMARY KEY,
    Placa      VARCHAR(10) NOT NULL,
    Tipo       VARCHAR(20) NOT NULL,      -- 'Estandar' | 'Ejecutivo'
    Capacidad  INT         NOT NULL
);

CREATE TABLE dbo.Asientos(
    AutobusID      INT         NOT NULL,
    NumeroAsiento  INT         NOT NULL,
    Ubicacion      VARCHAR(10) NOT NULL,  -- 'Ventana' | 'Pasillo'
    CONSTRAINT PK_Asientos PRIMARY KEY (AutobusID, NumeroAsiento)
);

CREATE TABLE dbo.Viajes(
    ViajeID      INT IDENTITY PRIMARY KEY,
    RutaID       INT          NOT NULL,
    AutobusID    INT          NOT NULL,
    FechaSalida  DATETIME2(0) NOT NULL,
    Estado       VARCHAR(15)  NOT NULL    -- 'Programado' | 'Completado' | 'Cancelado'
);

CREATE TABLE dbo.Clientes(
    ClienteID      INT IDENTITY PRIMARY KEY,
    Cedula         CHAR(11)     NOT NULL,
    Nombre         VARCHAR(50)  NOT NULL,
    Apellido       VARCHAR(50)  NOT NULL,
    Email          VARCHAR(100) NULL,
    Telefono       VARCHAR(15)  NULL,
    FechaRegistro  DATE         NOT NULL
);

CREATE TABLE dbo.Boletos(
    BoletoID       INT IDENTITY PRIMARY KEY,
    ViajeID        INT           NOT NULL,
    NumeroAsiento  INT           NOT NULL,
    ClienteID      INT           NOT NULL,
    FechaVenta     DATETIME2(0)  NOT NULL,
    Canal          VARCHAR(10)   NOT NULL, -- 'Taquilla' | 'Web'
    Precio         DECIMAL(10,2) NOT NULL,
    Estado         VARCHAR(10)   NOT NULL  -- 'Activo' | 'Anulado'
);

CREATE TABLE dbo.Pagos(
    PagoID     INT IDENTITY PRIMARY KEY,
    BoletoID   INT           NOT NULL,
    Monto      DECIMAL(10,2) NOT NULL,
    Metodo     VARCHAR(15)   NOT NULL,     -- 'Efectivo' | 'Tarjeta' | 'Transferencia'
    FechaPago  DATETIME2(0)  NOT NULL
);
GO

/* ---------- Tabla auxiliar de números ---------- */
IF OBJECT_ID('tempdb..#Num') IS NOT NULL DROP TABLE #Num;
SELECT TOP (100000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
INTO #Num
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
CREATE UNIQUE CLUSTERED INDEX IX_Num ON #Num(n);
GO

/* ---------- Rutas (20: ida y vuelta) ---------- */
DECLARE @r TABLE (Ciudad VARCHAR(50), Km INT, Precio DECIMAL(10,2));
INSERT @r VALUES
 ('Santiago',155,420),('Punta Cana',195,500),('La Romana',120,350),
 ('Puerto Plata',215,550),('San Francisco de Macorís',135,400),
 ('La Vega',125,360),('Barahona',200,480),('Samaná',170,450),
 ('San Pedro de Macorís',75,250),('Higüey',150,400);

INSERT dbo.Rutas(Origen,Destino,DistanciaKm,PrecioBase)
SELECT 'Santo Domingo', Ciudad, Km, Precio FROM @r
UNION ALL
SELECT Ciudad, 'Santo Domingo', Km, Precio FROM @r;
GO

/* ---------- Autobuses (40) y Asientos ---------- */
INSERT dbo.Autobuses(Placa,Tipo,Capacidad)
SELECT 'I' + CAST(100000 + n AS VARCHAR(6)),
       CASE WHEN n % 4 = 0 THEN 'Ejecutivo' ELSE 'Estandar' END,
       CASE WHEN n % 4 = 0 THEN 32 ELSE 44 END
FROM #Num WHERE n <= 40;

INSERT dbo.Asientos(AutobusID,NumeroAsiento,Ubicacion)
SELECT a.AutobusID, x.n,
       CASE WHEN x.n % 4 IN (0,1) THEN 'Ventana' ELSE 'Pasillo' END
FROM dbo.Autobuses a
JOIN #Num x ON x.n <= a.Capacidad;
GO

/* ---------- Viajes: 1 diario por ruta, oct-2024 a dic-2026 ---------- */
DECLARE @ini DATE = '2024-10-01', @dias INT = 822;
INSERT dbo.Viajes(RutaID,AutobusID,FechaSalida,Estado)
SELECT r.RutaID,
       ((r.RutaID * 7 + d.n) % 40) + 1,
       DATEADD(HOUR, 6 + (r.RutaID % 12),
               CAST(DATEADD(DAY, d.n - 1, @ini) AS DATETIME2(0))),
       CASE WHEN DATEADD(DAY, d.n - 1, @ini) >= '2026-10-15' THEN 'Programado'
            WHEN ABS(CHECKSUM(NEWID())) % 50 = 0             THEN 'Cancelado'
            ELSE 'Completado' END
FROM dbo.Rutas r
CROSS JOIN #Num d
WHERE d.n <= @dias;
GO

/* ---------- Clientes (50,000) ---------- */
INSERT dbo.Clientes(Cedula,Nombre,Apellido,Email,Telefono,FechaRegistro)
SELECT '402' + RIGHT('00000000' + CAST(n AS VARCHAR(8)), 8),
       CHOOSE(n % 10 + 1,'Juan','María','Pedro','Ana','Luis',
                         'Carmen','José','Rosa','Miguel','Laura'),
       CHOOSE((n / 10) % 10 + 1,'Pérez','Rodríguez','Martínez','García','Santos',
                                'Reyes','Díaz','Núñez','Peña','Jiménez'),
       'cliente' + CAST(n AS VARCHAR(10)) + '@correo.do',
       '809' + RIGHT('0000000' + CAST(n AS VARCHAR(7)), 7),
       DATEADD(DAY, -(n % 1500), '2026-10-01')
FROM #Num WHERE n <= 50000;
GO

/* ---------- Boletos (~230,000) ---------- */
IF OBJECT_ID('tempdb..#Ocup') IS NOT NULL DROP TABLE #Ocup;
SELECT v.ViajeID, r.PrecioBase, a.Capacidad,
       FechaRef = CASE WHEN v.FechaSalida > '2026-10-14T12:00:00'
                       THEN CAST('2026-10-14T12:00:00' AS DATETIME2(0))
                       ELSE v.FechaSalida END,
       Ocup = CASE WHEN v.Estado = 'Programado'
                   THEN ABS(CHECKSUM(NEWID())) % 8 + 1
                   ELSE ABS(CHECKSUM(NEWID())) % 20 + 6 END
INTO #Ocup
FROM dbo.Viajes v
JOIN dbo.Rutas r     ON r.RutaID = v.RutaID
JOIN dbo.Autobuses a ON a.AutobusID = v.AutobusID
WHERE v.Estado <> 'Cancelado';

INSERT dbo.Boletos(ViajeID,NumeroAsiento,ClienteID,FechaVenta,Canal,Precio,Estado)
SELECT o.ViajeID,
       ((x.n * 7 + o.ViajeID) % o.Capacidad) + 1,
       ABS(CHECKSUM(NEWID())) % 50000 + 1,
       DATEADD(MINUTE, -(ABS(CHECKSUM(NEWID())) % 20160), o.FechaRef), -- hasta 14 días antes
       CASE WHEN ABS(CHECKSUM(NEWID())) % 10 < 6 THEN 'Taquilla' ELSE 'Web' END,
       o.PrecioBase,
       CASE WHEN ABS(CHECKSUM(NEWID())) % 40 = 0 THEN 'Anulado' ELSE 'Activo' END
FROM #Ocup o
JOIN #Num x ON x.n <= o.Ocup;
GO

/* ---------- Datos sucios: asientos vendidos dos veces ---------- */
INSERT dbo.Boletos(ViajeID,NumeroAsiento,ClienteID,FechaVenta,Canal,Precio,Estado)
SELECT TOP (60) ViajeID, NumeroAsiento,
       ABS(CHECKSUM(NEWID())) % 50000 + 1,
       DATEADD(MINUTE, 1, FechaVenta), 'Web', Precio, 'Activo'
FROM dbo.Boletos
WHERE Estado = 'Activo'
ORDER BY NEWID();
GO

/* ---------- Pagos ---------- */
INSERT dbo.Pagos(BoletoID,Monto,Metodo,FechaPago)
SELECT BoletoID, Precio,
       CASE WHEN Canal = 'Web'
            THEN CASE WHEN ABS(CHECKSUM(NEWID())) % 3 = 0 THEN 'Transferencia' ELSE 'Tarjeta' END
            ELSE CASE WHEN ABS(CHECKSUM(NEWID())) % 3 = 0 THEN 'Tarjeta' ELSE 'Efectivo' END
       END,
       FechaVenta
FROM dbo.Boletos
WHERE Estado = 'Activo';

/* Datos sucios: pagos huérfanos */
INSERT dbo.Pagos(BoletoID,Monto,Metodo,FechaPago)
SELECT 900000 + n, 300, 'Efectivo', '2025-05-01'
FROM #Num WHERE n <= 15;
GO

/* ---------- Verificación ---------- */
SELECT 'Rutas' Tabla, COUNT(*) Filas FROM dbo.Rutas UNION ALL
SELECT 'Autobuses', COUNT(*) FROM dbo.Autobuses UNION ALL
SELECT 'Asientos',  COUNT(*) FROM dbo.Asientos  UNION ALL
SELECT 'Viajes',    COUNT(*) FROM dbo.Viajes    UNION ALL
SELECT 'Clientes',  COUNT(*) FROM dbo.Clientes  UNION ALL
SELECT 'Boletos',   COUNT(*) FROM dbo.Boletos   UNION ALL
SELECT 'Pagos',     COUNT(*) FROM dbo.Pagos;