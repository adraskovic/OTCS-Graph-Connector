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

$data = $param.daysArray

[TraceLogging]::LogEvent([LoggingLevel]::Information, "EnumeratorDailyActivity", "Main", "enda0010", "Initializing OTCS Client.");

$otcsClient = [OTCSClient]::new();

[TraceLogging]::LogEvent([LoggingLevel]::Information, "EnumeratorDailyActivity", "Main", "enda0011", "Retrieved $($data.Count) items for processing.");
$facet = $otcsClient.GetModifiedDateFacet();

$count = 1;

foreach ($item in $data)
{
    $date = $null;
    if ($item.date.Length -eq 8)
    {
        $date = [DateTime]::ParseExact($item.date, "yyyyMMdd", $null)
    }
    else 
    {
        $date = [DateTime]$item.date
    }
    [TraceLogging]::LogEvent([LoggingLevel]::Information, "EnumeratorDailyActivity", "Main", "enda0021", "Processing changes for date $($item.date).");
    $otcsClient.EnumerateChangesForDay($date, $facet);
    $output += $date;
    $count++
}

return $output;