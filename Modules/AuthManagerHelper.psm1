using module .\ConfigurationManager.psm1
using module .\AuthManager.psm1

# this is to prevent module nesting in ConfigurationManager class.
class AuthManagerHelper
{
    static [AuthManager]CreateInstance(
        [string]$Resource
    )
    {
        if ($null -eq [ConfigurationManager]::Certificate)
        {
            return [AuthManager]::new(
                [ConfigurationManager]::ClientId,
                [ConfigurationManager]::ClientSecret,
                [ConfigurationManager]::TenantDomain,
                $Resource
            );
        } else {
            return [AuthManager]::new(
                [ConfigurationManager]::ClientId,
                [ConfigurationManager]::Certificate,
                [ConfigurationManager]::TenantDomain,
                $Resource
            );
        }
    }

    static [AuthManager]CreateMSIInstance(
        [string]$Resource
    )
    {
        return [AuthManager]::new($Resource);
    }
}