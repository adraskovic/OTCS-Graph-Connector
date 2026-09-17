using module .\Logging.psm1
using module .\Utility.psd1
using module .\Utility.psm1
using module .\AuthManager.psm1

class SqlConnector
{
	hidden [string]$ConnectionString = [string]::Empty;
	hidden [System.Object]$AccessToken = $null;

	SqlConnector(
		[string]$ConnectionString
	)
	{
		$this.ConnectionString = $ConnectionString;
		$strBuilder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($this.ConnectionString);
		if ([string]::IsNullOrWhiteSpace($strBuilder.UserID) -and ![string]::IsNullOrWhiteSpace($env:MSI_ENDPOINT) -and ![string]::IsNullOrWhitespace($env:MSI_SECRET))
		{
			$this.AccessToken = $this.GetMSIAccessToken();
		}
	}

	SqlConnector(
		[string]$ConnectionString,
		[AuthManager]$AuthManager
	)
	{
		$this.ConnectionString = $ConnectionString;
		$this.AccessToken = $AuthManager.Token;
		$global:SqlAccessToken = $AuthManager.Token;
	}

	[System.Object]GetMSIAccessToken()
	{
		$validTokenAvailable = $false;

		if (![string]::IsNullOrWhiteSpace($global:SqlAccessToken))
		{
			[double]$doubleValue = -1;
			[DateTime]$tokenExpiration = [DateTime]::UtcNow;

			if (![System.Double]::TryParse($global:SqlAccessToken.expires_on, [ref]$doubleValue))
			{
				# not unix datetime, convert from DateTime string
				$tokenExpiration = [DateTime]$global:SqlAccessToken.expires_on
			} else {
				$tokenExpiration = [Utility]::ConvertFromUnixDate($global:SqlAccessToken.expires_on)
			}

			$validTokenAvailable = $tokenExpiration -gt [DateTime]::UtcNow
		}

		$tokenResponse = $null;

		if (!$validTokenAvailable) {
			$resourceURI = "https://database.windows.net/"
			$tokenAuthURI = $env:MSI_ENDPOINT + "?resource=$resourceURI&api-version=2017-09-01"
			$tokenResponse = Invoke-RestMethod -Method Get -Headers @{"Secret"="$env:MSI_SECRET"} -Uri $tokenAuthURI -TimeoutSec 30
			$global:SqlAccessToken = $tokenResponse
		} else {
			$tokenResponse = $global:SqlAccessToken
		}
		
		return $tokenResponse
	}

	[string] GetConnectionStringWithoutPassword()
	{
		$strBuilder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($this.ConnectionString);

		if (!([string]::IsNullOrWhiteSpace($strBuilder.UserID) -or $strBuilder.IntegratedSecurity))
		{
			$strBuilder.Password = "******";
		}

		return $strBuilder.ConnectionString;
	}

	[object]NormalizeValue(
		[object]$value
	)
	{
		if ($null -eq $value) {
			return [DBNull]::Value
		}
		return $value
	}

