BuildStep Execute-ReSharperCodeInspection {
  Param(
      [Parameter(Mandatory)] [string] $solutionFile,
      [Parameter(Mandatory)] [string] $configuration,
      [Parameter(Mandatory)] [string] $resultsFile)

  $reSharperCommandLineToolsPath = Get-NuGetSolutionPackagePath "JetBrains.ReSharper.CommandLineTools"
  $reSharperInspectCodeExecutable = "$reSharperCommandLineToolsPath\tools\inspectcode.exe"

  # TODO: Use /x=$(reSharperInspectCodeExtensions) again once https://youtrack.jetbrains.com/issue/RSRP-436208 is fixed.
  # $reSharperInspectCodeExtensions = "ReSharper.ImplicitNullability;ReSharper.SerializationInspections;ReSharper.XmlDocInspections"

  Exec { 
    & $reSharperInspectCodeExecutable `
      --caches-home=_ReSharperInspectCodeCache `
      --toolset=$MSBuildToolset `
      -o="$resultsFile" `
      --properties="Configuration=$configuration" `
       $solutionFile
  } -ErrorMessage "ReSharper code inspection failed"

  Report-ReSharperInspectCodeResults $resultsFile

  [xml] $xml = Get-Content $resultsFile
  $numberOfIssues = $xml.CreateNavigator().Evaluate("count(//Issue)")
  Write-Host "ReSharper InspectCode found $numberOfIssues issues."

  if ($numberOfIssues -gt 0) {
    if ($IsRunningLocally) {
      throw "BUILD FAILED: There are $numberOfIssues ReSharper code inspection issues."
    } else {
      TeamCity-BuildProblem "There are $numberOfIssues ReSharper code inspection issues."
    }
  }

  return $numberOfIssues
}