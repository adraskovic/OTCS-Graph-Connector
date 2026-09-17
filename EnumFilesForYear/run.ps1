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

$parallelTasks = @()

$year = $Context.Input.year

$currentDate = [DateTime]"$year-01-01";
$count = 0;
$batchSize = 7
$batchCount = 0;
$dateCollection = [System.Collections.Generic.List[System.Object]]::new();
$totalBatches = [math]::Ceiling([math]::Ceiling(([DateTime]::Now - $currentDate).TotalDays)/$batchSize)
$endDate = [DateTime]"$year-12-31";

while ($currentDate -le $endDate -and $currentDate -le [DateTime]::UtcNow)
{
    if ($count -ge $batchSize)
    {
        $parallelTasks += Invoke-DurableActivity `
            -FunctionName "EnumFilesForDaysActivity" `
            -Input @{ runId = $runId; correlationId = $correlationId; daysArray = $dateCollection.ToArray() } `
            -NoWait
        $dateCollection.Clear();
        $count = 0;
        $batchCount ++
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "FullEnumerator", "Main", "fe0004", "Created activity instance #$batchCount / $totalbatches");
    }

    $obj = @{
        date = $currentDate.ToString("yyyy-MM-dd");
    }

    $dateCollection.Add($obj);
    $currentDate = $currentDate.AddDays(1);
    $count++
}

if ($dateCollection.Count -gt 0)
{
    $parallelTasks += Invoke-DurableActivity `
        -FunctionName "EnumFilesForDaysActivity" `
        -Input @{ runId = $runId; correlationId = $correlationId; daysArray = $dateCollection.ToArray() } `
        -NoWait
        
    $dateCollection.Clear();
    [TraceLogging]::LogEvent([LoggingLevel]::Information, "FullEnumerator", "Main", "fe0005", "Created activity instance #$($batchCount+1) / $totalbatches");
}

$output = Wait-DurableTask -Task $parallelTasks
return $output