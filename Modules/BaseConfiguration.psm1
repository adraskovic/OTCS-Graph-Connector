using module .\AuthManager.psm1;
using module .\KeyVaultManager.psm1;
using module .\Utility.psd1;
using module .\Utility.psm1;

<# 
    ConfigurationManager is split into BaseConfiguration and ConfigurationManager
    to avoid circular dependency caused by DB module.
#>

class BaseConfiguration
{
    static [string]$ClientId = $env:ClientID;
    static [string]$ClientSecret = $env:ClientSecret;
    static [string]$TenantDomain = $env:TenantDomain;
    static [string]$KeyVaultURI = $env:KeyVaultURI;
    static [string]$ConnectionString = [BaseConfiguration]::GetConnectionString();
    static [boolean]$SkipDatabaseCreation = [Utility]::ParseBooleanValue($env:SkipDatabaseCreation);
    static [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate = ![string]::IsNullOrWhitespace($env:CertificateName) -and ![string]::IsNullOrWhitespace($env:KeyVaultURI) ? 
                                  [BaseConfiguration]::GetCertificate($env:CertificateName) : $null;

    static [string]GetConnectionString()
    {
        $value = [string]::Empty;
        if (![string]::IsNullOrWhiteSpace($global:ConnectionStringValue))
        {
            $value = $global:ConnectionStringValue;
        } elseif (![string]::IsNullOrWhiteSpace($env:SQLAZURECONNSTR_DBConnectionString))
        {
            $value = $env:SQLAZURECONNSTR_DBConnectionString;
        } else {
            $value = [BaseConfiguration]::GetSecret("ConnectionString");
        }

        $global:ConnectionStringValue = $value;
        return $value;
    }

    static [string]GetSecret(
        [string]$Name
    )
    {
        $value = $null;

        $authManager = [AuthManager]::new(
            [BaseConfiguration]::ClientId,
            [BaseConfiguration]::ClientSecret,
            [BaseConfiguration]::TenantDomain,
            "https://vault.azure.net"
        );

        $keyVaultManager = [KeyVaultManager]::new([BaseConfiguration]::KeyVaultURI, $authManager);
        $secret = $keyVaultManager.GetSecret($Name);
        if ($null -ne $secret)
        {
            $value = $secret.value;
        } 
        
        return $value;
    }
    
    static [void]SetSecret(
        [string]$Name,
        [string]$Value
    )
    {
        $authManager = [AuthManager]::new(
            [BaseConfiguration]::ClientId,
            [BaseConfiguration]::ClientSecret,
            [BaseConfiguration]::TenantDomain,
            "https://vault.azure.net"
        );

        $keyVaultManager = [KeyVaultManager]::new([BaseConfiguration]::KeyVaultURI, $authManager);
        $keyVaultManager.SetSecret($Name, $Value);
    }

    static [System.Security.Cryptography.X509Certificates.X509Certificate2]GetCertificate(
        [string]$CertificateName
    )
    {
        # System Assigned Managed Identity is used to access Key Vault       
        $authManager = [AuthManager]::new(
            "https://vault.azure.net"
        );

        $keyVaultManager = [KeyVaultManager]::new([BaseConfiguration]::KeyVaultURI, $authManager);
        return $keyVaultManager.GetCertificateWithPrivateKey($CertificateName);
    }
}