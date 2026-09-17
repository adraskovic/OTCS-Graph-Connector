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

$output = @()

$runId = $param.runId;

if ([string]::IsNullOrWhiteSpace($runId))
{
    $runId = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss");
}

$data = $param.data

$otcsClient = [OTCSClient]::new();

[TraceLogging]::LogEvent([LoggingLevel]::Information, "GroupMembershipSync", "Main", "gms0011", "Retrieved $($mySbMsg.Count) items for processing.");

foreach ($item in $data)
{
    [TraceLogging]::LogEvent([LoggingLevel]::Information, "GroupMembershipSync", "Main", "gms0021", "Processing group with id=$($item.GroupId). Action: $($item.Action)");
    $otcsClient.SyncGroupMembership($item.GroupId);
    $output += $item.GroupId
}

return $output;