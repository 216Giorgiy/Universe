
[CmdletBinding()]
param(
    [string]$GitHubEmail,
    [string]$GitHubUsername,
    [string]$GithubToken
)

$ErrorActionPreference = 'Stop'
Import-Module -Scope Local -Force "$PSScriptRoot/common.psm1"
Set-StrictMode -Version 1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$githubRaw = "https://raw.githubusercontent.com"
$versionsRepo = "dotnet/versions"
$versionsBranch = "master"

$coreSetupRepo = "dotnet/core-setup"
$coreFxRepo = "dotnet/corefx"

$coreSetupVersions = "$githubRaw/$versionsRepo/$versionsBranch/build-info/$coreSetupRepo/master/Latest_Packages.txt"

$tempDir = "$PSScriptRoot/../obj"
$localCoreSetupVersions = "$tempDir/coresetup.packages"
Write-Host "Downloading $coreSetupVersions to $localCoreSetupVersions"
Invoke-WebRequest -OutFile $localCoreSetupVersions -Uri $coreSetupVersions

$msNetCoreAppPackageVersion = $null
$msNetCoreAppPackageName = "Microsoft.NETCore.App"

Set-GitHubInfo $GithubToken $GitHubUsername $GitHubEmail

$variables = @{}

foreach ($line in Get-Content $localCoreSetupVersions) {
    if ($line.StartsWith("$msNetCoreAppPackageName ")) {
        $msNetCoreAppPackageVersion = $line.Trim("$msNetCoreAppPackageName ")
    }
    $parts = $line.Split(' ')
    $packageName = $parts[0]

    $varName = "$packageName" + "PackageVersion"
    $varName = $varName.Replace('.', '')

    $packageVersion = $parts[1]
    if ($variables[$varName]) {
        if ($variables[$varName].Where( {$_ -eq $packageVersion}, 'First').Count -eq 0) {
            $variables[$varName] += $packageVersion
        }
    }
    else {
        $variables[$varName] = @($packageVersion)
    }
}

if (!$msNetCoreAppPackageVersion) {
    Throw "$msNetCoreAppPackageName was not in $coreSetupVersions"
}

$coreAppDownloadLink = "https://dotnet.myget.org/F/dotnet-core/api/v2/package/$msNetCoreAppPackageName/$msNetCoreAppPackageVersion"
$netCoreAppNupkg = "$tempDir/microsoft.netcore.app.zip"
Invoke-WebRequest -OutFile $netCoreAppNupkg -Uri $coreAppDownloadLink
$expandedNetCoreApp = "$tempDir/microsoft.netcore.app/"
Expand-Archive -Path $netCoreAppNupkg -DestinationPath $expandedNetCoreApp -Force
$versionsTxt = "$expandedNetCoreApp/$msNetCoreAppPackageName.versions.txt"

$versionsCoreFxCommit = $null
foreach ($line in Get-Content $versionsTxt) {
    if ($line.StartsWith("dotnet/versions/corefx")) {
        $versionsCoreFxCommit = $line.Split(' ')[1]
        break
    }
}

if (!$versionsCoreFxCommit) {
    Throw "no 'dotnet/versions/corefx' in versions.txt of Microsoft.NETCore.App"
}

$coreFxVersionsUrl = "$githubRaw/$versionsRepo/$versionsCoreFxCommit/build-info/$coreFxRepo/$versionsBranch/Latest_Packages.txt"
$localCoreFxVersions = "$tempDir/$corefx.packages"
Invoke-WebRequest -OutFile $localCoreFxVersions -Uri $coreFxVersionsUrl

foreach ($line in Get-Content $localCoreFxVersions) {
    $parts = $line.Split(' ')

    $packageName = $parts[0]

    $varName = "$packageName" + "PackageVersion"
    $varName = $varName.Replace('.', '')
    $packageVersion = $parts[1]
    if ($variables[$varName]) {
        if ($variables[$varName].Where( {$_ -eq $packageVersion}, 'First').Count -eq 0) {
            $variables[$varName] += $packageVersion
        }
    }
    else {
        $variables[$varName] = @($packageVersion)
    }
}

$depsPath = Resolve-Path "$PSScriptRoot/../build/dependencies.props"
Write-Host "Loading deps from $depsPath"
[xml] $dependencies = LoadXml $depsPath

$remote = "origin"
$baseBranch = "dev"

$currentBranch = Invoke-Block { & git rev-parse --abbrev-ref HEAD }
$destinationBranch = "rybrande/UpgradeDepsTest"

Invoke-Block { & git checkout -tb $destinationBranch "$remote/$baseBranch" }
try {
    $updatedVars = UpdateVersions $variables $dependencies $depsPath
    $body = CommitUpdatedVersions $updatedVars $dependencies $depsPath

    if ($body) {
        CreatePR $baseBranch $destinationBranch $body $GithubToken
    }
}
finally {
    Invoke-Block { & git checkout $currentBranch }
}
