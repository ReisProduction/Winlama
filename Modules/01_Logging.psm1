Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot `
    'UI\ConsoleUI.psm1') -ErrorAction Stop
$script:DeploymentStatusKeys = [ordered]@{
    TRACE = 'Common.Level.Trace'
    DEBUG = 'Common.Level.Debug'
    INFO = 'Common.Level.Info'
    OK = 'Common.Level.Ok'
    RUNNING = 'Common.Level.Running'
    WAITING = 'Common.Level.Waiting'
    WARN = 'Common.Level.Warning'
    ERROR = 'Common.Level.Error'
    FATAL = 'Common.Level.Fatal'
}
$script:DeploymentModuleKeys = [ordered]@{
    STATE = 'Module.State'
    PROCESS = 'Module.Process'
    ENGINE = 'Module.Engine'
    ENVIRONMENT = 'Module.Environment'
    SECURITY = 'Module.Security'
    DEPENDENCIES = 'Module.Dependencies'
    HARDWARE = 'Module.Hardware'
    MODELS = 'Module.Models'
    WEBUI = 'Module.WebUI'
    VALIDATION = 'Module.Validation'
    REPORTING = 'Module.Reporting'
    LOGGING = 'Module.Logging'
    OLLAMA = 'Module.Ollama'
    RUNTIME = 'Module.Runtime'
}
$script:DeploymentStatusWidth = 5
$script:DeploymentModuleWidth = 5
function Write-DeploymentConsoleLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    Write-WinlamaUILine -Text $Text -Color $Color
}
function Write-DeploymentConsoleRule {
    [CmdletBinding()]
    param([ValidateSet('-', '=')][string]$Character = '-')
    Write-WinlamaUIRule -Character $Character
}
function Get-DeploymentDisplayWidths {
    [CmdletBinding()]
    param()
    foreach ($key in $script:DeploymentStatusKeys.Values) {
        $value = [string](Get-LocalizedText -Key $key)
        if ([string]::IsNullOrWhiteSpace($value) -or
            $value.Length -gt $script:DeploymentStatusWidth) {
            throw "Dagitim durum etiketi gecersiz: $key | $value"
        }
    }
    foreach ($key in $script:DeploymentModuleKeys.Values) {
        $value = [string](Get-LocalizedText -Key $key)
        if ([string]::IsNullOrWhiteSpace($value) -or
            $value.Length -gt $script:DeploymentModuleWidth) {
            throw "Dagitim modul etiketi gecersiz: $key | $value"
        }
    }
    return [pscustomobject]@{
        Status = $script:DeploymentStatusWidth
        Module = $script:DeploymentModuleWidth
    }
}
function New-DeploymentStatusLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )
    $widths = Get-DeploymentDisplayWidths
    if ($Status.Length -gt $widths.Status -or
        $Module.Length -gt $widths.Module) {
        throw 'Dagitim durum veya modul etiketi alana sigmiyor.'
    }
    $statusWidth = $widths.Status
    $moduleWidth = $widths.Module
    $messageWidth = (Get-WinlamaConsoleWidth) - 10 -
        $statusWidth - $moduleWidth
    if ($messageWidth -lt 20) {
        throw 'Dagitim durum satiri icin yeterli mesaj alani yok.'
    }
    $lines = [Collections.Generic.List[object]]::new()
    $first = $true
    foreach ($logicalLine in [regex]::Split($Message, '\r\n|\n|\r')) {
        $remaining = $logicalLine.TrimStart()
        do {
            $length = [Math]::Min($messageWidth, $remaining.Length)
            if ($remaining.Length -gt $messageWidth) {
                $breakAt = $remaining.LastIndexOf(
                    ' ', $messageWidth - 1, $messageWidth
                )
                if ($breakAt -gt 20) {
                    $length = $breakAt
                }
            }
            $part = $remaining.Substring(0, $length)
            $statusField = if ($first) {
                Format-WinlamaUICenteredField -Text $Status `
                    -Width $statusWidth
            }
            else {
                ' ' * $statusWidth
            }
            $moduleField = if ($first) {
                Format-WinlamaUICenteredField -Text $Module `
                    -Width $moduleWidth
            }
            else {
                ' ' * $moduleWidth
            }
            $messageField = $part.PadRight($messageWidth)
            $lines.Add([pscustomobject]@{
                Status = $statusField
                Module = $moduleField
                Message = $messageField
                Text = ('| {0} | {1} | {2} |' -f `
                    $statusField, $moduleField, $messageField)
            })
            $first = $false
            if ($remaining.Length -le $length) {
                $remaining = ''
            }
            else {
                $remaining = $remaining.Substring($length).TrimStart()
            }
        } while ($remaining.Length -gt 0)
    }
    return $lines.ToArray()
}
function Get-DeploymentStatusColor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StatusCode)
    $name = switch ($StatusCode.ToUpperInvariant()) {
        'TRACE' { 'Gray' }
        'DEBUG' { 'White' }
        'INFO' { 'Cyan' }
        'OK' { 'Green' }
        'RUNNING' { 'Magenta' }
        'WAITING' { 'Blue' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'FATAL' { 'Red' }
        default { 'Cyan' }
    }
    return [ConsoleColor]$name
}
function Get-DeploymentModuleColor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModuleCode)
    $name = switch ($ModuleCode.ToUpperInvariant()) {
        'STATE' { 'Magenta' }
        'PROCESS' { 'Cyan' }
        'ENGINE' { 'Green' }
        'ENVIRONMENT' { 'Blue' }
        'SECURITY' { 'White' }
        'DEPENDENCIES' { 'Yellow' }
        'HARDWARE' { 'Magenta' }
        'MODELS' { 'Green' }
        'WEBUI' { 'Cyan' }
        'VALIDATION' { 'Red' }
        'REPORTING' { 'White' }
        'LOGGING' { 'Gray' }
        'OLLAMA' { 'Blue' }
        'RUNTIME' { 'Cyan' }
        default { 'Gray' }
    }
    return [ConsoleColor]$name
}
function Get-DeploymentMessageColor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StatusCode)
    if ($StatusCode.ToUpperInvariant() -in @('TRACE', 'DEBUG')) {
        return [ConsoleColor]::Gray
    }
    return [ConsoleColor]::White
}
function Write-DeploymentConsoleSegment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory)][ConsoleColor]$Color,
        [switch]$NoNewline,
        [scriptblock]$SegmentWriter
    )
    if ($null -ne $SegmentWriter) {
        & $SegmentWriter $Text $Color ([ConsoleColor]::Black) `
            ([bool]$NoNewline)
        return
    }
    if ($NoNewline) {
        Write-Host $Text -NoNewline -ForegroundColor $Color `
            -BackgroundColor Black
        return
    }
    Write-Host $Text -ForegroundColor $Color -BackgroundColor Black
}
function Write-DeploymentStatusLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Status,
        [Parameter(Mandatory)]
        [string]$Module,
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$StatusCode = 'INFO',
        [string]$ModuleCode = 'LOGGING',
        [scriptblock]$SegmentWriter
    )
    $statusColor = Get-DeploymentStatusColor `
        -StatusCode $StatusCode
    $moduleColor = Get-DeploymentModuleColor `
        -ModuleCode $ModuleCode
    $messageColor = Get-DeploymentMessageColor `
        -StatusCode $StatusCode
    foreach ($line in @(New-DeploymentStatusLayout `
        -Status $Status -Module $Module -Message $Message)) {
        Write-DeploymentConsoleSegment -Text '| ' -Color Gray `
            -NoNewline -SegmentWriter $SegmentWriter
        Write-DeploymentConsoleSegment -Text $line.Status `
            -Color $statusColor -NoNewline `
            -SegmentWriter $SegmentWriter
        Write-DeploymentConsoleSegment -Text ' | ' -Color Gray `
            -NoNewline -SegmentWriter $SegmentWriter
        Write-DeploymentConsoleSegment -Text $line.Module `
            -Color $moduleColor -NoNewline `
            -SegmentWriter $SegmentWriter
        Write-DeploymentConsoleSegment -Text ' | ' -Color Gray `
            -NoNewline -SegmentWriter $SegmentWriter
        Write-DeploymentConsoleSegment -Text $line.Message `
            -Color $messageColor -NoNewline `
            -SegmentWriter $SegmentWriter
        Write-DeploymentConsoleSegment -Text ' |' -Color Gray `
            -SegmentWriter $SegmentWriter
    }
}
function Initialize-Logging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    [IO.Directory]::CreateDirectory($Context.LogsPath) | Out-Null
    if (-not (Test-Path -LiteralPath $Context.LogPath)) {
        [IO.File]::WriteAllText(
            $Context.LogPath,
            [string]::Empty,
            [Text.UTF8Encoding]::new($false)
        )
    }
}
function New-DeploymentLogRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$DisplayLevel,
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][string]$ModuleCode,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$StageCode,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$MessageKey,
        [Parameter(Mandatory)][string]$EventCode,
        [AllowEmptyString()][string]$ExceptionText = '',
        [AllowEmptyString()][string]$Recovery = '',
        [AllowEmptyString()][string]$RecoveryCode = '',
        [Parameter(Mandatory)][string]$Machine,
        [AllowEmptyString()][string]$SessionId = '',
        [int]$ProcessId = $PID
    )
    return [pscustomobject][ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('O')
        level = $Level
        displayLevel = $DisplayLevel
        module = $Module
        moduleCode = $ModuleCode
        eventCode = $EventCode
        stage = $Stage
        stageCode = $StageCode
        message = $Message
        messageKey = $MessageKey
        exception = $ExceptionText
        recovery = $Recovery
        recoveryCode = $RecoveryCode
        machine = $Machine
        sessionId = $SessionId
        processId = $ProcessId
    }
}
function Get-DeploymentLogEventCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MessageKey,
        [AllowEmptyString()][string]$EventCode = ''
    )
    if ([string]::IsNullOrWhiteSpace($EventCode)) {
        return $MessageKey
    }
    return $EventCode
}
function Assert-DeploymentLogSchemaContracts {
    [CmdletBinding()]
    param()
    $record = New-DeploymentLogRecord -Level ERROR `
        -DisplayLevel HATA -Module Motor -ModuleCode ENGINE `
        -Stage Baslangic -StageCode BOOTSTRAP -Message Fixture `
        -MessageKey Engine.Fixture -EventCode Engine.Fixture `
        -Machine FIXTURE -SessionId fixture-session -ProcessId 42
    $parsed = $record | ConvertTo-Json -Compress -Depth 8 |
        ConvertFrom-Json
    $timestamp = [DateTimeOffset]::MinValue
    if ([string]$parsed.level -cne 'ERROR' -or
        [string]$parsed.displayLevel -cne 'HATA' -or
        [string]$parsed.moduleCode -cne 'ENGINE' -or
        [string]$parsed.eventCode -cne 'Engine.Fixture' -or
        [string]$parsed.sessionId -cne 'fixture-session' -or
        [int]$parsed.processId -ne 42 -or
        (Get-DeploymentLogEventCode `
            -MessageKey Engine.Fixture) -cne 'Engine.Fixture' -or
        (Get-DeploymentLogEventCode -MessageKey Engine.Fixture `
            -EventCode ENGINE_OVERRIDE) -cne 'ENGINE_OVERRIDE' -or
        -not [DateTimeOffset]::TryParse(
            [string]$parsed.timestamp,
            [ref]$timestamp
        )) {
        throw 'Dagitim JSONL semasi gecersiz.'
    }
    $layout = @(New-DeploymentStatusLayout `
        -Status (Get-LocalizedText -Key 'Common.Level.Info') `
        -Module (Get-LocalizedText -Key 'Module.Dependencies') `
        -Message ('X' * 140))
    $widths = Get-DeploymentDisplayWidths
    $statusColors = @($script:DeploymentStatusKeys.Keys |
        ForEach-Object {
        [string](Get-DeploymentStatusColor -StatusCode $_)
    })
    $moduleColors = @($script:DeploymentModuleKeys.Keys |
        ForEach-Object {
        [string](Get-DeploymentModuleColor -ModuleCode $_)
    })
    $expectedStatus = Format-WinlamaUICenteredField `
        -Text (Get-LocalizedText -Key 'Common.Level.Info') `
        -Width $widths.Status
    $expectedModule = Format-WinlamaUICenteredField `
        -Text (Get-LocalizedText -Key 'Module.Dependencies') `
        -Width $widths.Module
    $readableColors = @(
        'Blue', 'Cyan', 'Green', 'Gray', 'Magenta', 'Red',
        'White', 'Yellow'
    )
    $longLabelRejected = $false
    try {
        $null = New-DeploymentStatusLayout -Status 'ALTIXX' `
            -Module 'BAGIM' -Message Fixture
    }
    catch {
        $longLabelRejected = $true
    }
    $segments = [Collections.Generic.List[object]]::new()
    $segmentWriter = {
        param(
            [string]$Text,
            [ConsoleColor]$Color,
            [ConsoleColor]$BackgroundColor,
            [bool]$NoNewline
        )
        [void]$segments.Add([pscustomobject]@{
            Text = $Text
            Color = $Color
            BackgroundColor = $BackgroundColor
            NoNewline = $NoNewline
        })
    }.GetNewClosure()
    $renderLayout = @(New-DeploymentStatusLayout `
        -Status 'BILGI' -Module 'BAGIM' -Message Fixture)
    Write-DeploymentStatusLine -Status BILGI -Module BAGIM `
        -Message Fixture -StatusCode INFO `
        -ModuleCode DEPENDENCIES -SegmentWriter $segmentWriter
    $renderedText = @($segments | ForEach-Object {
        $_.Text
    }) -join ''
    $segmentContract = $segments.Count -eq 7 -and
        $renderedText -ceq $renderLayout[0].Text -and
        $segments[0].Color -eq [ConsoleColor]::Gray -and
        $segments[1].Color -eq [ConsoleColor]::Cyan -and
        $segments[2].Color -eq [ConsoleColor]::Gray -and
        $segments[3].Color -eq [ConsoleColor]::Yellow -and
        $segments[4].Color -eq [ConsoleColor]::Gray -and
        $segments[5].Color -eq [ConsoleColor]::White -and
        $segments[6].Color -eq [ConsoleColor]::Gray -and
        @($segments | Where-Object {
            $_.BackgroundColor -ne [ConsoleColor]::Black
        }).Count -eq 0 -and
        @($segments[0..5] | Where-Object {
            -not $_.NoNewline
        }).Count -eq 0 -and -not $segments[6].NoNewline
    $segments.Clear()
    Write-DeploymentStatusLine -Status IZ -Module KAYIT `
        -Message Fixture -StatusCode TRACE -ModuleCode LOGGING `
        -SegmentWriter $segmentWriter
    $detailMessageContract = $segments.Count -eq 7 -and
        $segments[5].Color -eq [ConsoleColor]::Gray
    if ($widths.Status -ne 5 -or $widths.Module -ne 5 -or
        $layout.Count -ne 2 -or
        @($layout | Where-Object { $_.Text.Length -ne 100 }).Count `
            -ne 0 -or
        $layout[0].Status -cne $expectedStatus -or
        $layout[0].Module -cne $expectedModule -or
        $layout[1].Status -cne (' ' * $widths.Status) -or
        $layout[1].Module -cne (' ' * $widths.Module) -or
        @($statusColors | Sort-Object -Unique).Count -lt 8 -or
        (Get-DeploymentStatusColor -StatusCode INFO) -eq
            (Get-DeploymentStatusColor -StatusCode RUNNING) -or
        (Get-DeploymentStatusColor -StatusCode WAITING) -eq
            (Get-DeploymentStatusColor -StatusCode WARN) -or
        @($statusColors | Where-Object {
            $_ -notin $readableColors
        }).Count -ne 0 -or
        @($moduleColors | Sort-Object -Unique).Count -lt 8 -or
        @($moduleColors | Where-Object {
            $_ -notin $readableColors
        }).Count -ne 0 -or
        'Black' -in $statusColors -or 'Black' -in $moduleColors -or
        -not $longLabelRejected -or -not $segmentContract -or
        -not $detailMessageContract) {
        throw 'Dagitim durum/modul UI sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Logging.Schema'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Logging.HighContrastPalette'
    Write-Verbose 'WINLAMA_UI_OK:Logging.CenteredColoredFields'
    Write-Verbose 'WINLAMA_UI_OK:Logging.SegmentedBlackBackground'
    return $true
}
function Write-DeploymentLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [ValidateSet(
            'TRACE', 'DEBUG', 'INFO', 'OK',
            'RUNNING', 'WAITING', 'WARN', 'ERROR', 'FATAL'
        )]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Module,
        [Parameter(Mandatory)]
        [string]$Message,
        [object[]]$MessageArguments = @(),
        [Exception]$Exception,
        [string]$Recovery = '',
        [AllowEmptyString()][string]$EventCode = ''
    )
    $messageKey = $Message
    $EventCode = Get-DeploymentLogEventCode `
        -MessageKey $messageKey -EventCode $EventCode
    $Message = Get-LocalizedText -Key $Message `
        -Arguments $MessageArguments
    $exceptionText = ''
    if ($null -ne $Exception) {
        $exceptionText = $Exception.ToString()
    }
    $canonicalLevel = $Level.ToUpperInvariant()
    $displayLevel = switch ($canonicalLevel) {
        'TRACE' { Get-LocalizedText -Key 'Common.Level.Trace' }
        'DEBUG' { Get-LocalizedText -Key 'Common.Level.Debug' }
        'INFO' { Get-LocalizedText -Key 'Common.Level.Info' }
        'OK' { Get-LocalizedText -Key 'Common.Level.Ok' }
        'RUNNING' { Get-LocalizedText -Key 'Common.Level.Running' }
        'WAITING' { Get-LocalizedText -Key 'Common.Level.Waiting' }
        'WARN' { Get-LocalizedText -Key 'Common.Level.Warning' }
        'ERROR' { Get-LocalizedText -Key 'Common.Level.Error' }
        'FATAL' { Get-LocalizedText -Key 'Common.Level.Fatal' }
    }
    $displayModule = Get-LocalizedText -Key "Module.$Module"
    $displayStage = Get-LocalizedText `
        -Key "Stage.$($Context.CurrentStage)"
    $displayRecovery = if ([string]::IsNullOrWhiteSpace($Recovery)) {
        ''
    }
    else {
        Get-LocalizedText -Key "Recovery.$Recovery"
    }
    $entry = New-DeploymentLogRecord -Level $canonicalLevel `
        -DisplayLevel $displayLevel -Module $displayModule `
        -ModuleCode $Module -Stage $displayStage `
        -StageCode $Context.CurrentStage -Message $Message `
        -MessageKey $messageKey -EventCode $EventCode `
        -ExceptionText $exceptionText `
        -Recovery $displayRecovery -RecoveryCode $Recovery `
        -Machine $Context.MachineId -SessionId $Context.SessionId
    $line = $entry | ConvertTo-Json -Compress -Depth 8
    $mutex = [Threading.Mutex]::new(
        $false,
        'Global\WinlamaDeploymentLog'
    )
    $lockTaken = $false
    try {
        try {
            $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
        }
        catch [Threading.AbandonedMutexException] {
            Write-Verbose ('Birakilmis log kilidi devralindi: {0}' -f `
                $_.Exception.Message)
            $lockTaken = $true
        }
        if (-not $lockTaken) {
            throw (Get-LocalizedText `
                -Key 'Logging.Error.LockUnavailable')
        }
        $stream = [IO.File]::Open(
            $Context.LogPath,
            [IO.FileMode]::Append,
            [IO.FileAccess]::Write,
            [IO.FileShare]::Read
        )
        try {
            $writer = [IO.StreamWriter]::new(
                $stream,
                [Text.UTF8Encoding]::new($false)
            )
            try {
                $writer.WriteLine($line)
                $writer.Flush()
                $stream.Flush($true)
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        if ($lockTaken) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
    if ($Module -eq 'STATE' -and
        $messageKey -eq 'State.Stage.Started') {
        Write-DeploymentConsoleRule
    }
    Write-DeploymentStatusLine -Status $displayLevel `
        -Module $displayModule -Message $Message `
        -StatusCode $canonicalLevel -ModuleCode $Module
}
Export-ModuleMember -Function @(
    'Initialize-Logging', 'Write-DeploymentLog',
    'Assert-DeploymentLogSchemaContracts',
    'Write-DeploymentConsoleLine', 'Write-DeploymentStatusLine',
    'Write-DeploymentConsoleRule', 'Get-DeploymentDisplayWidths',
    'New-DeploymentStatusLayout', 'Get-DeploymentStatusColor',
    'Get-DeploymentModuleColor'
)