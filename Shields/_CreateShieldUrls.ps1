Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ConfirmPreference = "None"
trap { $error[0] | Format-List -Force }

[Reflection.Assembly]::LoadWithPartialName("System.Web") | Out-Null

function GenerateLabelUrl {
  Param([Parameter(Mandatory)] [string] $name)
  
  function Svg2Png {
    Param([Parameter(Mandatory)] [string] $inputFile)
    
    $inkscape = "C:\Program Files\Inkscape\inkscape.exe"
    
    $outputFile = [System.IO.Path]::ChangeExtension($inputFile, "png")
    
    Write-Host "Converting '$inputFile' to '$outputFile'..."
    
    & "$inkscape" --without-gui --file="$inputFile" --export-png="$outputFile" --export-width=64
    
    while (-not (Test-Path $outputFile)) {
      Start-Sleep -Milliseconds 100
    }
    
    return $outputFile
  }
  
  $svgFile = "$PSScriptRoot\$name.svg"
   
  try {
    $png = Svg2Png $svgFile
    
    $bytes = [System.IO.File]::ReadAllBytes($png)
    $base64 = [System.Convert]::ToBase64String($bytes)
  } finally {
    Remove-Item $png
  }
  
  $logo = "data:image/png;base64,$base64"
  $encoded = [System.Web.HttpUtility]::UrlEncode($logo)
  
  $urlFile = [System.IO.Path]::ChangeExtension($svgFile, "txt")
  
  "&logo=$encoded" | Out-File $urlFile
}

GenerateLabelUrl "NuGet"
GenerateLabelUrl "GitHub"
GenerateLabelUrl "AppVeyor"