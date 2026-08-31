Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertTo-NormalizedPathEntries {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$PathValue,
        [switch]$RemoveMissing
    )
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return @()
    }
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $result = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($PathValue -split ';')) {
        $candidate = $entry.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if ($candidate.IndexOf([char]0) -ge 0) {
            continue
        }
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        $root = [IO.Path]::GetPathRoot($expanded)
        if (-not [string]::IsNullOrWhiteSpace($root) -and
            $expanded.Length -gt $root.Length) {
            $candidate = $candidate.TrimEnd('\')
            $expanded = $expanded.TrimEnd('\')
        }
        if ($RemoveMissing -and -not (Test-Path -LiteralPath $expanded)) {
            continue
        }
        if ($seen.Add($candidate)) {
            $result.Add($candidate)
        }
    }
    return $result.ToArray()
}
function Send-EnvironmentChangedNotification {
    [CmdletBinding()]
    param()
    if ($null -eq ('Winlama.NativeEnvironment' -as [type])) {
        $source = @'
using System;
using System.Runtime.InteropServices;
namespace Winlama
{
    public static class NativeEnvironment
    {
        [DllImport("user32.dll", SetLastError = true,
            CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessageTimeout(
            IntPtr window,
            uint message,
            UIntPtr parameter,
            string value,
            uint flags,
            uint timeout,
            out UIntPtr result);
        public static void Broadcast()
        {
            UIntPtr result;
            SendMessageTimeout(
                new IntPtr(0xffff),
                0x001A,
                UIntPtr.Zero,
                "Environment",
                0x0002,
                5000,
                out result);
        }
    }
}
'@
        Add-Type -TypeDefinition $source -Language CSharp
    }
    [Winlama.NativeEnvironment]::Broadcast()
}
function Sync-SystemEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [switch]$VerifyChildProcess
    )
    $removeMissing = [bool]$Context.Config.Security.RemoveInvalidPathEntries
    $machinePath = [Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::Machine
    )
    $userPath = [Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::User
    )
    $machineEntries = ConvertTo-NormalizedPathEntries `
        -PathValue $machinePath -RemoveMissing:$removeMissing
    $userEntries = ConvertTo-NormalizedPathEntries `
        -PathValue $userPath -RemoveMissing:$removeMissing
    $machineValue = $machineEntries -join ';'
    $userValue = $userEntries -join ';'
    if ($machineValue -ne $machinePath) {
        [Environment]::SetEnvironmentVariable(
            'Path',
            $machineValue,
            [EnvironmentVariableTarget]::Machine
        )
    }
    if ($userValue -ne $userPath) {
        [Environment]::SetEnvironmentVariable(
            'Path',
            $userValue,
            [EnvironmentVariableTarget]::User
        )
    }
    $combined = ConvertTo-NormalizedPathEntries `
        -PathValue (($machineEntries + $userEntries) -join ';')
    $env:Path = $combined -join ';'
    Send-EnvironmentChangedNotification
    if ($VerifyChildProcess) {
        $pwsh = Get-PowerShellRuntimePath -Context $Context
        $result = Invoke-ExternalProcess -FilePath $pwsh `
            -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive',
                '-Command', '[Environment]::GetEnvironmentVariable(' +
                    "'Path','Process')"
            ) -TimeoutSeconds 30 `
            -Activity (Get-LocalizedText `
                -Key 'Environment.Process.ChildPathVerify')
        $childEntries = ConvertTo-NormalizedPathEntries `
            -PathValue $result.StandardOutput
        foreach ($entry in $combined) {
            if ($childEntries -notcontains $entry) {
                throw (Get-LocalizedText `
                    -Key 'Environment.Error.ChildPathSyncFailed' `
                    -Arguments @($entry))
            }
        }
    }
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module ENVIRONMENT -Message 'Environment.Synchronized'
}
function Test-SystemEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $machinePath = [Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::Machine
    )
    $userPath = [Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::User
    )
    $expected = ConvertTo-NormalizedPathEntries `
        -PathValue "$machinePath;$userPath"
    $actual = ConvertTo-NormalizedPathEntries -PathValue $env:Path
    foreach ($entry in $expected) {
        if ($actual -notcontains $entry) {
            return $false
        }
    }
    return $true
}
Export-ModuleMember -Function @(
    'ConvertTo-NormalizedPathEntries', 'Sync-SystemEnvironment',
    'Test-SystemEnvironment', 'Send-EnvironmentChangedNotification'
)