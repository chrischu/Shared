function Exec {
  [CmdletBinding()]
  Param(
      [Parameter(Mandatory)] [ScriptBlock] $command, 
      [Parameter(Mandatory)] [string] $errorMessage, 
      [bool] $failOnErrorCode = $True)

  $expandedCommandString = $ExecutionContext.InvokeCommand.ExpandString($command)
  Write-Host "Executing: $expandedCommandString"

  & $command | Out-Host
  if ($failOnErrorCode -and $LastExitCode -ne 0) {
    throw "BUILD FAILED: $errorMessage (LastExitCode: $LastExitCode)."
  }
}

function Get-BackupFileName {
  [CmdletBinding()]
  Param([Parameter(Mandatory)] [string] $file)

  return "$file.bak"
}

function Backup-File {
  [CmdletBinding()]
  Param([Parameter(Mandatory)] [string] $file)

  Write-Host "Backing up '$file'"

  $backupFile = Get-BackupFileName $file
  Copy-Item $file $backupFile | Out-Null
}

function Restore-File {
  [CmdletBinding()]
  Param([Parameter(Mandatory)] [string] $file)

  $backupFile = Get-BackupFileName $file
  if (Test-Path $backupFile) {
    Write-Host "Restoring '$file'"

    Move-Item -Force $backupFile $file | Out-Null
  }
}

BuildStep Clean-BuildDirectory {
  Param([Parameter(Mandatory)] [string] $buildDirectory)

  if (Test-Path $buildDirectory) {
    Remove-Item $buildDirectory -Recurse -Force
  }
}

class Project {
  [string] $ProjectName
  [string] $ProjectPath
  [string] $ProjectDir
  [string] $Configuration

  [string] $OutDir
  [string] $TargetName
  [string] $TargetPath
  [string] $TargetDir

  Project([string] $name, [string] $path, [string] $configuration) {
    $this.ProjectName = $name
    $this.ProjectPath = $path
    $this.ProjectDir = [System.IO.Path]::GetDirectoryName($path)

    $this.Configuration = $configuration

    # IDEA: This code is duplicated in ContainsXmlNode below, maybe find a way to avoid this duplication.
    [xml] $xml = Get-Content $this.ProjectPath
    [System.Xml.XmlNamespaceManager] $nsmgr = $xml.NameTable
    $nsmgr.AddNamespace("msb", "http://schemas.microsoft.com/developer/msbuild/2003")

    $configurationPropertyGroups = $xml.SelectNodes("//msb:PropertyGroup[contains(@Condition, `"'`$(Configuration)|`$(Platform)' == '$configuration|`")]", $nsmgr)
    if($configurationPropertyGroups.Count -ne 1) {
      throw "Found $($configurationPropertyGroups.Count) property groups for configuration '$configuration' but there should be only one."
    }

    $this.OutDir = $configurationPropertyGroups.OutputPath
    
    $assemblyName = $xml.SelectSingleNode("//msb:AssemblyName", $nsmgr).'#text'

    $outputType = $xml.SelectSingleNode("//msb:OutputType", $nsmgr).'#text'
    $extension = "dll"
    if ($outputType -eq "Exe") {
      $extension = "exe"
    }

    $this.TargetName = "$assemblyName.$extension"
    $this.TargetDir = Join-Path $this.ProjectDir $this.OutDir
    $this.TargetPath = Join-Path $this.TargetDir $this.TargetName
  }

  [bool] ContainsXmlNode([string] $nodeSelector) {
    [xml] $xml = Get-Content $this.ProjectPath
    [System.Xml.XmlNamespaceManager] $nsmgr = $xml.NameTable
    $nsmgr.AddNamespace("msb", "http://schemas.microsoft.com/developer/msbuild/2003")

    $nodes = $xml.SelectNodes($nodeSelector, $nsmgr)

    return $nodes.Count -gt 0
  }
}

function Get-ProjectsFromSolution {
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory)] [string] $solutionFile,
    [Parameter(Mandatory)] [string] $configuration)

  $solutionDirectory = [System.IO.Path]::GetDirectoryName($solutionFile)
  
  $solutionFolderProjectType = "2150E333-8FDC-42A3-9474-1A3956D46DE8"
  $projectRegex = "Project\(`"\{(?<ProjectTypeGuid>[^{]+)\}`"\)\s*=\s*`"(?<Name>[^`"]+)`",\s*`"(?<File>[^`"]+)`""

  $projects = Get-Content $solutionFile | ?{ $_ -match $projectRegex -and $matches["ProjectTypeGuid"] -ne $solutionFolderProjectType } | %{
    $projectName = $matches["Name"]
    $projectFile = Join-Path $solutionDirectory $matches["File"]

    return [Project]::new($projectName, $projectFile, $configuration)
  }

  return $projects
}

function Get-BinDirectory {
  [CmdletBinding()]
  Param(
      [Parameter(Mandatory)] [string] $projectDirectory, 
      [Parameter(Mandatory)] [string] $configuration)

  return "$projectDirectory\bin\$configuration"
}

function Get-PackageDirectory {
  [CmdletBinding()]
  Param(
      [Parameter(Mandatory)] [string] $projectDirectory, 
      [Parameter(Mandatory)] [string] $configuration)

  return "$projectDirectory\obj\$configuration\Package\PackageTmp"
}

BuildStep Update-AssemblyInfo -LogMessage 'Update-AssemblyInfo ''$file''' {
  Param(
    [Parameter(Mandatory)] [string] $file, 
    [Parameter(Mandatory)] [string] $configuration, 
    [Parameter(Mandatory)] [string] $assemblyVersion, 
    [Parameter(Mandatory)] [string] $assemblyFileVersion,
    [Parameter(Mandatory)] [string] $assemblyInformationalVersion)

  Backup-File $file

  Update-File $file {
    $_ -Replace 'AssemblyConfiguration\s*\(".+"\)', ('AssemblyConfiguration ("' + $configuration + '")') `
    -Replace 'AssemblyVersion\s*\(".+"\)', ('AssemblyVersion ("' + $assemblyVersion + '")') `
    -Replace 'AssemblyFileVersion\s*\(".+"\)', ('AssemblyFileVersion ("' + $assemblyFileVersion + '")') `
    -Replace 'AssemblyInformationalVersion\s*\(".+"\)', ('AssemblyInformationalVersion ("' + $assemblyInformationalVersion + '")')
  }
}

