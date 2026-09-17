using module .\SqlConnector.psm1;
using module .\Logging.psm1;
using module .\AuthManager.psm1;
<# <summary>
        A class which defines database upgrade action.
    </summary>
    <owner alias="aldras"/>
#>
class SHHDatabaseUpgradeAction
{
    [Guid]$ActionID = [Guid]::Empty;
    [string]$SqlAction = [string]::Empty;
    [string]$Notes = [string]::Empty;
    [System.Management.Automation.ScriptBlock]$PostUpgradeAction = $null;

    SHHDatabaseUpgradeAction(
        [Guid]$ActionID,
        [string]$SqlAction,
        [string]$Notes
    )
    {
        $this.ActionID = $ActionID;
        $this.SqlAction = $SqlAction;
        $this.Notes = $Notes;
        $this.PostUpgradeAction = $null
    }

    SHHDatabaseUpgradeAction(
        [Guid]$ActionID,
        [string]$SqlAction,
        [string]$Notes,
        [System.Management.Automation.ScriptBlock]$PostUpgradeAction
    )
    {
        $this.ActionID = $ActionID;
        $this.SqlAction = $SqlAction;
        $this.Notes = $Notes;
        $this.PostUpgradeAction = $PostUpgradeAction
    }

    SHHDatabaseUpgradeAction(
        [Guid]$ActionID,
        [string]$SqlAction
    )
    {
        $this.ActionID = $ActionID;
        $this.SqlAction = $SqlAction;
    }
}

class SHHDatabase
{
    hidden [string] $m_modulePath = "";
    hidden [string] $m_connectionString = "";
    hidden [SqlConnector] $sqlHelper = $null;
    hidden [string] $m_dbSchemaCreationScript = "";
    hidden [bool]$m_skipUpgrade = $false;
    hidden [System.Collections.Generic.Dictionary[Version, SHHDatabaseUpgradeAction]] $m_databaseUpgradeScripts = [System.Collections.Generic.Dictionary[Version, SHHDatabaseUpgradeAction]]::new()
    hidden [AuthManager]$m_authManager = $null;
    hidden [bool]$m_skipPostUpgradeProcedures = $false;

