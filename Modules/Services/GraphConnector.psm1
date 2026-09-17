using module ..\AuthManager.psm1
using module ..\AuthManagerHelper.psm1
using module ..\Logging.psm1
using module ..\ConfigurationManager.psm1
using module ..\OTCSGraphConnectorDB.psm1
using module ..\NameValuePair.psm1

class Principal {
    [string]$Id
    [string]$Type

    Principal(
        [string]$Id,
        [string]$Type
    ) {
        $this.Id = $Id;
        $this.Type = $Type;
    }
}

class Acl {
    [string]$type
    [string]$value
    [string]$accessType

    Acl(
        [string]$Type,
        [string]$Value,
        [string]$AccessType
    ) {
        $this.type = $Type;
        $this.value = $Value;
        $this.accessType = $AccessType;
    }

    [bool]Equals([object]$obj) {
        if ($null -eq $obj -or $this.GetType() -ne $obj.GetType()) {
            return $false
        }

        $other = [Acl]$obj
        return $($this.type -eq $other.type) -and $($this.value -eq $other.value) -and $($this.accessType -eq $other.accessType)
    }

    [int]GetHashCode() {
        return $this.type.GetHashCode() -bxor $this.value.GetHashCode() -bxor $this.accessType.GetHashCode()
    }
}

class IndexResponse {
    [bool]$Success
    [object]$Response
    [object]$Payload
}

class GraphConnector {
    [OTCSGraphConnectorDB]$m_db = [OTCSGraphConnectorDB]::new();
    [AuthManager]$AuthManager = $null;
    [bool]$Ready = $false;
    [string] $ConnectorId = "otcsGraphConnector";
    [string] $ConnectorEndpoint = "https://graph.microsoft.com/v1.0/external/connections/$($this.ConnectorId)";
    [string] $RootUrl = "";
    [object] $Connector = $null;
    [string] $ProvisioningStateUrl = "";
    [System.Collections.Generic.List[Acl]]$AccessControlList = [System.Collections.Generic.List[Acl]]::new();

