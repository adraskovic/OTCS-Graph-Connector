<#
.SYNOPSIS
Manages OTCS authentication tickets across Azure Functions workers.

.DESCRIPTION
OTCSAuthManager owns the complete OTCS ticket lifecycle:

- Retrieves Azure access tokens through the Function App's system-assigned
  managed identity.
- Reads and writes the shared OTCS ticket through Azure Key Vault REST APIs.
- Coordinates token updates through an Azure Blob lease.
- Loads cached tickets before issuing OTCS API requests.
- Stores rolling OTCSTicket response headers.
- Performs single-flight OTCS authentication after HTTP 401 responses.
- Prevents an older API response from overwriting a newer cached ticket.

The constructor performs no network operations. Authentication is lazy and
occurs only when GetUsableTicket() cannot find a cached ticket.

.AUTHOR
Aleksandar Draskovic, Microsoft Deutschland GmbH

.DATE
2026-09-01

.VERSION
2.0.2609.0
#>

using module .\Utility.psd1
using module .\Utility.psm1
using module .\Logging.psm1
using module .\ConfigurationManager.psm1

class OTCSAuthManager
{
	hidden [string]$OTCSInstance = [string]::Empty;
	hidden [string]$ClientSecret = [string]::Empty;
	hidden [string]$Username = [string]::Empty;
	hidden [string]$Password = [string]::Empty;
	hidden [string]$Resource = [string]::Empty;
	[System.Object]$Token = $null;

	OTCSAuthManager(
		[string]$OTCSInstance,
		[string]$Username,
		[string]$Password
	)
	{
		$this.OTCSInstance = $OTCSInstance;
		$this.Username = $Username;
		$this.Password = $Password;
		$this.Token = $this.RetrieveAuthToken();
	}

	# $authResponse = Invoke-RestMethod -Uri $authUrl -Method POST -Body $authBody -ContentType 'application/x-www-form-urlencoded -TimeoutSec 30
	
	OTCSAuthManager()
	{
		$this.OTCSInstance = [ConfigurationManager]::OTCSInstance;
		$this.Username = [ConfigurationManager]::OTCSUsername;
		$this.Password = [ConfigurationManager]::OTCSPassword;
		$this.Token = $this.RetrieveAuthToken();
	}

	[System.Object]GetAuthToken()
	{
		$this.Token = $this.RetrieveAuthToken();
		return $this.Token
	}

	[void]RefreshToken()
	{
		$this.Token = $this.RetrieveAuthToken();
	}

	hidden [System.Object]GetTokenRequestBody()
	{
		$body = "username=$($this.Username);password=$($this.Password)";
		return $body;
	}

	hidden [System.String]GetTokenRequestUri()
	{
		$uri = $this.OTCSInstance + "/api/v1/auth";
		return $uri;
	}

	hidden [System.Object]GetTokenRequestHeaders()
	{
		$headers = @{ContentType="application/x-www-form-urlencoded"}
		return $headers;
	}
	
	hidden [System.Object]RetrieveAuthToken()
	{
		$maxRetries = 10;
		$success = $false;
		$retry = 0;
		$result = $null;

		while ($success -eq $false -and $retry -lt $maxRetries)
		{
			[TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSAuthManager", "AuthToken", "oau2910", "Retrieving auth. token. Attempt #$($retry+1) of $maxRetries");
			try {
				$uri = $this.GetTokenRequestUri();
				$headers = $this.GetTokenRequestHeaders();			 
				$body = $this.GetTokenRequestBody();
				$response = Invoke-WebRequest -Method POST -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded' -SkipHttpErrorCheck -TimeoutSec 30;

				if ($response.StatusCode -eq 200)
				{
					$result = $response.Content | ConvertFrom-Json
				} else {
					throw "Failed to retrieve auth. token. Status code: $($response.StatusCode). Response: $($response.Content)";
				}
				[TraceLogging]::LogEvent([LoggingLevel]::Information, "OTCSAuthManager", "AuthToken", "oau2912b", "Auth. token retrieved successfully.");
				$success = $true;
			}
			catch {
				[TraceLogging]::LogEvent([LoggingLevel]::Error, "OTCSAuthManager", "AuthToken", "oau2913", "Failed to retrieve auth. token. Error: $_");
				$retry++;	
			}
		}

		return $result;
	}
}
