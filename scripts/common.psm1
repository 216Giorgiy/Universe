$ErrorActionPreference = 'Stop'

function Assert-Git {
    if (!(Get-Command git -ErrorAction Ignore)) {
        Write-Error 'git is required to execute this script'
        exit 1
    }
}

function Invoke-Block([scriptblock]$cmd) {
    $cmd | Out-String | Write-Verbose
    & $cmd

    # Need to check both of these cases for errors as they represent different items
    # - $?: did the powershell script block throw an error
    # - $lastexitcode: did a windows command executed by the script block end in error
    if ((-not $?) -or ($lastexitcode -ne 0)) {
        if(($error -ne $null))
        {
            Write-Warning $error[0]
        }
        throw "Command failed to execute: $cmd"
    }
}

function Get-Submodules {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [switch]$Shipping
    )

    $moduleConfigFile = Join-Path $RepoRoot ".gitmodules"
    $submodules = @()

    [xml] $submoduleConfig = Get-Content "$RepoRoot/build/submodules.props"
    $repos = $submoduleConfig.Project.ItemGroup.Repository | % { $_.Include }

    Get-ChildItem "$RepoRoot/modules/*" -Directory `
        | ? { (-not $Shipping) -or $($repos -contains $($_.Name)) -or $_.Name -eq 'Templating' } `
        | % {
        Push-Location $_ | Out-Null
        Write-Verbose "Attempting to get submodule info for $_"

        if (Test-Path 'version.props') {
            [xml] $versionXml = Get-Content 'version.props'
            $versionPrefix = $versionXml.Project.PropertyGroup.VersionPrefix | select-object -first 1
            $versionSuffix = $versionXml.Project.PropertyGroup.VersionSuffix | select-object -first 1
        }
        else {
            $versionPrefix = ''
            $versionSuffix = ''
        }

        try {
            $data = [PSCustomObject] @{
                path          = $_
                module        = $_.Name
                commit        = $(git rev-parse HEAD)
                newCommit     = $null
                changed       = $false
                remote        = $(git config remote.origin.url)
                branch        = $(git config -f $moduleConfigFile --get submodule.modules/$($_.Name).branch )
                versionPrefix = $versionPrefix
                versionSuffix = $versionSuffix
            }

            $submodules += $data
        }
        finally {
            Pop-Location | Out-Null
        }
    }

    return $submodules
}

function SaveXml([xml]$xml, [string]$path) {
    Write-Verbose "Saving to $path"
    $ErrorActionPreference = 'stop'

    $settings = New-Object System.XML.XmlWriterSettings
    $settings.OmitXmlDeclaration = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding( $true )
    $writer = [System.XML.XMLTextWriter]::Create($path, $settings)
    $xml.Save($writer)
    $writer.Close()
}

function LoadXml([string]$path) {
    Write-Verbose "Reading from $path"

    $ErrorActionPreference = 'stop'
    $obj = new-object xml
    $obj.PreserveWhitespace = $true
    $obj.Load($path)
    return $obj
}

function PackageIdVarName([string]$packageId) {
    $canonicalVarName = ''
    $upperCaseNext = $true
    for ($i = 0; $i -lt $packageId.Length; $i++) {
        $ch = $packageId[$i]
        if (-not [System.Char]::IsLetterOrDigit(($ch))) {
            $upperCaseNext = $true
            continue
        }
        if ($upperCaseNext) {
            $ch = [System.Char]::ToUpperInvariant($ch)
            $upperCaseNext = $false
        }
        $canonicalVarName += $ch
    }
    $canonicalVarName += "PackageVersion"
    return $canonicalVarName
}

function Ensure-Hub() {
    $tmpDir = "$PSScriptRoot\tmp"
    $zipDir = "$tmpDir\Hub"
    $hubLocation = "$zipDir\bin\hub.exe"

    if (-Not (Test-Path $hubLocation) ) {
        $source = "https://github.com/github/hub/releases/download/v2.3.0-pre9/hub-windows-amd64-2.3.0-pre9.zip"
        $zipLocation = "$tmpDir\hub.zip"

        mkdir -Path $tmpDir -ErrorAction Ignore | Out-Null

        Invoke-WebRequest -OutFile $zipLocation -Uri $source

        Expand-Archive -Path $zipLocation -DestinationPath $zipDir -Force
        if (-Not (Test-Path $hubLocation)) {
            throw "Hub couldn't be downloaded"
        }
    }

    return $hubLocation
}

function CreatePR(
    [string]$baseFork,
    [string]$headFork,
    [string]$baseBranch,
    [string]$destinationBranch,
    [string]$body,
    [string]$gitHubToken) {
    $hubLocation = Ensure-Hub

    Invoke-Block { git push -f https://$gitHubToken@github.com/$headFork/Universe.git $destinationBranch }
    & $hubLocation pull-request -f -b "${baseFork}:$baseBranch" -h "${headFork}:$destinationBranch" -m $body
}

function Set-GithubInfo(
    [string]$GitHubPassword,
    [string]$GitHubUser,
    [string]$GitHubEmail)
{
    $Env:GITHUB_TOKEN = $GitHubPassword
    $Env:GITHUB_USER = $GitHubUser
    $Env:GITHUB_EMAIL = $GitHubEmail
}
function CommitUpdatedVersions(
    [hashtable]$updatedVars,
    [xml]$dependencies,
    [string]$depsPath)
{
    $count = $updatedVars.Count
    if ($count -gt 0) {
        & git add build\dependencies.props
        & git add build\tools.props

        $subject = "Updating external dependencies"

        Invoke-Block { & git commit -m $subject } | Out-Null

        $body = "$subject`n`n"

        $body += "New versions:`n"

        foreach ($var in $updatedVars.GetEnumerator()) {
            $body += "    $($var.Name)`n"
        }

        return $body
    }
}

function UpdateVersions([hashtable]$variables, [xml]$dependencies, [string]$depsPath) {
    $updatedVars = @{}

    foreach ($varName in ($variables.Keys | sort)) {
        $packageVersions = $variables[$varName]
        if ($packageVersions.Length -gt 1) {
            Write-Warning "Skipped $varName. Multiple version found. { $($packageVersions -join ', ') }."
            continue
        }

        $packageVersion = $packageVersions | Select-Object -First 1

        $depVarNode = $dependencies.SelectSingleNode("//PropertyGroup[`@Label=`"Package Versions: Auto`"]/$varName")
        if ($depVarNode -and $depVarNode.InnerText -ne $packageVersion) {
            $depVarNode.InnerText = $packageVersion
            Write-Host -f DarkGray "   Updating $varName to $packageVersion"
            $updatedVars[$varName] = $packageVersion
        }
        elseif ($depVarNode) {
            Write-Host -f DarkBlue "   Didn't update $varName to $packageVersion because it was $($depVarNode.InnerText)"
        }
        else {
            # This isn't a dependency we use
        }
    }

    if ($updatedVars.Count -gt 0) {
        Write-Host -f Cyan "Updating version variables in $depsPath"
        SaveXml $dependencies $depsPath
    }
    else {
        Write-Host -f Green "No changes found"
    }

    return $updatedVars
}
