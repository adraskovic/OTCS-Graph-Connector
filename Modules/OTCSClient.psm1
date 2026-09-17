using module .\Logging.psm1
using module .\ConfigurationManager.psm1
using module .\OTCSAuthManager.psm1
using module .\OTCSGraphConnectorDB.psm1
using module .\Services\GraphConnector.psm1;
using module .\ServiceBusManager.psm1
using module .\BlobStorageManager.psm1
using module .\Utility.psd1
using module .\Utility.psm1

class Group {
    [string]$GroupID;
    [string]$Name;
    [string]$Description;

    Group(
        [string]$GroupID,
        [string]$Name,
        [string]$Description = ""
    ) {
        $this.GroupID = $GroupID;
        $this.Name = $Name;
        $this.Description = $Description;
    }
}

class GroupMember {
    [string]$GroupId;
    [string]$MemberId;
    [string]$MemberType;

    GroupMember(
        [string]$GroupId,
        [string]$MemberId,
        [string]$MemberType
    ) {
        $this.GroupId = $GroupId;
        $this.MemberId = $MemberId;
        $this.MemberType = $MemberType;
    }
}

class OTCSClient {
    [OTCSGraphConnectorDB]$m_db = [OTCSGraphConnectorDB]::new();
    [OTCSAuthManager]$m_authManager;
    [GraphConnector]$m_gc = [GraphConnector]::new();
    [ServiceBusManager]$m_sb = [ServiceBusManager]::new();
    [string]$KeyVaultSecretName = "otcs-auth-ticket";
	[BlobStorageManager]$BlobStorageManager = [BlobStorageManager]::new();

    OTCSClient() {
        if ($null -eq $global:OTCSAuthManager) {
            $global:OTCSAuthManager = [OTCSAuthManager]::new();
        }
        $this.m_authManager = $global:OTCSAuthManager;
    }

    [bool] TestTokenEnvelope(
        [object] $Envelope
    )
    {
        if ($null -eq $Envelope)
        {
            TraceLogging::LogEvent(
                [LoggingLevel]::Error,
                "OTCSClient",
                "TestTokenEnvelope",
                "oau3021",
                "The provided token envelope is null."
            );
            return $false
        }

        if ([string]::IsNullOrWhiteSpace($Envelope.ticket))
        {
            TraceLogging::LogEvent(
                [LoggingLevel]::Error,
                "OTCSClient",
                "TestTokenEnvelope",
                "oau3022",
                "The provided token envelope has an empty or null ticket."
            );
            return $false
        }

        if ([string]::IsNullOrWhiteSpace($Envelope.observedAtUtc))
        {
            TraceLogging::LogEvent(
                [LoggingLevel]::Error,
                "OTCSClient",
                "TestTokenEnvelope",
                "oau3023",
                "The provided token envelope has an empty or null observedAtUtc."
            );
            return $false
        }

        try
        {
            $null = [DateTimeOffset]::new([string]$Envelope.observedAtUtc)
        }
        catch
        {
            TraceLogging::LogEvent(
                [LoggingLevel]::Error,
                "OTCSClient",
                "TestTokenEnvelope",
                "oau3024",
                "The provided token envelope has an invalid observedAtUtc."
            );
            return $false
        }

        return $true
    }


    [DateTimeOffset] GetEnvelopeObservedAtUtc(
        [object] $Envelope
    )
    {
        return [DateTimeOffset]::new([string] $Envelope.observedAtUtc).ToUniversalTime()
    }


    [hashtable] NewTokenEnvelope(
        [string] $Ticket,
        [DateTimeOffset] $ObservedAtUtc,
        [string] $Source
    )
    {
        if ([string]::IsNullOrWhiteSpace($Ticket))
        {
            throw "Cannot create an OTCS token envelope without a ticket."
        }

        return [ordered] @{
            ticket        = $Ticket
            observedAtUtc = $ObservedAtUtc.ToUniversalTime().ToString("O")
            generationId  = [guid]::NewGuid().ToString()
            source        = $Source
            updatedBy     = [System.Environment]::MachineName
        }
    }


    hidden [object] GetCachedTokenEnvelope()
    {
        try
        {
            $response = [ConfigurationManager]::GetSecret($this.KeyVaultSecretName);

            if ([string]::IsNullOrWhiteSpace($response))
            {
                return $null
            }

            try
            {
                $envelope = $response |
                    ConvertFrom-Json -Depth 20
            }
            catch
            {
                throw "The Key Vault OTCS ticket secret does not contain " +
                      "valid JSON. Exception='$($_.Exception.Message)'."
            }

            if (-not $this.TestTokenEnvelope($envelope))
            {
                throw "The Key Vault OTCS ticket secret contains an " +
                      "invalid token envelope."
            }

            return $envelope
        }
        catch
        {
            $statusCode = [Utility]::GetHttpStatusCode($_)

            if ($statusCode -eq 404)
            {
                return $null
            }

            [TraceLogging]::LogEvent(
                [LoggingLevel]::Error,
                "OTCSAuthManager",
                "TokenCache",
                "oau3020",
                "Could not read the cached OTCS ticket from Key Vault. " +
                "StatusCode='$statusCode'; " +
                "Exception='$($_.Exception.Message)'."
            )

            throw
        }
    }


