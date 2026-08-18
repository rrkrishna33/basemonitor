-- ============================================================
-- SQL Server Metrics Database Schema
-- Run this once on the CENTRAL metrics repository server
-- ============================================================

IF DB_ID('CHN_DBA') IS NULL
BEGIN
    CREATE DATABASE CHN_DBA;
END
GO

USE CHN_DBA;
GO

-- ----------------------------------------------------------
-- Monitored Instances registry
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'MonitoredInstances')
BEGIN
    CREATE TABLE dbo.MonitoredInstances (
        InstanceId          INT IDENTITY(1,1) PRIMARY KEY,
        InstanceName        NVARCHAR(256) NOT NULL,
        Tags                NVARCHAR(256) NULL,
        FirstSeenAt         DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        LastSeenAt          DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT UQ_InstanceName UNIQUE (InstanceName)
    );
END
GO

-- ----------------------------------------------------------
-- System Metrics (CPU + Memory per host + SQL process)
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'SystemMetrics')
BEGIN
    CREATE TABLE dbo.SystemMetrics (
        Id                  BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId          INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt         DATETIME2 NOT NULL,
        SystemCpuPercent    INT NULL,
        SqlCpuPercent       INT NULL,
        TotalMemoryMB       BIGINT NULL,
        AvailableMemoryMB   BIGINT NULL,
        SqlMemoryUsedMB     BIGINT NULL,
        SqlMemoryTargetMB   BIGINT NULL,
        MemoryState         NVARCHAR(64) NULL,
        PageFaults          BIGINT NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SystemMetrics_Instance_Time' AND object_id = OBJECT_ID('dbo.SystemMetrics'))
BEGIN
    CREATE INDEX IX_SystemMetrics_Instance_Time ON dbo.SystemMetrics(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Wait Statistics
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'WaitStats')
BEGIN
    CREATE TABLE dbo.WaitStats (
        Id                  BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId          INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt         DATETIME2 NOT NULL,
        WaitType            NVARCHAR(256) NOT NULL,
        WaitingTasksCount   BIGINT NULL,
        WaitTimeMs          BIGINT NULL,
        MaxWaitTimeMs       BIGINT NULL,
        SignalWaitTimeMs    BIGINT NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_WaitStats_Instance_Time' AND object_id = OBJECT_ID('dbo.WaitStats'))
BEGIN
    CREATE INDEX IX_WaitStats_Instance_Time ON dbo.WaitStats(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Top Queries
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'TopQueries')
BEGIN
    CREATE TABLE dbo.TopQueries (
        Id                  BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId          INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt         DATETIME2 NOT NULL,
        DatabaseName        NVARCHAR(256) NULL,
        ProcedureSchema     NVARCHAR(256) NULL,
        ProcedureName       NVARCHAR(512) NULL,
        QueryText           NVARCHAR(MAX) NULL,
        AvgCpuUs            BIGINT NULL,
        TotalCpuUs          BIGINT NULL,
        ExecutionCount      BIGINT NULL,
        AvgDurationUs       BIGINT NULL,
        AvgLogicalReads     BIGINT NULL,
        AvgPhysicalReads    BIGINT NULL,
        AvgLogicalWrites    BIGINT NULL,
        LastExecutedAt      DATETIME2 NULL,
        PlanCreatedAt       DATETIME2 NULL
    );
END
IF COL_LENGTH('dbo.TopQueries', 'ProcedureSchema') IS NULL ALTER TABLE dbo.TopQueries ADD ProcedureSchema NVARCHAR(256) NULL;
IF COL_LENGTH('dbo.TopQueries', 'ProcedureName') IS NULL ALTER TABLE dbo.TopQueries ADD ProcedureName NVARCHAR(512) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_TopQueries_Instance_Time' AND object_id = OBJECT_ID('dbo.TopQueries'))
BEGIN
    CREATE INDEX IX_TopQueries_Instance_Time ON dbo.TopQueries(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Database Sizes
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DatabaseSizes')
BEGIN
    CREATE TABLE dbo.DatabaseSizes (
        Id                  BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId          INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt         DATETIME2 NOT NULL,
        DatabaseName        NVARCHAR(256) NOT NULL,
        State               NVARCHAR(64) NULL,
        RecoveryModel       NVARCHAR(64) NULL,
        DataSizeMB          BIGINT NULL,
        LogSizeMB           BIGINT NULL,
        FileCount           INT NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DatabaseSizes_Instance_Time' AND object_id = OBJECT_ID('dbo.DatabaseSizes'))
BEGIN
    CREATE INDEX IX_DatabaseSizes_Instance_Time ON dbo.DatabaseSizes(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Connection Snapshots
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ConnectionSnapshots')
BEGIN
    CREATE TABLE dbo.ConnectionSnapshots (
        Id                  BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId          INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt         DATETIME2 NOT NULL,
        TotalSessions       INT NULL,
        ActiveRequests      INT NULL,
        BlockedSessions     INT NULL,
        SessionDetailsJson  NVARCHAR(MAX) NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ConnectionSnapshots_Instance_Time' AND object_id = OBJECT_ID('dbo.ConnectionSnapshots'))
BEGIN
    CREATE INDEX IX_ConnectionSnapshots_Instance_Time ON dbo.ConnectionSnapshots(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Blocking Chains
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'BlockingChains')
BEGIN
    CREATE TABLE dbo.BlockingChains (
        Id                  BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId          INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt         DATETIME2 NOT NULL,
        BlockingSessionId   INT NULL,
        BlockedSessionId    INT NULL,
        WaitType            NVARCHAR(256) NULL,
        WaitTimeMs          INT NULL,
        BlockingStatement   NVARCHAR(MAX) NULL,
        BlockedStatement    NVARCHAR(MAX) NULL
    );
END
IF COL_LENGTH('dbo.BlockingChains', 'BlockingLevel') IS NULL ALTER TABLE dbo.BlockingChains ADD BlockingLevel NVARCHAR(32) NULL;
IF COL_LENGTH('dbo.BlockingChains', 'BlockingChain') IS NULL ALTER TABLE dbo.BlockingChains ADD BlockingChain NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.BlockingChains', 'LoginName') IS NULL ALTER TABLE dbo.BlockingChains ADD LoginName NVARCHAR(256) NULL;
IF COL_LENGTH('dbo.BlockingChains', 'HostName') IS NULL ALTER TABLE dbo.BlockingChains ADD HostName NVARCHAR(256) NULL;
IF COL_LENGTH('dbo.BlockingChains', 'ProgramName') IS NULL ALTER TABLE dbo.BlockingChains ADD ProgramName NVARCHAR(256) NULL;
IF COL_LENGTH('dbo.BlockingChains', 'DatabaseName') IS NULL ALTER TABLE dbo.BlockingChains ADD DatabaseName NVARCHAR(128) NULL;
IF COL_LENGTH('dbo.BlockingChains', 'RequestStatus') IS NULL ALTER TABLE dbo.BlockingChains ADD RequestStatus NVARCHAR(60) NULL;
IF COL_LENGTH('dbo.BlockingChains', 'Command') IS NULL ALTER TABLE dbo.BlockingChains ADD Command NVARCHAR(128) NULL;
IF COL_LENGTH('dbo.BlockingChains', 'WaitSeconds') IS NULL ALTER TABLE dbo.BlockingChains ADD WaitSeconds FLOAT NULL;
IF COL_LENGTH('dbo.BlockingChains', 'CpuTimeMs') IS NULL ALTER TABLE dbo.BlockingChains ADD CpuTimeMs INT NULL;
IF COL_LENGTH('dbo.BlockingChains', 'ElapsedSeconds') IS NULL ALTER TABLE dbo.BlockingChains ADD ElapsedSeconds FLOAT NULL;
IF COL_LENGTH('dbo.BlockingChains', 'RunningStatement') IS NULL ALTER TABLE dbo.BlockingChains ADD RunningStatement NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.BlockingChains', 'BatchText') IS NULL ALTER TABLE dbo.BlockingChains ADD BatchText NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BlockingChains_Instance_Time' AND object_id = OBJECT_ID('dbo.BlockingChains'))
BEGIN
    CREATE INDEX IX_BlockingChains_Instance_Time ON dbo.BlockingChains(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Disk I/O Stats
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DiskIOStats')
BEGIN
    CREATE TABLE dbo.DiskIOStats (
        Id                  BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId          INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt         DATETIME2 NOT NULL,
        DatabaseName        NVARCHAR(256) NULL,
        PhysicalName        NVARCHAR(512) NULL,
        FileType            NVARCHAR(64) NULL,
        ReadStallMs         BIGINT NULL,
        WriteStallMs        BIGINT NULL,
        TotalStallMs        BIGINT NULL,
        NumReads            BIGINT NULL,
        NumWrites           BIGINT NULL,
        BytesRead           BIGINT NULL,
        BytesWritten        BIGINT NULL,
        AvgReadLatencyMs    BIGINT NULL,
        AvgWriteLatencyMs   BIGINT NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DiskIOStats_Instance_Time' AND object_id = OBJECT_ID('dbo.DiskIOStats'))
BEGIN
    CREATE INDEX IX_DiskIOStats_Instance_Time ON dbo.DiskIOStats(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Index Fragmentation
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'IndexFragStats')
BEGIN
    CREATE TABLE dbo.IndexFragStats (
        Id                      BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId              INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt             DATETIME2 NOT NULL,
        DatabaseName            NVARCHAR(256) NOT NULL,
        TableName               NVARCHAR(512) NULL,
        IndexName               NVARCHAR(512) NULL,
        IndexType               NVARCHAR(64) NULL,
        FragmentationPercent    FLOAT NULL,
        PageCount               BIGINT NULL,
        RecordCount             BIGINT NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IndexFragStats_Instance_Time' AND object_id = OBJECT_ID('dbo.IndexFragStats'))
BEGIN
    CREATE INDEX IX_IndexFragStats_Instance_Time ON dbo.IndexFragStats(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- TempDB Health
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'TempDbStats')
BEGIN
    CREATE TABLE dbo.TempDbStats (
        Id                      BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId              INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt             DATETIME2 NOT NULL,
        DatabaseName            NVARCHAR(256) NULL,
        FileId                  INT NULL,
        FileType                NVARCHAR(64) NULL,
        FileName                NVARCHAR(256) NULL,
        PhysicalName            NVARCHAR(512) NULL,
        FileSizeMB              BIGINT NULL,
        UnallocatedSpaceMB      BIGINT NULL,
        UserObjectMB            BIGINT NULL,
        InternalObjectMB        BIGINT NULL,
        VersionStoreMB          BIGINT NULL,
        MixedExtentMB           BIGINT NULL,
        GrowthMB                BIGINT NULL,
        MaxSizeMB               BIGINT NULL,
        IsPercentGrowth         INT NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_TempDbStats_Instance_Time' AND object_id = OBJECT_ID('dbo.TempDbStats'))
BEGIN
    CREATE INDEX IX_TempDbStats_Instance_Time ON dbo.TempDbStats(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Deadlock History
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DeadlockHistory')
BEGIN
    CREATE TABLE dbo.DeadlockHistory (
        Id                      BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId              INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt             DATETIME2 NOT NULL,
        EventTime               DATETIME2 NULL,
        VictimSessionId         NVARCHAR(64) NULL,
        DeadlockGraphXml        NVARCHAR(MAX) NULL,
        ObjectName              NVARCHAR(256) NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DeadlockHistory_Instance_Time' AND object_id = OBJECT_ID('dbo.DeadlockHistory'))
BEGIN
    CREATE INDEX IX_DeadlockHistory_Instance_Time ON dbo.DeadlockHistory(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Log File / VLF Health
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LogFileStats')
BEGIN
    CREATE TABLE dbo.LogFileStats (
        Id                      BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId              INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt             DATETIME2 NOT NULL,
        DatabaseName            NVARCHAR(256) NOT NULL,
        FileName                NVARCHAR(256) NULL,
        PhysicalName            NVARCHAR(512) NULL,
        FileType                NVARCHAR(64) NULL,
        FileSizeMB              BIGINT NULL,
        MaxSizeMB               BIGINT NULL,
        GrowthMB                BIGINT NULL,
        IsPercentGrowth         INT NULL,
        RecoveryModel           NVARCHAR(64) NULL,
        LogSizeMB               BIGINT NULL,
        LogUsedMB               BIGINT NULL,
        VlfCount                INT NULL,
        FileId                  INT NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LogFileStats_Instance_Time' AND object_id = OBJECT_ID('dbo.LogFileStats'))
BEGIN
    CREATE INDEX IX_LogFileStats_Instance_Time ON dbo.LogFileStats(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Missing Index Recommendations
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'MissingIndexStats')
BEGIN
    CREATE TABLE dbo.MissingIndexStats (
        Id                      BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId              INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt             DATETIME2 NOT NULL,
        DatabaseName            NVARCHAR(256) NULL,
        StatementText           NVARCHAR(MAX) NULL,
        EqualityColumns         NVARCHAR(4000) NULL,
        InequalityColumns       NVARCHAR(4000) NULL,
        IncludedColumns         NVARCHAR(4000) NULL,
        UserSeeks               BIGINT NULL,
        UniqueCompiles          BIGINT NULL,
        AvgTotalUserCost        FLOAT NULL,
        AvgUserImpact           FLOAT NULL,
        LastUserSeek            DATETIME2 NULL,
        LastUserScan            DATETIME2 NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MissingIndexStats_Instance_Time' AND object_id = OBJECT_ID('dbo.MissingIndexStats'))
BEGIN
    CREATE INDEX IX_MissingIndexStats_Instance_Time ON dbo.MissingIndexStats(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Unused Indexes
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'UnusedIndexStats')
BEGIN
    CREATE TABLE dbo.UnusedIndexStats (
        Id                      BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId              INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt             DATETIME2 NOT NULL,
        DatabaseName            NVARCHAR(256) NULL,
        SchemaName              NVARCHAR(256) NULL,
        TableName               NVARCHAR(256) NULL,
        IndexName               NVARCHAR(256) NULL,
        IndexType               NVARCHAR(64) NULL,
        UserSeeks               BIGINT NULL,
        UserScans               BIGINT NULL,
        UserLookups             BIGINT NULL,
        UserUpdates             BIGINT NULL,
        LastUserSeek            DATETIME2 NULL,
        LastUserScan            DATETIME2 NULL,
        LastUserLookup          DATETIME2 NULL,
        LastUserUpdate          DATETIME2 NULL,
        [RowCount]              BIGINT NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_UnusedIndexStats_Instance_Time' AND object_id = OBJECT_ID('dbo.UnusedIndexStats'))
BEGIN
    CREATE INDEX IX_UnusedIndexStats_Instance_Time ON dbo.UnusedIndexStats(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Backup Status
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'BackupStatus')
BEGIN
    CREATE TABLE dbo.BackupStatus (
        Id                      BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId              INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt             DATETIME2 NOT NULL,
        DatabaseName            NVARCHAR(256) NOT NULL,
        RecoveryModel           NVARCHAR(64) NULL,
        LastFullBackupAt        DATETIME2 NULL,
        LastDiffBackupAt        DATETIME2 NULL,
        LastLogBackupAt         DATETIME2 NULL,
        FullBackupAgeHours      FLOAT NULL,
        DiffBackupAgeHours      FLOAT NULL,
        LogBackupAgeHours       FLOAT NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BackupStatus_Instance_Time' AND object_id = OBJECT_ID('dbo.BackupStatus'))
BEGIN
    CREATE INDEX IX_BackupStatus_Instance_Time ON dbo.BackupStatus(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- SQL Agent Job Health
-- ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'AgentJobHealth')
BEGIN
    CREATE TABLE dbo.AgentJobHealth (
        Id                      BIGINT IDENTITY(1,1) PRIMARY KEY,
        InstanceId              INT NOT NULL REFERENCES dbo.MonitoredInstances(InstanceId),
        CollectedAt             DATETIME2 NOT NULL,
        JobName                 NVARCHAR(256) NULL,
        JobId                   UNIQUEIDENTIFIER NULL,
        LastRunStatus           INT NULL,
        LastRunAt               DATETIME2 NULL,
        LastRunMessage          NVARCHAR(MAX) NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AgentJobHealth_Instance_Time' AND object_id = OBJECT_ID('dbo.AgentJobHealth'))
BEGIN
    CREATE INDEX IX_AgentJobHealth_Instance_Time ON dbo.AgentJobHealth(InstanceId, CollectedAt DESC);
END
GO

-- ----------------------------------------------------------
-- Retention cleanup stored procedure
-- ----------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_PurgeOldMetrics
    @RetentionDays INT = 30
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CutOff DATETIME2 = DATEADD(DAY, -@RetentionDays, SYSUTCDATETIME());

    DELETE FROM dbo.SystemMetrics       WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.WaitStats           WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.TopQueries          WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.DatabaseSizes       WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.ConnectionSnapshots WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.BlockingChains      WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.DiskIOStats         WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.IndexFragStats      WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.TempDbStats         WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.DeadlockHistory     WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.LogFileStats        WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.MissingIndexStats   WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.UnusedIndexStats    WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.BackupStatus        WHERE CollectedAt < @CutOff;
    DELETE FROM dbo.AgentJobHealth      WHERE CollectedAt < @CutOff;
END
GO
