#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+([-.+][A-Za-z0-9.-]+)?$')]
    [string] $Version,

    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\release'),

    [switch] $SkipMsi,

    [switch] $RequireMsi,

    [string] $WixVersion = '7.0.0',

    [switch] $AcceptWixEula
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputRootPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
$stageRoot = Join-Path $outputRootPath 'stage'
$packageRoot = Join-Path $stageRoot 'WindowsAutoProfiles'
$wixRoot = Join-Path $outputRootPath 'wix'
$artifactBaseName = "WindowsAutoProfiles-$Version"
$zipPath = Join-Path $outputRootPath "$artifactBaseName.zip"
$msiPath = Join-Path $outputRootPath "$artifactBaseName.msi"

function ConvertTo-WapMsiVersion {
    param([Parameter(Mandatory)][string] $PackageVersion)

    $match = [regex]::Match($PackageVersion, '^(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) {
        throw "Version '$PackageVersion' must start with major.minor.patch for MSI packaging."
    }
    return "$($match.Groups[1].Value).$($match.Groups[2].Value).$($match.Groups[3].Value)"
}

function ConvertTo-WapXmlText {
    param([AllowNull()][string] $Value)

    if ($null -eq $Value) { return '' }
    return [System.Security.SecurityElement]::Escape($Value)
}

function ConvertTo-WapWixId {
    param([Parameter(Mandatory)][string] $Value)

    $id = [regex]::Replace($Value, '[^A-Za-z0-9_.]', '_')
    if ($id -notmatch '^[A-Za-z_]') { $id = "_$id" }
    if ($id.Length -gt 60) { $id = $id.Substring(0, 60) }
    return $id
}

function New-WapDeterministicGuid {
    param([Parameter(Mandatory)][string] $Key)

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Key.ToLowerInvariant())
        $hash = $md5.ComputeHash($bytes)
        $guidBytes = New-Object byte[] 16
        [Array]::Copy($hash, $guidBytes, 16)
        $guid = New-Object -TypeName System.Guid -ArgumentList (,$guidBytes)
        return $guid.ToString('B').ToUpperInvariant()
    }
    finally {
        $md5.Dispose()
    }
}

function Copy-WapPackageItem {
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][string] $DestinationRoot
    )

    $source = Join-Path $repositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source)) { return }
    $destination = Join-Path $DestinationRoot $RelativePath
    $parent = Split-Path -Parent $destination
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

function New-WapCommandShim {
    param([Parameter(Mandatory)][string] $DestinationRoot)

    $shimPath = Join-Path $DestinationRoot 'wap.cmd'
    @(
        '@echo off'
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0wap.ps1" %*'
    ) | Set-Content -LiteralPath $shimPath -Encoding ASCII
}