    [void] SetCachedTokenEnvelope(
        [object] $Envelope
    )
    {
        if (-not $this.TestTokenEnvelope($Envelope))
        {
            throw "Cannot store an invalid OTCS token envelope."
        }

        $value = $(
                $Envelope |
                    ConvertTo-Json -Depth 20 -Compress
            )

        try
        {
            $lease = $this.BlobStorageManager.WaitForBlobLease();
            if ([string]::IsNullOrWhiteSpace($lease))
            {
                throw "Failed to acquire blob lease.";
            }
            try
            {
                [ConfigurationManager]::SetSecret($this.KeyVaultSecretName, $value);
            }
            finally
            {
                $this.BlobStorageManager.ReleaseBlobLease($lease);
            }
        }
        catch
        {
            [TraceLogging]::LogEvent(
                [LoggingLevel]::Error,
                "OTCSAuthManager",
                "TokenCache",
                "oau3021",
                "Could not store the OTCS ticket in Key Vault. " +
                "Exception='$($_.Exception.Message)'."
            )

            throw
        }
    }

    [void] ApplyTokenEnvelope(
        [object] $Envelope
    )
    {
        if (-not $this.TestTokenEnvelope($Envelope))
        {
            throw "Cannot apply an invalid OTCS token envelope."
        }

        if ($null -eq $this.m_authManager.Token)
        {
            $this.m_authManager.Token = [pscustomobject] @{
                ticket = [string] $Envelope.ticket
            }
        }
        else
        {
            $this.m_authManager.Token.ticket = [string]$Envelope.ticket
        }
    }

    [string]RefreshToken()
    {
        [TraceLogging]::LogEvent(
            [LoggingLevel]::Verbose,
            "OTCSAuthManager",
            "TokenCache",
            "oau3020",
            "Refreshing OTCS token."
        );
        $token = $this.m_authManager.GetAuthToken();

        [TraceLogging]::LogEvent(
            [LoggingLevel]::Verbose,
            "OTCSAuthManager",
            "TokenCache",
            "oau3020a",
            "Creating new token envelope."
        );
        $tokenEnvelope = $this.NewTokenEnvelope($token.ticket, [DateTime]::UtcNow, "OTCSClient");

        [TraceLogging]::LogEvent(
            [LoggingLevel]::Verbose,
            "OTCSAuthManager",
            "TokenCache",
            "oau3020b",
            "Storing new token envelope in cache."
        );

        $this.SetCachedTokenEnvelope($tokenEnvelope);

        [TraceLogging]::LogEvent(
            [LoggingLevel]::Verbose,
            "OTCSAuthManager",
            "TokenCache",
            "oau3020c",
            "New token envelope stored successfully."
        );
        return $token.ticket;
    }

    [void]SetToken(
        [string]$Token
    )
    {
        $tokenEnvelope = $this.NewTokenEnvelope($Token, [DateTime]::UtcNow, "OTCSClient");
        $this.SetCachedTokenEnvelope($tokenEnvelope);
    }

    [Object]GetToken()
    {
        [TraceLogging]::LogEvent(
            [LoggingLevel]::Verbose,
            "OTCSAuthManager",
            "TokenCache",
            "oau3021",
            "Retrieving cached token envelope."
        );

        $tokenEnvelope = $this.GetCachedTokenEnvelope();

        if ($null -eq $tokenEnvelope) {
            [TraceLogging]::LogEvent(
                [LoggingLevel]::Verbose,
                "OTCSAuthManager",
                "TokenCache",
                "oau3021a",
                "No cached token envelope found. Refreshing token."
            );
            $token = $this.RefreshToken();
            return $token;
        } else {
            if (-not $this.TestTokenEnvelope($tokenEnvelope)) {
                [TraceLogging]::LogEvent(
                    [LoggingLevel]::Verbose,
                    "OTCSAuthManager",
                    "TokenCache",
                    "oau3021b",
                    "Cached token envelope is invalid. Refreshing token."
                );
                $token = $this.RefreshToken();
                [TraceLogging]::LogEvent(
                    [LoggingLevel]::Verbose,
                    "OTCSAuthManager",
                    "TokenCache",
                    "oau3021c",
                    "Refreshed token successfully."
                );
                return $token;
            } else {
                return $tokenEnvelope.ticket;
            }
        }
    }

