#region Modules
using module ..\Modules\OTCSGraphConnectorDB.psm1
using module ..\Modules\Services\GraphConnector.psm1;
using module ..\Modules\Logging.psm1
#endregion

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

#region Init
[TraceLogging]::InitializeCorrelationID();
#endregion

[TraceLogging]::LogEvent([LoggingLevel]::Information, "Config", "Main", "cfg103", "Performing OpenText Content Server Graph Connector configuration.");

[TraceLogging]::LogEvent([LoggingLevel]::Information, "Config", "Main", "cfg104", "Checking database schema.");
$db = [OTCSGraphConnectorDB]::new();
$db.PerformSchemaCheck();

[TraceLogging]::LogEvent([LoggingLevel]::Information, "Config", "Main", "cfg105", "Checking Graph Connector state.");
$gc = [GraphConnector]::new()
if ([string]::IsNullOrWhiteSpace($gc.Connector))
{
    $gc.CreateConnector("OpenText Content Server", "This is a connector for OpenText Content Server, which contains internal documentation and enterprise content");
}

if ($gc.Connector.state -eq "draft")
{
    $gc.ProvisionSchema()
    $state = $gc.GetProvisioningState()
    while ($state.status -eq "inprogress")
    {
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "Config", "Main", "cfg10a", "Schema provisioning in progress. Sleeping for 10 seconds.");
        Sleep 10
        $state = $gc.GetProvisioningState()
    }

    if ($state.status -eq "completed")
    {
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "Config", "Main", "cfg10c", "Graph Connector provisioning completed successfully.");
    } else {
        [TraceLogging]::LogEvent([LoggingLevel]::Error, "Config", "Main", "cfg10f", "Graph Connector provisioning failed. Error: $($state.error)");
    }
}

[TraceLogging]::LogEvent([LoggingLevel]::Information, "Config", "Main", "cfg199", "All operations completed.");

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [System.Net.HttpStatusCode]::OK
    Body = ""
})