    hidden [void] m_InitializeUpgradeScripts()
    {
        $module = Get-Module SHHDatabase
        $this.m_modulePath = $module.ModuleBase;

        $this.m_databaseUpgradeScripts.Add(
            [Version]::new(1, 0, 2511, 1),
            [SHHDatabaseUpgradeAction]::new(
                [Guid]::new("3350f74f-6fbb-4bca-8bf2-507141198411"),
                @"
CREATE TABLE [dbo].[Locks](
    [Id] [int] IDENTITY(1,1) NOT NULL,
    [Type] [nvarchar](128) NOT NULL,
    [ObjectId] [nvarchar](128),
    [Component] [nvarchar](128),
    [Timestamp] [datetime] NOT NULL DEFAULT GETUTCDATE()
    CONSTRAINT [Locks_PK] PRIMARY KEY CLUSTERED 
(
    [Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = ON, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON)
)
GO

CREATE INDEX idx_Locks ON [dbo].[Locks] ([Id] ASC, [Type] ASC)
GO

-- ====================================================
-- Author: aldras
-- Create date: 05/27/2022
-- Modify date: 05/27/2022
-- Description: Creates an upgrade lock on the database
-- ====================================================
CREATE PROCEDURE [dbo].[proc_ObtainDBUpgradeLock]
    @Component NVARCHAR(128) = ''
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @existingLockTimestamp AS datetime = (SELECT TOP (1) [Timestamp] FROM [dbo].[Locks] WHERE [Type]='DBUpgradeLock' ORDER BY [Timestamp] DESC)
    DECLARE @locksDeleted AS bit = 0

    if (@existingLockTimestamp IS NOT NULL AND DATEADD(minute, -5, GETUTCDATE()) >= @existingLockTimestamp)
    BEGIN
        DELETE FROM [dbo].[Locks] WHERE [Type]='DBUpgradeLock'
        SET @locksDeleted = 1         
    END

    IF (@existingLockTimestamp IS NULL OR @locksDeleted = 1)
    BEGIN
        INSERT INTO
            [dbo].[Locks] ([Type], [Component])
        VALUES
            ('DBUpgradeLock', @Component)
        
        SELECT 1
    END ELSE
    BEGIN
        SELECT 0
    END
END
GO

-- ====================================================
-- Author: aldras
-- Create date: 05/27/2022
-- Modify date: 05/27/2022
-- Description: Releases an upgrade lock on the database
-- ====================================================
CREATE PROCEDURE [dbo].[proc_ReleaseDBUpgradeLock]
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM [dbo].[Locks] WHERE [Type]='DBUpgradeLock'
END
GO
                      
"@,
"Database upgrade lock support."
            )
        );

        $this.m_databaseUpgradeScripts.Add(
            [Version]::new(1, 0, 2511, 0),
            [SHHDatabaseUpgradeAction]::new(
                [Guid]::new("0162530e-91a1-4f96-9735-550250843fe3"),
                @"
IF OBJECT_ID(N'dbo.Version', N'U') IS NOT NULL  
DROP TABLE [dbo].[Version]
GO

CREATE TABLE [dbo].[Versions](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[VersionId] [uniqueidentifier] NOT NULL,
	[Version] [nvarchar](64) NOT NULL,
	[UserName] [nvarchar](255) NULL,
	[TimeStamp] [datetime] NULL,
	[Notes] [nvarchar](1024) NULL,
 CONSTRAINT [Versions_PK] PRIMARY KEY CLUSTERED 
(
	[VersionId] ASC,
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = ON, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON)
)

GO

INSERT INTO [dbo].[Versions]
	([VersionId], [Version], [UserName], [TimeStamp], [Notes])
VALUES
	('00000000-0000-0000-0000-000000000000',
	'1.0.2511.0',
	'dbo',
	getutcdate(),
	'')
GO
"@,
"Initial baseline"
            )
        );
    }

    SHHDatabase(
        [string]$ConnectionString
    )
    {
        $this.m_InitializeUpgradeScripts();
        $this.m_connectionString = $ConnectionString;
        $this.sqlHelper = [SqlConnector]::new($this.m_connectionString);
    }

    SHHDatabase(
        [string]$ConnectionString,
        [AuthManager]$AuthManager
    )
    {
        $this.m_InitializeUpgradeScripts();
        $this.m_connectionString = $ConnectionString;
        $this.sqlHelper = [SqlConnector]::new($this.m_connectionString, $AuthManager);
        $this.m_authManager = $AuthManager;
        Write-Host "AuthManager"
    }

    SHHDatabase(
        [string]$ConnectionString,
        [boolean]$SkipUpgrade
    )
    {
        $this.m_InitializeUpgradeScripts();
        $this.m_connectionString = $ConnectionString;
        $this.sqlHelper = [SqlConnector]::new($this.m_connectionString);
        $this.m_skipUpgrade = $SkipUpgrade;
    }

    [System.Collections.Generic.List[System.Collections.Hashtable]] GetDatabaseRecords(
        [string] $query, 
        [int]$timeout = -1)
    {
        return $this.GetDatabaseRecords($query, $null, $timeout);   
    }

    <# /// <summary>
    /// Gets list of hastable with database records using parametrized query
    /// </summary>
    /// <owner alias="aldras" />
    /// <param name="query"></param>
    /// <param name="parameters"></param>
    /// <returns></returns> #> 
    [System.Collections.Generic.List[System.Collections.Hashtable]] GetDatabaseRecords(
        [string] $query, 
        [System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]]$parameters,
        [int]$timeout = -1)
    {
        [System.Collections.Generic.List[System.Collections.Hashtable]] $lht = [System.Collections.Generic.List[System.Collections.Hashtable]]::new();
        
        if ($null -eq $parameters)
        {
            $parameters = [System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]]::new();
        }

        $sqlData = $this.sqlHelper.GetParametrizedDataSet($query, $parameters, $timeout);

