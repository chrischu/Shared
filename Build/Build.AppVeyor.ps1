BuildStep Publish-CoverageReport {
  Param(
    [Parameter(Mandatory)] [string] $version,
    [Parameter(Mandatory)] [string] $coverageBadgeFile,
    [Parameter(Mandatory)] [string] $coverageReportFile)

  $coverageReportDirectory = Join-Path ([System.IO.Path]::GetDirectoryName($coverageReportFile)) ([System.IO.Path]::GetFileNameWithoutExtension($coverageReportFile))

  $targetReportsDirectory = "..\CoverageReports\"
  $targetReportsVersionDirectory = Join-Path $targetReportsDirectory "${version}-temp"

  _Setup-Git

  git fetch -q --all
  git checkout -q $env:APPVEYOR_REPO_BRANCH

  Remove-Item -Confirm:$false -Recurse "Shared"
  git checkout -q gh-pages

  Write-Host "Copying coverage badge"
  Copy-Item -Force $coverageBadgeFile $targetReportsDirectory

  Write-Host "Copying report to main directory"
  Copy-Item -Force $coverageReportFile $targetReportsDirectory
  Copy-Item -Force -Recurse $coverageReportDirectory $targetReportsDirectory

  Write-Host "Copying report to version directory"
  New-Item -ItemType Directory $targetReportsVersionDirectory | Out-Null
  Copy-Item $coverageReportFile $targetReportsVersionDirectory
  Copy-Item -Recurse $coverageReportDirectory $targetReportsVersionDirectory

  git add -A

  git commit -q -m "Added coverage report for v$version."

  git push -q
}

function _Setup-Git {
  git config --global credential.helper store
  Add-Content "$env:USERPROFILE\.git-credentials" "https://$($env:GitHubToken):x-oauth-basic@github.com`n"
  git config --global user.email "pusher@appveyor.com"
  git config --global user.name "AppVeyor Build Pusher"
  git config --global core.safecrlf "false"
  git config --global push.default "simple"
}