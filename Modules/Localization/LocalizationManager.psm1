Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:LocalizationValues = @{}
function Initialize-Localization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,
        [AllowNull()]
        [pscustomobject]$Configuration
    )
    $script:LocalizationValues = @{}
    if ($null -eq $Configuration) {
        return $false
    }
    $directory = [Environment]::ExpandEnvironmentVariables(
        [string]$Configuration.Directory
    )
    if (-not [IO.Path]::IsPathRooted($directory)) {
        $directory = Join-Path $ProjectRoot $directory
    }
    $path = Join-Path $directory (
        '{0}.ini' -f [string]$Configuration.Language
    )
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $false
    }
    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or
            $trimmed.StartsWith(';') -or
            $trimmed.StartsWith('#')) {
            continue
        }
        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) {
            continue
        }
        $key = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1)
        $script:LocalizationValues[$key] = $value.Replace(
            '\n', "`n"
        ).Replace('\r', "`r").Replace('\t', "`t")
    }
    return $true
}
function Get-LocalizedText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key,
        [object[]]$Arguments = @()
    )
    $value = $Key
    if ($script:LocalizationValues.ContainsKey($Key)) {
        $value = [string]$script:LocalizationValues[$Key]
    }
    if ($Arguments.Count -eq 0) {
        return $value
    }
    try {
        return [string]::Format(
            [Globalization.CultureInfo]::CurrentCulture,
            $value,
            $Arguments
        )
    }
    catch {
        Write-Verbose ('Yerellestirilmis metin bicimlendirilemedi: {0} | {1}' `
            -f $Key, $_.Exception.Message)
        return $Key
    }
}
Export-ModuleMember -Function @(
    'Initialize-Localization',
    'Get-LocalizedText'
)