        if ($null -ne $sqlData)
        {
            $dt = $sqlData.Tables[0];
            if ($dt.Rows.Count -gt 0)
            {
                foreach ($dr in $dt.Rows)
                {
                    $ht = [System.Collections.Hashtable]::new();
                    foreach ($dc in $dt.Columns)
                    {
                        $ht.Add($dc.ColumnName, $dr[$dc.ColumnName]);
                    }

                    $lht.Add($ht);
                }
            }
        }

        return $lht;
    }

    [void] ExecuteDatabaseCommand([string] $query)
    {
        $this.sqlHelper.ExecuteQuery($query);
    }

    [int] ExecuteParameterizedDatabaseCommand(
        [string] $query,
        [System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]] $parameters)
    {
        return $this.sqlHelper.ExecuteParameterizedQuery($query, $parameters);
    }

    [int] ExecuteParameterizedDatabaseSP(
        [string] $command,
        [System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]] $parameters)
    {
        return $this.sqlHelper.ExecuteParameterizedSP($command, $parameters);
    }

    [void]EnsureDatabase()
    {
        $this.EnsureDatabase($false);
    }

    [void]EnsureDatabase(
        [Boolean]$SkipSQLDatabaseCreation = $false
        )
    {
        $schemaExists = $false;
        $strBuilder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($this.m_connectionString);
        $dbName = $strBuilder["Initial Catalog"];
        $dbServer = $strBuilder["Data Source"];
            
        [TraceLogging]::LogEvent(
            [LoggingLevel]::Information,
            "Database",
            "Core", "dbc264",
            [string]::Format("SHHDatabase.EnsureDatabase(): Database {0} exists on server {1}. Checking database schema.", $dbName, $dbServer));
        
        if ($null -ne $this.m_authManager)
        { 
            $this.sqlHelper = [SqlConnector]::new($this.m_connectionString, $this.m_authManager);
        } else 
        {
            $this.sqlHelper = [SqlConnector]::new($this.m_connectionString);
        }

        try
        {
            $dbObjects = $this.sqlHelper.GetTSQLDataTableCollection("SELECT [name] FROM [sys].[objects] WHERE [is_ms_shipped]=0");
            if ($dbObjects.Rows.Count -gt 0)
            {
                # database exists and is not empty. log and return.
                $schemaExists = $true;
                [TraceLogging]::LogEvent(
                    [LoggingLevel]::Information,
                    "Database",
                    "Core", "dbc269",
                    [string]::Format("SHHDatabase.EnsureDatabase(): Database {0} on server {1} contains custom schema. Schema creation will be skipped.", $dbName, $dbServer));
            }
        }
        catch
        {
            # cannot access the database, log and re-throw.# ZTTraceLogging.LogEvent(ZTLoggingLevel.Error, "Zero Touch Core", "Provisioning", "ZTDB0086", string.Format("ZTDatabase.EnsureDatabase(): Cannot obtain schema information for database {0} on server {1}. Exception: {2}", _name, _dbServer, ex), "");
            [TraceLogging]::LogEvent(
                [LoggingLevel]::Error,
                "Database",
                "Core", "dbc273",
                [string]::Format("SHHDatabase.EnsureDatabase(): Cannot obtain schema information for database {0} on server {1}. Exception: {2}", $dbName, $dbServer, $_));
            
            throw;
        }

        if ($schemaExists -ne $true)
        {
            # at this point, the database exists and is empty. create the db schema. each inheriting object should present it's own schema creation script.
            [TraceLogging]::LogEvent(
                [LoggingLevel]::Information,
                "Database",
                "Core", "dbc277",
                [string]::Format("SHHDatabase.EnsureDatabase(): Creating database schema in database {0}, server {1}.", $dbName, $dbServer));
            
            try
            {
                # create database schema. log the action
                if ($null -ne $this.m_authManager)
                { 
                    $this.sqlHelper = [SqlConnector]::new($this.m_connectionString, $this.m_authManager);
                } else 
                {
                    $this.sqlHelper = [SqlConnector]::new($this.m_connectionString);
                }
                $this.sqlHelper.ExecuteQuery($this.m_dbSchemaCreationScript);
            }
            catch
            {
                # cannot create database. log and re-throw.
                [TraceLogging]::LogEvent(
                    [LoggingLevel]::Error,
                    "Database",
                    "Core", "dbc281",
                    [string]::Format("SHHDatabase.EnsureDatabase(): Cannot create database schema in database {0} on server {1}. Exception: {2}", $dbName, $dbServer, $_));
                
                throw;
            }
            [TraceLogging]::LogEvent(
                [LoggingLevel]::Information,
                "Database",
                "Core", "dbc286",
                [string]::Format("SHHDatabase.EnsureDatabase(): Database schema created successfully. Database {0} is successfully created on server {1}.", $dbName, $dbServer));
        }

        # perform database upgrade operations
        $this.Upgrade();
    }

    [System.Object]ObtainDBUpgradeLock()
    {
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("Component", "MicrosoftServiceHealthHubSync"))) | Out-Null
        return $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_ObtainDBUpgradeLock]", $parameters)
    }

    [void]ReleaseDBUpgradeLock()
    {
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_ReleaseDBUpgradeLock]", $parameters) | Out-Null
    }

    [void]Upgrade()
    {
        $strBuilder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($this.m_connectionString);
        $dbName = $strBuilder["Initial Catalog"];
        $dbServer = $strBuilder["Data Source"];

        [TraceLogging]::LogEvent(
            [LoggingLevel]::Information,
            "Database",
            "Upgrade", "dbu071a",
            [string]::Format(
                "SHHDatabase.Upgrade(): Validating database version for the database {0}, server {1}.",
                $dbName,
                $dbServer));

        [Version]$dbVersion = [Version]::new(1, 0, 0, 0);

        [string]$query = "SELECT COUNT(1) as TableExists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_CATALOG='$dbName' AND TABLE_NAME = 'Versions'";
        $res = $this.sqlHelper.GetTSQLDataTableCollection($query);

        if ($null -ne $res -and $res.Rows.Count -gt 0 -and ($res.Rows | Select-Object -First 1)["TableExists"] -eq 1)
        {
            $dbVersion = [Version]::new(1, 0, 0, 0);
            $query = "SELECT Version FROM [dbo].[Versions]";
            $versions = $this.GetDatabaseRecords($query, $null, -1);

            if ($null -ne $versions)
            {
                foreach ($ht in $versions)
                {
                    if ($ht.ContainsKey("Version"))
                    {
                        try
                        {
                            $ver = [Version]::new($ht["Version"]);
                            if ($ver -gt $dbVersion)
                            {
                                $dbVersion = $ver;
                            }
                        }
                        catch
                        {
                            # version info corrupted.
                        }
                    }
                }
            }
        }

        [TraceLogging]::LogEvent(
            [LoggingLevel]::Information,
            "Database",
            "Upgrade", "dbu071f",
            [string]::Format(
                "SHHDatabase.Upgrade(): Database {0} on server {1} contains schema verision {2}.",
                $dbName,
                $dbServer,
                $dbVersion));

        $sortedVersions = [System.Collections.Generic.List[Version]]$this.m_databaseUpgradeScripts.Keys;
        $sortedVersions.Sort(); # ensure we are executing upgrade operations in sequence

        $lockAcquired = -1;

        if ($dbVersion -lt [Version]::new(1, 0, 2511, 1))
        {
            $lockAcquired = -1; # DB Lock is supported starting with v1.0.2511.1, setting to unsupported
        } else {
            $lockAcquired = $this.ObtainDBUpgradeLock()
        }

        if ($lockAcquired -ne 0)
        {
            try
            {
                foreach ($version in $sortedVersions)
                {
                    [TraceLogging]::LogEvent(
                        [LoggingLevel]::Information,
                        "Database",
                        "Upgrade", "dbu0721",
                        [string]::Format(
                            "SHHDatabase.Upgrade(): Database {0}, server {1}: Checking schema version {2}.",
                            $dbName,
                            $dbServer,
                            $version));

                    if ($version -gt $dbVersion)
                    {
                        $action = $this.m_databaseUpgradeScripts[$version];

                        try
                        {
                            [TraceLogging]::LogEvent(
                                [LoggingLevel]::Information,
                                "Database",
                                "Upgrade", "dbu0723",
                                [string]::Format(
                                    "SHHDatabase.Upgrade(): Database {0}, server {1}: Upgrading to schema version {2}.",
                                    $dbName,
                                    $dbServer,
                                    $version));

                            # execute sql action
                            $this.ExecuteDatabaseCommand($action.SqlAction);
                        }
                        catch
                        {
                            [TraceLogging]::LogEvent(
                                [LoggingLevel]::Error,
                                "Database",
                                "Upgrade", "dbu0727",
                                [string]::Format(
                                    "SHHDatabase.Upgrade(): Failed to upgrade database {0} on server {1} to the schema version {2}. Exception: {3}",
                                    $dbName,
                                    $dbServer,
                                    $version,
                                    $_));

                            throw;
                        }

                        try
                        {
                            [TraceLogging]::LogEvent(
                                [LoggingLevel]::Information,
                                "Database",
                                "Upgrade", "dbu072a",
                                [string]::Format(
                                    "SHHDatabase.Upgrade(): Database {0}, server {1}: Adding version information for the schema version {2}.",
                                    $dbName,
                                    $dbServer,
                                    $version));

                            # add version information
                            $query = "INSERT INTO [dbo].[Versions] ([VersionId], [Version], [UserName], [TimeStamp], [Notes]) VALUES (@VersionId, @Version, @UserName, getutcdate(), @Notes)";

                            $sqlParams = [System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]]::new();

                            $sqlParams.Add($(New-Object System.Data.SqlClient.SqlParameter("VersionId", $action.ActionID))) | Out-Null
                            $sqlParams.Add($(New-Object System.Data.SqlClient.SqlParameter("Version", $version.ToString()))) | Out-Null
                            $sqlParams.Add($(New-Object System.Data.SqlClient.SqlParameter("UserName", "dbo"))) | Out-Null
                            $sqlParams.Add($(New-Object System.Data.SqlClient.SqlParameter("Notes", $action.Notes))) | Out-Null   

                            $this.ExecuteParameterizedDatabaseCommand($query, $sqlParams);
                        }
                        catch
                        {
                            [TraceLogging]::LogEvent(
                                [LoggingLevel]::Error,
                                "Database",
                                "Upgrade", "dbu072f",
                                [string]::Format(
                                    "SHHDatabase.Upgrade(): Failed to upgrade database {0} on server {1} to the schema version {2}. Exception: {3}",
                                    $dbName,
                                    $dbServer,
                                    $version,
                                    $_));

                            throw;
                        }

                        if ($null -ne $action.PostUpgradeAction -and !$this.m_skipPostUpgradeProcedures)
                        {
                            [TraceLogging]::LogEvent(
                                [LoggingLevel]::Information,
                                "Database",
                                "Upgrade", "dbu0731",
                                [string]::Format(
                                    "SHHDatabase.Upgrade(): Running post-upgrade actions for version {0}.",
                                    $version));
                            try {
                                # Invoke-Command -ScriptBlock $action.PostUpgradeAction;
                            }
                            catch {
                                [TraceLogging]::LogEvent(
                                [LoggingLevel]::Error,
                                "Database",
                                "Upgrade", "dbu0735",
                                [string]::Format(
                                    "SHHDatabase.Upgrade(): Post-upgrade actions for version {0} failed. Error: {1}",
                                    $version,
                                    $_));
                            }
                        }

                        $dbVersion = $version;
                    }
                }
            }
            catch {
                throw;
            }
            finally {
                if ($lockAcquired -ne -1)
                {
                    $this.ReleaseDBUpgradeLock();
                }
            }
        }
        else {
            throw "Database upgrade lock is in place. Skipping.";
        }
    }
}