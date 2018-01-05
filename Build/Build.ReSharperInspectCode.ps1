BuildStep Execute-ReSharperCodeInspection {
  Param(
      [Parameter(Mandatory)] [string] $solutionFile,
      [Parameter(Mandatory)] [string] $configuration,
      [Parameter(Mandatory)] [string] $resultsFile,
      [Parameter()] [string] $branchName = "(local)")

  $reSharperCommandLineToolsPath = Get-NuGetSolutionPackagePath "JetBrains.ReSharper.CommandLineTools"
  $reSharperInspectCodeExecutableDir = "$reSharperCommandLineToolsPath\tools"
  $reSharperInspectCodeExecutable = "$reSharperInspectCodeExecutableDir\inspectcode.exe"

  $extensions = @("ReSharper.ImplicitNullability", "ReSharper.SerializationInspections", "ReSharper.XmlDocInspections")
  foreach($ext in $extensions) {
    $extPath = Get-NuGetSolutionPackagePath $ext
    $nupkg = Get-ChildItem "$extPath\*.nupkg"
    Copy-Item $nupkg $reSharperInspectCodeExecutableDir
  }

  $escapedBranchName = $branchName -replace "[^\w\(\)\.-]","_"

  Exec { 
    & $reSharperInspectCodeExecutable `
      --caches-home=_ReSharperInspectCodeCache_$escapedBranchName `
      --toolset=$MSBuildToolset `
      -o="$resultsFile" `
      --properties="Configuration=$configuration" `
       $solutionFile
  } -ErrorMessage "ReSharper code inspection failed"

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
    throw "BUILD FAILED: There are $numberOfIssues ReSharper code inspection issues."
  }

  return $numberOfIssues
}