using module ..\Modules\Utility.psd1
using module ..\Modules\Utility.psm1
using module ..\Modules\Logging.psm1
using module ..\Modules\OTCSClient.psm1

# Input bindings are passed in via param block.
param($param)

#region Init
$correlationId = $param.correlationId;
if ([string]::IsNullOrWhiteSpace($correlationId))
{
    [TraceLogging]::InitializeCorrelationID();
} else {
    [TraceLogging]::InitializeCorrelationID([guid]$correlationId);
}

#endregion

$runId = $param.runId;

if ([string]::IsNullOrWhiteSpace($runId))
{
    $runId = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss");
}

$data = $param.data

[TraceLogging]::LogEvent([LoggingLevel]::Information, "GroupSync", "Main", "gs0001", "Starting group synchronization process.");
$otcsClient = [OTCSClient]::new();

[TraceLogging]::LogEvent([LoggingLevel]::Information, "GroupSync", "Main", "gs0002", "Starting external group synchronization.");
$otcsClient.SyncGroups();

[TraceLogging]::LogEvent([LoggingLevel]::Information, "GroupSync", "Main", "gs00ff", "Group synchronization process completed successfully.");

$output = @{
    success = $true;
    message = "Group synchronization process for run id $runId completed successfully.";
}
return $output;