    [object]InvokeOTCSApiCall(
        [string]$Url,
        [string]$Method,
        [hashtable]$Headers,
        [object]$Body = $null
    ) {
        [TraceLogging]::LogEvent(
            [LoggingLevel]::Verbose,
            "OTCSClient",
            "InvokeOTCSApiCall",
            "oc0a0",
            "Invoking OTCS API call to URL: $Url with method: $Method"
        );

        [TraceLogging]::LogEvent(
            [LoggingLevel]::Verbose,
            "OTCSClient",
            "InvokeOTCSApiCall",
            "oc0a0a",
            "Retrieving authentication token for API call."
        );
        $token = $this.GetToken();

        if ($null -eq $Headers) {
            $Headers = @{};
        }

        $Headers["OTCSTicket"] = $token;
        $Headers["Content-Type"] = "application/json";

        $res = $null;

        $success = $false;
        $maxRetries = 3;
        $retryCount = 0;
        while (-not $success -and $retryCount -lt $maxRetries) {
            [TraceLogging]::LogEvent(
                [LoggingLevel]::Verbose,
                "OTCSClient",
                "InvokeOTCSApiCall",
                "oc0a0b",
                "Attempting API call. Retry count: $retryCount"
            );

            try {
                if ($Method -eq "GET" -or $null -eq $Body) {
                    $res = Invoke-WebRequest -Method $Method -Uri $Url -Headers $Headers -SkipHttpErrorCheck;
                }
                else {
                    $res = Invoke-WebRequest -Method $Method -Uri $Url -Headers $Headers -Body ($Body | ConvertTo-Json -Depth 10) -SkipHttpErrorCheck;
                }

                [TraceLogging]::LogEvent(
                    [LoggingLevel]::Verbose,
                    "OTCSClient",
                    "InvokeOTCSApiCall",
                    "oc0a0d",
                    "API call completed with status code: $($res.StatusCode)"
                );

                if ($res.StatusCode -eq 401) {
                    [TraceLogging]::LogEvent([LoggingLevel]::Warning, "OTCSClient", "InvokeOTCSApiCall", "oc0a1", "Received 401 Unauthorized response. Attempting to refresh authentication token and retry. Retry count: $($retryCount + 1)");
                    # Refresh token
                    $token = $this.RefreshToken();
                    $Headers["OTCSTicket"] = $token;
                    # Increment retry count and retry
                    $retryCount++;
                }
                else {
                    # For other status codes, consider the call successful (even if it's an error code like 400 or 500, we want to return that to the caller rather than retrying)
                    $success = $true;

                    if (![string]::IsNullOrWhiteSpace($res.Headers["OTCSTicket"])) {
                        $ticket = $res.Headers["OTCSTicket"].GetType().FullName -eq "System.String[]" ? $res.Headers["OTCSTicket"][0] : $res.Headers["OTCSTicket"];
                        if ([string]::IsNullOrWhiteSpace(($global:OTCSAuthManager.Token.ticket)) -or $($global:OTCSAuthManager.Token.ticket).ToString() -ne $ticket.ToString()) {
                            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "InvokeOTCSApiCall", "oc0a0c", "Updating authentication token with new OTCSTicket.");
                            $global:OTCSAuthManager.Token.ticket = $ticket;
                            $this.SetToken($ticket);
                        }
                    }
                }
            }
            catch {
                [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "InvokeOTCSApiCall", "oc0a2", "Exception occurred during API call: $_. Exception message: $($_.Message)");
                # For exceptions (e.g. network errors), we may want to retry
                if ($retryCount -lt $maxRetries) {
                    [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "InvokeOTCSApiCall", "oc0a3", "Retrying API call due to exception. Retry count: $($retryCount + 1)");
                    Start-Sleep -Seconds 2; # Wait before retrying
                    # Increment retry count and retry
                    $retryCount++;
                }
                else {
                    [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "InvokeOTCSApiCall", "oc0a4", "Max retries reached. Failing API call.");
                    throw "Max retries reached. Failing API call.";
                }
            }
        }
        
