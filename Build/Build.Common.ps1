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

  [bool] $IsPackable

  Project([string] $name, [string] $path, [string] $configuration) {
    $this.ProjectName = $name
    $this.ProjectPath = $path
    $this.ProjectDir = [System.IO.Path]::GetDirectoryName($path)

    $this.Configuration = $configuration
    
    $globalProperties = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $globalProperties['Configuration'] = $this.Configuration
    $toolsVersion = "15.0";
    
    Load-MicrosoftBuildAssembly
    $project = New-Object 'Microsoft.Build.Evaluation.Project' -ArgumentList @($this.ProjectPath, $globalProperties, $toolsVersion)
    
    $this.OutDir = $project.GetPropertyValue("OutDir")
       
    $assemblyName = $project.GetPropertyValue("AssemblyName")
    $outputType = $project.GetPropertyValue("OutputType")
    $extension = "dll"
    if ($outputType -eq "Exe") {
      $extension = "exe"
    }

    $this.TargetName = "$assemblyName.$extension"
    $this.TargetDir = Join-Path $this.ProjectDir $this.OutDir
    $this.TargetPath = Join-Path $this.TargetDir $this.TargetName

    $this.IsPackable = $project.GetPropertyValue("IsPackable")
  }
}

function Load-MicrosoftBuildAssembly {
  $msBuildExecutableDirectory = Split-Path -Path $MSBuildExecutable 
  $microsoftBuildAssemblyFile = Join-Path $msBuildExecutableDirectory "Microsoft.Build.dll"
  Add-Type -Path $microsoftBuildAssemblyFile
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

function Format-MsBuildProperties {
  [CmdletBinding()]
  Param([Parameter(Mandatory)] [Hashtable] $properties)

  return ($properties.GetEnumerator() | %{ "$($_.Name)=$($_.Value)" }) -join ";"
}