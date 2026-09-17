using module .\BaseConfiguration.psm1;
using module .\OTCSGraphConnectorDB.psm1;
using module .\Utility.psd1;
using module .\Utility.psm1;

<# 
    ConfigurationManager is split into BaseConfiguration and ConfigurationManager
    to avoid circular dependency caused by OTCSGraphConnectorDB module.
#>

enum IdentityMappingType
{
    MEID = 1
    Custom = 2
}
class IdentityMappingConfiguration{
    [IdentityMappingType]$MappingType;
    [string]$RegexMatchingPattern;
    [string]$ReplacementPattern;

    IdentityMappingConfiguration(
        [IdentityMappingType]$MappingType,
        [string]$RegexMatchingPattern,
        [string]$ReplacementPattern
    )
    {
        $this.MappingType = $MappingType;
        $this.RegexMatchingPattern = $RegexMatchingPattern;
        $this.ReplacementPattern = $ReplacementPattern;
    }
}

class ConfigurationManager: BaseConfiguration
{
    static [string]$OTCSInstance = $env:OTCSInstance;
    static [string]$OTCSUsername = $env:OTCSUsername;
    static [string]$OTCSPassword = $env:OTCSPassword;
    static [string]$SkipDatabaseCreation = [string]::IsNullOrWhiteSpace($env:SkipDatabaseCreation) ? $true : [Utility]::ParseBooleanValue($env:SkipDatabaseCreation);
    static [string]$FileExtensionExclusionList = $env:FileExtensionExclusionList;
    static [string]$FileWhitelist = $env:FileWhitelist;
    static [string]$ServiceBusEndpoint = $env:ServiceBusEndpoint;
    static [string]$BlobStorageUri = $env:BlobStorageUri;
    static [int]$ItemProcessingBatchSize = $env:ItemProcessingBatchSize;
    static [System.Object]$IMConfig = $(dir env:"$($env:IdentityMapping).*")
    static [IdentityMappingConfiguration]$IdentityMappingConfiguration = [ConfigurationManager]::GetIdentityMappingConfigParameter("IdentityMapping.Type") -ne "Custom" ?
        [IdentityMappingConfiguration]::new(
            [IdentityMappingType]::MEID,
            "",
            "") : 
        [IdentityMappingConfiguration]::new(
            [IdentityMappingType]::Custom,
            [ConfigurationManager]::GetIdentityMappingConfigParameter("IdentityMapping.RegexPattern"),
            [ConfigurationManager]::GetIdentityMappingConfigParameter("IdentityMapping.ReplacementPattern"));

    static [string]GetConfigurationValue(
        [string]$Name
    )
    {
        $db = [OTCSGraphConnectorDB]::new();
        return $db.GetConfigValue($Name);
    }

    static [string]GetIdentityMappingConfigParameter(
        [string]$ConfigParameter
    )
    {
        $configEntry = [ConfigurationManager]::IMConfig | Where-Object Name -eq $ConfigParameter
        if ($null -eq $configEntry)
        {
            return "";
        } else {
            return $configEntry.Value;
        }
    }
}