function Update-File {
  Param(
      [Parameter(Mandatory)] [string] $file, 
      [Parameter(Mandatory)] [ScriptBlock] $updateLine, 
      [System.Text.Encoding] $encoding = [System.Text.Encoding]::UTF8)

  $lines = [System.IO.File]::ReadAllLines($file, $encoding)

  $updatedLines = $lines | % { & $updateLine $_ }
  $text = $updatedLines -join [Environment]::NewLine

  [System.IO.File]::WriteAllText($file, $text, $encoding)
}

BuildStep Restore-AssemblyInfo -LogMessage 'Restore-AssemblyInfo ''$file''' {
  Param([Parameter(Mandatory)] [string] $file)

  Restore-File $file
}

BuildStep Create-ScreenshotReport {
  Param(
      [Parameter(Mandatory)] [string] $reporterExecutable, 
      [Parameter(Mandatory)] [string] $screenshotDirectory)

  Exec { & $reporterExecutable $screenshotDirectory } -ErrorMessage "Failed to create screenshot reports"
}

BuildStep Prepare-TestConfigFile -LogMessage 'Prepare-TestConfigFile (DataSource=''$dataSource'')' {
  Param(
      [Parameter(Mandatory)] [string] $appConfigFilePath, 
      [Parameter(Mandatory)] [string] $dataSource)

  Update-File $appConfigFilePath {
    $_ -Replace "connectionString\s*=\s*`"Data Source\s*=\s*localhost\s*;", "connectionString=`"Data Source=$dataSource;"
  }
}

BuildStep Prepare-WebTestConfigFile -LogMessage 'Prepare-WebTestConfigFile (Browser=''$browser'', ScreenshotAndLogDirectory=''$screenshotAndLogsDirectory'')' {
  Param(
      [Parameter(Mandatory)] [string] $webAppConfigPath, 
      [Parameter(Mandatory)] [string] $browser, 
      [Parameter(Mandatory)] [string] $screenshotAndLogsDirectory,
      [Parameter(Mandatory)] [string] $webTestLogName) 

  [xml] $xml = Get-Content $webAppConfigPath
  Xml-UpdateAttribute $xml "/configuration/appSettings/add[@key='Browser']" "value" $browser
  Xml-UpdateAttribute $xml "/configuration/appSettings/add[@key='ScreenshotDirectory']" "value" $screenshotAndLogsDirectory
  Xml-UpdateAttribute $xml "/configuration/log4net/appender[@name='FileAppender']/file/conversionPattern" "value" "$screenshotAndLogsDirectory\$webTestLogName.%date{yyyyMMdd}.log"

  $xml.Save($webAppConfigPath)
}

function Xml-UpdateAttribute {
  [CmdletBinding()]
  Param(
      [Parameter(Mandatory)] [xml] $xml, 
      [Parameter(Mandatory)] [string] $xpath, 
      [Parameter(Mandatory)] [string] $attributeName, 
      [Parameter(Mandatory)] [string] $newAttributeValue)

  $elem = $xml.SelectSingleNode($xpath)
  $elem.SetAttribute($attributeName, $newAttributeValue)
}

Add-Type -As System.IO.Compression.FileSystem

function Zip-Directory {
  [CmdletBinding()]
  Param(
      [Parameter(Mandatory)] [string] $zipFilePath, 
      [Parameter(Mandatory)] [string] $sourceDirectory, 
      [System.IO.Compression.CompressionLevel] $compression = "Fastest")

  [System.IO.Compression.ZipFile]::CreateFromDirectory($sourceDirectory, $zipFilePath, $compression, $false)
}

function Ensure-StringEndsWith {
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory)] [string] $string,
    [Parameter(Mandatory)] [char] $char
  )

  if ($string.EndsWith($char)) {
    return $string
  }

  return $string + $char
}