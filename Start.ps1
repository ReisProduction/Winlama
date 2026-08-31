[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet('Keep', 'Restart', 'Skip')]
    [string]$OllamaMode = 'Keep',
    [ValidateSet('Keep', 'Restart', 'Skip')]
    [string]$OpenWebUIMode = 'Restart',
    [ValidateSet('Keep', 'Restart', 'Skip')]
    [string]$VoiceMode = 'Restart',
    [ValidateSet('Keep', 'Restart', 'Skip')]
    [string]$ComfyUIMode = 'Restart',
    [switch]$NoSupervise,
    [switch]$ValidateOnly,
    [switch]$NoPause
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertFrom-StartJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()][string]$Json
    )
    process {
        $parameters = @{
            InputObject = $Json
            ErrorAction = 'Stop'
        }
        if ((Get-Command ConvertFrom-Json -ErrorAction Stop).
            Parameters.ContainsKey('DateKind')) {
            $parameters.DateKind = 'String'
        }
        return ConvertFrom-Json @parameters
    }
}
try {
    $Host.UI.RawUI.BackgroundColor = [ConsoleColor]::Black
    $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::White
    [Console]::BackgroundColor = [ConsoleColor]::Black
    [Console]::ForegroundColor = [ConsoleColor]::White
}
catch {
}
$projectRoot = $PSScriptRoot
function Write-StartBootstrapRule {
    param([ValidateSet('-', '=')][string]$Character = '-')
    $command = Get-Command Write-WinlamaUIRule `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        & $command -Character $Character
        return
    }
    $Host.UI.WriteLine([ConsoleColor]::Cyan,
        [ConsoleColor]::Black, ($Character * 100))
}
function Write-StartBootstrapLine {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ConsoleColor]$Color = 'White'
    )
    $command = Get-Command Write-WinlamaUILine `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        & $command -Text $Text -Color $Color
        return
    }
    foreach ($logicalLine in [regex]::Split($Text, '\r\n|\n|\r')) {
        $remaining = $logicalLine.TrimStart()
        do {
            $length = [Math]::Min(96, $remaining.Length)
            $part = $remaining.Substring(0, $length)
            $Host.UI.WriteLine($Color, [ConsoleColor]::Black,
                ('| {0} |' -f $part.PadRight(96)))
            $remaining = if ($remaining.Length -le $length) {
                ''
            }
            else {
                $remaining.Substring($length)
            }
        } while ($remaining.Length -gt 0)
    }
}
function Get-StartBootstrapStatusStyle {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL',
            'SKIP'
        )]
        [string]$Level
    )
    $style = switch ($Level) {
        'INFO' { @{ Label = 'BILGI'; Color = 'Cyan' } }
        'STEP' { @{ Label = 'ADIM'; Color = 'Blue' } }
        'SUCCESS' { @{ Label = 'TAMAM'; Color = 'Green' } }
        'WARN' { @{ Label = 'UYARI'; Color = 'Yellow' } }
        'ERROR' { @{ Label = 'HATA'; Color = 'Red' } }
        'DETAIL' { @{ Label = 'DETAY'; Color = 'Gray' } }
        'SKIP' { @{ Label = 'ATLA'; Color = 'Magenta' } }
    }
    return $style
}
function Get-StartBootstrapStatusWidth {
    $width = 0
    foreach ($level in @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    )) {
        $style = Get-StartBootstrapStatusStyle -Level $level
        $width = [Math]::Max($width, $style.Label.Length)
    }
    return $width
}
function Write-StartBootstrapStatus {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL',
            'SKIP'
        )]
        [string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $command = Get-Command Write-WinlamaUIStatus `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        if ($Message -ceq 'Bos veya gecersiz komut kabul edilmedi.') {
            $Message = Get-WinlamaUIString `
                -Key 'Common.Command.Invalid' -Fallback $Message
        }
        & $command -Level $Level -Message $Message
        return
    }
    $style = Get-StartBootstrapStatusStyle -Level $Level
    $width = Get-StartBootstrapStatusWidth
    $left = [Math]::Floor(($width - $style.Label.Length) / 2)
    $label = ((' ' * $left) + $style.Label).PadRight($width)
    $messageColor = if ($Level -ceq 'DETAIL') {
        [ConsoleColor]::Gray
    }
    else {
        [ConsoleColor]::White
    }
    $first = $true
    foreach ($logicalLine in [regex]::Split($Message, '\r\n|\n|\r')) {
        $remaining = $logicalLine.TrimStart()
        do {
            $length = [Math]::Min(88, $remaining.Length)
            if ($remaining.Length -gt 88) {
                $breakAt = $remaining.LastIndexOf(' ', 87, 88)
                if ($breakAt -gt 20) {
                    $length = $breakAt
                }
            }
            $part = $remaining.Substring(0, $length)
            $status = if ($first) { $label } else { ' ' * $width }
            $Host.UI.Write([ConsoleColor]::Gray,
                [ConsoleColor]::Black, '| ')
            $Host.UI.Write([ConsoleColor]$style.Color,
                [ConsoleColor]::Black, $status)
            $Host.UI.Write([ConsoleColor]::Gray,
                [ConsoleColor]::Black, ' | ')
            $Host.UI.Write($messageColor,
                [ConsoleColor]::Black, $part.PadRight(88))
            $Host.UI.WriteLine([ConsoleColor]::Gray,
                [ConsoleColor]::Black, ' |')
            $first = $false
            $remaining = if ($remaining.Length -le $length) {
                ''
            }
            else {
                $remaining.Substring($length).TrimStart()
            }
        } while ($remaining.Length -gt 0)
    }
}
function Format-StartBootstrapInputLine {
    param([AllowEmptyString()][string]$Value = '')
    $display = if ($Value.Length -gt 85) {
        '...' + $Value.Substring($Value.Length - 82)
    }
    else {
        $Value
    }
    $selection = 'Se{0}iminiz' -f [char]0x00E7
    return '| {0} |' -f ("${selection}: $display").PadRight(96)
}
function ConvertFrom-StartBootstrapReadValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    if ($null -eq $Value) {
        throw [IO.EndOfStreamException]::new(
            'Standart girdi kapali; zorunlu komut okunamadi.'
        )
    }
    return [string]$Value
}
function Test-StartBootstrapExactExit {
    param([AllowNull()][string]$Value)
    return $null -ne $Value -and $Value -ceq 'CIKIS'
}
function Assert-StartBootstrapInputContracts {
    $eofRejected = $false
    try {
        $null = ConvertFrom-StartBootstrapReadValue -Value $null
    }
    catch [IO.EndOfStreamException] {
        $eofRejected = $true
    }
    if (-not $eofRejected -or
        (ConvertFrom-StartBootstrapReadValue -Value '') -cne '') {
        throw 'Baslatma bootstrap EOF girdi sozlesmesi gecersiz.'
    }
    foreach ($invalid in @('', 'C', 'cikis', 'Cikis', ' CIKIS ')) {
        if (Test-StartBootstrapExactExit -Value $invalid) {
            throw 'Baslatma bootstrap kesin CIKIS sozlesmesi gecersiz.'
        }
    }
    if (-not (Test-StartBootstrapExactExit -Value 'CIKIS')) {
        throw 'Baslatma bootstrap kesin CIKIS sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Start.BootstrapEOF'
    Write-Verbose 'WINLAMA_UI_OK:Start.BootstrapExactExit'
    return $true
}
function Read-StartBootstrapRawInput {
    if ([Console]::IsInputRedirected) {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-StartBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-StartBootstrapInputLine -Value $value))
        return $value
    }
    try {
        $row = [Console]::CursorTop
        $buffer = [Text.StringBuilder]::new()
        while ($true) {
            $value = $buffer.ToString()
            $display = if ($value.Length -gt 85) {
                '...' + $value.Substring($value.Length - 82)
            }
            else {
                $value
            }
            [Console]::SetCursorPosition(0, $row)
            $Host.UI.Write([ConsoleColor]::White,
                [ConsoleColor]::Black,
                (Format-StartBootstrapInputLine -Value $value))
            [Console]::SetCursorPosition(
                [Math]::Min(98, 13 + $display.Length), $row)
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) { break }
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($buffer.Length -gt 0) { $buffer.Length-- }
                continue
            }
            if (-not [char]::IsControl($key.KeyChar)) {
                [void]$buffer.Append($key.KeyChar)
            }
        }
        $value = $buffer.ToString()
        [Console]::SetCursorPosition(0, $row)
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-StartBootstrapInputLine -Value $value))
        return $value
    }
    catch {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-StartBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-StartBootstrapInputLine -Value $value))
        return $value
    }
}
function Write-StartBootstrapError {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $command = Get-Command Write-WinlamaUIError `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $Context = Get-WinlamaUIString `
            -Key 'Startup.Error.StartFailed' -Fallback $Context
        & $command -Context $Context -ErrorRecord $ErrorRecord
        return
    }
    Write-StartBootstrapRule -Character '='
    Write-StartBootstrapLine -Text 'ISLEM OZETI' -Color Cyan
    Write-StartBootstrapStatus -Level ERROR -Message $Context
    Write-StartBootstrapStatus -Level ERROR `
        -Message $ErrorRecord.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace(
        $ErrorRecord.InvocationInfo.PositionMessage
    )) {
        Write-StartBootstrapStatus -Level DETAIL `
            -Message $ErrorRecord.InvocationInfo.PositionMessage.Trim()
    }
    Write-StartBootstrapRule -Character '='
}
function ConvertTo-StartErrorLogText {
    param(
        [AllowNull()][object]$Value,
        [ValidateRange(32, 2048)][int]$MaximumLength = 768,
        [switch]$AllowEmpty
    )
    $text = [regex]::Replace([string]$Value, '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $(if ($AllowEmpty) { '' } else { 'Bilinmeyen hata.' })
    }
    if ($text.StartsWith('{') -or $text.StartsWith('[')) {
        $text = 'Yapilandirilmis hata ayrintisi gizlendi.'
    }
    if ($text.Length -gt $MaximumLength) {
        $text = $text.Substring(0, $MaximumLength - 3) + '...'
    }
    return $text
}
function New-StartErrorLogRecord {
    param(
        [Parameter(Mandatory)][string]$Message,
        [AllowEmptyString()][string]$ErrorText = '',
        [AllowEmptyString()][string]$ErrorType = '',
        [int]$ProcessId = $PID
    )
    return [pscustomobject][ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('O')
        level = 'ERROR'
        displayLevel = 'HATA'
        moduleCode = 'START'
        eventCode = 'START_FAILED'
        script = 'Start.ps1'
        message = ConvertTo-StartErrorLogText -Value $Message
        error = ConvertTo-StartErrorLogText -Value $ErrorText `
            -MaximumLength 1536 -AllowEmpty
        errorType = $ErrorType
        processId = $ProcessId
    }
}
function Assert-StartErrorLogSchemaContracts {
    $record = New-StartErrorLogRecord -Message Fixture `
        -ErrorText '{"level":"ERROR"}' `
        -ErrorType FixtureException -ProcessId 42
    $parsed = $record | ConvertTo-Json -Compress -Depth 5 |
        ConvertFrom-StartJson
    $timestamp = [DateTimeOffset]::MinValue
    if ([string]$parsed.level -cne 'ERROR' -or
        [string]$parsed.displayLevel -cne 'HATA' -or
        [string]$parsed.moduleCode -cne 'START' -or
        [string]$parsed.eventCode -cne 'START_FAILED' -or
        [string]$parsed.script -cne 'Start.ps1' -or
        [int]$parsed.processId -ne 42 -or
        [string]$parsed.error -match '^\s*[\{\[]' -or
        -not [DateTimeOffset]::TryParse(
            [string]$parsed.timestamp,
            [ref]$timestamp
        )) {
        throw 'Start hata JSONL semasi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Start.ErrorLogSchema'
    return $true
}
function Write-StartErrorLog {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $logsPath = Join-Path ([IO.Path]::GetTempPath()) 'Winlama-Logs'
    [IO.Directory]::CreateDirectory($logsPath) | Out-Null
    $name = 'start-error-{0}-{1}.log' -f @(
        [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff'),
        [guid]::NewGuid().ToString('N')
    )
    $path = Join-Path $logsPath $name
    $record = New-StartErrorLogRecord `
        -Message $ErrorRecord.Exception.Message `
        -ErrorText $ErrorRecord.InvocationInfo.PositionMessage `
        -ErrorType $ErrorRecord.Exception.GetType().FullName
    $line = $record | ConvertTo-Json -Compress -Depth 5
    [IO.File]::WriteAllText(
        $path,
        $line + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    return $path
}
function Read-StartBootstrapInput {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Label = 'Devam'
    )
    $command = Get-Command Read-WinlamaUIInput `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return & $command `
            -Prompt (Get-WinlamaUIString `
                -Key 'Common.Prompt.Close' -Fallback $Prompt) `
            -Label $Label `
            -Hint (Get-WinlamaUIString `
                -Key 'Common.Prompt.ExactCommand' `
                -Fallback 'Yalniz tam olarak {0} yazin.' `
                -Arguments @('CIKIS'))
    }
    Write-StartBootstrapRule
    Write-StartBootstrapStatus -Level INFO -Message $Prompt
    Write-StartBootstrapStatus -Level DETAIL `
        -Message 'Yalniz tam olarak CIKIS yazin.'
    Write-StartBootstrapRule
    $value = Read-StartBootstrapRawInput
    Write-StartBootstrapRule
    return $value
}
trap {
    Write-StartBootstrapError `
        -Context 'Beklenmeyen baslatma hatasi.' -ErrorRecord $_
    if (-not $ValidateOnly -and -not $NoPause) {
        do {
            $answer = Read-StartBootstrapInput `
                -Prompt 'Oturumu kapatmak icin CIKIS yazin.'
            if (-not (Test-StartBootstrapExactExit -Value $answer)) {
                Write-StartBootstrapStatus -Level WARN `
                    -Message 'Bos veya gecersiz komut kabul edilmedi.'
            }
        } while (-not (Test-StartBootstrapExactExit -Value $answer))
    }
    exit 1
}
Import-Module (Join-Path $projectRoot `
    'Modules\UI\ConsoleUI.psm1') -Force -ErrorAction Stop `
    -Verbose:$false
try {
    $host.UI.RawUI.WindowTitle = Get-WinlamaUIString `
        -Key 'Startup.WindowTitle' `
        -Fallback 'Winlama - Servisler'
}
catch {
    Write-Verbose ('Pencere basligi ayarlanamadi: {0}' -f `
        $_.Exception.Message)
}
function Resolve-WinlamaConfigPath {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $explicitPath = [IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $explicitPath -PathType Leaf)) {
            throw [IO.FileNotFoundException]::new(
                'Belirtilen yapilandirma dosyasi bulunamadi.',
                $explicitPath
            )
        }
        return $explicitPath
    }
    foreach ($candidate in @(
        (Join-Path $projectRoot 'Data\Configs\config.json'),
        (Join-Path $env:LOCALAPPDATA `
            'Programs\Winlama\Data\Configs\config.json')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'Winlama yapilandirma dosyasi bulunamadi.'
}
function ConvertTo-StartupCommandLineArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Argument)
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }
    $builder = [Text.StringBuilder]::new($Argument.Length + 8)
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            $null = $builder.Append('\' * (($backslashes * 2) + 1))
            $null = $builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            $null = $builder.Append('\' * $backslashes)
            $backslashes = 0
        }
        $null = $builder.Append($character)
    }
    if ($backslashes -gt 0) {
        $null = $builder.Append('\' * ($backslashes * 2))
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}
function Start-WithRequiredPowerShell {
    param([Parameter(Mandatory)][string]$ResolvedConfigPath)
    if ($PSVersionTable.PSVersion -ge [version]'7.6') {
        return $false
    }
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) {
        throw 'PowerShell 7.6 veya daha yenisi bulunamadi.'
    }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (ConvertTo-StartupCommandLineArgument `
            -Argument $PSCommandPath),
        '-ConfigPath', (ConvertTo-StartupCommandLineArgument `
            -Argument $ResolvedConfigPath),
        '-OllamaMode', $OllamaMode,
        '-OpenWebUIMode', $OpenWebUIMode,
        '-VoiceMode', $VoiceMode,
        '-ComfyUIMode', $ComfyUIMode
    )
    if ($NoSupervise) {
        $arguments += '-NoSupervise'
    }
    if ($NoPause) {
        $arguments += '-NoPause'
    }
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $arguments += '-Verbose'
    }
    $process = Start-Process -FilePath $pwsh `
        -ArgumentList $arguments -WorkingDirectory $projectRoot `
        -NoNewWindow -Wait -PassThru
    exit $process.ExitCode
}
function Initialize-StartupLocalization {
    param([Parameter(Mandatory)][string]$ResolvedConfigPath)
    $module = Join-Path $projectRoot `
        'Modules\Localization\LocalizationManager.psm1'
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) {
        throw 'Yerellestirme modulu bulunamadi.'
    }
    $configuration = Get-Content -LiteralPath $ResolvedConfigPath `
        -Raw -Encoding UTF8 | ConvertFrom-StartJson
    Import-Module $module -Force -ErrorAction Stop -Verbose:$false
    $null = Initialize-Localization -ProjectRoot $projectRoot `
        -Configuration $configuration.Localization
    try {
        $host.UI.RawUI.WindowTitle = Get-LocalizedText `
            -Key 'Startup.WindowTitle'
    }
    catch {
        Write-Verbose (Get-LocalizedText `
            -Key 'Common.Verbose.WindowTitleUnavailable' `
            -Arguments @($_.Exception.Message))
    }
}
$controllerPath = $null
$context = $null
$initialReady = $null
$effectiveModes = $null
$supervisionEnabled = $false
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
function Assert-StartupEffectiveModeContracts {
    $defaults = @{
        RequestedOllamaMode = 'Keep'
        RequestedOpenWebUIMode = 'Restart'
        RequestedVoiceMode = 'Restart'
        RequestedComfyUIMode = 'Restart'
    }
    $disabledConfig = [pscustomobject]@{
        Ollama = [pscustomobject]@{ Enabled = $false }
        OpenWebUI = [pscustomobject]@{ Enabled = $false }
        Voice = [pscustomobject]@{ Enabled = $false }
        ComfyUI = [pscustomobject]@{ Enabled = $false }
    }
    $disabledModes = New-EffectiveStartupModes `
        -Config $disabledConfig @defaults
    foreach ($requestedMode in @('Keep', 'Restart', 'Skip')) {
        $modeMatrix = New-EffectiveStartupModes `
            -Config $disabledConfig `
            -RequestedOllamaMode $requestedMode `
            -RequestedOpenWebUIMode $requestedMode `
            -RequestedVoiceMode $requestedMode `
            -RequestedComfyUIMode $requestedMode
        foreach ($name in @(
            'Ollama', 'OpenWebUI', 'Voice', 'ComfyUI'
        )) {
            if ([string]$modeMatrix.$name -ne 'Skip') {
                throw "Devre disi servis Skip olmadi: $name"
            }
        }
    }
    $disabledReady = Get-StartupReadyState `
        -RuntimeContext ([pscustomobject]@{}) `
        -Modes $disabledModes -ProbeInvoker {
            throw 'Devre disi servis icin saglik sorgusu calisti.'
        }
    if (@(Get-StartupActiveComponents `
        -Modes $disabledModes).Count -ne 0 -or
        @(Get-StartupEndpointComponents -Modes $disabledModes `
            -ReadyState $disabledReady).Count -ne 0 -or
        (Test-StartupSupervisionEnabled -Disabled $false `
            -Modes $disabledModes)) {
        throw 'Tum servisler kapali etkin mod sozlesmesi gecersiz.'
    }
    foreach ($enabledName in @(
        'Ollama', 'OpenWebUI', 'Voice', 'ComfyUI'
    )) {
        $config = [pscustomobject]@{}
        foreach ($name in @(
            'Ollama', 'OpenWebUI', 'Voice', 'ComfyUI'
        )) {
            $config | Add-Member -NotePropertyName $name `
                -NotePropertyValue ([pscustomobject]@{
                    Enabled = $name -eq $enabledName
                })
        }
        $modes = New-EffectiveStartupModes -Config $config @defaults
        $calls = [Collections.Generic.List[string]]::new()
        $ready = Get-StartupReadyState `
            -RuntimeContext ([pscustomobject]@{}) -Modes $modes `
            -ProbeInvoker {
                param([string]$Name, [pscustomobject]$Context)
                $calls.Add($Name)
                return $true
            }
        $active = @(Get-StartupActiveComponents -Modes $modes)
        $endpoints = @(Get-StartupEndpointComponents `
            -Modes $modes -ReadyState $ready)
        $recovery = Get-StartupRecoveryModes -Modes $modes
        if ($active.Count -ne 1 -or
            $active[0] -cne $enabledName -or
            $calls.Count -ne 1 -or $calls[0] -cne $enabledName -or
            $endpoints.Count -ne 1 -or
            $endpoints[0] -cne $enabledName -or
            [string]$recovery.$enabledName -ne 'Keep' -or
            -not (Test-StartupSupervisionEnabled -Disabled $false `
                -Modes $modes) -or
            (Test-StartupSupervisionEnabled -Disabled $true `
                -Modes $modes)) {
            throw "Tek servis etkin mod sozlesmesi gecersiz: $enabledName"
        }
        foreach ($disabledName in @(
            'Ollama', 'OpenWebUI', 'Voice', 'ComfyUI'
        )) {
            if ($disabledName -ne $enabledName -and
                [string]$modes.$disabledName -ne 'Skip' -or
                $disabledName -ne $enabledName -and
                [string]$recovery.$disabledName -ne 'Skip') {
                throw "Devre disi servis moda sizdi: $disabledName"
            }
        }
        $unhealthy = [pscustomobject]@{
            Ollama = $false
            OpenWebUI = $false
            Voice = $false
            ComfyUI = $false
        }
        if (@(Get-StartupEndpointComponents -Modes $modes `
            -ReadyState $unhealthy).Count -ne 0) {
            throw "Sagliksiz servis endpointi gorundu: $enabledName"
        }
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Start.EffectiveModeMatrix'
    return $true
}
function Remove-RuntimeControllerRegistration {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    try {
        $registration = Get-Content -LiteralPath $Path -Raw `
            -Encoding UTF8 | ConvertFrom-StartJson
        if ([int]$registration.ProcessId -eq $PID) {
            Remove-Item -LiteralPath $Path -Force
        }
    }
    catch {
        Write-WinlamaUIStatus -Level WARN -Message (
            Get-LocalizedText `
                -Key 'Startup.Warning.ControllerRecordCleanupFailed' `
                -Arguments @($_.Exception.Message)
        )
    }
}
function Stop-OwnedRuntime {
    param(
        [Parameter(Mandatory)][pscustomobject]$RuntimeContext,
        [Parameter(Mandatory)][pscustomobject]$ReadyBeforeStart,
        [Parameter(Mandatory)][pscustomobject]$Modes
    )
    Stop-AiRuntime -Context $RuntimeContext `
        -IncludeOllama:(
            $Modes.Ollama -ne 'Skip' -and
                -not $ReadyBeforeStart.Ollama
        ) `
        -KeepOpenWebUI:(
            $Modes.OpenWebUI -eq 'Skip' -or
                ($Modes.OpenWebUI -eq 'Keep' -and
                    $ReadyBeforeStart.OpenWebUI)
        ) `
        -KeepVoice:(
            $Modes.Voice -eq 'Skip' -or
                ($Modes.Voice -eq 'Keep' -and
                    $ReadyBeforeStart.Voice)
        ) `
        -KeepComfyUI:(
            $Modes.ComfyUI -eq 'Skip' -or
                ($Modes.ComfyUI -eq 'Keep' -and
                    $ReadyBeforeStart.ComfyUI)
        )
}
try {
    $ConfigPath = Resolve-WinlamaConfigPath -Path $ConfigPath
    if ($ValidateOnly) {
        Initialize-StartupLocalization `
            -ResolvedConfigPath $ConfigPath
        $null = Assert-WinlamaUIStandard
        $null = Assert-StartBootstrapInputContracts
        $null = Assert-WinlamaUIInputFormatter -Formatter {
            param([string]$Value)
            Format-StartBootstrapInputLine -Value $Value
        }
        $null = Assert-StartErrorLogSchemaContracts
        Write-Verbose (Get-LocalizedText `
            -Key 'Verbose.Validation.Started' `
            -Arguments @('Start.ps1'))
        foreach ($relativePath in @(
            'Modules\Localization\LocalizationManager.psm1',
            'Modules\00_Common.psm1',
            'Modules\01_Logging.psm1',
            'Modules\03_Process.psm1',
            'Modules\04_Environment.psm1',
            'Modules\07_Ollama.psm1',
            'Modules\09_WebUI.psm1',
            'Modules\10_Runtime.psm1'
            'Modules\UI\ConsoleUI.psm1'
        )) {
            $path = Join-Path $projectRoot $relativePath
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw (Get-LocalizedText `
                    -Key 'Installer.Error.RequiredFileMissing' `
                    -Arguments @($relativePath))
            }
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$tokens,
                [ref]$errors
            )
            if (@($errors).Count -gt 0) {
                throw @($errors)[0]
            }
            Write-Verbose (Get-LocalizedText `
                -Key 'Verbose.Validation.File' `
                -Arguments @($relativePath))
        }
        foreach ($name in @(
            '00_Common.psm1', '01_Logging.psm1',
            '03_Process.psm1', '04_Environment.psm1',
            '07_Ollama.psm1', '09_WebUI.psm1',
            '10_Runtime.psm1'
        )) {
            Import-Module (Join-Path $projectRoot "Modules\$name") `
                -Force -ErrorAction Stop -Verbose:$false
        }
        $validationConfig = Read-JsonFile -Path $ConfigPath
        $null = Test-DeploymentConfiguration -Config $validationConfig
        $null = Assert-WinlamaTtsRuntimeContracts
        $null = Assert-ComfyUIObjectInfoContracts
        $null = Assert-AiRuntimeAggregateContracts
        $null = Assert-StartupEffectiveModeContracts
        $runtimeParameters = (Get-Command Start-AiRuntime `
            -ErrorAction Stop).Parameters.Keys
        foreach ($parameter in @(
            'Context', 'OllamaMode', 'OpenWebUIMode',
            'VoiceMode', 'ComfyUIMode', 'Attached'
        )) {
            if ($parameter -notin $runtimeParameters) {
                throw "Start-AiRuntime parametresi eksik: $parameter"
            }
        }
        if ((ConvertTo-StartupCommandLineArgument `
            -Argument 'C:\Program Files\Winlama\Start.ps1') -cne `
            '"C:\Program Files\Winlama\Start.ps1"' -or
            (ConvertTo-StartupCommandLineArgument `
                -Argument 'C:\Winlama') -cne 'C:\Winlama') {
            throw 'PowerShell yeniden baslatma arguman sozlesmesi gecersiz.'
        }
        Write-Verbose 'WINLAMA_VALIDATION_OK:Start.ArgumentQuoting'
        Write-Verbose 'WINLAMA_VALIDATION_OK:Start.RuntimeContracts'
        Write-Verbose (Get-LocalizedText `
            -Key 'Verbose.Validation.Completed' `
            -Arguments @('Start.ps1'))
        Write-WinlamaUIRule -Character '='
        Write-WinlamaUILine -Text (Get-LocalizedText `
            -Key 'Startup.Status.Title') -Color Cyan
        Write-WinlamaUIRule -Character '='
        [void](Read-WinlamaUIInput `
            -Prompt 'Dogrulama secim istemi.' `
            -Label ('Se{0}iminiz' -f [char]0x00E7) `
            -InputReader { param([string]$Label) return '0' })
        $errorStyle = Get-WinlamaUIStatusStyle -Level ERROR
        if ($errorStyle.Label -cne 'HATA' -or
            $errorStyle.Color -cne 'Red') {
            throw 'Baslatma hata arayuzu renk sozlesmesi gecersiz.'
        }
        Write-Verbose 'WINLAMA_UI_INPUT_OK:Start.Validation'
        Write-Verbose 'WINLAMA_UI_ERROR_OK:Start.Validation'
        Write-Verbose 'WINLAMA_UI_OK:Start.Status'
        Write-Verbose 'WINLAMA_VALIDATION_OK:Start.ps1'
        exit 0
    }
    $null = Start-WithRequiredPowerShell `
        -ResolvedConfigPath $ConfigPath
    Initialize-StartupLocalization -ResolvedConfigPath $ConfigPath
    foreach ($name in @(
        '00_Common.psm1',
        '01_Logging.psm1',
        '03_Process.psm1',
        '04_Environment.psm1',
        '07_Ollama.psm1',
        '09_WebUI.psm1',
        '10_Runtime.psm1'
    )) {
        Import-Module (Join-Path $projectRoot "Modules\$name") `
            -Force -ErrorAction Stop -Verbose:$false
    }
    $config = Read-JsonFile -Path $ConfigPath
    $effectiveModes = New-EffectiveStartupModes -Config $config `
        -RequestedOllamaMode $OllamaMode `
        -RequestedOpenWebUIMode $OpenWebUIMode `
        -RequestedVoiceMode $VoiceMode `
        -RequestedComfyUIMode $ComfyUIMode
    $activeComponents = @(
        Get-StartupActiveComponents -Modes $effectiveModes
    )
    $supervisionEnabled = Test-StartupSupervisionEnabled `
        -Disabled ([bool]$NoSupervise) -Modes $effectiveModes
    $context = New-DeploymentContext -Config $config `
        -PackageRoot $projectRoot
    Initialize-DeploymentDirectories -Context $context
    Initialize-Logging -Context $context
    if ($supervisionEnabled) {
        $controllerPath = Join-Path $context.DataPath `
            'runtime-controller.json'
        if (Test-Path -LiteralPath $controllerPath -PathType Leaf) {
            try {
                $existing = Read-JsonFile -Path $controllerPath
                $process = Get-Process -Id ([int]$existing.ProcessId) `
                    -ErrorAction SilentlyContinue
                $sameScript = [string]$existing.ScriptPath -ieq `
                    [IO.Path]::GetFullPath($PSCommandPath)
                $sameStart = $null -ne $process -and
                    $process.StartTime.ToUniversalTime().ToString('O') -eq
                        [string]$existing.ProcessStartTimeUtc
                if ($null -ne $process -and $process.Id -ne $PID -and
                    $sameScript -and $sameStart) {
                    Stop-Process -Id $process.Id -Force `
                        -ErrorAction Stop
                    $process.WaitForExit(10000)
                }
            }
            catch {
                Write-WinlamaUIStatus -Level WARN -Message (
                    Get-LocalizedText `
                        -Key 'Startup.Warning.ControllerStopFailed' `
                        -Arguments @($_.Exception.Message)
                )
            }
        }
        $currentProcess = Get-Process -Id $PID
        Write-AtomicTextFile -Path $controllerPath `
            -Content (ConvertTo-StableJson -Depth 5 -Value `
                ([pscustomobject]@{
                    ProcessId = $PID
                    ProcessStartTimeUtc = $currentProcess.StartTime.
                        ToUniversalTime().ToString('O')
                    ScriptPath = [IO.Path]::GetFullPath($PSCommandPath)
                }))
        $currentProcess.Dispose()
    }
    $initialReady = Get-StartupReadyState -RuntimeContext $context `
        -Modes $effectiveModes
    try {
        if (-not (Test-WinlamaStartupShortcut -Context $context)) {
            $null = Install-WinlamaStartupShortcut -Context $context
        }
    }
    catch {
        Write-DeploymentLog -Context $context -Level WARN `
            -Module RUNTIME -Message 'Runtime.StartupShortcut.Failed' `
            -Exception $_.Exception -Recovery MANUAL_REPAIR
    }
    $delay = [int]$config.Runtime.StartupInitialDelaySeconds
    if ($activeComponents.Count -gt 0 -and $delay -gt 0) {
        Start-Sleep -Seconds $delay
    }
    if ($effectiveModes.Ollama -ne 'Skip') {
        try {
            Set-OllamaConfiguration -Context $context
        }
        catch {
            Write-DeploymentLog -Context $context -Level WARN `
                -Module RUNTIME `
                -Message 'Runtime.Ollama.ConfigurationFailed' `
                -Exception $_.Exception -Recovery RETRY
        }
    }
    if ($activeComponents.Count -gt 0) {
        Start-AiRuntime -Context $context `
            -OllamaMode $effectiveModes.Ollama `
            -OpenWebUIMode $effectiveModes.OpenWebUI `
            -VoiceMode $effectiveModes.Voice `
            -ComfyUIMode $effectiveModes.ComfyUI `
            -Attached:$supervisionEnabled
    }
    $readyAfterStart = Get-StartupReadyState `
        -RuntimeContext $context -Modes $effectiveModes
    $endpointComponents = @(
        Get-StartupEndpointComponents -Modes $effectiveModes `
            -ReadyState $readyAfterStart
    )
    $uris = Get-WinlamaServiceUris -Config $config
    if ('Ollama' -in $endpointComponents) {
        Write-DeploymentConsoleLine `
            -Text (Get-LocalizedText `
                -Key 'Startup.Endpoint.OllamaLocal' `
                -Arguments @($uris.OllamaLocal)) -Color Cyan
    }
    if ('OpenWebUI' -in $endpointComponents) {
        Write-DeploymentConsoleLine `
            -Text (Get-LocalizedText `
                -Key 'Startup.Endpoint.OpenWebUILocal' `
                -Arguments @($uris.OpenWebUILocal)) -Color Cyan
        Write-DeploymentConsoleLine `
            -Text (Get-LocalizedText `
                -Key 'Startup.Endpoint.OpenWebUITemporary' `
                -Arguments @($uris.OpenWebUITemporary)) `
            -Color Green
    }
    if ('Voice' -in $endpointComponents) {
        Write-DeploymentConsoleLine `
            -Text (Get-LocalizedText `
                -Key 'Startup.Endpoint.VoiceLocal' `
                -Arguments @(
                    'http://127.0.0.1:{0}' -f $config.Voice.Port
                )) -Color Cyan
    }
    if ('ComfyUI' -in $endpointComponents) {
        Write-DeploymentConsoleLine `
            -Text (Get-LocalizedText `
                -Key 'Startup.Endpoint.ComfyUILocal' `
                -Arguments @($uris.ComfyUILocal)) -Color Cyan
    }
    if ('Ollama' -in $endpointComponents -and
        -not [string]::IsNullOrWhiteSpace($uris.OllamaLan)) {
        Write-DeploymentConsoleLine `
            -Text (Get-LocalizedText `
                -Key 'Startup.Endpoint.OllamaLan' `
                -Arguments @($uris.OllamaLan)) -Color Cyan
    }
    if ('OpenWebUI' -in $endpointComponents -and
        -not [string]::IsNullOrWhiteSpace($uris.OpenWebUILan)) {
        Write-DeploymentConsoleLine `
            -Text (Get-LocalizedText `
                -Key 'Startup.Endpoint.OpenWebUILan' `
                -Arguments @($uris.OpenWebUILan)) `
            -Color Cyan
    }
    if (-not $supervisionEnabled) {
        if (-not $NoPause) {
            Complete-WinlamaUIOperation `
                -Summary (Get-LocalizedText `
                    -Key 'Startup.Operation.Started') `
                -Level SUCCESS -Command CIKIS
        }
        exit 0
    }
    Write-DeploymentConsoleLine -Text (Get-LocalizedText `
        -Key 'Startup.Supervisor.Active') -Color Green
    try {
        while ($true) {
            Start-Sleep -Seconds 5
            $currentReady = Get-StartupReadyState `
                -RuntimeContext $context -Modes $effectiveModes
            $unhealthyComponents = @(
                $activeComponents | Where-Object {
                    -not [bool]$currentReady.$_
                }
            )
            if ($unhealthyComponents.Count -eq 0) {
                continue
            }
            Write-DeploymentConsoleLine -Text (Get-LocalizedText `
                -Key 'Startup.Service.Recovery') `
                -Color Yellow
            try {
                $recoveryModes = Get-StartupRecoveryModes `
                    -Modes $effectiveModes
                Start-AiRuntime -Context $context `
                    -OllamaMode $recoveryModes.Ollama `
                    -OpenWebUIMode $recoveryModes.OpenWebUI `
                    -VoiceMode $recoveryModes.Voice `
                    -ComfyUIMode $recoveryModes.ComfyUI `
                    -Attached
            }
            catch {
                Write-DeploymentConsoleLine -Text (Get-LocalizedText `
                    -Key 'Startup.Service.RecoveryFailed' `
                    -Arguments @($_.Exception.Message)) `
                    -Color Red
            }
        }
    }
    finally {
        Stop-OwnedRuntime -RuntimeContext $context `
            -ReadyBeforeStart $initialReady -Modes $effectiveModes
        Remove-RuntimeControllerRegistration -Path $controllerPath
    }
    if (-not $NoPause) {
        Complete-WinlamaUIOperation `
            -Summary (Get-LocalizedText `
                -Key 'Startup.Operation.SupervisorCompleted') `
            -Level SUCCESS -Command CIKIS
    }
    exit 0
}
catch {
    $failure = $_
    if ($supervisionEnabled -and $null -ne $context -and
        $null -ne $initialReady -and $null -ne $effectiveModes) {
        try {
            Stop-OwnedRuntime -RuntimeContext $context `
                -ReadyBeforeStart $initialReady -Modes $effectiveModes
        }
        catch {
            Write-WinlamaUIStatus -Level WARN -Message (
                Get-LocalizedText `
                    -Key 'Startup.Warning.ServiceCleanupFailed' `
                    -Arguments @($_.Exception.Message)
            )
        }
    }
    Remove-RuntimeControllerRegistration -Path $controllerPath
    if (-not $ValidateOnly) {
        try {
            $null = Write-StartErrorLog -ErrorRecord $failure
        }
        catch {
            Write-WinlamaUIStatus -Level WARN -Message (
                Get-LocalizedText `
                    -Key 'Startup.Warning.ErrorLogFailed' `
                    -Arguments @($_.Exception.Message)
            )
        }
    }
    Write-WinlamaUIError -Context (Get-LocalizedText `
        -Key 'Startup.Error.StartFailed') `
        -ErrorRecord $failure
    if (-not $NoPause) {
        try {
            Complete-WinlamaUIOperation `
                -Summary (Get-LocalizedText `
                    -Key 'Startup.Operation.Failed') `
                -Level ERROR -Command CIKIS
        }
        catch {
            Write-Verbose ('Kapanis beklemesi atlandi: {0}' -f `
                $_.Exception.Message)
        }
    }
    exit 1
}