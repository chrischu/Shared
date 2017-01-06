BuildStep Execute-MSpecTests -LogMessage 'Execute-MSpecTests (withDotCover: $withDotCover)' {
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory)] [string[]] $testAssemblies,
    [Parameter(ParameterSetName="WithDotCover")][switch] $withDotCover,
    [Parameter(ParameterSetName="WithDotCover")][string] $dotSettingsFile,
    [Parameter(ParameterSetName="WithDotCover")][string] $dotCoverResultsFile
  )

  $mSpecRunnerPath = Get-NuGetSolutionPackagePath "Machine.Specifications.Runner.Console"
  $mSpecExecutable = "$mSpecRunnerPath\tools\mspec-x86-clr4.exe"
  
  try {
    if ($withDotCover.IsPresent) {
      _Execute-TestsWithDotCover "MSpec" $mSpecExecutable "" $testAssemblies $dotSettingsFile $dotCoverResultsFile
    } else {
      Exec { & $mSpecExecutable $testAssemblies } -ErrorMessage "Machine.Specifications tests have failed"
    }
  } catch {
    Report-TestError $_
  }
}

BuildStep Execute-NUnitTests -LogMessage 'Execute-NUnitTests (withDotCover: $withDotCover)' {
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory)] [string[]] $testAssemblies,
    [Parameter(Mandatory)] [string] $resultsFile,
    [Parameter(ParameterSetName="WithDotCover")][switch] $withDotCover,
    [Parameter(ParameterSetName="WithDotCover")][string] $dotSettingsFile,
    [Parameter(ParameterSetName="WithDotCover")][string] $dotCoverResultsFile
  )

  $nUnitRunnerPath = Get-NuGetSolutionPackagePath "NUnit.ConsoleRunner"
  $nUnitRunnerExecutable =  "$nUnitRunnerPath\tools\nunit3-console.exe"
  # It is important that we specify the parameters as separate strings here, otherwise they would be quoted as one ("/framework=net4.5 /labels...")
  # and this would lead to errors when the arguments are parsed by NUnit.
  $nUnitRunnerArguments = @(
    # The /framework value does not have to be exactly correct, it is mainly needed since the NUnit auto detection would use .NET 3.5.
    # Therefore it is only necessary to specify the right major version (in this case 4). However, if problems arise make it a parameter to allow it to 
    # be set from the build script.
    "--framework=net-4.5", 
    "--x86",
    "--labels=On", 
    "--result=$resultsFile")
  
  try {
    if ($withDotCover.IsPresent) {
      _Execute-TestsWithDotCover "NUnit" $nUnitRunnerExecutable $nUnitRunnerArguments $testAssemblies $dotSettingsFile $dotCoverResultsFile
    } else {
      Exec { & $nUnitRunnerExecutable $nUnitRunnerArguments $testAssemblies } -ErrorMessage "NUnit tests have failed"
    } 
  } catch {
    Report-TestError $_
  }
}

function _Execute-TestsWithDotCover {
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory)] [string] $testType, 
    [Parameter(Mandatory)] [string] $testRunnerExecutable, 
    [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $testRunnerArguments, 
    [Parameter(Mandatory)] [string[]] $testAssemblies,
    [Parameter(Mandatory)] [string] $dotSettingsFile, 
    [Parameter(Mandatory)] [string] $dotCoverResultsFile)

  try {
    $dotCoverConfig = _Create-DotCoverConfigurationFile $dotSettingsFile

    _Invoke-DotCover @(
      "cover", 
      $dotCoverConfig, 
      "/TargetExecutable=$testRunnerExecutable", 
      "/TargetArguments=""$testRunnerArguments $testAssemblies""", 
      "/Output=$dotCoverResultsFile"
    ) -ErrorMessage "$testType tests with dotCover Coverage analysis have failed"

    [double] $coveragePercentage = _Get-DotCoverCoveragePercentage $dotCoverResultsFile

    if ($coveragePercentage -lt 100.0) {
      throw "ERROR: Test coverage percentage is less than 100% ($coveragePercentage%)."
    }

    Report-DotCoverCoverageAnalysisResults $dotCoverResultsFile
  } finally {
    Remove-Item $dotCoverConfig
  }
}

function _Invoke-DotCover {
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory)] [string[]] $arguments, 
    [Parameter(Mandatory)] [string] $errorMessage)

  $dotCoverPath = Get-NuGetSolutionPackagePath "JetBrains.dotCover.CommandLineTools"
  $dotCoverExecutable = "$dotCoverPath\tools\dotCover.exe"

  Exec { 
    & $dotCoverExecutable $arguments
  } -ErrorMessage $errorMessage
}

BuildStep Create-DotCoverCoverageBadge -LogMessage "Create-DotCoverCoverageBadge (for '`$(Split-Path -Leaf `$dotCoverResultsFile)')" {
  Param(
    [Parameter(Mandatory)] [string] $dotCoverResultsFile,
    [Parameter(Mandatory)] [string] $dotCoverCoverageBadgeFile)

  $coveragePercentage = _Get-DotCoverCoveragePercentage $dotCoverResultsFile
  $badgeColor = _Get-DotCoverCoverageBadgeColor $coveragePercentage

  Invoke-WebRequest -Uri "https://img.shields.io/badge/coverage-${coveragePercentage}%-${badgeColor}.svg?style=flat" -OutFile $dotCoverCoverageBadgeFile
}