function New-WapWixSource {
    param(
        [Parameter(Mandatory)][string] $SourceRoot,
        [Parameter(Mandatory)][string] $DestinationPath,
        [Parameter(Mandatory)][string] $PackageVersion
    )

    $componentRefs = New-Object System.Collections.Generic.List[string]
    $componentIndex = 0
    $directoryIndex = 0

    function Write-WapDirectoryXml {
        param(
            [Parameter(Mandatory)][string] $DirectoryPath,
            [Parameter(Mandatory)][string] $DirectoryId,
            [Parameter(Mandatory)][string] $DirectoryName,
            [Parameter(Mandatory)][int] $IndentLevel,
            [switch] $IsInstallFolder
        )

        $indent = ' ' * $IndentLevel
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("$indent<Directory Id=`"$(ConvertTo-WapXmlText $DirectoryId)`" Name=`"$(ConvertTo-WapXmlText $DirectoryName)`">")

        if ($IsInstallFolder) {
            $componentRefs.Add('cmp_UserPath')
            $lines.Add("$indent  <Component Id=`"cmp_UserPath`" Guid=`"$(New-WapDeterministicGuid 'component:path')`">")
            $lines.Add("$indent    <Environment Id=`"env_UserPath`" Name=`"PATH`" Value=`"[INSTALLFOLDER]`" Permanent=`"no`" Part=`"last`" Action=`"set`" System=`"no`" />")
            $lines.Add("$indent    <RegistryValue Root=`"HKCU`" Key=`"Software\WindowsAutoProfiles`" Name=`"InstallDir`" Type=`"string`" Value=`"[INSTALLFOLDER]`" KeyPath=`"yes`" />")
            $lines.Add("$indent  </Component>")
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $DirectoryPath -File | Sort-Object Name)) {
            $script:componentIndex++
            $sourceRootPrefix = $SourceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            $relative = $file.FullName.Substring($sourceRootPrefix.Length).Replace('\', '/')
            $componentId = "cmp_$('{0:D5}' -f $script:componentIndex)_$(ConvertTo-WapWixId $file.BaseName)"
            $fileId = "fil_$('{0:D5}' -f $script:componentIndex)_$(ConvertTo-WapWixId $file.BaseName)"
            $componentRefs.Add($componentId)
            $lines.Add("$indent  <Component Id=`"$(ConvertTo-WapXmlText $componentId)`" Guid=`"$(New-WapDeterministicGuid "component:$relative")`">")
            $lines.Add("$indent    <File Id=`"$(ConvertTo-WapXmlText $fileId)`" Source=`"$(ConvertTo-WapXmlText $file.FullName)`" KeyPath=`"yes`" />")
            $lines.Add("$indent  </Component>")
        }

        foreach ($directory in @(Get-ChildItem -LiteralPath $DirectoryPath -Directory | Sort-Object Name)) {
            $script:directoryIndex++
            $childId = "dir_$('{0:D5}' -f $script:directoryIndex)_$(ConvertTo-WapWixId $directory.Name)"
            $childLines = Write-WapDirectoryXml -DirectoryPath $directory.FullName -DirectoryId $childId -DirectoryName $directory.Name -IndentLevel ($IndentLevel + 2)
            foreach ($childLine in $childLines) { $lines.Add($childLine) }
        }

        $lines.Add("$indent</Directory>")
        return $lines
    }

    $script:componentIndex = 0
    $script:directoryIndex = 0
    $msiVersion = ConvertTo-WapMsiVersion -PackageVersion $PackageVersion
    $upgradeCode = '{7D24E4A7-FEC1-47C7-AE92-5C1E4F5DF0A0}'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $lines.Add('<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">')
    $lines.Add("  <Package Name=`"WindowsAutoProfiles`" Manufacturer=`"WindowsAutoProfiles`" Version=`"$(ConvertTo-WapXmlText $msiVersion)`" UpgradeCode=`"$upgradeCode`" Scope=`"perUser`">")
    $lines.Add('    <MajorUpgrade DowngradeErrorMessage="A newer version of WindowsAutoProfiles is already installed." />')
    $lines.Add('    <MediaTemplate EmbedCab="yes" />')
    $lines.Add('    <StandardDirectory Id="LocalAppDataFolder">')
    $directoryLines = Write-WapDirectoryXml -DirectoryPath $SourceRoot -DirectoryId 'INSTALLFOLDER' -DirectoryName 'WindowsAutoProfiles' -IndentLevel 6 -IsInstallFolder
    foreach ($line in $directoryLines) { $lines.Add($line) }
    $lines.Add('    </StandardDirectory>')
    $lines.Add('    <Feature Id="Main" Title="WindowsAutoProfiles" Level="1">')
    foreach ($componentRef in @($componentRefs | Sort-Object -Unique)) {
        $lines.Add("      <ComponentRef Id=`"$(ConvertTo-WapXmlText $componentRef)`" />")
    }
    $lines.Add('    </Feature>')
    $lines.Add('  </Package>')
    $lines.Add('</Wix>')

    New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationPath) -Force | Out-Null
    $lines | Set-Content -LiteralPath $DestinationPath -Encoding UTF8
}

function Get-WapWixCommand {
    param(
        [Parameter(Mandatory)][string] $ToolRoot,
        [Parameter(Mandatory)][string] $Version
    )

    $wix = Get-Command wix -ErrorAction SilentlyContinue
    if ($wix) {
        return $wix.Source
    }

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        throw "WiX Toolset CLI 'wix' was not found, and the .NET SDK CLI 'dotnet' is not available to install it. Install the .NET SDK or rerun with -SkipMsi."
    }

    $sdkList = @(& $dotnet.Source --list-sdks)
    if ($LASTEXITCODE -ne 0 -or -not $sdkList.Count) {
        throw "WiX Toolset CLI 'wix' was not found, and no .NET SDK is available to install it. Install the .NET SDK or rerun with -SkipMsi."
    }

    $wixToolRoot = Join-Path $ToolRoot 'wix'
    New-Item -ItemType Directory -Path $wixToolRoot -Force | Out-Null

    Write-Host "WiX Toolset CLI 'wix' was not found. Installing WiX Toolset CLI $Version under '$wixToolRoot'..."
    & $dotnet.Source tool install wix --version $Version --tool-path $wixToolRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install WiX Toolset CLI with dotnet tool install. Rerun with -SkipMsi to build only the ZIP package."
    }

    $localWix = Join-Path $wixToolRoot 'wix.exe'
    if (-not (Test-Path -LiteralPath $localWix)) {
        throw "WiX Toolset CLI installation completed, but '$localWix' was not found."
    }

    return $localWix
}

if (Test-Path -LiteralPath $outputRootPath) {
    Remove-Item -LiteralPath $outputRootPath -Recurse -Force
}
New-Item -ItemType Directory -Path $packageRoot, $wixRoot -Force | Out-Null

foreach ($item in @('wap.ps1', 'README.md', 'src', 'docs', 'profiles', 'templates')) {
    Copy-WapPackageItem -RelativePath $item -DestinationRoot $packageRoot
}
foreach ($optionalItem in @('LICENSE', 'LICENSE.md', 'NOTICE', 'NOTICE.md')) {
    Copy-WapPackageItem -RelativePath $optionalItem -DestinationRoot $packageRoot
}
New-WapCommandShim -DestinationRoot $packageRoot

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -Force
Write-Host "Created ZIP package: $zipPath"

if (-not $SkipMsi) {
    try {
        $wixCommand = Get-WapWixCommand -ToolRoot (Join-Path $outputRootPath 'tools') -Version $WixVersion
        $wxsPath = Join-Path $wixRoot 'WindowsAutoProfiles.wxs'
        New-WapWixSource -SourceRoot $packageRoot -DestinationPath $wxsPath -PackageVersion $Version
        $wixBuildArgs = @('build')
        if ($AcceptWixEula) {
            $wixBuildArgs += @('-acceptEula', 'wix7')
        }
        $wixBuildArgs += @($wxsPath, '-out', $msiPath)
        & $wixCommand @wixBuildArgs
        if ($LASTEXITCODE -ne 0) {
            throw "WiX build failed with exit code $LASTEXITCODE."
        }
        Write-Host "Created MSI package: $msiPath"
    }
    catch {
        if ($RequireMsi) {
            throw
        }
        Write-Warning "Skipping MSI package: $($_.Exception.Message)"
    }
}

Get-ChildItem -LiteralPath $outputRootPath -File |
    Where-Object { $_.Extension -in @('.zip', '.msi') } |
    Select-Object Name, Length, FullName |
    Format-Table -AutoSize
