function Get-EffectiveStartupMode {
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter(Mandatory)]
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$RequestedMode
    )
    if (-not $Enabled) {
        return 'Skip'
    }
    return $RequestedMode
}
function New-EffectiveStartupModes {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)]
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$RequestedOllamaMode,
        [Parameter(Mandatory)]
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$RequestedOpenWebUIMode,
        [Parameter(Mandatory)]
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$RequestedVoiceMode,
        [Parameter(Mandatory)]
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$RequestedComfyUIMode
    )
    return [pscustomobject][ordered]@{
        Ollama = Get-EffectiveStartupMode `
            -Enabled ([bool]$Config.Ollama.Enabled) `
            -RequestedMode $RequestedOllamaMode
        OpenWebUI = Get-EffectiveStartupMode `
            -Enabled ([bool]$Config.OpenWebUI.Enabled) `
            -RequestedMode $RequestedOpenWebUIMode
        Voice = Get-EffectiveStartupMode `
            -Enabled ([bool]$Config.Voice.Enabled) `
            -RequestedMode $RequestedVoiceMode
        ComfyUI = Get-EffectiveStartupMode `
            -Enabled ([bool]$Config.ComfyUI.Enabled) `
            -RequestedMode $RequestedComfyUIMode
    }
}
function Get-StartupActiveComponents {
    param([Parameter(Mandatory)][pscustomobject]$Modes)
    $components = [Collections.Generic.List[string]]::new()
    foreach ($name in @('Ollama', 'OpenWebUI', 'Voice', 'ComfyUI')) {
        if ([string]$Modes.$name -ne 'Skip') {
            $components.Add($name)
        }
    }
    return @($components)
}
function Get-StartupReadyState {
    param(
        [Parameter(Mandatory)][pscustomobject]$RuntimeContext,
        [Parameter(Mandatory)][pscustomobject]$Modes,
        [scriptblock]$ProbeInvoker = {
            param([string]$Name, [pscustomobject]$Context)
            switch ($Name) {
                'Ollama' {
                    return Test-OllamaApiReady -Context $Context
                }
                'OpenWebUI' {
                    return Test-OpenWebUIReady -Context $Context
                }
                'Voice' {
                    return Test-WinlamaTtsReady -Context $Context
                }
                'ComfyUI' {
                    return Test-ComfyUIReady -Context $Context
                }
            }
            throw "Bilinmeyen servis saglik hedefi: $Name"
        }
    )
    $ready = [ordered]@{
        Ollama = $false
        OpenWebUI = $false
        Voice = $false
        ComfyUI = $false
    }
    foreach ($name in @(Get-StartupActiveComponents -Modes $Modes)) {
        $ready[$name] = [bool](& $ProbeInvoker $name $RuntimeContext)
    }
    return [pscustomobject]$ready
}
function Get-StartupEndpointComponents {
    param(
        [Parameter(Mandatory)][pscustomobject]$Modes,
        [Parameter(Mandatory)][pscustomobject]$ReadyState
    )
    $components = [Collections.Generic.List[string]]::new()
    foreach ($name in @(Get-StartupActiveComponents -Modes $Modes)) {
        if ([bool]$ReadyState.$name) {
            $components.Add($name)
        }
    }
    return @($components)
}
function Get-StartupRecoveryModes {
    param([Parameter(Mandatory)][pscustomobject]$Modes)
    $recovery = [ordered]@{}
    foreach ($name in @('Ollama', 'OpenWebUI', 'Voice', 'ComfyUI')) {
        $recovery[$name] = if ([string]$Modes.$name -eq 'Skip') {
            'Skip'
        }
        else {
            'Keep'
        }
    }
    return [pscustomobject]$recovery
}
function Test-StartupSupervisionEnabled {
    param(
        [Parameter(Mandatory)][bool]$Disabled,
        [Parameter(Mandatory)][pscustomobject]$Modes
    )
    return -not $Disabled -and
        @(Get-StartupActiveComponents -Modes $Modes).Count -gt 0
}
function Register-WinlamaRuntimeController {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ScriptPath,
        [switch]$Replace
    )
    $scriptFile = [IO.Path]::GetFullPath($ScriptPath)
    $pathBytes = [Text.Encoding]::UTF8.GetBytes(
        [IO.Path]::GetFullPath($Path).ToUpperInvariant()
    )
    $suffix = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pathBytes))
    $mutex = [Threading.Mutex]::new($false, "Local\Winlama.Start.$suffix")
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw (Get-LocalizedText -Key 'Startup.Error.ControllerBusy')
        }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $process = $null
            try {
                $existing = Read-JsonFile -Path $Path
                $recordedStart = ([datetime]$existing.ProcessStartTimeUtc).ToUniversalTime()
                $process = Get-Process -Id ([int]$existing.ProcessId) -ErrorAction SilentlyContinue
            }
            catch {
                Write-WinlamaUIStatus -Level WARN -Message (
                    Get-LocalizedText -Key 'Startup.Warning.ControllerRecordInvalid'
                )
            }
            if ($null -ne $process) {
                try {
                    $sameStart = $process.StartTime.ToUniversalTime() -eq $recordedStart
                    if ($process.Id -ne $PID -and $sameStart) {
                        if (-not $Replace -or [string]$existing.ScriptPath -ine $scriptFile) {
                            return $false
                        }
                        Stop-Process -InputObject $process -Force -ErrorAction Stop
                        if (-not $process.WaitForExit(10000)) {
                            throw (Get-LocalizedText -Key 'Startup.Error.ControllerBusy')
                        }
                    }
                }
                finally {
                    $process.Dispose()
                }
            }
        }
        $current = Get-Process -Id $PID
        try {
            $record = [pscustomobject]@{
                ProcessId = $PID
                ProcessStartTimeUtc = $current.StartTime.ToUniversalTime().ToString('O')
                ScriptPath = $scriptFile
            }
            Write-AtomicTextFile -Path $Path `
                -Content (ConvertTo-StableJson -Depth 5 -Value $record)
        }
        finally {
            $current.Dispose()
        }
        return $true
    }
    finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}