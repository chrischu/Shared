# It is important that there is either no enviroment variable "VisualStudioVersion" or it is set to at least "14.0", 
# otherwise building/cleaning solutions that require the VSSDK won't work anymore.

BuildStep Clean-Solution {
  Param([Parameter(Mandatory)] [string] $solutionFile)

  Exec { & $MSBuildExecutable $solutionFile /t:Clean /m /nr:False } -ErrorMessage "Could not clean solution '$solutionFile'"
}

BuildStep Build-Solution {
  Param(
      [Parameter(Mandatory)] [string] $solutionFile, 
      [Parameter(Mandatory)] [Project[]] $projects,
      [Parameter(Mandatory)] [string] $configuration, 
      [Parameter(Mandatory)] [boolean] $treatWarningsAsErrors, 
      [string] $versionPrefix = $null,
      [string] $versionSuffix = $null,
      [boolean] $runFxCopCodeAnalysis = $false,
      [string] $fxCopResultsDirectory = $null)

  $msBuildProperties = @{
    "Configuration" = $configuration;
    "TreatWarningsAsErrors" = $treatWarningsAsErrors;
    "RunCodeAnalysis" = $runFxCopCodeAnalysis;
    "SourceLinkServerType" = "GitHub";
    "SourceLinkCreate" = "True";
  }

  if ($runFxCopCodeAnalysis) {
    $msBuildProperties.Add("CodeAnalysisTreatWarningsAsErrors", "True")
  }

  if($version) {
    $msBuildProperties.Add("VersionPrefix", $version)

    if($versionSuffix) {
      $msBuildProperties.Add("VersionSuffix", $versionSuffix)
    }
  }

  $formattedMsBuildProperties = Format-MsBuildProperties $msBuildProperties
  
  Exec { & $MSBuildExecutable $solutionFile /t:Build /m /nr:False "/p:$formattedMsBuildProperties" } -ErrorMessage "Could not build solution '$solutionFile'"

  if($runFxCopCodeAnalysis) {
    $fxCopResultsFiles = $projects | % { "$($_.TargetPath).CodeAnalysisLog.xml" }
    foreach ($fxCopResultsFile in $fxCopResultsFiles) {
      Move-Item $fxCopResultsFile $FxCopResultsDirectory
    }

    Get-ChildItem $FxCopResultsDirectory | % { Report-FxCopCodeAnalysisResults $_.FullName }
  }
}

BuildStep Package-Projects {
  Param(
      [Parameter(Mandatory)] [string] $solutionDirectory, 
      [Parameter(Mandatory)] [Project[]] $projects, 
      [Parameter(Mandatory)] [string] $configuration)

  # We explicitly use '\' here (instead of sth like Path.DirectorySeparatorChar) because it is a convention in
  # MSBuild to use backslashes for directory separators.
  $solutionDirectory = Ensure-StringEndsWith $solutionDirectory '\'

  foreach ($project in $projects) {
    Exec { & $MSBuildExecutable "$($project.ProjectPath)" /t:Package /m /nr:False "/p:Configuration=$configuration;SolutionDir=$solutionDirectory" } -ErrorMessage "Could not package project '$($project.ProjectName)'"
  }
}

BuildStep Apply-XdtTransform {
  Param(
    [Parameter(Mandatory)] [Project] $project,
    [Parameter(Mandatory)] [string] $file,
    [Parameter(Mandatory)] [string] $transform
  )

  try {
    $transformProject = Join-Path $project.ProjectDir "Transform.proj"
    Write-Host "TFP: $transformProject"
    $transformContent = @"
<Project ToolsVersion="$MSBuildToolset" DefaultTargets="Transform" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <UsingTask TaskName="TransformXml" AssemblyFile="`$(MSBuildExtensionsPath)\Microsoft\VisualStudio\v$MSBuildToolset\Web\Microsoft.Web.Publishing.Tasks.dll"/>
  <Target Name="Transform">
    <TransformXml Source="$file" Transform="$transform" Destination="$file"/>
  </Target>
</Project>
"@
    
    Set-Content -Path $transformProject -Value $transformContent

    Exec { & $MSBuildExecutable $transformProject /t:Transform /m /nr:False } -ErrorMessage "Could not transform file '$file'"

  } finally {
    Remove-Item $transformProject
  }
}