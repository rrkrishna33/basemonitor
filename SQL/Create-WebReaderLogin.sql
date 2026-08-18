-- ============================================================
-- Creates a dedicated, read-only SQL login for the WebApp dashboard.
-- Run this manually on the central repository server
-- (OVHWEDEV-SQL027\OVHCHN_DEV01). Requires Mixed Mode authentication
-- to be enabled on the instance (Server Properties > Security).
-- ============================================================

USE master;
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'WebMonitorReader')
BEGIN
    CREATE LOGIN WebMonitorReader WITH PASSWORD = 'CHANGE_ME_STRONG_PASSWORD', CHECK_POLICY = ON;
END
GO

USE CHN_DBA;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'WebMonitorReader')
BEGIN
    CREATE USER WebMonitorReader FOR LOGIN WebMonitorReader;
END
GO

ALTER ROLE db_datareader ADD MEMBER WebMonitorReader;
GO
