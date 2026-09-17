using module .\KeyVaultManager.psm1
using module .\ConfigurationManager.psm1
using module .\AuthManagerHelper.psm1


# this is to prevent module nesting in ConfigurationManager class.
class KeyVaultManagerHelper
{
    static [KeyVaultManager]CreateInstance()
    {
        return [KeyVaultManager]::new([ConfigurationManager]::KeyVaultURI, [AuthManagerHelper]::CreateInstance("https://vault.azure.net"));
    }
}