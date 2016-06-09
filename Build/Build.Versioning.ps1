function Get-CurrentBranchName {
  return (git rev-parse --abbrev-ref HEAD)
}

function Get-CurrentCommitHash {
  return (git rev-parse HEAD)
}