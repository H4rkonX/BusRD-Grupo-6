/* =========================================================
   BusRD - E4. Seguridad (Unidad III)
   Roles: rol_taquilla, rol_reportes, rol_admin
   Usuarios de prueba sin login (CREATE USER ... WITHOUT LOGIN),
   probados con EXECUTE AS USER / REVERT.

   Ejecutar cada SECCIÓN completa (seleccionar y F5), en orden.
   Cada prueba imprime PERMITIDO o DENEGADO en la pestaña Messages
   ========================================================= */


/* =========================================================
   SECCIÓN 1 - VISTAS
   Las vistas pertenecen a dbo igual que las tablas, por lo que el
   encadenamiento de propiedad (ownership chaining) permite leer los datos
   a través de ellas sin dar permisos sobre las tablas.
   ========================================================= */
USE BusRD;
GO
CREATE OR ALTER VIEW dbo.vw_AsientosDisponibles
AS
SELECT v.ViajeID, r.Origen, r.Destino, v.FechaSalida,
       v.AutobusID, s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.Estado = 'Programado'
  AND NOT EXISTS (SELECT 1
                  FROM dbo.Boletos b
                  WHERE b.ViajeID = v.ViajeID
                    AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo');
GO

/* Solo datos agregados: no expone clientes ni sus datos personales */
CREATE OR ALTER VIEW dbo.vw_VentasMensuales
AS
SELECT r.Origen, r.Destino,
       YEAR(b.FechaVenta)  AS Anio,
       MONTH(b.FechaVenta) AS Mes,
       COUNT(*)            AS Boletos,
       SUM(p.Monto)        AS Ingresos
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, YEAR(b.FechaVenta), MONTH(b.FechaVenta);
GO


/* =========================================================
   SECCIÓN 2 - ROLES Y PERMISOS
   ========================================================= */
USE BusRD;
GO
/* Re-ejecución: quitar usuarios y roles previos */
DROP USER IF EXISTS usr_taquilla;
DROP USER IF EXISTS usr_reportes;
DROP USER IF EXISTS usr_admin;
DROP ROLE IF EXISTS rol_taquilla;
DROP ROLE IF EXISTS rol_reportes;
DROP ROLE IF EXISTS rol_admin;
GO

CREATE ROLE rol_taquilla;
CREATE ROLE rol_reportes;
CREATE ROLE rol_admin;
GO

/* --- rol_taquilla: solo EXECUTE sobre los 2 procedimientos y SELECT sobre
       la vista de asientos. Ningún permiso sobre tablas. --- */
GRANT EXECUTE ON OBJECT::dbo.sp_VenderBoleto  TO rol_taquilla;
GRANT EXECUTE ON OBJECT::dbo.sp_AnularBoleto  TO rol_taquilla;
GRANT SELECT  ON OBJECT::dbo.vw_AsientosDisponibles TO rol_taquilla;

/* --- rol_reportes: solo SELECT sobre la vista de ventas.
       Además se niega explícitamente Email y Telefono como defensa en
       profundidad (por si en el futuro se le concediera SELECT sobre Clientes). --- */
GRANT SELECT ON OBJECT::dbo.vw_VentasMensuales TO rol_reportes;
DENY  SELECT ON OBJECT::dbo.Clientes(Email, Telefono) TO rol_reportes;

/* --- rol_admin: administración completa de ESTA base de datos
       (no es sysadmin del servidor). --- */
ALTER ROLE db_owner ADD MEMBER rol_admin;
GO


/* =========================================================
   SECCIÓN 3 - USUARIOS DE PRUEBA (sin login) Y ASIGNACIÓN A ROLES
   ========================================================= */
USE BusRD;
GO
CREATE USER usr_taquilla WITHOUT LOGIN;
CREATE USER usr_reportes WITHOUT LOGIN;
CREATE USER usr_admin    WITHOUT LOGIN;

ALTER ROLE rol_taquilla ADD MEMBER usr_taquilla;
ALTER ROLE rol_reportes ADD MEMBER usr_reportes;
ALTER ROLE rol_admin    ADD MEMBER usr_admin;
GO


/* =========================================================
   SECCIÓN 4A - PRUEBAS rol_taquilla (usr_taquilla)
   Permitidos: ver asientos, vender boleto, anular boleto
   Denegados : leer Boletos, leer Clientes, borrar Boletos
   ========================================================= */
USE BusRD;
GO
SET NOCOUNT ON;
DECLARE @v INT, @a INT, @id INT;

/* Buscar un viaje Programado y un asiento libre (como dbo, antes del cambio de contexto) */
SELECT TOP (1) @v = ViajeID, @a = NumeroAsiento
FROM dbo.vw_AsientosDisponibles
ORDER BY ViajeID, NumeroAsiento DESC;

EXECUTE AS USER = 'usr_taquilla';
PRINT CONCAT('=== Contexto: ', USER_NAME(), ' (rol_taquilla) | viaje ', @v, ' asiento ', @a, ' ===');

-- PERMITIDO 1: consultar asientos disponibles por la vista
BEGIN TRY
    SELECT TOP (5) ViajeID, NumeroAsiento, Ubicacion
    FROM dbo.vw_AsientosDisponibles WHERE ViajeID = @v ORDER BY NumeroAsiento;
    PRINT '1) PERMITIDO: SELECT en vw_AsientosDisponibles';
END TRY
BEGIN CATCH PRINT CONCAT('1) DENEGADO (inesperado): ', ERROR_MESSAGE()); END CATCH

-- PERMITIDO 2: vender un boleto con el procedimiento (el INSERT en tablas funciona por ownership chaining)
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @ViajeID = @v, @NumeroAsiento = @a, @ClienteID = 1,
         @Canal = 'Taquilla', @Metodo = 'Efectivo', @BoletoID = @id OUTPUT;
    PRINT CONCAT('2) PERMITIDO: EXEC sp_VenderBoleto -> BoletoID ', @id);
END TRY
BEGIN CATCH PRINT CONCAT('2) DENEGADO (inesperado): ', ERROR_MESSAGE()); END CATCH

-- PERMITIDO 3: anular ese boleto con el procedimiento
BEGIN TRY
    EXEC dbo.sp_AnularBoleto @BoletoID = @id;
    PRINT CONCAT('3) PERMITIDO: EXEC sp_AnularBoleto -> boleto ', @id, ' anulado');
END TRY
BEGIN CATCH PRINT CONCAT('3) DENEGADO (inesperado): ', ERROR_MESSAGE()); END CATCH

-- DENEGADO 1: leer la tabla Boletos directamente
BEGIN TRY
    SELECT TOP (1) * FROM dbo.Boletos;
    PRINT '4) FALLO: se pudo leer dbo.Boletos';
END TRY
BEGIN CATCH PRINT CONCAT('4) DENEGADO (esperado): ', ERROR_MESSAGE()); END CATCH

-- DENEGADO 2: leer la tabla Clientes directamente
BEGIN TRY
    SELECT TOP (1) * FROM dbo.Clientes;
    PRINT '5) FALLO: se pudo leer dbo.Clientes';
END TRY
BEGIN CATCH PRINT CONCAT('5) DENEGADO (esperado): ', ERROR_MESSAGE()); END CATCH

-- DENEGADO 3: borrar boletos directamente (el WHERE no afecta: el permiso se evalúa antes)
BEGIN TRY
    DELETE FROM dbo.Boletos WHERE BoletoID = -1;
    PRINT '6) FALLO: se pudo ejecutar DELETE sobre dbo.Boletos';
END TRY
BEGIN CATCH PRINT CONCAT('6) DENEGADO (esperado): ', ERROR_MESSAGE()); END CATCH

REVERT;
PRINT CONCAT('Contexto restaurado: ', USER_NAME());
GO


/* =========================================================
   SECCIÓN 4B - PRUEBAS rol_reportes (usr_reportes)
   Permitidos: consultar vw_VentasMensuales (2 formas)
   Denegados : Email/Telefono de Clientes, tabla Boletos, ejecutar ventas
   ========================================================= */
USE BusRD;
GO
SET NOCOUNT ON;
EXECUTE AS USER = 'usr_reportes';
PRINT CONCAT('=== Contexto: ', USER_NAME(), ' (rol_reportes) ===');

-- PERMITIDO 1: reporte mensual de un año
BEGIN TRY
    SELECT TOP (10) Origen, Destino, Anio, Mes, Boletos, Ingresos
    FROM dbo.vw_VentasMensuales
    WHERE Anio = 2025
    ORDER BY Origen, Destino, Mes;
    PRINT '1) PERMITIDO: SELECT en vw_VentasMensuales (detalle 2025)';
END TRY
BEGIN CATCH PRINT CONCAT('1) DENEGADO (inesperado): ', ERROR_MESSAGE()); END CATCH

-- PERMITIDO 2: totales por ruta
BEGIN TRY
    SELECT TOP (5) Origen, Destino, SUM(Boletos) AS Boletos, SUM(Ingresos) AS Ingresos
    FROM dbo.vw_VentasMensuales
    GROUP BY Origen, Destino
    ORDER BY SUM(Ingresos) DESC;
    PRINT '2) PERMITIDO: totales por ruta desde vw_VentasMensuales';
END TRY
BEGIN CATCH PRINT CONCAT('2) DENEGADO (inesperado): ', ERROR_MESSAGE()); END CATCH

-- DENEGADO 1: Email y Telefono de clientes
BEGIN TRY
    SELECT TOP (1) Email, Telefono FROM dbo.Clientes;
    PRINT '3) FALLO: se pudo leer Email/Telefono';
END TRY
BEGIN CATCH PRINT CONCAT('3) DENEGADO (esperado): ', ERROR_MESSAGE()); END CATCH

-- DENEGADO 2: la tabla Boletos
BEGIN TRY
    SELECT TOP (1) * FROM dbo.Boletos;
    PRINT '4) FALLO: se pudo leer dbo.Boletos';
END TRY
BEGIN CATCH PRINT CONCAT('4) DENEGADO (esperado): ', ERROR_MESSAGE()); END CATCH

-- DENEGADO 3: vender un boleto (no tiene EXECUTE)
BEGIN TRY
    DECLARE @id INT;
    EXEC dbo.sp_VenderBoleto 1, 1, 1, 'Web', 'Tarjeta', @id OUTPUT;
    PRINT '5) FALLO: pudo ejecutar sp_VenderBoleto';
END TRY
BEGIN CATCH PRINT CONCAT('5) DENEGADO (esperado): ', ERROR_MESSAGE()); END CATCH

REVERT;
PRINT CONCAT('Contexto restaurado: ', USER_NAME());
GO


/* =========================================================
   SECCIÓN 4C - PRUEBAS rol_admin (usr_admin)
   Permitidos: leer tablas (incluye Email/Telefono), crear y borrar objetos
   Denegados : operaciones de SERVIDOR (crear logins, acceder a master).
               Es administrador de la base BusRD, no sysadmin.
   Nota: el texto exacto de los errores de las pruebas denegadas puede
   variar según la versión; lo importante es que sean rechazadas.
   ========================================================= */
USE BusRD;
GO
SET NOCOUNT ON;
EXECUTE AS USER = 'usr_admin';
PRINT CONCAT('=== Contexto: ', USER_NAME(), ' (rol_admin) ===');

-- PERMITIDO 1: leer tablas y datos personales
BEGIN TRY
    SELECT TOP (3) ClienteID, Nombre, Apellido, Email, Telefono FROM dbo.Clientes;
    PRINT '1) PERMITIDO: SELECT en dbo.Clientes (incluye Email y Telefono)';
END TRY
BEGIN CATCH PRINT CONCAT('1) DENEGADO (inesperado): ', ERROR_MESSAGE()); END CATCH

-- PERMITIDO 2: crear y borrar un objeto en la base
BEGIN TRY
    CREATE TABLE dbo.zz_prueba_admin(Id INT);
    DROP TABLE dbo.zz_prueba_admin;
    PRINT '2) PERMITIDO: CREATE TABLE / DROP TABLE';
END TRY
BEGIN CATCH PRINT CONCAT('2) DENEGADO (inesperado): ', ERROR_MESSAGE()); END CATCH

-- DENEGADO 1: crear un login (permiso de servidor)
BEGIN TRY
    CREATE LOGIN zz_login_prueba WITH PASSWORD = 'Pr0eba#Segura2026!';
    PRINT '3) FALLO: se pudo crear un login';
END TRY
BEGIN CATCH PRINT CONCAT('3) DENEGADO (esperado): ', ERROR_MESSAGE()); END CATCH

-- DENEGADO 2: acceder a otra base del servidor
BEGIN TRY
    SELECT TOP (1) name FROM master.sys.databases;
    PRINT '4) FALLO: se pudo acceder a master';
END TRY
BEGIN CATCH PRINT CONCAT('4) DENEGADO (esperado): ', ERROR_MESSAGE()); END CATCH

REVERT;
PRINT CONCAT('Contexto restaurado: ', USER_NAME());
GO

/* Seguridad: si por algún motivo se llegó a crear el login de prueba, quitarlo */
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'zz_login_prueba')
    DROP LOGIN zz_login_prueba;
GO


/* =========================================================
   SECCIÓN 5 - MATRIZ DE ROLES Y PERMISOS (evidencia para el informe)
   ========================================================= */
USE BusRD;
GO
-- Membresía: usuario -> rol
SELECT r.name AS Rol, m.name AS Usuario
FROM sys.database_role_members rm
JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
WHERE r.name IN ('rol_taquilla','rol_reportes','rol_admin')
ORDER BY r.name;

-- Permisos explícitos de cada rol
SELECT pr.name AS Rol,
       dp.state_desc AS Estado,
       dp.permission_name AS Permiso,
       OBJECT_NAME(dp.major_id) AS Objeto,
       COL_NAME(dp.major_id, dp.minor_id) AS Columna
FROM sys.database_permissions dp
JOIN sys.database_principals pr ON pr.principal_id = dp.grantee_principal_id
WHERE pr.name IN ('rol_taquilla','rol_reportes','rol_admin')
ORDER BY pr.name, Objeto, Permiso;

-- rol_admin es miembro de db_owner
SELECT r.name AS RolFijo, m.name AS Miembro
FROM sys.database_role_members rm
JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
WHERE r.name = 'db_owner' AND m.name = 'rol_admin';
GO