    GraphConnector() {
        # retrieve connector configuration from the database

        $authConfigKey = [string]::IsNullOrWhiteSpace([ConfigurationManager]::CopilotConnectorAuthConfig) ? 
                            [ConfigurationManager]::GraphApiAuthConfig : [ConfigurationManager]::CopilotConnectorAuthConfig;
                            
        if ([string]::IsNullOrWhiteSpace($authConfigKey))
        {
            $this.AuthManager = [AuthManagerHelper]::CreateInstance("https://graph.microsoft.com");
        } else {
            $authConfigJson = [ConfigurationManager]::GetSecret($authConfigKey);
            $authConfig = ConvertFrom-Json $authConfigJson
            $this.AuthManager = [AuthManager]::new(
                $authConfig.ClientId,
                $authConfig.ClientSecret,
                $authConfig.TenantDomain,
                "https://graph.microsoft.com")
        }

        $this.RefreshConnectorState();

        if (!$this.CheckRoles()) {
            $decodedToken = $this.AuthManager.DecodeToken();
            $errorMsg = "App registration doesn't have required API permissions. Please add ExternalItem.ReadWrite.OwnedBy or ExternalItem.ReadWrite.All permission to the App registration '$($decodedToken.Payload.app_displayname)' [App Id: $($decodedToken.Payload.appid)] and try again.";
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "Initialization", "gm021", $errorMsg);
            throw $errorMsg
        }
    }

    [void]RefreshConnectorState() {
        $this.Connector = $this.GetConnector();
        if ($null -ne $this.Connector -and $this.Connector.state -eq "ready") {
            $this.Ready = $true;
        } else {
            $this.Ready = $false;
        }
    }   

    [object]CreateConnector(
        [string]$Name,
        [string]$Description
    ) {
        if ($null -ne $this.Connector) {
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "CreateConnector", "gm030", "Graph connector already exists. Updating existing connector.");
            return $this.UpdateConnector($Name, $Description);
        }

        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "CreateConnector", "gm031", "Creating Graph connector.");

        $connectorBody = @{
            id = $this.ConnectorId
            name = $Name
            description = $Description
        }

        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/external/connections" -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json" } -Body $(ConvertTo-Json $connectorBody -Depth 10) -SkipHttpErrorCheck -TimeoutSec 30

        $conn = $null
        if ($res.StatusCode -eq 201) {
            $conn = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "CreateConnector", "gm032", "Connector created: $($conn.name). Connector state: $($conn.state)");
        }
        else {
            $responseObject = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "CreateConnector", "gm033", "Creating connector failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
        }
        
        return $conn;
    }

    [object]UpdateConnector(
        [string]$Name,
        [string]$Description
    ) {
        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "CreateConnector", "gm031", "Creating Graph connector.");

        $connectorBody = @{
            id = $this.ConnectorId
            name = $Name
            description = $Description
        }

        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method PATCH -Uri $this.ConnectorEndpoint -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json" } -Body $(ConvertTo-Json $connectorBody -Depth 10) -SkipHttpErrorCheck -TimeoutSec 30

        $conn = $null
        if ($res.StatusCode -eq 200) {
            $conn = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "CreateConnector", "gm032", "Connector created: $($conn.name). Connector state: $($conn.state)");
        }
        else {
            $responseObject = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "CreateConnector", "gm033", "Creating connector failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
        }
        
        return $conn;
    }

    [void]ProvisionSchema() {
        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "ProvisionSchema", "gm040", "Provisioning schema.");

        $schemaBody = @{
            baseType = "microsoft.graph.externalItem"
            properties = @(
                @{
                    name = "id"
                    type = "String"
                    isQueryable = $true
                    isRetrievable = $true
                    isRefinable = $false
                    isSearchable = $false
                },
                @{
                    name = "title"
                    type = "String"
                    isQueryable = $true
                    isRetrievable = $true
                    isRefinable = $false
                    isSearchable = $true
                    labels = @(
                        "title"
                    )
                },
                @{
                    name = "url"
                    type = "String"
                    isQueryable = $true
                    isRetrievable = $true
                    isRefinable = $true
                    isSearchable = $true
                    labels = @(
                        "url"
                    )
                },
                @{
                    name = "iconUrl"
                    type = "String"
                    isQueryable = $true
                    isRetrievable = $true
                    isRefinable = $true
                    isSearchable = $true
                    labels = @(
                        "iconUrl"
                    )
                },
                @{
                    name = "lastModifiedDateTime"
                    type = "dateTime"
                    isQueryable = $true
                    isRetrievable = $true
                    isRefinable = $true
                    isSearchable = $false
                    labels = @(
                        "lastModifiedDateTime"
                    )
                }
            )
        }

        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method PATCH -Uri "$($this.ConnectorEndpoint)/schema" -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json" } -Body $(ConvertTo-Json $schemaBody -Depth 10) -SkipHttpErrorCheck -TimeoutSec 30

        if ($res.StatusCode -eq 202) {
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "ProvisionSchema", "gm041", "Schema provisioning started successfully.");
            $this.ProvisioningStateUrl = $res.Headers."Location"[0];
        }
        else {
            # $responseObject = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "ProvisionSchema", "gm042", "Provisioning schema failed. HTTP status code: $($res.StatusCode).");
        }
    }

    [object]GetProvisioningState() {
        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "GetProvisioningState", "gm050", "Retrieving provisioning state.");

        if ([string]::IsNullOrWhiteSpace($this.ProvisioningStateUrl)) {
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "GetProvisioningState", "gm051", "No provisioning job in progress.");
            return $null;
        }

        $provisioningState = $null

        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method GET -Uri $this.ProvisioningStateUrl -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json" } -SkipHttpErrorCheck -TimeoutSec 30

        if ($res.StatusCode -eq 200) {
            $provisioningState = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "GetProvisioningState", "gm051", "Provisioning state retrieved: $($provisioningState.status).");
            if ($provisioningState.status -eq "completed") {
                $this.ProvisioningStateUrl = "";
            }
        }
        else {
            $responseObject = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "GetProvisioningState", "gm052", "Retrieving provisioning state failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
        }
        
        return $provisioningState;
    }   

    [bool]CheckRoles() {
        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "CheckRoles", "gm042", "Validating permissions.");
        $requiredRolesAvailable = $false;
        $decodedToken = $this.AuthManager.DecodeToken();
        $decodedToken.Payload.roles | Foreach-Object { $requiredRolesAvailable = $requiredRolesAvailable -or ($_ -in @("ExternalItem.ReadWrite.OwnedBy", "ExternalItem.ReadWrite.All")) }
        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "CheckRoles", "gm043", "Required roles available: $requiredRolesAvailable.");
        return $requiredRolesAvailable;
    }

    [object]GetConnector() {
        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "GetConnector", "gm052", "Retrieving Graph connector.");

        $conn = $null

        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method GET -Uri $this.ConnectorEndpoint -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json" } -SkipHttpErrorCheck -TimeoutSec 30

        if ($res.StatusCode -eq 200) {
            $conn = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "GetConnector", "gm053", "Connector retrieved: $($conn.name). Connector state: $($conn.state)");
        }
        else {
            $responseObject = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "GetConnector", "gm053", "Retrieving connector failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
        }
        
        return $conn;
    }

    [IndexResponse]IndexItem(
        [string]$Id,
        [string]$Title,
        [string]$Url,
        [string]$Content,
        [string]$contentType,
        [System.Collections.Generic.List[Acl]]$AclList
    ) {
        if ($AclList.Count -lt 1) {
            $AclList.Add((New-Object Acl("everyone", "everyone", "deny")));
        }

        $responseObject = [IndexResponse]::new();
        if ($this.Ready -eq $false) {
            $errorMsg = "Graph connector is not ready. Indexing item will be skipped.";
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "GraphManager", "Index", "gm0a0", $errorMsg);
            $responseObject.Success = $false
            $responseObject.Response = @{ 
                Content = $errorMsg
                StatusCode = 405
                StatusDescription = "Method Not Allowed"
            }
            $responseObject.Payload = $null
        }
        else {
            $iconUrl = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAACXBIWXMAAAsTAAALEwEAmpwYAAAE9mlUWHRYTUw6Y29tLmFkb2JlLnhtcAAAAAAAPD94cGFja2V0IGJlZ2luPSLvu78iIGlkPSJXNU0wTXBDZWhpSHpyZVN6TlRjemtjOWQiPz4gPHg6eG1wbWV0YSB4bWxuczp4PSJhZG9iZTpuczptZXRhLyIgeDp4bXB0az0iQWRvYmUgWE1QIENvcmUgOS4xLWMwMDIgNzkuYTZhNjM5NjhhLCAyMDI0LzAzLzA2LTExOjUyOjA1ICAgICAgICAiPiA8cmRmOlJERiB4bWxuczpyZGY9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkvMDIvMjItcmRmLXN5bnRheC1ucyMiPiA8cmRmOkRlc2NyaXB0aW9uIHJkZjphYm91dD0iIiB4bWxuczp4bXA9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC8iIHhtbG5zOmRjPSJodHRwOi8vcHVybC5vcmcvZGMvZWxlbWVudHMvMS4xLyIgeG1sbnM6cGhvdG9zaG9wPSJodHRwOi8vbnMuYWRvYmUuY29tL3Bob3Rvc2hvcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RFdnQ9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZUV2ZW50IyIgeG1wOkNyZWF0b3JUb29sPSJBZG9iZSBQaG90b3Nob3AgMjUuMTEgKE1hY2ludG9zaCkiIHhtcDpDcmVhdGVEYXRlPSIyMDI0LTA5LTA2VDEyOjM3OjM0KzAyOjAwIiB4bXA6TW9kaWZ5RGF0ZT0iMjAyNC0wOS0wNlQxMjo0MjoxMSswMjowMCIgeG1wOk1ldGFkYXRhRGF0ZT0iMjAyNC0wOS0wNlQxMjo0MjoxMSswMjowMCIgZGM6Zm9ybWF0PSJpbWFnZS9wbmciIHBob3Rvc2hvcDpDb2xvck1vZGU9IjMiIHhtcE1NOkluc3RhbmNlSUQ9InhtcC5paWQ6MjhjZGQxMGYtMWViOS00NTQ5LWJiNTMtODFjOTE3MThhNzU4IiB4bXBNTTpEb2N1bWVudElEPSJ4bXAuZGlkOjI4Y2RkMTBmLTFlYjktNDU0OS1iYjUzLTgxYzkxNzE4YTc1OCIgeG1wTU06T3JpZ2luYWxEb2N1bWVudElEPSJ4bXAuZGlkOjI4Y2RkMTBmLTFlYjktNDU0OS1iYjUzLTgxYzkxNzE4YTc1OCI+IDx4bXBNTTpIaXN0b3J5PiA8cmRmOlNlcT4gPHJkZjpsaSBzdEV2dDphY3Rpb249ImNyZWF0ZWQiIHN0RXZ0Omluc3RhbmNlSUQ9InhtcC5paWQ6MjhjZGQxMGYtMWViOS00NTQ5LWJiNTMtODFjOTE3MThhNzU4IiBzdEV2dDp3aGVuPSIyMDI0LTA5LTA2VDEyOjM3OjM0KzAyOjAwIiBzdEV2dDpzb2Z0d2FyZUFnZW50PSJBZG9iZSBQaG90b3Nob3AgMjUuMTEgKE1hY2ludG9zaCkiLz4gPC9yZGY6U2VxPiA8L3htcE1NOkhpc3Rvcnk+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+tEc1XQAAAixJREFUWMPtl8srRFEcx8eCjTTMsFDKxkJJzGoWNqxspNjY2lj4D7CytCJ5JJGQLrKwVFMkhQWmLOSxGGUjj5LXeF/fn75T1+3cO/eeMJTFpzvn8bu/7/md37m/MwHTNAOZJPDnBBiGUQ6WwQOIg05Q+iMC4CgHHIJT0AvWwBuR3+2gkHNbwD64BaMgz5MAmQgmwQ0wbTzy2WSZX8oo7HLsCWyDVz4nwAtYB0EvAqZoMA16bGyAc5DtEKFK2j+DTZDL/maK3wKhdALuwJyiP5/7PuCyRVXgitEosI01WPKmyE2AhHFY0d/GsaiD8zJwBk5AicOcei5wDxT7FbAKDhxeXASOKKAiTSLXMTEPRKh0hMECk8f0gcyfZxLGubKox9NUA67BojRmmSAjiqRzY5R2x3w2+jzSfSJCfiSlofFBygJDPqOWQhL1AiRSe95heXE3aFU4bJUxW18X7Xt8Mk+7DZUAaa8oBKzImK2vw7oyi72XviWJfiYFfNj+WgEJ5oKVhJMAnSqYToAjOhHQEfClW/BrBPCrGwPVXyrA456H+ck2KeJ7IsD+CJ2EFM7jbDsKqJUQKQRI2Go9CojxmrbDMv3JuWsO6BwlhYAwnb+x6n1ybhdwD/o1BQxKGXYYC1GEOL+0OrcLMFjbx3wWlHHazbgIDHE7Im7HUO56c4yEn5J6x7tEUDN6Qx/FSDGQisi4Rpn1Gz1DJSDIlSU1LxteSDLqwcD/n9NMC3gH+DphDKIJ8XAAAAAASUVORK5CYII="
            $itemBody = @{
                acl        = $AclList
                properties = @{
                    id                     = $Id
                    title                  = $Title
                    url                    = $Url
                    iconUrl                = $iconUrl
                }
                content    = @{
                    value = $Content
                    type  = $ContentType
                }
            }
        
            $token = $this.AuthManager.GetAuthToken();
            $itemRes = Invoke-WebRequest -Method PUT -URI "$($this.ConnectorEndpoint)/items/$Id" -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json; charset=utf-8" } -Body $(ConvertTo-Json $itemBody -Depth 10) -SkipHttpErrorCheck -TimeoutSec 120
            
            if ($itemRes.StatusCode -eq 200) {
                $responseObject.Success = $true
                $responseObject.Response = $(ConvertFrom-Json $itemRes.Content)
                $responseObject.Payload = $null
            
                $this.m_db.MarkQueueItemProcessed($Id);
            }
            else {
                $responseObject.Success = $false
                $responseObject.Response = $($itemRes | Select-Object Content, Encoding, Headers, Images, InputFields, Links, RelationLink, StatusCode, StatusDescription)
                $responseObject.Payload = $(ConvertTo-Json $itemBody -Depth 10)
                [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "Index", "gm0a1", "Couldn't index item. HTTP status code: $($itemRes.StatusCode). Message: $($responseObject.Response.Content).");
            
            }
        }

        return $responseObject;
    }

    [void]DeleteItem(
        [string]$Id
    ) {
        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method DELETE -Uri "$($this.ConnectorEndpoint)/items/$Id" -Headers @{ Authorization = "Bearer $($token.access_token)" } -SkipHttpErrorCheck -TimeoutSec 30

        if ($res.StatusCode -eq 204) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "GraphManager", "Delete", "gm0b1", "Item with ID '$Id' deleted successfully.");
            $this.m_db.RemoveIndexedItem($Id);
        }
        else {
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "Delete", "gm0b2", "Couldn't delete item with ID '$Id'. HTTP status code: $($res.StatusCode). Message: $($res.Content).");
        }
    }

    [object]GetGroup(
        [string]$GroupId
    ) {
        $group = $null

        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method GET -Uri "$($this.ConnectorEndpoint)/groups/$GroupId" -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json" } -SkipHttpErrorCheck -TimeoutSec 30

        if ($res.StatusCode -eq 200) {
            $group = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "GetGroup", "gm0c1", "Group retrieved: $($group.displayName) [ID: $($group.id)].");
        }
        else {
            $responseObject = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "GetGroup", "gm0c2", "Retrieving group failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
        }
        
        return $group;
    }

    [object]CreateGroup(
        [string]$GroupId,
        [string]$DisplayName,
        [string]$Description
    ) {
        $group = $this.GetGroup($GroupId);
        if ($null -ne $group) {
            return $group;
        }

        $groupBody = @{
            id = $GroupId
            displayName = $DisplayName
            description = $Description
        }

        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method POST -Uri "$($this.ConnectorEndpoint)/groups" -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json" } -Body $(ConvertTo-Json $groupBody -Depth 10) -SkipHttpErrorCheck -TimeoutSec 30

        if ($res.StatusCode -eq 201) {
            $group = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "CreateGroup", "gm0d1", "Group created: $($group.displayName) [ID: $($group.id)].");
            $this.m_db.AddGroup($GroupId, $DisplayName, [DateTime]::UtcNow);
        }
        else {
            $responseObject = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "CreateGroup", "gm0d2", "Creating group failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
        }
        
        return $group;
    }

    [object]UpdateGroup(
        [string]$GroupId,
        [string]$DisplayName,
        [string]$Description
    ) {
        $group = $this.GetGroup($GroupId);
        if ($null -ne $group) {
            if ($group.displayName -eq $DisplayName -and $group.description -eq $Description) {
                [TraceLogging]::LogEvent([LoggingLevel]::Information, "GraphManager", "UpdateGroup", "gm0d0", "Group with ID '$GroupId' is already up to date. No update needed.");
                return $group;
            }

            $groupBody = @{
                displayName = $DisplayName
                description = $Description
            }

            $token = $this.AuthManager.GetAuthToken();
            $res = Invoke-WebRequest -Method PATCH -Uri "$($this.ConnectorEndpoint)/groups/$GroupId" -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json" } -Body $(ConvertTo-Json $groupBody -Depth 10) -SkipHttpErrorCheck -TimeoutSec 30

            if ($res.StatusCode -eq 204) {
                $group = $(ConvertFrom-Json $res.Content);
                [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "UpdateGroup", "gm0d1", "Group updated: $($group.displayName) [ID: $($group.id)].");
                $this.m_db.AddGroup($GroupId, $DisplayName, [DateTime]::UtcNow); # AddGroup method will update existing group as well
            }
            else {
                $responseObject = $(ConvertFrom-Json $res.Content);
                [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "UpdateGroup", "gm0d2", "Updating group failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
            }
            
            return $group;
        } else {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "GraphManager", "UpdateGroup", "gm0d3", "Group with ID '$GroupId' doesn't exist. Creating new group.");
            return $this.CreateGroup($GroupId, $DisplayName, $Description);
        }  
    }

    [void]DeleteGroup(
        [string]$GroupId
    ) {
        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method DELETE -Uri "$($this.ConnectorEndpoint)/groups/$GroupId" -Headers @{ Authorization = "Bearer $($token.access_token)" } -SkipHttpErrorCheck -TimeoutSec 30

        if ($res.StatusCode -eq 204) {
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "DeleteGroup", "gm0h1", "Group deleted: [ID: $GroupId].");
            $this.m_db.RemoveGroup($GroupId);
        }
        else {
            $responseObject = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "DeleteGroup", "gm0h2", "Deleting group failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
        }
    }

    [object]GetUserByEmail(
        [string]$UserEmail
    ) {
        $user = $this.m_db.GetUser($UserEmail);

        if ($null -ne $user) {
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "GetUserByEmail", "gm0e0", "User retrieved from cache: [ID: $($user.id)].");
            return $user;
        }

        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users?`$filter=proxyAddresses/any(c:c eq 'SMTP:$UserEmail')" -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json" } -SkipHttpErrorCheck -TimeoutSec 30

        
        if ($res.StatusCode -eq 200) {
            $resultObject = $(ConvertFrom-Json $res.Content);
            $user = $resultObject.value | Select-Object -First 1;
            if ($null -eq $user)
            {
                [TraceLogging]::LogEvent([LoggingLevel]::Warning, "GraphManager", "GetUserByEmail", "gm0e3", "User with email '$UserEmail' not found. Trying UPN lookup.");
                $res = Invoke-WebRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$UserEmail" -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json" } -SkipHttpErrorCheck -TimeoutSec 30
                if ($res.StatusCode -eq 200) {
                    $resultObject = $(ConvertFrom-Json $res.Content);
                    $user = $resultObject;
                    [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "GetUserByEmail", "gm0e4", "User retrieved by UPN: $($user.displayName) [ID: $($user.id)].");
                } else {
                    $responseObject = $(ConvertFrom-Json $res.Content);
                    [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "GetUserByEmail", "gm0e5", "Retrieving user by UPN failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
                }
    
            }
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "GetUserByEmail", "gm0e1", "User retrieved: $($user.displayName) [ID: $($user.id)].");
        }
        else {
            $responseObject = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "GetUserByEmail", "gm0e2", "Retrieving user failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
        }
        
        if ($null -ne $user) {
            $this.m_db.AddUser($user.id, $UserEmail);
        }

        return $user;
    }

    [object]AddGroupMember(
        [string]$GroupId,
        [string]$MemberId,
        [string]$MemberType
    ) {
        if ($MemberType -notin @("user", "group", "externalGroup")) {
            $errorMsg = "Invalid member type '$MemberType'. Only 'user', 'group' and 'externalGroup' types are supported.";
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "AddGroupMember", "gm0f3", $errorMsg);
            return $null;
        }

        $MemberUniqueId = $MemberId;
        if ($MemberType.ToLower() -eq "user") {
            $userObject = $this.GetUserByEmail($MemberId);
            if ($null -ne $userObject) {
                $MemberUniqueId = $userObject.id;
            } else {
                $errorMsg = "User with email / UPN '$MemberId' not found.";
                [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "AddGroupMember", "gm0f0", $errorMsg);
                return $null;
            }
        }

        $memberBody = @{
            id = $MemberUniqueId
            type = $MemberType
        }

        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method POST -Uri "$($this.ConnectorEndpoint)/groups/$GroupId/members/" -Headers @{ Authorization = "Bearer $($token.access_token)"; "Content-Type" = "application/json" } -Body $(ConvertTo-Json $memberBody -Depth 10) -SkipHttpErrorCheck -TimeoutSec 120

        $memberObject = $null;
        if ($res.StatusCode -eq 201) {
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "AddGroupMember", "gm0f1", "Member with ID '$MemberId' added to group with ID '$GroupId'.");
            $memberObject = $(ConvertFrom-Json $res.Content);
            $this.m_db.AddGroupMember($GroupId, $MemberId, $MemberType);
        }
        else {
            $responseObject = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "AddGroupMember", "gm0f2", "Adding user to group failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
        }
        return $memberObject;
    }

    [void]RemoveGroupMember(
        [string]$GroupId,
        [string]$MemberId,
        [string]$MemberType
    ) {
        if ($MemberType -notin @("user", "group", "externalGroup")) {
            $errorMsg = "Invalid member type '$MemberType'. Only 'user', 'group' and 'externalGroup' types are supported.";
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "RemoveGroupMember", "gm0g3", $errorMsg);
        }

        $MemberUniqueId = $MemberId;
        if ($MemberType.ToLower() -eq "user") {
            $userObject = $this.GetUserByEmail($MemberId);
            if ($null -ne $userObject) {
                $MemberUniqueId = $userObject.id;
            } else {
                $errorMsg = "User with email '$MemberId' not found.";
                [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "RemoveGroupMember", "gm0g0", $errorMsg);
            }
        }

        $token = $this.AuthManager.GetAuthToken();
        $res = Invoke-WebRequest -Method DELETE -Uri "$($this.ConnectorEndpoint)/groups/$GroupId/members/$MemberUniqueId" -Headers @{ Authorization = "Bearer $($token.access_token)" } -SkipHttpErrorCheck -TimeoutSec 30

        if ($res.StatusCode -eq 204) {
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "GraphManager", "RemoveGroupMember", "gm0g1", "Member with ID '$MemberId' removed from group with ID '$GroupId'.");
            $this.m_db.RemoveGroupMember($GroupId, $MemberId, $MemberType);
        }
        else {
            $responseObject = $(ConvertFrom-Json $res.Content);
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "GraphManager", "RemoveGroupMember", "gm0g2", "Removing member from group failed. HTTP status code: $($res.StatusCode). Error code: $($responseObject.error.code). Error message: $($responseObject.error.message)");
        }
    }
}