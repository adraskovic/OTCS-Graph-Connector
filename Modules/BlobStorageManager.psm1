using module .\AuthManagerHelper.psm1
using module .\AuthManager.psm1
using module .\ConfigurationManager.psm1
using module .\Logging.psm1
using module .\Utility.psd1
using module .\Utility.psm1

class BlobStorageManager
{
    [string] $LockBlobUri = [string]::Empty
    [string] $StorageApiVersion = "2023-11-03"

    [int] $HttpTimeoutSeconds = 30
    [int] $LeaseDurationSeconds = 60
    [int] $MaximumAuthenticationAttempts = 3
    [int] $MaximumLeaseWaitAttempts = 20
    [AuthManager] $AuthManager = $null

    BlobStorageManager()
    {
        $this.LockBlobUri = [Uri]::new([Uri]::new($([ConfigurationManager]::BlobStorageUri)), "/locks/otcs-auth-ticket.lock");
        $this.AuthManager = [AuthManagerHelper]::CreateMSIInstance("https://storage.azure.com/");
    }

    [hashtable] GetStorageHeaders()
    {
        $headers = @{
            "Authorization" = "Bearer $($this.AuthManager.GetAuthToken().access_token)"
            "x-ms-version" = $this.StorageApiVersion
            "x-ms-date" = [DateTime]::UtcNow.ToString("R")
            "x-ms-client-request-id" = [guid]::NewGuid().ToString()
        }

        return $headers
    }

    [void] EnsureLockBlobExists()
    {
        $headers = $this.GetStorageHeaders()
        $headers["x-ms-blob-type"] = "BlockBlob"
        $headers["Content-Length"] = "0"

        try
        {
            Invoke-WebRequest `
                -Method Put `
                -Uri $this.LockBlobUri `
                -Headers $headers `
                -Body ([byte[]] @()) `
                -ContentType "application/octet-stream" `
                -TimeoutSec 15 -SkipHttpErrorCheck | Out-Null
        }
        catch
        {
            $statusCode = [Utility]::GetHttpStatusCode($_)

            # 409 means the blob, snapshot or lease already exists.
            # For this initialisation operation, the blob already existing
            # is the expected concurrent case.
            if ($statusCode -eq 409)
            {
                return
            }

            [TraceLogging]::LogEvent(
                [LoggingLevel]::Error,
                "OTCSAuthManager",
                "BlobLease",
                "oau3030",
                "Could not create or verify the OTCS lock blob. " +
                "StatusCode='$statusCode'; " +
                "Exception='$($_.Exception.Message)'."
            )

            throw
        }
    }


    [string] AcquireBlobLease()
    {
        $this.EnsureLockBlobExists()

        $proposedLeaseId = [guid]::NewGuid().ToString()
        $headers = $this.GetStorageHeaders()

        $headers["x-ms-lease-action"] = "acquire"
        $headers["x-ms-lease-duration"] = $this.LeaseDurationSeconds.ToString()
        $headers["x-ms-proposed-lease-id"] = $proposedLeaseId

        $separator = [Utility]::GetQuerySeparator($this.LockBlobUri)
        $uri = "{0}{1}comp=lease" -f $this.LockBlobUri, $separator

        try
        {
            $response = Invoke-WebRequest `
                -Method Put `
                -Uri $uri `
                -Headers $headers `
                -TimeoutSec 15 -ErrorAction Continue

            $leaseId = [Utility]::GetResponseHeader(
                $response,
                "x-ms-lease-id"
            )

            if ([string]::IsNullOrEmpty($leaseId))
            {
                throw "Blob lease acquisition succeeded but Azure Storage " +
                      "returned no x-ms-lease-id header."
            }

            return $leaseId
        }
        catch
        {
            $statusCode = [Utility]::GetHttpStatusCode($_)

            if ($statusCode -eq 409 -or $statusCode -eq 412)
            {
                return $null
            }

            [TraceLogging]::LogEvent(
                [LoggingLevel]::Error,
                "OTCSAuthManager",
                "BlobLease",
                "oau3031",
                "Could not acquire the OTCS token lease. " +
                "StatusCode='$statusCode'; " +
                "Exception='$($_.Exception.Message)'."
            )

            throw
        }
    }


    [bool] RenewBlobLease(
        [string] $LeaseId
    )
    {
        if ([string]::IsNullOrWhiteSpace($LeaseId))
        {
            throw "LeaseId must not be empty."
        }

        $headers = $this.GetStorageHeaders()
        $headers["x-ms-lease-action"] = "renew"
        $headers["x-ms-lease-id"] = $LeaseId

        $separator = [Utility]::GetQuerySeparator($this.LockBlobUri)
        $uri = "{0}{1}comp=lease" -f $this.LockBlobUri, $separator

        try
        {
            Invoke-WebRequest `
                -Method Put `
                -Uri $uri `
                -Headers $headers `
                -TimeoutSec 15 | Out-Null

            return $true
        }
        catch
        {
            $statusCode = [Utility]::GetHttpStatusCode($_)

            [TraceLogging]::LogEvent(
                [LoggingLevel]::Error,
                "OTCSAuthManager",
                "BlobLease",
                "oau3032",
                "Could not renew the OTCS token lease. " +
                "LeaseId='$LeaseId'; " +
                "StatusCode='$statusCode'; " +
                "Exception='$($_.Exception.Message)'."
            )

            return $false
        }
    }


    [void] ReleaseBlobLease(
        [string] $LeaseId
    )
    {
        if ([string]::IsNullOrWhiteSpace($LeaseId))
        {
            return
        }

        $headers = $this.GetStorageHeaders()
        $headers["x-ms-lease-action"] = "release"
        $headers["x-ms-lease-id"] = $LeaseId

        $separator = [Utility]::GetQuerySeparator($this.LockBlobUri)
        $uri = "{0}{1}comp=lease" -f $this.LockBlobUri, $separator

        try
        {
            Invoke-WebRequest `
                -Method Put `
                -Uri $uri `
                -Headers $headers `
                -TimeoutSec 15 | Out-Null
        }
        catch
        {
            $statusCode = [Utility]::GetHttpStatusCode($_)

            [TraceLogging]::LogEvent(
                [LoggingLevel]::Error,
                "OTCSAuthManager",
                "BlobLease",
                "oau3033",
                "Could not release the OTCS token lease. " +
                "LeaseId='$LeaseId'; " +
                "StatusCode='$statusCode'; " +
                "Exception='$($_.Exception.Message)'."
            )

            # A finite lease will expire automatically. Do not replace the
            # actual operation result with a lease-release exception.
        }
    }


    [string] WaitForBlobLease()
    {
        for (
            $attempt = 1;
            $attempt -le $this.MaximumLeaseWaitAttempts;
            $attempt++
        )
        {
            $leaseId = $this.AcquireBlobLease()

            if (-not [string]::IsNullOrWhiteSpace($leaseId))
            {
                return $leaseId
            }

            $delayMilliseconds =
                Get-Random -Minimum 1000 -Maximum 2000

            [TraceLogging]::LogEvent(
                [LoggingLevel]::Warning,
                "OTCSAuthManager",
                "BlobLease",
                "oau3034",
                "Another host owns the OTCS token lease. " +
                "Attempt='$attempt'; " +
                "DelayMilliseconds='$delayMilliseconds'."
            )

            Start-Sleep -Milliseconds $delayMilliseconds
        }

        throw "The OTCS token lease could not be acquired after " +
              "$($this.MaximumLeaseWaitAttempts) attempts."
    }
}