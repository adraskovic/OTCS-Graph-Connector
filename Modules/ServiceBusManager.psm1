using module .\ConfigurationManager.psm1
using module .\AuthManagerHelper.psm1
using module .\AuthManager.psm1
using module .\Utility.psd1
using module .\Utility.psm1
using module .\Logging.psm1

class ServiceBusManager
{
	[string]$Endpoint = [string]::Empty;
    hidden [AuthManager]$AuthManager = $null;

	ServiceBusManager()
	{
		$this.Endpoint = $([ConfigurationManager]::ServiceBusEndpoint);
        $this.AuthManager = [AuthManagerHelper]::CreateInstance("https://servicebus.azure.net");
	}

	hidden [void]SendMessage(
		[string]$QueueName,
		[object]$Message
	)
	{
		[TraceLogging]::LogEvent([LoggingLevel]::Information, "ServiceBusManager", "SendMessage", "sb1029", "Entering method ServiceBusManager.SendMessage()");
		
		$body = $(ConvertTo-Json $Message -Depth 10);

		if (![string]::IsNullOrWhiteSpace($this.Endpoint))
		{
			[TraceLogging]::LogEvent([LoggingLevel]::Information, "ServiceBusManager", "SendMessage", "sb1033", "Message endpoint provided, posting message to $($this.Endpoint)");
			try
			{
                $headers = @{                                                                                                          
                    Authorization = [string]::Format("{0} {1}", $this.AuthManager.Token.token_type, $this.AuthManager.Token.access_token)
                    "Content-Type" = 'application/json'
                }

				$uri = $this.Endpoint.Trim().TrimEnd('/')
				$uri = $uri + '/' + $QueueName + '/messages'

				Invoke-RestMethod -Uri $uri -Method Post -Body $body -Headers $headers -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
				[TraceLogging]::LogEvent([LoggingLevel]::Information, "ServiceBusManager", "SendMessage", "sb1034", "Message successfully posted.");
			}
			catch
			{
				[TraceLogging]::LogEvent([LoggingLevel]::Error, "ServiceBusManager", "SendMessage", "sb1087", "An exception was caught while posting an adaptive card. Exception: $_");
				[TraceLogging]::LogEvent([LoggingLevel]::Error, "ServiceBusManager", "SendMessage", "sb1087", "Stack trace: $($_.ScriptStackTrace)");
				[TraceLogging]::LogEvent([LoggingLevel]::Error, "ServiceBusManager", "SendMessage", "sb1087", "Data: $body");
			}
		}

		[TraceLogging]::LogEvent([LoggingLevel]::Information, "ServiceBusManager", "SendMessage", "sb1099", "Exiting method ServiceBusManager.SendMessage()");
	}
}