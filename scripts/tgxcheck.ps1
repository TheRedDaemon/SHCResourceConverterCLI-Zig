# Helper script to check tgx extract and pack.
# @author: gynt (2024)

param (
  [Parameter(Mandatory = $true)][string]$Source,
  [Parameter(Mandatory = $true)][string]$Destination,
  [Parameter(Mandatory = $true)][string]$Converter,
  [Parameter(Mandatory = $false)][string]$Suffix = ""
)

$ErrorActionPreference = 'Stop'

$TGXSource = Get-Item -Path "$Source"
if ($true -ne (Test-Path -Path "$Destination")) {
  $TGXDestination = New-Item -ItemType Directory -Path "$Destination"
}
else {
  $TGXDestination = Get-Item -Path "$Destination"
}

Write-Host "Source: $TGXSource"
Write-Host "Destination: $TGXDestination"

function DiscoverTGXFiles {
  param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.DirectoryInfo]$Folder
  )
  
  Get-ChildItem -Path $Folder -Recurse -Include "*.tgx"
}

function ExtractTGXFile {
  param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.FileInfo]$File,
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.DirectoryInfo]$Folder
  )

  & "$Converter" extract "$($File.FullName)" "$($Folder.FullName)"
}

function PackTGXFile {
  param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.DirectoryInfo]$Folder,
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.FileInfo]$File
  )

  & "$Converter" pack "$($Folder.FullName)" "$($File.FullName)" 
}

function ComparePathsEquality {
  param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.FileSystemInfo]$A,
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.FileSystemInfo]$B
  )

  $an = Join-Path $A.FullName "" -Resolve
  $bn = Join-Path $B.FullName "" -Resolve

  return "$an" -eq "$bn"
}

function RelativePathTo {
  param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.FileInfo]$File,
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.DirectoryInfo]$Folder,
    [Parameter(Mandatory = $false)][bool]$IncludeBaseName = $true
  )

  Write-Host "$File"
  
  $Current = $File.Directory
  if ($IncludeBaseName) {
    $Result = "$($File.BaseName)"
  }
  else {
    $Result = ""
  }

  while ($false -eq (ComparePathsEquality -A $Current -B $Folder)) {
    $Result = Join-Path $Current.Name $Result

    $Current = $Current.Parent
  }

  return $Result
}

function RoundTripTGXFile {
  param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.FileInfo]$File,
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.DirectoryInfo]$Source,
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][System.IO.DirectoryInfo]$Destination
  )
  
  $relativeFolderWithName = RelativePathTo -File $File -Folder $Source

  $resolvedDestinationFolderPath = Join-Path $Destination $relativeFolderWithName

  $tgxFolder = New-Item -ItemType Directory -Path $resolvedDestinationFolderPath
  #$resolvedDestinationFolder = Get-Item -Path $resolvedDestinationFolderPath
  
  Write-Host "Extract '$File' to '$tgxFolder'"
  ExtractTGXFile -File $File -Folder $tgxFolder

  if ($Suffix -ne "") {
    $packedFileName = "$($tgxFolder.Name)-$($Suffix).tgx"
  }
  else {
    $packedFileName = "$($tgxFolder.Name).tgx"
  }
  
  $packedTGXFilePath = Join-Path $tgxFolder "$packedFileName"

  Write-Host "Pack '$tgxFolder' to '$packedTGXFilePath'"
  PackTGXFile -Folder $tgxFolder -File $packedTGXFilePath

  $packedTGXFile = Get-Item -Path $packedTGXFilePath

  return $packedTGXFile
}

if ($true -eq (ComparePathsEquality -A $TGXSource -B $TGXDestination)) {
  if ($Suffix -eq "") {
    Write-Error "If Source is equal to Destination, an empty Suffix is not allowed as it would mean .tgx files are overwritten"
    return 1
  }
}

$tgxFiles = $TGXSource | DiscoverTGXFiles

$results = $tgxFiles | ForEach-Object {
  Write-Host "Round tripping: $_"
  $r = RoundTripTGXFile -File $_ -Source $TGXSource -Destination $TGXDestination
  Write-Host "Create hashes of '$_' and '$r'"
  $rHash = $r | Get-FileHash -Algorithm SHA1
  $oHash = $_ | Get-FileHash -Algorithm SHA1
  return @{
    original      = $_
    roundtrip     = $r
    originalHash  = $oHash.Hash
    roundtripHash = $rHash.Hash
  }
}

Write-Host "*** REPORT ***"

$mismatches = $results | Where-Object { $_.originalHash -ne $_.roundtripHash } | ForEach-Object { return $_.original.Name }

$mismatches | Write-Host -ForegroundColor Red

Write-Host "Mismatches: $($mismatches.Length)/$($tgxFiles.Length)"