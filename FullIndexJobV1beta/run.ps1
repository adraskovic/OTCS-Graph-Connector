using module ..\Modules\Logging.psm1
using module ..\Modules\ConfigurationManager.psm1

# Input bindings are passed in via param block.
param($Context)

#region Init
$correlationId = $Context.Input.correlationId;
if ([string]::IsNullOrWhiteSpace($correlationId))
{
    [TraceLogging]::InitializeCorrelationID();
} else {
    [TraceLogging]::InitializeCorrelationID([guid]$correlationId);
}
#endregion

$output = @()

$runId = $Context.Input.runId;

if ([string]::IsNullOrWhiteSpace($runId))
{
    $runId = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss");
}

[TraceLogging]::LogEvent([LoggingLevel]::Information, "FullIndexJobV1alpha", "Main", "sdls011", "Dispatching group synchronization activity.");
$enumGroupsResult = Invoke-DurableActivity -FunctionName "SyncGroupsActivity" -Input $Context.Input
$output += @{
    operation = "SyncGroupsActivity";
    result = $enumGroupsResult
}

if ($enumGroupsResult.success)
{
    $parallelTasks = @()

    $startYear = 2000;
    $endYear = [DateTime]::UtcNow.Year

    $maxParallel = 1024
    $allResults = @()

    for ($offset = $startYear; $offset -le $endYear; $offset += $maxParallel ) {

        $lastYear = [Math]::Min(
            $offset + $maxParallel-1,
            $endYear
        )

        $tasks = @()

        for ($index = $offset; $index -le $lastYear; $index++) {
            $tasks += Invoke-DurableSubOrchestrator `
                -FunctionName 'EnumFilesForYear' `
                -Input @{ runId = $runId; correlationId = $correlationId; year = $index }  `
                -NoWait
        }

        # Fan-in: next window starts only after this window finishes
        $windowResults = Wait-DurableTask -Task $tasks
        $allResults += $windowResults
    }

    $output += @{
        operation = "EnumFiles";
        result = $allResults
    }
    return $output
} else {
    throw $enumSiteResult.message
}