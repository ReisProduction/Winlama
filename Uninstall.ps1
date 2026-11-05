#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [switch]$NoPause,
    [AllowEmptyString()][string]$ConfigPath = '',
    [string]$InitiatingUserSid = '',
    [string]$InitiatingUserProfile = '',
    [switch]$ElevatedHost
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertFrom-UninstallJson {
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
$script:UninstallLogPath = $null
$script:UninstallDiagnosticRoot = $null
$script:UninstallConfigPathExplicit = `
    $PSBoundParameters.ContainsKey('ConfigPath')
$script:UninstallResolvedConfigPath = $null
$script:UninstallActionSequence = 0
$script:UninstallLocalizationReady = $false
$script:UninstallMutex = $null
function Write-UninstallBootstrapRule {
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
function Write-UninstallBootstrapLine {
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
            if ($remaining.Length -le $length) {
                $remaining = ''
            }
            else {
                $remaining = $remaining.Substring($length).TrimStart()
            }
        } while ($remaining.Length -gt 0)
    }
}
function Get-UninstallBootstrapStatusStyle {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR',
            'DETAIL', 'SKIP')]
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
function Get-UninstallBootstrapStatusWidth {
    $width = 0
    foreach ($level in @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    )) {
        $style = Get-UninstallBootstrapStatusStyle -Level $level
        $width = [Math]::Max($width, $style.Label.Length)
    }
    return $width
}
function Write-UninstallBootstrapStatus {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR',
            'DETAIL', 'SKIP')]
        [string]$Level,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    $command = Get-Command Write-WinlamaUIStatus `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        & $command -Level $Level -Message $Message
        return
    }
    $style = Get-UninstallBootstrapStatusStyle -Level $Level
    $width = Get-UninstallBootstrapStatusWidth
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
function Format-UninstallBootstrapInputLine {
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
function ConvertFrom-UninstallBootstrapReadValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    if ($null -eq $Value) {
        throw [IO.EndOfStreamException]::new(
            'Standart girdi kapali; zorunlu komut okunamadi.'
        )
    }
    return [string]$Value
}
function Test-UninstallBootstrapExactExit {
    param([AllowNull()][string]$Value)
    return $null -ne $Value -and $Value -ceq 'CIKIS'
}
function Assert-UninstallBootstrapInputContracts {
    $eofRejected = $false
    try {
        $null = ConvertFrom-UninstallBootstrapReadValue -Value $null
    }
    catch [IO.EndOfStreamException] {
        $eofRejected = $true
    }
    if (-not $eofRejected -or
        (ConvertFrom-UninstallBootstrapReadValue -Value '') -cne '') {
        throw 'Kaldirma bootstrap EOF girdi sozlesmesi gecersiz.'
    }
    foreach ($invalid in @('', 'C', 'cikis', 'Cikis', ' CIKIS ')) {
        if (Test-UninstallBootstrapExactExit -Value $invalid) {
            throw 'Kaldirma bootstrap kesin CIKIS sozlesmesi gecersiz.'
        }
    }
    if (-not (Test-UninstallBootstrapExactExit -Value 'CIKIS')) {
        throw 'Kaldirma bootstrap kesin CIKIS sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Uninstall.BootstrapEOF'
    Write-Verbose 'WINLAMA_UI_OK:Uninstall.BootstrapExactExit'
    return $true
}
function Read-UninstallBootstrapRawInput {
    if ([Console]::IsInputRedirected) {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-UninstallBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-UninstallBootstrapInputLine -Value $value))
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
                (Format-UninstallBootstrapInputLine -Value $value))
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
            (Format-UninstallBootstrapInputLine -Value $value))
        return $value
    }
    catch {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-UninstallBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-UninstallBootstrapInputLine -Value $value))
        return $value
    }
}
function Write-UninstallBootstrapError {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $command = Get-Command Write-WinlamaUIError `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        & $command -Context $Context -ErrorRecord $ErrorRecord
        return
    }
    Write-UninstallBootstrapRule -Character '='
    Write-UninstallBootstrapLine -Text 'ISLEM OZETI' -Color Cyan
    Write-UninstallBootstrapStatus -Level ERROR -Message $Context
    Write-UninstallBootstrapStatus -Level ERROR `
        -Message $ErrorRecord.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace(
        $ErrorRecord.InvocationInfo.PositionMessage
    )) {
        Write-UninstallBootstrapStatus -Level DETAIL `
            -Message $ErrorRecord.InvocationInfo.PositionMessage.Trim()
    }
    Write-UninstallBootstrapRule -Character '='
}
function Read-UninstallInput {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Label = ('Se{0}iminiz' -f [char]0x00E7),
        [string]$Hint = '',
        [scriptblock]$InputReader,
        [switch]$NoLeadingRule
    )
    $command = Get-Command Read-WinlamaUIInput `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return & $command -Prompt $Prompt -Label $Label `
            -Hint $Hint -InputReader $InputReader `
            -NoLeadingRule:$NoLeadingRule
    }
    $hasPrompt = -not [string]::IsNullOrWhiteSpace($Prompt) -and
        $Prompt.Trim() -ine $Label.Trim() -and
        $Prompt.Trim() -ine ('Se{0}iminiz' -f [char]0x00E7)
    $hasHint = -not [string]::IsNullOrWhiteSpace($Hint)
    if (-not $NoLeadingRule) {
        Write-UninstallBootstrapRule
    }
    if ($hasPrompt) {
        Write-UninstallBootstrapStatus -Level INFO -Message $Prompt
    }
    if ($hasHint) {
        Write-UninstallBootstrapStatus -Level DETAIL -Message $Hint
    }
    if ($hasPrompt -or $hasHint) {
        Write-UninstallBootstrapRule
    }
    $value = if ($null -eq $InputReader) {
        Read-UninstallBootstrapRawInput
    }
    else {
        $inputValue = [string](& $InputReader $Label)
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-UninstallBootstrapInputLine -Value $inputValue))
        $inputValue
    }
    Write-UninstallBootstrapRule
    return [string]$value
}
function Get-UninstallPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) {
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}
function ConvertTo-UninstallAsciiText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $normalized = $Text.Normalize(
        [Text.NormalizationForm]::FormD
    )
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $normalized.ToCharArray()) {
        $code = [int]$character
        if ($code -le 127) {
            [void]$builder.Append($character)
            continue
        }
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory(
            $character
        )
        if ($category -eq [Globalization.UnicodeCategory]::NonSpacingMark) {
            continue
        }
        $replacement = switch ($code) {
            0x0131 { 'i' }
            0x0130 { 'I' }
            0x2500 { '-' }
            0x2550 { '=' }
            0x2502 { '|' }
            0x2551 { '|' }
            0x250C { '+' }
            0x2510 { '+' }
            0x2514 { '+' }
            0x2518 { '+' }
            0x2554 { '+' }
            0x2557 { '+' }
            0x255A { '+' }
            0x255D { '+' }
            0x00A0 { ' ' }
            default { '?' }
        }
        [void]$builder.Append($replacement)
    }
    return $builder.ToString().Normalize(
        [Text.NormalizationForm]::FormC
    )
}
function Initialize-UninstallLocalization {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $script:UninstallLocalizationReady = $false
    $module = Join-Path $PSScriptRoot `
        'Modules\Localization\LocalizationManager.psm1'
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) {
        Write-Verbose 'Yerellestirme modulu yok; ASCII yedek metin etkin.'
        return $false
    }
    try {
        Import-Module $module -Force -ErrorAction Stop
        $localization = Get-UninstallPropertyValue `
            -InputObject $Config -Name 'Localization'
        $script:UninstallLocalizationReady = [bool](
            Initialize-Localization -ProjectRoot $PSScriptRoot `
                -Configuration $localization
        )
    }
    catch {
        Write-Verbose ('Yerellestirme baslatilamadi: {0}' -f `
            $_.Exception.Message)
        $script:UninstallLocalizationReady = $false
    }
    return $script:UninstallLocalizationReady
}
function Get-UninstallText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$Fallback = $Key,
        [object[]]$Arguments = @()
    )
    $text = $Fallback
    $usingFallback = $true
    if ($script:UninstallLocalizationReady) {
        try {
            $candidate = [string](Get-LocalizedText `
                -Key $Key -Arguments $Arguments)
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and
                $candidate -cne $Key) {
                $text = $candidate
                $usingFallback = $false
            }
        }
        catch {
            Write-Verbose ('Yerellestirilmis metin yedegi: {0} | {1}' -f `
                $Key, $_.Exception.Message)
        }
    }
    if ($usingFallback -and $Arguments.Count -gt 0) {
        try {
            $text = [string]::Format(
                [Globalization.CultureInfo]::CurrentCulture,
                $text,
                $Arguments
            )
        }
        catch {
            Write-Verbose ('Yedek metin bicimlendirilemedi: {0} | {1}' -f `
                $Key, $_.Exception.Message)
        }
    }
    return ConvertTo-UninstallAsciiText -Text $text
}
function Get-UninstallConfirmationText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Fallback
    )
    $text = Get-UninstallText -Key $Key -Fallback $Fallback
    return ($text -replace '\s*\[[^\]]+\]\s*$', '').Trim()
}
function Select-UninstallExistingPath {
    param(
        [Parameter(Mandatory)][string[]]$Candidates,
        [scriptblock]$PathExists = {
            param($Path)
            Test-Path -LiteralPath $Path -PathType Leaf
        }
    )
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (& $PathExists $candidate) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}
function Select-UninstallValidConfigPath {
    param(
        [Parameter(Mandatory)][string[]]$Candidates,
        [scriptblock]$PathExists = {
            param($Path)
            Test-Path -LiteralPath $Path -PathType Leaf
        },
        [scriptblock]$ConfigurationReader = {
            param($Path)
            Read-UninstallConfiguration -Path $Path
        },
        [scriptblock]$RejectionHandler = {
            param($Path, $ErrorRecord)
        }
    )
    $existing = $false
    foreach ($candidate in $Candidates) {
        if (-not (& $PathExists $candidate)) {
            continue
        }
        $existing = $true
        $path = [IO.Path]::GetFullPath($candidate)
        try {
            $null = & $ConfigurationReader $path
            return $path
        }
        catch {
            & $RejectionHandler $path $_
        }
    }
    if ($existing) {
        throw 'Mevcut Winlama yapilandirma dosyalarinin tumu gecersiz.'
    }
    throw 'Winlama yapilandirma dosyasi bulunamadi.'
}
function Resolve-UninstallConfigPath {
    param([switch]$PackageOnly)
    if ($script:UninstallConfigPathExplicit) {
        if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
            throw 'Acik ConfigPath bos olamaz.'
        }
        try {
            $explicitPath = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($ConfigPath)
            )
        }
        catch {
            throw "Acik ConfigPath gecersiz: $ConfigPath"
        }
        if (-not (Test-Path -LiteralPath $explicitPath -PathType Leaf)) {
            throw "Acik ConfigPath bulunamadi: $explicitPath"
        }
        return $explicitPath
    }
    $packageCandidates = @(
        (Join-Path $PSScriptRoot 'Data\Configs\config.json')
    )
    $candidates = if ($PackageOnly) {
        $packageCandidates
    }
    else {
        @(
            (Join-Path $env:LOCALAPPDATA `
                'Programs\Winlama\Data\Configs\config.json')
        ) + $packageCandidates
    }
    return Select-UninstallValidConfigPath -Candidates $candidates `
        -RejectionHandler {
            param($Path, $ErrorRecord)
            $message = 'Gecersiz yapilandirma atlandi: {0} | {1}' -f `
                $Path, $ErrorRecord.Exception.Message
            Write-Verbose $message
            Write-UninstallBootstrapStatus -Level WARN -Message $message
            Write-UninstallLog -Event 'CONFIG_REJECTED' -Level WARN `
                -Message $message -ErrorRecord $ErrorRecord
        }
}
function Get-UninstallRequiredConfigValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context,
        [switch]$String
    )
    $value = Get-UninstallPropertyValue -InputObject $InputObject `
        -Name $Name
    if ($null -eq $value -or
        ($String -and [string]::IsNullOrWhiteSpace([string]$value))) {
        throw "Zorunlu yapilandirma alani eksik: $Context.$Name"
    }
    return $value
}
function Assert-UninstallConfigExactPath {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Context
    )
    try {
        $actualPath = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables($Value)
        ).TrimEnd('\')
        $expectedPath = [IO.Path]::GetFullPath($Expected).TrimEnd('\')
    }
    catch {
        throw "Gecersiz yapilandirma yolu: $Context | $Value"
    }
    if (-not $actualPath.Equals(
        $expectedPath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Guvenli olmayan yapilandirma yolu: $Context | $actualPath"
    }
}
function Assert-UninstallConfigurationContract {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $paths = Get-UninstallRequiredConfigValue -InputObject $Config `
        -Name 'Paths' -Context 'Config'
    $rootPath = [string](Get-UninstallRequiredConfigValue `
        -InputObject $paths -Name 'Root' -Context 'Paths' -String)
    $logsPath = [string](Get-UninstallRequiredConfigValue `
        -InputObject $paths -Name 'Logs' -Context 'Paths' -String)
    $modelsPath = [string](Get-UninstallRequiredConfigValue `
        -InputObject $paths -Name 'Models' -Context 'Paths' -String)
    Assert-UninstallConfigExactPath -Value $rootPath `
        -Expected (Join-Path $env:LOCALAPPDATA 'Programs\Winlama') `
        -Context 'Paths.Root'
    $expandedRoot = [Environment]::ExpandEnvironmentVariables($rootPath)
    $resolvedLogs = if ([IO.Path]::IsPathRooted(
        [Environment]::ExpandEnvironmentVariables($logsPath)
    )) {
        [Environment]::ExpandEnvironmentVariables($logsPath)
    }
    else {
        Join-Path $expandedRoot $logsPath
    }
    Assert-UninstallConfigExactPath -Value $resolvedLogs `
        -Expected (Join-Path $expandedRoot 'Logs') `
        -Context 'Paths.Logs'
    Assert-UninstallConfigExactPath -Value $modelsPath `
        -Expected (Join-Path $env:USERPROFILE '.ollama\models') `
        -Context 'Paths.Models'
    $ollama = Get-UninstallRequiredConfigValue -InputObject $Config `
        -Name 'Ollama' -Context 'Config'
    $ollamaPath = [string](Get-UninstallRequiredConfigValue `
        -InputObject $ollama -Name 'InstallPath' -Context 'Ollama' `
        -String)
    Assert-UninstallConfigExactPath -Value $ollamaPath `
        -Expected (Join-Path $env:LOCALAPPDATA 'Programs\Ollama') `
        -Context 'Ollama.InstallPath'
    $portValue = Get-UninstallRequiredConfigValue `
        -InputObject $ollama -Name 'Port' -Context 'Ollama'
    $port = 0
    if (-not [int]::TryParse([string]$portValue, [ref]$port) -or
        $port -lt 1 -or $port -gt 65535) {
        throw "Gecersiz yapilandirma alani: Ollama.Port | $portValue"
    }
    $openWebUI = Get-UninstallRequiredConfigValue `
        -InputObject $Config -Name 'OpenWebUI' -Context 'Config'
    $openWebUIRoot = [string](Get-UninstallRequiredConfigValue `
        -InputObject $openWebUI -Name 'RootPath' `
        -Context 'OpenWebUI' -String)
    Assert-UninstallConfigExactPath -Value $openWebUIRoot `
        -Expected (Join-Path $env:USERPROFILE '.openui') `
        -Context 'OpenWebUI.RootPath'
    $startup = Get-UninstallRequiredConfigValue -InputObject $Config `
        -Name 'Startup' -Context 'Config'
    $shortcutPath = [string](Get-UninstallRequiredConfigValue `
        -InputObject $startup -Name 'ShortcutPath' `
        -Context 'Startup' -String)
    $startupRoot = [Environment]::ExpandEnvironmentVariables(
        '%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup'
    )
    Assert-UninstallConfigExactPath -Value $shortcutPath `
        -Expected (Join-Path $startupRoot 'Winlama.lnk') `
        -Context 'Startup.ShortcutPath'
    $uninstall = Get-UninstallRequiredConfigValue `
        -InputObject $Config -Name 'Uninstall' -Context 'Config'
    $taskName = [string](Get-UninstallRequiredConfigValue `
        -InputObject $uninstall -Name 'ResumeTaskName' `
        -Context 'Uninstall' -String)
    if ($taskName -cne 'Winlama-Deployment-Resume') {
        throw "Gecersiz yapilandirma alani: Uninstall.ResumeTaskName"
    }
    $environmentVariables = @(
        Get-UninstallRequiredConfigValue -InputObject $uninstall `
            -Name 'EnvironmentVariables' -Context 'Uninstall'
    )
    $expectedVariables = @(
        'OLLAMA_HOST', 'OLLAMA_MODELS', 'OLLAMA_ORIGINS'
    )
    if ($environmentVariables.Count -ne $expectedVariables.Count -or
        (($environmentVariables | Sort-Object -Unique) -join ',') -cne `
            (($expectedVariables | Sort-Object) -join ',')) {
        throw 'Gecersiz yapilandirma alani: Uninstall.EnvironmentVariables'
    }
    $security = Get-UninstallRequiredConfigValue -InputObject $Config `
        -Name 'Security' -Context 'Config'
    $firewall = Get-UninstallRequiredConfigValue -InputObject $security `
        -Name 'FirewallRules' -Context 'Security'
    $expectedRules = [ordered]@{
        OllamaLanAllow = 'Winlama-Ollama-LAN'
        WebUILanAllow = 'Winlama-WebUI-LAN'
        OllamaLocalOnly = 'Winlama-Ollama-LocalOnly'
        WebUILocalOnly = 'Winlama-WebUI-LocalOnly'
    }
    if (@($firewall.PSObject.Properties).Count -ne `
        $expectedRules.Count) {
        throw 'Gecersiz yapilandirma alani: Security.FirewallRules'
    }
    foreach ($ruleName in $expectedRules.Keys) {
        $ruleValue = [string](Get-UninstallRequiredConfigValue `
            -InputObject $firewall -Name $ruleName `
            -Context 'Security.FirewallRules' -String)
        if ($ruleValue -cne $expectedRules[$ruleName]) {
            throw "Gecersiz guvenlik duvari kurali: $ruleName"
        }
    }
    $comfyUI = Get-UninstallRequiredConfigValue `
        -InputObject $Config -Name 'ComfyUI' -Context 'Config'
    $comfyInstall = [string](Get-UninstallRequiredConfigValue `
        -InputObject $comfyUI -Name 'InstallPath' `
        -Context 'ComfyUI' -String)
    $comfyModels = [string](Get-UninstallRequiredConfigValue `
        -InputObject $comfyUI -Name 'ModelsPath' `
        -Context 'ComfyUI' -String)
    Assert-UninstallConfigExactPath -Value $comfyInstall `
        -Expected (Join-Path $env:LOCALAPPDATA 'Programs\ComfyUI') `
        -Context 'ComfyUI.InstallPath'
    Assert-UninstallConfigExactPath -Value $comfyModels `
        -Expected (Join-Path $env:USERPROFILE '.comfyui\models') `
        -Context 'ComfyUI.ModelsPath'
    $dependencies = @(Get-UninstallRequiredConfigValue `
        -InputObject $Config -Name 'Dependencies' -Context 'Config')
    $python = @($dependencies | Where-Object {
        [string](Get-UninstallPropertyValue -InputObject $_ `
            -Name 'Name') -ceq 'Python'
    })
    if ($python.Count -ne 1) {
        throw 'Python bagimlilik semasi eksik veya belirsiz.'
    }
    $pythonId = [string](Get-UninstallRequiredConfigValue `
        -InputObject $python[0] -Name 'WingetId' `
        -Context 'Dependencies.Python' -String)
    $pythonVersionText = [string](Get-UninstallRequiredConfigValue `
        -InputObject $python[0] -Name 'WingetVersion' `
        -Context 'Dependencies.Python' -String)
    $pythonVersion = $null
    if ($pythonId -cne 'Python.Python.3.11' -or
        -not [version]::TryParse($pythonVersionText, [ref]$pythonVersion) -or
        $pythonVersion.Major -ne 3 -or $pythonVersion.Minor -ne 11) {
        throw 'Gecersiz Python bagimlilik semasi.'
    }
}
function Read-UninstallConfiguration {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-UninstallJson
    }
    catch {
        throw "Winlama yapilandirma dosyasi gecersiz: $Path | $($_.Exception.Message)"
    }
    foreach ($name in @(
        'Paths', 'Dependencies', 'Ollama', 'OpenWebUI', 'Startup',
        'Runtime', 'Uninstall', 'Security', 'ComfyUI'
    )) {
        if ($null -eq (Get-UninstallPropertyValue `
            -InputObject $config -Name $name)) {
            throw "Zorunlu yapilandirma bolumu eksik: $name"
        }
    }
    Assert-UninstallConfigurationContract -Config $config
    return $config
}
function Resolve-UninstallDiagnosticRoot {
    param([AllowNull()][pscustomobject]$Config)
    $null = $Config
    $logs = [IO.Path]::GetFullPath(
        (Join-Path ([IO.Path]::GetTempPath()) 'Winlama-Logs')
    ).TrimEnd('\')
    $packageRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    $installedRoot = [IO.Path]::GetFullPath(
        (Join-Path $env:LOCALAPPDATA 'Programs\Winlama')
    ).TrimEnd('\')
    foreach ($forbiddenRoot in @($packageRoot, $installedRoot)) {
        if ($logs.Equals(
                $forbiddenRoot,
                [StringComparison]::OrdinalIgnoreCase
            ) -or $logs.StartsWith(
                $forbiddenRoot + '\',
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Tanilama dizini kaldirma kokunde olamaz: $logs"
        }
    }
    return $logs
}
function Set-UninstallDiagnosticRoot {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $script:UninstallDiagnosticRoot = `
        Resolve-UninstallDiagnosticRoot -Config $Config
    $script:UninstallLogPath = $null
}
function Write-UninstallLog {
    param(
        [Parameter(Mandatory)][string]$Event,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO',
        [string]$ActionId = '',
        [string]$Action = '',
        [AllowNull()]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    if ($ValidateOnly) {
        Write-Verbose ('UNINSTALL_LOG|{0}|{1}|{2}|{3}' -f `
            $Level, $Event, $ActionId, $Message)
        return
    }
    try {
        $directory = if ([string]::IsNullOrWhiteSpace(
            $script:UninstallDiagnosticRoot
        )) {
            Resolve-UninstallDiagnosticRoot -Config $null
        }
        else {
            $script:UninstallDiagnosticRoot
        }
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [IO.Directory]::CreateDirectory($directory) | Out-Null
        }
        if ([string]::IsNullOrWhiteSpace($script:UninstallLogPath)) {
            $name = 'uninstall-{0}-{1}.log' -f @(
                [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff'),
                [guid]::NewGuid().ToString('N')
            )
            $script:UninstallLogPath = Join-Path $directory $name
        }
        $canonicalLevel = if ($Level -eq 'SUCCESS') {
            'INFO'
        }
        else {
            $Level
        }
        $displayLevel = switch ($Level) {
            'SUCCESS' { Get-UninstallText -Key 'Common.Level.Ok' }
            'ERROR' { Get-UninstallText -Key 'Common.Level.Error' }
            'WARN' { Get-UninstallText -Key 'Common.Level.Warning' }
            default { Get-UninstallText -Key 'Common.Level.Info' }
        }
        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('O')
            level = $canonicalLevel
            displayLevel = $displayLevel
            moduleCode = 'UNINSTALL'
            eventCode = $Event
            actionId = $ActionId
            action = $Action
            message = $Message
            errorType = if ($null -eq $ErrorRecord) {
                ''
            }
            else {
                $ErrorRecord.Exception.GetType().FullName
            }
            errorMessage = if ($null -eq $ErrorRecord) {
                ''
            }
            else {
                $ErrorRecord.Exception.Message
            }
            processId = $PID
        }
        $json = $entry | ConvertTo-Json -Compress
        [IO.File]::AppendAllText(
            $script:UninstallLogPath,
            $json + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
    }
    catch {
        Write-UninstallBootstrapStatus -Level WARN -Message (
            Get-UninstallText `
                -Key 'Uninstall.Warning.LogWriteFailed' `
                -Fallback 'Kaldirma gunlugu yazilamadi: {0}' `
                -Arguments @($_.Exception.Message)
        )
    }
}
function Test-UninstallAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}
function Test-UninstallUserContextMatch {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$ExpectedSid = '',
        [AllowEmptyString()][string]$ExpectedProfile = '',
        [AllowEmptyString()][string]$ActualSid = '',
        [AllowEmptyString()][string]$ActualProfile = ''
    )
    $expectedSidMissing = [string]::IsNullOrWhiteSpace($ExpectedSid)
    $expectedProfileMissing =
        [string]::IsNullOrWhiteSpace($ExpectedProfile)
    if ($expectedSidMissing -and $expectedProfileMissing) {
        return $true
    }
    if ($expectedSidMissing -or $expectedProfileMissing -or
        [string]::IsNullOrWhiteSpace($ActualSid) -or
        [string]::IsNullOrWhiteSpace($ActualProfile) -or
        $ExpectedSid -cne $ActualSid) {
        return $false
    }
    try {
        $expectedFullPath = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables($ExpectedProfile)
        ).TrimEnd('\')
        $actualFullPath = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables($ActualProfile)
        ).TrimEnd('\')
        return $expectedFullPath.Equals(
            $actualFullPath,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}
function Assert-UninstallElevatedUserContext {
    [CmdletBinding()]
    param()
    if ([string]::IsNullOrWhiteSpace($InitiatingUserSid) -and
        [string]::IsNullOrWhiteSpace($InitiatingUserProfile)) {
        return
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $actualSid = if ($null -eq $identity.User) {
        ''
    }
    else {
        [string]$identity.User.Value
    }
    $actualProfile = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile
    )
    if (-not (Test-UninstallUserContextMatch `
        -ExpectedSid $InitiatingUserSid `
        -ExpectedProfile $InitiatingUserProfile `
        -ActualSid $actualSid -ActualProfile $actualProfile)) {
        throw [UnauthorizedAccessException]::new(
            (Get-UninstallText `
                -Key 'Uninstall.Error.ElevatedUserMismatch' `
                -Fallback ('Yonetici izni farkli bir Windows hesabi ile ' +
                    'verildi. Kullaniciya ozel kaldirma durduruldu.'))
        )
    }
}
function Enter-UninstallMutex {
    if ($ValidateOnly) {
        throw 'ValidateOnly sirasinda kaldirma kilidi istendi.'
    }
    $createdNew = $false
    $mutex = [Threading.Mutex]::new(
        $false,
        'Local\Winlama.Uninstall.26.8.6',
        [ref]$createdNew
    )
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw 'Baska bir Winlama kaldirma islemi zaten calisiyor.'
        }
        $script:UninstallMutex = $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}
