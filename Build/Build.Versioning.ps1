$versionTagFormat = '^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$'

class VersionInfo {
  [Version] $Version
  [string] $AssemblyVersion
  [string] $AssemblyFileVersion
  [string] $AssemblyInformationalVersion

  VersionInfo([Version] $lastTagVersion, [int] $commitCount, [bool] $isPreRelease) {
    $this.Version = New-Object Version $lastTagVersion.Major, $lastTagVersion.Minor, $lastTagVersion.Build, $commitCount
    $this.AssemblyFileVersion = "$($lastTagVersion.Major).$($lastTagVersion.Minor).$($lastTagVersion.Build).$commitCount"
    $this.AssemblyVersion = "$($lastTagVersion.Major).0.0.0"
    $this.AssemblyInformationalVersion = "$($lastTagVersion.Major).$($lastTagVersion.Minor).$($lastTagVersion.Build)"

    if($isPreRelease) {
      $this.AssemblyInformationalVersion = "$($this.AssemblyInformationalVersion)-pre$commitCount"
    }
  }
}

function Get-CurrentBranchName {
  return (git rev-parse --abbrev-ref HEAD)
}

function Get-CurrentCommitTag {
  return (git tag -l --points-at HEAD)
}

function Get-CurrentCommitHash {
  return (git rev-parse HEAD)
}

function Get-VersionInfoFromCurrentCommit {
  $lastVersionTag = Get-LastVersionTag
  $commitCount = Get-CommitCountSinceTag $lastVersionTag
  $isPreRelease = Is-PreRelease

  if ($lastVersionTag) {
    $version = Parse-VersionTag $lastVersionTag
  } else {
    $version = (New-Object Version 0, 0, 0)
  }

  return [VersionInfo]::new($version, $commitCount, $isPreRelease)
}

function Get-LastVersionTag {
  $allVersionTags = @((git tag -l v*.*.*) | ?{ $_ -match $versionTagFormat })

  if($allVersionTags) {
    return $allVersionTags[-1]
  }

  return $null
}

function Get-CommitCountSinceTag {
  [CmdletBinding()]
  Param([string] $tag)

  if ($tag) {
    return (git rev-list "${tag}..HEAD" --count) + 1
  } else {
    return (git rev-list HEAD --count) + 1
  }
}

function Is-PreRelease {
  return (Get-CurrentBranchName) -ne "master"
}

function Parse-VersionTag {
  [CmdletBinding()]
  Param([string] $versionTag)

  if (-not ($versionTag -Match $versionTagFormat)) {
    throw "The tag '$versionTag' is not a valid version tag of the form 'v{major}.{minor}.{patch}'."
  }

  return (New-Object Version $matches['major'], $matches['minor'], $matches['patch'])
}