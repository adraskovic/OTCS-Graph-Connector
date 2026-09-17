using module .\Logging.psm1
using module .\AuthManager.psm1

class KeyVaultManager 
{
    hidden [string] $KeyVaultURI = [string]::Empty;
    hidden [AuthManager] $AuthManager = $null;

    KeyVaultManager(
        [string]$KeyVaultURI,
        [AuthManager]$AuthManager
    )
    {
        if ([string]::IsNullOrWhiteSpace($KeyVaultURI))
        {
            $errorMessage = "Key Vault configuration is not found. Please specify KeyVaultURI parameter and try again.";
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Initialization", "kvm109", $errorMessage);
            throw $errorMessage;
        } else {
            $this.KeyVaultURI = $KeyVaultURI.TrimEnd("/");
        }

        $this.AuthManager = $AuthManager;
    }

    [System.Object]GetSecret(
        [string]$SecretName
    )
    {
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm270", "Entering method KeyVaultManager.GetSecret()");
        
        $uri = [string]::Format("{0}/secrets/{1}?api-version=7.1", $this.KeyVaultURI, $SecretName);
        $Headers = @{
            Authorization = [string]::Format("{0} {1}",
                $this.AuthManager.Token.token_type,
                $this.AuthManager.Token.access_token);
        }

        $res = $null;
        try {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm273", "Retrieving secret '$($SecretName)' from $($this.KeyVaultURI)");
            $res = Invoke-RestMethod -Uri $uri -Method GET -Headers $Headers -TimeoutSec 30
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm274", "Successfully retrieved secret '$($SecretName)' from $($this.KeyVaultURI)");
        }
        catch {
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "KeyVaultManager", "Secret", "kvm275", "Could not retrieve secret from Key Vault. Error: $($_.ErrorDetails.Message). Exception: $($_.Exception). Stack trace: $($_.ScriptStackTrace)"); 
        }
        
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm27f", "Exiting method KeyVaultManager.GetSecret()");
        return $res;
    }

    [System.Object]SetSecret(
        [string]$SecretName,
        [string]$SecretValue
    )
    {
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm277", "Entering method KeyVaultManager.SetSecret()");
        
        $uri = [string]::Format("{0}/secrets/{1}?api-version=7.4", $this.KeyVaultURI, $SecretName);
        $Headers = @{
            Authorization = [string]::Format("{0} {1}",
                $this.AuthManager.Token.token_type,
                $this.AuthManager.Token.access_token);
            "Content-Type" = "application/json";
        }

        $body = @{
            value = $SecretValue;
            attributes = @{
                enabled = $true;
            }
        } | ConvertTo-Json;

        $res = $null;
        try {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm278", "Setting secret '$($SecretName)' in $($this.KeyVaultURI)");
            $res = Invoke-RestMethod -Uri $uri -Method PUT -Body $body -Headers $Headers -ContentType "application/json" -TimeoutSec 30
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm279", "Successfully set secret '$($SecretName)' from $($this.KeyVaultURI)");
        }
        catch {
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "KeyVaultManager", "Secret", "kvm27a", "Could not set secret. Error: $($_.ErrorDetails.Message). Exception: $($_.Exception). Stack trace: $($_.ScriptStackTrace)"); 
        }
        
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm27b", "Exiting method KeyVaultManager.SetSecret()");
        return $res;
    }

    [System.Object]GetCertificate(
        [string]$CertificateName
    )
    {
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm280", "Entering method KeyVaultManager.GetCertificate()");
        
        $uri = [string]::Format("{0}/certificates/{1}?api-version=7.4", $this.KeyVaultURI, $CertificateName);
        $Headers = @{
            Authorization = [string]::Format("{0} {1}",
                $this.AuthManager.Token.token_type,
                $this.AuthManager.Token.access_token);
        }

        $res = $null;
        try {
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm283", "Retrieving certificate '$($CertificateName)' from $($this.KeyVaultURI)");
            $res = Invoke-RestMethod -Uri $uri -Method GET -Headers $Headers -TimeoutSec 30
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm284", "Successfully retrieved secret '$($CertificateName)' from $($this.KeyVaultURI)");
        }
        catch {
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "KeyVaultManager", "Secret", "kvm285", "Could not retrieve secret from Key Vault. Error: $($_.ErrorDetails.Message). Exception: $($_.Exception). Stack trace: $($_.ScriptStackTrace)"); 
        }
        
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm28f", "Exiting method KeyVaultManager.GetCertificate()");
        return $res;
    }

    [System.Security.Cryptography.X509Certificates.X509Certificate2]GetCertificateWithPrivateKey(
        [string]$CertificateName
    )
    {
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm280", "Entering method KeyVaultManager.GetCertificateWithPrivateKey()");
        $cert = $this.GetCertificate($CertificateName);
        if ($null -eq $cert)
        {
            [TraceLogging]::LogEvent([LoggingLevel]::Error, "KeyVaultManager", "Secret", "kvm280",
                "Failed to retrieve certificate '$($CertificateName)' from Key Vault. Exiting.");
            return $null;
        } else {
            $Headers = @{
                Authorization = [string]::Format("{0} {1}",
                    $this.AuthManager.Token.token_type,
                    $this.AuthManager.Token.access_token);
            }

            [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm281",
                "Successfully retrieved certificate '$($CertificateName)' from Key Vault. Retrieving certificate with private key.");
            $certResponse = Invoke-RestMethod -Method Get -Uri $($cert.sid + "?api-version=7.4") -Headers $Headers -TimeoutSec 30
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "KeyVaultManager", "Secret", "kvm282",
                "Successfully retrieved certificate with private key '$($CertificateName)' from Key Vault.");

            # Convert the certificate to X509Certificate2 type
            $certBase64 = $certResponse.value
            $certBytes = [System.Convert]::FromBase64String($certBase64)
            return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
        }
    }
}