function Exit-UninstallMutex {
    if ($null -eq $script:UninstallMutex) {
        return
    }
    try {
        $script:UninstallMutex.ReleaseMutex()
    }
    catch {
        Write-Verbose ('Kaldirma kilidi birakilamadi: {0}' -f `
            $_.Exception.Message)
    }
    finally {
        $script:UninstallMutex.Dispose()
        $script:UninstallMutex = $null
    }
}
function Test-UninstallLauncherParent {
    param(
        [AllowNull()][string]$ExecutablePath,
        [AllowNull()][string]$CommandLine,
        [Parameter(Mandatory)][string]$LauncherPath
    )
    try {
        if ([string]::IsNullOrWhiteSpace($ExecutablePath) -or
            [string]::IsNullOrWhiteSpace($CommandLine) -or
            [IO.Path]::GetFileName($ExecutablePath) -notin @(
                'powershell.exe', 'pwsh.exe'
            )) {
            return $false
        }
        $match = [regex]::Match(
            $CommandLine,
            '(?i)(?:^|\s)-File(?:\s+|=)' +
            '(?:"(?<Path>[^"]+)"|(?<Path>\S+))'
        )
        if (-not $match.Success) {
            return $false
        }
        $candidate = [Environment]::ExpandEnvironmentVariables(
            $match.Groups['Path'].Value
        )
        if (-not [IO.Path]::IsPathRooted($candidate)) {
            return $false
        }
        return [IO.Path]::GetFullPath($candidate).Equals(
            [IO.Path]::GetFullPath($LauncherPath),
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}
function Get-UninstallParentProcessIdentity {
    try {
        $current = Get-CimInstance -ClassName Win32_Process `
            -Filter "ProcessId = $PID" -ErrorAction Stop
        $parentId = [int](Get-UninstallPropertyValue `
            -InputObject $current -Name 'ParentProcessId')
        if ($parentId -le 0 -or $parentId -eq $PID) {
            return $null
        }
        $parentRecord = Get-CimInstance -ClassName Win32_Process `
            -Filter "ProcessId = $parentId" -ErrorAction Stop
        $executable = [string](Get-UninstallPropertyValue `
            -InputObject $parentRecord -Name 'ExecutablePath')
        $commandLine = [string](Get-UninstallPropertyValue `
            -InputObject $parentRecord -Name 'CommandLine')
        $launcherPath = Join-Path $PSScriptRoot 'Launcher.ps1'
        if (-not (Test-UninstallLauncherParent `
            -ExecutablePath $executable -CommandLine $commandLine `
            -LauncherPath $launcherPath)) {
            return $null
        }
        $parent = Get-Process -Id $parentId -ErrorAction Stop
        return [pscustomobject]@{
            ProcessId = $parentId
            StartTicks = $parent.StartTime.ToUniversalTime().Ticks
        }
    }
    catch {
        Write-Verbose ('Cagiran surec kimligi cozumlenemedi: {0}' -f `
            $_.Exception.Message)
        return $null
    }
}
function Start-ElevatedUninstall {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity.User) {
        throw 'Kullanici SID bilgisi okunamadi.'
    }
    $initiatingSid = [string]$identity.User.Value
    $initiatingProfile = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-InitiatingUserSid', $initiatingSid,
        '-InitiatingUserProfile',
        (ConvertTo-UninstallCommandLineArgument `
            -Value $initiatingProfile),
        '-ElevatedHost'
    )
    if ($NoPause) {
        $arguments += '-NoPause'
    }
    if ($script:UninstallConfigPathExplicit) {
        if ([string]::IsNullOrWhiteSpace(
            $script:UninstallResolvedConfigPath
        )) {
            throw 'Yukseltilmis surec icin ConfigPath cozumlenemedi.'
        }
        $arguments += @(
            '-ConfigPath',
            (ConvertTo-UninstallCommandLineArgument `
                -Value $script:UninstallResolvedConfigPath)
        )
    }
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $arguments += '-Verbose'
    }
    try {
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList $arguments -WorkingDirectory $PSScriptRoot `
            -WindowStyle Normal -Verb RunAs -PassThru -ErrorAction Stop
        if ($null -eq $process) {
            throw 'Yonetici sureci olusturulamadi.'
        }
        $process.Dispose()
        return 0
    }
    catch {
        Write-UninstallBootstrapError `
            -Context (Get-UninstallText `
                -Key 'Uninstall.Error.AdminDenied' `
                -Fallback ('Yonetici izni verilmedi; ' +
                    'islem baslatilmadi.')) `
            -ErrorRecord $_
        if (Test-UninstallPauseRequired) {
            Complete-WinlamaUIOperation `
                -Summary (Get-UninstallText `
                    -Key 'Uninstall.Operation.AdminDenied' `
                    -Fallback ('Yonetici izni verilmedigi icin ' +
                        'islem yapilmadi.')) `
                -Level ERROR -Command CIKIS
        }
        return 1
    }
}
function Get-UninstallBroadPaths {
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        [IO.Path]::GetPathRoot($PSScriptRoot),
        $env:SystemRoot,
        $env:USERPROFILE,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:ProgramData,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        [IO.Path]::GetTempPath()
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        try {
            $full = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
            if ($full -notin $paths) {
                $paths.Add($full)
            }
        }
        catch {
            Write-Verbose ('Genis yol atlandi: {0}' -f $candidate)
        }
    }
    return $paths.ToArray()
}
function Test-UninstallPathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [switch]$AllowRoot
    )
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($fullPath.Equals(
        $fullRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        return $AllowRoot.IsPresent
    }
    return $fullPath.StartsWith(
        $fullRoot + '\',
        [StringComparison]::OrdinalIgnoreCase
    )
}
function Assert-UninstallExactPath {
    param(
        [Parameter(Mandatory)][string]$Actual,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    $fullActual = [IO.Path]::GetFullPath($Actual).TrimEnd('\')
    $fullExpected = [IO.Path]::GetFullPath($Expected).TrimEnd('\')
    if (-not $fullActual.Equals(
        $fullExpected,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Label kesin hedefle eslesmiyor: $fullActual"
    }
    return $fullActual
}
function Test-UninstallReparseAttribute {
    param([IO.FileAttributes]$Attributes)
    return ($Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}
function Assert-UninstallNoReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRoot,
        [switch]$Recurse
    )
    $cursor = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    while (Test-UninstallPathWithin -Path $cursor -Root $root -AllowRoot) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force `
                -ErrorAction Stop
            if (Test-UninstallReparseAttribute `
                -Attributes $item.Attributes) {
                throw "Yeniden ayrisim noktasi guvenli hedef degil: $cursor"
            }
        }
        if ($cursor.Equals(
            $root,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            break
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent -eq $cursor) {
            break
        }
        $cursor = $parent.TrimEnd('\')
    }
    if (-not $Recurse -or
        -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force `
        -Recurse -ErrorAction Stop)) {
        if (Test-UninstallReparseAttribute `
            -Attributes $item.Attributes) {
            throw "Kaldirma hedefinde yeniden ayrisim noktasi var: $($item.FullName)"
        }
    }
}
function Resolve-SafeUninstallPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedRoots,
        [switch]$AllowRoot,
        [switch]$Recurse,
        [switch]$SkipReparseCheck
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path.StartsWith('\\?\') -or
        $Path.StartsWith('\\.\') -or
        $Path.StartsWith('\\')) {
        throw "Guvenli olmayan kaldirma yolu: $Path"
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        throw "Kaldirma yolu mutlak olmali: $Path"
    }
    $fullPath = [IO.Path]::GetFullPath($expanded).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($fullPath) -or
        $fullPath -cmatch '^[A-Za-z]:$') {
        throw "Genis kaldirma yolu reddedildi: $fullPath"
    }
    foreach ($broad in @(Get-UninstallBroadPaths)) {
        if ($fullPath.Equals(
            $broad,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Genis kaldirma yolu reddedildi: $fullPath"
        }
    }
    $matchedRoot = $null
    foreach ($allowedRoot in $AllowedRoots) {
        if ([string]::IsNullOrWhiteSpace($allowedRoot)) {
            continue
        }
        $expandedRoot = [Environment]::ExpandEnvironmentVariables(
            $allowedRoot
        )
        if (-not [IO.Path]::IsPathRooted($expandedRoot)) {
            throw "Izin verilen kaldirma koku mutlak olmali: $allowedRoot"
        }
        $root = [IO.Path]::GetFullPath($expandedRoot).TrimEnd('\')
        if (Test-UninstallPathWithin -Path $fullPath -Root $root `
            -AllowRoot:$AllowRoot) {
            $matchedRoot = $root
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($matchedRoot)) {
        throw "Kaldirma yolu izin listesinin disinda: $fullPath"
    }
    if (-not $SkipReparseCheck) {
        Assert-UninstallNoReparsePoint -Path $fullPath `
            -AllowedRoot $matchedRoot -Recurse:$Recurse
    }
    return $fullPath
}
function Remove-UninstallPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$AllowedRoots,
        [switch]$AllowRoot,
        [switch]$Recurse
    )
    if ($ValidateOnly) {
        throw 'ValidateOnly sirasinda silme fonksiyonu cagrildi.'
    }
    $fullPath = Resolve-SafeUninstallPath -Path $Path `
        -AllowedRoots $AllowedRoots -AllowRoot:$AllowRoot `
        -Recurse:$Recurse
    if (-not (Test-Path -LiteralPath $fullPath)) {
        Write-UninstallLog -Event 'PATH_ALREADY_ABSENT' `
            -Action $Label -Message $fullPath
        Write-UninstallBootstrapStatus -Level SKIP `
            -Message (Get-UninstallText `
                -Key 'Uninstall.Path.AlreadyAbsent' `
                -Fallback '{0} zaten yok: {1}' `
                -Arguments @($Label, $fullPath))
        return $false
    }
    Write-UninstallBootstrapStatus -Level DETAIL `
        -Message (Get-UninstallText `
            -Key 'Uninstall.Path.Target' `
            -Fallback '{0} hedefi: {1}' `
            -Arguments @($Label, $fullPath))
    Write-UninstallLog -Event 'PATH_REMOVAL_STARTED' `
        -Action $Label -Message $fullPath
    Remove-Item -LiteralPath $fullPath -Force `
        -Recurse:$Recurse -ErrorAction Stop
    if (Test-Path -LiteralPath $fullPath) {
        throw "$Label kaldirma son kosulu basarisiz: $fullPath"
    }
    Write-UninstallBootstrapStatus -Level SUCCESS `
        -Message (Get-UninstallText `
            -Key 'Uninstall.Path.Removed' `
            -Fallback '{0} kaldirildi.' -Arguments @($Label))
    Write-UninstallLog -Event 'PATH_REMOVAL_COMPLETED' `
        -Level SUCCESS -Action $Label -Message $fullPath
    return $true
}
function ConvertTo-UninstallCommandLineArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and
        $Value -notmatch '[\s"]') {
        return $Value
    }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) {
            [void]$builder.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) {
        [void]$builder.Append(('\' * ($slashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}
function Wait-UninstallNativeOutputTasks {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Threading.Tasks.Task[]]$Tasks,
        [ValidateRange(1, 60000)]
        [int]$TimeoutMilliseconds
    )
    if ($Tasks.Count -eq 0) {
        return $true
    }
    try {
        return [Threading.Tasks.Task]::WaitAll(
            $Tasks,
            $TimeoutMilliseconds
        )
    }
    catch {
        return $false
    }
}
function Stop-UninstallNativeProcessTree {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [ValidateRange(1000, 60000)]
        [int]$WaitMilliseconds = 5000,
        [scriptblock]$LegacyTreeKiller = {
            param($TargetProcessId, $TimeoutMilliseconds)
            $system32 = Join-Path $env:SystemRoot 'System32'
            $taskkill = Join-Path $system32 'taskkill.exe'
            if (-not (Test-Path -LiteralPath $taskkill -PathType Leaf) -or
                -not (Test-UninstallTrustedSigner -FilePath $taskkill `
                    -SubjectPattern 'Microsoft (Corporation|Windows)')) {
                throw 'Guvenilir taskkill.exe bulunamadi.'
            }
            $taskkill = Resolve-SafeUninstallPath -Path $taskkill `
                -AllowedRoots @($system32)
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $taskkill
            $info.Arguments = "/PID $TargetProcessId /T /F"
            $info.WorkingDirectory = $system32
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $killer = [Diagnostics.Process]::new()
            $killer.StartInfo = $info
            try {
                if (-not $killer.Start()) {
                    throw 'taskkill.exe baslatilamadi.'
                }
                $stdoutTask = $killer.StandardOutput.ReadToEndAsync()
                $stderrTask = $killer.StandardError.ReadToEndAsync()
                if (-not $killer.WaitForExit($TimeoutMilliseconds)) {
                    try {
                        $killer.Kill()
                    }
                    catch {
                    }
                    throw 'taskkill.exe zaman asimina ugradi.'
                }
                $tasks = [Threading.Tasks.Task[]]@(
                    $stdoutTask,
                    $stderrTask
                )
                $outputComplete = Wait-UninstallNativeOutputTasks `
                    -Tasks $tasks -TimeoutMilliseconds 2000
                $errorText = if ($outputComplete) {
                    $stderrTask.GetAwaiter().GetResult().Trim()
                }
                else {
                    ''
                }
                if ($killer.ExitCode -ne 0) {
                    throw ('taskkill.exe surec agacini durduramadi. ' +
                        "Cikis kodu: $($killer.ExitCode) | $errorText")
                }
            }
            finally {
                $killer.Dispose()
            }
        }
    )
    if ($Process.HasExited) {
        return
    }
    $treeKill = $Process.GetType().GetMethod(
        'Kill',
        [Reflection.BindingFlags]::Instance -bor
            [Reflection.BindingFlags]::Public,
        $null,
        [type[]]@([bool]),
        $null
    )
    $treeKillInvoked = $false
    if ($null -ne $treeKill) {
        try {
            $null = $treeKill.Invoke(
                $Process,
                [object[]]@($true)
            )
            $treeKillInvoked = $true
        }
        catch {
            Write-Verbose ('Kill(true) surec agaci durduramadi: {0}' -f `
                $_.Exception.Message)
        }
    }
    if ($treeKillInvoked -and
        $Process.WaitForExit($WaitMilliseconds)) {
        return
    }
    if (-not $Process.HasExited) {
        try {
            & $LegacyTreeKiller $Process.Id $WaitMilliseconds
        }
        catch {
            try {
                $Process.Kill()
                $null = $Process.WaitForExit($WaitMilliseconds)
            }
            catch {
            }
            throw
        }
    }
    if (-not $Process.HasExited -and
        -not $Process.WaitForExit($WaitMilliseconds)) {
        throw "Surec agaci durdurulamadi: $($Process.Id)"
    }
}
function Invoke-UninstallNativeProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$RawArguments = '',
        [int[]]$AllowedExitCodes = @(0),
        [int]$TimeoutSeconds = 900,
        [string]$ActionId = '',
        [string]$Action = 'Native process',
        [switch]$SuppressUiOutput
    )
    if ($ValidateOnly) {
        throw 'ValidateOnly sirasinda yerel surec cagrildi.'
    }
    $resolved = $FilePath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        $command = Get-Command $FilePath -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            throw "Yerel calistirilabilir dosya bulunamadi: $FilePath"
        }
        $resolved = $command.Source
    }
    $arguments = if (-not [string]::IsNullOrWhiteSpace($RawArguments)) {
        $RawArguments
    }
    else {
        @($ArgumentList | ForEach-Object {
            ConvertTo-UninstallCommandLineArgument -Value ([string]$_)
        }) -join ' '
    }
    Write-UninstallLog -Event 'NATIVE_STARTED' -ActionId $ActionId `
        -Action $Action -Message "$resolved $arguments"
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $resolved
    $info.Arguments = $arguments
    $info.WorkingDirectory = Split-Path -Parent $resolved
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) {
            throw "Yerel surec baslamadi: $resolved"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $terminationError = ''
            try {
                Stop-UninstallNativeProcessTree -Process $process
            }
            catch {
                $terminationError = $_.Exception.Message
            }
            $timeoutTasks = [Threading.Tasks.Task[]]@(
                $stdoutTask,
                $stderrTask
            )
            $timeoutOutputComplete = Wait-UninstallNativeOutputTasks `
                -Tasks $timeoutTasks -TimeoutMilliseconds 5000
            if (-not $timeoutOutputComplete) {
                try {
                    $process.StandardOutput.Dispose()
                }
                catch {
                }
                try {
                    $process.StandardError.Dispose()
                }
                catch {
                }
            }
            $message = "Yerel surec $TimeoutSeconds saniyede zaman asimina ugradi."
            if (-not [string]::IsNullOrWhiteSpace($terminationError)) {
                $message += " Surec agaci hatasi: $terminationError"
            }
            throw $message
        }
        $outputTasks = [Threading.Tasks.Task[]]@(
            $stdoutTask,
            $stderrTask
        )
        $outputComplete = Wait-UninstallNativeOutputTasks `
            -Tasks $outputTasks -TimeoutMilliseconds 5000
        if (-not $outputComplete) {
            try {
                $process.StandardOutput.Dispose()
            }
            catch {
            }
            try {
                $process.StandardError.Dispose()
            }
            catch {
            }
            Write-Verbose ('Yerel surec cikti kanallari sinirli ' +
                "surede kapanmadi: $resolved")
        }
        $stdout = if ($outputComplete) {
            $stdoutTask.GetAwaiter().GetResult().Trim()
        }
        else {
            ''
        }
        $stderr = if ($outputComplete) {
            $stderrTask.GetAwaiter().GetResult().Trim()
        }
        else {
            ''
        }
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
    foreach ($stream in @(
        [pscustomobject]@{ Name = 'stdout'; Value = $stdout },
        [pscustomobject]@{ Name = 'stderr'; Value = $stderr }
    )) {
        if ([string]::IsNullOrWhiteSpace($stream.Value)) {
            continue
        }
        $value = [string]$stream.Value
        if ($value.Length -gt 4000) {
            $value = $value.Substring(0, 4000) + ' [truncated]'
        }
        Write-UninstallLog -Event 'NATIVE_OUTPUT' -ActionId $ActionId `
            -Action $Action -Message ("{0}: {1}" -f `
                $stream.Name, $value)
        if (-not $SuppressUiOutput) {
            Write-UninstallBootstrapStatus -Level DETAIL `
                -Message ("{0}: {1}" -f $stream.Name, $value)
        }
    }
    Write-UninstallLog -Event 'NATIVE_COMPLETED' -ActionId $ActionId `
        -Action $Action -Message "Cikis kodu: $exitCode"
    if ($exitCode -notin $AllowedExitCodes) {
        throw "$Action $exitCode cikis koduyla basarisiz oldu."
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        OutputComplete = $outputComplete
        StandardOutput = $stdout
        StandardError = $stderr
    }
}
function Get-UninstallRegistryEntries {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($root in $roots) {
        foreach ($entry in @(Get-ItemProperty -Path "$root\*" `
            -ErrorAction SilentlyContinue)) {
            $entries.Add($entry)
        }
    }
    return $entries.ToArray()
}
function Get-UninstallDisplayName {
    param([AllowNull()][object]$Entry)
    $value = Get-UninstallPropertyValue -InputObject $Entry `
        -Name 'DisplayName'
    if ($null -eq $value) {
        return ''
    }
    return [string]$value
}
function Get-UninstallCommandText {
    param([AllowNull()][object]$Entry)
    foreach ($name in @('QuietUninstallString', 'UninstallString')) {
        $value = Get-UninstallPropertyValue -InputObject $Entry `
            -Name $name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }
    return ''
}
function Resolve-UninstallRegisteredCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [scriptblock]$PathResolver
    )
    $match = [regex]::Match(
        $Command,
        '^\s*(?:"(?<File>[^"]+\.exe)"|' +
        '(?<File>[^"].*?\.exe))\s*(?<Args>.*)$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) {
        throw "Kayitli kaldirma komutu gecersiz: $Command"
    }
    $filePath = [Environment]::ExpandEnvironmentVariables(
        $match.Groups['File'].Value.Trim()
    )
    if ($null -ne $PathResolver) {
        $resolvedPath = [string](& $PathResolver $filePath)
        if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
            throw "Kayitli kaldirici bulunamadi: $filePath"
        }
        $filePath = [IO.Path]::GetFullPath($resolvedPath)
    }
    elseif (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        $resolved = Get-Command $filePath -ErrorAction SilentlyContinue
        if ($null -eq $resolved) {
            throw "Kayitli kaldirici bulunamadi: $filePath"
        }
        $filePath = [IO.Path]::GetFullPath($resolved.Source)
    }
    return [pscustomobject]@{
        FilePath = $filePath
        Arguments = [Environment]::ExpandEnvironmentVariables(
            $match.Groups['Args'].Value.Trim()
        )
    }
}
function Test-UninstallTrustedSigner {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$SubjectPattern,
        [scriptblock]$SignatureReader = {
            param($Path)
            Get-AuthenticodeSignature -LiteralPath $Path `
                -ErrorAction Stop
        }
    )
    try {
        $signature = & $SignatureReader $FilePath
        $certificate = Get-UninstallPropertyValue `
            -InputObject $signature -Name 'SignerCertificate'
        $subject = [string](Get-UninstallPropertyValue `
            -InputObject $certificate -Name 'Subject')
        return [string](Get-UninstallPropertyValue `
                -InputObject $signature -Name 'Status') -ceq 'Valid' -and
            $subject -match $SubjectPattern
    }
    catch {
        return $false
    }
}
function Test-UninstallTrustedWingetPath {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [scriptblock]$ItemReader = {
            param($Path)
            Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        },
        [scriptblock]$SignatureReader = {
            param($Path)
            Get-AuthenticodeSignature -LiteralPath $Path `
                -ErrorAction Stop
        },
        [scriptblock]$AliasIdentityReader = {
            param($Path)
            $fsutil = Join-Path $env:SystemRoot 'System32\fsutil.exe'
            $result = Invoke-UninstallNativeProcess `
                -FilePath $fsutil `
                -ArgumentList @('reparsepoint', 'query', $Path) `
                -TimeoutSeconds 15 -Action 'Winget alias kimligi' `
                -SuppressUiOutput
            $output = '{0} {1}' -f `
                $result.StandardOutput, $result.StandardError
            $hex = [Collections.Generic.List[string]]::new()
            foreach ($line in [regex]::Split($output, '\r\n|\n|\r')) {
                $match = [regex]::Match(
                    $line,
                    '^\s*[0-9A-F]{4}:\s*' +
                        '(?<Hex>(?:[0-9A-F]{2}\s*){16})',
                    [Text.RegularExpressions.RegexOptions]::IgnoreCase
                )
                if (-not $match.Success) {
                    continue
                }
                foreach ($pair in [regex]::Matches(
                    $match.Groups['Hex'].Value,
                    '[0-9A-F]{2}',
                    [Text.RegularExpressions.RegexOptions]::IgnoreCase
                )) {
                    $hex.Add($pair.Value)
                }
            }
            $bytes = [byte[]]@($hex | ForEach-Object {
                [Convert]::ToByte($_, 16)
            })
            $identity = if ($bytes.Count -gt 4) {
                [Text.Encoding]::Unicode.GetString(
                    $bytes,
                    4,
                    $bytes.Count - 4
                )
            }
            else {
                ''
            }
            return $output -match '(?i)0x8000001b' -and
                $identity -match `
                    'Microsoft\.DesktopAppInstaller_8wekyb3d8bbwe' -and
                $identity -match '(?i)!winget'
        }
    )
    try {
        $fullPath = [IO.Path]::GetFullPath($FilePath)
        if ([IO.Path]::GetFileName($fullPath) -ine 'winget.exe') {
            return $false
        }
        $aliasPath = [IO.Path]::GetFullPath(
            (Join-Path $env:LOCALAPPDATA `
                'Microsoft\WindowsApps\winget.exe')
        )
        $item = & $ItemReader $fullPath
        if ($fullPath.Equals(
            $aliasPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $attributes = [IO.FileAttributes](
                Get-UninstallPropertyValue -InputObject $item `
                    -Name 'Attributes'
            )
            $length = [long](Get-UninstallPropertyValue `
                -InputObject $item -Name 'Length')
            return ($attributes -band `
                [IO.FileAttributes]::ReparsePoint) -ne 0 -and
                $length -eq 0 -and
                [bool](& $AliasIdentityReader $fullPath)
        }
        $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
        if (-not (Test-UninstallPathWithin -Path $fullPath `
            -Root $windowsApps) -or
            $fullPath -notmatch (
                '^' + [regex]::Escape(
                    [IO.Path]::GetFullPath($windowsApps).TrimEnd('\')
                ) + '\\Microsoft\.DesktopAppInstaller_' +
                '[^\\]+__8wekyb3d8bbwe\\winget\.exe$'
            )) {
            return $false
        }
        return Test-UninstallTrustedSigner -FilePath $fullPath `
            -SubjectPattern 'Microsoft (Corporation|Windows)' `
            -SignatureReader $SignatureReader
    }
    catch {
        return $false
    }
}
function Get-UninstallTrustedWingetPath {
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $command -or
        -not (Test-UninstallTrustedWingetPath `
            -FilePath ([string]$command.Source))) {
        throw 'Guvenilir Winget calistiricisi bulunamadi.'
    }
    return [IO.Path]::GetFullPath([string]$command.Source)
}
function Get-PythonMsiProductCode {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments
    )
    try {
        $fullPath = [IO.Path]::GetFullPath($FilePath)
        $expected = @(
            (Join-Path $env:SystemRoot 'System32\msiexec.exe'),
            (Join-Path $env:SystemRoot 'SysWOW64\msiexec.exe')
        )
        if (@($expected | Where-Object {
            [IO.Path]::GetFullPath($_).Equals(
                $fullPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        }).Count -ne 1) {
            return $null
        }
        $match = [regex]::Match(
            $Arguments,
            '^\s*/[IX]\s*(?<Code>\{[0-9A-F]{8}-' +
                '(?:[0-9A-F]{4}-){3}[0-9A-F]{12}\})' +
                '(?:\s+/(?:qn|quiet|norestart))*\s*$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if (-not $match.Success) {
            return $null
        }
        return $match.Groups['Code'].Value.ToUpperInvariant()
    }
    catch {
        return $null
    }
}
function Test-PythonOfficialUninstaller {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][pscustomobject]$Ownership,
        [scriptblock]$SignatureReader = {
            param($Path)
            Get-AuthenticodeSignature -LiteralPath $Path `
                -ErrorAction Stop
        },
        [scriptblock]$VersionReader = {
            param($Path)
            (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo
        }
    )
    try {
        $fullPath = [IO.Path]::GetFullPath($FilePath)
        $executable = [string](Get-UninstallPropertyValue `
            -InputObject $Ownership -Name 'ExecutablePath')
        $pythonRoot = Split-Path -Parent $executable
        $rootUninstaller = [IO.Path]::GetFullPath(
            (Join-Path $pythonRoot 'uninstall.exe')
        )
        $expectedVersion = [version][string](
            Get-UninstallPropertyValue -InputObject $Ownership `
                -Name 'Version'
        )
        $cachedName = 'python-{0}-amd64.exe' -f `
            $expectedVersion.ToString(3)
        $cacheRoots = @(
            (Join-Path $env:ProgramData 'Package Cache'),
            (Join-Path $env:LOCALAPPDATA 'Package Cache')
        )
        $trustedCache = @($cacheRoots | Where-Object {
            $pattern = '^' + [regex]::Escape(
                [IO.Path]::GetFullPath($_).TrimEnd('\')
            ) + '\\\{[0-9A-F-]{36}\}(?:v\d+(?:\.\d+)*)?\\' + `
                [regex]::Escape($cachedName) + '$'
            $fullPath -match $pattern
        }).Count -eq 1
        $trustedLocation = $fullPath.Equals(
            $rootUninstaller,
            [StringComparison]::OrdinalIgnoreCase
        ) -or $trustedCache
        if (-not $trustedLocation -or
            -not (Test-UninstallTrustedSigner `
            -FilePath $fullPath `
            -SubjectPattern 'Python Software Foundation' `
            -SignatureReader $SignatureReader)) {
            return $false
        }
        $versionInfo = & $VersionReader $fullPath
        $actualText = [string](Get-UninstallPropertyValue `
            -InputObject $versionInfo -Name 'ProductVersion')
        if ([string]::IsNullOrWhiteSpace($actualText)) {
            $actualText = [string](Get-UninstallPropertyValue `
                -InputObject $versionInfo -Name 'FileVersion')
        }
        $versionMatch = [regex]::Match(
            $actualText,
            '^\s*(?<Version>\d+\.\d+\.\d+(?:\.\d+)?)'
        )
        if (-not $versionMatch.Success) {
            return $false
        }
        $actualVersion = [version]$versionMatch.Groups['Version'].Value
        return $actualVersion.Major -eq $expectedVersion.Major -and
            $actualVersion.Minor -eq $expectedVersion.Minor -and
            $actualVersion.Build -eq $expectedVersion.Build
    }
    catch {
        return $false
    }
}
function New-PythonRemovalPlan {
    param(
        [Parameter(Mandatory)][pscustomobject]$Ownership,
        [Parameter(Mandatory)][object]$RegistryEntry,
        [scriptblock]$SignatureReader = {
            param($Path)
            Get-AuthenticodeSignature -LiteralPath $Path `
                -ErrorAction Stop
        },
        [scriptblock]$VersionReader = {
            param($Path)
            (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo
        },
        [scriptblock]$CommandPathResolver
    )
    $source = [string](Get-UninstallPropertyValue `
        -InputObject $Ownership -Name 'Source')
    $packageId = [string](Get-UninstallPropertyValue `
        -InputObject $Ownership -Name 'PackageId')
    if ($packageId -cne 'Python.Python.3.11' -or
        $source -notin @(
            'LocalArtifact',
            'OfficialHttpsArtifact',
            'ExistingOwnedPath'
        )) {
        throw "Desteklenmeyen Python sahiplik kaynagi: $source"
    }
    $commandText = Get-UninstallCommandText -Entry $RegistryEntry
    $command = Resolve-UninstallRegisteredCommand -Command $commandText `
        -PathResolver $CommandPathResolver
    if ([IO.Path]::GetFileName($command.FilePath) -ieq 'msiexec.exe') {
        throw 'Python MSI kaldirma kaydi Winlama sahipligini kanitlamiyor.'
    }
    if (-not (Test-PythonOfficialUninstaller `
        -FilePath $command.FilePath -Ownership $Ownership `
        -SignatureReader $SignatureReader `
        -VersionReader $VersionReader)) {
        throw "Python kaldirici kimligi guvenli degil: $($command.FilePath)"
    }
    return [pscustomobject]@{
        FilePath = $command.FilePath
        Arguments = @('/uninstall', '/quiet', '/norestart')
        AllowedExitCodes = @(0, 1605, 1614, 3010)
        Method = 'SignedPythonUninstaller'
    }
}
function Get-UninstallDependency {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$Name
    )
    return @($Config.Dependencies | Where-Object {
        [string](Get-UninstallPropertyValue -InputObject $_ `
            -Name 'Name') -ceq $Name
    }) | Select-Object -First 1
}
function Test-PythonOwnershipDocument {
    param(
        [AllowNull()][object]$Document,
        [Parameter(Mandatory)][pscustomobject]$Dependency
    )
    try {
        if ([int](Get-UninstallPropertyValue -InputObject $Document `
            -Name 'SchemaVersion') -ne 1) {
            return $false
        }
        $components = Get-UninstallPropertyValue `
            -InputObject $Document -Name 'Components'
        $python = Get-UninstallPropertyValue `
            -InputObject $components -Name 'Python'
        if ($null -eq $python -or
            (Get-UninstallPropertyValue -InputObject $python `
                -Name 'OwnedByWinlama') -isnot [bool] -or
            -not [bool](Get-UninstallPropertyValue `
                -InputObject $python -Name 'OwnedByWinlama')) {
            return $false
        }
        $packageId = [string](Get-UninstallPropertyValue `
            -InputObject $python -Name 'PackageId')
        $version = [string](Get-UninstallPropertyValue `
            -InputObject $python -Name 'Version')
        $installScope = [string](Get-UninstallPropertyValue `
            -InputObject $python -Name 'InstallScope')
        $installRoot = [string](Get-UninstallPropertyValue `
            -InputObject $python -Name 'InstallRoot')
        $executable = [string](Get-UninstallPropertyValue `
            -InputObject $python -Name 'ExecutablePath')
        $source = [string](Get-UninstallPropertyValue `
            -InputObject $python -Name 'Source')
        $installedAtText = [string](Get-UninstallPropertyValue `
            -InputObject $python -Name 'InstalledAt')
        $expectedId = [string](Get-UninstallPropertyValue `
            -InputObject $Dependency -Name 'WingetId')
        $expectedVersion = [string](Get-UninstallPropertyValue `
            -InputObject $Dependency -Name 'WingetVersion')
        $configuredRoot = [Environment]::ExpandEnvironmentVariables(
            [string](Get-UninstallPropertyValue `
                -InputObject $Dependency -Name 'InstallPath')
        )
        $expectedRoot = [IO.Path]::GetFullPath(
            (Join-Path $env:LOCALAPPDATA `
                'Programs\Winlama\Dependencies\Python311')
        ).TrimEnd('\')
        $expectedExecutable = [IO.Path]::GetFullPath(
            (Join-Path $expectedRoot 'python.exe')
        )
        $installedAt = [DateTimeOffset]::MinValue
        if ($packageId -cne 'Python.Python.3.11' -or
            $packageId -cne $expectedId -or
            ([version]$version) -ne ([version]$expectedVersion) -or
            [string](Get-UninstallPropertyValue `
                -InputObject $Dependency -Name 'Scope') -cne 'user' -or
            $installScope -cne 'User' -or
            -not [IO.Path]::IsPathRooted($installRoot) -or
            -not [IO.Path]::IsPathRooted($executable) -or
            $source -notin @(
                'LocalArtifact',
                'OfficialHttpsArtifact',
                'ExistingOwnedPath'
            ) -or
            -not [DateTimeOffset]::TryParse(
                $installedAtText,
                [ref]$installedAt
            )) {
            return $false
        }
        return [IO.Path]::GetFullPath($configuredRoot).TrimEnd('\').Equals(
                $expectedRoot,
                [StringComparison]::OrdinalIgnoreCase
            ) -and [IO.Path]::GetFullPath($installRoot).TrimEnd('\').Equals(
                $expectedRoot,
                [StringComparison]::OrdinalIgnoreCase
            ) -and [IO.Path]::GetFullPath($executable).Equals(
                $expectedExecutable,
                [StringComparison]::OrdinalIgnoreCase
            )
    }
    catch {
        return $false
    }
}
function Get-PythonOwnership {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $root = Get-UninstallExpectedWinlamaRoot
    $path = Join-Path $root 'Data\install-ownership.json'
    $safePath = Resolve-SafeUninstallPath -Path $path `
        -AllowedRoots @($root)
    if (-not (Test-Path -LiteralPath $safePath -PathType Leaf)) {
        Write-UninstallLog -Event 'PYTHON_OWNERSHIP_ABSENT' `
            -Level WARN `
            -Message ('Sahiplik kaydi yok; yalniz kesin Winlama Python ' +
                'hedefi kurtarma denetimine alinacak. Sistem Python korunur.')
        return $null
    }
    try {
        $document = Get-Content -LiteralPath $safePath -Raw `
            -Encoding UTF8 | ConvertFrom-UninstallJson
    }
    catch {
        Write-UninstallBootstrapStatus -Level WARN `
            -Message (Get-UninstallText `
                -Key 'Uninstall.Python.OwnershipUnreadable' `
                -Fallback ('Python sahiplik kaydi okunamadi; yalniz kesin ' +
                    'Winlama hedefi kurtarma denetimine alinacak.'))
        Write-UninstallLog -Event 'PYTHON_OWNERSHIP_UNREADABLE' `
            -Level WARN -Message ('Sahiplik kaydi okunamadi; yalniz kesin ' +
                'Winlama Python hedefi denetlenecek.') `
            -ErrorRecord $_
        return $null
    }
    $dependency = Get-UninstallDependency -Config $Config -Name 'Python'
    if ($null -eq $dependency -or
        -not (Test-PythonOwnershipDocument -Document $document `
            -Dependency $dependency)) {
        Write-UninstallBootstrapStatus -Level WARN `
            -Message (Get-UninstallText `
                -Key 'Uninstall.Python.OwnershipUncertain' `
                -Fallback ('Python sahipligi kesin degil; yalniz kesin ' +
                    'Winlama hedefi kurtarma denetimine alinacak.'))
        Write-UninstallLog -Event 'PYTHON_OWNERSHIP_REJECTED' `
            -Level WARN `
            -Message ('Sahiplik kaydi sozlesmeyi gecmedi; yalniz kesin ' +
                'Winlama Python hedefi denetlenecek.')
        return $null
    }
    return Get-UninstallPropertyValue -InputObject (
        Get-UninstallPropertyValue -InputObject $document `
            -Name 'Components'
    ) -Name 'Python'
}
function Get-PythonOwnedRootForRemoval {
    param([Parameter(Mandatory)][pscustomobject]$Ownership)
    $recordedRoot = [string](Get-UninstallPropertyValue `
        -InputObject $Ownership -Name 'InstallRoot')
    $executable = [string](Get-UninstallPropertyValue `
        -InputObject $Ownership -Name 'ExecutablePath')
    if ([string]::IsNullOrWhiteSpace($recordedRoot) -or
        [string]::IsNullOrWhiteSpace($executable) -or
        [IO.Path]::GetFileName($executable) -ine 'python.exe') {
        throw 'Python sahiplik hedefi gecersiz.'
    }
    $root = [IO.Path]::GetFullPath($recordedRoot).TrimEnd('\')
    $expectedRoot = [IO.Path]::GetFullPath(
        (Join-Path $env:LOCALAPPDATA `
            'Programs\Winlama\Dependencies\Python311')
    ).TrimEnd('\')
    $expectedExecutable = [IO.Path]::GetFullPath(
        (Join-Path $expectedRoot 'python.exe')
    )
    if ($root.Equals(
            $expectedRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -and [IO.Path]::GetFullPath($executable).Equals(
            $expectedExecutable,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        return $root
    }
    throw "Python sahiplik koku guvenli degil: $root"
}
function Get-PythonRegistryEntries {
    param(
        [Parameter(Mandatory)][pscustomobject]$Ownership,
        [object[]]$Entries = $(Get-UninstallRegistryEntries)
    )
    $version = [string](Get-UninstallPropertyValue `
        -InputObject $Ownership -Name 'Version')
    $expectedRoot = Get-PythonOwnedRootForRemoval `
        -Ownership $Ownership
    $hkcuPrefix = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\' +
        'Windows\CurrentVersion\Uninstall\'
    return @($Entries | Where-Object {
        try {
            $displayName = Get-UninstallDisplayName -Entry $_
            $displayVersion = [string](Get-UninstallPropertyValue `
                -InputObject $_ -Name 'DisplayVersion')
            $publisher = [string](Get-UninstallPropertyValue `
                -InputObject $_ -Name 'Publisher')
            $registryPath = [string](Get-UninstallPropertyValue `
                -InputObject $_ -Name 'PSPath')
            $installLocation = [Environment]::ExpandEnvironmentVariables(
                [string](Get-UninstallPropertyValue `
                    -InputObject $_ -Name 'InstallLocation')
            )
            $command = Get-UninstallCommandText -Entry $_
            $displayName -match '^Python 3\.11\.\d+ \(64-bit\)$' -and
                $registryPath.StartsWith(
                    $hkcuPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                -not [string]::IsNullOrWhiteSpace($displayVersion) -and
                ([version]$displayVersion) -eq ([version]$version) -and
                $publisher -like 'Python Software Foundation*' -and
                -not [string]::IsNullOrWhiteSpace($installLocation) -and
                ([IO.Path]::GetFullPath(
                    $installLocation
                ).TrimEnd('\')).Equals(
                        [IO.Path]::GetFullPath($expectedRoot).TrimEnd('\'),
                        [StringComparison]::OrdinalIgnoreCase
                    ) -and
                -not [string]::IsNullOrWhiteSpace($command)
        }
        catch {
            $false
        }
    })
}
function Get-OllamaRegistryEntries {
    param([object[]]$Entries = $(Get-UninstallRegistryEntries))
    return @($Entries | Where-Object {
        (Get-UninstallDisplayName -Entry $_) -ieq 'Ollama'
    })
}
function Stop-UninstallProcessesFromPath {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string[]]$AllowedRoots,
        [switch]$AllowRoot
    )
    if ($ValidateOnly) {
        throw 'ValidateOnly sirasinda surec durdurma cagrildi.'
    }
    $root = Resolve-SafeUninstallPath -Path $RootPath `
        -AllowedRoots $AllowedRoots -AllowRoot:$AllowRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return
    }
    $prefix = $root.TrimEnd('\') + '\'
    $targets = [Collections.Generic.List[int]]::new()
    foreach ($process in @(Get-CimInstance -ClassName Win32_Process `
        -ErrorAction SilentlyContinue)) {
        $path = [string](Get-UninstallPropertyValue `
            -InputObject $process -Name 'ExecutablePath')
        $processId = Get-UninstallPropertyValue `
            -InputObject $process -Name 'ProcessId'
        if ([string]::IsNullOrWhiteSpace($path) -or
            $null -eq $processId -or [int]$processId -eq $PID) {
            continue
        }
        try {
            $fullPath = [IO.Path]::GetFullPath($path)
        }
        catch {
            continue
        }
        if ($fullPath.StartsWith(
            $prefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $targets.Add([int]$processId)
        }
    }
    foreach ($processId in $targets) {
        Write-UninstallLog -Event 'PROCESS_STOP_STARTED' `
            -Action 'Yol tabanli surec durdurma' `
            -Message "PID: $processId | Kok: $root"
        Stop-Process -Id $processId -Force -ErrorAction Stop
    }
    foreach ($processId in $targets) {
        try {
            Wait-Process -Id $processId -Timeout 15 -ErrorAction Stop
        }
        catch {
            if ($null -ne (Get-Process -Id $processId `
                -ErrorAction SilentlyContinue)) {
                throw "Surec durdurulamadi: $processId"
            }
        }
        Write-UninstallLog -Event 'PROCESS_STOP_COMPLETED' `
            -Level SUCCESS -Action 'Yol tabanli surec durdurma' `
            -Message "PID: $processId | Kok: $root"
    }
}
function Test-UninstallOllamaProcessProof {
    param(
        [AllowNull()][string]$ExecutablePath,
        [AllowNull()][string]$ProcessName,
        [Parameter(Mandatory)][string]$InstallRoot
    )
    try {
        if ([string]::IsNullOrWhiteSpace($ExecutablePath) -or
            [string]::IsNullOrWhiteSpace($ProcessName) -or
            $ProcessName -notin @(
                'ollama', 'ollama app', 'ollama_llama_server',
                'ollama runner', 'llama-server'
            )) {
            return $false
        }
        return Test-UninstallPathWithin `
            -Path ([IO.Path]::GetFullPath($ExecutablePath)) `
            -Root ([IO.Path]::GetFullPath($InstallRoot))
    }
    catch {
        return $false
    }
}
function Stop-OllamaProcessesForRemoval {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    if ($ValidateOnly) {
        throw 'ValidateOnly sirasinda Ollama sureci durdurma istendi.'
    }
    $expectedRoot = Get-UninstallExpectedOllamaRoot
    $configured = [string](Get-UninstallPropertyValue `
        -InputObject $Config.Ollama -Name 'InstallPath')
    $installRoot = Resolve-SafeUninstallPath -Path $configured `
        -AllowedRoots @($expectedRoot) -AllowRoot
    $installRoot = Assert-UninstallExactPath -Actual $installRoot `
        -Expected $expectedRoot -Label 'Ollama kurulum yolu'
    Stop-UninstallProcessesFromPath -RootPath $installRoot `
        -AllowedRoots @($expectedRoot) -AllowRoot
    $namedTargets = [Collections.Generic.List[int]]::new()
    foreach ($name in @(
        'ollama', 'ollama app', 'ollama_llama_server',
        'ollama runner', 'llama-server'
    )) {
        foreach ($process in @(Get-Process -Name $name `
            -ErrorAction SilentlyContinue)) {
            $path = ''
            try {
                $path = [string]$process.Path
            }
            catch {
                Write-Verbose ('Ollama surec yolu okunamadi: {0} | {1}' `
                    -f $process.Id, $_.Exception.Message)
            }
            if (Test-UninstallOllamaProcessProof `
                -ExecutablePath $path -ProcessName $process.ProcessName `
                -InstallRoot $installRoot) {
                $namedTargets.Add([int]$process.Id)
            }
        }
    }
    foreach ($processId in @($namedTargets | Sort-Object -Unique)) {
        Write-UninstallLog -Event 'PROCESS_STOP_STARTED' `
            -Action 'Ollama surec durdurma' `
            -Message "PID: $processId | Kok: $installRoot"
        Stop-Process -Id $processId -Force -ErrorAction Stop
        Wait-Process -Id $processId -Timeout 15 `
            -ErrorAction SilentlyContinue
        if ($null -ne (Get-Process -Id $processId `
            -ErrorAction SilentlyContinue)) {
            throw "Ollama sureci durdurulamadi: $processId"
        }
        Write-UninstallLog -Event 'PROCESS_STOP_COMPLETED' `
            -Level SUCCESS -Action 'Ollama surec durdurma' `
            -Message "PID: $processId | Kok: $installRoot"
    }
    $port = [int](Get-UninstallPropertyValue `
        -InputObject $Config.Ollama -Name 'Port')
    if ($port -lt 1 -or $port -gt 65535) {
        throw "Gecersiz Ollama portu: $port"
    }
    $getConnection = Get-Command Get-NetTCPConnection `
        -ErrorAction SilentlyContinue
    if ($null -eq $getConnection) {
        $netstat = Join-Path $env:SystemRoot 'System32\netstat.exe'
        $result = Invoke-UninstallNativeProcess -FilePath $netstat `
            -ArgumentList @('-ano', '-p', 'tcp') `
            -Action 'Ollama port dogrulamasi'
        $pattern = '(?m)^\s*TCP\s+\S+:{0}\s+\S+\s+LISTENING\s+\d+\s*$' `
            -f $port
        if ($result.StandardOutput -match $pattern) {
            throw "Ollama portu hala dinleniyor: $port"
        }
        return
    }
    $listeners = @(Get-NetTCPConnection -State Listen `
        -LocalPort $port -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        $details = @($listeners | ForEach-Object {
            '{0}:{1} pid={2}' -f `
                $_.LocalAddress, $_.LocalPort, $_.OwningProcess
        }) -join ', '
        throw "Ollama portu hala dinleniyor: $port | $details"
    }
}
function Invoke-UninstallAggregateActions {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Actions,
        [switch]$Quiet,
        [switch]$SuppressLog
    )
    $failures = [Collections.Generic.List[object]]::new()
    $completed = [Collections.Generic.List[string]]::new()
    foreach ($descriptor in $Actions) {
        $name = [string](Get-UninstallPropertyValue `
            -InputObject $descriptor -Name 'Name')
        $action = Get-UninstallPropertyValue `
            -InputObject $descriptor -Name 'Action'
        $script:UninstallActionSequence++
        $actionId = 'uninstall-{0:D3}' -f `
            $script:UninstallActionSequence
        if (-not $SuppressLog) {
            Write-UninstallLog -Event 'ACTION_STARTED' `
                -ActionId $actionId -Action $name `
                -Message (Get-UninstallText `
                    -Key 'Uninstall.Action.Started' `
                    -Fallback '{0} baslatildi.' -Arguments @($name))
        }
        if (-not $Quiet) {
            Write-UninstallBootstrapStatus -Level STEP `
                -Message (Get-UninstallText `
                    -Key 'Uninstall.Action.Started' `
                    -Fallback '{0} baslatildi.' -Arguments @($name))
        }
        try {
            $null = & $action
            $completed.Add($name)
            if (-not $SuppressLog) {
                Write-UninstallLog -Event 'ACTION_COMPLETED' `
                    -ActionId $actionId -Action $name `
                    -Level SUCCESS -Message (Get-UninstallText `
                        -Key 'Uninstall.Action.Completed' `
                        -Fallback '{0} tamamlandi.' -Arguments @($name))
            }
            if (-not $Quiet) {
                Write-UninstallBootstrapStatus -Level SUCCESS `
                    -Message (Get-UninstallText `
                        -Key 'Uninstall.Action.Completed' `
                        -Fallback '{0} tamamlandi.' -Arguments @($name))
            }
        }
        catch {
            $failure = [pscustomobject]@{
                Name = $name
                Message = $_.Exception.Message
                ErrorRecord = $_
            }
            $failures.Add($failure)
            if (-not $SuppressLog) {
                Write-UninstallLog -Event 'ACTION_FAILED' `
                    -ActionId $actionId -Action $name -Level ERROR `
                    -Message $_.Exception.Message -ErrorRecord $_
            }
            if (-not $Quiet) {
                Write-UninstallBootstrapStatus -Level ERROR `
                    -Message (Get-UninstallText `
                        -Key 'Uninstall.Action.Failed' `
                        -Fallback '{0} basarisiz: {1}' `
                        -Arguments @($name, $_.Exception.Message))
            }
        }
    }
    return [pscustomobject]@{
        Succeeded = $failures.Count -eq 0
        Completed = $completed.ToArray()
        Failures = $failures.ToArray()
    }
}
function Get-UninstallExpectedWinlamaRoot {
    return [IO.Path]::GetFullPath(
        (Join-Path $env:LOCALAPPDATA 'Programs\Winlama')
    ).TrimEnd('\')
}
function Get-UninstallExpectedPythonRoot {
    return [IO.Path]::GetFullPath(
        (Join-Path (Get-UninstallExpectedWinlamaRoot) `
            'Dependencies\Python311')
    ).TrimEnd('\')
}
function Get-UninstallExpectedOllamaRoot {
    return [IO.Path]::GetFullPath(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama')
    ).TrimEnd('\')
}
function Get-UninstallExpectedOpenWebUIRoot {
    return [IO.Path]::GetFullPath(
        (Join-Path $env:USERPROFILE '.openui')
    ).TrimEnd('\')
}
function Get-UninstallExpectedComfyUIRoot {
    return [IO.Path]::GetFullPath(
        (Join-Path $env:LOCALAPPDATA 'Programs\ComfyUI')
    ).TrimEnd('\')
}
function Get-UninstallExpectedComfyUIModelsRoot {
    return [IO.Path]::GetFullPath(
        (Join-Path $env:USERPROFILE '.comfyui\models')
    ).TrimEnd('\')
}
function Remove-OllamaEnvironment {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $names = @(Get-UninstallPropertyValue `
        -InputObject $Config.Uninstall -Name 'EnvironmentVariables')
    $actions = [Collections.Generic.List[object]]::new()
    foreach ($nameValue in $names) {
        $name = [string]$nameValue
        if ($name -notin @(
            'OLLAMA_HOST', 'OLLAMA_MODELS', 'OLLAMA_ORIGINS'
        )) {
            throw "Guvenli olmayan ortam degiskeni adi: $name"
        }
        foreach ($targetValue in @('User', 'Machine')) {
            $targetName = $targetValue
            $variableName = $name
            $actions.Add([pscustomobject]@{
                Name = "Ortam degiskeni $targetName/$variableName"
                Action = {
                    $target = [EnvironmentVariableTarget]([Enum]::Parse(
                        [EnvironmentVariableTarget],
                        $targetName
                    ))
                    [Environment]::SetEnvironmentVariable(
                        $variableName,
                        $null,
                        $target
                    )
                    if ($null -ne [Environment]::GetEnvironmentVariable(
                        $variableName,
                        $target
                    )) {
                        throw 'Ortam degiskeni son kosulu basarisiz.'
                    }
                }.GetNewClosure()
            })
        }
        $variableName = $name
        $actions.Add([pscustomobject]@{
            Name = "Ortam degiskeni Process/$variableName"
            Action = {
                Remove-Item -LiteralPath "Env:$variableName" `
                    -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath "Env:$variableName") {
                    throw 'Surec ortami son kosulu basarisiz.'
                }
            }.GetNewClosure()
        })
    }
    $result = Invoke-UninstallAggregateActions `
        -Actions $actions.ToArray()
    if (-not $result.Succeeded) {
        throw ('Ortam degiskeni temizligi basarisiz: ' +
            (@($result.Failures.Message) -join ' | '))
    }
}
function Remove-OllamaApplication {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $expectedRoot = Get-UninstallExpectedOllamaRoot
    $configured = [string](Get-UninstallPropertyValue `
        -InputObject $Config.Ollama -Name 'InstallPath')
    $installRoot = Resolve-SafeUninstallPath -Path $configured `
        -AllowedRoots @($expectedRoot) -AllowRoot
    $installRoot = Assert-UninstallExactPath -Actual $installRoot `
        -Expected $expectedRoot -Label 'Ollama kurulum yolu'
    Stop-OllamaProcessesForRemoval -Config $Config
    $registryEntries = @(Get-OllamaRegistryEntries)
    $knownUninstaller = Join-Path $installRoot 'unins000.exe'
    $trustedUninstaller = (Test-Path -LiteralPath $knownUninstaller `
        -PathType Leaf) -and
        (Test-UninstallTrustedSigner -FilePath $knownUninstaller `
            -SubjectPattern 'Ollama')
    if ($trustedUninstaller) {
        $null = Invoke-UninstallNativeProcess `
            -FilePath $knownUninstaller `
            -ArgumentList @(
                '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
            ) -AllowedExitCodes @(0, 3010) `
            -Action 'Ollama kaldiricisi'
    }
    elseif ($registryEntries.Count -gt 0) {
        $wingetPath = Get-UninstallTrustedWingetPath
        $null = Invoke-UninstallNativeProcess -FilePath $wingetPath `
            -ArgumentList @(
                'uninstall', '--exact', '--id', 'Ollama.Ollama',
                '--silent', '--disable-interactivity',
                '--accept-source-agreements'
            ) -AllowedExitCodes @(0, -1978335212) `
            -Action 'Winget Ollama kaldirma'
    }
    elseif (Test-Path -LiteralPath $knownUninstaller -PathType Leaf) {
        Write-UninstallLog -Event 'UNTRUSTED_UNINSTALLER_SKIPPED' `
            -Level WARN -Action 'Ollama kaldiricisi' `
            -Message "Imzasi kanitlanamayan dosya calistirilmadi: $knownUninstaller"
    }
    $null = Remove-UninstallPath -Path $installRoot `
        -Label 'Ollama uygulamasi' -AllowedRoots @($expectedRoot) `
        -AllowRoot -Recurse
    Remove-OllamaEnvironment -Config $Config
    if (Test-Path -LiteralPath $installRoot) {
        throw 'Ollama klasoru kaldirma sonrasinda hala mevcut.'
    }
    foreach ($name in @('ollama', 'ollama app')) {
        if (@(Get-Process -Name $name `
            -ErrorAction SilentlyContinue).Count -gt 0) {
            throw "Ollama sureci hala calisiyor: $name"
        }
    }
    if ($registryEntries.Count -gt 0) {
        $deadline = [DateTimeOffset]::Now.AddSeconds(30)
        do {
            if (@(Get-OllamaRegistryEntries).Count -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 500
        } while ([DateTimeOffset]::Now -lt $deadline)
        if (@(Get-OllamaRegistryEntries).Count -gt 0) {
            throw 'Ollama kaldirma kaydi hala kayit defterinde.'
        }
    }
}
function Remove-OllamaModels {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $expected = [IO.Path]::GetFullPath(
        (Join-Path $env:USERPROFILE '.ollama\models')
    ).TrimEnd('\')
    $configured = [string](Get-UninstallPropertyValue `
        -InputObject $Config.Paths -Name 'Models')
    $modelsPath = Resolve-SafeUninstallPath -Path $configured `
        -AllowedRoots @($expected) -AllowRoot -Recurse
    $modelsPath = Assert-UninstallExactPath -Actual $modelsPath `
        -Expected $expected -Label 'Ollama model yolu'
    Stop-OllamaProcessesForRemoval -Config $Config
    $null = Remove-UninstallPath -Path $modelsPath `
        -Label 'Ollama modelleri' -AllowedRoots @($expected) `
        -AllowRoot -Recurse
}
function Remove-OpenWebUIData {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $expected = Get-UninstallExpectedOpenWebUIRoot
    $configured = [string](Get-UninstallPropertyValue `
        -InputObject $Config.OpenWebUI -Name 'RootPath')
    $root = Resolve-SafeUninstallPath -Path $configured `
        -AllowedRoots @($expected) -AllowRoot
    $root = Assert-UninstallExactPath -Actual $root `
        -Expected $expected -Label 'Open WebUI veri yolu'
    $venv = Join-Path $root 'venv'
    Stop-UninstallProcessesFromPath -RootPath $venv `
        -AllowedRoots @($root)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Write-UninstallBootstrapStatus -Level SKIP `
            -Message (Get-UninstallText `
                -Key 'Uninstall.WebUI.AlreadyAbsent' `
                -Fallback 'Open WebUI verileri zaten yok.')
        return
    }
    $actions = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Force `
        -ErrorAction Stop)) {
        if ($item.Name -ieq 'venv') {
            continue
        }
        $target = $item.FullName
        $label = "Open WebUI data/$($item.Name)"
        $isDirectory = $item.PSIsContainer
        $actions.Add([pscustomobject]@{
            Name = $label
            Action = {
                $null = Remove-UninstallPath -Path $target `
                    -Label $label -AllowedRoots @($expected) `
                    -Recurse:$isDirectory
            }.GetNewClosure()
        })
    }
    $result = Invoke-UninstallAggregateActions `
        -Actions $actions.ToArray()
    if (-not $result.Succeeded) {
        throw ('Open WebUI veri temizligi basarisiz: ' +
            (@($result.Failures.Message) -join ' | '))
    }
    $remaining = @(Get-ChildItem -LiteralPath $root -Force `
        -ErrorAction Stop | Where-Object Name -ine 'venv')
    if ($remaining.Count -gt 0) {
        throw 'Open WebUI veri son kosulu basarisiz.'
    }
    foreach ($process in @(Get-CimInstance -ClassName Win32_Process `
        -ErrorAction SilentlyContinue)) {
        $executable = [string](Get-UninstallPropertyValue `
            -InputObject $process -Name 'ExecutablePath')
        if ([string]::IsNullOrWhiteSpace($executable)) {
            continue
        }
        try {
            if ([IO.Path]::GetFullPath($executable).StartsWith(
                [IO.Path]::GetFullPath($venv).TrimEnd('\') + '\',
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw 'Open WebUI sanal ortam sureci hala calisiyor.'
            }
        }
        catch [IO.IOException] {
            continue
        }
        catch [ArgumentException] {
            continue
        }
    }
}
function Remove-PythonLibraries {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $expected = Get-UninstallExpectedOpenWebUIRoot
    $configured = [string](Get-UninstallPropertyValue `
        -InputObject $Config.OpenWebUI -Name 'RootPath')
    $root = Resolve-SafeUninstallPath -Path $configured `
        -AllowedRoots @($expected) -AllowRoot
    $root = Assert-UninstallExactPath -Actual $root `
        -Expected $expected -Label 'Open WebUI calisma yolu'
    $venv = Join-Path $root 'venv'
    Stop-UninstallProcessesFromPath -RootPath $venv `
        -AllowedRoots @($root)
    $targets = @(
        [pscustomobject]@{
            Name = 'Winlama Python sanal ortami'
            Path = $venv
            Recurse = $true
        },
        [pscustomobject]@{
            Name = 'Winlama Python calisma kaydi'
            Path = (Join-Path $root 'runtime.json')
            Recurse = $false
        }
    )
    $actions = @($targets | ForEach-Object {
        $target = $_
        [pscustomobject]@{
            Name = $target.Name
            Action = {
                $null = Remove-UninstallPath -Path $target.Path `
                    -Label $target.Name -AllowedRoots @($root) `
                    -Recurse:$target.Recurse
            }.GetNewClosure()
        }
    })
    $result = Invoke-UninstallAggregateActions -Actions $actions
    if (-not $result.Succeeded) {
        throw ('Python kutuphane temizligi basarisiz: ' +
            (@($result.Failures.Message) -join ' | '))
    }
    if (Test-Path -LiteralPath $root -PathType Container) {
        $remaining = @(Get-ChildItem -LiteralPath $root -Force `
            -ErrorAction Stop)
        if ($remaining.Count -eq 0) {
            $null = Remove-UninstallPath -Path $root `
                -Label 'Bos Open WebUI kok klasoru' `
                -AllowedRoots @($expected) -AllowRoot -Recurse
        }
    }
}
function Remove-PythonApplication {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $ownership = Get-PythonOwnership -Config $Config
    if ($null -eq $ownership) {
        $pythonRoot = Get-UninstallExpectedPythonRoot
        $dependency = Get-UninstallDependency -Config $Config -Name 'Python'
        if ($null -eq $dependency) {
            throw 'Winlama Python bagimlilik kaydi bulunamadi.'
        }
        $probe = [pscustomobject]@{
            Version = [string](Get-UninstallPropertyValue `
                -InputObject $dependency -Name 'WingetVersion')
            InstallRoot = $pythonRoot
            ExecutablePath = Join-Path $pythonRoot 'python.exe'
        }
        $records = @(Get-PythonRegistryEntries -Ownership $probe)
        if ($records.Count -gt 1) {
            throw ('Winlama Python kaydi belirsiz; kaldirma durduruldu. ' +
                "Eslesen kayit sayisi: $($records.Count)")
        }
        if ($records.Count -eq 1) {
            $ownership = [pscustomobject]@{
                PackageId = 'Python.Python.3.11'
                Version = [string]$probe.Version
                InstallScope = 'User'
                InstallRoot = $pythonRoot
                ExecutablePath = [string]$probe.ExecutablePath
                Source = 'ExistingOwnedPath'
            }
            Write-UninstallBootstrapStatus -Level WARN `
                -Message (Get-UninstallText `
                    -Key 'Uninstall.Python.OwnershipRecovered' `
                    -Fallback ('Python sahiplik dosyasi yok; kesin Winlama ' +
                        'koku ve resmi kayitla sahiplik kurtarildi.'))
            Write-UninstallLog -Event 'PYTHON_OWNERSHIP_RECOVERED' `
                -Level WARN -Action 'Winlama Python 3.11 kaldirma' `
                -Message "Kesin Python kaydi kurtarildi: $pythonRoot"
        }
        elseif (Test-Path -LiteralPath $pythonRoot) {
            $ownership = [pscustomobject]@{
                PackageId = 'Python.Python.3.11'
                Version = [string]$probe.Version
                InstallScope = 'User'
                InstallRoot = $pythonRoot
                ExecutablePath = [string]$probe.ExecutablePath
                Source = 'ExistingOwnedPath'
            }
            Write-UninstallBootstrapStatus -Level WARN `
                -Message (Get-UninstallText `
                    -Key 'Uninstall.Python.OrphanedRootRecovered' `
                    -Fallback ('Python sahiplik ve resmi kaldirma kaydi yok; ' +
                        'yalniz kesin Winlama Python koku temizlenecek.'))
            Write-UninstallLog -Event 'PYTHON_ORPHANED_ROOT_RECOVERED' `
                -Level WARN -Action 'Winlama Python 3.11 kaldirma' `
                -Message "Kayitsiz kesin Python koku bulundu: $pythonRoot"
        }
        else {
            Write-UninstallBootstrapStatus -Level SKIP `
                -Message (Get-UninstallText `
                    -Key 'Uninstall.Python.AlreadyAbsent' `
                    -Fallback ('Winlama tarafindan sahiplenilen Python ' +
                        '3.11 zaten yok.'))
            Write-UninstallLog -Event 'PYTHON_ALREADY_ABSENT' `
                -Action 'Winlama Python 3.11 kaldirma' `
                -Message 'Kesin Winlama Python sahiplik kaydi bulunamadi.'
            return
        }
    }
    $pythonRoot = Get-PythonOwnedRootForRemoval -Ownership $ownership
    $winlamaRoot = Get-UninstallExpectedWinlamaRoot
    Write-UninstallLog -Event 'PYTHON_PROCESS_STOP_STARTED' `
        -Action 'Winlama Python 3.11 kaldirma' `
        -Message "Python koku: $pythonRoot"
    Stop-UninstallProcessesFromPath -RootPath $pythonRoot `
        -AllowedRoots @($winlamaRoot)
    Write-UninstallLog -Event 'PYTHON_PROCESS_STOP_COMPLETED' `
        -Level SUCCESS -Action 'Winlama Python 3.11 kaldirma' `
        -Message "Python koku: $pythonRoot"
    $records = @(Get-PythonRegistryEntries -Ownership $ownership)
    if ($records.Count -gt 1) {
        throw ('Winlama Python kaydi belirsiz; kaldirma durduruldu. ' +
            "Eslesen kayit sayisi: $($records.Count)")
    }
    if ($records.Count -eq 0) {
        if (Test-Path -LiteralPath $pythonRoot) {
            $null = Remove-UninstallPath -Path $pythonRoot `
                -Label 'Kayitsiz Winlama Python 3.11 hedefi' `
                -AllowedRoots @($winlamaRoot) -Recurse
            if (Test-Path -LiteralPath $pythonRoot) {
                throw ('Kayitsiz Winlama Python hedefi ' +
                    "kaldirma sonrasinda kaldi: $pythonRoot")
            }
            Write-UninstallLog -Event 'PYTHON_REMOVED' -Level SUCCESS `
                -Action 'Winlama Python 3.11 kaldirma' `
                -Message "Kayitsiz kesin Python hedefi kaldirildi: $pythonRoot"
            return
        }
        Write-UninstallBootstrapStatus -Level SKIP `
            -Message (Get-UninstallText `
                -Key 'Uninstall.Python.AlreadyAbsent' `
                -Fallback 'Winlama Python 3.11 zaten yok.')
        Write-UninstallLog -Event 'PYTHON_ALREADY_ABSENT' `
            -Action 'Winlama Python 3.11 kaldirma' `
            -Message 'Resmi kayit ve kesin Python hedefi zaten yok.'
        return
    }
    if ($records.Count -eq 1) {
        $record = $records[0]
        $plan = New-PythonRemovalPlan -Ownership $ownership `
            -RegistryEntry $record
        $displayName = Get-UninstallDisplayName -Entry $record
        $null = Invoke-UninstallNativeProcess `
            -FilePath $plan.FilePath `
            -ArgumentList $plan.Arguments `
            -AllowedExitCodes $plan.AllowedExitCodes `
            -Action "Winlama Python kaldirma: $displayName"
        $deadline = [DateTimeOffset]::Now.AddSeconds(30)
        do {
            $remaining = @(Get-PythonRegistryEntries `
                -Ownership $ownership)
            if ($remaining.Count -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 500
        } while ([DateTimeOffset]::Now -lt $deadline)
        if ($remaining.Count -ne 0) {
            throw ('Winlama Python kaydi kaldirma sonrasinda kaldi: ' +
                $displayName)
        }
    }
    $null = Remove-UninstallPath -Path $pythonRoot `
        -Label 'Winlama Python 3.11 hedefi' `
        -AllowedRoots @($winlamaRoot) -Recurse
    if (Test-Path -LiteralPath $pythonRoot) {
        throw "Winlama Python hedefi kaldirma sonrasinda kaldi: $pythonRoot"
    }
    Write-UninstallLog -Event 'PYTHON_REMOVED' -Level SUCCESS `
        -Action 'Winlama Python 3.11 kaldirma' `
        -Message "Winlama Python hedefi kaldirildi: $pythonRoot"
}
function Get-DeveloperCliNpmPackages {
    return @(
        [pscustomobject]@{
            Name = 'OpenAI Codex CLI'
            PackageName = '@openai/codex'
        },
        [pscustomobject]@{
            Name = 'GitHub Copilot CLI'
            PackageName = '@github/copilot'
        }
    )
}
function Get-UninstallNodeAllowedBases {
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:USERPROFILE
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $paths.Add([IO.Path]::GetFullPath($candidate).TrimEnd('\'))
    }
    return @($paths | Sort-Object Length -Descending -Unique)
}
function Get-UninstallVoltaHomes {
    param(
        [string[]]$Candidates = @(
            [Environment]::GetEnvironmentVariable('VOLTA_HOME'),
            (Join-Path $env:LOCALAPPDATA 'Volta'),
            (Join-Path $env:USERPROFILE '.volta')
        )
    )
    $configured = [Environment]::GetEnvironmentVariable('VOLTA_HOME')
    $homes = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $fullPath = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        if (-not (Test-UninstallNodeRootAllowed -Root $fullPath)) {
            if (-not [string]::IsNullOrWhiteSpace($configured) -and
                $fullPath.Equals(
                    [IO.Path]::GetFullPath($configured).TrimEnd('\'),
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "VOLTA_HOME guvenli kullanici kokunde degil: $fullPath"
            }
            continue
        }
        $allowedBase = @(Get-UninstallNodeAllowedBases | Where-Object {
            Test-UninstallPathWithin -Path $fullPath -Root $_
        } | Select-Object -First 1)
        if ($allowedBase.Count -ne 1) {
            throw "Volta izin koku cozumlenemedi: $fullPath"
        }
        Assert-UninstallNoReparsePoint -Path $fullPath `
            -AllowedRoot $allowedBase[0]
        if ($seen.Add($fullPath)) {
            $homes.Add($fullPath)
        }
    }
    return $homes.ToArray()
}
function Test-UninstallNodeRootAllowed {
    param([Parameter(Mandatory)][string]$Root)
    try {
        $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        if ($fullRoot -cnotmatch '^[A-Za-z]:\\') {
            return $false
        }
        return @(
            Get-UninstallNodeAllowedBases | Where-Object {
                Test-UninstallPathWithin -Path $fullRoot -Root $_
            }
        ).Count -gt 0
    }
    catch {
        return $false
    }
}
function Test-VoltaDeveloperCliPackageMetadata {
    param(
        [AllowNull()][object]$Metadata,
        [Parameter(Mandatory)][string]$PackageName
    )
    try {
        if ($PackageName -notin @(
                '@openai/codex',
                '@github/copilot'
            ) -or
            [string](Get-UninstallPropertyValue `
                -InputObject $Metadata -Name 'name') -cne $PackageName) {
            return $false
        }
        $version = [string](Get-UninstallPropertyValue `
            -InputObject $Metadata -Name 'version')
        if ($version -notmatch
            '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
            return $false
        }
        $bin = Get-UninstallPropertyValue -InputObject $Metadata -Name 'bin'
        $expectedCommand = if ($PackageName -ceq '@openai/codex') {
            'codex'
        }
        else {
            'copilot'
        }
        if ($bin -is [string]) {
            return -not [string]::IsNullOrWhiteSpace([string]$bin)
        }
        $property = $bin.PSObject.Properties[$expectedCommand]
        return $null -ne $property -and
            -not [string]::IsNullOrWhiteSpace([string]$property.Value)
    }
    catch {
        return $false
    }
}
function Get-VoltaDeveloperCliPackageRecords {
    param(
        [string[]]$VoltaHomes = $(Get-UninstallVoltaHomes),
        [scriptblock]$PathExists = {
            param($Path, $PathType)
            Test-Path -LiteralPath $Path -PathType $PathType
        },
        [scriptblock]$MetadataReader = {
            param($Path)
            Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
                ConvertFrom-UninstallJson
        }
    )
    $records = [Collections.Generic.List[object]]::new()
    foreach ($voltaHome in $VoltaHomes) {
        if (-not (Test-UninstallNodeRootAllowed -Root $voltaHome)) {
            throw "Volta koku izin listesinin disinda: $voltaHome"
        }
        $packagesRoot = Join-Path $voltaHome 'tools\image\packages'
        foreach ($package in @(Get-DeveloperCliNpmPackages)) {
            $packageRoot = Join-Path $packagesRoot `
                $package.PackageName.Replace('/', '\')
            if (-not (& $PathExists $packageRoot 'Container')) {
                continue
            }
            Assert-UninstallNoReparsePoint -Path $packagesRoot `
                -AllowedRoot $voltaHome
            $packageRoot = Resolve-SafeUninstallPath `
                -Path $packageRoot -AllowedRoots @($packagesRoot) `
                -Recurse
            Assert-UninstallNoReparsePoint -Path $packageRoot `
                -AllowedRoot $packagesRoot -Recurse
            $metadataMatches = [Collections.Generic.List[string]]::new()
            foreach ($relative in @(
                ('node_modules\{0}\package.json' -f `
                    $package.PackageName.Replace('/', '\')),
                ('lib\node_modules\{0}\package.json' -f `
                    $package.PackageName.Replace('/', '\'))
            )) {
                $metadataPath = Join-Path $packageRoot $relative
                if (-not (& $PathExists $metadataPath 'Leaf')) {
                    continue
                }
                $metadata = & $MetadataReader $metadataPath
                if (-not (Test-VoltaDeveloperCliPackageMetadata `
                    -Metadata $metadata `
                    -PackageName $package.PackageName)) {
                    throw "Volta paket kimligi kanitlanamadi: $packageRoot"
                }
                $metadataMatches.Add($metadataPath)
            }
            if ($metadataMatches.Count -ne 1) {
                throw ('Volta paket kimligi belirsiz: ' +
                    "$packageRoot | Metadata: $($metadataMatches.Count)")
            }
            $records.Add([pscustomobject]@{
                Name = $package.Name
                PackageName = $package.PackageName
                VoltaHome = [IO.Path]::GetFullPath($voltaHome).TrimEnd('\')
                PackagesRoot = [IO.Path]::GetFullPath(
                    $packagesRoot
                ).TrimEnd('\')
                PackageRoot = $packageRoot
                MetadataPath = $metadataMatches[0]
            })
        }
    }
    return $records.ToArray()
}
function Remove-VoltaDeveloperCliPackages {
    param(
        [string[]]$VoltaHomes = $(Get-UninstallVoltaHomes),
        [scriptblock]$PathExists = {
            param($Path, $PathType)
            Test-Path -LiteralPath $Path -PathType $PathType
        },
        [scriptblock]$MetadataReader = {
            param($Path)
            Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
                ConvertFrom-UninstallJson
        },
        [scriptblock]$PackageRemover = {
            param($Record)
            $null = Remove-UninstallPath -Path $Record.PackageRoot `
                -Label "$($Record.Name) Volta paketi" `
                -AllowedRoots @($Record.PackagesRoot) -Recurse
        }
    )
    $removerInjected = $PSBoundParameters.ContainsKey('PackageRemover')
    if ($ValidateOnly -and -not $removerInjected) {
        throw 'ValidateOnly sirasinda Volta paket kaldirma cagrildi.'
    }
    $records = @(Get-VoltaDeveloperCliPackageRecords `
        -VoltaHomes $VoltaHomes -PathExists $PathExists `
        -MetadataReader $MetadataReader)
    if ($records.Count -eq 0) {
        Write-UninstallBootstrapStatus -Level SKIP `
            -Message (Get-UninstallText `
                -Key 'Uninstall.DeveloperCli.VoltaPackagesAbsent' `
                -Fallback ('Resmi Volta gelistirici CLI paketi ' +
                    'zaten yok.'))
        return
    }
    foreach ($record in $records) {
        & $PackageRemover $record
    }
    foreach ($record in $records) {
        if (& $PathExists $record.PackageRoot 'Container') {
            throw "$($record.Name) Volta kaldirma son kosulu basarisiz."
        }
    }
    $remaining = @(Get-VoltaDeveloperCliPackageRecords `
        -VoltaHomes $VoltaHomes -PathExists $PathExists `
        -MetadataReader $MetadataReader)
    if ($remaining.Count -ne 0) {
        throw ('Volta CLI paketleri kaldirma sonrasinda kaldi: ' +
            (@($remaining.PackageRoot) -join ', '))
    }
}
function Get-NodeRuntimeCandidateRoots {
    $roots = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $add = {
        param([AllowEmptyString()][string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }
        try {
            $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
            if ($seen.Add($fullPath)) {
                $roots.Add($fullPath)
            }
        }
        catch {
            Write-Verbose "Node.js aday yolu gecersiz: $Path"
        }
    }.GetNewClosure()
    foreach ($path in @(
        (Join-Path $env:ProgramFiles 'nodejs'),
        $(if (-not [string]::IsNullOrWhiteSpace(
            ${env:ProgramFiles(x86)}
        )) {
            Join-Path ${env:ProgramFiles(x86)} 'nodejs'
        }),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs')
    )) {
        & $add $path
    }
    foreach ($name in @('node.exe', 'npm.cmd')) {
        foreach ($command in @(Get-Command $name -All `
            -ErrorAction SilentlyContinue)) {
            & $add (Split-Path -Parent ([string]$command.Source))
        }
    }
    $nvmBases = @(
        [Environment]::GetEnvironmentVariable('NVM_HOME'),
        (Join-Path $env:APPDATA 'nvm'),
        (Join-Path $env:LOCALAPPDATA 'nvm')
    )
    foreach ($base in $nvmBases) {
        if ([string]::IsNullOrWhiteSpace($base)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $base -PathType Container)) {
            continue
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $base `
            -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($directory.Name -match '^v?\d+\.\d+\.\d+$') {
                & $add $directory.FullName
            }
        }
    }
    $fnmBases = @(
        [Environment]::GetEnvironmentVariable('FNM_DIR'),
        (Join-Path $env:LOCALAPPDATA 'fnm'),
        (Join-Path $env:APPDATA 'fnm')
    )
    foreach ($base in $fnmBases) {
        if ([string]::IsNullOrWhiteSpace($base)) {
            continue
        }
        $versions = Join-Path $base 'node-versions'
        if (-not (Test-Path -LiteralPath $versions `
            -PathType Container)) {
            continue
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $versions `
            -Directory -Force -ErrorAction SilentlyContinue)) {
            & $add (Join-Path $directory.FullName 'installation')
        }
    }
    & $add ([Environment]::GetEnvironmentVariable(
        'FNM_MULTISHELL_PATH'
    ))
    $voltaBases = @(
        [Environment]::GetEnvironmentVariable('VOLTA_HOME'),
        (Join-Path $env:LOCALAPPDATA 'Volta')
    )
    foreach ($base in $voltaBases) {
        if ([string]::IsNullOrWhiteSpace($base)) {
            continue
        }
        $images = Join-Path $base 'tools\image\node'
        if (-not (Test-Path -LiteralPath $images `
            -PathType Container)) {
            continue
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $images `
            -Directory -Force -ErrorAction SilentlyContinue)) {
            & $add $directory.FullName
            & $add (Join-Path $directory.FullName 'bin')
        }
    }
    return $roots.ToArray()
}
function Test-NpmRuntimeIdentity {
    param([Parameter(Mandatory)][string]$NpmCli)
    try {
        $metadataPath = [IO.Path]::GetFullPath(
            (Join-Path (Split-Path -Parent `
                (Split-Path -Parent $NpmCli)) 'package.json')
        )
        $metadata = Get-Content -LiteralPath $metadataPath -Raw `
            -Encoding UTF8 | ConvertFrom-UninstallJson
        $version = $null
        return [string]$metadata.name -ceq 'npm' -and
            [version]::TryParse([string]$metadata.version, [ref]$version)
    }
    catch {
        return $false
    }
}
function Get-TrustedNodeNpmRuntimes {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()][string[]]$CandidateRoots
    )
    $runtimes = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $CandidateRoots) {
        if (-not (Test-UninstallNodeRootAllowed -Root $candidate)) {
            continue
        }
        $root = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        $node = Join-Path $root 'node.exe'
        $npmCli = Join-Path $root 'node_modules\npm\bin\npm-cli.js'
        if (-not (Test-Path -LiteralPath $node -PathType Leaf) -or
            -not (Test-Path -LiteralPath $npmCli -PathType Leaf)) {
            continue
        }
        $allowedBase = @(Get-UninstallNodeAllowedBases | Where-Object {
            Test-UninstallPathWithin -Path $root -Root $_
        } | Select-Object -First 1)
        if ($allowedBase.Count -ne 1) {
            continue
        }
        try {
            Assert-UninstallNoReparsePoint -Path $node `
                -AllowedRoot $allowedBase[0]
            Assert-UninstallNoReparsePoint -Path $npmCli `
                -AllowedRoot $allowedBase[0]
        }
        catch {
            Write-Verbose "Node.js yeniden ayrisim adayi reddedildi: $root"
            continue
        }
        if (-not (Test-UninstallTrustedSigner -FilePath $node `
            -SubjectPattern '(?i)(OpenJS Foundation|Node\.js)') -or
            -not (Test-NpmRuntimeIdentity -NpmCli $npmCli)) {
            Write-Verbose "Node.js/NPM kimligi reddedildi: $root"
            continue
        }
        $runtimes.Add([pscustomobject]@{
            Root = $root
            Node = [IO.Path]::GetFullPath($node)
            NpmCli = [IO.Path]::GetFullPath($npmCli)
        })
    }
    return $runtimes.ToArray()
}
function Get-NpmGlobalRootAllowlist {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()][string[]]$RuntimeRoots
    )
    $roots = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($candidate in @(
        (Join-Path $env:APPDATA 'npm\node_modules'),
        (Join-Path $env:LOCALAPPDATA 'npm\node_modules')
    ) + @($RuntimeRoots | ForEach-Object {
        Join-Path $_ 'node_modules'
    })) {
        try {
            $fullPath = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
            if ((Test-UninstallNodeRootAllowed -Root $fullPath) -and
                $seen.Add($fullPath)) {
                $roots.Add($fullPath)
            }
        }
        catch {
            Write-Verbose "NPM kok adayi gecersiz: $candidate"
        }
    }
    return $roots.ToArray()
}
function Get-TrustedNpmGlobalRoot {
    param(
        [Parameter(Mandatory)][pscustomobject]$Runtime,
        [Parameter(Mandatory)][string[]]$AllowedRoots
    )
    $result = Invoke-UninstallNativeProcess -FilePath $Runtime.Node `
        -ArgumentList @($Runtime.NpmCli, 'root', '--global') `
        -Action 'NPM genel paket kokunu sorgula' -SuppressUiOutput
    if (-not $result.OutputComplete) {
        throw 'NPM genel paket koku ciktisi tamamlanmadi.'
    }
    $lines = @([regex]::Split(
        $result.StandardOutput,
        '\r\n|\n|\r'
    ) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if ($lines.Count -ne 1 -or
        -not [IO.Path]::IsPathRooted($lines[0])) {
        throw 'NPM genel paket koku kesin olarak cozumlenemedi.'
    }
    $root = [IO.Path]::GetFullPath($lines[0]).TrimEnd('\')
    if (@($AllowedRoots | Where-Object {
        [IO.Path]::GetFullPath($_).TrimEnd('\') -ieq $root
    }).Count -ne 1) {
        throw "Guvenli olmayan NPM genel paket koku: $root"
    }
    if (Test-Path -LiteralPath $root) {
        Assert-UninstallNoReparsePoint -Path $root -AllowedRoot $root
    }
    return $root
}
function Get-NpmPackagePath {
    param(
        [Parameter(Mandatory)][string]$GlobalRoot,
        [Parameter(Mandatory)][string]$PackageName
    )
    if ($PackageName -notmatch '^@(?:openai|github)/[a-z0-9-]+$') {
        throw "Desteklenmeyen NPM paket kimligi: $PackageName"
    }
    $relative = $PackageName.Replace('/', '\')
    return Resolve-SafeUninstallPath `
        -Path (Join-Path $GlobalRoot $relative) `
        -AllowedRoots @($GlobalRoot)
}
function Test-NpmPackageIdentity {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$PackageName,
        [scriptblock]$MetadataReader = {
            param($Path)
            Get-Content -LiteralPath $Path -Raw `
                -Encoding UTF8 | ConvertFrom-UninstallJson
        }
    )
    $metadataPath = Join-Path $PackagePath 'package.json'
    try {
        $metadata = & $MetadataReader $metadataPath
        return [string]$metadata.name -ceq $PackageName
    }
    catch {
        return $false
    }
}
function Remove-NpmDeveloperCliPackages {
    $candidateRoots = @(Get-NodeRuntimeCandidateRoots)
    $allowedRoots = @(Get-NpmGlobalRootAllowlist `
        -RuntimeRoots $candidateRoots)
    $runtimes = @(Get-TrustedNodeNpmRuntimes `
        -CandidateRoots $candidateRoots)
    $runtimeByRoot = @{}
    foreach ($runtime in $runtimes) {
        try {
            $globalRoot = Get-TrustedNpmGlobalRoot -Runtime $runtime `
                -AllowedRoots $allowedRoots
            if (-not $runtimeByRoot.ContainsKey($globalRoot)) {
                $runtimeByRoot[$globalRoot] = $runtime
            }
        }
        catch {
            Write-UninstallLog -Event 'NPM_RUNTIME_REJECTED' `
                -Level WARN -Action 'Gelistirici CLI temizligi' `
                -Message $_.Exception.Message -ErrorRecord $_
        }
    }
    $removed = 0
    foreach ($globalRoot in @($runtimeByRoot.Keys)) {
        $runtime = $runtimeByRoot[$globalRoot]
        foreach ($package in @(Get-DeveloperCliNpmPackages)) {
            $rawPath = Join-Path $globalRoot `
                $package.PackageName.Replace('/', '\')
            if (-not (Test-Path -LiteralPath $rawPath `
                -PathType Container)) {
                continue
            }
            $packagePath = Get-NpmPackagePath -GlobalRoot $globalRoot `
                -PackageName $package.PackageName
            Assert-UninstallNoReparsePoint -Path $packagePath `
                -AllowedRoot $globalRoot -Recurse
            if (-not (Test-NpmPackageIdentity -PackagePath $packagePath `
                -PackageName $package.PackageName)) {
                throw "NPM paket kimligi kanitlanamadi: $packagePath"
            }
            $null = Invoke-UninstallNativeProcess `
                -FilePath $runtime.Node -ArgumentList @(
                    $runtime.NpmCli, 'uninstall', '--global',
                    $package.PackageName, '--ignore-scripts',
                    '--no-audit', '--no-fund'
                ) -Action "$($package.Name) NPM kaldirma"
            if (Test-Path -LiteralPath $packagePath) {
                throw "$($package.Name) NPM kaldirma son kosulu basarisiz."
            }
            $removed++
        }
    }
    $remaining = [Collections.Generic.List[string]]::new()
    foreach ($globalRoot in $allowedRoots) {
        foreach ($package in @(Get-DeveloperCliNpmPackages)) {
            $rawPath = Join-Path $globalRoot `
                $package.PackageName.Replace('/', '\')
            if (-not (Test-Path -LiteralPath $rawPath `
                -PathType Container)) {
                continue
            }
            $packagePath = Get-NpmPackagePath -GlobalRoot $globalRoot `
                -PackageName $package.PackageName
            Assert-UninstallNoReparsePoint -Path $packagePath `
                -AllowedRoot $globalRoot -Recurse
            if (-not (Test-NpmPackageIdentity -PackagePath $packagePath `
                -PackageName $package.PackageName)) {
                throw "NPM paket kimligi kanitlanamadi: $packagePath"
            }
            $remaining.Add($packagePath)
        }
    }
    if ($remaining.Count -gt 0) {
        throw ('Guvenilir NPM kaldirma ortami bulunamayan resmi CLI ' +
            "paketleri var: $($remaining -join ', ')")
    }
    if ($removed -eq 0) {
        Write-UninstallBootstrapStatus -Level SKIP `
            -Message (Get-UninstallText `
                -Key 'Uninstall.DeveloperCli.NpmRuntimeMissing' `
                -Fallback ('Guvenilir Node.js/NPM bulunamadi; ' +
                    'resmi NPM CLI paketi yok.'))
    }
}
function Test-UninstallOwnedJunctionTarget {
    param(
        [AllowNull()][string]$Target,
        [Parameter(Mandatory)][string]$OwnerRoot
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Target) -or
            -not [IO.Path]::IsPathRooted($Target)) {
            return $false
        }
        return Test-UninstallPathWithin `
            -Path ([IO.Path]::GetFullPath($Target)) `
            -Root ([IO.Path]::GetFullPath($OwnerRoot)) -AllowRoot
    }
    catch {
        return $false
    }
}
function Remove-UninstallOwnedJunction {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$Label
    )
    $fullPath = Resolve-SafeUninstallPath -Path $Path `
        -AllowedRoots @($AllowedRoot) -SkipReparseCheck
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return
    }
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    $targets = @($item.Target)
    if (-not (Test-UninstallReparseAttribute `
            -Attributes $item.Attributes) -or
        [string]$item.LinkType -ine 'Junction' -or
        $targets.Count -ne 1 -or
        -not (Test-UninstallOwnedJunctionTarget `
            -Target ([string]$targets[0]) -OwnerRoot $TargetRoot)) {
        throw "$Label Winlama tarafindan guvenle kaldirilabilir degil."
    }
    Remove-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $fullPath) {
        throw "$Label kaldirma son kosulu basarisiz: $fullPath"
    }
    Write-UninstallBootstrapStatus -Level SUCCESS `
        -Message (Get-UninstallText `
            -Key 'Uninstall.Path.Removed' `
            -Fallback '{0} kaldirildi.' -Arguments @($Label))
}
function Test-UninstallEnvironmentPathEntry {
    param(
        [AllowNull()][string]$Entry,
        [Parameter(Mandatory)][string]$ExpectedPath
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Entry)) {
            return $false
        }
        $value = $Entry.Trim()
        if ($value.Length -ge 2 -and
            $value.StartsWith('"') -and
            $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $expanded = [Environment]::ExpandEnvironmentVariables($value)
        if (-not [IO.Path]::IsPathRooted($expanded)) {
            return $false
        }
        return [IO.Path]::GetFullPath($expanded).TrimEnd('\').Equals(
            [IO.Path]::GetFullPath($ExpectedPath).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}
function Remove-StandaloneCodexCli {
    $codexHome = Join-Path $env:USERPROFILE '.codex'
    $standaloneRoot = Join-Path $codexHome 'packages\standalone'
    $releasesRoot = Join-Path $standaloneRoot 'releases'
    $currentJunction = Join-Path $standaloneRoot 'current'
    $codexProgramRoot = Join-Path $env:LOCALAPPDATA `
        'Programs\OpenAI\Codex'
    $visibleBin = Join-Path $codexProgramRoot 'bin'
    if (-not (Test-Path -LiteralPath $standaloneRoot) -and
        -not (Test-Path -LiteralPath $visibleBin)) {
        Write-UninstallBootstrapStatus -Level SKIP `
            -Message (Get-UninstallText `
                -Key 'Uninstall.DeveloperCli.CodexStandaloneAbsent' `
                -Fallback 'Resmi Codex standalone kurulumu zaten yok.')
        return
    }
    if (Test-Path -LiteralPath $standaloneRoot -PathType Container) {
        Stop-UninstallProcessesFromPath -RootPath $standaloneRoot `
            -AllowedRoots @($standaloneRoot) -AllowRoot
    }
    Remove-UninstallOwnedJunction -Path $visibleBin `
        -AllowedRoot $codexProgramRoot `
        -TargetRoot $standaloneRoot `
        -Label 'Codex gorunur komut baglantisi'
    Remove-UninstallOwnedJunction -Path $currentJunction `
        -AllowedRoot $standaloneRoot -TargetRoot $releasesRoot `
        -Label 'Codex guncel surum baglantisi'
    $null = Remove-UninstallPath -Path $standaloneRoot `
        -Label 'Codex standalone paketleri' `
        -AllowedRoots @($codexHome) -Recurse
    $userPath = [string][Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::User
    )
    $segments = @($userPath -split ';' | Where-Object {
        -not (Test-UninstallEnvironmentPathEntry `
            -Entry $_ -ExpectedPath $visibleBin)
    })
    $newPath = $segments -join ';'
    if ($newPath -cne $userPath) {
        [Environment]::SetEnvironmentVariable(
            'Path',
            $newPath,
            [EnvironmentVariableTarget]::User
        )
        Write-UninstallBootstrapStatus -Level SUCCESS `
            -Message (Get-UninstallText `
                -Key 'Uninstall.DeveloperCli.CodexPathRemoved' `
                -Fallback 'Codex PATH kaydi kaldirildi.')
    }
    $remainingPath = [string][Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::User
    )
    if (@($remainingPath -split ';' | Where-Object {
        Test-UninstallEnvironmentPathEntry `
            -Entry $_ -ExpectedPath $visibleBin
    }).Count -ne 0) {
        throw 'Codex PATH kaydi kaldirma son kosulu basarisiz.'
    }
}
function Get-GitHubCopilotRegistryEntries {
    param([object[]]$Entries = $(Get-UninstallRegistryEntries))
    return @($Entries | Where-Object {
        (Get-UninstallDisplayName -Entry $_) -match `
            '^GitHub Copilot(?: CLI)?(?: Prerelease)?$'
    })
}
function Get-DeveloperCliWingetPackageIds {
    return @(
        'GitHub.Copilot',
        'GitHub.Copilot.Prerelease'
    )
}
function Test-WingetExactPackageInstalled {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$PackageId,
        [scriptblock]$ProcessInvoker = {
            param($Path, $Arguments, $AllowedCodes, $Action)
            Invoke-UninstallNativeProcess -FilePath $Path `
                -ArgumentList $Arguments `
                -AllowedExitCodes $AllowedCodes -Action $Action `
                -SuppressUiOutput
        }
    )
    if ($PackageId -notin @(Get-DeveloperCliWingetPackageIds)) {
        throw "Desteklenmeyen Winget CLI kimligi: $PackageId"
    }
    $notFound = -1978335212
    $result = & $ProcessInvoker $WingetPath @(
        'list', '--exact', '--id', $PackageId,
        '--disable-interactivity', '--accept-source-agreements'
    ) @(0, $notFound) "Winget exact CLI sorgusu: $PackageId"
    if (-not [bool]$result.OutputComplete) {
        throw "Winget exact CLI sorgu ciktisi tamamlanmadi: $PackageId"
    }
    if ([int]$result.ExitCode -eq $notFound) {
        return $false
    }
    if ([int]$result.ExitCode -ne 0) {
        throw "Winget exact CLI sorgusu basarisiz: $PackageId"
    }
    $output = [regex]::Replace(
        [string]$result.StandardOutput,
        '\x1B\[[0-?]*[ -/]*[@-~]',
        ''
    )
    foreach ($line in [regex]::Split($output, '\r\n|\n|\r')) {
        foreach ($token in @($line -split '\s+' | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        })) {
            if ($token -ceq $PackageId) {
                return $true
            }
        }
    }
    return $false
}
function Remove-WingetDeveloperCliPackages {
    param(
        [AllowEmptyString()][string]$WingetPath = '',
        [scriptblock]$PackageProbe,
        [scriptblock]$PackageUninstaller
    )
    $injected = $PSBoundParameters.ContainsKey('WingetPath') -and
        $PSBoundParameters.ContainsKey('PackageProbe') -and
        $PSBoundParameters.ContainsKey('PackageUninstaller')
    if ($ValidateOnly -and -not $injected) {
        throw 'ValidateOnly sirasinda Winget CLI kaldirma cagrildi.'
    }
    if ([string]::IsNullOrWhiteSpace($WingetPath)) {
        $command = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            Write-UninstallBootstrapStatus -Level SKIP `
                -Message (Get-UninstallText `
                    -Key 'Uninstall.DeveloperCli.WingetRuntimeMissing' `
                    -Fallback ('Winget bulunamadi; Winget CLI paketi ' +
                        'yok.'))
            return
        }
        $WingetPath = Get-UninstallTrustedWingetPath
    }
    if ($null -eq $PackageProbe) {
        $PackageProbe = {
            param($Path, $PackageId)
            Test-WingetExactPackageInstalled `
                -WingetPath $Path -PackageId $PackageId
        }
    }
    if ($null -eq $PackageUninstaller) {
        $PackageUninstaller = {
            param($Path, $PackageId)
            $null = Invoke-UninstallNativeProcess -FilePath $Path `
                -ArgumentList @(
                    'uninstall', '--exact', '--id', $PackageId,
                    '--silent', '--disable-interactivity',
                    '--accept-source-agreements'
                ) -AllowedExitCodes @(0, -1978335212) `
                -Action "Winget CLI kaldirma: $PackageId"
        }
    }
    $installed = [Collections.Generic.List[string]]::new()
    foreach ($packageId in @(Get-DeveloperCliWingetPackageIds)) {
        if (& $PackageProbe $WingetPath $packageId) {
            $installed.Add($packageId)
        }
    }
    if ($installed.Count -eq 0) {
        Write-UninstallBootstrapStatus -Level SKIP `
            -Message (Get-UninstallText `
                -Key 'Uninstall.DeveloperCli.CopilotWingetAbsent' `
                -Fallback ('Winget GitHub Copilot CLI paketi ' +
                    'zaten yok.'))
        return
    }
    foreach ($packageId in $installed) {
        & $PackageUninstaller $WingetPath $packageId
    }
    $remaining = @(Get-DeveloperCliWingetPackageIds | Where-Object {
        & $PackageProbe $WingetPath $_
    })
    if ($remaining.Count -ne 0) {
        throw ('GitHub Copilot CLI Winget kaldirma son kosulu ' +
            "basarisiz: $($remaining -join ', ')")
    }
}
function Remove-DeveloperCliApplications {
    $actions = @(
        [pscustomobject]@{
            Name = 'Codex resmi standalone kurulumu'
            Action = { Remove-StandaloneCodexCli }
        },
        [pscustomobject]@{
            Name = 'Codex ve Copilot NPM paketleri'
            Action = { Remove-NpmDeveloperCliPackages }
        },
        [pscustomobject]@{
            Name = 'Codex ve Copilot Volta paketleri'
            Action = { Remove-VoltaDeveloperCliPackages }
        },
        [pscustomobject]@{
            Name = 'GitHub Copilot Winget paketi'
            Action = { Remove-WingetDeveloperCliPackages }
        }
    )
    $result = Invoke-UninstallAggregateActions -Actions $actions
    if (-not $result.Succeeded) {
        throw ('Gelistirici CLI kaldirma bazi hatalarla tamamlandi: ' +
            (@($result.Failures.Name) -join ', '))
    }
}
function Remove-ComfyUI {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $expectedInstall = Get-UninstallExpectedComfyUIRoot
    $expectedModels = Get-UninstallExpectedComfyUIModelsRoot
    $installPath = Resolve-SafeUninstallPath `
        -Path ([string](Get-UninstallPropertyValue `
            -InputObject $Config.ComfyUI -Name 'InstallPath')) `
        -AllowedRoots @($expectedInstall) -AllowRoot
    $modelsPath = Resolve-SafeUninstallPath `
        -Path ([string](Get-UninstallPropertyValue `
            -InputObject $Config.ComfyUI -Name 'ModelsPath')) `
        -AllowedRoots @($expectedModels) -AllowRoot
    $installPath = Assert-UninstallExactPath -Actual $installPath `
        -Expected $expectedInstall -Label 'ComfyUI kurulum yolu'
    $modelsPath = Assert-UninstallExactPath -Actual $modelsPath `
        -Expected $expectedModels -Label 'ComfyUI model yolu'
    Stop-UninstallProcessesFromPath -RootPath $installPath `
        -AllowedRoots @($expectedInstall) -AllowRoot
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) 'Winlama\ComfyUI'
    $actions = @(
        [pscustomobject]@{
            Name = 'ComfyUI uygulamasi'
            Action = {
                $null = Remove-UninstallPath -Path $installPath `
                    -Label 'ComfyUI uygulamasi' `
                    -AllowedRoots @($expectedInstall) `
                    -AllowRoot -Recurse
            }.GetNewClosure()
        },
        [pscustomobject]@{
            Name = 'ComfyUI modelleri'
            Action = {
                $null = Remove-UninstallPath -Path $modelsPath `
                    -Label 'ComfyUI modelleri' `
                    -AllowedRoots @($expectedModels) `
                    -AllowRoot -Recurse
            }.GetNewClosure()
        },
        [pscustomobject]@{
            Name = 'ComfyUI gecici medyasi'
            Action = {
                $null = Remove-UninstallPath -Path $tempRoot `
                    -Label 'ComfyUI gecici medyasi' `
                    -AllowedRoots @($tempRoot) -AllowRoot -Recurse
            }.GetNewClosure()
        }
    )
    $result = Invoke-UninstallAggregateActions -Actions $actions
    if (-not $result.Succeeded) {
        throw ('ComfyUI temizligi basarisiz: ' +
            (@($result.Failures.Message) -join ' | '))
    }
}
function Get-WinlamaFirewallRules {
    param([Parameter(Mandatory)][string]$Name)
    $command = Get-Command Get-NetFirewallRule `
        -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return @()
    }
    return @(
        Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
        Get-NetFirewallRule -DisplayName $Name `
            -ErrorAction SilentlyContinue
    ) | Sort-Object Name -Unique
}
function Remove-WinlamaFirewallRule {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notin @(
        'Winlama-Ollama-LAN',
        'Winlama-WebUI-LAN',
        'Winlama-Ollama-LocalOnly',
        'Winlama-WebUI-LocalOnly'
    )) {
        throw "Guvenli olmayan guvenlik duvari kurali: $Name"
    }
    $rules = @(Get-WinlamaFirewallRules -Name $Name)
    if ($rules.Count -gt 0) {
        $command = Get-Command Remove-NetFirewallRule `
            -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $rules | Remove-NetFirewallRule -ErrorAction Stop
        }
        else {
            $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
            $null = Invoke-UninstallNativeProcess -FilePath $netsh `
                -ArgumentList @(
                    'advfirewall', 'firewall', 'delete', 'rule',
                    "name=$Name"
                ) -Action "Guvenlik duvari kurali $Name"
        }
    }
    if (@(Get-WinlamaFirewallRules -Name $Name).Count -gt 0) {
        throw "Guvenlik duvari kurali son kosulu basarisiz: $Name"
    }
}
function Remove-WinlamaScheduledTask {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -cne 'Winlama-Deployment-Resume') {
        throw "Guvenli olmayan zamanlanmis gorev adi: $Name"
    }
    $getTask = Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue
    $removeTask = Get-Command Unregister-ScheduledTask `
        -ErrorAction SilentlyContinue
    if ($null -ne $getTask -and $null -ne $removeTask) {
        $task = Get-ScheduledTask -TaskName $Name `
            -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            Unregister-ScheduledTask -TaskName $Name `
                -Confirm:$false -ErrorAction Stop
        }
        if ($null -ne (Get-ScheduledTask -TaskName $Name `
            -ErrorAction SilentlyContinue)) {
            throw "Zamanlanmis gorev son kosulu basarisiz: $Name"
        }
        return
    }
    $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $query = Invoke-UninstallNativeProcess -FilePath $schtasks `
        -ArgumentList @('/Query', '/TN', $Name) `
        -AllowedExitCodes @(0, 1) `
        -Action "Zamanlanmis gorevi sorgula $Name"
    if ($query.ExitCode -eq 0) {
        $null = Invoke-UninstallNativeProcess -FilePath $schtasks `
            -ArgumentList @('/Delete', '/TN', $Name, '/F') `
            -Action "Zamanlanmis gorevi kaldir $Name"
        $verify = Invoke-UninstallNativeProcess -FilePath $schtasks `
            -ArgumentList @('/Query', '/TN', $Name) `
            -AllowedExitCodes @(0, 1) `
            -Action "Zamanlanmis gorevi dogrula $Name"
        if ($verify.ExitCode -eq 0) {
            throw "Zamanlanmis gorev son kosulu basarisiz: $Name"
        }
    }
}
function Remove-WinlamaSettings {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $actions = [Collections.Generic.List[object]]::new()
    $firewall = Get-UninstallPropertyValue `
        -InputObject $Config.Security -Name 'FirewallRules'
    foreach ($property in @($firewall.PSObject.Properties)) {
        $ruleName = [string]$property.Value
        $actions.Add([pscustomobject]@{
            Name = "Guvenlik duvari kurali $ruleName"
            Action = {
                Remove-WinlamaFirewallRule -Name $ruleName
            }.GetNewClosure()
        })
    }
    $taskName = [string](Get-UninstallPropertyValue `
        -InputObject $Config.Uninstall -Name 'ResumeTaskName')
    $actions.Add([pscustomobject]@{
        Name = "Zamanlanmis gorev $taskName"
        Action = {
            Remove-WinlamaScheduledTask -Name $taskName
        }.GetNewClosure()
    })
    $startupRoot = [Environment]::ExpandEnvironmentVariables(
        '%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup'
    )
    $configuredShortcut = [Environment]::ExpandEnvironmentVariables(
        [string](Get-UninstallPropertyValue `
            -InputObject $Config.Startup -Name 'ShortcutPath')
    )
    $expectedShortcut = Join-Path $startupRoot 'Winlama.lnk'
    $configuredShortcut = Assert-UninstallExactPath `
        -Actual $configuredShortcut -Expected $expectedShortcut `
        -Label 'Winlama baslangic kisayolu'
    foreach ($shortcut in @(
        $configuredShortcut,
        (Join-Path $startupRoot 'Winlama-OpenWebUI.lnk')
    )) {
        $target = $shortcut
        $actions.Add([pscustomobject]@{
            Name = "Baslangic kisayolu $target"
            Action = {
                $null = Remove-UninstallPath -Path $target `
                    -Label 'Winlama baslangic kisayolu' `
                    -AllowedRoots @($startupRoot)
            }.GetNewClosure()
        })
    }
    $result = Invoke-UninstallAggregateActions `
        -Actions $actions.ToArray()
    if (-not $result.Succeeded) {
        throw ('Winlama ayar temizligi basarisiz: ' +
            (@($result.Failures.Message) -join ' | '))
    }
}
function New-WinlamaRootCleanupScript {
    $template = @'
param(
    [Parameter(Mandatory)][string]$RootPath,
    [AllowEmptyString()][string]$PreservePath = '',
    [Parameter(Mandatory)][int]$ParentProcessId,
    [Parameter(Mandatory)][long]$ParentStartTicks,
    [int]$OwnerProcessId = 0,
    [long]$OwnerStartTicks = 0,
    [Parameter(Mandatory)][string]$CleanupId,
    [Parameter(Mandatory)][string]$StatusPath
)
$ErrorActionPreference = 'Stop'
try {
    $Host.UI.RawUI.BackgroundColor = [ConsoleColor]::Black
    $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::White
    [Console]::BackgroundColor = [ConsoleColor]::Black
    [Console]::ForegroundColor = [ConsoleColor]::White
}
catch {
}
function Write-CleanupRule {
    param(
        [ValidateSet('-', '=')][string]$Character = '-',
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )
    $Host.UI.WriteLine($Color, [ConsoleColor]::Black,
        ($Character * 100))
}
function Write-CleanupLine {
    param(
        [Parameter(Mandatory)][string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    foreach ($logicalLine in [regex]::Split($Text, '\r\n|\n|\r')) {
        $remaining = $logicalLine.TrimStart()
        do {
            $length = [Math]::Min(96, $remaining.Length)
            $part = $remaining.Substring(0, $length)
            $Host.UI.WriteLine(
                $Color,
                [ConsoleColor]::Black,
                ('| {0} |' -f $part.PadRight(96))
            )
            $remaining = if ($remaining.Length -le $length) {
                ''
            }
            else {
                $remaining.Substring($length).TrimStart()
            }
        } while ($remaining.Length -gt 0)
    }
}
function Get-CleanupUIStatusStyle {
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
function Get-CleanupUIStatusWidth {
    $width = 0
    foreach ($level in @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    )) {
        $style = Get-CleanupUIStatusStyle -Level $level
        $width = [Math]::Max($width, $style.Label.Length)
    }
    return $width
}
function Format-CleanupUIStatusLabel {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL',
            'SKIP'
        )]
        [string]$Level
    )
    $style = Get-CleanupUIStatusStyle -Level $Level
    $width = Get-CleanupUIStatusWidth
    $left = [Math]::Floor(($width - $style.Label.Length) / 2)
    return ((' ' * $left) + $style.Label).PadRight($width)
}
function Write-CleanupUIStatus {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL',
            'SKIP'
        )]
        [string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $style = Get-CleanupUIStatusStyle -Level $Level
    $label = Format-CleanupUIStatusLabel -Level $Level
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
            $status = if ($first) { $label } else { ' ' * 5 }
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
function Format-CleanupInputLine {
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
function ConvertFrom-CleanupReadValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    if ($null -eq $Value) {
        throw [IO.EndOfStreamException]::new(
            'Standart girdi kapali; zorunlu komut okunamadi.'
        )
    }
    return [string]$Value
}
function Test-CleanupExactExit {
    param([AllowNull()][string]$Value)
    return $null -ne $Value -and $Value -ceq 'CIKIS'
}
function Read-CleanupRawInput {
    param([scriptblock]$InputReader)
    if ($null -ne $InputReader) {
        $readValue = & $InputReader
        $value = ConvertFrom-CleanupReadValue -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-CleanupInputLine -Value $value))
        return $value
    }
    if ([Console]::IsInputRedirected) {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-CleanupReadValue -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-CleanupInputLine -Value $value))
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
                (Format-CleanupInputLine -Value $value))
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
            (Format-CleanupInputLine -Value $value))
        return $value
    }
    catch {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-CleanupReadValue -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-CleanupInputLine -Value $value))
        return $value
    }
}
function Wait-CleanupExit {
    param([scriptblock]$InputReader)
    while ($true) {
        Write-CleanupUIStatus -Level INFO `
            -Message '__WINLAMA_CLOSE_PROMPT__'
        Write-CleanupUIStatus -Level DETAIL `
            -Message '__WINLAMA_EXACT_COMMAND__'
        Write-CleanupRule
        $value = Read-CleanupRawInput -InputReader $InputReader
        Write-CleanupRule
        if (Test-CleanupExactExit -Value $value) {
            return
        }
        Write-CleanupUIStatus -Level WARN `
            -Message '__WINLAMA_INVALID_COMMAND__'
    }
}
function Complete-CleanupOperation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('SUCCESS', 'WARN', 'ERROR', 'SKIP')]
        [string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [string]$Detail = '',
        [scriptblock]$InputReader
    )
    Write-CleanupRule -Character '='
    Write-CleanupLine -Text '__WINLAMA_OPERATION_SUMMARY__' `
        -Color Cyan
    Write-CleanupUIStatus -Level $Level -Message $Message
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        Write-CleanupUIStatus -Level DETAIL -Message $Detail
    }
    $ruleColor = switch ($Level) {
        'SUCCESS' { 'Green' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'SKIP' { 'Yellow' }
    }
    Write-CleanupRule -Character '=' `
        -Color $ruleColor
    try {
        Wait-CleanupExit -InputReader $InputReader
    }
    catch [IO.EndOfStreamException] {
        return
    }
}
try {
    $Host.UI.RawUI.WindowTitle = '__WINLAMA_CLEANUP_WINDOW_TITLE__'
}
catch {
}
$target = ''
$preserve = ''
$status = ''
$cleanupIdValid = $false
$statusPathValid = $false
$preflightValid = $false
$preflightDetail = ''
try {
    $expected = [IO.Path]::GetFullPath(
        (Join-Path $env:LOCALAPPDATA 'Programs\Winlama')
    ).TrimEnd('\')
    $target = [IO.Path]::GetFullPath($RootPath).TrimEnd('\')
    $expectedPreserve = [IO.Path]::GetFullPath(
        (Join-Path $expected 'Dependencies\Python311')
    ).TrimEnd('\')
    $preserve = if ([string]::IsNullOrWhiteSpace($PreservePath)) {
        ''
    }
    else {
        [IO.Path]::GetFullPath($PreservePath).TrimEnd('\')
    }
    $expectedStatus = [IO.Path]::GetFullPath(
        (Join-Path ([IO.Path]::GetTempPath()) `
            "winlama-cleanup-$CleanupId.status.json")
    )
    $status = [IO.Path]::GetFullPath($StatusPath)
    $cleanupIdValid = $CleanupId -match '^[a-f0-9]{32}$'
    $statusPathValid = $cleanupIdValid -and
        $status -ieq $expectedStatus
    $preflightValid = $target -ieq $expected -and
        $cleanupIdValid -and
        $statusPathValid -and
        ([string]::IsNullOrWhiteSpace($preserve) -or
            $preserve -ieq $expectedPreserve)
}
catch {
    $preflightDetail = $_.Exception.Message
}
function Remove-CleanupStatus {
    if (-not $statusPathValid -or
        [string]::IsNullOrWhiteSpace($status)) {
        return
    }
    Remove-Item -LiteralPath $status -Force -ErrorAction SilentlyContinue
}
if (-not $preflightValid) {
    Remove-CleanupStatus
    Complete-CleanupOperation -Level ERROR `
        -Message '__WINLAMA_CLEANUP_PREFLIGHT_INVALID__' `
        -Detail $preflightDetail
    exit 1
}
Write-CleanupRule -Character '='
Write-CleanupLine -Text '__WINLAMA_CLEANUP_TITLE__' -Color Cyan
Write-CleanupUIStatus -Level INFO `
    -Message '__WINLAMA_CLEANUP_WAIT__'
Write-CleanupRule -Character '='
function Write-CleanupStatus {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][bool]$RootAbsent,
        [Parameter(Mandatory)][bool]$PayloadRemoved,
        [Parameter(Mandatory)][int]$Attempt,
        [string]$ErrorMessage = ''
    )
    $document = [ordered]@{
        schemaVersion = 1
        cleanupId = $CleanupId
        phase = $Phase
        processId = $PID
        parentProcessId = $ParentProcessId
        ownerProcessId = $OwnerProcessId
        rootPath = $target
        preservedPath = $preserve
        rootAbsent = $RootAbsent
        payloadRemoved = $PayloadRemoved
        attempt = $Attempt
        error = $ErrorMessage
        timestamp = [DateTimeOffset]::UtcNow.ToString('O')
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText(
        $status,
        $document,
        [Text.UTF8Encoding]::new($false)
    )
}
Write-CleanupStatus -Phase 'Ready' -RootAbsent $false `
    -PayloadRemoved $false -Attempt 0
function Test-CleanupProcessRunning {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTicks
    )
    if ($ProcessId -le 0 -or $StartTicks -le 0) {
        return $false
    }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return $false
    }
    try {
        return $process.StartTime.ToUniversalTime().Ticks -eq $StartTicks
    }
    catch {
        return $false
    }
}
function Test-CleanupReparseAttribute {
    param([IO.FileAttributes]$Attributes)
    return ($Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}
function Test-CleanupPayloadPathAllowed {
    param(
        [Parameter(Mandatory)][string]$ItemPath,
        [Parameter(Mandatory)][string]$Preserve
    )
    $item = [IO.Path]::GetFullPath($ItemPath).TrimEnd('\')
    $kept = [IO.Path]::GetFullPath($Preserve).TrimEnd('\')
    return $item.Equals(
            $kept,
            [StringComparison]::OrdinalIgnoreCase
        ) -or $item.StartsWith(
            $kept + '\',
            [StringComparison]::OrdinalIgnoreCase
        ) -or $kept.StartsWith(
            $item + '\',
            [StringComparison]::OrdinalIgnoreCase
        )
}
function Assert-CleanupTreeSafe {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $items = @(
        Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    ) + @(
        Get-ChildItem -LiteralPath $Path -Force -Recurse `
            -ErrorAction Stop
    )
    foreach ($item in $items) {
        if (Test-CleanupReparseAttribute `
            -Attributes $item.Attributes) {
            throw ('Kaldirma hedefinde yeniden ayrisim noktasi var: {0}' `
                -f $item.FullName)
        }
    }
}
function Remove-CleanupChildrenExcept {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Preserve
    )
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force `
        -ErrorAction Stop)) {
        $childPath = [IO.Path]::GetFullPath($child.FullName).TrimEnd('\')
        $isPreserved = $childPath.Equals(
            $Preserve,
            [StringComparison]::OrdinalIgnoreCase
        )
        $isAncestor = $Preserve.StartsWith(
            $childPath + '\',
            [StringComparison]::OrdinalIgnoreCase
        )
        if ($isPreserved) {
            continue
        }
        if ($isAncestor) {
            if (-not $child.PSIsContainer) {
                throw "Koruma yolu klasor olmayan bir hedeften geciyor: $childPath"
            }
            Remove-CleanupChildrenExcept -Path $childPath `
                -Preserve $Preserve
            continue
        }
        Remove-Item -LiteralPath $childPath -Force `
            -Recurse:$child.PSIsContainer -ErrorAction Stop
    }
}
function Test-CleanupPayloadRemoved {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Preserve,
        [Parameter(Mandatory)][bool]$PreserveWasPresent
    )
    if (-not $PreserveWasPresent) {
        return -not (Test-Path -LiteralPath $Path)
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container) -or
        -not (Test-Path -LiteralPath $Preserve -PathType Container)) {
        return $false
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force `
        -Recurse -ErrorAction Stop)) {
        $itemPath = [IO.Path]::GetFullPath($item.FullName).TrimEnd('\')
        $allowed = Test-CleanupPayloadPathAllowed `
            -ItemPath $itemPath -Preserve $Preserve
        if (-not $allowed) {
            return $false
        }
    }
    return $true
}
$deadline = [DateTimeOffset]::Now.AddSeconds(90)
$parentStillRunning = $false
do {
    $parentStillRunning = Test-CleanupProcessRunning `
        -ProcessId $ParentProcessId -StartTicks $ParentStartTicks
    $ownerStillRunning = Test-CleanupProcessRunning `
        -ProcessId $OwnerProcessId -StartTicks $OwnerStartTicks
    if (-not $parentStillRunning -and -not $ownerStillRunning) {
        break
    }
    Start-Sleep -Milliseconds 250
} while ([DateTimeOffset]::Now -lt $deadline)
$parentStillRunning = Test-CleanupProcessRunning `
    -ProcessId $ParentProcessId -StartTicks $ParentStartTicks
$ownerStillRunning = Test-CleanupProcessRunning `
    -ProcessId $OwnerProcessId -StartTicks $OwnerStartTicks
$completed = $false
$rootAbsent = $false
$preserveWasPresent = $false
$attempt = 0
$lastError = ''
if (-not $parentStillRunning -and -not $ownerStillRunning) {
    Write-CleanupUIStatus -Level STEP `
        -Message $(if ([string]::IsNullOrWhiteSpace($preserve)) {
            '__WINLAMA_CLEANUP_REMOVE_STEP__'
        }
        else {
            '__WINLAMA_CLEANUP_PRESERVE_STEP__'
        })
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            if (-not (Test-Path -LiteralPath $target)) {
                if ($preserveWasPresent) {
                    throw 'Korunacak Winlama Python hedefi beklenmedik sekilde kayboldu.'
                }
                $completed = $true
                $rootAbsent = $true
                break
            }
            Assert-CleanupTreeSafe -Path $target
            if (-not [string]::IsNullOrWhiteSpace($preserve)) {
                if ($preserveWasPresent -and
                    -not (Test-Path -LiteralPath $preserve `
                        -PathType Container)) {
                    throw ('Korunacak Winlama Python hedefi ' +
                        'beklenmedik sekilde kayboldu.')
                }
                if (Test-Path -LiteralPath $preserve) {
                    if (-not (Test-Path -LiteralPath $preserve `
                        -PathType Container)) {
                        throw "Korunacak Winlama Python hedefi klasor degil: $preserve"
                    }
                    $preserveWasPresent = $true
                    Remove-CleanupChildrenExcept -Path $target `
                        -Preserve $preserve
                }
                else {
                    Remove-Item -LiteralPath $target -Recurse -Force `
                        -ErrorAction Stop
                }
            }
            else {
                Remove-Item -LiteralPath $target -Recurse -Force `
                    -ErrorAction Stop
            }
            $completed = Test-CleanupPayloadRemoved -Path $target `
                -Preserve $preserve `
                -PreserveWasPresent $preserveWasPresent
            $rootAbsent = -not (Test-Path -LiteralPath $target)
            if ($completed) {
                break
            }
        }
        catch {
            $lastError = $_.Exception.Message
            if ($lastError -like `
                    'Kaldirma hedefinde yeniden ayrisim noktasi var:*' -or
                $lastError -like `
                    'Korunacak Winlama Python hedefi*') {
                break
            }
        }
        Start-Sleep -Milliseconds 750
    }
}
$phase = if ($completed) { 'Completed' } else { 'Failed' }
$failure = if ($parentStillRunning -or $ownerStillRunning) {
    '__WINLAMA_CLEANUP_PARENT_TIMEOUT__'
}
elseif ($lastError) {
    $lastError
}
else {
    '__WINLAMA_CLEANUP_POSTCONDITION_FAILED__'
}
try {
    Write-CleanupStatus -Phase $phase -RootAbsent $rootAbsent `
        -PayloadRemoved $completed -Attempt $attempt `
        -ErrorMessage $(if ($completed) { '' } else {
            $failure
        })
}
catch {
    $lastError = $_.Exception.Message
}
$resultText = if ($completed -and $preserveWasPresent) {
    '__WINLAMA_CLEANUP_PRESERVED__'
}
elseif ($completed -and
    -not [string]::IsNullOrWhiteSpace($preserve)) {
    '__WINLAMA_CLEANUP_PRESERVE_ABSENT__'
}
elseif ($completed) {
    '__WINLAMA_CLEANUP_SUCCEEDED__'
}
else {
    '__WINLAMA_CLEANUP_FAILED__'
}
Remove-CleanupStatus
Complete-CleanupOperation `
    -Level $(if ($completed) { 'SUCCESS' } else { 'ERROR' }) `
    -Message $resultText `
    -Detail $(if ($completed) { '' } else { $failure })
$self = $PSCommandPath
for ($attempt = 1; $attempt -le 5; $attempt++) {
    Remove-Item -LiteralPath $self -Force
    if (-not (Test-Path -LiteralPath $self)) {
        break
    }
    Start-Sleep -Milliseconds 200
}
if ($completed) {
    exit 0
}
exit 1
'@
    $values = [ordered]@{
        '__WINLAMA_CLOSE_PROMPT__' = Get-UninstallText `
            -Key 'Common.Prompt.Close' `
            -Fallback 'Oturumu kapatmak icin CIKIS yazin.'
        '__WINLAMA_EXACT_COMMAND__' = Get-UninstallText `
            -Key 'Common.Prompt.ExactCommand' `
            -Fallback 'Yalniz tam olarak {0} yazin.' `
            -Arguments @('CIKIS')
        '__WINLAMA_INVALID_COMMAND__' = Get-UninstallText `
            -Key 'Common.Command.Invalid' `
            -Fallback 'Bos veya gecersiz komut kabul edilmedi.'
        '__WINLAMA_OPERATION_SUMMARY__' = Get-UninstallText `
            -Key 'Common.Operation.Summary' `
            -Fallback 'ISLEM OZETI'
        '__WINLAMA_CLEANUP_WINDOW_TITLE__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.WindowTitle' `
            -Fallback 'Winlama - Kok Temizligi'
        '__WINLAMA_CLEANUP_PREFLIGHT_INVALID__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.Error.PreflightInvalid' `
            -Fallback 'Kok temizligi guvenlik on denetimi basarisiz.'
        '__WINLAMA_CLEANUP_TITLE__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.Title' `
            -Fallback 'WINLAMA KOK TEMIZLIGI'
        '__WINLAMA_CLEANUP_WAIT__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.Waiting' `
            -Fallback 'Launcher ve kaldirma surecleri bekleniyor.'
        '__WINLAMA_CLEANUP_REMOVE_STEP__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.RemovingRoot' `
            -Fallback 'Winlama kurulum koku kaldiriliyor.'
        '__WINLAMA_CLEANUP_PRESERVE_STEP__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.RemovingExceptPython' `
            -Fallback ('Winlama Python 3.11 korunarak diger Winlama ' +
                'payloadi kaldiriliyor.')
        '__WINLAMA_CLEANUP_PARENT_TIMEOUT__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.Error.ParentTimeout' `
            -Fallback 'Guvenlik suresi sonunda bir ust surec calisiyordu.'
        '__WINLAMA_CLEANUP_POSTCONDITION_FAILED__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.Error.PostconditionFailed' `
            -Fallback 'Kok kaldirma son kosulu saglanamadi.'
        '__WINLAMA_CLEANUP_SUCCEEDED__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.Completed' `
            -Fallback 'Winlama kurulum koku kaldirildi.'
        '__WINLAMA_CLEANUP_PRESERVED__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.CompletedExceptPython' `
            -Fallback ('Winlama Python 3.11 korundu; diger Winlama ' +
                'payloadi kaldirildi.')
        '__WINLAMA_CLEANUP_PRESERVE_ABSENT__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.CompletedPythonAlreadyAbsent' `
            -Fallback ('Winlama Python 3.11 zaten yoktu; kalan Winlama ' +
                'kurulum koku kaldirildi.')
        '__WINLAMA_CLEANUP_FAILED__' = Get-UninstallText `
            -Key 'Uninstall.Cleanup.Failed' `
            -Fallback 'Winlama kurulum koku kaldirilamadi.'
    }
    foreach ($token in $values.Keys) {
        $escaped = ([string]$values[$token]).Replace("'", "''")
        $template = $template.Replace($token, $escaped)
    }
    return $template
}
function Test-WinlamaRootCleanupHandshake {
    param(
        [AllowNull()][object]$Candidate,
        [Parameter(Mandatory)][string]$CleanupId,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$RootPath,
        [AllowEmptyString()][string]$PreservePath = ''
    )
    try {
        $candidatePreserve = [string](Get-UninstallPropertyValue `
            -InputObject $Candidate -Name 'preservedPath')
        $expectedPreserve = if ([string]::IsNullOrWhiteSpace(
            $PreservePath
        )) {
            ''
        }
        else {
            [IO.Path]::GetFullPath($PreservePath).TrimEnd('\')
        }
        $normalizedCandidatePreserve = if (
            [string]::IsNullOrWhiteSpace($candidatePreserve)
        ) {
            ''
        }
        else {
            [IO.Path]::GetFullPath($candidatePreserve).TrimEnd('\')
        }
        return [int](Get-UninstallPropertyValue `
                -InputObject $Candidate -Name 'schemaVersion') -eq 1 -and
            [string](Get-UninstallPropertyValue `
                -InputObject $Candidate -Name 'cleanupId') -ceq `
                $CleanupId -and
            [string](Get-UninstallPropertyValue `
                -InputObject $Candidate -Name 'phase') -ceq 'Ready' -and
            [int](Get-UninstallPropertyValue `
                -InputObject $Candidate -Name 'processId') -eq `
                $ProcessId -and
            [string](Get-UninstallPropertyValue `
                -InputObject $Candidate -Name 'rootPath') -ieq `
                $RootPath -and
            $normalizedCandidatePreserve -ieq $expectedPreserve -and
            -not [bool](Get-UninstallPropertyValue `
                -InputObject $Candidate -Name 'rootAbsent') -and
            -not [bool](Get-UninstallPropertyValue `
                -InputObject $Candidate -Name 'payloadRemoved')
    }
    catch {
        return $false
    }
}
function Start-WinlamaRootCleanup {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [AllowEmptyString()][string]$PreservePath = ''
    )
    if ($ValidateOnly) {
        throw 'ValidateOnly sirasinda kok temizligi cagrildi.'
    }
    $expectedRoot = Get-UninstallExpectedWinlamaRoot
    $configuredRoot = [string](Get-UninstallPropertyValue `
        -InputObject $Config.Paths -Name 'Root')
    $root = Resolve-SafeUninstallPath -Path $configuredRoot `
        -AllowedRoots @($expectedRoot) -AllowRoot -Recurse
    if (-not $root.Equals(
        $expectedRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Winlama koku kesin hedef degil: $root"
    }
    $preserve = if ([string]::IsNullOrWhiteSpace($PreservePath)) {
        ''
    }
    else {
        Assert-UninstallExactPath -Actual $PreservePath `
            -Expected (Get-UninstallExpectedPythonRoot) `
            -Label 'Korunacak Winlama Python koku'
    }
    $cleanupId = [guid]::NewGuid().ToString('N')
    $cleanupPath = Join-Path ([IO.Path]::GetTempPath()) `
        "winlama-cleanup-$cleanupId.ps1"
    $statusPath = Join-Path ([IO.Path]::GetTempPath()) `
        "winlama-cleanup-$cleanupId.status.json"
    [IO.File]::WriteAllText(
        $cleanupPath,
        (New-WinlamaRootCleanupScript),
        [Text.UTF8Encoding]::new($false)
    )
    $windowsPowerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        Remove-Item -LiteralPath $cleanupPath -Force `
            -ErrorAction SilentlyContinue
        throw "Windows PowerShell temizlik ortami bulunamadi: $windowsPowerShell"
    }
    $parent = Get-Process -Id $PID -ErrorAction Stop
    $owner = Get-UninstallParentProcessIdentity
    $ownerId = if ($null -eq $owner) { 0 } else { $owner.ProcessId }
    $ownerTicks = if ($null -eq $owner) { 0 } else { $owner.StartTicks }
    $arguments = @(
        '-NoLogo', '-NoProfile',
        '-ExecutionPolicy', 'Bypass', '-File',
        ('"{0}"' -f $cleanupPath),
        '-RootPath', ('"{0}"' -f $root),
        '-PreservePath', ('"{0}"' -f $preserve),
        '-ParentProcessId', $PID,
        '-ParentStartTicks', $parent.StartTime.ToUniversalTime().Ticks,
        '-OwnerProcessId', $ownerId,
        '-OwnerStartTicks', $ownerTicks,
        '-CleanupId', $cleanupId,
        '-StatusPath', ('"{0}"' -f $statusPath)
    )
    $process = $null
    try {
        $process = Start-Process -FilePath $windowsPowerShell `
            -ArgumentList $arguments `
            -WorkingDirectory ([IO.Path]::GetTempPath()) `
            -NoNewWindow -PassThru -ErrorAction Stop
        if ($null -eq $process) {
            throw 'Harici temizlik sureci olusturulamadi.'
        }
        $handshake = $null
        $deadline = [DateTimeOffset]::Now.AddSeconds(5)
        do {
            if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                try {
                    $candidate = Get-Content -LiteralPath $statusPath `
                        -Raw -Encoding UTF8 |
                        ConvertFrom-UninstallJson
                    if (Test-WinlamaRootCleanupHandshake `
                        -Candidate $candidate -CleanupId $cleanupId `
                        -ProcessId $process.Id -RootPath $root `
                        -PreservePath $preserve) {
                        $handshake = $candidate
                        break
                    }
                }
                catch {
                    Write-Verbose ('Temizlik el sikisma kaydi bekleniyor: {0}' `
                        -f $_.Exception.Message)
                }
            }
            if ($process.HasExited) {
                throw "Harici temizlik sureci erken kapandi: $($process.ExitCode)"
            }
            Start-Sleep -Milliseconds 100
        } while ([DateTimeOffset]::Now -lt $deadline)
        if ($null -eq $handshake) {
            throw 'Harici temizlik el sikismasi dogrulanamadi.'
        }
        $process.Dispose()
        $process = $null
    }
    catch {
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    $process.WaitForExit(5000)
                }
            }
            catch {
                Write-Verbose ('Basarisiz temizlik sureci durdurulamadi: {0}' `
                    -f $_.Exception.Message)
            }
            $process.Dispose()
        }
        Remove-Item -LiteralPath $cleanupPath -Force `
            -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $statusPath -Force `
            -ErrorAction SilentlyContinue
        throw
    }
    if (-not (Test-Path -LiteralPath $cleanupPath -PathType Leaf)) {
        throw 'Harici temizlik betigi baslatma dogrulamasindan once kayboldu.'
    }
    Write-UninstallLog -Event 'ROOT_CLEANUP_LAUNCHED' `
        -Level SUCCESS -Action 'Winlama kok temizligi' `
        -Message ("Temizlik kimligi: {0} | Sonuc: {1} | Korunan: {2}" -f `
            $cleanupId, $statusPath, $(if ($preserve) {
                $preserve
            }
            else {
                'yok'
            }))
    return $true
}
function Test-UninstallExactYes {
    param([AllowNull()][string]$Value)
    return $null -ne $Value -and $Value -ceq 'EVET'
}
function Test-UninstallPauseRequired {
    param(
        [bool]$ValidationMode = $ValidateOnly.IsPresent,
        [bool]$AutomationMode = $NoPause.IsPresent
    )
    return -not $ValidationMode -and -not $AutomationMode
}
function Read-UninstallExactConfirmation {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [scriptblock]$InputReader
    )
    while ($true) {
        $value = Read-UninstallInput -Prompt $Prompt `
            -Hint (Get-UninstallText `
                -Key 'Common.Prompt.ExactYesNo' `
                -Fallback ('Yalniz tam olarak EVET veya HAYIR ' +
                    'yazin.')) `
            -Label (Get-UninstallText `
                -Key 'Uninstall.Prompt.ConfirmationLabel' `
                -Fallback 'Onay') -InputReader $InputReader
        if (Test-UninstallExactYes -Value $value) {
            return $true
        }
        if ($value -cne 'HAYIR') {
            Write-UninstallBootstrapStatus -Level WARN `
                -Message (Get-UninstallText `
                    -Key 'Common.Confirmation.Invalid' `
                    -Fallback ('Bos veya gecersiz onay ' +
                        'kabul edilmedi.'))
            continue
        }
        return $false
    }
}
function Resolve-UninstallIndexSelection {
    param(
        [AllowNull()][string]$Value,
        [int]$Count = 7
    )
    $text = [string]$Value
    $text = $text.Trim()
    if ($text -iin @('0', 'S', 'SKIP', 'IPTAL')) {
        return [pscustomobject]@{
            Cancelled = $true
            Selection = @()
        }
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'Bos bilesen secimi kabul edilmez.'
    }
    if ($text -iin @('A', 'ALL', 'HEPSI')) {
        return [pscustomobject]@{
            Cancelled = $false
            Selection = @(1..$Count)
        }
    }
    $keepMode = $text.StartsWith('-')
    if ($keepMode) {
        $text = $text.Substring(1).Trim()
    }
    $tokens = @($text -split ',' | ForEach-Object { $_.Trim() })
    if ($tokens.Count -eq 0 -or
        @($tokens | Where-Object {
            $_ -notmatch '^\d+$'
        }).Count -gt 0) {
        throw 'Gecersiz bilesen secimi.'
    }
    $numbers = @($tokens | ForEach-Object {
        [int]$_
    } | Sort-Object -Unique)
    if (@($numbers | Where-Object {
        $_ -lt 1 -or $_ -gt $Count
    }).Count -gt 0) {
        throw 'Bilesen secimi gecerli araligin disinda.'
    }
    $selection = if ($keepMode) {
        @(1..$Count | Where-Object { $_ -notin $numbers })
    }
    else {
        $numbers
    }
    return [pscustomobject]@{
        Cancelled = $false
        Selection = @($selection)
    }
}
. (Join-Path $PSScriptRoot 'Modules\Uninstall\Menu.ps1')
function Get-FullUninstallActions {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$Selection
    )
    $actions = [Collections.Generic.List[object]]::new()
    if (1 -in $Selection) {
        $actions.Add([pscustomobject]@{
            Name = Get-UninstallText `
                -Key 'Uninstall.ActionName.ComfyUI' `
                -Fallback 'ComfyUI temizligi'
            Action = { Remove-ComfyUI -Config $Config }.GetNewClosure()
        })
    }
    if (2 -in $Selection) {
        $actions.Add([pscustomobject]@{
            Name = Get-UninstallText `
                -Key 'Uninstall.ActionName.WebUIData' `
                -Fallback 'Open WebUI veri temizligi'
            Action = { Remove-OpenWebUIData -Config $Config }.GetNewClosure()
        })
    }
    if (3 -in $Selection) {
        $actions.Add([pscustomobject]@{
            Name = Get-UninstallText `
                -Key 'Uninstall.ActionName.OllamaApplication' `
                -Fallback 'Ollama uygulama temizligi'
            Action = {
                Remove-OllamaApplication -Config $Config
            }.GetNewClosure()
        })
    }
    if (4 -in $Selection) {
        $actions.Add([pscustomobject]@{
            Name = Get-UninstallText `
                -Key 'Uninstall.ActionName.OllamaModels' `
                -Fallback 'Ollama model temizligi'
            Action = { Remove-OllamaModels -Config $Config }.GetNewClosure()
        })
    }
    if (5 -in $Selection) {
        $actions.Add([pscustomobject]@{
            Name = Get-UninstallText `
                -Key 'Uninstall.ActionName.PythonLibraries' `
                -Fallback 'Python kutuphane temizligi'
            Action = {
                Remove-PythonLibraries -Config $Config
            }.GetNewClosure()
        })
    }
    if (6 -in $Selection) {
        $actions.Add([pscustomobject]@{
            Name = Get-UninstallText `
                -Key 'Uninstall.ActionName.PythonApplication' `
                -Fallback 'Winlama Python 3.11 temizligi'
            Action = {
                Remove-PythonApplication -Config $Config
            }.GetNewClosure()
        })
    }
    if (7 -in $Selection) {
        $actions.Add([pscustomobject]@{
            Name = Get-UninstallText `
                -Key 'Uninstall.ActionName.DeveloperCli' `
                -Fallback 'Gelistirici CLI temizligi'
            Action = { Remove-DeveloperCliApplications }
        })
    }
    $actions.Add([pscustomobject]@{
        Name = Get-UninstallText `
            -Key 'Uninstall.ActionName.WinlamaSettings' `
            -Fallback 'Winlama ayar temizligi'
        Action = { Remove-WinlamaSettings -Config $Config }.GetNewClosure()
    })
    return $actions.ToArray()
}
function Get-FullUninstallCleanupPlan {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()][int[]]$Selection
    )
    $preservePython = 6 -notin $Selection
    return [pscustomobject]@{
        PreservePython = $preservePython
        PreservePath = if ($preservePython) {
            Get-UninstallExpectedPythonRoot
        }
        else {
            ''
        }
    }
}
function Invoke-FullUninstall {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $selectionResult = Read-FullUninstallSelection
    if ($selectionResult.Cancelled) {
        Write-UninstallBootstrapStatus -Level SKIP `
            -Message (Get-UninstallText `
                -Key 'Uninstall.Cancelled' `
                -Fallback 'Islem iptal edildi.')
        return 'Cancelled'
    }
    $effectiveSelection = @($selectionResult.Selection)
    $cleanupPlan = Get-FullUninstallCleanupPlan `
        -Selection $effectiveSelection
    $preservePython = $cleanupPlan.PreservePython
    $labels = @(
        (Get-UninstallText -Key 'Uninstall.SelectionName.ComfyUI' `
            -Fallback 'ComfyUI'),
        (Get-UninstallText -Key 'Uninstall.SelectionName.WebUI' `
            -Fallback 'Open WebUI'),
        (Get-UninstallText `
            -Key 'Uninstall.SelectionName.OllamaApplication' `
            -Fallback 'Ollama uygulamasi'),
        (Get-UninstallText -Key 'Uninstall.SelectionName.OllamaModels' `
            -Fallback 'Ollama modelleri'),
        (Get-UninstallText `
            -Key 'Uninstall.SelectionName.PythonLibraries' `
            -Fallback 'Python kutuphaneleri'),
        (Get-UninstallText `
            -Key 'Uninstall.SelectionName.PythonApplication' `
            -Fallback 'Winlama Python 3.11'),
        (Get-UninstallText `
            -Key 'Uninstall.SelectionName.DeveloperCli' `
            -Fallback 'Codex ve GitHub Copilot CLI')
    )
    $deleteState = Get-UninstallText `
        -Key 'Uninstall.SelectionState.Delete' -Fallback 'SIL'
    $keepState = Get-UninstallText `
        -Key 'Uninstall.SelectionState.Keep' -Fallback 'KORU'
    Write-UninstallBootstrapRule
    for ($index = 1; $index -le 7; $index++) {
        $state = if ($index -in $effectiveSelection) {
            $deleteState
        }
        else {
            $keepState
        }
        $color = if ($index -in $effectiveSelection) {
            'Red'
        }
        else {
            'Green'
        }
        Write-UninstallBootstrapLine `
            -Text ('{0}: {1}' -f $labels[$index - 1], $state) `
            -Color $color
    }
    if ($preservePython) {
        Write-UninstallBootstrapLine `
            -Text (Get-UninstallText `
                -Key 'Uninstall.FullSelection.PythonRootKeep' `
                -Fallback 'Winlama Python 3.11 kesin koku: KORU') `
            -Color Green
        Write-UninstallBootstrapLine `
            -Text (Get-UninstallText `
                -Key 'Uninstall.FullSelection.OtherPayloadDelete' `
                -Fallback 'Python koku disindaki Winlama payloadi: SIL') `
            -Color Red
    }
    else {
        Write-UninstallBootstrapLine `
            -Text (Get-UninstallText `
                -Key 'Uninstall.FullSelection.WinlamaRootDelete' `
                -Fallback 'Winlama ayarlari ve kurulum koku: SIL') `
            -Color Red
    }
    Write-UninstallBootstrapRule
    if (-not (Read-UninstallExactConfirmation -Prompt `
        (Get-UninstallConfirmationText `
            -Key 'Uninstall.Prompt.Full' `
            -Fallback ('Winlama bilesenlerinin tamamen ve kalici ' +
                'kaldirilmasini onaylayin.')))) {
        Write-UninstallBootstrapStatus -Level SKIP `
            -Message (Get-UninstallText `
                -Key 'Uninstall.Cancelled' `
                -Fallback 'Islem iptal edildi.')
        return 'Cancelled'
    }
    $actions = Get-FullUninstallActions -Config $Config `
        -Selection $effectiveSelection
    $result = Invoke-UninstallAggregateActions -Actions $actions
    if (-not $result.Succeeded) {
        Write-UninstallBootstrapStatus -Level ERROR -Message (
            Get-UninstallText -Key 'Uninstall.Full.PartialFailure' `
                -Fallback ('Tam kaldirma bazi hatalarla ' +
                    'tamamlandi: {0}') `
                -Arguments @((@($result.Failures.Name) -join ', '))
        )
        return 'Failed'
    }
    if (-not (Start-WinlamaRootCleanup -Config $Config `
        -PreservePath $cleanupPlan.PreservePath)) {
        return 'Failed'
    }
    Write-UninstallBootstrapStatus -Level SUCCESS `
        -Message $(if ($preservePython) {
            Get-UninstallText `
                -Key 'Uninstall.Full.CompletedExceptPython' `
                -Fallback ('Winlama Python 3.11 korunarak diger Winlama ' +
                    'payloadinin temizligi baslatildi.')
        }
        else {
            Get-UninstallText `
                -Key 'Uninstall.Full.Completed' `
                -Fallback ('Secilen ve Winlama''ya ait bilesenlerin kok ' +
                    'temizligi baslatildi.')
        })
    return 'RootCleanupScheduled'
}
function Invoke-ModelManager {
    $path = Join-Path $PSScriptRoot 'ModelManager.ps1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'ModelManager.ps1 bulunamadi.'
    }
    & (Get-Process -Id $PID).Path -NoLogo -NoProfile `
        -ExecutionPolicy Bypass -File $path -NoPause
    if ($LASTEXITCODE -ne 0) {
        throw "ModelManager.ps1 $LASTEXITCODE cikis koduyla kapandi."
    }
}
function Invoke-ConfirmedUninstallAction {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if (-not (Read-UninstallExactConfirmation -Prompt $Prompt)) {
        Write-UninstallBootstrapStatus -Level SKIP `
            -Message (Get-UninstallText `
                -Key 'Uninstall.Action.Cancelled' `
                -Fallback '{0} iptal edildi.' -Arguments @($Name))
        return 'Cancelled'
    }
    $result = Invoke-UninstallAggregateActions -Actions @(
        [pscustomobject]@{ Name = $Name; Action = $Action }
    )
    if (-not $result.Succeeded) {
        return 'Failed'
    }
    return 'Completed'
}
function Complete-UninstallMenuAction {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Cancelled', 'Completed')]
        [string]$Status
    )
    if (-not (Test-UninstallPauseRequired)) {
        return
    }
    Complete-WinlamaUIOperation `
        -Summary $(if ($Status -ceq 'Cancelled') {
            Get-UninstallText `
                -Key 'Uninstall.Operation.ActionCancelled' `
                -Fallback 'Secilen kaldirma islemi iptal edildi.'
        }
        else {
            Get-UninstallText `
                -Key 'Uninstall.Operation.ActionCompleted' `
                -Fallback 'Secilen kaldirma islemi tamamlandi.'
        }) `
        -Level $(if ($Status -ceq 'Cancelled') {
            'SKIP'
        }
        else {
            'SUCCESS'
        }) -Command DEVAM
}
function Invoke-UninstallMenu {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    :uninstallMenu while ($true) {
        try {
            Clear-Host
        }
        catch {
            Write-Verbose ('Konsol temizleme atlandi: {0}' -f `
                $_.Exception.Message)
        }
        Show-UninstallMenu
        $choice = (Read-UninstallInput `
            -Prompt (Get-UninstallText `
                -Key 'Uninstall.Prompt.Action' `
                -Fallback 'Bir kaldirma islemi secin.') `
            -Hint (Get-UninstallText `
                -Key 'Uninstall.Prompt.BlankSafe' `
                -Fallback 'Bos giris hicbir seyi silmez.') `
            -Label (Get-UninstallText `
                -Key 'Common.Prompt.Selection' `
                -Fallback ('Se{0}iminiz' -f [char]0x00E7))).Trim()
        switch ($choice) {
            '0' { return 'Cancelled' }
            '1' { return Invoke-FullUninstall -Config $Config }
            '2' {
                $status = Invoke-ConfirmedUninstallAction `
                    -Prompt (Get-UninstallConfirmationText `
                        -Key 'Uninstall.Prompt.RemoveComfyUI' `
                        -Fallback ('ComfyUI ve tum ComfyUI modelleri ' +
                            'silinsin mi?')) `
                    -Name (Get-UninstallText `
                        -Key 'Uninstall.ActionName.ComfyUI' `
                        -Fallback 'ComfyUI temizligi') `
                    -Action { Remove-ComfyUI -Config $Config }
            }
            '3' {
                $status = Invoke-ConfirmedUninstallAction `
                    -Prompt (Get-UninstallConfirmationText `
                        -Key 'Uninstall.Prompt.RemoveWebUIData' `
                        -Fallback 'Open WebUI kullanici verileri silinsin mi?') `
                    -Name (Get-UninstallText `
                        -Key 'Uninstall.ActionName.WebUIData' `
                        -Fallback 'Open WebUI veri temizligi') `
                    -Action { Remove-OpenWebUIData -Config $Config }
            }
            '4' {
                $status = Invoke-ConfirmedUninstallAction `
                    -Prompt (Get-UninstallConfirmationText `
                        -Key 'Uninstall.Prompt.RemoveOllama' `
                        -Fallback 'Ollama uygulamasi kaldirilsin mi?') `
                    -Name (Get-UninstallText `
                        -Key 'Uninstall.ActionName.OllamaApplication' `
                        -Fallback 'Ollama uygulama temizligi') `
                    -Action { Remove-OllamaApplication -Config $Config }
            }
            '5' {
                $status = Invoke-ConfirmedUninstallAction `
                    -Prompt (Get-UninstallConfirmationText `
                        -Key 'Uninstall.Prompt.RemoveDeveloperCli' `
                        -Fallback ('Codex CLI ve GitHub Copilot CLI ' +
                            'kaldirilsin mi?')) `
                    -Name (Get-UninstallText `
                        -Key 'Uninstall.ActionName.DeveloperCli' `
                        -Fallback 'Gelistirici CLI temizligi') `
                    -Action { Remove-DeveloperCliApplications }
            }
            '6' {
                try {
                    Invoke-ModelManager
                    $status = 'Completed'
                }
                catch {
                    Write-UninstallLog -Event 'ACTION_FAILED' `
                        -Level ERROR -Action 'Model yoneticisi' `
                        -Message $_.Exception.Message -ErrorRecord $_
                    Write-UninstallBootstrapError `
                        -Context (Get-UninstallText `
                            -Key 'Uninstall.Error.ModelManagerMissing' `
                            -Fallback 'Model yoneticisi acilamadi.') `
                        -ErrorRecord $_
                    return 'Failed'
                }
            }
            default {
                Write-UninstallBootstrapStatus -Level WARN `
                    -Message (Get-UninstallText `
                        -Key 'Common.Selection.Invalid' `
                        -Fallback ('Gecersiz secim. Hicbir sey ' +
                            'silinmedi.'))
                continue uninstallMenu
            }
        }
        if ($status -eq 'Failed') {
            return 'Failed'
        }
        Complete-UninstallMenuAction -Status $status
    }
}
function Get-UninstallExitCode {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Cancelled', 'Completed', 'Failed',
            'RootCleanupScheduled')]
        [string]$Status
    )
    switch ($Status) {
        'Failed' { return 1 }
        'Cancelled' { return 2 }
        'RootCleanupScheduled' { return 10 }
        default { return 0 }
    }
}
function Assert-UninstallValidationContracts {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $null = Assert-WinlamaUIStandard
    $null = Assert-UninstallBootstrapInputContracts
    $null = Assert-WinlamaUIInputFormatter -Formatter {
        param([string]$Value)
        Format-UninstallBootstrapInputLine -Value $Value
    }
    if (-not $script:UninstallLocalizationReady) {
        throw 'Yerellestirme dogrulama sirasinda baslatilamadi.'
    }
    $fallbackFixture = Get-UninstallText `
        -Key 'Uninstall.Validation.MissingKey' `
        -Fallback 'Guvenli yedek metin'
    $formattedFallbackFixture = Get-UninstallText `
        -Key 'Uninstall.Validation.MissingFormattedKey' `
        -Fallback 'Guvenli yedek: {0}' -Arguments @('TAMAM')
    if ($fallbackFixture -cne 'Guvenli yedek metin' -or
        $fallbackFixture -match 'Uninstall\.Validation' -or
        $formattedFallbackFixture -cne 'Guvenli yedek: TAMAM') {
        throw 'Ham yerellestirme anahtari yedek fiksturu basarisiz.'
    }
    if ((Get-WinlamaConsoleWidth) -ne 100) {
        throw 'Konsol UI genisligi 100 degil.'
    }
    $menu = @(Get-UninstallMenuItems)
    if (($menu.Choice -join ',') -cne '1,2,3,4,5,6,0') {
        throw 'Kaldirma menu sirasi gecersiz.'
    }
    if (($menu.Color -join ',') -cne `
        'Red,Magenta,Cyan,Yellow,Magenta,Green,Gray') {
        throw 'Kaldirma menu renk sirasi gecersiz.'
    }
    foreach ($item in $menu) {
        foreach ($character in $item.Text.ToCharArray()) {
            if ([int]$character -gt 127) {
                throw 'Kaldirma menusu yalniz ASCII degil.'
            }
        }
        foreach ($line in @(Format-WinlamaUILine -Text $item.Text)) {
            if ($line.Length -ne 100) {
                throw 'Kaldirma menu geometrisi gecersiz.'
            }
        }
    }
    if (@($menu | Where-Object {
        $_.Text -match '(?i)\b(remove|return|manager)\b'
    }).Count -gt 0) {
        throw 'Kaldirma menusu Turkce ASCII degil.'
    }
    $selectionItems = @(Get-FullUninstallSelectionItems)
    if (($selectionItems.Index -join ',') -cne '1,2,3,4,5,6,7' -or
        ($selectionItems.Color -join ',') -cne `
            'Magenta,Cyan,Yellow,Green,Cyan,Red,Magenta') {
        throw 'Tam kaldirma secim renk veya sira sozlesmesi gecersiz.'
    }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw `
        -Encoding UTF8
    $sourceTokens = $null
    $sourceErrors = $null
    $sourceAst = [Management.Automation.Language.Parser]::ParseFile(
        $PSCommandPath,
        [ref]$sourceTokens,
        [ref]$sourceErrors
    )
    if (@($sourceErrors).Count -gt 0) {
        throw @($sourceErrors)[0]
    }
    $getSourceFunction = {
        param([string]$Name)
        $functionAst = $sourceAst.Find({
            param($node)
            $node -is `
                [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $Name
        }.GetNewClosure(), $true)
        if ($null -eq $functionAst) {
            throw "Dogrulama fonksiyonu bulunamadi: $Name"
        }
        return $functionAst.Extent.Text
    }.GetNewClosure()
    $resolverSource = & $getSourceFunction 'Resolve-UninstallConfigPath'
    $logSource = & $getSourceFunction 'Write-UninstallLog'
    if ($resolverSource -notmatch `
            "Data\\Configs\\config\.json" -or
        ([regex]::Matches(
            $resolverSource,
            'Join-Path\s+\$PSScriptRoot'
        )).Count -ne 1 -or
        $logSource -match `
            'Join-Path\s+\$PSScriptRoot\s+''Logs''' -or
        $logSource -notmatch '(?s)if \(\$ValidateOnly\).*?return.*?' +
            '\[IO\.Directory\]::CreateDirectory') {
        throw 'Canonical config veya tanilama koku sozlesmesi gecersiz.'
    }
    $configuredDiagnostic = Resolve-UninstallDiagnosticRoot -Config $Config
    $fallbackDiagnostic = Resolve-UninstallDiagnosticRoot -Config $null
    $expectedFallback = [IO.Path]::GetFullPath(
        (Join-Path ([IO.Path]::GetTempPath()) 'Winlama-Logs')
    ).TrimEnd('\')
    if (-not $configuredDiagnostic.Equals(
            $expectedFallback,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not $fallbackDiagnostic.Equals(
            $expectedFallback,
            [StringComparison]::OrdinalIgnoreCase
        ) -or (Test-UninstallPathWithin `
            -Path $configuredDiagnostic `
            -Root (Get-UninstallExpectedWinlamaRoot) -AllowRoot) -or
        (Test-UninstallPathWithin -Path $configuredDiagnostic `
            -Root $PSScriptRoot -AllowRoot)) {
        throw 'Tanilama koku cozumleme fiksturu basarisiz.'
    }
    $logPathBeforeValidation = $script:UninstallLogPath
    Write-UninstallLog -Event 'VALIDATION_DIAGNOSTIC_PURITY' `
        -Message 'ValidateOnly tanilama safligi.'
    if ($script:UninstallLogPath -ne $logPathBeforeValidation) {
        throw 'ValidateOnly tanilama dosyasi olusturma girisiminde bulundu.'
    }
    $savedExplicitConfig = $script:UninstallConfigPathExplicit
    $savedConfigPath = $ConfigPath
    $explicitMissingRejected = $false
    try {
        $script:UninstallConfigPathExplicit = $true
        $ConfigPath = Join-Path ([IO.Path]::GetTempPath()) `
            ('winlama-missing-{0}.json' -f [guid]::NewGuid().ToString('N'))
        try {
            $null = Resolve-UninstallConfigPath -PackageOnly
        }
        catch {
            $explicitMissingRejected = $true
        }
    }
    finally {
        $script:UninstallConfigPathExplicit = $savedExplicitConfig
        $ConfigPath = $savedConfigPath
    }
    if (-not $explicitMissingRejected) {
        throw 'Eksik acik ConfigPath fallback ile kabul edildi.'
    }
    $forbiddenUiCommands = @(
        ('Write' + '-Host'),
        ('Read' + '-Host'),
        ('Write' + '-Warning')
    )
    $rawUiCalls = @($sourceAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -in $forbiddenUiCommands
    }, $true))
    if ($rawUiCalls.Count -gt 0) {
        throw 'Uninstall.ps1 ham UI komutu iceriyor.'
    }
    foreach ($character in $source.ToCharArray()) {
        if ([int]$character -gt 127) {
            throw 'Uninstall.ps1 ASCII disi metin iceriyor.'
        }
    }
    $installed = 'C:\Fixture\Installed\config.json'
    $package = 'C:\Fixture\Package\config.json'
    $selected = Select-UninstallExistingPath `
        -Candidates @($installed, $package) -PathExists {
            param($Path)
            return $Path -in @(
                'C:\Fixture\Installed\config.json',
                'C:\Fixture\Package\config.json'
            )
        }
    if ($selected -ine $installed) {
        throw 'Kurulu yapilandirma onceligi dogrulamasi basarisiz.'
    }
    $rejectedConfigs = [Collections.Generic.List[string]]::new()
    $fallbackSelected = Select-UninstallValidConfigPath `
        -Candidates @($installed, $package) `
        -PathExists {
            param($Path)
            return $Path -in @(
                'C:\Fixture\Installed\config.json',
                'C:\Fixture\Package\config.json'
            )
        } -ConfigurationReader {
            param($Path)
            if ($Path -ieq 'C:\Fixture\Installed\config.json') {
                throw 'beklenen bozuk kurulu yapilandirma'
            }
            return [pscustomobject]@{ Valid = $true }
        } -RejectionHandler {
            param($Path, $ErrorRecord)
            $rejectedConfigs.Add($Path)
        }
    if ($fallbackSelected -ine $package -or
        $rejectedConfigs.Count -ne 1 -or
        $rejectedConfigs[0] -ine $installed) {
        throw 'Bozuk kurulu yapilandirma yedegi fiksturu basarisiz.'
    }
    $validNestedConfig = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-Json
    $invalidNestedConfig = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-Json
    $invalidNestedConfig.Ollama.PSObject.Properties.Remove('Port')
    $nestedRejections = [Collections.Generic.List[string]]::new()
    $nestedReader = {
        param($Path)
        $candidate = if ($Path -ieq $installed) {
            $invalidNestedConfig
        }
        else {
            $validNestedConfig
        }
        Assert-UninstallConfigurationContract -Config $candidate
        return $candidate
    }.GetNewClosure()
    $nestedFallback = Select-UninstallValidConfigPath `
        -Candidates @($installed, $package) `
        -PathExists { param($Path) $true } `
        -ConfigurationReader $nestedReader `
        -RejectionHandler {
            param($Path, $ErrorRecord)
            $nestedRejections.Add($Path)
        }
    if ($nestedFallback -ine $package -or
        $nestedRejections.Count -ne 1 -or
        $nestedRejections[0] -ine $installed) {
        throw 'Eksik nested kurulu yapilandirma yedegi basarisiz.'
    }
    $missingDisplayName = [pscustomobject]@{
        UninstallString = 'C:\Fixture\remove.exe /quiet'
    }
    if (-not [string]::IsNullOrEmpty(
        (Get-UninstallDisplayName -Entry $missingDisplayName)
    ) -or @(Get-OllamaRegistryEntries `
        -Entries @($missingDisplayName)).Count -ne 0) {
        throw 'Eksik DisplayName kayit fiksturu basarisiz.'
    }
    $dependency = Get-UninstallDependency -Config $Config -Name 'Python'
    if ($null -eq $dependency) {
        throw 'Python bagimliligi yapilandirmada eksik.'
    }
    $ownership = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Components = [pscustomobject][ordered]@{
            Python = [pscustomobject][ordered]@{
                OwnedByWinlama = $true
                PackageId = 'Python.Python.3.11'
                Version = [string]$dependency.WingetVersion
                InstallScope = 'User'
                InstallRoot = Join-Path $env:LOCALAPPDATA `
                    'Programs\Winlama\Dependencies\Python311'
                ExecutablePath = Join-Path $env:LOCALAPPDATA `
                    ('Programs\Winlama\Dependencies\Python311\' +
                        'python.exe')
                InstalledAt = '2026-08-21T00:00:00Z'
                Source = 'LocalArtifact'
            }
        }
    }
    if (-not (Test-PythonOwnershipDocument `
        -Document $ownership -Dependency $dependency)) {
        throw 'Kesin Python sahiplik fiksturu basarisiz.'
    }
    $pythonRecord = [pscustomobject]@{
        DisplayName = 'Python 3.11.9 (64-bit)'
        DisplayVersion = '3.11.9'
        Publisher = 'Python Software Foundation'
        PSPath = ('Registry::HKEY_CURRENT_USER\Software\Microsoft\' +
            'Windows\CurrentVersion\Uninstall\Python311')
        InstallLocation = Split-Path -Parent `
            $ownership.Components.Python.ExecutablePath
        QuietUninstallString = ('"{0}" /quiet' -f `
            (Join-Path $ownership.Components.Python.InstallRoot `
                'uninstall.exe'))
    }
    if (@(Get-PythonRegistryEntries `
        -Ownership $ownership.Components.Python `
        -Entries @($pythonRecord)).Count -ne 1) {
        throw 'Kesin Python kayit eslesme fiksturu basarisiz.'
    }
    $machinePythonRecord = $pythonRecord | Select-Object *
    $machinePythonRecord.PSPath = ('Registry::HKEY_LOCAL_MACHINE\' +
        'Software\Microsoft\Windows\CurrentVersion\Uninstall\Python311')
    if (@(Get-PythonRegistryEntries `
        -Ownership $ownership.Components.Python `
        -Entries @($machinePythonRecord)).Count -ne 0) {
        throw 'Makine kapsamli Python kaydi kabul edildi.'
    }
    $pythonRecord.PSObject.Properties.Remove('InstallLocation')
    if (@(Get-PythonRegistryEntries `
        -Ownership $ownership.Components.Python `
        -Entries @($pythonRecord)).Count -ne 0) {
        throw 'Konumsuz Python kayit fiksturu kabul edildi.'
    }
    $pythonRoot = Split-Path -Parent `
        $ownership.Components.Python.ExecutablePath
    $pythonSigner = {
        param($Path)
        [pscustomobject]@{
            Status = 'Valid'
            SignerCertificate = [pscustomobject]@{
                Subject = 'CN=Python Software Foundation'
            }
        }
    }
    $pythonVersionReader = {
        param($Path)
        [pscustomobject]@{
            ProductVersion = '3.11.9.0'
            FileVersion = '3.11.9.0'
        }
    }
    if (-not (Test-PythonOfficialUninstaller `
        -FilePath (Join-Path $pythonRoot 'uninstall.exe') `
        -Ownership $ownership.Components.Python `
        -SignatureReader $pythonSigner `
        -VersionReader $pythonVersionReader) -or
        -not (Test-PythonOfficialUninstaller `
            -FilePath (Join-Path (Join-Path $env:ProgramData `
                'Package Cache\{12345678-1234-1234-1234-1234567890AB}') `
                'python-3.11.9-amd64.exe') `
            -Ownership $ownership.Components.Python `
            -SignatureReader $pythonSigner `
            -VersionReader $pythonVersionReader) -or
        (Test-PythonOfficialUninstaller `
            -FilePath 'C:\Fixture\malicious.exe' `
            -Ownership $ownership.Components.Python `
            -SignatureReader $pythonSigner `
            -VersionReader $pythonVersionReader)) {
        throw 'Python kaldirici yolu kanit fiksturu basarisiz.'
    }
    $msiPath = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    $productCode = '{12345678-1234-1234-1234-1234567890AB}'
    if ((Get-PythonMsiProductCode -FilePath $msiPath `
        -Arguments "/I$productCode /qn") -cne $productCode -or
        $null -ne (Get-PythonMsiProductCode -FilePath $msiPath `
            -Arguments "/I$productCode /qn & evil.exe") -or
        $null -ne (Get-PythonMsiProductCode `
            -FilePath $PSHOME\powershell.exe `
            -Arguments "/X$productCode /qn")) {
        throw 'Python MSI GUID kanit fiksturu basarisiz.'
    }
    $msiPythonRecord = $pythonRecord | Select-Object *
    $msiPythonRecord.QuietUninstallString = '"{0}" /I{1} /qn' -f `
        $msiPath, $productCode
    $msiOwnershipRejected = $false
    try {
        $null = New-PythonRemovalPlan `
            -Ownership $ownership.Components.Python `
            -RegistryEntry $msiPythonRecord `
            -CommandPathResolver { param($Path) $Path }
    }
    catch {
        $msiOwnershipRejected = $true
    }
    if (-not $msiOwnershipRejected) {
        throw 'Kanitsiz Python MSI urun kodu kabul edildi.'
    }
    $wingetAlias = Join-Path $env:LOCALAPPDATA `
        'Microsoft\WindowsApps\winget.exe'
    $wingetItemReader = {
        param($Path)
        [pscustomobject]@{
            Attributes = [IO.FileAttributes]::ReparsePoint
            Length = 0
        }
    }
    if (-not (Test-UninstallTrustedWingetPath `
        -FilePath $wingetAlias -ItemReader $wingetItemReader `
        -AliasIdentityReader { param($Path) $true }) -or
        (Test-UninstallTrustedWingetPath `
            -FilePath 'C:\Fixture\winget.exe' `
            -ItemReader $wingetItemReader `
            -AliasIdentityReader { param($Path) $true })) {
        throw 'Winget yolu kanit fiksturu basarisiz.'
    }
    $artifactPlan = New-PythonRemovalPlan `
        -Ownership $ownership.Components.Python `
        -RegistryEntry $pythonRecord `
        -SignatureReader $pythonSigner `
        -VersionReader $pythonVersionReader `
        -CommandPathResolver { param($Path) $Path }
    if ($artifactPlan.Method -cne 'SignedPythonUninstaller' -or
        ($artifactPlan.Arguments -join ' ') -cne
            '/uninstall /quiet /norestart') {
        throw 'Python imzali kaldirma plani fiksturu basarisiz.'
    }
    $recoveredPython = $ownership.Components.Python | Select-Object *
    $recoveredPython.Source = 'ExistingOwnedPath'
    $recoveredPlan = New-PythonRemovalPlan `
        -Ownership $recoveredPython -RegistryEntry $pythonRecord `
        -SignatureReader $pythonSigner `
        -VersionReader $pythonVersionReader `
        -CommandPathResolver { param($Path) $Path }
    if ($recoveredPlan.Method -cne 'SignedPythonUninstaller' -or
        (Get-PythonOwnedRootForRemoval -Ownership $recoveredPython) `
            -ine $pythonRoot) {
        throw 'Python kurtarilmis sahiplik plani fiksturu basarisiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Uninstall.PythonOwnershipRecovery'
    $maliciousPythonRecord = [pscustomobject]@{
        PSPath = ('Registry::HKEY_CURRENT_USER\Software\Microsoft\' +
            'Windows\CurrentVersion\Uninstall\Python311')
        QuietUninstallString = ('"{0}" --elevated-payload' -f `
            (Join-Path $PSHOME 'powershell.exe'))
    }
    $maliciousRejected = $false
    try {
        $null = New-PythonRemovalPlan `
            -Ownership $ownership.Components.Python `
            -RegistryEntry $maliciousPythonRecord `
            -SignatureReader $pythonSigner `
            -VersionReader $pythonVersionReader
    }
    catch {
        $maliciousRejected = $true
    }
    if (-not $maliciousRejected) {
        throw 'HKCU Python kaldirici enjeksiyonu kabul edildi.'
    }
    if (@(Get-PythonRegistryEntries `
        -Ownership $ownership.Components.Python `
        -Entries @($missingDisplayName)).Count -ne 0) {
        throw 'Eksik DisplayName Python kayit fiksturu basarisiz.'
    }
    $cliPackages = @(Get-DeveloperCliNpmPackages)
    if (($cliPackages.PackageName -join ',') -cne `
        '@openai/codex,@github/copilot' -or
        -not (Test-NpmPackageIdentity `
            -PackagePath 'C:\Fixture\codex' `
            -PackageName '@openai/codex' `
            -MetadataReader {
                param($Path)
                [pscustomobject]@{ name = '@openai/codex' }
            }) -or
        (Test-NpmPackageIdentity `
            -PackagePath 'C:\Fixture\codex' `
            -PackageName '@github/copilot' `
            -MetadataReader {
                param($Path)
                [pscustomobject]@{ name = '@openai/codex' }
            })) {
        throw 'Gelistirici CLI paket kimligi fiksturu basarisiz.'
    }
    $runtimeFixtureRoot = Join-Path $env:LOCALAPPDATA `
        'nvm\v24.0.0'
    $npmAllowlist = @(Get-NpmGlobalRootAllowlist `
        -RuntimeRoots @($runtimeFixtureRoot))
    $expectedRuntimeModules = Join-Path $runtimeFixtureRoot 'node_modules'
    $runtimeDiscoverySource = & $getSourceFunction `
        'Get-NodeRuntimeCandidateRoots'
    $runtimeTrustSource = & $getSourceFunction `
        'Get-TrustedNodeNpmRuntimes'
    $npmRemovalSource = & $getSourceFunction `
        'Remove-NpmDeveloperCliPackages'
    $npmPathSource = & $getSourceFunction 'Get-NpmPackagePath'
    if ($expectedRuntimeModules -notin $npmAllowlist -or
        $runtimeDiscoverySource -notmatch 'Get-Command' -or
        $runtimeDiscoverySource -notmatch 'NVM_HOME' -or
        $runtimeDiscoverySource -notmatch 'FNM_DIR' -or
        $runtimeDiscoverySource -notmatch 'VOLTA_HOME' -or
        $runtimeTrustSource -notmatch 'Test-UninstallTrustedSigner' -or
        $runtimeTrustSource -notmatch 'Assert-UninstallNoReparsePoint' -or
        $npmPathSource -match 'SkipReparseCheck' -or
        $npmRemovalSource -notmatch 'Test-NpmPackageIdentity' -or
        $npmRemovalSource -notmatch '\$remaining\.Count\s+-gt\s+0') {
        throw 'Gelistirici CLI NPM kesif veya guvenlik sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.NpmDiscovery'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.NpmPathSafety'
    $voltaFixtureHome = Join-Path $env:LOCALAPPDATA `
        'WinlamaValidation\Volta'
    $voltaPackagesRoot = Join-Path $voltaFixtureHome `
        'tools\image\packages'
    $voltaCodexRoot = Join-Path $voltaPackagesRoot `
        '@openai\codex'
    $voltaCopilotRoot = Join-Path $voltaPackagesRoot `
        '@github\copilot'
    $voltaCodexMetadata = Join-Path $voltaCodexRoot `
        'node_modules\@openai\codex\package.json'
    $voltaCopilotMetadata = Join-Path $voltaCopilotRoot `
        'lib\node_modules\@github\copilot\package.json'
    $voltaFixturePaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in @(
        $voltaCodexRoot,
        $voltaCopilotRoot,
        $voltaCodexMetadata,
        $voltaCopilotMetadata
    )) {
        $null = $voltaFixturePaths.Add($path)
    }
    $voltaRemoved = [Collections.Generic.List[string]]::new()
    $voltaPathExists = {
        param($Path, $PathType)
        return $voltaFixturePaths.Contains(
            [IO.Path]::GetFullPath($Path)
        )
    }.GetNewClosure()
    $voltaMetadataReader = {
        param($Path)
        if ([IO.Path]::GetFullPath($Path).Equals(
            [IO.Path]::GetFullPath($voltaCodexMetadata),
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return [pscustomobject]@{
                name = '@openai/codex'
                version = '1.2.3-test.1'
                bin = [pscustomobject]@{ codex = 'bin\codex.js' }
            }
        }
        return [pscustomobject]@{
            name = '@github/copilot'
            version = '2.3.4'
            bin = 'index.js'
        }
    }.GetNewClosure()
    $voltaPackageRemover = {
        param($Record)
        $voltaRemoved.Add([string]$Record.PackageName)
        foreach ($path in @($voltaFixturePaths)) {
            if (Test-UninstallPathWithin -Path $path `
                -Root $Record.PackageRoot -AllowRoot) {
                $null = $voltaFixturePaths.Remove($path)
            }
        }
    }.GetNewClosure()
    Remove-VoltaDeveloperCliPackages `
        -VoltaHomes @($voltaFixtureHome) `
        -PathExists $voltaPathExists `
        -MetadataReader $voltaMetadataReader `
        -PackageRemover $voltaPackageRemover
    $voltaDiscoverySource = & $getSourceFunction `
        'Get-VoltaDeveloperCliPackageRecords'
    $voltaRemovalSource = & $getSourceFunction `
        'Remove-VoltaDeveloperCliPackages'
    if (($voltaRemoved -join ',') -cne `
            '@openai/codex,@github/copilot' -or
        $voltaFixturePaths.Count -ne 0 -or
        (Test-VoltaDeveloperCliPackageMetadata `
            -Metadata ([pscustomobject]@{
                name = '@github/copilot-sdk'
                version = '1.0.0'
                bin = 'index.js'
            }) -PackageName '@github/copilot') -or
        $voltaDiscoverySource -notmatch 'tools\\image\\packages' -or
        $voltaDiscoverySource -notmatch 'Resolve-SafeUninstallPath' -or
        $voltaDiscoverySource -notmatch 'Assert-UninstallNoReparsePoint' -or
        $voltaRemovalSource -notmatch '\$remaining\.Count\s+-ne\s+0') {
        throw 'Volta exact CLI kaldirma fiksturu basarisiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.VoltaExactPackages'
    $wingetInstalledResult = [pscustomobject]@{
        ExitCode = 0
        OutputComplete = $true
        StandardOutput = ('Name  Id  Version' + [Environment]::NewLine +
            'GitHub Copilot  GitHub.Copilot  1.2.3')
        StandardError = ''
    }
    $wingetOtherResult = [pscustomobject]@{
        ExitCode = 0
        OutputComplete = $true
        StandardOutput = ('Name  Id  Version' + [Environment]::NewLine +
            'GitHub Copilot Preview  GitHub.Copilot.Prerelease  1.2.3')
        StandardError = ''
    }
    $wingetAbsentResult = [pscustomobject]@{
        ExitCode = -1978335212
        OutputComplete = $true
        StandardOutput = ''
        StandardError = ''
    }
    if (-not (Test-WingetExactPackageInstalled `
            -WingetPath 'C:\Fixture\winget.exe' `
            -PackageId 'GitHub.Copilot' `
            -ProcessInvoker { $wingetInstalledResult }.GetNewClosure()) -or
        (Test-WingetExactPackageInstalled `
            -WingetPath 'C:\Fixture\winget.exe' `
            -PackageId 'GitHub.Copilot' `
            -ProcessInvoker { $wingetOtherResult }.GetNewClosure()) -or
        (Test-WingetExactPackageInstalled `
            -WingetPath 'C:\Fixture\winget.exe' `
            -PackageId 'GitHub.Copilot' `
            -ProcessInvoker { $wingetAbsentResult }.GetNewClosure())) {
        throw 'Winget exact paket sorgu fiksturu basarisiz.'
    }
    $wingetFixtureInstalled = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $null = $wingetFixtureInstalled.Add(
        'GitHub.Copilot.Prerelease'
    )
    $wingetFixtureRemoved = [Collections.Generic.List[string]]::new()
    $wingetFixtureProbe = {
        param($Path, $PackageId)
        return $wingetFixtureInstalled.Contains($PackageId)
    }.GetNewClosure()
    $wingetFixtureUninstaller = {
        param($Path, $PackageId)
        $wingetFixtureRemoved.Add($PackageId)
        $null = $wingetFixtureInstalled.Remove($PackageId)
    }.GetNewClosure()
    Remove-WingetDeveloperCliPackages `
        -WingetPath 'C:\Fixture\winget.exe' `
        -PackageProbe $wingetFixtureProbe `
        -PackageUninstaller $wingetFixtureUninstaller
    $wingetRemovalSource = & $getSourceFunction `
        'Remove-WingetDeveloperCliPackages'
    if (($wingetFixtureRemoved -join ',') -cne `
            'GitHub.Copilot.Prerelease' -or
        $wingetFixtureInstalled.Count -ne 0 -or
        $wingetRemovalSource -match 'Get-GitHubCopilotRegistryEntries' -or
        $wingetRemovalSource -notmatch 'Get-DeveloperCliWingetPackageIds' -or
        $wingetRemovalSource -notmatch '\$remaining\.Count\s+-ne\s+0') {
        throw 'Winget exact CLI kaldirma fiksturu basarisiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.WingetExactPackages'
    $completedOutput = [Threading.Tasks.Task]::FromResult('hazir')
    $pendingOutput = [Threading.Tasks.TaskCompletionSource[string]]::new()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $completedAccepted = Wait-UninstallNativeOutputTasks `
        -Tasks ([Threading.Tasks.Task[]]@($completedOutput)) `
        -TimeoutMilliseconds 100
    $pendingAccepted = Wait-UninstallNativeOutputTasks `
        -Tasks ([Threading.Tasks.Task[]]@($pendingOutput.Task)) `
        -TimeoutMilliseconds 25
    $watch.Stop()
    $null = $pendingOutput.TrySetCanceled()
    $nativeSource = & $getSourceFunction `
        'Invoke-UninstallNativeProcess'
    $treeStopSource = & $getSourceFunction `
        'Stop-UninstallNativeProcessTree'
    if (-not $completedAccepted -or $pendingAccepted -or
        $watch.ElapsedMilliseconds -gt 1000 -or
        $nativeSource -notmatch 'Wait-UninstallNativeOutputTasks' -or
        $nativeSource -notmatch 'TimeoutMilliseconds 5000' -or
        $nativeSource -notmatch 'Stop-UninstallNativeProcessTree' -or
        $nativeSource -notmatch '\$timeoutOutputComplete' -or
        $nativeSource -notmatch 'OutputComplete = \$outputComplete' -or
        $nativeSource -notmatch '\$exitCode\s+=\s+\$process\.ExitCode' -or
        $treeStopSource -notmatch 'Test-UninstallTrustedSigner' -or
        $treeStopSource -notmatch 'taskkill\.exe' -or
        $treeStopSource -notmatch '/PID \$TargetProcessId /T /F' -or
        $treeStopSource -notmatch '\[object\[\]\]@\(\$true\)' -or
        $treeStopSource -notmatch 'WaitForExit\(\$WaitMilliseconds\)') {
        throw 'Kaldirma yerel surec cikti bekleme siniri gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Uninstall.NativeOutputDrainBounded'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Uninstall.NativeExitCodePropagation'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Uninstall.NativeProcessTreeTermination'
    if (-not (Test-UninstallOwnedJunctionTarget `
        -Target 'C:\Fixture\Codex\releases\1.2.3\bin' `
        -OwnerRoot 'C:\Fixture\Codex') -or
        (Test-UninstallOwnedJunctionTarget `
            -Target 'C:\Fixture\Other\bin' `
            -OwnerRoot 'C:\Fixture\Codex')) {
        throw 'Codex baglanti hedefi fiksturu basarisiz.'
    }
    $codexVisibleFixture = Join-Path $env:LOCALAPPDATA `
        'Programs\OpenAI\Codex\bin'
    $codexStandaloneSource = & $getSourceFunction `
        'Remove-StandaloneCodexCli'
    if (-not (Test-UninstallEnvironmentPathEntry `
            -Entry $codexVisibleFixture `
            -ExpectedPath $codexVisibleFixture) -or
        -not (Test-UninstallEnvironmentPathEntry `
            -Entry '%LOCALAPPDATA%\Programs\OpenAI\Codex\bin' `
            -ExpectedPath $codexVisibleFixture) -or
        -not (Test-UninstallEnvironmentPathEntry `
            -Entry ('"{0}"' -f $codexVisibleFixture) `
            -ExpectedPath $codexVisibleFixture) -or
        (Test-UninstallEnvironmentPathEntry `
            -Entry (Join-Path $codexVisibleFixture 'Other') `
            -ExpectedPath $codexVisibleFixture) -or
        $codexStandaloneSource -match
            '(?i)Remove-UninstallPath[^\r\n]*-Path\s+\$codexHome\b' -or
        $codexStandaloneSource -notmatch
            'Test-UninstallEnvironmentPathEntry') {
        throw 'Codex PATH veya oturum koruma fiksturu basarisiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.CodexSessionPreserved'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.CodexPathCleanup'
    $ownership.Components.Python.PackageId = 'Python.Python.3.12'
    if (Test-PythonOwnershipDocument `
        -Document $ownership -Dependency $dependency) {
        throw 'Guvenli olmayan Python sahiplik fiksturu kabul edildi.'
    }
    $blankSelectionRejected = $false
    try {
        $null = Read-FullUninstallSelection -Value ''
    }
    catch {
        $blankSelectionRejected = $true
    }
    if (-not $blankSelectionRejected -or
        (Resolve-UninstallIndexSelection -Value '0').Cancelled -ne $true -or
        (Resolve-UninstallIndexSelection -Value 'A').Selection.Count -ne 7 -or
        ((Resolve-UninstallIndexSelection `
            -Value '-1,2').Selection -join ',') -cne '3,4,5,6,7' -or
        (Test-UninstallExactYes -Value '') -or
        (Test-UninstallExactYes -Value 'E') -or
        (Test-UninstallExactYes -Value 'evet') -or
        (Test-UninstallExactYes -Value ' EVET ') -or
        -not (Test-UninstallExactYes -Value 'EVET')) {
        throw 'Guvenli iptal veya kesin onay fiksturu basarisiz.'
    }
    $exactNoQueue = [Collections.Generic.Queue[string]]::new()
    foreach ($value in @('', 'H', 'hayir', ' HAYIR ', 'HAYIR')) {
        $exactNoQueue.Enqueue($value)
    }
    if (Read-UninstallExactConfirmation `
        -Prompt 'Dogrulama kesin HAYIR onayi.' `
        -InputReader { $exactNoQueue.Dequeue() }.GetNewClosure()) {
        throw 'Kaldirma kesin HAYIR fiksturu basarisiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Uninstall.ExactTokens'
    $pythonKeptPlan = Get-FullUninstallCleanupPlan `
        -Selection @(1, 2, 3, 4, 5, 7)
    $pythonDeletedPlan = Get-FullUninstallCleanupPlan `
        -Selection @(1..7)
    $emptySelectionPlan = Get-FullUninstallCleanupPlan -Selection @()
    $expectedPythonRoot = Get-UninstallExpectedPythonRoot
    if (-not $pythonKeptPlan.PreservePython -or
        -not $pythonKeptPlan.PreservePath.Equals(
            $expectedPythonRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or $pythonDeletedPlan.PreservePython -or
        -not [string]::IsNullOrEmpty(
            [string]$pythonDeletedPlan.PreservePath
        ) -or -not $emptySelectionPlan.PreservePython) {
        throw 'Tam kaldirma Python koruma plani fiksturu basarisiz.'
    }
    if (-not (Test-UninstallPauseRequired `
            -ValidationMode $false -AutomationMode $false) -or
        (Test-UninstallPauseRequired `
            -ValidationMode $true -AutomationMode $false) -or
        (Test-UninstallPauseRequired `
            -ValidationMode $false -AutomationMode $true)) {
        throw 'Kaldirma interaktif bekleme modu fiksturu basarisiz.'
    }
    $menuCompletionSource = & $getSourceFunction `
        'Complete-UninstallMenuAction'
    $menuLoopSource = & $getSourceFunction 'Invoke-UninstallMenu'
    if ($menuCompletionSource -notmatch 'Test-UninstallPauseRequired' -or
        $menuCompletionSource -notmatch '-Command\s+DEVAM' -or
        $menuLoopSource -notmatch `
            'Complete-UninstallMenuAction\s+-Status\s+\$status') {
        throw 'Kaldirma menu eylem ozeti sozlesmesi basarisiz.'
    }
    $pythonActions = @(Get-FullUninstallActions -Config $Config `
        -Selection @(6))
    if ($pythonActions.Count -ne 2 -or
        $pythonActions[0].Name -notmatch 'Winlama Python' -or
        $pythonActions[0].Name -match '(?i)resmi') {
        throw 'Winlama Python eylem etiketi veya sirasi gecersiz.'
    }
    $pythonRemovalSource = & $getSourceFunction `
        'Remove-PythonApplication'
    $officialRemovalIndex = $pythonRemovalSource.IndexOf(
        'Invoke-UninstallNativeProcess',
        [StringComparison]::Ordinal
    )
    $pythonRootRemovalIndex = $pythonRemovalSource.LastIndexOf(
        'Remove-UninstallPath -Path $pythonRoot',
        [StringComparison]::Ordinal
    )
    if ($pythonRemovalSource -notmatch `
            '\$records\.Count\s+-eq\s+0' -or
        $pythonRemovalSource -notmatch `
            'PYTHON_OWNERSHIP_RECOVERED' -or
        $pythonRemovalSource -notmatch `
            'PYTHON_ORPHANED_ROOT_RECOVERED' -or
        $pythonRemovalSource -notmatch `
            'Kayitsiz Winlama Python 3\.11 hedefi' -or
        $officialRemovalIndex -lt 0 -or
        $pythonRootRemovalIndex -le $officialRemovalIndex) {
        throw 'Winlama Python resmi kaldirma sirasi sozlesmesi gecersiz.'
    }
    $invalidSelectionRejected = $false
    try {
        $null = Resolve-UninstallIndexSelection -Value 'x,9'
    }
    catch {
        $invalidSelectionRejected = $true
    }
    if (-not $invalidSelectionRejected) {
        throw 'Gecersiz secim fiksturu kabul edildi.'
    }
    $fixtureRoot = Join-Path $env:LOCALAPPDATA `
        'Programs\Winlama-Fixture'
    $safeFixture = Join-Path $fixtureRoot 'Data\fixture.txt'
    $resolvedFixture = Resolve-SafeUninstallPath -Path $safeFixture `
        -AllowedRoots @($fixtureRoot) -SkipReparseCheck
    if ($resolvedFixture -ine [IO.Path]::GetFullPath($safeFixture)) {
        throw 'Guvenli yol fiksturu basarisiz.'
    }
    if ((Assert-UninstallExactPath -Actual $fixtureRoot `
        -Expected $fixtureRoot -Label 'Fikstur') -ine `
        [IO.Path]::GetFullPath($fixtureRoot)) {
        throw 'Kesin yol fiksturu basarisiz.'
    }
    $exactChildRejected = $false
    try {
        $null = Assert-UninstallExactPath `
            -Actual (Join-Path $fixtureRoot 'Child') `
            -Expected $fixtureRoot -Label 'Fikstur'
    }
    catch {
        $exactChildRejected = $true
    }
    if (-not $exactChildRejected) {
        throw 'Kesin olmayan alt yol fiksturu kabul edildi.'
    }
    $ollamaFixtureRoot = 'C:\Fixture\Ollama'
    if (-not (Test-UninstallOllamaProcessProof `
        -ExecutablePath 'C:\Fixture\Ollama\ollama.exe' `
        -ProcessName 'ollama' -InstallRoot $ollamaFixtureRoot) -or
        -not (Test-UninstallOllamaProcessProof `
            -ExecutablePath ('C:\Fixture\Ollama\lib\' +
                'ollama_llama_server.exe') `
            -ProcessName 'ollama_llama_server' `
            -InstallRoot $ollamaFixtureRoot) -or
        (Test-UninstallOllamaProcessProof `
            -ExecutablePath 'C:\Fixture\Other\ollama.exe' `
            -ProcessName 'ollama' -InstallRoot $ollamaFixtureRoot) -or
        (Test-UninstallOllamaProcessProof `
            -ExecutablePath 'C:\Fixture\Ollama\other.exe' `
            -ProcessName 'other' -InstallRoot $ollamaFixtureRoot)) {
        throw 'Ollama surec kaniti fiksturu basarisiz.'
    }
    if ($source -notmatch '(?s)function Remove-OllamaModels.*?' +
        'Stop-OllamaProcessesForRemoval.*?Remove-UninstallPath' -or
        $source -notmatch '(?s)function Remove-OpenWebUIData.*?' +
            'Stop-UninstallProcessesFromPath.*?' +
            'Open WebUI veri son kosulu') {
        throw 'Model veya WebUI surec kilidi sozlesmesi basarisiz.'
    }
    foreach ($unsafe in @(
        [IO.Path]::GetPathRoot($fixtureRoot),
        $env:LOCALAPPDATA,
        (Join-Path $fixtureRoot '..\outside')
    )) {
        $rejected = $false
        try {
            $null = Resolve-SafeUninstallPath -Path $unsafe `
                -AllowedRoots @($fixtureRoot) -AllowRoot `
                -SkipReparseCheck
        }
        catch {
            $rejected = $true
        }
        if (-not $rejected) {
            throw "Guvenli olmayan yol fiksturu kabul edildi: $unsafe"
        }
    }
    if (-not (Test-UninstallReparseAttribute `
        -Attributes ([IO.FileAttributes]::Directory -bor `
            [IO.FileAttributes]::ReparsePoint)) -or
        (Test-UninstallReparseAttribute `
            -Attributes ([IO.FileAttributes]::Directory))) {
        throw 'Yeniden ayrisim ozniteligi fiksturu basarisiz.'
    }
    $visited = [Collections.Generic.List[string]]::new()
    $aggregate = Invoke-UninstallAggregateActions -Quiet `
        -SuppressLog -Actions @(
        [pscustomobject]@{
            Name = 'Fixture one'
            Action = { $visited.Add('one') }.GetNewClosure()
        },
        [pscustomobject]@{
            Name = 'Fixture failure'
            Action = {
                $visited.Add('failure')
                throw 'beklenen fikstur hatasi'
            }.GetNewClosure()
        },
        [pscustomobject]@{
            Name = 'Fixture three'
            Action = { $visited.Add('three') }.GetNewClosure()
        }
    )
    if ($aggregate.Succeeded -or
        $aggregate.Failures.Count -ne 1 -or
        ($visited -join ',') -cne 'one,failure,three') {
        throw 'Bagimsiz islem toplama fiksturu basarisiz.'
    }
    $emptyAggregate = Invoke-UninstallAggregateActions -Quiet `
        -SuppressLog -Actions @()
    if (-not $emptyAggregate.Succeeded -or
        @($emptyAggregate.Completed).Count -ne 0 -or
        @($emptyAggregate.Failures).Count -ne 0) {
        throw 'Bos islem toplama fiksturu basarisiz.'
    }
    if ((Get-UninstallExitCode -Status RootCleanupScheduled) -ne 10 -or
        (Get-UninstallExitCode -Status Cancelled) -ne 2 -or
        (Get-UninstallExitCode -Status Completed) -ne 0 -or
        (Get-UninstallExitCode -Status Failed) -ne 1) {
        throw 'Kaldirma cikis kodu sozlesmesi basarisiz.'
    }
    $launcherFixture = Join-Path $PSScriptRoot 'Launcher.ps1'
    $quotedLauncher = 'pwsh.exe -NoProfile -File "{0}" -NoPause' -f `
        $launcherFixture
    if (-not (Test-UninstallLauncherParent `
        -ExecutablePath 'C:\Program Files\PowerShell\7\pwsh.exe' `
        -CommandLine $quotedLauncher -LauncherPath $launcherFixture) -or
        (Test-UninstallLauncherParent `
            -ExecutablePath 'C:\Windows\System32\cmd.exe' `
            -CommandLine $quotedLauncher -LauncherPath $launcherFixture) -or
        (Test-UninstallLauncherParent `
            -ExecutablePath 'C:\Windows\explorer.exe' `
            -CommandLine $quotedLauncher -LauncherPath $launcherFixture) -or
        (Test-UninstallLauncherParent `
            -ExecutablePath ('C:\Windows\System32\WindowsPowerShell\' +
                'v1.0\powershell.exe') `
            -CommandLine ('powershell.exe -File "{0}"' -f `
                $PSCommandPath) -LauncherPath $launcherFixture) -or
        (Test-UninstallLauncherParent `
            -ExecutablePath 'C:\Program Files\PowerShell\7\pwsh.exe' `
            -CommandLine ('pwsh.exe -Command "Write-Output ''{0}''"' -f `
                $launcherFixture) -LauncherPath $launcherFixture)) {
        throw 'Launcher ust surec kimligi fiksturu basarisiz.'
    }
    if ($null -ne $script:UninstallMutex -or
        $source -notmatch '(?s)if \(\$ValidateOnly\).*?exit 0.*?' +
            'Enter-UninstallMutex.*?finally\s*\{\s*' +
            'Exit-UninstallMutex') {
        throw 'ValidateOnly kaldirma kilidi saflik sozlesmesi basarisiz.'
    }
    $cleanupSource = New-WinlamaRootCleanupScript
    $cleanupTokens = $null
    $cleanupErrors = $null
    $cleanupAst = [Management.Automation.Language.Parser]::ParseInput(
        $cleanupSource,
        [ref]$cleanupTokens,
        [ref]$cleanupErrors
    )
    $cleanupFunction = $sourceAst.Find({
        param($node)
        $node -is `
            [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Start-WinlamaRootCleanup'
    }, $true)
    $cleanupFunctionSource = if ($null -eq $cleanupFunction) {
        ''
    }
    else {
        $cleanupFunction.Extent.Text
    }
    if ($cleanupSource -notmatch 'ParentStartTicks' -or
        $cleanupSource -notmatch 'OwnerProcessId' -or
        $cleanupSource -notmatch 'StatusPath' -or
        $cleanupSource -notmatch 'PreservePath' -or
        $cleanupSource -notmatch 'preservedPath' -or
        $cleanupSource -notmatch 'payloadRemoved' -or
        $cleanupSource -notmatch "Phase 'Ready'" -or
        $cleanupSource -notmatch "'Completed'" -or
        $cleanupSource -notmatch "'Failed'" -or
        $cleanupSource -notmatch 'parentStillRunning' -or
        $cleanupSource -notmatch 'for \(\$attempt = 1;' -or
        $cleanupSource -notmatch 'Remove-Item -LiteralPath \$self' -or
        $cleanupSource -notmatch 'function Write-CleanupLine' -or
        $cleanupSource -notmatch 'function Get-CleanupUIStatusStyle' -or
        $cleanupSource -notmatch 'function Get-CleanupUIStatusWidth' -or
        $cleanupSource -notmatch 'function Format-CleanupUIStatusLabel' -or
        $cleanupSource -notmatch 'function Write-CleanupUIStatus' -or
        $cleanupSource -notmatch 'function Format-CleanupInputLine' -or
        $cleanupSource -notmatch 'function ConvertFrom-CleanupReadValue' -or
        $cleanupSource -notmatch 'function Complete-CleanupOperation' -or
        $cleanupSource -notmatch 'function Assert-CleanupTreeSafe' -or
        $cleanupSource -notmatch 'function Test-CleanupReparseAttribute' -or
        $cleanupSource -notmatch `
            'function Test-CleanupPayloadPathAllowed' -or
        $cleanupSource -notmatch 'Get-ChildItem[^\r\n]+-Recurse' -or
        $cleanupSource -notmatch 'function Remove-CleanupStatus' -or
        $cleanupSource -notmatch 'Test-CleanupExactExit -Value \$value' -or
        $cleanupSource -notmatch '(?s)if \(-not \$preflightValid\).*?' +
            'Complete-CleanupOperation -Level ERROR.*?exit 1' -or
        $cleanupSource -notmatch 'ISLEM OZETI' -or
        $cleanupSource -match '__WINLAMA_[A-Z_]+' -or
        @($cleanupErrors).Count -ne 0 -or
        $cleanupFunctionSource -notmatch '-NoNewWindow' -or
        $cleanupFunctionSource -match '-NonInteractive' -or
        $cleanupFunctionSource -match '-WindowStyle') {
        throw 'Harici temizlik bekleme/tekrar/kendini silme sozlesmesi basarisiz.'
    }
    $lastStatusCleanup = $cleanupSource.LastIndexOf(
        'Remove-CleanupStatus',
        [StringComparison]::Ordinal
    )
    $lastCompletion = $cleanupSource.LastIndexOf(
        'Complete-CleanupOperation',
        [StringComparison]::Ordinal
    )
    if ($lastStatusCleanup -lt 0 -or
        $lastCompletion -le $lastStatusCleanup) {
        throw 'Harici temizlik sonuc kaydi kapanis oncesi silinmiyor.'
    }
    $cleanupFixtureNames = @(
        'Write-CleanupRule',
        'Write-CleanupLine',
        'Get-CleanupUIStatusStyle',
        'Get-CleanupUIStatusWidth',
        'Format-CleanupUIStatusLabel',
        'Write-CleanupUIStatus',
        'Format-CleanupInputLine',
        'ConvertFrom-CleanupReadValue',
        'Test-CleanupExactExit',
        'Test-CleanupReparseAttribute',
        'Test-CleanupPayloadPathAllowed',
        'Read-CleanupRawInput',
        'Wait-CleanupExit',
        'Complete-CleanupOperation'
    )
    $cleanupFixtureSource = foreach ($functionName in
        $cleanupFixtureNames) {
        $functionAst = $cleanupAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] `
                -and $node.Name -ceq $functionName
        }.GetNewClosure(), $true)
        if ($null -eq $functionAst) {
            throw "Harici temizlik UI fonksiyonu eksik: $functionName"
        }
        $functionAst.Extent.Text
    }
    $cleanupFixtureSource += @'
$fixtureInputs = [Collections.Generic.Queue[string]]::new()
$fixtureInputs.Enqueue('')
$fixtureInputs.Enqueue('C')
$fixtureInputs.Enqueue('cikis')
$fixtureInputs.Enqueue(' CIKIS ')
$fixtureInputs.Enqueue('CIKIS')
$fixtureReader = { $fixtureInputs.Dequeue() }.GetNewClosure()
Complete-CleanupOperation -Level SKIP `
    -Message 'Kok temizligi UI fiksturu.' `
    -InputReader $fixtureReader
if ($fixtureInputs.Count -ne 0) {
    throw 'Harici temizlik girdi kuyrugu tuketilmedi.'
}
Write-Verbose 'WINLAMA_UI_OK:Uninstall.CleanupExactExit'
$fixtureEofRejected = $false
try {
    $null = ConvertFrom-CleanupReadValue -Value $null
}
catch [IO.EndOfStreamException] {
    $fixtureEofRejected = $true
}
if (-not $fixtureEofRejected -or
    (ConvertFrom-CleanupReadValue -Value '') -cne '') {
    throw 'Harici temizlik EOF girdi sozlesmesi gecersiz.'
}
Complete-CleanupOperation -Level SUCCESS `
    -Message 'Kok temizligi EOF tamamlanma fiksturu.' `
    -InputReader { $null }
Write-Verbose 'WINLAMA_UI_OK:Uninstall.CleanupClosedInput'
$fixtureKeep = 'C:\Fixture\Winlama\Dependencies\Python311'
if (-not (Test-CleanupPayloadPathAllowed `
        -ItemPath 'C:\Fixture\Winlama\Dependencies' `
        -Preserve $fixtureKeep) -or
    -not (Test-CleanupPayloadPathAllowed `
        -ItemPath $fixtureKeep -Preserve $fixtureKeep) -or
    -not (Test-CleanupPayloadPathAllowed `
        -ItemPath (Join-Path $fixtureKeep 'python.exe') `
        -Preserve $fixtureKeep) -or
    (Test-CleanupPayloadPathAllowed `
        -ItemPath 'C:\Fixture\Winlama\Data' `
        -Preserve $fixtureKeep) -or
    -not (Test-CleanupReparseAttribute `
        -Attributes ([IO.FileAttributes]::ReparsePoint)) -or
    (Test-CleanupReparseAttribute `
        -Attributes ([IO.FileAttributes]::Directory))) {
    throw 'Harici temizlik Python koruma veya reparse fiksturu gecersiz.'
}
$fixtureInfoStyle = Get-CleanupUIStatusStyle -Level INFO
$fixtureStatusWidth = Get-CleanupUIStatusWidth
$fixtureOddLabel = Format-CleanupUIStatusLabel -Level STEP
if ($fixtureInfoStyle.Label -cne 'BILGI' -or
    $fixtureInfoStyle.Color -cne 'Cyan' -or
    $fixtureStatusWidth -ne 5 -or
    $fixtureOddLabel -cne 'ADIM ') {
    throw 'Harici temizlik durum UI sozlesmesi gecersiz.'
}
$fixtureEmptyLine = Format-CleanupInputLine
$fixtureSelection = 'Se{0}iminiz' -f [char]0x00E7
if ($fixtureEmptyLine.Length -ne 100 -or
    -not $fixtureEmptyLine.StartsWith(
        ('| {0}: ' -f $fixtureSelection)
    ) -or
    -not $fixtureEmptyLine.EndsWith(' |')) {
    throw 'Harici temizlik bos girdi geometrisi gecersiz.'
}
$fixtureLine = Format-CleanupInputLine -Value ('x' * 200)
if ($fixtureLine.Length -ne 100 -or
    -not $fixtureLine.StartsWith(
        ('| {0}: ...' -f $fixtureSelection)
    ) -or
    -not $fixtureLine.EndsWith(' |')) {
    throw 'Harici temizlik uzun girdi geometrisi gecersiz.'
}
'@
    $cleanupCompletionFunction = $cleanupAst.Find({
        param($node)
        $node -is `
            [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Complete-CleanupOperation'
    }, $true)
    if ($null -eq $cleanupCompletionFunction -or
        $cleanupCompletionFunction.Extent.Text -match
            '(?i)\b(Remove|Move|Copy|New|Set)-Item\b|' +
            '\b(Set|Add)-Content\b|\[IO\.File\]::') {
        throw 'Harici temizlik ozet fiksturu dosya sistemi safligi bozuldu.'
    }
    $cleanupFixture = [scriptblock]::Create(
        ($cleanupFixtureSource -join [Environment]::NewLine)
    )
    & $cleanupFixture
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.RootCleanupUI'
    $handshake = [pscustomobject]@{
        schemaVersion = 1
        cleanupId = '0123456789abcdef0123456789abcdef'
        phase = 'Ready'
        processId = 42
        rootPath = 'C:\Fixture\Winlama'
        preservedPath = ''
        rootAbsent = $false
        payloadRemoved = $false
    }
    if (-not (Test-WinlamaRootCleanupHandshake `
        -Candidate $handshake -CleanupId $handshake.cleanupId `
        -ProcessId 42 -RootPath $handshake.rootPath) -or
        (Test-WinlamaRootCleanupHandshake `
            -Candidate $handshake -CleanupId $handshake.cleanupId `
            -ProcessId 43 -RootPath $handshake.rootPath)) {
        throw 'Harici temizlik el sikisma fiksturu basarisiz.'
    }
    $preserveHandshake = $handshake | Select-Object *
    $preserveHandshake.preservedPath = `
        'C:\Fixture\Winlama\Dependencies\Python311'
    if (-not (Test-WinlamaRootCleanupHandshake `
            -Candidate $preserveHandshake `
            -CleanupId $preserveHandshake.cleanupId `
            -ProcessId 42 -RootPath $preserveHandshake.rootPath `
            -PreservePath $preserveHandshake.preservedPath) -or
        (Test-WinlamaRootCleanupHandshake `
            -Candidate $preserveHandshake `
            -CleanupId $preserveHandshake.cleanupId `
            -ProcessId 42 -RootPath $preserveHandshake.rootPath)) {
        throw 'Harici temizlik Python koruma el sikismasi gecersiz.'
    }
    Show-UninstallMenu
    Write-Verbose 'WINLAMA_UI_RENDERED:Uninstall.Main'
    Show-FullUninstallSelection
    $promptFixture = Read-UninstallInput `
        -Prompt 'Dogrulama kaldirma secimi.' `
        -Label 'FarkliEtiket' -InputReader { '0' } -NoLeadingRule
    if ($promptFixture -cne '0') {
        throw 'Kaldirma gercek secim istemi fiksturu basarisiz.'
    }
    Write-Verbose 'WINLAMA_UI_PROMPT_OK:Uninstall.Selection'
    Write-Verbose 'WINLAMA_UI_OK:Uninstall.Main'
    Write-Verbose 'WINLAMA_UI_OK:Uninstall.FullSelection'
    Write-Verbose 'WINLAMA_UI_OK:Uninstall.RuntimeContracts'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.RegistryPropertySafety'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.ConfigPrecedence'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.PythonOwnership'
    $expectedPythonFixtureRoot = Join-Path $env:LOCALAPPDATA `
        'Programs\Winlama\Dependencies\Python311'
    $pythonFixture = [pscustomobject]@{
        InstallRoot = $expectedPythonFixtureRoot
        ExecutablePath = Join-Path $expectedPythonFixtureRoot `
            'python.exe'
    }
    $pythonFixtureRoot = Get-PythonOwnedRootForRemoval `
        -Ownership $pythonFixture
    $pythonFixtureRejected = $false
    try {
        $null = Get-PythonOwnedRootForRemoval -Ownership `
            ([pscustomobject]@{
                InstallRoot = 'C:\Fixture\Python311'
                ExecutablePath = 'C:\Fixture\Python311\python.exe'
            })
    }
    catch {
        $pythonFixtureRejected = $true
    }
    if (-not $pythonFixtureRoot.Equals(
        [IO.Path]::GetFullPath(
            $expectedPythonFixtureRoot
        ),
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not $pythonFixtureRejected) {
        throw 'Python surec kok guvenligi fiksturu basarisiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.PythonProcessRoot'
    $fixtureProfile = 'C:\Users\Validation User'
    $elevationSource = (Get-Command Start-ElevatedUninstall `
        -ErrorAction Stop).Definition
    if (-not (Test-UninstallUserContextMatch `
        -ExpectedSid 'S-1-5-21-100' -ExpectedProfile $fixtureProfile `
        -ActualSid 'S-1-5-21-100' -ActualProfile $fixtureProfile) -or
        (Test-UninstallUserContextMatch `
            -ExpectedSid 'S-1-5-21-100' -ExpectedProfile $fixtureProfile `
            -ActualSid 'S-1-5-21-200' -ActualProfile $fixtureProfile) -or
        (Test-UninstallUserContextMatch `
            -ExpectedSid 'S-1-5-21-100' -ExpectedProfile $fixtureProfile `
            -ActualSid 'S-1-5-21-100' `
            -ActualProfile 'C:\Users\Other') -or
        (Test-UninstallUserContextMatch `
            -ExpectedSid 'S-1-5-21-100' -ExpectedProfile '' `
            -ActualSid 'S-1-5-21-100' -ActualProfile $fixtureProfile) -or
        -not (Test-UninstallUserContextMatch) -or
        $elevationSource -notmatch '-InitiatingUserSid' -or
        $elevationSource -notmatch '-InitiatingUserProfile' -or
        $elevationSource -notmatch '-ElevatedHost' -or
        $elevationSource -notmatch '-ConfigPath') {
        throw 'Kaldirma farkli yonetici hesabi korumasi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Uninstall.ElevatedUserContext'
    Write-Verbose 'WINLAMA_UI_OK:Uninstall.ElevatedBufferClear'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.Aggregation'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.Cancellation'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.PathSafety'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.RootCleanup'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.Mutex'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.LauncherParent'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.ProcessLocks'
}
try {
    $host.UI.RawUI.WindowTitle = Get-UninstallText `
        -Key 'Uninstall.WindowTitle' `
        -Fallback 'Winlama - Kaldirma'
}
catch {
    Write-Verbose ('Pencere basligi ayarlanamadi: {0}' -f `
        $_.Exception.Message)
}
$consoleModule = Join-Path $PSScriptRoot `
    'Modules\UI\ConsoleUI.psm1'
try {
    Import-Module $consoleModule -Force -ErrorAction Stop
    if ($ElevatedHost -and -not $ValidateOnly) {
        Initialize-WinlamaConsole -ClearBuffer
    }
    if ($ValidateOnly) {
        $configPath = Resolve-UninstallConfigPath -PackageOnly
        $script:UninstallResolvedConfigPath = $configPath
        $config = Read-UninstallConfiguration -Path $configPath
        Set-UninstallDiagnosticRoot -Config $config
        $null = Initialize-UninstallLocalization -Config $config
        Write-Verbose 'WINLAMA_VALIDATION_START:Uninstall.ps1'
        Assert-UninstallValidationContracts -Config $config
        Write-Verbose 'WINLAMA_VALIDATION_OK:Uninstall.ps1'
        exit 0
    }
    $configPath = Resolve-UninstallConfigPath
    $script:UninstallResolvedConfigPath = $configPath
    $config = Read-UninstallConfiguration -Path $configPath
    Set-UninstallDiagnosticRoot -Config $config
    $null = Initialize-UninstallLocalization -Config $config
    if (-not (Test-UninstallAdministrator)) {
        exit (Start-ElevatedUninstall)
    }
    Assert-UninstallElevatedUserContext
    Enter-UninstallMutex
    Write-UninstallLog -Event 'SESSION_STARTED' `
        -Message (Get-UninstallText `
            -Key 'Uninstall.Log.Configuration' `
            -Fallback 'Yapilandirma: {0}' -Arguments @($configPath))
    $status = Invoke-UninstallMenu -Config $config
    $exitCode = Get-UninstallExitCode -Status $status
    if ($status -ceq 'Cancelled') {
        Write-UninstallLog -Event 'UNINSTALL_CANCELLED' -Level WARN `
            -Message (Get-UninstallText `
                -Key 'Uninstall.Operation.Cancelled' `
                -Fallback ('Kaldirma oturumu kullanici ' +
                    'secimiyle kapatildi.'))
    }
    else {
        Write-UninstallLog -Event 'SESSION_COMPLETED' `
            -Level $(if ($exitCode -eq 1) { 'ERROR' } else { 'SUCCESS' }) `
            -Message (Get-UninstallText `
                -Key 'Uninstall.Log.SessionCompleted' `
                -Fallback 'Durum: {0} | Cikis kodu: {1}' `
                -Arguments @($status, $exitCode))
    }
    if ((Test-UninstallPauseRequired) -and
        $status -cne 'RootCleanupScheduled') {
        Complete-WinlamaUIOperation `
            -Summary $(if ($status -ceq 'Failed') {
                Get-UninstallText `
                    -Key 'Uninstall.Operation.Failed' `
                    -Fallback 'Kaldirma oturumu hatalarla tamamlandi.'
            }
            elseif ($status -ceq 'Cancelled') {
                Get-UninstallText `
                    -Key 'Uninstall.Operation.Cancelled' `
                    -Fallback ('Kaldirma oturumu kullanici ' +
                        'secimiyle kapatildi.')
            }
            else {
                Get-UninstallText `
                    -Key 'Uninstall.Operation.Completed' `
                    -Fallback 'Kaldirma oturumu tamamlandi.'
            }) `
            -Level $(if ($status -ceq 'Failed') {
                'ERROR'
            }
            elseif ($status -ceq 'Cancelled') {
                'SKIP'
            }
            else {
                'SUCCESS'
            }) -Command CIKIS
    }
    exit $exitCode
}
catch {
    Write-UninstallLog -Event 'SESSION_FAILED' -Level ERROR `
        -Message $_.Exception.Message -ErrorRecord $_
    Write-UninstallBootstrapError `
        -Context (Get-UninstallText `
            -Key 'Uninstall.Error.ActionFailed' `
            -Fallback 'Kaldirma islemi guvenle durduruldu: {0}' `
            -Arguments @($_.Exception.Message)) -ErrorRecord $_
    if (Test-UninstallPauseRequired) {
        try {
            $completeCommand = Get-Command Complete-WinlamaUIOperation `
                -ErrorAction SilentlyContinue
            if ($null -ne $completeCommand) {
                & $completeCommand `
                    -Summary (Get-UninstallText `
                        -Key 'Uninstall.Operation.Fatal' `
                        -Fallback 'Kaldirma islemi hatayla durdu.') `
                    -Level ERROR -Command CIKIS
            }
            else {
                do {
                    $answer = Read-UninstallInput `
                        -Prompt (Get-UninstallText `
                            -Key 'Common.Prompt.Close' `
                            -Fallback ('Oturumu kapatmak icin ' +
                                'CIKIS yazin.')) `
                        -Hint (Get-UninstallText `
                            -Key 'Common.Prompt.ExactCommand' `
                            -Fallback 'Yalniz tam olarak {0} yazin.' `
                            -Arguments @('CIKIS'))
                    if (-not (Test-UninstallBootstrapExactExit `
                        -Value $answer)) {
                        Write-UninstallBootstrapStatus -Level WARN `
                            -Message (Get-UninstallText `
                                -Key 'Common.Command.Invalid' `
                                -Fallback ('Bos veya gecersiz komut ' +
                                    'kabul edilmedi.'))
                    }
                } while (-not (Test-UninstallBootstrapExactExit `
                    -Value $answer))
            }
        }
        catch {
            Write-Verbose ('Kapanis beklemesi atlandi: {0}' -f `
                $_.Exception.Message)
        }
    }
    exit 1
}
finally {
    Exit-UninstallMutex
}