	[void]AddParam(
		[System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]]$parameters,
		[string]$name,
		[object]$value
	)
	{
		$param = New-Object System.Data.SqlClient.SqlParameter(
			$name,
			$this.NormalizeValue($value)
		)
		$parameters.Add($param) | Out-Null
	}

	[System.Data.SqlClient.SqlParameter]AddOutParam(
		[System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]]$parameters,
		[string]$name,
		[System.Data.SqlDbType]$dbType
	)
	{
		$param = New-Object System.Data.SqlClient.SqlParameter($name, $dbType)
		$param.Direction = [System.Data.ParameterDirection]::Output
		$parameters.Add($param) | Out-Null
		return $param
	}

	[System.Object] InvokeSQLProcedure(
		$sqlCommand,
		[System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]]
		$Parameters,
		[int]$Timeout
	)
	{				
		if ([string]::IsNullOrEmpty($this.ConnectionString))
		{
			throw "Connection string is not provided. Cannot invoke T-SQL command."
		}
		
		if ($null -eq $Timeout)
		{
			$Timeout = $script:CommandTimeout
		}
			
		$conn = New-Object System.Data.SqlClient.SqlConnection
		$conn.ConnectionString = $this.ConnectionString
		if ($null -ne $this.AccessToken)
		{
			$token = $this.GetMSIAccessToken()
			$conn.AccessToken = $token.access_token
		}
		$conn.open()
		$sqlCmd = New-Object System.Data.SqlClient.SqlCommand($sqlCommand)
		$sqlCmd.CommandType = [System.Data.CommandType]::StoredProcedure;
		$sqlCmd.Connection = $conn;
	
		foreach ($parameter in $Parameters)
		{
			$sqlCmd.Parameters.Add($parameter)
		}
	
		$sqlCmd.Parameters.Add("@RETURN_VALUE", [System.Data.SqlDbType]::Int).Direction = [System.Data.ParameterDirection]::ReturnValue;
		$sqlCmd.CommandTimeout = $Timeout;
		try
		{
			$r = $sqlCmd.ExecuteScalar();
			$global:sqlResult = $r
			if ($null -ne $r)
			{
				$result = $($r)
			}
			else
			{
				$result = 0
			} 
		}
		catch
		{
			throw "Error executing stored procedure $sqlCommand `r`nMessage: $($_.Exception.Message)"
		}
		
		$conn.close() | Out-Null

		return $result
	}

	[System.Object] InvokeSQLProcedure(
		$sqlCommand,
		[System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]]
		$Parameters
	)
	{
		return $this.InvokeSQLProcedure($sqlCommand, $Parameters, 600)
	}

	[System.Data.DataTableCollection]GetTSQLDataTableCollection(
		[string]$TSQL,
		[int]$Timeout=600
	)
	{
	
		if ([string]::IsNullOrEmpty($this.ConnectionString))
		{
			throw "Connection string is not provided. Cannot invoke T-SQL command."
		}
		
		if ($null -eq $Timeout)
		{
			$Timeout = $script:CommandTimeout
		}
					
		$SqlConnection = New-Object System.Data.SqlClient.SqlConnection
		$SqlConnection.ConnectionString = $this.ConnectionString

		if ($null -ne $this.AccessToken)
		{
			$SqlConnection.AccessToken = $this.AccessToken.access_token
		}
		
		$SqlConnection.Open();
		
		$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
		$SqlCmd.CommandText = $TSQL
		$SqlCmd.Connection = $SqlConnection
		$SqlCmd.CommandTimeout = $Timeout
		
		$SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
		$SqlAdapter.SelectCommand = $SqlCmd
		
		$DataSet = New-Object System.Data.DataSet
		$SqlAdapter.Fill($DataSet) | Out-Null
		
		$SqlConnection.Close() | Out-Null
		$SqlConnection.Dispose() | Out-Null

		$res = $null
		
		if (![string]::IsNullOrEmpty($DataSet))
		{
			if ($DataSet.Tables.Count -gt 0)
			{
				$res = $DataSet.Tables
			}
			
			$DataSet.Dispose() | Out-Null
		}
		return $res
	}

	[System.Data.DataTableCollection]GetTSQLDataTableCollection(
		[string]$TSQL
	)
	{
		return $this.GetTSQLDataTableCollection($TSQL, 600);
	}

	[System.Data.DataSet]GetParametrizedDataSet(
		[string]$command,
		[System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]]$parameters,
		[int]$timeout=-1
	)
	{	
		if ([string]::IsNullOrEmpty($this.ConnectionString))
		{
			throw "Connection string is not provided. Cannot invoke T-SQL command."
		}
		
		if ($null -eq $parameters)
        {
            $parameters = [System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]]::new();
        }

		if ($null -eq $Timeout)
		{
			$timeout = 600
		}
					
		$SqlConnection = New-Object System.Data.SqlClient.SqlConnection
		$SqlConnection.ConnectionString = $this.ConnectionString
		if ($null -ne $this.AccessToken)
		{
			$SqlConnection.AccessToken = $this.AccessToken.access_token
		}
		$SqlConnection.Open();
		
		$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
		$SqlCmd.CommandText = $command
		$SqlCmd.Connection = $SqlConnection
		$SqlCmd.CommandTimeout = $timeout -gt 0 ? $timeout : 600;

		foreach ($parameter in $parameters)
		{
			$SqlCmd.Parameters.Add($parameter);
		}
		
		$SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
		$SqlAdapter.SelectCommand = $SqlCmd

		$DataSet = New-Object System.Data.DataSet
		
		try {	
			$SqlAdapter.Fill($DataSet) | Out-Null
		}
		catch {
			$paramListArray = @();
			[string]$paramListStr = [string]::Empty;
			foreach ($parameter in $parameters)
			{
				$paramListArray += [string]::Format("[{0} @{1} = '{2}'], ", $parameter.GetType().FullName, $parameter.ParameterName, $parameter.Value);
			}

			$paramListStr = $paramListArray -join ', '

			[TraceLogging]::LogEvent(
				[LoggingLevel]::Critical,
				"M365 Service Health Hub Core",
				"Database",
				"SQL0db9v",
				[string]::Format(
					"Couldn't retrieve the data from the database. SQL command: {0}.`r`nParameters: {1}.`r`nException: {2}.`r`nStack trace: {3}",
					$command,
					$paramListStr,
					$_,
					$_.StackTrace
					)
				);

			throw;
		}
		finally {
			$SqlAdapter.Dispose() | Out-Null
 			$SqlConnection.Close() | Out-Null
			$SqlConnection.Dispose() | Out-Null
		}

		return $DataSet
	}

	[int] ExecuteQuery([string] $command)
	{
		if ([string]::IsNullOrWhiteSpace($command))
		{
			throw $(New-Object System.ArgumentException("Command cannot be null or empty."));
		}

		$separatorList = New-Object System.Collections.Generic.List[string]  
		$separatorList.Add("GO`r`n")
		$separatorList.Add("GO`n")  
		$separatorList.Add("GO`t")
		$separatorList.Add("GO ")

		$sqlStatements = $command.Split($separatorList.ToArray(), [System.StringSplitOptions]::RemoveEmptyEntries);
		$result = -1;

		if ([string]::IsNullOrEmpty($this.ConnectionString))
		{
			throw "Connection string is not provided. Cannot invoke T-SQL command."
		}
					
		$conn = New-Object System.Data.SqlClient.SqlConnection
		$conn.ConnectionString = $this.ConnectionString
		if ($null -ne $this.AccessToken)
		{
			$token = $this.GetMSIAccessToken()
			$conn.AccessToken = $token.access_token
		}
		$conn.Open()
		
		foreach ($sqlStatement in $sqlStatements)
		{
			if ($sqlStatement.Trim().ToUpper -ne "GO")
			{
				$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
				$SqlCmd.CommandText = $sqlStatement.Trim().TrimEnd("GO")
				$SqlCmd.Connection = $conn
				$SqlCmd.CommandTimeout = 600;
				
				if (![string]::IsNullOrWhiteSpace($SqlCmd.CommandText))
				{
					[TraceLogging]::LogEvent(
							[LoggingLevel]::Information,
							"M365 Service Health Hub Core",
							"Database",
							"SQL0dbx2",
							[string]::Format(
								"Executing SQL Query. Connection string: {0}.`r`nSQL command: {1}",
								$this.GetConnectionStringWithoutPassword(),
								$sqlStatement
								)
							);
					try {
						$SqlCmd.ExecuteNonQuery();
						# ZTSQLDiagnostic.RegisterQueryExecution();
					}
					catch {
						[TraceLogging]::LogEvent(
							[LoggingLevel]::Critical,
							"M365 Service Health Hub Core",
							"Database",
							"SQL0dbh1",
							[string]::Format(
								"Couldn't execute the SQL query. Connection string: {0}.`r`nSQL command: {1}.`r`nException: {2}.`r`nStack trace: {3}",
								$this.GetConnectionStringWithoutPassword(),
								$sqlStatement,
								$_,
								$_.StackTrace
								)
							);
					}
					finally {
						$SqlCmd.Dispose();
					}
				}
				else {
					$SqlCmd.Dispose();
				}
			}
		}

		$conn.Close();
		$conn.Dispose();
		return $result;
	}

	[int] ExecuteParameterizedQuery(
		[string]$command,
		[System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]]$parameters)
	{
		if ([string]::IsNullOrWhiteSpace($command))
		{
			throw $(New-Object System.ArgumentException("Command cannot be null or empty."));
		}
		
		$result = -1;

		if ([string]::IsNullOrEmpty($this.ConnectionString))
		{
			throw "Connection string is not provided. Cannot invoke T-SQL command."
		}
					
		$conn = New-Object System.Data.SqlClient.SqlConnection
		$conn.ConnectionString = $this.ConnectionString
		if ($null -ne $this.AccessToken)
		{
			$token = $this.GetMSIAccessToken()
			$conn.AccessToken = $token.access_token
		}
		$conn.Open()
		
		$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
		$SqlCmd.CommandText = $command.Trim().TrimEnd("GO")
		$SqlCmd.Connection = $conn
		foreach ($parameter in $parameters)
		{
			$SqlCmd.Parameters.Add($parameter) | Out-Null
		}
		$sqlCmd.Parameters.Add("@RETURN_VALUE", [System.Data.SqlDbType]::Int).Direction = [System.Data.ParameterDirection]::ReturnValue;
						
		if (![string]::IsNullOrWhiteSpace($sqlCmd.CommandText))
		{
			try {
				$SqlCmd.ExecuteNonQuery();
				$result = $null -eq $sqlCmd.Parameters["@RETURN_VALUE"] ? 0 : $sqlCmd.Parameters["@RETURN_VALUE"].Value;
				# ZTSQLDiagnostic.RegisterQueryExecution();
			}
			catch {
				$paramListArray = @();
				[string]$paramListStr = [string]::Empty;
				foreach ($parameter in $parameters)
				{
					$paramListArray += [string]::Format("[{0} @{1} = '{2}'], ", $parameter.GetType().FullName, $parameter.ParameterName, $parameter.Value);
				}

				$paramListStr = $paramListArray -join ', '

				[TraceLogging]::LogEvent(
					[LoggingLevel]::Critical,
					"M365 Service Health Hub Core",
					"Database",
					"SQL0dbrj",
					[string]::Format(
						"Couldn't execute SQL query. Connection string: {0}.`r`nSQL command: {1}.`r`nParameters: {2}.`r`nException: {3}.`r`nStack trace: {4}",
						$this.GetConnectionStringWithoutPassword(),
						$command,
						$paramListStr,
						$_,
						$_.StackTrace
						)
					);
			}
			finally {
				$SqlCmd.Dispose();
			}
		}
		else {
			$SqlCmd.Dispose();
		}

		$conn.Close();
		$conn.Dispose();
		return $result;
	}

	[int] ExecuteParameterizedSP(
		[string]$command,
		[System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]]$parameters)
	{
		if ([string]::IsNullOrWhiteSpace($command))
		{
			throw $(New-Object System.ArgumentException("Command cannot be null or empty."));
		}
		
		$result = -1;

		if ([string]::IsNullOrEmpty($this.ConnectionString))
		{
			throw "Connection string is not provided. Cannot invoke T-SQL command."
		}
					
		$conn = New-Object System.Data.SqlClient.SqlConnection
		$conn.ConnectionString = $this.ConnectionString
		if ($null -ne $this.AccessToken)
		{
			$token = $this.GetMSIAccessToken()
			$conn.AccessToken = $token.access_token
		}
		$conn.Open()
		
		$SqlCmd = New-Object System.Data.SqlClient.SqlCommand($command)
		$SqlCmd.CommandType = [System.Data.CommandType]::StoredProcedure;
		$SqlCmd.CommandText = $command.Trim().TrimEnd("GO")
		$SqlCmd.Connection = $conn
		foreach ($parameter in $parameters)
		{
			$SqlCmd.Parameters.Add($parameter) | Out-Null
		}
		$sqlCmd.Parameters.Add("@RETURN_VALUE", [System.Data.SqlDbType]::Int).Direction = [System.Data.ParameterDirection]::ReturnValue;
						
		if (![string]::IsNullOrWhiteSpace($sqlCmd.CommandText))
		{
			try {
				$SqlCmd.ExecuteNonQuery();
				$result = $null -eq $sqlCmd.Parameters["@RETURN_VALUE"] ? 0 : $sqlCmd.Parameters["@RETURN_VALUE"].Value;
				# ZTSQLDiagnostic.RegisterQueryExecution();
			}
			catch {
				$paramListArray = @();
				[string]$paramListStr = [string]::Empty;
				foreach ($parameter in $parameters)
				{
					$paramListArray += [string]::Format("[{0} @{1} = '{2}'], ", $parameter.GetType().FullName, $parameter.ParameterName, $parameter.Value);
				}

				$paramListStr = $paramListArray -join ', '

				[TraceLogging]::LogEvent(
					[LoggingLevel]::Critical,
					"M365 Service Health Hub Core",
					"Database",
					"SQL0tALG",
					[string]::Format(
						"Couldn't execute SQL stored procedure. Connection string: {0}.`r`nStored procedure: {1}.`r`nParameters: {2}.`r`nException: {3}.`r`nStack trace: {4}",
						$this.GetConnectionStringWithoutPassword(),
						$command,
						$paramListStr,
						$_,
						$_.StackTrace
					)
				);
			}
			finally {
				$SqlCmd.Dispose();
			}
		}
		else {
			$SqlCmd.Dispose();
		}

		$conn.Close();
		$conn.Dispose();
		return $result;
	}

	[System.Object]GetTSQLValue(
		[string]$TSQL,
		[string]$VarName,
		[int]$Timeout=600
	)
	{	
		if ($null -eq $Timeout)
		{
			$Timeout = $script:CommandTimeout
		}
		
		$DataSet = $this.GetTSQLDataTableCollection($TSQL, $Timeout) 
		
		if ($DataSet.GetType() -eq [PSObject])
		{
			return $DataSet[0].$VarName
		}
		else
		{
			if (![string]::IsNullOrEmpty($DataSet))
			{
				if ($DataSet.Tables.Count -gt 0)
				{
					return $DataSet.Tables[0].$VarName
				}
				else
				{
					return $DataSet.$VarName
				}
				$DataSet.Dispose() | Out-Null
			}
			else
			{
				return $null
			}
		}
	}

	[System.Object]GetTSQLValue(
		[string]$TSQL,
		[string]$VarName
	)
	{	
		return $this.GetTSQLValue($TSQL, $VarName, 600);
	}
}
