$versionTagFormat = '^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$'

function Get-VersionFromCurrentCommit {
  $lastVersionTag = Get-LastVersionTag
  $commitCount = Get-CommitCountSinceTag $lastVersionTag

  if ($lastVersionTag) {
    return Parse-VersionTag $lastVersionTag $commitCount
  } else {
    return (New-Object Version 0, 0, 0, $commitCount)
  }
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
    return [int](git rev-list "${tag}..HEAD" --count)
  } else {
    return [int](git rev-list HEAD --count)
  }
}

function Parse-VersionTag {
  [CmdletBinding()]
  Param([string] $versionTag, [int] $commitCount)

  if (-not ($versionTag -Match $versionTagFormat)) {
    throw "The tag '$versionTag' is not a valid version tag of the form 'v{major}.{minor}.{patch}'."
  }

  return (New-Object Version $matches['major'], $matches['minor'], $matches['patch'], $commitCount)
}

return Get-VersionFromCurrentCommit