# never include using module .\ConfigurationManager.psm1 in this module to prevent module nesting.
enum LoggingLevel
{
    Debug = 0;
    Verbose = 1;
    Information = 2;
    Warning = 3;
    Error = 4;
    Critical = 5;
    General = 6;
    Off = 999
}

class TraceLogging
{
    #region Internal and private fields
    static [Guid] $CorrelationID = [Guid]::Empty;
    hidden static [int] $processId = -1;
    hidden static [string] $processName = [string]::Empty;
    hidden static [int] $threadId = -1;
    #endregion

    #region Public methods
    static [bool] InitializeCorrelationID()
    {
        return [TraceLogging]::InitializeCorrelationID([Guid]::Empty);
    }

    static [bool] InitializeCorrelationID([Guid]$correlationId)
    {
        if ($correlationId -ne [Guid]::Empty)
        {
            [TraceLogging]::CorrelationID = $correlationId;
            return $true;
        }

        if ($correlationID -eq [Guid]::Empty)
        {
            [TraceLogging]::CorrelationID = [Guid]::NewGuid();
            return $true; # created a new id
        }
        else
        {
            return $false; # using existing correlation id
        }
    }

    static [void] ReleaseCorrelationID()
    {
        [TraceLogging]::CorrelationID = [Guid]::Empty;
    }

    <#
    .SYNOPSIS
    Logs the event to the trace log based on the provided parameters.

    .DESCRIPTION
    Logs the event to the trace log based on the provided parameters.

    .PARAMETER severity
    Severity of the event

    .PARAMETER component
    Component in which the event occured

    .PARAMETER category
    Category of the event.
    
    .PARAMETER tag
    Event tag. Used to easily locate the event within the source code. Each event must have an unique tag.

    .PARAMETER eventMessage
    Event message. Text containing descriptive information and diagnostic information of the event.

    .NOTES
        Author: Aleksandar Draskovic (aldras@microsoft.com)
        Last Edit: 2020-08-27    
    #>
    static [void] LogEvent([LoggingLevel] $severity, [string] $component, [string] $category, [string] $tag, [string] $eventMessage)
    {
        $VerbosePreference = "Continue"
        $DebugPreference = "Continue"

        $message = @{
            TimestampUTC = [DateTime]::UtcNow;
            Severity = $severity.ToString();
            Component = $component;
            Category = $category;
            Tag = $tag;
            CorrelationID = [TraceLogging]::CorrelationID;
            EventMessage = $eventMessage;
        } | ConvertTo-Json -Depth 20

        switch($severity)
        {        
            {$_ -eq [LoggingLevel]::Debug} {
                Write-Debug -Message $message
            } 
            {$_ -eq [LoggingLevel]::Verbose} {
                Write-Verbose -Message $message
            }
            {$_ -eq [LoggingLevel]::Information} {
                Write-Information -MessageData $message -Tags $tag -InformationAction Continue
            }
            {$_ -eq [LoggingLevel]::Warning} {
                Write-Warning -Message $message -WarningAction Continue
            }
            {$_ -eq [LoggingLevel]::Error} {
                Write-Error -Message $message -ErrorAction Continue
            }
            {$_ -eq [LoggingLevel]::Critical} {
                Write-Error -Message $message -ErrorAction Continue
            }
            {$_ -eq [LoggingLevel]::General} {
                Write-Information -MessageData $message -Tags $tag -InformationAction Continue
            }
        }
    }
    #endregion Public methods
}