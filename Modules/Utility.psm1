using module .\Utility.psd1
# never include using module .\ConfigurationManager.psm1 in this module to prevent module nesting.
class Utility
{
    static [System.DateTime] ConvertFromUnixDate(
        $UnixDate
    )
    {
        return [System.TimeZone]::CurrentTimeZone.ToLocalTime(([datetime]'1/1/1970').AddSeconds($UnixDate))
    }

    static [System.Object] NormalizeValue($InputValue)
    {        
        if ([string]::IsNullOrWhitespace($InputValue))
        { 
            return ""
        }
        else
        {
            return $InputValue
        }
    }

    static [string] DateTimeToString($InputValue)
    {
        return [Utility]::DateTimeToString($InputValue, "o");
    }

    static [string] DateTimeToString($InputValue, $Format)
    {
        return [Utility]::DateTimeToString($InputValue, $Format, $null);
    }

    static [string] DateTimeToString($InputValue, $Format, $InputFormat)
    {
        $result = ""
        if (![string]::IsNullOrWhitespace($InputValue))
        {  
            if ($InputValue.GetType() -eq [datetime])
            {
                if ($InputValue -ne [DateTime]::MinValue -and $InputValue -ne [DateTime]::MaxValue)
                { 
                    $result = [datetime]::SpecifyKind($InputValue, [System.DateTimeKind]::Utc).ToString($Format);
                }
            } else {
                if ([string]::IsNullOrWhiteSpace($InputFormat))
                {
                    $result = [datetime]::SpecifyKind([datetime]::Parse($InputValue), [System.DateTimeKind]::Utc).ToString($Format)
                } else {
                    $result = [datetime]::SpecifyKind([datetime]::ParseExact($InputValue, $InputFormat, $null), [System.DateTimeKind]::Utc).ToString($Format)
                }
            }
        }

        return $result;
    }
    
    static [bool] ParseBooleanValue([string]$Value)
    {            
        return [Utility]::ParseBooleanValue($Value, $false)
    }

    static [bool] ParseBooleanValue([string]$Value, [bool]$DefaultValue = $false)
    {    
        $result = $DefaultValue
    
        try {
            $result = [bool]::Parse($Value)
        }
        catch {
            $result = $DefaultValue
        }
        
        return $result
    }

    static [string] BoolToString(
        [bool]$value,
        [string]$trueString,
        [string]$falseString
    )
    {
        return $value ? $trueString : $falseString
    }

