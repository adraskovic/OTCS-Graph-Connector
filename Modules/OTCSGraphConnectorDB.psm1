using module .\BaseConfiguration.psm1
using module .\Logging.psm1
using module .\SHHDatabase.psm1
using module .\AuthManager.psm1

class OTCSGraphConnectorDB: SHHDatabase
{
    #region Schema Creation Script
    hidden [string] $m_dbSchemaCreationScript = @"

CREATE TABLE [dbo].[Config](
    [Key] [nvarchar](256) NOT NULL,
    [SerializedValue] [nvarchar](max) NULL,
    [DataType] [nchar](64) NOT NULL,
    CONSTRAINT [PK_Config] PRIMARY KEY CLUSTERED 
(
    [Key] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

-- Table to queue items for processing
CREATE TABLE Queue (
    QueueID        BIGINT IDENTITY PRIMARY KEY,
    NodeId         NVARCHAR(128) NOT NULL,
    URL            NVARCHAR(2048) NOT NULL,
    LastModified   DATETIME2,
    Properties     NVARCHAR(MAX),   -- JSON or XML of serialized node properties
    Permissions    NVARCHAR(MAX),   -- JSON or XML of permissions snapshot at enqueue time
    SecurityClass  NVARCHAR(100),
    Type           INT,              -- Type of item (e.g., 1 = Document, 0 = Folder)
    EnqueuedAt     DATETIME2 DEFAULT GETUTCDATE(),
    Status         NVARCHAR(20) DEFAULT 'Pending'  -- 'Pending', 'Processing', 'Error' etc.
);

-- Table to track successfully processed (indexed) items
CREATE TABLE Items (
    ID                 BIGINT IDENTITY PRIMARY KEY,
    NodeId             NVARCHAR(128) NOT NULL,
    LastModified       DATETIME2,
    Permissions        NVARCHAR(MAX),
    SecurityClass      NVARCHAR(100),
    IndexedAt          DATETIME2 DEFAULT GETUTCDATE(),
    ContentSourceUrl   NVARCHAR(2048),  -- Original URL or metadata for reference
    Properties         NVARCHAR(MAX)
);

-- Table for external groups (permissions groups from OTCS mirrored in Graph)
CREATE TABLE Groups (
    GroupID       NVARCHAR(128) PRIMARY KEY,  -- External Group ID used in Graph (could use OTCS group ID or name)
    DisplayName   NVARCHAR(255),
    LastModified  DATETIME2                   -- Last time group membership changed in OTCS
);

-- Table mapping group members (users or nested groups) for each external group
CREATE TABLE GroupMembers (
    GroupID    NVARCHAR(128) NOT NULL,
    MemberID   NVARCHAR(256) NOT NULL,
    MemberType NVARCHAR(20)  NOT NULL,  -- e.g. 'User' or 'Group'
    PRIMARY KEY (GroupID, MemberID),
    FOREIGN KEY (GroupID) REFERENCES Groups(GroupID) ON DELETE CASCADE
);


CREATE NONCLUSTERED INDEX IX_Queue_Pending_EnqueuedAt
ON dbo.Queue (EnqueuedAt, QueueID)
INCLUDE (NodeId, URL, LastModified, SecurityClass)
WHERE Status = N'Pending';
GO


CREATE NONCLUSTERED INDEX IX_Queue_Status_EnqueuedAt
ON dbo.Queue (Status, EnqueuedAt)
INCLUDE (NodeId, URL, LastModified, SecurityClass);
GO


CREATE NONCLUSTERED INDEX IX_Queue_NodeId_EnqueuedAt
ON dbo.Queue (NodeId, EnqueuedAt DESC)
INCLUDE (Status, URL, LastModified, SecurityClass);
GO

CREATE NONCLUSTERED INDEX IX_Queue_NodeId_Type
ON dbo.Queue (NodeId, [Type] DESC)
INCLUDE ([Status], [URL], LastModified, SecurityClass);
GO

CREATE UNIQUE NONCLUSTERED INDEX UX_Items_NodeId
ON dbo.Items (NodeId);
GO


CREATE NONCLUSTERED INDEX IX_Items_IndexedAt
ON dbo.Items (IndexedAt DESC, ID)
INCLUDE (NodeId, LastModified, SecurityClass, ContentSourceUrl);
GO


CREATE NONCLUSTERED INDEX IX_Items_NodeId_LastModified
ON dbo.Items (NodeId, LastModified)
INCLUDE (IndexedAt, SecurityClass);
GO


CREATE NONCLUSTERED INDEX IX_Items_SecurityClass
ON dbo.Items (SecurityClass)
INCLUDE (NodeId, IndexedAt, LastModified);
GO


CREATE NONCLUSTERED INDEX IX_Groups_LastModified
ON dbo.Groups (LastModified DESC)
INCLUDE (GroupID, DisplayName);
GO


CREATE NONCLUSTERED INDEX IX_Groups_DisplayName
ON dbo.Groups (DisplayName)
INCLUDE (GroupID, LastModified);
GO

CREATE NONCLUSTERED INDEX IX_GroupMembers_MemberID_MemberType_GroupID
ON dbo.GroupMembers (MemberID, MemberType, GroupID);
GO


CREATE NONCLUSTERED INDEX IX_GroupMembers_GroupID_MemberType
ON dbo.GroupMembers (GroupID, MemberType)
INCLUDE (MemberID);
GO

-- ====================================================
-- Author:		aldras
-- Create date: 12/22/2025
-- Modify date: 01/05/2026
-- Description:	Adds item to a queue for processing
-- ====================================================
CREATE PROCEDURE [dbo].[proc_AddQueueItem]
    @NodeId NVARCHAR(128),
    @URL NVARCHAR(2048),
    @LastModified DATETIME2,
    @Properties NVARCHAR(MAX),
    @Permissions NVARCHAR(MAX),
    @SecurityClass NVARCHAR(100),
    @Type INT
AS
    BEGIN
        SET NOCOUNT ON;

        declare @existingQueueId as BIGINT = (select [QueueId] from [dbo].[Queue] where [NodeId]=@NodeId)

        if (@existingQueueId IS NULL)
        begin
            insert into [dbo].[Queue] ([NodeId], [URL], [LastModified], [Properties], [Permissions], [SecurityClass], [Type])
            values (@NodeId, @URL, @LastModified, @Properties, @Permissions, @SecurityClass, @Type)
        end
        else
        begin
            update [dbo].[Queue]
            set 
                [NodeId] = @NodeId,
                [URL] = @URL,
                [LastModified] = @LastModified,
                [Properties] = @Properties,
                [Permissions] = @Permissions,
                [SecurityClass] = @SecurityClass,
                [Type] = @Type
            where [QueueId] = @existingQueueId
        end
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 12/22/2025
-- Modify date: 01/05/2026
-- Description:	Moves item to Items table
-- ====================================================
CREATE PROCEDURE [dbo].[proc_MarkQueueItemProcessed]
    @NodeId NVARCHAR(128)
AS
    BEGIN
        SET NOCOUNT ON;

        declare @existingQueueItemType as INT = (select [Type] from [dbo].[Queue] where [NodeId]=@NodeId)

        if (@existingQueueItemType IS NOT NULL)
        begin
            if (@existingQueueItemType > 0)
            BEGIN
                -- Document type item processing, folder type will be just removed from queue when processed
                declare @indexedItemId AS BIGINT = (select [ID] from [dbo].[Items] where [NodeId]=@NodeId)
                if (@indexedItemId IS NULL)
                begin
                    insert into [dbo].[Items] ([NodeId], [LastModified], [Permissions], [SecurityClass], [Properties])
                    select 
                        [NodeId],
                        [LastModified],
                        [Permissions],
                        [SecurityClass],
                        [Properties]
                    from [dbo].[Queue]
                    where [NodeId]=@NodeId
                end
                else
                begin
                    update [dbo].[Items]
                    set 
                        [LastModified] = q.[LastModified],
                        [Permissions] = q.[Permissions],
                        [SecurityClass] = q.[SecurityClass],
                        [Properties] = q.[Properties],
                        [IndexedAt] = GETUTCDATE()
                    from [dbo].[Items]
                    join [dbo].[Queue] q on q.[NodeId] = [dbo].[Items].[NodeId]
                    where [ID] = @indexedItemId
                end
            END

            DELETE FROM [dbo].[Queue] WHERE [NodeId]=@NodeId
        end
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 12/22/2025
-- Modify date: 12/22/2025
-- Description:	Sets a status on a queue item
-- ====================================================
CREATE PROCEDURE [dbo].[proc_SetQueueItemStatus]
    @NodeId NVARCHAR(128),
    @Status NVARCHAR(20)
AS
    BEGIN
        SET NOCOUNT ON;

        update [dbo].[Queue]
        set 
            [Status] = @Status
        where [NodeId] = @NodeId
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 01/05/2026
-- Modify date: 01/05/2026
-- Description:	Sets a status on a queue item
-- ====================================================
CREATE PROCEDURE [dbo].[proc_SetQueueItemSecurityClass]
    @NodeId NVARCHAR(128),
    @SecurityClass NVARCHAR(100)
AS
    BEGIN
        SET NOCOUNT ON;

        update [dbo].[Queue]
        set 
            [SecurityClass] = @SecurityClass
        where [NodeId] = @NodeId
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 12/30/2025
-- Modify date: 12/30/2025
-- Description:	Removes an item from the items table
-- ====================================================
CREATE PROCEDURE [dbo].[proc_RemoveIndexedItem]
    @NodeId NVARCHAR(128)
AS
    BEGIN
        SET NOCOUNT ON;

        DELETE FROM [dbo].[Items]
        WHERE [NodeId] = @NodeId
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 12/24/2025
-- Modify date: 12/24/2025
-- Description:	Adds a group to the Groups table
-- ====================================================
CREATE PROCEDURE [dbo].[proc_AddGroup]
    @GroupId NVARCHAR(128),
    @DisplayName NVARCHAR(255),
    @LastModified DATETIME2
AS
    BEGIN
        SET NOCOUNT ON;

        declare @existingGroupId as NVARCHAR(128) = (select [GroupId] from [dbo].[Groups] where [GroupId]=@GroupId)

        if (@existingGroupId IS NULL)
        begin
            insert into [dbo].[Groups] ([GroupId], [DisplayName], [LastModified])
            values (@GroupId, @DisplayName, @LastModified)
        end
        else
        begin
            update [dbo].[Groups]
            set 
                [GroupId] = @GroupId,
                [DisplayName] = @DisplayName,
                [LastModified] = @LastModified
            where [GroupId] = @existingGroupId
        end
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 12/30/2025
-- Modify date: 12/30/2025
-- Description:	Removes a group from the Groups table
-- ====================================================
CREATE PROCEDURE [dbo].[proc_RemoveGroup]
    @GroupId NVARCHAR(128)
AS
    BEGIN
        SET NOCOUNT ON;

        DELETE FROM
            [dbo].[Groups]
        WHERE 
            [GroupId] = @GroupId 
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 12/24/2025
-- Modify date: 12/24/2025
-- Description:	Adds a group member to the GroupMembers table
-- ====================================================
CREATE PROCEDURE [dbo].[proc_AddGroupMember]
    @GroupId NVARCHAR(128),
    @MemberId NVARCHAR(256),
    @MemberType NVARCHAR(20)
AS
    BEGIN
        SET NOCOUNT ON;

        declare @existingMemberId as NVARCHAR(256) = (select [MemberId] from [dbo].[GroupMembers] where [GroupId]=@GroupId AND [MemberId]=@MemberId)

        if (@existingMemberId IS NULL)
        begin
            insert into [dbo].[GroupMembers] ([GroupId], [MemberId], [MemberType])
            values (@GroupId, @MemberId, @MemberType)
        end
        else
        begin
            update [dbo].[GroupMembers]
            set 
                [GroupId] = @GroupId,
                [MemberId] = @MemberId,
                [MemberType] = @MemberType
            where [GroupId] = @GroupId AND [MemberId] = @MemberId
        end
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 12/24/2025
-- Modify date: 12/24/2025
-- Description:	Removes a group member from the GroupMembers table
-- ====================================================
CREATE PROCEDURE [dbo].[proc_RemoveGroupMember]
    @GroupId NVARCHAR(128),
    @MemberId NVARCHAR(256),
    @MemberType NVARCHAR(20)
AS
    BEGIN
        SET NOCOUNT ON;

        DELETE FROM
            [dbo].[GroupMembers]
        WHERE
            [GroupId] = @GroupId 
            AND [MemberId] = @MemberId
            AND [MemberType] = @MemberType
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 10/07/2022
-- Modify date: 12/29/2022
-- Description:	Adds configuration value
-- ====================================================
CREATE OR ALTER PROCEDURE [dbo].[proc_SetConfigValue]
@Key nvarchar(128),
@Value nvarchar(max) NULL = NULL,
@DataType nchar(64)
AS
    BEGIN
        SET NOCOUNT ON;

        declare @existingKey as nvarchar(max) = (select [Key] from [dbo].[Config] where [Key]=@Key)

        if (@existingKey IS NULL)
        begin
            insert into [dbo].[Config] ([Key], [SerializedValue], [DataType])
            values (@Key, @Value, @DataType)
        end
        else
        begin
            UPDATE
                [dbo].[Config]
            SET
                [SerializedValue] = @Value,
                [DataType] = @DataType
            WHERE
                [Key] = @Key
        end
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 12/18/2018
-- Modify date: 11/08/2021
-- Description:	Updates last sync timestamp
-- ====================================================
CREATE PROCEDURE [dbo].[proc_RegisterSyncHeartbeat]
AS
    BEGIN
        SET NOCOUNT ON;

        declare @heartbeatKey as nvarchar(256) = 'LastSyncTimestamp'
        declare @existingHeartbeat as nvarchar(max) = (select [SerializedValue] from [dbo].[Config] where [Key]=@heartbeatKey)
        declare @syncTimestamp as nvarchar(max) = CONVERT(nvarchar(max), GETUTCDATE(), 127)

        if (@existingHeartbeat IS NULL)
        begin
            insert into [dbo].[Config] ([Key], [SerializedValue], [DataType])
            values (@heartbeatKey, @syncTimestamp, 'System.DateTime')
        end
        else
        begin
            UPDATE
                [dbo].[Config]
            SET
                [SerializedValue] = @syncTimestamp,
                [DataType] = 'System.DateTime'
            WHERE
                [Key] = @heartbeatKey
        end
    END
GO
       
"@;
    #endregion

    hidden [void] m_InitializeUpgradeScripts()
    {
        ([SHHDatabase]$this).m_InitializeUpgradeScripts();
        
        $module = Get-Module OTCSGraphConnectorDB
        $this.m_modulePath = $module.ModuleBase;

        $this.m_databaseUpgradeScripts.Add(
            [Version]::new(1, 0, 2604, 0),
            [SHHDatabaseUpgradeAction]::new(
                [Guid]::new("6128d348-845d-4991-be47-b8270f0b0723"),
                @"
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Table to store user information
CREATE TABLE Users (
    id             UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
    email          NVARCHAR(320) NOT NULL
);
GO


CREATE UNIQUE NONCLUSTERED INDEX IX_Users_Email
ON dbo.Users (email);
GO

-- ====================================================
-- Author:		aldras
-- Create date: 04/09/2026
-- Modify date: 04/09/2026
-- Description:	Adds a user to the Users table
-- ====================================================
CREATE PROCEDURE [dbo].[proc_AddUser]
@id UNIQUEIDENTIFIER,
@email NVARCHAR(320)
AS
    BEGIN
        SET NOCOUNT ON;

        declare @existingUserId as UNIQUEIDENTIFIER = (select [id] from [dbo].[Users] where [id]=@id)

        if (@existingUserId IS NULL)
        begin
            insert into [dbo].[Users] ([id], [email])
            values (@id, @email)
        end
        else
        begin
            update [dbo].[Users]
            set 
                [email] = @email
            where [Id] = @existingUserId
        end
    END
GO

"@,
"Added users table and stored procedure."
            )
        );

        $this.m_databaseUpgradeScripts.Add(
            [Version]::new(1, 0, 2604, 1),
            [SHHDatabaseUpgradeAction]::new(
                [Guid]::new("12f201ce-8ee1-4d05-ae79-1e2d0ea65d18"),
                @"
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Table to store object cache information
CREATE TABLE ObjectCache (
    id             UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
    objectId       NVARCHAR(320) NOT NULL,  
    objectType     NVARCHAR(100) NOT NULL,
    serializedData NVARCHAR(MAX) NOT NULL,
    lastModified   DATETIME2 NOT NULL DEFAULT GETUTCDATE()
    expiresOn      DATETIME2 NOT NULL
);
GO


CREATE UNIQUE NONCLUSTERED INDEX IX_ObjectCache_ObjectId_ObjectType
ON ObjectCache (objectId, objectType);
GO

-- ====================================================
-- Author:		aldras
-- Create date: 04/15/2026
-- Modify date: 04/15/2026
-- Description:	Adds an object to the ObjectCache table
-- ====================================================
CREATE PROCEDURE [dbo].[proc_AddObject]
@id UNIQUEIDENTIFIER,
@objectId NVARCHAR(320),
@objectType NVARCHAR(100),
@serializedData NVARCHAR(MAX),
@expiresOn DATETIME2
AS
    BEGIN
        SET NOCOUNT ON;

        declare @existingObjectId as UNIQUEIDENTIFIER = (select [id] from [dbo].[ObjectCache] where [objectId]=@objectId and [objectType]=@objectType)

        if (@existingObjectId IS NULL)
        begin
            insert into [dbo].[ObjectCache] ([id], [objectId], [objectType], [serializedData], [expiresOn])
            values (@id, @objectId, @objectType, @serializedData, @expiresOn)
        end
        else
        begin
            update [dbo].[ObjectCache]
            set 
                [serializedData] = @serializedData,
                [expiresOn] = @expiresOn
            where [Id] = @existingObjectId
        end
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 04/15/2026
-- Modify date: 04/15/2026
-- Description:	Removes an object from the ObjectCache table
-- ====================================================
CREATE PROCEDURE [dbo].[proc_RemoveObject]
@objectId NVARCHAR(320),
@objectType NVARCHAR(100)
AS
    BEGIN
        SET NOCOUNT ON;
        DELETE FROM [dbo].[ObjectCache]
        WHERE [objectId] = @objectId AND [objectType] = @objectType
    END
GO

-- ====================================================
-- Author:		aldras
-- Create date: 12/22/2025
-- Modify date: 04/16/2025
-- Description:	Sets a status on a queue item
-- ====================================================
ALTER PROCEDURE [dbo].[proc_SetQueueItemStatus]
    @NodeId NVARCHAR(MAX),
    @Status NVARCHAR(20)
AS
    BEGIN
        SET NOCOUNT ON;

        update [dbo].[Queue]
        set 
            [Status] = @Status
        where [NodeId] IN (SELECT trim(value) FROM STRING_SPLIT(@NodeId, ','))
    END
GO

"@,
"Added object cache table and stored procedure."
            )
        );

        $this.m_databaseUpgradeScripts.Add(
            [Version]::new(1, 0, 2605, 0),
            [SHHDatabaseUpgradeAction]::new(
                [Guid]::new("37fb1f67-4c7d-4fad-86cd-3fd27bcceddf"),
                @"
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ====================================================
-- Author:		aldras
-- Modify date: 05/27/2026
-- Description:	Adds a unique constraint on NodeId in the Queue table
-- ====================================================
ALTER TABLE dbo.Queue
ADD CONSTRAINT UQ_NodeId UNIQUE (NodeId);
GO

-- ====================================================
-- Author:		aldras
-- Create date: 12/22/2025
-- Modify date: 05/27/2026
-- Description:	Adds item to a queue for processing
-- ====================================================
ALTER PROCEDURE [dbo].[proc_AddQueueItem]
    @NodeId NVARCHAR(128),
    @URL NVARCHAR(2048),
    @LastModified DATETIME2,
    @Properties NVARCHAR(MAX),
    @Permissions NVARCHAR(MAX),
    @SecurityClass NVARCHAR(100),
    @Type INT
AS
    BEGIN
        SET NOCOUNT ON;

        MERGE [dbo].[Queue] WITH (HOLDLOCK) AS target
        USING (SELECT @NodeId AS NodeId) AS source
        ON target.NodeId = source.NodeId
        WHEN MATCHED THEN
            UPDATE SET
                URL = @URL,
                LastModified = @LastModified,
                Properties = @Properties,
                Permissions = @Permissions,
                SecurityClass = @SecurityClass,
                Type = @Type
        WHEN NOT MATCHED THEN
            INSERT (NodeId, URL, LastModified, Properties, Permissions, SecurityClass, Type)
            VALUES (@NodeId, @URL, @LastModified, @Properties, @Permissions, @SecurityClass, @Type);
    END
GO

"@,
"Added unique constraint on NodeId in Queue table and changed proc_AddQueueItem to use MERGE for upsert logic."
            )
        );
    }

    OTCSGraphConnectorDB(): base([BaseConfiguration]::ConnectionString)
    {
        # $this.PerformSchemaCheck();
    }

    OTCSGraphConnectorDB([bool]$SkipUpgrade): base([BaseConfiguration]::ConnectionString, $SkipUpgrade)
    {
        # $this.PerformSchemaCheck();
    }

    OTCSGraphConnectorDB([string]$ConnectionString): base($ConnectionString)
    {
        # $this.PerformSchemaCheck();
    }

    OTCSGraphConnectorDB([string]$ConnectionString, [bool]$SkipUpgrade): base($ConnectionString, $SkipUpgrade)
    {
        # $this.PerformSchemaCheck();
    }

    OTCSGraphConnectorDB([string]$ConnectionString, [AuthManager]$AuthManager): base($ConnectionString, $AuthManager)
    {
        # $this.PerformSchemaCheck();
    }

    [void]PerformSchemaCheck()
    {
        if ($null -eq $global:OTCSGCDBSchemaCheckCompleted -and $this.m_skipUpgrade -ne $true)
        {
            if (![string]::IsNullOrWhiteSpace([BaseConfiguration]::SkipDatabaseCreation)) {
                $this.EnsureDatabase([BaseConfiguration]::SkipDatabaseCreation);
            } else {
                $this.EnsureDatabase();
            }
            
            $global:OTCSGCDBSchemaCheckCompleted = $true;
        }
    }

    [void]PerformSchemaCheck([bool]$SkipPostUpgradeProcedures)
    {
        $this.m_skipPostUpgradeProcedures = $SkipPostUpgradeProcedures;
        $this.EnsureDatabase($true);
        $global:OTCSGCDBSchemaCheckCompleted = $true;
    }

    [System.Object]GetLastSyncTime(
        [string]$CommunicationType
    )
    {
        $tsql = "SELECT [SerializedValue] FROM [dbo].[Config] WHERE [Key] = 'LastSyncTimestamp'" # keep the key in sync with [proc_RegisterSyncHeartbeat] stored procedure.
        $val = $this.sqlHelper.GetTSQLValue($tsql, "SerializedValue")
        return $val
    }

    [void]SetLastSyncTime(
        [string]$CommunicationType
    )
    {
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_RegisterSyncHeartbeat]", $parameters) | Out-Null
    }

    [System.Object]GetConfigValue(
        [string]$Key
    )
    {
        $tsql = "SELECT [SerializedValue] FROM [dbo].[Config] WHERE [Key] = '$Key'"
        $val = $this.sqlHelper.GetTSQLValue($tsql, "SerializedValue")
        # add deserialzation

        if ($null -eq $val)
        {
            return $null
        }

        try {
            return $($val | ConvertFrom-Json)
        } catch {
            return $val
        }
    }

    [void]SetConfigValue(
        [string]$Key,
        [object]$Value
    )
    {
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("Key", $Key))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("Value", $($Value | ConvertTo-Json -Depth 10)))) | Out-Null # replace with serialization
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("DataType", $($null -eq $Value ? "null" : $Value.GetType().FullName)))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_SetConfigValue]", $parameters) | Out-Null
    }

    [void]AddQueueItem(
        [string]$NodeId,
        [string]$URL,
        [datetime]$LastModified,
        [object]$Properties,
        [object]$Permissions,
        [string]$SecurityClass,
        [int]$Type
    )
    {
        if ($NodeId.Length -gt 128)
        {
            throw "NodeId length exceeds maximum of 128 characters."
        }

        if ($URL.Length -gt 2048)
        {
            throw "URL length exceeds maximum of 2048 characters."
        }

        if ($SecurityClass.Length -gt 100)
        {
            throw "SecurityClass length exceeds maximum of 100 characters."
        }
        
        $properties = ConvertTo-Json -InputObject $Properties -Depth 10
        $permissions = ConvertTo-Json -InputObject $Permissions -Depth 10

        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("NodeId", $NodeId))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("URL", $URL))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("LastModified", $LastModified))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("Properties", $properties))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("Permissions", $permissions))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("SecurityClass", $SecurityClass))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("Type", $Type))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_AddQueueItem]", $parameters) | Out-Null
    }

    [void]SetQueueItemSecurityClass(
        [string]$NodeId,
        [string]$SecurityClass
    )
    {
        if ($NodeId.Length -gt 128)
        {
            throw "NodeId length exceeds maximum of 128 characters."
        }

        if ($SecurityClass.Length -gt 100)
        {
            throw "SecurityClass length exceeds maximum of 100 characters."
        }

        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("NodeId", $NodeId))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("SecurityClass", $SecurityClass))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_SetQueueItemSecurityClass]", $parameters) | Out-Null
    }

    [void]MarkQueueItemProcessed(
        [string]$NodeId
    )
    {
        if ($NodeId.Length -gt 128)
        {
            throw "NodeId length exceeds maximum of 128 characters."
        }

        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("NodeId", $NodeId))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_MarkQueueItemProcessed]", $parameters) | Out-Null
    }

    [void]SetQueueItemStatus(
        [string]$NodeId, #single value or comma separated list of node ids for batch update
        [string]$Status
    )
    {
        if ($Status.Length -gt 20)
        {
            throw "Status length exceeds maximum of 20 characters."
        }

        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("NodeId", $NodeId))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("Status", $Status))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_SetQueueItemStatus]", $parameters) | Out-Null
    }

    [int32]GetNextFolderToEnumerate(
        [bool]$FoldersOnly = $false
    )
    {
        # $this.PerformSchemaCheck();
        $statusRequired = $FoldersOnly ? "Pending" : "FolderEnumerated"
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $dataset = $this.sqlHelper.GetParametrizedDataSet("SELECT TOP 1 [NodeId] FROM [dbo].[Queue] WHERE [Type]=0 AND [Status]='$statusRequired' ORDER BY [EnqueuedAt] ASC", $parameters, -1)
        $res = -1

        if ($dataset.Tables.Count -ge 1)
        {
            if ($dataset.Tables[0].Rows.Count -ge 1)
            {
                $res = [int32]$dataset.Tables[0].Rows[0]["NodeId"]
            }
        }

        return $res
    }

    [int32]GetTotalQueueItemsToProcess()
    {
        # $this.PerformSchemaCheck();
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $count = $this.sqlHelper.GetTSQLValue("SELECT COUNT(*) AS ItemCount FROM [dbo].[Queue] WHERE [Type]=1 AND [Status]='Pending'", "ItemCount")
        return [int32]$count
    }

    [object]GetQueueItemsToProcess(
        [int32]$MaxItemsToProcess = 10
    )
    {
        # $this.PerformSchemaCheck();
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $dataset = $this.sqlHelper.GetParametrizedDataSet("SELECT TOP $MaxItemsToProcess * FROM [dbo].[Queue] WHERE [Type]=1 AND [Status]='Pending' ORDER BY [EnqueuedAt] ASC", $parameters, -1)
        $res = -1

        if ($dataset.Tables.Count -ge 1)
        {
            if ($dataset.Tables[0].Rows.Count -ge 1)
            {
                $res = $dataset.Tables[0].Rows
            }
        }

        return $res
    }

    [object]GetQueueItem(
        [int32]$NodeId
    )
    {
        # $this.PerformSchemaCheck();
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("NodeId", $NodeId))) | Out-Null
        $dataset = $this.sqlHelper.GetParametrizedDataSet("SELECT * FROM [dbo].[Queue] WHERE [NodeId]=@NodeId", $parameters, -1)
        $res = $null

        if ($dataset.Tables.Count -ge 1)
        {
            if ($dataset.Tables[0].Rows.Count -ge 1)
            {
                $res = $dataset.Tables[0].Rows[0]
            }
        }

        return $res
    }

    [object]GetQueueFoldersToProcess(
        [int32]$MaxItemsToProcess = 10
    )
    {
        # $this.PerformSchemaCheck();
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $dataset = $this.sqlHelper.GetParametrizedDataSet("SELECT TOP $MaxItemsToProcess * FROM [dbo].[Queue] WHERE [Type]=0 AND [Status]='Pending' ORDER BY [EnqueuedAt] ASC", $parameters, -1)
        $res = -1

        if ($dataset.Tables.Count -ge 1)
        {
            if ($dataset.Tables[0].Rows.Count -ge 1)
            {
                $res = $dataset.Tables[0].Rows
            }
        }

        return $res
    }

    [void]RemoveIndexedItem(
        [string]$NodeId
    )
    {
        if ($NodeId.Length -gt 128)
        {
            throw "NodeId length exceeds maximum of 128 characters."
        }

        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("NodeId", $NodeId))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_RemoveIndexedItem]", $parameters) | Out-Null
    }

    [void]AddGroup(
        [string]$GroupId,
        [string]$DisplayName,
        [datetime]$LastModified
    )
    {
        if ($GroupId.Length -gt 128)
        {
            throw "GroupId length exceeds maximum of 128 characters."
        }

        if ($DisplayName.Length -gt 255)
        {
            throw "DisplayName length exceeds maximum of 255 characters."
        }

        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("GroupId", $GroupId))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("DisplayName", $DisplayName))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("LastModified", $LastModified))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_AddGroup]", $parameters) | Out-Null
    }

    [System.Object]GetGroup(
        [string]$GroupId
    )
    {
        # $this.PerformSchemaCheck();
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("GroupId", $GroupId))) | Out-Null
        $dataset = $this.sqlHelper.GetParametrizedDataSet("SELECT * FROM [dbo].[Groups] WHERE [GroupId]=@GroupId", $parameters, -1)
        $res = $null

        if ($dataset.Tables.Count -ge 1)
        {
            if ($dataset.Tables[0].Rows.Count -ge 1)
            {
                $res = $dataset.Tables[0].Rows[0]
            }
        }

        return $res
    }

    [System.Object]GetGroups()
    {
        # $this.PerformSchemaCheck();
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $dataset = $this.sqlHelper.GetParametrizedDataSet("SELECT * FROM [dbo].[Groups]", $parameters, -1)
        $res = $null

        if ($dataset.Tables.Count -ge 1)
        {
            if ($dataset.Tables[0].Rows.Count -ge 1)
            {
                $res = $dataset.Tables[0].Rows
            }
        }

        return $res
    }


    [void]RemoveGroup(
        [string]$GroupId
    )
    {
        if ($GroupId.Length -gt 128)
        {
            throw "GroupId length exceeds maximum of 128 characters."
        }

        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("GroupId", $GroupId))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_RemoveGroup]", $parameters) | Out-Null
    }

    [void]AddGroupMember(
        [string]$GroupId,
        [string]$MemberId,
        [string]$MemberType
    )
    {
        if ($GroupId.Length -gt 128)
        {
            throw "GroupId length exceeds maximum of 128 characters."
        }

        if ($MemberId.Length -gt 256)
        {
            throw "MemberId length exceeds maximum of 256 characters."
        }

        if ($MemberType.Length -gt 20)
        {
            throw "MemberType length exceeds maximum of 20 characters."
        }

        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("GroupId", $GroupId))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("MemberId", $MemberId))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("MemberType", $MemberType))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_AddGroupMember]", $parameters) | Out-Null
    }

    [System.Object]GetGroupMembers(
        [string]$GroupId
    )
    {
        # $this.PerformSchemaCheck();
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("GroupId", $GroupId))) | Out-Null
        $dataset = $this.sqlHelper.GetParametrizedDataSet("SELECT * FROM [dbo].[GroupMembers] WHERE [GroupId]=@GroupId", $parameters, -1)
        $res = $null

        if ($dataset.Tables.Count -ge 1)
        {
            if ($dataset.Tables[0].Rows.Count -ge 1)
            {
                $res = $dataset.Tables[0].Rows[0]
            }
        }

        return $res
    }

    [void]RemoveGroupMember(
        [string]$GroupId,
        [string]$MemberId,
        [string]$MemberType
    )
    {
        if ($GroupId.Length -gt 128)
        {
            throw "GroupId length exceeds maximum of 128 characters."
        }

        if ($MemberId.Length -gt 256)
        {
            throw "MemberId length exceeds maximum of 256 characters."
        }

        if ($MemberType.Length -gt 20)
        {
            throw "MemberType length exceeds maximum of 20 characters."
        }

        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("GroupId", $GroupId))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("MemberId", $MemberId))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("MemberType", $MemberType))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_RemoveGroupMember]", $parameters) | Out-Null
    }

    [void]AddUser(
        [Guid]$Id,
        [string]$EMail
    )
    {
        if ($EMail.Length -gt 320)
        {
            throw "EMail length exceeds maximum of 320 characters."
        }

        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("Id", $Id))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("EMail", $EMail))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_AddUser]", $parameters) | Out-Null
    }

    [System.Object]GetUser(
        [string]$EMail
    )
    {
        # $this.PerformSchemaCheck();
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("EMail", $EMail))) | Out-Null
        $dataset = $this.sqlHelper.GetParametrizedDataSet("SELECT * FROM [dbo].[Users] WHERE [EMail]=@EMail", $parameters, -1)
        $res = $null

        if ($dataset.Tables.Count -ge 1)
        {
            if ($dataset.Tables[0].Rows.Count -ge 1)
            {
                $res = $dataset.Tables[0].Rows[0]
            }
        }

        return $res
    }

    [System.Object]GetCachedObject(
        [string]$ObjectId,
        [string]$ObjectType
    )
    {
        # $this.PerformSchemaCheck();
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("ObjectId", $ObjectId))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("ObjectType", $ObjectType))) | Out-Null
        $dataset = $this.sqlHelper.GetParametrizedDataSet("SELECT * FROM [dbo].[CachedObjects] WHERE [ObjectId]=@ObjectId AND [ObjectType]=@ObjectType", $parameters, -1)
        $res = $null

        if ($dataset.Tables.Count -ge 1)
        {
            if ($dataset.Tables[0].Rows.Count -ge 1)
            {
                $res = $dataset.Tables[0].Rows[0]
            }
        }

        if ($null -ne $res)
        {
            $expiresOn = $res["expiresOn"]
            if ($expiresOn -lt ([DateTime]::UtcNow))
            {
                # cache expired, remove it
                $this.RemoveCachedObject($ObjectId, $ObjectType)
                return $null
            }
        }

        return $res
    }

    [void]AddCachedObject(
        [Guid]$Id,
        [string]$ObjectId,
        [string]$ObjectType,
        [string]$SerializedData,
        [int]$ExpirationInMinutes
    )
    {
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("Id", $Id))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("ObjectId", $ObjectId))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("ObjectType", $ObjectType))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("SerializedData", $SerializedData))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("ExpiresOn", ([DateTime]::UtcNow).AddMinutes($ExpirationInMinutes)))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_AddCachedObject]", $parameters) | Out-Null
    }

    [void]RemoveCachedObject(
        [string]$ObjectId,
        [string]$ObjectType
    )
    {
        $parameters = New-Object 'System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]'
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("ObjectId", $ObjectId))) | Out-Null
        $parameters.Add($(New-Object System.Data.SqlClient.SqlParameter("ObjectType", $ObjectType))) | Out-Null
        $this.sqlHelper.InvokeSQLProcedure("[dbo].[proc_RemoveCachedObject]", $parameters) | Out-Null
    }
}