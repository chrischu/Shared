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
      [Parameter(Mandatory)] [string] $resultsDirectory)

  # Unfortunately XPath 1.0 does not support ends-with so therefore we have to build our own version of it.
  $endsWith = "{1} = substring({0}, string-length({0}) - string-length({1}) + 1)"
  $nuGetPackProjects = $projects | ? { $_.ContainsXmlNode("//msb:None[$($endsWith -f "@Include", "'.nuspec'")]") }

  try {
    _Create-DummyNuSpecAndDirectoriesForNuGet $solutionDirectory $nuGetPackProjects

    _Insert-PdbSourceLinks $nuGetPackProjects $solutionDirectory $vcsUrlTemplate

    foreach ($project in $nuGetPackProjects) {
      # IDEA: Add parameter for excludes
      Exec { 
        & $NuGetExecutable pack "$($project.ProjectPath)" `
          -Version $version `
          -Properties "Configuration=$configuration;OutputDir=$($project.OutDir)" `
          -IncludeReferencedProjects `
          -OutputDirectory $resultsDirectory
      } -ErrorMessage "Could not create NuGet package for '$($project.ProjectName)'"
    }
  } finally {
    _Remove-DummyNuSpecAndDirectoriesForNuGet $nuGetPackProjects
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

function _Insert-PdbSourceLinks {
  [CmdletBinding()]
  Param(
      [Parameter(Mandatory)] [Project[]] $nuGetPackProjects, 
      [Parameter(Mandatory)] [string] $solutionDirectory, 
      [Parameter(Mandatory)] [string] $vcsUrlTemplate)

  foreach ($project in $nuGetPackProjects) {
    $pdbFile = [System.IO.Path]::ChangeExtension($project.TargetPath, "pdb")

    $remotionMSBuildTasksDll = Join-Path (Get-NuGetSolutionPackagePath "Remotion.BuildTools.MSBuildTasks") "tools\Remotion.BuildTools.MSBuildTasks.dll"
    $insertSourceLinksMsBuildFile = Join-Path $solutionDirectory "InsertSourceLinks.msbuild"

    Exec { 
      & $MSBuildExecutable $insertSourceLinksMsBuildFile `
        /t:InsertSourceLinks `
        "/p:RemotionMSBuildTasksDll=$remotionMSBuildTasksDll;PdbFile=$pdbFile;SolutionDirectory=$solutionDirectory;VcsUrlTemplate=`"$vcsUrlTemplate`"" 
    } -ErrorMessage "Could not insert source links into PDB '$pdbFile'"
  }
}

function _Create-DummyNuSpecAndDirectoriesForNuGet {
  [CmdletBinding()]
  Param(
      [Parameter(Mandatory)] [string] $solutionDirectory, 
      [Parameter(Mandatory)] [Project[]] $nuGetPackProjects)

  _Create-DummyNuSpecFiles $nuGetPackProjects

  # Create special dummy directory as a workaround for a NuGet bug that occurs when NuGet pack is used for projects which are referencing other projects (see https://github.com/NuGet/Home/issues/1299)
  foreach($project in $nuGetPackProjects) {
    $dummyDirectory = Join-Path $solutionDirectory $project.OutDir
    if (-not (Test-Path $dummyDirectory)) {
      New-Item $dummyDirectory -Type Directory | Out-Null
    }
  }
}

function _Remove-DummyNuSpecAndDirectoriesForNuGet {
  [CmdletBinding()]
  Param([Parameter(Mandatory)] [Project[]] $nuGetPackProjects)

  _Remove-DummyNuSpecFiles $nuGetPackProjects

  foreach($project in $nuGetPackProjects) {
    $dummyBaseDirectory = Join-Path $solutionDirectory ($project.OutDir.Split('\')[0]) # we hard code "\" here because this is the convention of the OutDir in .csprojs.
    if (Test-Path $dummyBaseDirectory) {
      if (Get-ChildItem $dummyBaseDirectory -Recurse -File) {
        throw "Didn't expect any files in temporarily created directory '$dummyBaseDirectory'."
      } else {
        Remove-Item $dummyBaseDirectory -Recurse
      }
    }
  }
}

function _Create-DummyNuSpecFiles {
  [CmdletBinding()]
  Param([Parameter(Mandatory)] [Project[]] $nuGetPackProjects)

  # We need a dummy NuSpec file to make sure the referenced projects are recorded correctly.

  foreach ($project in $nuGetPackProjects) {
    $dummyNuSpecFile = [System.IO.Path]::ChangeExtension($project.ProjectPath, "nuspec")
    New-Item $dummyNuSpecFile -Type file | Out-Null
  }
}

function _Remove-DummyNuSpecFiles {
  [CmdletBinding()]
  Param([Parameter(Mandatory)] [Project[]] $nuGetPackProjects)

  foreach ($project in $nuGetPackProjects) {
    $dummyNuSpecFile = [System.IO.Path]::ChangeExtension($project.ProjectPath, "nuspec")
    Remove-Item $dummyNuSpecFile -Force
  }
}