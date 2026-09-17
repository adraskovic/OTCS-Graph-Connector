using namespace System.Net
using module ..\Modules\Logging.psm1

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

#region Init
[TraceLogging]::InitializeCorrelationID();
#endregion

$runId = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss");

$instanceId = Start-DurableOrchestration -FunctionName "FullIndexJobV1alpha" -Input @{ runId = $runId; correlationId = $([TraceLogging]::CorrelationID) }
[TraceLogging]::LogEvent([LoggingLevel]::Information, "FullIndexJob", "Main", "sdls011", "Started orchestration: $instanceId");

$Response = New-DurableOrchestrationCheckStatusResponse -Request $Request -InstanceId $InstanceId
Push-OutputBinding -Name Response -Value $Response
