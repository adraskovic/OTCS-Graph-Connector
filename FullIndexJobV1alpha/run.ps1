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
#$enumGroupsResult = Invoke-DurableActivity -FunctionName "SyncGroupsActivity" -Input $Context.Input

#if ($enumGroupsResult.success)
#{
    $parallelTasks = @()

    $currentDate = [DateTime]"2020-01-01";
    $count = 0;
    $batchSize = 7
    $batchCount = 0;
    $dateCollection = [System.Collections.Generic.List[System.Object]]::new();
    $totalBatches = [math]::Ceiling([math]::Ceiling(([DateTime]::Now - $currentDate).TotalDays)/$batchSize)
    $pendingBatches = [System.Collections.Generic.List[System.Object]]::new();

    while ($currentDate -le [DateTime]::Now)
    {
        if ($count -ge $batchSize)
        {
            $pendingBatches.Add(
                @{
                    runId = $runId;
                    correlationId = $correlationId;
                    daysArray = $dateCollection.ToArray()
                }
            )

            $dateCollection.Clear();
            $count = 0;
            $batchCount ++
            [TraceLogging]::LogEvent([LoggingLevel]::Information, "FullEnumerator", "Main", "fe0004", "Created a job order #$batchCount / $totalbatches");
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
        $pendingBatches.Add(
            @{
                runId = $runId;
                correlationId = $correlationId;
                daysArray = $dateCollection.ToArray()
            }
        )
            
        $dateCollection.Clear();
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "FullEnumerator", "Main", "fe0006", "Created a job order #$($batchCount+1) / $totalbatches");
    }

    $retryOptions = New-DurableRetryOptions `
        -FirstRetryInterval (New-TimeSpan -Minutes 1) `
        -MaxNumberOfAttempts 10

    $c = 1
    $runningTasks = @();

    foreach ($pendingTask in $pendingBatches)
    {
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "FullEnumerator", "Main", "fe0007", "Dispatching job #$c / $($pendingBatches.Count)");

        $runningTasks += Invoke-DurableActivity `
            -FunctionName "EnumFilesForDaysActivity" `
            -Input $pendingTask `
            -NoWait `
            -RetryOptions $retryOptions
    }

    $completed = Wait-DurableTask -Task $runningTasks
    foreach ($t in $completed)
    {
        $result = Get-DurableTaskResult -Task $t
        $output += $result
    }

    <# $maxParallelJobs = 2048
    $runningTasks = @();

    $retryOptions = New-DurableRetryOptions `
        -FirstRetryInterval (New-TimeSpan -Minutes 1) `
        -MaxNumberOfAttempts 10

    # Fill initial window
    $c = 0
    $totalJobs = $pendingBatches.Count;

    while ($runningTasks.Count -lt $maxParallelJobs -and $c -lt $pendingBatches.Count)
    {
        [TraceLogging]::LogEvent([LoggingLevel]::Information, "FullEnumerator", "Main", "fe0007", "Dispatching job #$c / $totalJobs");

        $job = $pendingBatches[$c]

        $runningTasks += Invoke-DurableActivity `
            -FunctionName "EnumFilesForDaysActivity" `
            -Input $job `
            -NoWait `
            -RetryOptions $retryOptions

        $c++
    }

    while ($runningTasks.Count -gt 0)
    {
        $completed = Wait-DurableTask -Any -Task $runningTasks
        foreach ($t in $completed)
        {
            $result = Get-DurableTaskResult -Task $t
            $output += $result
        }

        $runningTasks = @(
            $runningTasks | Where-Object { $_ -ne $completed }
        )

        if ($c -lt $pendingBatches.Count)
        {
            $job = $pendingBatches[$c]

            [TraceLogging]::LogEvent([LoggingLevel]::Information, "FullEnumerator", "Main", "fe0008", "Dispatching job #$c / $totalJobs");

            $runningTasks += Invoke-DurableActivity `
            -FunctionName "EnumFilesForDaysActivity" `
            -Input $job `
            -NoWait `
            -RetryOptions $retryOptions

            $c++
        }
    } #>

    return $output
#} else {
#    throw $enumSiteResult.message
#}