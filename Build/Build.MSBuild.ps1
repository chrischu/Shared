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
      [Parameter(Mandatory)] [boolean] $runFxCopCodeAnalysis,
      [Parameter(Mandatory)] [string] $fxCopResultsDirectory)

  $treatCodeAnalysisWarningsAsErrorsParam = ""
  if ($runFxCopCodeAnalysis) {
    $treatCodeAnalysisWarningsAsErrorsParam = ";CodeAnalysisTreatWarningsAsErrors=True"
  }

  Exec { & $MSBuildExecutable $solutionFile /t:Build /m /nr:False "/p:Configuration=$configuration;TreatWarningsAsErrors=$treatWarningsAsErrors;RunCodeAnalysis=$runFxCopCodeAnalysis$treatCodeAnalysisWarningsAsErrorsParam" } -ErrorMessage "Could not build solution '$solutionFile'"

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