        return $res;
    }

    [void]SyncGroups() {
        if ($this.m_gc.Ready) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "SyncGroups", "oc0d1", "Starting synchronization of groups from OTCS instance.");
            $allGroupsUrl = "/api/v2/members?where_type=1";
            
            $groupsArray = @();
            $nextPageUrl = $allGroupsUrl;

            while (![string]::IsNullOrWhiteSpace($nextPageUrl)) {
                $nextPageUrl = $([ConfigurationManager]::OTCSInstance + $nextPageUrl);
                [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroups", "oc0d2", "Retrieving groups from OTCS. URL: $nextPageUrl");
                $res = $this.InvokeOTCSApiCall($nextPageUrl, "GET", $null, $null);
                if ($res.StatusCode -eq 200) {
                    $responseObject = $(ConvertFrom-Json $res.Content);
                    [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroups", "oc0d3", "Groups retrieved successfully from OTCS. Count: $($responseObject.results.data.properties.Count)");
                    $groupsArray += $responseObject.results.data.properties;
                    $nextPageUrl = $responseObject.collection.paging.links.data.next.href;
                }
                else {
                    [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "SyncGroups", "oc0d4", "Failed to retrieve groups from OTCS. HTTP status code: $($res.StatusCode). Response: $($res.Content)");
                    $nextPageUrl = $null;
                }
            }

            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroups", "oc0d6", "Total groups retrieved from OTCS: $($groupsArray.Count).");
            $groupsFromApi = [System.Collections.Generic.List[Group]]::new();
            $groupsQueue = [System.Collections.Generic.List[object]]::new();
            $queueSize = 10;
            $count = 0;

            foreach ($group in $groupsArray) {
                $groupsFromApi.Add([Group]::new($group.id.ToString(), $group.name.ToString(), $group.name_formatted.ToString()));

                if ($count -eq $queueSize) {
                    
                    $this.m_sb.SendMessage(
                        'groupsyncqueue',
                        $groupsQueue            
                    );
                    $groupsQueue = [System.Collections.Generic.List[object]]::new();

                    $count = 0;
                }
                $groupsQueue.Add(
                    @{
                        Action = "SyncMembership";
                        GroupId = $group.id.ToString();
                    }
                );
                $count++;
            }

            if ($groupsQueue.Count -gt 0) {
                $this.m_sb.SendMessage(
                    'groupsyncqueue',
                    $groupsQueue             
                );
            }

            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroups", "oc0d7", "Retrieving existing groups from local database.");
            $groupsFromDB = [System.Collections.Generic.List[Group]]::new();
            $dbGroups = $this.m_db.GetGroups();
            foreach ($g in $dbGroups) {
                $groupsFromDB.Add([Group]::new($g.GroupID, $g.Name, $g.Description));
            }

            $diff = Compare-Object -ReferenceObject $groupsFromApi -DifferenceObject $groupsFromDB -Property GroupID;
            $removals = $diff | Where-Object { $_.SideIndicator -eq "=>" };
            $additions = $diff | Where-Object { $_.SideIndicator -eq "<=" };

            # Remove groups that are no longer in the OTCS instance
            foreach ($group in $removals) {
                [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroups", "oc0d8", "Removing group: ID=$($group.GroupID), Name=$($group.Name)");
                $this.m_gc.DeleteGroup($group.GroupID);
            }
            # Add new groups from the OTCS instance
            foreach ($group in $additions) {
                $g = $groupsFromApi | Where-Object GroupID -eq $group.GroupID | Select-Object -First 1;;
                [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroups", "oc0d9", "Adding group: ID=$($g.GroupID), Name=$($g.Name)");
                $this.m_gc.CreateGroup($g.GroupID, $g.Name, $g.Description);
            }   
        }
        
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "SyncGroups", "oc0da", "Completed synchronization of groups from OTCS instance.");
    }

    [string]MapIdentity(
        [string]$Identity
    ) {
        $mappingConfig = [ConfigurationManager]::IdentityMappingConfiguration;
        if ($mappingConfig.MappingType -eq [IdentityMappingType]::MEID) {
            return $Identity;
        }
        elseif ($mappingConfig.MappingType -eq [IdentityMappingType]::Custom) {
            if ($Identity -match $mappingConfig.RegexMatchingPattern) {
                $mappedIdentity = $Identity -replace $mappingConfig.RegexMatchingPattern, $mappingConfig.ReplacementPattern;
                return $mappedIdentity;
            }
            else {
                return $Identity;
            }
        }
        else {
            return $Identity;
        }
    }

    [void]SyncGroupMembership(
        [string]$GroupID
    ) {
        if ($this.m_gc.Ready) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "SyncGroupMembership", "oc0m0", "Starting synchronization of group membership for group ID=$GroupID from OTCS instance.");
            $membersUrl = "/api/v2/members/$GroupID/members";
            
            $membersArray = @();
            $nextPageUrl = $membersUrl;

            while (![string]::IsNullOrWhiteSpace($nextPageUrl)) {
                $nextPageUrl = $([ConfigurationManager]::OTCSInstance + $nextPageUrl);
                [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroupMembership", "oc0m3", "Retrieving members from OTCS. URL: $nextPageUrl");
                $res = $this.InvokeOTCSApiCall($nextPageUrl, "GET", $null, $null);
                if ($res.StatusCode -eq 200) {
                    $responseObject = $(ConvertFrom-Json $res.Content);
                    [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroupMembership", "oc0m4", "Members retrieved successfully from OTCS. Count: $($responseObject.results.data.properties.Count)");
                    $membersArray += $responseObject.results.data.properties;

                    $nextPageUrl = $responseObject.collection.paging.links.data.next.href;
                }
                else {
                    [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "SyncGroupMembership", "oc0m7", "Failed to retrieve members for group ID=$GroupID. HTTP status code: $($res.StatusCode). Response: $($res.Content)");
                    $nextPageUrl = $null;
                }
            }

            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroupMembership", "oc0m8", "Total members retrieved for group ID=$($GroupID): $($membersArray.Count).");
            # Get existing members from local database 
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroupMembership", "oc0m9", "Retrieving existing members from local database for group ID=$($GroupID).");
            $em = $this.m_db.GetGroupMembers($GroupID);
            $existingMembers = [System.Collections.Generic.List[GroupMember]]::new();
            foreach ($m in $em) {
                $existingMembers.Add([GroupMember]::new($m.GroupId, $m.MemberId, $m.MemberType))
            }

            $membersRetrievedFromApi = [System.Collections.Generic.List[GroupMember]]::new();
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "SyncGroupMembership", "oc0m5", "Total members retrieved for group ID=$($GroupID): $($membersArray.Count). Updating local database and Graph Connector.");
            foreach ($member in $membersArray) {
                if ($null -ne $member) {
                    $membersRetrievedFromApi.Add(
                        [GroupMember]::new(
                            $GroupID,
                            $member.type_name -eq "Group" ? $member.id.ToString() : $this.MapIdentity([string]::IsNullOrWhiteSpace($member.business_email) ? $member.name.ToString() : $member.business_email.ToString()),
                            $member.type_name -eq "Group" ? "externalGroup" : "user"
                        )
                    );
                }
            }

            $diff = Compare-Object -ReferenceObject $membersRetrievedFromApi -DifferenceObject $existingMembers -Property MemberId, MemberType;
            $removals = $diff | Where-Object { $_.SideIndicator -eq "=>" };
            $additions = $diff | Where-Object { $_.SideIndicator -eq "<=" };

            # Remove members that are no longer in the OTCS group
            foreach ($member in $removals) {
                [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroupMembership", "oc0m10", "Removing member: ID=$($member.MemberId), Type=$($member.MemberType)");
                $this.m_gc.RemoveGroupMember($GroupID, $member.MemberId, $member.MemberType);
            }
            
            # Add new members to the OTCS group
            
            # for test - remove before moving to production
            $this.m_gc.AddGroupMember($GroupID, "adraskovic@adrit.de", "user");
            # end test

            foreach ($member in $additions) {
                [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroupMembership", "oc0m11", "Adding member: ID=$($member.MemberId), Type=$($member.MemberType)");
                $this.m_gc.AddGroupMember($GroupID, $member.MemberId, $member.MemberType);
            }
        }
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "SyncGroupMembership", "oc0m6", "Completed synchronization of group membership for group ID=$GroupID from OTCS instance.");
    }

    [void]SyncAllGroupMemberships() {
        if ($this.m_gc.Ready) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "SyncGroupMemberships", "oc0m1", "Starting synchronization of group memberships from OTCS instance.");
            $allGroups = $this.m_db.GetGroups();

            foreach ($group in $allGroups) {
                [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "SyncGroupMemberships", "oc0m2", "Retrieving members for group ID=$($group.GroupID), Name=$($group.DisplayName)");
                $this.SyncGroupMembership($group.GroupID);
            }
        }
    }

    [string]GetModifiedDateFacet()
    {
        $facetNames = @("Modified Date", "sys_ModifyDate", "modify_date", "modified_date", "modification_date", "date_modified", "date_last_modified");
        $facetUrl = $([ConfigurationManager]::OTCSInstance + "/api/v2/facets/2000"); # NodeID 2000 is refering to Enterprise Workspace in OTCS which has the modify_date facet
        $res = $this.InvokeOTCSApiCall($facetUrl, "GET", $null, $null);
        
        if ($res.StatusCode -eq 200) {
            try {
                $responseObject = $(ConvertFrom-Json $res.Content);
                $facets = $responseObject.results.data.facets | Get-Member | Where-Object MemberType -eq "NoteProperty" | Select-Object -ExpandProperty Name;

                $facetNamesInResponse = @();
                foreach ($facet in $facets) {
                    $facetObj = $responseObject.results.data.facets."$facet";

                    if ($facetNames -contains $facetObj.Name) {
                        $modifiedDateFacet = $facetObj.id;
                        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "GetModifiedDateFacet", "oc0g0", "Found Modified Date facet in OTCS response: $modifiedDateFacet");
                        return $modifiedDateFacet;
                    }
                    $facetNamesInResponse += $facetObj.Name;
                }
                [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "GetModifiedDateFacet", "oc0g1", "Failed to find Modified Date facet in OTCS response. Facets found: $($facetNamesInResponse -join ", "). Expected facet names: $($facetNames -join ", ").");
                return $null;
            }
            catch {
                [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "GetModifiedDateFacet", "oc0g2", "Failed to parse JSON response while retrieving modified date facet. Response content: $($res.Content)");
                return $null;
            }
        }
        else {
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "GetModifiedDateFacet", "oc0g3", "Failed to retrieve modified date facet from OTCS. Status code: $($res.StatusCode)");
            return $null;
        }
    }

    [void]EnumerateFolder(
        [int32]$NodeId
    ) {
        if ($this.m_gc.Ready) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "EnumerateFolder", "oc0e1", "Starting enumeration of items from the folder ID=$NodeId.");
            $allItemsUrl = $null;
            if ($NodeId -eq -1) {
                $allItemsUrl = "/api/v2/volumes/141/nodes?limit=100&where_type=0&where_type=144";
            }
            else {
                $allItemsUrl = "/api/v2/nodes/$NodeId/nodes?limit=100&where_type=0&where_type=144";
            }

            $nextPageUrl = $allItemsUrl;

            $exclusionList = [string]::IsNullOrWhiteSpace([ConfigurationManager]::FileExtensionExclusionList) ? @() : [ConfigurationManager]::FileExtensionExclusionList.Split(",", [System.StringSplitOptions]::TrimEntries);

            # $folderJobs = [System.Collections.Generic.List[object]]::new();

            while (![string]::IsNullOrWhiteSpace($nextPageUrl)) {
                [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "EnumerateFolder", "oc0e2", "Retrieving items from folder ID=$NodeId. URL: $nextPageUrl");
                $res = $this.InvokeOTCSApiCall($([ConfigurationManager]::OTCSInstance + $nextPageUrl), "GET", $null, $null);
                if ($res.StatusCode -eq 200) {
                    try {
                        $responseObject = $(ConvertFrom-Json $res.Content);
                    }
                    catch {
                        [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "EnumerateFolder", "oc0e5", "Failed to parse JSON response while enumerating folder ID=$NodeId. Response content: $($res.Content)");
                        break;
                    }
                    #$responseObject = $(ConvertFrom-Json $res.Content);
                    [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "EnumerateFolder", "oc0e3", "Items retrieved successfully from OTCS. Count: $($responseObject.results.data.properties.Count)");

                    # Process items here as needed
                    foreach ($item in $responseObject.results) {
                        $extension = [System.IO.Path]::GetExtension($item.data.properties.name).TrimStart(".");
                        if ($exclusionList -contains $extension) {
                            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "EnumerateFolder", "oc0e4a", "Skipping item ID=$($item.data.properties.id), Name=$($item.data.properties.name) due to file extension '$extension' being in the exclusion list.");
                            continue
                        }
                        # Example processing: Log item ID, name, a nd type
                        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "EnumerateFolder", "oc0e4b", "Processing item ID=$($item.data.properties.id), Name=$($item.data.properties.name), Type=$($item.data.properties.type_name)");
                        $url = "" # to be implemented: get item download URL

                        if (($item.data.properties.container -and $item.data.properties.container_size -gt 0) -or
                            (-not $item.data.properties.container)) {
                            
                            $this.m_db.AddQueueItem(
                                $item.data.properties.id,
                                $url,
                                $item.data.properties.modify_date,
                                $item.data.properties,
                                $item.data.permissions,
                                0, # SecurityClass will be retrieved in processing
                                $item.data.properties.container ? 0 : 1 # QueueItemType: 0 = Folder, 1 = Document
                            );
                            }

                        <#if ($item.data.properties.container) {
                            # add subfolders to the queue for enumeration
                            $folderJobs.Add(
                                    @{
                                        Action = "EnumerateFolder";
                                        NodeId = $item.data.properties.id;
                                    }
                                );
                        }#>
                    }

                    $nextPageUrl = $responseObject.collection.paging.links.data.next.href;
                } else {
                    [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "EnumerateFolder", "oc0e4", "Failed to retrieve items from OTCS for folder ID=$NodeId. HTTP status code: $($res.StatusCode). Response: $($res.Content)");
                    $nextPageUrl = $null;
                }
            }

            if ($NodeId -gt -1) {
                $this.m_db.MarkQueueItemProcessed($NodeId);
            }

            <#if ($folderJobs.Count -gt 0) {
                [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "EnumerateFolder", "oc0e4c", "Adding $($folderJobs.Count) folder enumeration jobs to the queue.");
                $this.m_sb.SendMessage(
                    'folderenumqueue',
                    $folderJobs              
                );
            }#>
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "EnumerateFolder", "oc0e4", "Completed enumeration of items from the folder ID=$NodeId.");
        }
    }

    [void]StartFolderEnumerationAsync() {
        $this.EnumerateFolder(-1);
    }

    [void]EnumerateAllFolders() {
        $this.EnumerateFolder(-1);

        $this.EnumerateFoldersWithoutRoot();
    }

    [void]EnumerateFoldersWithoutRoot() {
        $nextFolderId = $this.m_db.GetNextFolderToEnumerate($true);
        while ($nextFolderId -gt -1) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "EnumerateAllFolders", "oc0a8", "Enumerating folders in folder ID=$nextFolderId.");
            $this.EnumerateFolder($nextFolderId);
            $nextFolderId = $this.m_db.GetNextFolderToEnumerate($true);
        }
    }

    [void]EnumerateAllItems() {
        $this.EnumerateFolder(-1);

        $nextFolderId = $this.m_db.GetNextFolderToEnumerate($false);
        while ($nextFolderId -gt -1) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "EnumerateAllItems", "oc0a1", "Enumerating items in folder ID=$nextFolderId.");
            $this.EnumerateFolder($nextFolderId);
            $nextFolderId = $this.m_db.GetNextFolderToEnumerate($false);
        }
    }

    [void]EnumerateChangesForDay(
        [datetime]$date,
        [string]$facet = $null
    ) {
        if ([string]::IsNullOrWhiteSpace($facet)) {
            $facet = $this.GetModifiedDateFacet();
            if ($null -eq $facet) {
                [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "EnumerateChangesForDay", "oc1d1", "Cannot enumerate changes since last sync date because modified date facet could not be found.");
                return;
            }
        }
        $exclusionList = [string]::IsNullOrWhiteSpace([ConfigurationManager]::FileExtensionExclusionList) ? @() : [ConfigurationManager]::FileExtensionExclusionList.Split(",", [System.StringSplitOptions]::TrimEntries);
        $whitelist = [string]::IsNullOrWhiteSpace([ConfigurationManager]::FileWhitelist) ? @() : [ConfigurationManager]::FileWhitelist.Split(",", [System.StringSplitOptions]::TrimEntries);

        $nextPageUrl = "/api/v2/volumes/141/nodes?limit=100&where_facet=$($facet):dy$($date.ToUniversalTime().ToString("yyyyMMdd")))";

        while (![string]::IsNullOrWhiteSpace($nextPageUrl)) {
            [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "EnumerateChangesForDay", "oc1d2", "Retrieving modified items for $date. URL: $nextPageUrl");
            $res = $this.InvokeOTCSApiCall($([ConfigurationManager]::OTCSInstance + $nextPageUrl), "GET", $null, $null);
            if ($res.StatusCode -eq 200) {
                try {
                    $responseObject = $(ConvertFrom-Json $res.Content);
                }
                catch {
                    [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "EnumerateChangesForDay", "oc1d5", "Failed to parse JSON response while enumerating modified items for $date. Response content: $($res.Content)");
                    break;
                }
                #$responseObject = $(ConvertFrom-Json $res.Content);
                [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "EnumerateChangesForDay", "oc1d3", "Items retrieved successfully from OTCS. Count: $($responseObject.results.data.properties.Count)");

                # Process items here as needed
                foreach ($item in $responseObject.results) {
                    $extension = [System.IO.Path]::GetExtension($item.data.properties.name).TrimStart(".");
                    if ($whitelist.Count -gt 0 -and -not $whitelist.Contains($extension)) {
                        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "EnumerateChangesForDay", "oc1d4d", "Skipping item ID=$($item.data.properties.id), Name=$($item.data.properties.name) due to file extension '$extension' not being in the whitelist.");
                        continue
                    }

                    if ($exclusionList -contains $extension) {
                        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "EnumerateChangesForDay", "oc1d4a", "Skipping item ID=$($item.data.properties.id), Name=$($item.data.properties.name) due to file extension '$extension' being in the exclusion list.");
                        continue
                    }

                    # as facet search with date does not guarantee that all items returned will have modify_date greater than the specified date, we need to filter them here and skip those that are not modified since last sync date
                    #if ($item.data.properties.modify_date -lt $lastSyncDate.ToUniversalTime()) {
                    #    continue;
                    #}

                    if ($item.data.properties.container) {
                        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "EnumerateChangesForDay", "oc1d4c", "Item ID=$($item.data.properties.id), Name=$($item.data.properties.name) is a folder. Skipping.");
                        continue;
                    }
                    # Example processing: Log item ID, name, a nd type
                    [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "EnumerateChangesForDay", "oc1d4b", "Processing item ID=$($item.data.properties.id), Name=$($item.data.properties.name), Type=$($item.data.properties.type_name)");
                    $url = "" # to be implemented: get item download URL
                    $this.m_db.AddQueueItem(
                        $item.data.properties.id,
                        $url,
                        $item.data.properties.modify_date,
                        $item.data.properties,
                        $item.data.permissions,
                        0, # SecurityClass will be retrieved in processing
                        $item.data.properties.container ? 0 : 1 # QueueItemType: 0 = Document, 1 = Folder
                    );
                }

                $nextPageUrl = $responseObject.collection.paging.links.data.next.href;
            }
        }

        [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "EnumerateChangesForDay", "oc1d42", "Completed enumeration of changes for $date.");
    }

    [void]EnumerateChangesSince(
        [datetime]$lastSyncDate
    ) {
        if ($this.m_gc.Ready) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "EnumerateChangesSince", "oc1e1", "Starting enumeration of changes since $lastSyncDate.");
            
            $facet = $this.GetModifiedDateFacet();
            if ($null -eq $facet) {
                [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "EnumerateChangesSince", "oc1c1", "Cannot enumerate changes since last sync date because modified date facet could not be found.");
                return;
            }

            $evalDate = $([DateTime]$($lastSyncDate.ToUniversalTime().ToString("yyyy-MM-ddT00:00:00Z"))).ToUniversalTime();
            
            while ($evalDate -lt (Get-Date).ToUniversalTime()) {
                $this.EnumerateChangesForDay($evalDate, $facet);
                $evalDate = $evalDate.AddDays(1);
            }

            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "EnumerateChangesSince", "oc1e4", "Completed enumeration of changes since $lastSyncDate.");
        }
    }

    [System.Collections.Generic.List[Acl]] GetItemAcls(
        [object]$Node
    ) {
        $acls = [System.Collections.Generic.List[Acl]]::new();
        $nodePermissions = ConvertFrom-Json $Node.Permissions;
        foreach ($permission in $nodePermissions) {
            $allowed = $false;
            foreach ($p in $permission.permissions) {
                if ($p -eq "see" -or $p -eq "see_contents") {
                    $allowed = $true;
                    break;
                }
            }

            if ($allowed) {
                if ($permission.type -eq "public") {
                    $acls.Add([Acl]::new("everyone", "everyone", "grant"));
                }
                else {
                    $group = $this.m_db.GetGroup($permission.right_id);
                    if ($null -ne $group) {
                        $acls.Add([Acl]::new("externalGroup", $permission.right_id.ToString(),"grant"));
                    }
                    else {
                        $memberUrl = $([ConfigurationManager]::OTCSInstance + "/api/v2/members/$($permission.right_id)");
                        $res = $this.InvokeOTCSApiCall($memberUrl, "GET", $null, $null);

                        if ($res.StatusCode -eq 200) {
                            try {
                                $memberObject = $(ConvertFrom-Json $res.Content);
                                if ($memberObject.type -eq 0) {
                                    # user
                                    [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "GetItemAcls", "oc0e6", "Mapping user ID=$($memberObject.id) with email=$($memberObject.business_email) to identity.");
                                    $mappedIdentity = $this.MapIdentity($memberObject.business_email.ToString());
                                    $userObject = $this.m_gc.GetUserByEmail($mappedIdentity);
                                    $MemberUniqueId = $null;
                                    if ($null -ne $userObject) {
                                        $MemberUniqueId = $userObject.id;
                                    }
                                    else {
                                        $errorMsg = "User with email / UPN '$mappedIdentity' not found.";
                                        [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "GetItemAcls", "oc0e7", $errorMsg);
                                    }
                                    if ($null -ne $MemberUniqueId) {
                                        [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "GetItemAcls", "oc0e8", "Adding ACL for user ID=$MemberUniqueId mapped from OTCS user ID=$($memberObject.id).");
                                        $acls.Add([Acl]::new("user", $mappedIdentity, "grant"));
                                    }                          
                                    continue;
                                }
                                elseif ($memberObject.type -eq 1) {
                                    # group was not found, sync it and add members
                                    [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "GetItemAcls", "oc0e9", "Group ID=$($memberObject.id) not found in local database. Creating group in Graph Connector.");
                                    $this.m_gc.CreateGroup($memberObject.id, $memberObject.name.ToString(), $group.name_formatted.ToString());
                                    [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "GetItemAcls", "oc0ea", "Synchronizing membership for group ID=$($memberObject.id).");
                                    $this.SyncGroupMembership($memberObject.id);
                                    [TraceLogging]::LogEvent([LoggingLevel]::Verbose, "OTCSClient", "GetItemAcls", "oc0eb", "Adding ACL for group ID=$($memberObject.id).");
                                    $acls.Add([Acl]::new("externalGroup", $permission.right_id.ToString(), "grant"));
                                    continue;
                                }
                            }
                            catch {
                                [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "GetItemAcls", "oc0ef", "Failed to parse JSON response while retrieving member information for $($permission.right_id). Response content: $($res.Content)");
                                break;
                            }
                        }
                    }
                }
            }
        }
        return $acls;
    }

    [string]GetFileTextContent(
        [int32]$NodeId
    ) {
        $fileContentUrl = $([ConfigurationManager]::OTCSInstance + "/api/v2/nodes/$NodeId/view/html");
        $res = $this.InvokeOTCSApiCall($fileContentUrl, "GET", $null, $null);
        if ($res.StatusCode -eq 200) {
            return [Utility]::ConvertHTMLToText($res.Content);
        }
        else {
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "GetFileTextContent", "oc0f1", "Failed to retrieve content for file NodeID=$NodeId. HTTP status code: $($res.StatusCode). Response: $($res.Content)");
            return "";
        }
    }

    [void]ProcessQueueItems(
        [int32]$MaxItemsToProcess = 10
    ) {
        if ($this.m_gc.Ready) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "ProcessQueueItems", "oc0q0", "Starting processing of up to $MaxItemsToProcess queue items.");
            $items = $this.m_db.GetQueueItemsToProcess($MaxItemsToProcess);
            foreach ($item in $items) {
                [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "ProcessQueueItems", "oc0q1", "Processing queue item ID=$($item.QueueItemID), NodeID=$($item.NodeId).");
                # To be implemented: Process the queue item (e.g., download document, update metadata, etc.)

                $acls = $this.GetItemAcls($item);
                $content = $this.GetFileTextContent($item.NodeId);

                $properties = ConvertFrom-Json $item.Properties;
                $res = $this.m_gc.IndexItem(
                    $item.NodeId.ToString(),
                    $properties.name,
                    $([ConfigurationManager]::OTCSInstance + "?func=ll&objId=$($item.NodeId.ToString())&objAction=viewheader"),
                    $content,
                    "text", # to be implemented: get actual content type
                    $acls
                );

                # Mark the item as processed
                $this.m_db.MarkQueueItemProcessed($item.NodeId);
            }
        }
    }

    [void]QueueItemsForProcessing()
    {
        $queueSize = [string]::IsNullOrWhiteSpace([ConfigurationManager]::ItemProcessingBatchSize) ? 100 : [ConfigurationManager]::ItemProcessingBatchSize;
        if ($this.m_gc.Ready) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "QueueItemsForProcessing", "oc0q0", "Starting queuing items for processing.");

            $count = 0;

            do {
                $items = $this.m_db.GetQueueItemsToProcess($queueSize);
                if ($null -ne $items -and $items.Count -gt 0) {
                    $this.m_sb.SendMessage("indexqueue", $($items | Select-Object -Property NodeId, LastModified));
                    # Mark item as added to Service Bus Queue for processing.
                    $this.m_db.SetQueueItemStatus(($items | Select-Object -ExpandProperty NodeId) -join ',', "Queued");                
                    $count += $items.Count;
                }
            } while ($items.Count -eq $queueSize);
                [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "QueueItemsForProcessing", "oc0q1", "Completed queuing items for processing. Total items queued: $count.");
            }
    }

    [void]QueueFoldersForProcessing()
    {
        $queueSize = [string]::IsNullOrWhiteSpace([ConfigurationManager]::ItemProcessingBatchSize) ? 100 : [ConfigurationManager]::ItemProcessingBatchSize;
        if ($this.m_gc.Ready) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "QueueFoldersForProcessing", "oc0x0", "Starting queuing folders for processing.");

            $count = 0;

            do {
                $items = $this.m_db.GetQueueFoldersToProcess($queueSize);
                if ($null -ne $items -and $items.Count -gt 0) {
                    $this.m_sb.SendMessage("folderenumqueue", $($items | Select-Object -Property NodeId, @{ Name = 'Action'; Expression = { 'EnumerateFolder' } }));
                    # Mark item as added to Service Bus Queue for processing.
                    $this.m_db.SetQueueItemStatus($($items | Select-Object -ExpandProperty NodeId) -join ',', "Queued");
                    $count += $items.Count;
                }
            } while ($items.Count -eq $queueSize);
                [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "QueueFoldersForProcessing", "oc0x1", "Completed queuing folders for processing. Total folders queued: $count.");
            }
    }

    [object]GetQueuedItem(
        [int32]$NodeId
    ) {
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "GetQueuedItem", "oc0q0", "Retrieving queue item for NodeID=$NodeId.");
        return $this.m_db.GetQueueItem($NodeId);
    }

    [void]ProcessItem(
        [object]$item
    )
    {
        if ($this.m_gc.Ready) {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "ProcessQueueItems", "oc0q1", "Processing queue item ID=$($item.QueueItemID), NodeID=$($item.NodeId).");
            # To be implemented: Process the queue item (e.g., download document, update metadata, etc.)

            $acls = $this.GetItemAcls($item);
            $content = $this.GetFileTextContent($item.NodeId);

            $properties = ConvertFrom-Json $item.Properties;
            $res = $this.m_gc.IndexItem(
                $item.NodeId.ToString(),
                $properties.name,
                $([ConfigurationManager]::OTCSInstance + "?func=ll&objId=$($item.NodeId.ToString())&objAction=viewheader"),
                $content,
                "text", # to be implemented: get actual content type
                $acls
            );

            # Mark the item as processed, only if it is properly indexed. Otherwise, it will stay in the queue for retrying later
            if ($res.Success)
            {
                [TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSClient", "ProcessQueueItems", "oc0q2", "Successfully indexed item ID=$($item.NodeId). Marking as processed.");
                $this.m_db.MarkQueueItemProcessed($item.NodeId);
            } else {
                [TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSClient", "ProcessItem", "oc0q3", "Failed to index item ID=$($item.NodeId). It will remain in the queue for retrying later.");
            }
        }
    }
}