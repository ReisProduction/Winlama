[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$ValidateOnly,
    [switch]$NoPause
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertFrom-OpenWebUIJson {
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
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
function Write-OpenWebUIBootstrapRule {
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
function Write-OpenWebUIBootstrapLine {
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
function Get-OpenWebUIBootstrapStatusStyle {
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
function Get-OpenWebUIBootstrapStatusWidth {
    $width = 0
    foreach ($level in @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    )) {
        $style = Get-OpenWebUIBootstrapStatusStyle -Level $level
        $width = [Math]::Max($width, $style.Label.Length)
    }
    return $width
}
function Write-OpenWebUIBootstrapStatus {
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
    $style = Get-OpenWebUIBootstrapStatusStyle -Level $Level
    $width = Get-OpenWebUIBootstrapStatusWidth
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
function Format-OpenWebUIBootstrapInputLine {
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
function ConvertFrom-OpenWebUIBootstrapReadValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    if ($null -eq $Value) {
        throw [IO.EndOfStreamException]::new(
            'Standart girdi kapali; zorunlu komut okunamadi.'
        )
    }
    return [string]$Value
}
function Test-OpenWebUIBootstrapExactExit {
    param([AllowNull()][string]$Value)
    return $null -ne $Value -and $Value -ceq 'CIKIS'
}
function Assert-OpenWebUIBootstrapInputContracts {
    $eofRejected = $false
    try {
        $null = ConvertFrom-OpenWebUIBootstrapReadValue -Value $null
    }
    catch [IO.EndOfStreamException] {
        $eofRejected = $true
    }
    if (-not $eofRejected -or
        (ConvertFrom-OpenWebUIBootstrapReadValue -Value '') -cne '') {
        throw 'Open WebUI bootstrap EOF girdi sozlesmesi gecersiz.'
    }
    foreach ($invalid in @('', 'C', 'cikis', 'Cikis', ' CIKIS ')) {
        if (Test-OpenWebUIBootstrapExactExit -Value $invalid) {
            throw 'Open WebUI bootstrap kesin CIKIS sozlesmesi gecersiz.'
        }
    }
    if (-not (Test-OpenWebUIBootstrapExactExit -Value 'CIKIS')) {
        throw 'Open WebUI bootstrap kesin CIKIS sozlesmesi gecersiz.'
    }
    $inputSource = (Get-Command Read-OpenWebUIBootstrapRawInput `
        -ErrorAction Stop).Definition
    if ($inputSource.IndexOf(
            '[Console]::IsOutputRedirected',
            [StringComparison]::Ordinal
        ) -ge 0) {
        throw 'Open WebUI cikti hatti girdiyi gizleyemez.'
    }
    Write-Verbose 'WINLAMA_UI_OK:OpenWebUI.BootstrapEOF'
    Write-Verbose 'WINLAMA_UI_OK:OpenWebUI.BootstrapExactExit'
    Write-Verbose 'WINLAMA_UI_OK:OpenWebUI.OutputPipelineInput'
    return $true
}
function Read-OpenWebUIBootstrapRawInput {
    if ([Console]::IsInputRedirected) {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-OpenWebUIBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-OpenWebUIBootstrapInputLine -Value $value))
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
                (Format-OpenWebUIBootstrapInputLine -Value $value))
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
            (Format-OpenWebUIBootstrapInputLine -Value $value))
        return $value
    }
    catch {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-OpenWebUIBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-OpenWebUIBootstrapInputLine -Value $value))
        return $value
    }
}
function Write-OpenWebUIBootstrapError {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $command = Get-Command Write-WinlamaUIError `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        & $command -Context (Get-WinlamaUIString `
            -Key 'OpenWebUI.Operation.FailedContext' `
            -Fallback 'Open WebUI baslatilamadi.') `
            -ErrorRecord $ErrorRecord
        return
    }
    Write-OpenWebUIBootstrapRule -Character '='
    Write-OpenWebUIBootstrapLine -Text 'ISLEM OZETI' -Color Cyan
    Write-OpenWebUIBootstrapStatus -Level ERROR `
        -Message 'Open WebUI baslatilamadi.'
    Write-OpenWebUIBootstrapStatus -Level ERROR `
        -Message $ErrorRecord.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace(
        $ErrorRecord.InvocationInfo.PositionMessage
    )) {
        Write-OpenWebUIBootstrapStatus -Level DETAIL `
            -Message $ErrorRecord.InvocationInfo.PositionMessage.Trim()
    }
    Write-OpenWebUIBootstrapRule -Character '='
}
function ConvertTo-OpenWebUIErrorLogText {
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
function New-OpenWebUIErrorLogRecord {
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
        moduleCode = 'OPENWEBUI'
        eventCode = 'OPENWEBUI_FAILED'
        script = 'OpenWebUI.ps1'
        message = ConvertTo-OpenWebUIErrorLogText -Value $Message
        error = ConvertTo-OpenWebUIErrorLogText -Value $ErrorText `
            -MaximumLength 1536 -AllowEmpty
        errorType = $ErrorType
        processId = $ProcessId
    }
}
function Assert-OpenWebUIErrorLogSchemaContracts {
    $record = New-OpenWebUIErrorLogRecord -Message Fixture `
        -ErrorText '{"level":"ERROR"}' `
        -ErrorType FixtureException -ProcessId 42
    $parsed = $record | ConvertTo-Json -Compress -Depth 5 |
        ConvertFrom-OpenWebUIJson
    $timestamp = [DateTimeOffset]::MinValue
    if ([string]$parsed.level -cne 'ERROR' -or
        [string]$parsed.displayLevel -cne 'HATA' -or
        [string]$parsed.moduleCode -cne 'OPENWEBUI' -or
        [string]$parsed.eventCode -cne 'OPENWEBUI_FAILED' -or
        [string]$parsed.script -cne 'OpenWebUI.ps1' -or
        [int]$parsed.processId -ne 42 -or
        [string]$parsed.error -match '^\s*[\{\[]' -or
        -not [DateTimeOffset]::TryParse(
            [string]$parsed.timestamp,
            [ref]$timestamp
        )) {
        throw 'Open WebUI hata JSONL semasi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:OpenWebUI.ErrorLogSchema'
    return $true
}
function Write-OpenWebUIErrorLog {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $logsPath = Join-Path ([IO.Path]::GetTempPath()) 'Winlama-Logs'
    [IO.Directory]::CreateDirectory($logsPath) | Out-Null
    $name = 'openwebui-error-{0}-{1}.log' -f @(
        [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff'),
        [guid]::NewGuid().ToString('N')
    )
    $path = Join-Path $logsPath $name
    $record = New-OpenWebUIErrorLogRecord `
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
function Read-OpenWebUIBootstrapInput {
    param([Parameter(Mandatory)][string]$Prompt)
    $command = Get-Command Read-WinlamaUIInput `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return & $command `
            -Prompt (Get-WinlamaUIString `
                -Key 'Common.Prompt.Close' -Fallback $Prompt) `
            -Label (Get-WinlamaUIString `
                -Key 'Common.Prompt.Selection' `
                -Fallback ('Se{0}iminiz' -f [char]0x00E7)) `
            -Hint (Get-WinlamaUIString `
                -Key 'Common.Prompt.ExactCommand' `
                -Fallback 'Yalniz tam olarak {0} yazin.' `
                -Arguments @('CIKIS'))
    }
    Write-OpenWebUIBootstrapRule
    Write-OpenWebUIBootstrapStatus -Level INFO -Message $Prompt
    Write-OpenWebUIBootstrapStatus -Level DETAIL `
        -Message 'Yalniz tam olarak CIKIS yazin.'
    Write-OpenWebUIBootstrapRule
    $value = Read-OpenWebUIBootstrapRawInput
    Write-OpenWebUIBootstrapRule
    return $value
}
trap {
    Write-OpenWebUIBootstrapError -ErrorRecord $_
    if (-not $ValidateOnly -and -not $NoPause) {
        do {
            $answer = Read-OpenWebUIBootstrapInput `
                -Prompt 'Oturumu kapatmak icin CIKIS yazin.'
            if (-not (Test-OpenWebUIBootstrapExactExit -Value $answer)) {
                Write-OpenWebUIBootstrapStatus -Level WARN `
                    -Message 'Bos veya gecersiz komut kabul edilmedi.'
            }
        } while (-not (Test-OpenWebUIBootstrapExactExit -Value $answer))
    }
    exit 1
}
Import-Module (Join-Path $projectRoot `
    'Modules\UI\ConsoleUI.psm1') -Force -ErrorAction Stop `
    -Verbose:$false
try {
    $host.UI.RawUI.WindowTitle = Get-WinlamaUIString `
        -Key 'OpenWebUI.WindowTitle' `
        -Fallback 'Winlama - Open WebUI'
}
catch {
    Write-Verbose ('Pencere basligi ayarlanamadi: {0}' -f `
        $_.Exception.Message)
}
function Get-OpenWebUIText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Fallback,
        [object[]]$Arguments = @()
    )
    if ($null -ne (Get-Command Get-LocalizedText `
        -ErrorAction SilentlyContinue)) {
        $candidate = Get-LocalizedText -Key $Key -Arguments $Arguments
        if ($candidate -cne $Key) {
            return $candidate
        }
    }
    return $Fallback -f $Arguments
}
function Resolve-OpenWebUIConfigPath {
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
function Start-WithRequiredPowerShell {
    param([Parameter(Mandatory)][string]$ResolvedConfigPath)
    if ($PSVersionTable.PSVersion -ge [version]'7.6') {
        return
    }
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) {
        throw 'PowerShell 7.6 veya daha yenisi bulunamadi.'
    }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath, '-ConfigPath', $ResolvedConfigPath
    )
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
function Initialize-OpenWebUILocalization {
    param([Parameter(Mandatory)][string]$ResolvedConfigPath)
    $module = Join-Path $projectRoot `
        'Modules\Localization\LocalizationManager.psm1'
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) {
        throw 'Yerellestirme modulu bulunamadi.'
    }
    $configuration = Get-Content -LiteralPath $ResolvedConfigPath `
        -Raw -Encoding UTF8 | ConvertFrom-OpenWebUIJson
    Import-Module $module -Force -ErrorAction Stop -Verbose:$false
    $null = Initialize-Localization -ProjectRoot $projectRoot `
        -Configuration $configuration.Localization
    try {
        $host.UI.RawUI.WindowTitle = Get-LocalizedText `
            -Key 'OpenWebUI.WindowTitle'
    }
    catch {
        Write-Verbose (Get-LocalizedText `
            -Key 'Common.Verbose.WindowTitleUnavailable' `
            -Arguments @($_.Exception.Message))
    }
}
try {
    $ConfigPath = Resolve-OpenWebUIConfigPath -Path $ConfigPath
    Import-Module (Join-Path $projectRoot `
        'Modules\00_Common.psm1') -Force -ErrorAction Stop `
        -Verbose:$false
    if ($ValidateOnly) {
        $null = Assert-WinlamaUIStandard
        $null = Assert-OpenWebUIBootstrapInputContracts
        $null = Assert-WinlamaUIInputFormatter -Formatter {
            param([string]$Value)
            Format-OpenWebUIBootstrapInputLine -Value $Value
        }
        $null = Assert-OpenWebUIErrorLogSchemaContracts
        Initialize-OpenWebUILocalization `
            -ResolvedConfigPath $ConfigPath
        Write-Verbose (Get-LocalizedText `
            -Key 'Verbose.Validation.Started' `
            -Arguments @('OpenWebUI.ps1'))
        $configuration = Get-Content -LiteralPath $ConfigPath `
            -Raw -Encoding UTF8 | ConvertFrom-OpenWebUIJson
        foreach ($property in @(
            'Enabled', 'Version', 'RootPath', 'Host', 'Port',
            'DefaultConfig', 'Environment'
        )) {
            if ($null -eq $configuration.OpenWebUI.
                PSObject.Properties[$property]) {
                throw "Open WebUI yapilandirma alani eksik: $property"
            }
        }
        foreach ($relativePath in @(
            'Start.ps1',
            'Data\Configs\openui-config.json',
            'Modules\Localization\LocalizationManager.psm1'
            'Modules\UI\ConsoleUI.psm1'
        )) {
            if (-not (Test-Path -LiteralPath `
                (Join-Path $projectRoot $relativePath) -PathType Leaf)) {
                throw (Get-LocalizedText `
                    -Key 'Installer.Error.RequiredFileMissing' `
                    -Arguments @($relativePath))
            }
            Write-Verbose (Get-LocalizedText `
                -Key 'Verbose.Validation.File' `
                -Arguments @($relativePath))
        }
        Write-Verbose (Get-LocalizedText `
            -Key 'Verbose.Validation.Completed' `
            -Arguments @('OpenWebUI.ps1'))
        Write-WinlamaUIRule -Character '='
        Write-WinlamaUILine -Text (Get-LocalizedText `
            -Key 'OpenWebUI.Status.Title') -Color Cyan
        Write-WinlamaUIRule -Character '='
        Write-Verbose 'WINLAMA_UI_OK:OpenWebUI.Status'
        Write-Verbose 'WINLAMA_VALIDATION_OK:OpenWebUI.ps1'
        exit 0
    }
    Start-WithRequiredPowerShell -ResolvedConfigPath $ConfigPath
    Initialize-OpenWebUILocalization `
        -ResolvedConfigPath $ConfigPath
    $startScript = Join-Path $projectRoot 'Start.ps1'
    if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
        throw (Get-OpenWebUIText `
            -Key 'OpenWebUI.Error.StartScriptMissing' `
            -Fallback 'Winlama baslaticisi bulunamadi: {0}' `
            -Arguments @($startScript))
    }
    & $startScript -ConfigPath $ConfigPath `
        -OllamaMode Keep `
        -OpenWebUIMode Restart `
        -VoiceMode Restart `
        -ComfyUIMode Skip `
        -NoPause:$NoPause `
        -Verbose:($VerbosePreference -ne 'SilentlyContinue')
    exit $LASTEXITCODE
}
catch {
    $failure = $_
    try {
        if (-not $ValidateOnly) {
            $null = Write-OpenWebUIErrorLog -ErrorRecord $failure
        }
    }
    catch {
        $warning = Get-OpenWebUIText `
            -Key 'OpenWebUI.Warning.ErrorLogFailed' `
            -Fallback 'Open WebUI hata gunlugu yazilamadi: {0}' `
            -Arguments @($_.Exception.Message)
        $warningCommand = Get-Command Write-WinlamaUIStatus `
            -ErrorAction SilentlyContinue
        if ($null -ne $warningCommand) {
            & $warningCommand -Level WARN -Message $warning
        }
        else {
            Write-OpenWebUIBootstrapLine -Text $warning -Color Yellow
        }
    }
    Write-OpenWebUIBootstrapError -ErrorRecord $failure
    if (-not $NoPause) {
        try {
            Complete-WinlamaUIOperation `
                -Summary (Get-OpenWebUIText `
                    -Key 'OpenWebUI.Operation.Failed' `
                    -Fallback 'Open WebUI baslatma islemi hatayla durdu.') `
                -Level ERROR -Command CIKIS
        }
        catch {
            Write-Verbose ('Kapanis beklemesi atlandi: {0}' -f `
                $_.Exception.Message)
        }
    }
    exit 1
}