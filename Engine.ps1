[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$Resume,
    [switch]$ForceRepair,
    [switch]$ValidateOnly,
    [switch]$NoPause,
    [switch]$GenerateReport,
    [string]$PackageRoot = '',
    [string]$SessionId = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertFrom-EngineJson {
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
function Write-EngineBootstrapRule {
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
function Write-EngineBootstrapLine {
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
function Get-EngineBootstrapStatusStyle {
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
function Get-EngineBootstrapStatusWidth {
    $width = 0
    foreach ($level in @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    )) {
        $style = Get-EngineBootstrapStatusStyle -Level $level
        $width = [Math]::Max($width, $style.Label.Length)
    }
    return $width
}
function Write-EngineBootstrapStatus {
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
    $style = Get-EngineBootstrapStatusStyle -Level $Level
    $width = Get-EngineBootstrapStatusWidth
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
function Format-EngineBootstrapInputLine {
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
function ConvertFrom-EngineBootstrapReadValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    if ($null -eq $Value) {
        throw [IO.EndOfStreamException]::new(
            'Standart girdi kapali; zorunlu komut okunamadi.'
        )
    }
    return [string]$Value
}
function Test-EngineBootstrapExactExit {
    param([AllowNull()][string]$Value)
    return $null -ne $Value -and $Value -ceq 'CIKIS'
}
function Assert-EngineBootstrapInputContracts {
    $eofRejected = $false
    try {
        $null = ConvertFrom-EngineBootstrapReadValue -Value $null
    }
    catch [IO.EndOfStreamException] {
        $eofRejected = $true
    }
    if (-not $eofRejected -or
        (ConvertFrom-EngineBootstrapReadValue -Value '') -cne '') {
        throw 'Motor bootstrap EOF girdi sozlesmesi gecersiz.'
    }
    foreach ($invalid in @('', 'C', 'cikis', 'Cikis', ' CIKIS ')) {
        if (Test-EngineBootstrapExactExit -Value $invalid) {
            throw 'Motor bootstrap kesin CIKIS sozlesmesi gecersiz.'
        }
    }
    if (-not (Test-EngineBootstrapExactExit -Value 'CIKIS')) {
        throw 'Motor bootstrap kesin CIKIS sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Engine.BootstrapEOF'
    Write-Verbose 'WINLAMA_UI_OK:Engine.BootstrapExactExit'
    return $true
}
function Read-EngineBootstrapRawInput {
    if ([Console]::IsInputRedirected) {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-EngineBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-EngineBootstrapInputLine -Value $value))
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
                (Format-EngineBootstrapInputLine -Value $value))
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
            (Format-EngineBootstrapInputLine -Value $value))
        return $value
    }
    catch {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-EngineBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-EngineBootstrapInputLine -Value $value))
        return $value
    }
}
function Write-EngineBootstrapError {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $command = Get-Command Write-WinlamaUIError `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $Context = Get-WinlamaUIString `
            -Key 'Engine.Operation.FailedContext' -Fallback $Context
        & $command -Context $Context -ErrorRecord $ErrorRecord
        return
    }
    Write-EngineBootstrapRule -Character '='
    Write-EngineBootstrapLine -Text 'ISLEM OZETI' -Color Cyan
    Write-EngineBootstrapStatus -Level ERROR -Message $Context
    Write-EngineBootstrapStatus -Level ERROR `
        -Message $ErrorRecord.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace(
        $ErrorRecord.InvocationInfo.PositionMessage
    )) {
        Write-EngineBootstrapStatus -Level DETAIL `
            -Message $ErrorRecord.InvocationInfo.PositionMessage.Trim()
    }
    Write-EngineBootstrapRule -Character '='
}
function Read-EngineBootstrapInput {
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
    Write-EngineBootstrapRule
    Write-EngineBootstrapStatus -Level INFO -Message $Prompt
    Write-EngineBootstrapStatus -Level DETAIL `
        -Message 'Yalniz tam olarak CIKIS yazin.'
    Write-EngineBootstrapRule
    $value = Read-EngineBootstrapRawInput
    Write-EngineBootstrapRule
    return $value
}
trap {
    Write-EngineBootstrapError -Context 'Beklenmeyen motor hatasi.' `
        -ErrorRecord $_
    if (-not $ValidateOnly -and -not $NoPause) {
        do {
            $answer = Read-EngineBootstrapInput `
                -Prompt 'Oturumu kapatmak icin CIKIS yazin.'
            if (-not (Test-EngineBootstrapExactExit -Value $answer)) {
                Write-EngineBootstrapStatus -Level WARN `
                    -Message 'Bos veya gecersiz komut kabul edilmedi.'
            }
        } while (-not (Test-EngineBootstrapExactExit -Value $answer))
    }
    exit 1
}
Import-Module (Join-Path $PSScriptRoot `
    'Modules\UI\ConsoleUI.psm1') -Force -ErrorAction Stop `
    -Verbose:$false
try {
    $host.UI.RawUI.WindowTitle = Get-WinlamaUIString `
        -Key 'Engine.WindowTitle' `
        -Fallback 'Winlama - Kurulum motoru'
}
catch {
    Write-Verbose ('Pencere basligi ayarlanamadi: {0}' -f `
        $_.Exception.Message)
}
try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
}
catch {
    Write-Verbose ('Konsol kodlamasi ayarlanamadi: {0}' -f `
        $_.Exception.Message)
}
function Resolve-EngineConfigPath {
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
    foreach ($cand in @(
        (Join-Path $PSScriptRoot 'Data\Configs\config.json'),
        (Join-Path $env:LOCALAPPDATA `
            'Programs\Winlama\Data\Configs\config.json')
    )) {
        if (Test-Path -LiteralPath $cand -PathType Leaf) {
            return [IO.Path]::GetFullPath($cand)
        }
    }
    throw [IO.FileNotFoundException]::new(
        'Canonical yapilandirma dosyasi bulunamadi.'
    )
}
$ConfigPath = Resolve-EngineConfigPath -Path $ConfigPath
$localizationModule = Join-Path $PSScriptRoot `
    'Modules\Localization\LocalizationManager.psm1'
if (Test-Path -LiteralPath $localizationModule -PathType Leaf) {
    try {
        Import-Module $localizationModule -Force -ErrorAction Stop `
            -Verbose:$false
        $localizationConfig = (
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
                ConvertFrom-EngineJson
        ).Localization
        $null = Initialize-Localization -ProjectRoot $PSScriptRoot `
            -Configuration $localizationConfig
        try {
            $host.UI.RawUI.WindowTitle = Get-LocalizedText `
                -Key 'Engine.WindowTitle'
        }
        catch {
            Write-Verbose (Get-LocalizedText `
                -Key 'Common.Verbose.WindowTitleUnavailable' `
                -Arguments @($_.Exception.Message))
        }
    }
    catch {
        Write-Verbose ('Yerellestirme baslatilamadi: {0}' -f `
            $_.Exception.Message)
    }
}
if ($null -eq (Get-Command Get-LocalizedText `
    -ErrorAction SilentlyContinue)) {
    function global:Get-LocalizedText {
        param(
            [Parameter(Mandatory)][string]$Key,
            [object[]]$Arguments = @()
        )
        return $Key
    }
}
function Assert-EngineStartupCommitContracts {
    [CmdletBinding()]
    param()
    $source = [IO.File]::ReadAllText($PSCommandPath)
    $finalToken = '-Name FINAL_' + 'VALIDATION'
    $startupToken = '-Name STARTUP_' + 'COMMIT'
    $completeToken = 'Complete-' + 'EngineState'
    $finalIndex = $source.LastIndexOf(
        $finalToken,
        [StringComparison]::Ordinal
    )
    $startupIndex = $source.LastIndexOf(
        $startupToken,
        [StringComparison]::Ordinal
    )
    $completeIndex = $source.LastIndexOf(
        $completeToken,
        [StringComparison]::Ordinal
    )
    $webPath = Join-Path $PSScriptRoot 'Modules\09_WebUI.psm1'
    $webSource = [IO.File]::ReadAllText($webPath)
    $installStart = $webSource.IndexOf(
        'function Install-OpenWebUI {',
        [StringComparison]::Ordinal
    )
    $installEnd = $webSource.IndexOf(
        'function Install-OpenWebUIWithOptionalVoicePolicy {',
        [StringComparison]::Ordinal
    )
    if ($finalIndex -lt 0 -or $startupIndex -le $finalIndex -or
        $completeIndex -le $startupIndex -or $installStart -lt 0 -or
        $installEnd -le $installStart) {
        throw 'Baslangic kisayolu commit sirasi gecersiz.'
    }
    $installBody = $webSource.Substring(
        $installStart,
        $installEnd - $installStart
    )
    if ($installBody.IndexOf(
        'Install-OpenWebUIStartupShortcut',
        [StringComparison]::Ordinal
    ) -ge 0) {
        throw 'Baslangic kisayolu WebUI asamasinda erken yaziliyor.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Engine.StartupCommitOrder'
}
function Get-EngineTranscriptPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [DateTimeOffset]$Timestamp = [DateTimeOffset]::Now,
        [string]$Token = ([guid]::NewGuid().ToString('N'))
    )
    $directory = Join-Path $Context.LogsPath 'Transcripts'
    $name = 'engine-{0}-{1}.transcript.txt' -f @(
        $Timestamp.ToString('yyyyMMdd-HHmmss-fff'),
        $Token
    )
    return Join-Path $directory $name
}
function Assert-EngineTranscriptContracts {
    [CmdletBinding()]
    param()
    $logsPath = [IO.Path]::GetFullPath('C:\Fixture\Logs')
    $context = [pscustomobject]@{ LogsPath = $logsPath }
    $path = Get-EngineTranscriptPath -Context $context `
        -Timestamp ([DateTimeOffset]'2026-08-20T00:00:00+00:00') `
        -Token '0123456789abcdef0123456789abcdef'
    $expectedDirectory = Join-Path $logsPath 'Transcripts'
    if ((Split-Path -Parent $path) -ine $expectedDirectory -or
        [IO.Path]::GetExtension($path) -cne '.txt' -or
        $path -notlike '*.transcript.txt' -or
        $path -like '*.log') {
        throw 'Motor transcript dosyasi JSONL gunluklerinden ayrilmadi.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Engine.TranscriptIsolation'
}
Write-Verbose (Get-LocalizedText -Key 'Verbose.Validation.Started' `
    -Arguments @('Engine.ps1'))
$moduleNames = @(
    '00_Common.psm1',
    '01_Logging.psm1',
    '02_State.psm1',
    '03_Process.psm1',
    '04_Environment.psm1',
    '05_Dependencies.psm1',
    '06_Hardware.psm1',
    '07_Ollama.psm1',
    '08_Models.psm1',
    '09_WebUI.psm1',
    '10_Runtime.psm1',
    '11_Security.psm1',
    '12_Validation.psm1',
    '13_Reporting.psm1'
)
if ($ValidateOnly) {
    $null = Assert-WinlamaUIStandard
    $null = Assert-EngineBootstrapInputContracts
    Assert-EngineStartupCommitContracts
    Assert-EngineTranscriptContracts
    $null = Assert-WinlamaUIInputFormatter -Formatter {
        param([string]$Value)
        Format-EngineBootstrapInputLine -Value $Value
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw (Get-LocalizedText -Key 'Common.Error.ConfigMissing' `
            -Arguments @($ConfigPath))
    }
    $null = Get-Content -LiteralPath $ConfigPath -Raw `
        -Encoding UTF8 | ConvertFrom-EngineJson
    foreach ($moduleName in $moduleNames) {
        $modulePath = Join-Path $PSScriptRoot "Modules\$moduleName"
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw (Get-LocalizedText `
                -Key 'Installer.Error.RequiredFileMissing' `
                -Arguments @($modulePath))
        }
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $modulePath,
            [ref]$tokens,
            [ref]$errors
        )
        if (@($errors).Count -gt 0) {
            throw @($errors)[0]
        }
        Write-Verbose (Get-LocalizedText `
            -Key 'Verbose.Validation.File' `
            -Arguments @($moduleName))
    }
    Write-Verbose (Get-LocalizedText `
        -Key 'Verbose.Validation.Completed' `
        -Arguments @('Engine.ps1'))
    Write-WinlamaUIRule -Character '='
    Write-WinlamaUILine -Text (Get-LocalizedText `
        -Key 'Engine.Banner.Title') -Color Cyan
    Write-WinlamaUIRule -Character '='
    [void](Read-WinlamaUIInput `
        -Prompt 'Dogrulama secim istemi.' `
        -Label ('Se{0}iminiz' -f [char]0x00E7) `
        -InputReader { param([string]$Label) return '0' })
    $errorStyle = Get-WinlamaUIStatusStyle -Level ERROR
    if ($errorStyle.Label -cne 'HATA' -or $errorStyle.Color -cne 'Red') {
        throw 'Motor hata arayuzu renk sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_INPUT_OK:Engine.Validation'
    Write-Verbose 'WINLAMA_UI_ERROR_OK:Engine.Validation'
    Write-Verbose 'WINLAMA_UI_OK:Engine.Status'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Engine.ps1'
    exit 0
}
if ($PSVersionTable.PSVersion -lt [version]'7.6') {
    throw 'Engine.ps1 PowerShell 7.6 veya daha yenisini gerektiriyor.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw (Get-LocalizedText -Key 'Engine.Error.AdminRequired')
}
foreach ($moduleName in $moduleNames) {
    $modulePath = Join-Path $PSScriptRoot "Modules\$moduleName"
    Import-Module $modulePath -Force -ErrorAction Stop `
        -Verbose:$false
}
$config = Read-JsonFile -Path $ConfigPath
$parsedSessionId = [guid]::Empty
if ([string]::IsNullOrWhiteSpace($SessionId)) {
    $savedSession = $config.Installation.PSObject.Properties['SessionId']
    if ($Resume -and $null -ne $savedSession) {
        $SessionId = [string]$savedSession.Value
    }
}
if ([string]::IsNullOrWhiteSpace($SessionId)) {
    $SessionId = [guid]::NewGuid().ToString('D')
}
elseif (-not [guid]::TryParseExact(
    $SessionId,
    'D',
    [ref]$parsedSessionId
) -or $parsedSessionId -eq [guid]::Empty) {
    throw [IO.InvalidDataException]::new(
        'Motor oturum kimligi gecersiz.'
    )
}
$config.Installation | Add-Member -NotePropertyName SessionId `
    -NotePropertyValue $SessionId -Force
$null = Test-DeploymentConfiguration -Config $config
$resolvedPackageRoot = if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    [IO.Path]::GetFullPath($PSScriptRoot)
}
else {
    [IO.Path]::GetFullPath($PackageRoot)
}
$context = New-DeploymentContext -Config $config `
    -PackageRoot $resolvedPackageRoot
Initialize-DeploymentDirectories -Context $context
Initialize-Logging -Context $context
$prioritySet = Set-WinlamaProcessPriority `
    -Priority $config.Runtime.ProcessPriority
Write-DeploymentLog -Context $context `
    -Level $(if ($prioritySet) { 'OK' } else { 'WARN' }) `
    -Module ENGINE -Message $(if ($prioritySet) {
        'Common.Priority.Applied'
    }
    else {
        'Common.Priority.Failed'
    })
$engineLock = $null
$transcriptStarted = $false
$startupShortcutCommitAttempted = $false
$startupShortcutWasValid = $false
try {
    $transcriptPath = Get-EngineTranscriptPath -Context $context
    [IO.Directory]::CreateDirectory(
        (Split-Path -Parent $transcriptPath)
    ) | Out-Null
    try {
        $null = Start-Transcript -LiteralPath $transcriptPath -Append
        $transcriptStarted = $true
    }
    catch {
        Write-DeploymentLog -Context $context -Level WARN `
            -Module LOGGING -Message 'Logging.Transcript.StartFailed' `
            -Exception $_.Exception
    }
    Write-DeploymentConsoleRule -Character '='
    Write-DeploymentConsoleLine -Text (Get-LocalizedText `
        -Key 'Engine.Banner.Title') `
        -Color Cyan
    Write-DeploymentConsoleRule -Character '='
    Assert-DeploymentPrerequisites -Context $context
    $engineLock = Enter-EngineLock -Context $context
    Initialize-EngineState -Context $context
    Repair-InterruptedEngineState -Context $context
    Unregister-DeploymentResumeTask -Context $context
    Write-DeploymentLog -Context $context -Level INFO `
        -Module ENGINE `
        -Message 'Engine.Started' `
        -MessageArguments @($config.EngineVersion)
    $localRetryDelays = @(2, 5)
    $networkRetryDelays = @($config.Network.RetryBackoffSeconds)
    $runtimeRetryDelays = @(5, 15, 30)
    $noRetryDelays = @()
    Invoke-DeploymentStage -Context $context -Name BOOTSTRAP `
        -RetryDelays $localRetryDelays -Force `
        -Action {
            Install-ApplicationPayload -Context $context
        } `
        -Verify {
            Test-ApplicationPayload -Context $context
        }
    Invoke-DeploymentStage -Context $context -Name SECURITY_BASELINE `
        -RetryDelays $localRetryDelays -Force:$ForceRepair `
        -Action {
            Set-TransportSecurity -Context $context
        } `
        -Verify {
            Test-TransportSecurity -Context $context
        }
    Invoke-DeploymentStage -Context $context -Name DEPENDENCIES `
        -RetryDelays $networkRetryDelays -Force:$ForceRepair `
        -Action {
            Install-PlatformDependencies -Context $context
        } `
        -Verify {
            Test-PlatformDependencies -Context $context
        }
    Invoke-DeploymentStage -Context $context -Name ENVIRONMENT `
        -RetryDelays $localRetryDelays -Force:$ForceRepair `
        -Action {
            Sync-SystemEnvironment -Context $context `
                -VerifyChildProcess
        } `
        -Verify {
            Test-SystemEnvironment -Context $context
        }
    Invoke-DeploymentStage -Context $context -Name HARDWARE_ANALYSIS `
        -RetryDelays $localRetryDelays -Force:$ForceRepair `
        -Action {
            Invoke-HardwareDecisionEngine -Context $context
        } `
        -Verify {
            Test-HardwareDecision -Context $context
        }
    Invoke-DeploymentStage -Context $context -Name OLLAMA_CONFIGURATION `
        -RetryDelays $localRetryDelays -Force:$ForceRepair `
        -Action {
            Set-OllamaConfiguration -Context $context
        } `
        -Verify {
            Test-OllamaConfiguration -Context $context
        }
    Invoke-DeploymentStage -Context $context -Name WEBUI_SETUP `
        -RetryDelays $networkRetryDelays -Force:$ForceRepair `
        -Action {
            Install-OpenWebUIWithOptionalVoicePolicy -Context $context
        } `
        -Verify {
            Test-OpenWebUIInstallation -Context $context
        }
    Invoke-DeploymentStage -Context $context -Name RUNTIME `
        -RetryDelays $runtimeRetryDelays -Force:$ForceRepair `
        -Action {
            Start-AiRuntime -Context $context
        } `
        -Verify {
            Test-AiRuntime -Context $context
        } `
        -Rollback {
            Stop-AiRuntime -Context $context
        }
    Invoke-DeploymentStage -Context $context -Name MODEL_DOWNLOAD `
        -RetryDelays $noRetryDelays -Force:$ForceRepair `
        -Action {
            Install-SelectedModels -Context $context
        } `
        -Verify {
            Test-SelectedModels -Context $context
        }
    Invoke-DeploymentStage -Context $context -Name GPU_VALIDATION `
        -RetryDelays $runtimeRetryDelays -Force:$ForceRepair `
        -Action {
            Invoke-GpuInferenceValidation -Context $context
        } `
        -Verify {
            Test-GpuValidationResult -Context $context
        }
    Invoke-DeploymentStage -Context $context -Name SECURITY_HARDENING `
        -RetryDelays $localRetryDelays -Force:$ForceRepair `
        -Action {
            Set-DeploymentSecurity -Context $context
        } `
        -Verify {
            Test-DeploymentSecurity -Context $context
        }
    Invoke-DeploymentStage -Context $context -Name FINAL_VALIDATION `
        -RetryDelays $runtimeRetryDelays -Force:$ForceRepair `
        -Action {
            Invoke-PlatformValidation -Context $context
        } `
        -Verify {
            Test-PlatformValidation -Context $context
        }
    $startupShortcutWasValid = Test-WinlamaStartupShortcut `
        -Context $context
    $startupShortcutCommitAttempted = $true
    Invoke-DeploymentStage -Context $context -Name STARTUP_COMMIT `
        -RetryDelays $localRetryDelays -Force:$ForceRepair `
        -Action {
            $null = Install-WinlamaStartupShortcut -Context $context
        } `
        -Verify {
            Test-WinlamaStartupShortcut -Context $context
        }
    Complete-EngineState -Context $context
    if ($GenerateReport) {
        Write-DashboardReport -Context $context
    }
    Unregister-DeploymentResumeTask -Context $context
    Write-DeploymentLog -Context $context -Level INFO `
        -Module ENGINE -Message 'Engine.Ready'
    $readyMessage = if ($GenerateReport) {
        Get-LocalizedText -Key 'Engine.Ready.Output' `
            -Arguments @($context.DashboardPath)
    }
    else {
        Get-LocalizedText -Key 'Engine.Ready.OutputNoReport'
    }
    Write-WinlamaUIStatus -Level SUCCESS -Message $readyMessage
    if (-not $NoPause) {
        Complete-WinlamaUIOperation `
            -Summary (Get-LocalizedText `
                -Key 'Engine.Operation.Completed') `
            -Level SUCCESS -Command CIKIS
    }
    exit 0
}
catch {
    if ($startupShortcutCommitAttempted -and
        -not $startupShortcutWasValid -and $null -ne $context) {
        try {
            $shortcutPath = Get-WinlamaStartupShortcutPath `
                -Context $context
            Remove-Item -LiteralPath $shortcutPath -Force `
                -ErrorAction Stop
        }
        catch [Management.Automation.ItemNotFoundException] {
        }
        catch {
            Write-DeploymentLog -Context $context -Level WARN `
                -Module ENGINE `
                -Message 'Engine.StartupShortcut.RollbackFailed' `
                -MessageArguments @($_.Exception.Message) `
                -Exception $_.Exception
        }
    }
    if ($null -ne $context) {
        Set-EngineFailure -Context $context -Exception $_.Exception
        Write-DeploymentLog -Context $context -Level FATAL `
            -Module ENGINE -Message 'Engine.Stopped' `
            -Exception $_.Exception
        if ($GenerateReport) {
            Write-DashboardReport -Context $context `
                -ErrorAction SilentlyContinue
        }
    }
    Write-WinlamaUIError -Context (Get-LocalizedText `
        -Key 'Engine.Operation.FailedContext') `
        -ErrorRecord $_
    if (-not $NoPause) {
        Complete-WinlamaUIOperation `
            -Summary (Get-LocalizedText `
                -Key 'Engine.Operation.Failed') `
            -Level ERROR -Command CIKIS
    }
    exit 1
}
finally {
    if ($null -ne $engineLock) {
        Exit-EngineLock -Lock $engineLock
    }
    if ($transcriptStarted) {
        $null = Stop-Transcript -ErrorAction SilentlyContinue
    }
}