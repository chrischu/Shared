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

  [string] $NuSpecName
  [string] $NuSpecPath

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
      throw "Project '$name': Found $($configurationPropertyGroups.Count) property groups for configuration '$configuration' but there should be only one."
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

    # Unfortunately XPath 1.0 does not support ends-with so therefore we have to build our own version of it.
    $endsWith = "{1} = substring({0}, string-length({0}) - string-length({1}) + 1)"

    $nuSpecNodes = $xml.SelectNodes("//msb:None[$($endsWith -f "@Include", "'.nuspec'")]", $nsmgr)

    if($nuSpecNodes.Count -eq 0){
      $this.NuSpecName = $null
      $this.NuSpecPath = $null
    } elseif ($nuSpecNodes.Count -eq 1) {
      $this.NuSpecPath = Join-Path $this.ProjectDir $nuSpecNodes.Include
      $this.NuSpecName = [System.IO.Path]::GetFileName($this.NuSpecPath)
    } else {
      throw "ERROR: Project '$($this.ProjectName)' should not contain more than one .nuspec file."
    }
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

function Format-Xml([string] $path) {
  [xml] $xml = Get-Content $path

  $xws = New-Object System.Xml.XmlWriterSettings
  $xws.Indent = $true
  $xws.IndentChars = "  "

  $xw = [System.Xml.XmlWriter]::Create($path, $xws)
  $xml.Save($xw)
  $xw.Dispose()
}