    static [string] FixQuotes ([string]$InputJsonString)
    {
        $singleQuotes = "[\u2019\u2018]"
        $doubleQuotes = "[\u201C\u201D]"
        
        $res = $InputJsonString | % { `
             $_ = [regex]::Replace($_, $singleQuotes, "'")
             [regex]::Replace($_, $doubleQuotes, '\"')
         }
         
         return $res
    }

    static [string] GetTextFromAPICode([string]$Code)
    {
        $myTI = $(New-Object CultureInfo("en-US", $false)).TextInfo;
        return $myTI.ToTitleCase([Regex]::Replace([Utility]::NormalizeValue($Code), "([a-z])([A-Z])", '$1 $2'));
    }


    static [System.Collections.Generic.List[string]] GetRoadmapIDs([string]$MessageText)
    {
        $IDs = New-Object System.Collections.Generic.List[string]

        $matches = [regex]::Matches($MessageText, "(?<=<a([^>]+)>)(.+?)(?=<\/a>)")
        foreach ($match in $matches)
        {
            $roadmapMatch = $false
            foreach ($group in $match.Groups)
            {
                if ($group.Value.ToUpper().Contains("MICROSOFT-365/ROADMAP"))
                {
                    $roadmapMatch = $true
                }
            }
        
            if ($roadmapMatch)
            {
                $extractNumber = [regex]::Match($match.Value.ToUpper().Replace("MICROSOFT 365", ""), "\d+")
                if (!$IDs.Contains($extractNumber.Value))
                {
                    $IDs.Add($extractNumber.Value)
                }
            }
        }
        return $IDs
    }

    static [bool] ObjectsEqual(
        [System.Object]$Object1,
        [System.Object]$Object2
    )
    {
        if ($null -eq $Object1 -and $null -eq $Object2)
        {
            return $true
        }

        if ($null -eq $Object1 -or $null -eq $Object2)
        {
            return $false
        }

        $diff = Compare-Object -ReferenceObject $Object1 -DifferenceObject $Object2

        return $($diff.Count -eq 0)
    }

    static [string] ConvertToPlainText(
        [string]$Text
    )
    {
        return [Utility]::ConvertToPlainText($Text, $false);
    }

    static [string] ConvertToPlainText(
        [string]$Text,
        [bool]$SkipHyperlinks
    )
    {
        if ([string]::IsNullOrWhiteSpace($Text))
        {
            return [string]::Empty;
        } else {
            $nbsp = [char]0xA0;
            $value = $Text.Replace("`r", "").Replace("`n", "").Replace($nbsp, " ");
            $value = [regex]::Replace($value, "<br[^>]*>", "`r`n");
            $value = $value.Replace('&nbsp;', ' ');
            $value = $value.Replace('&nbsp', ' ');
            $value = $value.Replace('“','\"');
            $value = $value.Replace('”','\"');
            $value = $value.Replace("`r`n`r`n`r`n", "`r`n`r`n");
            
            $listProcessed = [regex]::Replace($value, "<li>(.*?)<\/li>", ' - $1'+"`r`n");
            $listProcessed = $listProcessed.Replace("</ul>", "`r`n");
            if (!$skipHyperlinks)
            {
                $linksProcessed = [regex]::Replace($listProcessed, "<a[ \t]+href=""(.*?)""[^>]*>(.*?)</a>", '[$2]($1)');
            } else 
            {
                $linksProcessed = $listProcessed
            }
            $paragraphProcessed = [regex]::Replace($linksProcessed, "<p>(.*?)<\/p>", '$1'+"`r`n`r`n");
            $paragraphProcessed = [regex]::Replace($paragraphProcessed, "<h(.?)>(.*?)<\/h(.?)>", '$2'+"`r`n`r`n");
            $plainText = [regex]::Replace($paragraphProcessed, "<[^>]*>", "");
            return $plainText;
        }
    }

    static [string] ConvertISO88591ToUTF8(
        [string]$Text
    )
    {
        $iso88591 = [System.Text.Encoding]::GetEncoding("iso-8859-1")
        $utf8 = [System.Text.Encoding]::UTF8
        $isoBytes = $iso88591.GetBytes($Text)
        $utf8bytes = [System.Text.Encoding]::Convert($iso88591, $utf8, $isoBytes)
        return $utf8.GetString($utf8bytes)
    }

    static [byte[]] ConvertISO88591ToUTF8Bytes(
        [string]$Text
    )
    {
        $iso88591 = [System.Text.Encoding]::GetEncoding("iso-8859-1")
        $utf8 = [System.Text.Encoding]::UTF8
        $isoBytes = $iso88591.GetBytes($Text)
        return [System.Text.Encoding]::Convert($iso88591, $utf8, $isoBytes)
    }

    static [string] ConvertToMarkdown(
        [string]$Text
    )
    {
        if ([string]::IsNullOrWhiteSpace($Text))
        {
            return [string]::Empty;
        } else {
            $converter = [ReverseMarkdown.Converter]::new();
            $markdownText = $converter.Convert($Text);
            return $markdownText;
        }
    }

    static [string]GetMessageTypeCode([string]$MessageType)
    {
        $mtMapping = @{
            incident = "💥"
            messagecenter = "📣"
        }
    
        $code = [string]::Empty
        if (![string]::IsNullOrWhiteSpace($MessageType))
        {
            $code = $mtMapping.$($MessageType.ToLower())
        }
    
        if ([string]::IsNullOrWhiteSpace($code))
        {
            return $MessageType
        }
        else
        {
            return $code
        }
    }

    static [string]GetClassificationCode($Classification)
    {
        $clMapping = @{
            incident = "🚨"
            advisory = "🎓"
        }
    
        $image = [string]::Empty
        if (![string]::IsNullOrWhiteSpace($Classification))
        {
            $image = $clMapping.$($Classification.ToLower())
        }
    
        if ([string]::IsNullOrWhiteSpace($image))
        {
            return $Classification.ToUpper()
        }
        else
        {
            return $image
        }
    }

    static [string]GetStatusCode($Status)
    {
        $s = $Status.ToLower().Trim()
        if ($s -in @("general information", "false positive", "post-incident report published", "service restored", "falsePositive", "postIncidentReviewPublished", "serviceRestored", "mitigatedExternal", "mitigated", "resolvedExternal", "resolved"))
        {
            return "✅"
        }
        elseif ($s -in @("extended recovery", "investigation suspended", "restoring service", "extendedRecovery", "investigationSuspended", "investigating", "restoringService", "verifyingService"))
        {
            return "⚠️"
        }
        else
        {
            return "🔴"
        }
	}

	static [string]GetStatusThemeColor($Status)
    {
        $s = $Status.ToLower().Trim()
        if ($s -in @("general information", "false positive", "post-incident report published", "service restored", "falsePositive", "postIncidentReviewPublished", "serviceRestored", "mitigatedExternal", "mitigated", "resolvedExternal", "resolved"))
        {
            return "00FF00"
        }
        elseif ($s -in @("extended recovery", "investigation suspended", "restoring service", "extendedRecovery", "investigationSuspended", "investigating", "restoringService", "verifyingService"))
        {
            return "0070C0"
        }
        else
        {
            return "FF0000"
        }
	}

    static [string] ProcessWorkItemUrl($WorkItemUrl, $Routing)
    {
        if ($null -ne $Routing -and [Utility]::ParseBooleanValue($Routing.HideWorkItem, $false) -eq $false)
        {
            return $WorkItemUrl;
        } else {
            return [string]::Empty;
        }
    }

    # HTML to Adaptive Card
    static [string] PreprocessTags(
        [string] $body
        )
    {
        $res = [Regex]::Replace($body, '<a.*?href=["'']([^"'']*)["''][^>]*>([^<]*)</a>', '[$2]($1)')
        $res = [Regex]::Replace($res, '(?<=<p>) ?\[(.+?)\] ?\n?(&nbsp;)?(<br>)?(<br\/)?(?=<\/p>)', '**$1**');
        $res = [Regex]::Replace($res, '<b>(\s+)', ' **')
        $res = [Regex]::Replace($res, '<strong>(\s+)', '** ')
        $res = [Regex]::Replace($res, '<i>(\s+)', '* ')
        $res = [Regex]::Replace($res, '<em>(\s+)', '** ')
        $res = [Regex]::Replace($res, '(\s+)<\/b>', '** ')
        $res = [Regex]::Replace($res, '(\s+)<\/strong>', '** ')
        $res = [Regex]::Replace($res, '(\s+)<\/i>', '* ')
        $res = [Regex]::Replace($res, '(\s+)<\/em>', '** ')
        $res = $res.Replace('<b>', '**')
        $res = $res.Replace('</b>', '** ')
        $res = $res.Replace('<strong>', '**')
        $res = $res.Replace('</strong>', '**')
        $res = $res.Replace('<i>', '*')
        $res = $res.Replace('</i>', '*')
        $res = $res.Replace('<em>', '*')
        $res = $res.Replace('</em>', '*')
        return $res
    }

    static [object]ProcessChildNodes(
        [object]$rootNode
        )
    {
        $result = [System.Collections.Generic.List[System.Object]]::new();

        foreach ($node in $rootNode.ChildNodes)
        {
            if ($node.ChildNodes.Count -gt 0 -and $node.OriginalName -notin @("ul", "ol", "li", "table", "td", "tr"))
            {
                $r = [Utility]::ProcessChildNodes($node);
                foreach ($element in $r)
                {
                    $result.Add($element)
                }
            } else {
                switch ($node.OriginalName)
                {
                    "#text" {
                        $resultObj = [PSCustomObject]@{
                            type = "TextBlock"
                            text = $node.Text
                            wrap = $true
                        }
                        $result.Add($resultObj)
                    }

                    "img" {
                        $resultObj = [PSCustomObject]@{
                            type = "Image"
                            url = $($node.Attributes | Where-Object Name -eq "src").Value
                        }
                        $result.Add($resultObj)
                    }

                    default {
                        Write-Host $node.OuterHtml
                        $converter = [ReverseMarkdown.Converter]::new()
                        $content = $converter.Convert($node.OuterHtml);
                        $content = $content.Replace('\*', '*');
                        $resultObj = [PSCustomObject]@{
                            type = "TextBlock"
                            text = $content
                            wrap = $true
                        }
                        $result.Add($resultObj)
                    }
                }
            }
        }

        return $result
    }

    static [object]ConvertHTMLToAdaptiveCardBody(
        [string] $HTML
    )
    {
        $content = [Utility]::PreprocessTags($HTML);
        $htmlDoc = [HtmlAgilityPack.HtmlDocument]::new()
        $htmlDoc.LoadHtml($content)
        $r = [Utility]::ProcessChildNodes($htmlDoc.DocumentNode);
        return $r
    }

    static [string]ConvertHTMLToText(
        [string] $HTML
    )
    {
        $htmlDoc = [HtmlAgilityPack.HtmlDocument]::new()
        $htmlDoc.LoadHtml($HTML)
        $r = $htmlDoc.DocumentNode.SelectSingleNode("//body//body").InnerText
        return $r
    }
    
    static [string] GetQuerySeparator(
        [string] $Uri
    )
    {
        if ($Uri.Contains("?"))
        {
            return "&"
        }

        return "?"
    }

    static [int] GetHttpStatusCode(
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )
    {
        if ($null -eq $ErrorRecord)
        {
            return 0
        }

        if ($null -eq $ErrorRecord.Exception.Response)
        {
            return 0
        }

        try
        {
            return [int] $ErrorRecord.Exception.Response.StatusCode
        }
        catch
        {
            return 0
        }
    }


    static [string] GetResponseHeader(
        [object] $Response,
        [string] $HeaderName
    )
    {
        if ($null -eq $Response -or $null -eq $Response.Headers)
        {
            return $null
        }

        $value = $Response.Headers[$HeaderName]

        if ($null -eq $value)
        {
            return $null
        }

        if ($value -is [string])
        {
            return $value
        }

        if ($value -is [System.Array])
        {
            if ($value.Count -eq 0)
            {
                return $null
            }

            return [string] $value[0]
        }

        if ($value -is [System.Collections.IEnumerable])
        {
            foreach ($item in $value)
            {
                return [string] $item
            }

            return $null
        }

        return [string] $value
    }
}