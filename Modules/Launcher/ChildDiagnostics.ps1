function Get-LauncherLogReadOffset {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Length,
        [Parameter(Mandatory)][DateTime]$LastWriteTimeUtc,
        [Parameter(Mandatory)][DateTimeOffset]$StartedAt,
        [Parameter(Mandatory)][hashtable]$Snapshot
    )
    if ($Snapshot.ContainsKey($Path)) {
        $offset = [long]$Snapshot[$Path]
        if ($Length -le $offset) {
            return -1
        }
        return $offset
    }
    if ($LastWriteTimeUtc -lt $StartedAt.UtcDateTime.AddSeconds(-1)) {
        return -1
    }
    return 0
}
function Get-LauncherLogPropertyValue {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }
    return $null
}
function Get-LauncherTextDigest {
    param([AllowEmptyString()][string]$Value = '')
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $algorithm.ComputeHash($bytes)
        $hex = [BitConverter]::ToString($hash) -replace '-', ''
        return $hex.Substring(0, 16)
    }
    finally {
        $algorithm.Dispose()
    }
}
function ConvertTo-LauncherBoundedLogText {
    param(
        [AllowNull()][object]$Value,
        [ValidateRange(32, 4096)][int]$MaximumLength = 320
    )
    $original = [string]$Value
    $text = $original.Trim()
    for ($depth = 0; $depth -lt 2; $depth++) {
        if (($text.StartsWith('{') -or $text.StartsWith('[')) -and
            $text.Length -le 16384) {
            try {
                $nested = $text | ConvertFrom-LauncherJson `
                    -ErrorAction Stop
                $candidate = Get-LauncherLogPropertyValue `
                    -InputObject $nested `
                    -Names @(
                        'message', 'Message', 'errorMessage',
                        'ErrorMessage', 'exception', 'Exception',
                        'error', 'Error'
                    )
                if ($null -eq $candidate -or
                    [string]::IsNullOrWhiteSpace([string]$candidate)) {
                    $text = 'Yapilandirilmis hata ayrintisi gizlendi.'
                    break
                }
                $text = ([string]$candidate).Trim()
                continue
            }
            catch {
                $text = 'Gecersiz yapilandirilmis hata ayrintisi gizlendi.'
                break
            }
        }
        if ($text.StartsWith('{') -or $text.StartsWith('[')) {
            $text = 'Buyuk yapilandirilmis hata ayrintisi gizlendi.'
        }
        break
    }
    $text = [regex]::Replace($text, '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = 'Alt betik hata kaydi.'
    }
    if ($text.Length -gt $MaximumLength) {
        $text = $text.Substring(0, $MaximumLength - 3) + '...'
    }
    return [pscustomobject]@{
        Text = $text
        Hash = Get-LauncherTextDigest -Value $original
    }
}
function ConvertTo-LauncherCanonicalLogLevel {
    param([AllowEmptyString()][string]$Level = '')
    return $Level.Trim().ToUpperInvariant()
}
function ConvertFrom-LauncherChildLogLine {
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Offset,
        [Parameter(Mandatory)][int]$TailLine,
        [Parameter(Mandatory)][DateTimeOffset]$StartedAt,
        [Parameter(Mandatory)][int]$ExpectedProcessId,
        [Parameter(Mandatory)][string]$ExpectedScriptName,
        [AllowEmptyString()][string]$ExpectedSessionId = ''
    )
    try {
        $entry = $Line | ConvertFrom-LauncherJson -ErrorAction Stop
        $level = ConvertTo-LauncherCanonicalLogLevel -Level ([string](
            Get-LauncherLogPropertyValue -InputObject $entry `
                -Names @('level')
        ))
        if ($level -notin @('ERROR', 'FATAL')) {
            return $null
        }
        $processValue = Get-LauncherLogPropertyValue `
            -InputObject $entry -Names @('processId')
        $processId = 0
        if (-not [int]::TryParse(
            [string]$processValue,
            [ref]$processId
        )) {
            return $null
        }
        $entrySessionId = [string](Get-LauncherLogPropertyValue `
            -InputObject $entry -Names @('sessionId'))
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSessionId)) {
            if ($entrySessionId -cne $ExpectedSessionId) {
                return $null
            }
        }
        elseif ($processId -ne $ExpectedProcessId) {
            return $null
        }
        $timestampValue = Get-LauncherLogPropertyValue `
            -InputObject $entry `
            -Names @('timestamp')
        $timestamp = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse(
            [string]$timestampValue,
            [ref]$timestamp
        ) -or $timestamp -lt $StartedAt.AddSeconds(-1)) {
            return $null
        }
        $entryScript = [string](Get-LauncherLogPropertyValue `
            -InputObject $entry -Names @('script'))
        if (-not [string]::IsNullOrWhiteSpace($entryScript) -and
            [IO.Path]::GetFileName($entryScript) -ine
                [IO.Path]::GetFileName($ExpectedScriptName)) {
            return $null
        }
        $messageValue = Get-LauncherLogPropertyValue `
            -InputObject $entry -Names @('message')
        $bounded = ConvertTo-LauncherBoundedLogText `
            -Value $messageValue
        return [pscustomobject]@{
            Path = $Path
            Offset = $Offset
            TailLine = $TailLine
            ScriptName = $ExpectedScriptName
            ProcessId = $processId
            SessionId = $entrySessionId
            Level = $level
            ModuleCode = [string](Get-LauncherLogPropertyValue `
                -InputObject $entry `
                -Names @('moduleCode'))
            EventCode = [string](Get-LauncherLogPropertyValue `
                -InputObject $entry `
                -Names @('eventCode'))
            Message = $bounded.Text
            ErrorHash = $bounded.Hash
        }
    }
    catch {
        return $null
    }
}
function Format-LauncherChildLogFailure {
    param([Parameter(Mandatory)][object]$Failure)
    $module = if ([string]::IsNullOrWhiteSpace($Failure.ModuleCode)) {
        'UNKNOWN'
    }
    else {
        $Failure.ModuleCode
    }
    $event = if ([string]::IsNullOrWhiteSpace($Failure.EventCode)) {
        'ERROR'
    }
    else {
        $Failure.EventCode
    }
    $text = '{0} | PID {1} | {2}/{3} | {4} | {5}@+{6}:{7} | SHA256:{8}' -f @(
        $Failure.ScriptName,
        $Failure.ProcessId,
        $module,
        $event,
        $Failure.Message,
        $Failure.Path,
        $Failure.Offset,
        $Failure.TailLine,
        $Failure.ErrorHash
    )
    return (ConvertTo-LauncherBoundedLogText `
        -Value $text -MaximumLength 1024).Text
}
function Get-LauncherChildFailurePaths {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Failures = @()
    )
    $paths = foreach ($failure in @($Failures)) {
        if ($null -eq $failure) {
            continue
        }
        $property = $failure.PSObject.Properties['Path']
        if ($null -eq $property) {
            continue
        }
        $value = [string]$property.Value
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $value
        }
    }
    return @($paths | Sort-Object -Unique | Select-Object -First 5)
}
function Get-LauncherChildLogFailures {
    param(
        [Parameter(Mandatory)][DateTimeOffset]$StartedAt,
        [Parameter(Mandatory)][hashtable]$Snapshot,
        [Parameter(Mandatory)][int]$ExpectedProcessId,
        [Parameter(Mandatory)][string]$ExpectedScriptName,
        [AllowEmptyString()][string]$ExpectedSessionId = '',
        [string[]]$Directories = @(Get-LauncherDiagnosticRoots),
        [scriptblock]$FileProvider,
        [scriptblock]$TailReader
    )
    $failures = [Collections.Generic.List[object]]::new()
    if ($null -eq $TailReader) {
        $TailReader = {
            param([string]$Path, [long]$Offset)
            Read-LauncherLogTail -Path $Path -Offset $Offset
        }
    }
    foreach ($file in @(Get-LauncherLogFiles `
        -Directories $Directories -FileProvider $FileProvider)) {
        if ($file.FullName -eq $script:LauncherLogPath) {
            continue
        }
        $offset = Get-LauncherLogReadOffset `
            -Path $file.FullName -Length $file.Length `
            -LastWriteTimeUtc $file.LastWriteTimeUtc `
            -StartedAt $StartedAt -Snapshot $Snapshot
        if ($offset -lt 0) {
            continue
        }
        $tailLine = 0
        foreach ($line in @(& $TailReader $file.FullName $offset)) {
            $tailLine++
            $failure = ConvertFrom-LauncherChildLogLine `
                -Line $line -Path $file.FullName -Offset $offset `
                -TailLine $tailLine -StartedAt $StartedAt `
                -ExpectedProcessId $ExpectedProcessId `
                -ExpectedScriptName $ExpectedScriptName `
                -ExpectedSessionId $ExpectedSessionId
            if ($null -ne $failure) {
                $failures.Add($failure)
            }
        }
    }
    return $failures.ToArray()
}