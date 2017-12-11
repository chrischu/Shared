BuildStep Restore-NuGetPackagesForSolution {
  Param([Parameter(Mandatory)] [string] $solutionFile)

  Exec { & $NuGetExecutable restore $solutionFile } -ErrorMessage "Could not bootstrap solution '$solutionFile' - failed to restore NuGet packages"
}

BuildStep Create-NuGetPackagesFromSolution -LogMessage 'Create-NuGetPackagesFromSolution in ''$solutionDirectory''' {
  Param(
      [Parameter(Mandatory)] [string] $solutionDirectory, 
      [Parameter(Mandatory)] [Project[]] $projects,
      [Parameter(Mandatory)] [string] $version,
      [Parameter(Mandatory)] [string] $configuration, 
      [Parameter(Mandatory)] [string] $vcsUrlTemplate, 
      [Parameter(Mandatory)] [string] $resultsDirectory,
      [string] $versionSuffix = $null)

  $nuGetPackProjects = $projects | ?{ $_.IsPackable }

  _CreateNuGetPackages `
    -SolutionDirectory $solutionDirectory `
    -NuGetProjects $nuGetPackProjects `
    -Version $version -VersionSuffix $versionSuffix `
    -Configuration $configuration `
    -ResultsDirectory $resultsDirectory
}

function _CreateNuGetPackages {
  [CmdletBinding()]
  Param(
      [Parameter(Mandatory)] [string] $solutionDirectory, 
      [Parameter(Mandatory)] [Project[]] $nuGetProjects,
      [Parameter(Mandatory)] [string] $version, 
      [Parameter(Mandatory)] [string] $configuration, 
      [Parameter(Mandatory)] [string] $resultsDirectory,
      [string] $versionSuffix = $null)

  $msBuildProperties = @{
    "IncludeBuildOutput" = "true";
    "SolutionDir" = $solutionDirectory;
    "Configuration" = $configuration;
    "PackageOutputPath" = $resultsDirectory;
    "VersionPrefix" = $version;
    "VersionSuffix" = $versionSuffix;
    "SourceLinkServerType" = "GitHub";
    "SourceLinkCreate" = "True";
  }

  $formattedMsBuildProperties = Format-MsBuildProperties $msBuildProperties

  # Restore is necessary to workaround a problem with project references 
  # (otherwise when building a pre-release version, referenced projects would only use the version without suffix)
  $msBuildArguments = @("/t:Restore;Pack", "/p:$formattedMsBuildProperties")

  foreach ($project in $nuGetProjects) {
    Push-Location $project.ProjectDir
    Exec { & $MsBuildExecutable $msBuildArguments } -ErrorMessage "Could not create NuGet package for '$($project.ProjectName)'"
    Pop-Location
  }
}

BuildStep Create-NuGetPackageFromNuSpec -LogMessage 'Create-NuGetPackageFromNuSpec ''$nuSpecFile''' {
  Param(
      [Parameter(Mandatory)] [string] $nuSpecFile, 
      [Parameter(Mandatory)] [string] $version, 
      [Parameter(Mandatory)] [string] $resultsDirectory, 
      [switch] $noPackageAnalysis)

  $packageAnalysis = ""
  if($noPackageAnalysis.IsPresent) {
    $packageAnalysis = "-NoPackageAnalysis"
  }

  Exec { 
    & $NuGetExecutable pack $nuSpecFile `
      -Version $version `
      -Properties Configuration=$Configuration `
      -OutputDirectory $resultsDirectory `
      $packageAnalysis 
  } -ErrorMessage "Could not create NuGet package for '$nuSpecFile'"
}

BuildStep Push-AllNuGetPackages -LogMessage 'Push-AllNuGetPackages from ''$packageDirectory'' to ''$targetFeed''' {
  Param(
      [Parameter(Mandatory)] [string] $packageDirectory, 
      [Parameter(Mandatory)] [string] $targetFeed,
      [Parameter(Mandatory)] [string] $nuGetApiKey)

  Exec { & $NuGetExecutable push "$packageDirectory\*.nupkg" -Source $targetFeed -ApiKey $nuGetApiKey } -ErrorMessage "Could not push NuGet packages to '$targetFeed'"
}

function Get-NuGetSolutionPackagePath {
  [CmdletBinding()]
  Param([Parameter(Mandatory)] [string] $solutionPackage)

  $solutionPackagesConfigFile = ".\SolutionPackages\packages.config"

  [xml] $xml = Get-Content $solutionPackagesConfigFile
  $package = $xml.SelectSingleNode("/packages/package[@id = '$solutionPackage']")

  if($package -eq $null) {
    throw "ERROR: Cannot find solution package '$solutionPackage'."
  }

  $version = $package.Version

  return ".\packages\$solutionPackage.$version"
}