BuildStep Create-DotCoverCoverageReport -LogMessage "Create-DotCoverCoverageReport (for '`$(Split-Path -Leaf `$dotCoverResultsFile)')" {
  Param(
    [Parameter(Mandatory)] [string] $dotCoverResultsFile,
    [Parameter(Mandatory)] [string] $dotCoverCoverageReportFile)

  _Create-DotCoverReport $dotCoverResultsFile $dotCoverCoverageReportFile "HTML"
}

function _Get-DotCoverCoverageBadgeColor {
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory)] [int] $coveragePercentage)

  if ($coveragePercentage -eq 100) {
    return "brightgreen"
  } elseif ($coveragePercentage -ge 90) {
    return "green"
  } elseif ($coveragePercentage -ge 80) {
    return "yellowgreen"
  } elseif ($coveragePercentage -ge 65) {
    return "yellow"
  } elseif ($coveragePercentage -ge 50) {
    return "orange"
  } else {
    return "red"
  }
}

function _Get-DotCoverCoveragePercentage {
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory)] [string] $dotCoverResultsFile)

  try {
    $xmlReportFile = [System.IO.Path]::GetTempFileName()
    _Create-DotCoverReport $dotCoverResultsFile $xmlReportFile "XML"

    [xml] $xmlReport = Get-Content $xmlReportFile

    return $xmlReport.Root.CoveragePercent
  } finally {
    Remove-Item $xmlReportFile
  }
}

function _Create-DotCoverReport {
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory)] [string] $dotCoverResultsFile,
    [Parameter(Mandatory)] [string] $outputFile,
    [Parameter(Mandatory)] [ValidateSet("HTML", "XML")] [string] $reportFormat)

  _Invoke-DotCover @(
      "report", 
      "/Source=$dotCoverResultsFile", 
      "/Output=$outputFile", 
      "/ReportType=$reportFormat"
    ) -ErrorMessage "Creating a $reportFormat report for '$dotCoverResultsFile' failed"
}

function _Create-DotCoverConfigurationFile {
  [CmdletBinding()]
  Param([Parameter(Mandatory)] [string] $dotSettingsFile)

  function Append-Filters($source, $dest, $name) {
    $sourceFilters = @($source | Select-Xml "/data/$name/Filter" | % { $_.Node } )
    $destFilters = $dest.OwnerDocument.CreateElement($name)

    foreach ($sourceFilter in $sourceFilters) {
      if ($sourceFilter.IsEnabled -ne "True") {
        continue
      }

      $destFilter = $dest.OwnerDocument.CreateElement("FilterEntry")

      foreach ($attr in $sourceFilter.Attributes) {
        if ($attr.Name -eq "IsEnabled") {
          continue
        }

        $maskName = $attr.Name
        $mask = $dest.OwnerDocument.CreateElement($maskName)
        $mask.InnerText = $sourceFilter.$maskName
        $destFilter.AppendChild($mask) | Out-Null
      }

      $destFilters.AppendChild($destFilter) | Out-Null
    }

    $dest.AppendChild($destFilters) | Out-Null
  }
  
  function Append-AttributeFilters($source, $dest) {
    $sourceFilters = @($source | Select-Xml "/data/AttributeFilter" | % { $_.Node })
    
    foreach($sourceFilter in $sourceFilters) {
      if ($sourceFilter.IsEnabled -ne "True") {
        continue
      }
      
      $destFilter = $dest.OwnerDocument.CreateElement("AttributeFilterEntry")
      $destFilter.InnerText = $sourceFilter.ClassMask
      $dest.AppendChild($destFilter) | Out-Null
    }
  }
 
  [xml]$dotSettings = Get-Content $dotSettingsFile
  [xml]$filtersSource = ($dotSettings.ResourceDictionary.String | Where { $_.Key -eq "/Default/FilterSettingsManager/CoverageFilterXml/@EntryValue" } | % { $_.InnerText } )
  [xml]$attrFiltersSource = ($dotSettings.ResourceDictionary.String | Where { $_.Key -eq "/Default/FilterSettingsManager/AttributeFilterXml/@EntryValue" } | % { $_.InnerText } )
  
  [xml]$template = "<CoverageParams><Filters></Filters><AttributeFilters></AttributeFilters></CoverageParams>"
  
  if($filtersSource) {
    $filtersDest = ($template | Select-Xml "/CoverageParams/Filters").Node 
    Append-Filters $filtersSource $filtersDest "IncludeFilters"
    Append-Filters $filtersSource $filtersDest "ExcludeFilters"
  }
  
  if($attrFiltersSource) {
    $attrFiltersDest = ($template | Select-Xml "/CoverageParams/AttributeFilters").Node 
    Append-AttributeFilters $attrFiltersSource $attrFiltersDest
  }
  
  $configFile = [System.IO.Path]::GetTempFileName()
  $template.Save($configFile)

  return $configFile
}