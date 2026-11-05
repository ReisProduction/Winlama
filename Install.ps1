[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Resume,
    [switch]$ForceRepair,
    [switch]$ValidateOnly,
    [switch]$NoPause,
    [switch]$GenerateReport,
    [ValidateSet('Prompt', 'Install', 'Skip')]
    [string]$OllamaSelection = 'Prompt',
    [string]$ModelSelection,
    [string]$ComfyUISelection,
    [ValidateSet('Prompt', 'Install', 'Skip')]
    [string]$ComfyUIInstallSelection = 'Prompt',
    [ValidateSet('Prompt', 'Install', 'Skip')]
    [string]$OpenWebUISelection = 'Prompt',
    [ValidateSet('Prompt', 'Apply', 'Skip')]
    [string]$DefaultConfigSelection = 'Prompt',
    [ValidateSet('Prompt', 'Install', 'Skip')]
    [string]$VoiceSelection = 'Prompt',
    [ValidateSet('Prompt', 'Turkish', 'English', 'Both')]
    [string]$VoiceLanguageSelection = 'Prompt',
    [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
    [string]$OllamaSourceSelection = 'Prompt',
    [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
    [string]$ModelSourceSelection = 'Prompt',
    [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
    [string]$ComfyUISourceSelection = 'Prompt',
    [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
    [string]$DependencySourceSelection = 'Prompt',
    [ValidateSet('Prompt', 'Stop', 'Continue')]
    [string]$OptionalErrorMode = 'Prompt',
    [ValidateSet('Prompt', 'Verify', 'Skip')]
    [string]$LocalPayloadHashSelection = 'Prompt',
    [string]$InitiatingUserSid = '',
    [string]$InitiatingUserProfile = '',
    [switch]$ElevatedHost,
    [string]$SessionId = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:InstallerConfigPathWasExplicit =
    -not [string]::IsNullOrWhiteSpace($ConfigPath)
$script:InstallerSessionIdWasExplicit =
    -not [string]::IsNullOrWhiteSpace($SessionId)
$script:InstallerJsonSupportsDateKind =
    (Get-Command ConvertFrom-Json -ErrorAction Stop).
        Parameters.ContainsKey('DateKind')
function ConvertFrom-InstallerJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Json
    )
    process {
        $parameters = @{
            InputObject = $Json
            ErrorAction = 'Stop'
        }
        if ($script:InstallerJsonSupportsDateKind) {
            $parameters.DateKind = 'String'
        }
        return ConvertFrom-Json @parameters
    }
}
function Resolve-InstallerSessionId {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value = '')
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [guid]::NewGuid().ToString('D')
    }
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact(
        $Value,
        'D',
        [ref]$parsed
    ) -or $parsed -eq [guid]::Empty) {
        throw [IO.InvalidDataException]::new(
            'Kurulum oturum kimligi gecersiz.'
        )
    }
    return $parsed.ToString('D')
}
$SessionId = Resolve-InstallerSessionId -Value $SessionId
$script:InstallerPackageRoot = [IO.Path]::GetFullPath($PSScriptRoot)
try {
    $Host.UI.RawUI.BackgroundColor = [ConsoleColor]::Black
    $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::White
    [Console]::BackgroundColor = [ConsoleColor]::Black
    [Console]::ForegroundColor = [ConsoleColor]::White
}
catch {
}
$script:InstallerUIAvailable = $false
try {
    Import-Module (Join-Path $PSScriptRoot `
        'Modules\UI\ConsoleUI.psm1') -Force -ErrorAction Stop
    $script:InstallerUIAvailable = $true
    if ($ElevatedHost -and -not $ValidateOnly) {
        Initialize-WinlamaConsole -ClearBuffer
    }
}
catch {
    Write-Verbose ('Konsol UI modulu yuklenemedi: {0}' -f `
        $_.Exception.Message)
}
function Get-InstallerBootstrapText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Fallback,
        [object[]]$Arguments = @()
    )
    $command = Get-Command Get-WinlamaUIString `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return & $command -Key $Key -Fallback $Fallback `
            -Arguments $Arguments
    }
    if ($Arguments.Count -eq 0) {
        return $Fallback
    }
    return [string]::Format(
        [Globalization.CultureInfo]::CurrentCulture,
        $Fallback,
        $Arguments
    )
}
function Write-InstallerBootstrapLine {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ConsoleColor]$Color = 'White'
    )
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
                $remaining.Substring($length).TrimStart()
            }
        } while ($remaining.Length -gt 0)
    }
}
function Get-InstallerBootstrapStatusStyle {
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
function Get-InstallerBootstrapStatusWidth {
    $width = 0
    foreach ($level in @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    )) {
        $style = Get-InstallerBootstrapStatusStyle -Level $level
        $width = [Math]::Max($width, $style.Label.Length)
    }
    return $width
}
function Write-InstallerBootstrapSegment {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ConsoleColor]$Color,
        [switch]$NoNewline
    )
    if ($NoNewline) {
        $Host.UI.Write($Color, [ConsoleColor]::Black, $Text)
        return
    }
    $Host.UI.WriteLine($Color, [ConsoleColor]::Black, $Text)
}
function Write-InstallerBootstrapStatus {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL',
            'SKIP'
        )]
        [string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    if ($script:InstallerUIAvailable) {
        Write-WinlamaUIStatus -Level $Level -Message $Message
        return
    }
    $style = Get-InstallerBootstrapStatusStyle -Level $Level
    $width = Get-InstallerBootstrapStatusWidth
    $left = [Math]::Floor(($width - $style.Label.Length) / 2)
    $label = ((' ' * $left) + $style.Label).PadRight($width)
    $messageWidth = 96 - $width - 3
    foreach ($logicalLine in [regex]::Split($Message, '\r\n|\n|\r')) {
        $remaining = $logicalLine.TrimStart()
        $lineLabel = $label
        do {
            $length = [Math]::Min($messageWidth, $remaining.Length)
            $part = $remaining.Substring(0, $length)
            Write-InstallerBootstrapSegment -Text '| ' -Color Gray `
                -NoNewline
            Write-InstallerBootstrapSegment -Text $lineLabel `
                -Color $style.Color -NoNewline
            Write-InstallerBootstrapSegment -Text ' | ' -Color Gray `
                -NoNewline
            Write-InstallerBootstrapSegment `
                -Text $part.PadRight($messageWidth) -Color White `
                -NoNewline
            Write-InstallerBootstrapSegment -Text ' |' -Color Gray
            $lineLabel = ' ' * $width
            $remaining = if ($remaining.Length -le $length) {
                ''
            }
            else {
                $remaining.Substring($length).TrimStart()
            }
        } while ($remaining.Length -gt 0)
    }
}
function Format-InstallerBootstrapInputLine {
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
function ConvertFrom-InstallerBootstrapReadValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    if ($null -eq $Value) {
        throw [IO.EndOfStreamException]::new(
            'Standart girdi kapali; zorunlu komut okunamadi.'
        )
    }
    return [string]$Value
}
function Test-InstallerBootstrapExactExit {
    param([AllowNull()][string]$Value)
    return $null -ne $Value -and $Value -ceq 'CIKIS'
}
function Assert-InstallerBootstrapInputContracts {
    $eofRejected = $false
    try {
        $null = ConvertFrom-InstallerBootstrapReadValue -Value $null
    }
    catch [IO.EndOfStreamException] {
        $eofRejected = $true
    }
    if (-not $eofRejected -or
        (ConvertFrom-InstallerBootstrapReadValue -Value '') -cne '') {
        throw 'Kurulum bootstrap EOF girdi sozlesmesi gecersiz.'
    }
    foreach ($invalid in @('', 'C', 'cikis', 'Cikis', ' CIKIS ')) {
        if (Test-InstallerBootstrapExactExit -Value $invalid) {
            throw 'Kurulum bootstrap kesin CIKIS sozlesmesi gecersiz.'
        }
    }
    if (-not (Test-InstallerBootstrapExactExit -Value 'CIKIS')) {
        throw 'Kurulum bootstrap kesin CIKIS sozlesmesi gecersiz.'
    }
    $statusSource = (Get-Command Write-InstallerBootstrapStatus `
        -ErrorAction Stop).Definition
    if (-not $statusSource.Contains('-Text $lineLabel') -or
        -not $statusSource.Contains('-Color $style.Color') -or
        -not $statusSource.Contains(
            '-Text $part.PadRight($messageWidth) -Color White'
        )) {
        throw 'Kurulum bootstrap renk segmenti sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Install.BootstrapEOF'
    Write-Verbose 'WINLAMA_UI_OK:Install.BootstrapExactExit'
    Write-Verbose 'WINLAMA_UI_OK:Install.BootstrapSegmentedColor'
    return $true
}
function Read-InstallerBootstrapRawInput {
    if ([Console]::IsInputRedirected) {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-InstallerBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-InstallerBootstrapInputLine -Value $value))
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
                (Format-InstallerBootstrapInputLine -Value $value))
            [Console]::SetCursorPosition(
                [Math]::Min(98, 13 + $display.Length), $row)
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                break
            }
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($buffer.Length -gt 0) {
                    $buffer.Length--
                }
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
            (Format-InstallerBootstrapInputLine -Value $value))
        return $value
    }
    catch {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-InstallerBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-InstallerBootstrapInputLine -Value $value))
        return $value
    }
}
function Write-InstallerBootstrapError {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$Record)
    $context = Get-InstallerBootstrapText `
        -Key 'Installer.Operation.FailedContext' `
        -Fallback 'Kurulum basarisiz.'
    if ($script:InstallerUIAvailable -and
        $null -ne (Get-Command Write-WinlamaUIError `
            -ErrorAction SilentlyContinue)) {
        Write-WinlamaUIError -Context $context `
            -ErrorRecord $Record
        return
    }
    $rule = '=' * 100
    $Host.UI.WriteLine(
        [ConsoleColor]::Red,
        [ConsoleColor]::Black,
        $rule
    )
    Write-InstallerBootstrapLine -Text 'ISLEM OZETI' -Color Cyan
    Write-InstallerBootstrapStatus -Level ERROR `
        -Message $context
    Write-InstallerBootstrapStatus -Level ERROR `
        -Message $Record.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace(
        $Record.InvocationInfo.PositionMessage
    )) {
        Write-InstallerBootstrapStatus -Level DETAIL `
            -Message $Record.InvocationInfo.PositionMessage.Trim()
    }
    $Host.UI.WriteLine(
        [ConsoleColor]::Red,
        [ConsoleColor]::Black,
        $rule
    )
}
try {
    $host.UI.RawUI.WindowTitle = 'Winlama - Kurulum'
}
catch {
    Write-Verbose ('Pencere basligi ayarlanamadi: {0}' -f `
        $_.Exception.Message)
}
trap {
    Write-InstallerBootstrapError -Record $_
    if (-not $ValidateOnly -and -not $NoPause) {
        if ($script:InstallerUIAvailable) {
            Complete-WinlamaUIOperation `
                -Summary (Get-InstallerBootstrapText `
                    -Key 'Installer.Operation.UnexpectedFailure' `
                    -Fallback 'Kurulum beklenmeyen bir hatayla durdu.') `
                -Level ERROR -Command CIKIS
        }
        else {
            do {
                Write-InstallerBootstrapStatus -Level INFO `
                    -Message 'Oturumu kapatmak icin CIKIS yazin.'
                Write-InstallerBootstrapStatus -Level DETAIL `
                    -Message 'Yalniz tam olarak CIKIS yazin.'
                $Host.UI.WriteLine([ConsoleColor]::Cyan,
                    [ConsoleColor]::Black, ('-' * 100))
                $answer = Read-InstallerBootstrapRawInput
                $Host.UI.WriteLine([ConsoleColor]::Cyan,
                    [ConsoleColor]::Black, ('-' * 100))
                if (-not (Test-InstallerBootstrapExactExit -Value $answer)) {
                    Write-InstallerBootstrapStatus -Level WARN `
                        -Message 'Bos veya gecersiz komut kabul edilmedi.'
                }
            } while (-not (Test-InstallerBootstrapExactExit -Value $answer))
        }
    }
    exit 1
}
function Resolve-InstallerConfigPath {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables($Path)
        )
    }
    foreach ($cand in @(
        (Join-Path $PSScriptRoot 'Data\Configs\config.json'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Winlama\Data\Configs\config.json')
    )) {
        if (Test-Path -LiteralPath $cand -PathType Leaf) {
            return [IO.Path]::GetFullPath($cand)
        }
    }
    $targetPath = Join-Path $PSScriptRoot 'Data\Configs\config.json'
    return [IO.Path]::GetFullPath($targetPath)
}
$ConfigPath = Resolve-InstallerConfigPath -Path $ConfigPath
$script:InstallerConfiguration = $null
$script:InstallerLogPath = $null
$localizationModule = Join-Path $PSScriptRoot `
    'Modules\Localization\LocalizationManager.psm1'
if (Test-Path -LiteralPath $localizationModule -PathType Leaf) {
    try {
        Import-Module $localizationModule -Force -ErrorAction Stop
        $localizationConfig = $null
        if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
            $script:InstallerConfiguration = Get-Content `
                -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
                ConvertFrom-InstallerJson
            $localizationConfig = `
                $script:InstallerConfiguration.Localization
        }
        $null = Initialize-Localization -ProjectRoot $PSScriptRoot `
            -Configuration $localizationConfig
        try {
            $host.UI.RawUI.WindowTitle = Get-LocalizedText `
                -Key 'Installer.WindowTitle'
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
Import-Module (Join-Path $PSScriptRoot `
    'Modules\00_Common.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot `
    'Modules\10_Runtime.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot `
    'Modules\UI\ConsoleUI.psm1') -Force -ErrorAction Stop
$script:InstallerUIAvailable = $true
function Assert-InstallerResumeConfigHandoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$ResumeRequested,
        [Parameter(Mandatory)][bool]$ConfigPathWasExplicit,
        [AllowEmptyString()][string]$RequestedConfigPath = ''
    )
    if (-not $ResumeRequested) {
        return
    }
    if (-not $ConfigPathWasExplicit -or
        [string]::IsNullOrWhiteSpace($RequestedConfigPath) -or
        -not (Test-Path -LiteralPath $RequestedConfigPath -PathType Leaf)) {
        throw [IO.InvalidDataException]::new(
            (Get-InstallerBootstrapText `
                -Key 'Installer.Error.ResumeConfigRequired' `
                -Fallback ('Resume icin onceki etkin config ' +
                    'dosyasinin yolu -ConfigPath ile verilmelidir.'))
        )
    }
}
Assert-InstallerResumeConfigHandoff `
    -ResumeRequested ([bool]$Resume) `
    -ConfigPathWasExplicit $script:InstallerConfigPathWasExplicit `
    -RequestedConfigPath $ConfigPath
if ($Resume -and -not $script:InstallerSessionIdWasExplicit -and
    $null -ne $script:InstallerConfiguration) {
    $installation = $script:InstallerConfiguration.PSObject.Properties[
        'Installation'
    ]
    if ($null -ne $installation -and $null -ne $installation.Value) {
        $savedSession = $installation.Value.PSObject.Properties['SessionId']
        if ($null -ne $savedSession -and
            -not [string]::IsNullOrWhiteSpace([string]$savedSession.Value)) {
            $SessionId = Resolve-InstallerSessionId `
                -Value ([string]$savedSession.Value)
        }
    }
}
function Resolve-InstallerPath {
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $PSScriptRoot $expanded
    }
    return [IO.Path]::GetFullPath($expanded)
}
function Resolve-InstallerDeploymentPath {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$Path
    )
    $root = Resolve-InstallerPath -Path ([string]$Config.Paths.Root)
    return Resolve-ConfigurationPath -Path $Path -BasePath $root
}
function Get-InstallerLogDirectory {
    param([AllowNull()][pscustomobject]$Configuration)
    if ($null -eq $Configuration) {
        return Join-Path ([IO.Path]::GetTempPath()) 'Winlama-Logs'
    }
    return Resolve-InstallerDeploymentPath -Config $Configuration `
        -Path ([string]$Configuration.Paths.Logs)
}
function Set-InstallerLogPathForDirectory {
    param([Parameter(Mandatory)][string]$Directory)
    $resolvedDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $currentDirectory = if ([string]::IsNullOrWhiteSpace(
        $script:InstallerLogPath
    )) {
        ''
    }
    else {
        [IO.Path]::GetFullPath(
            (Split-Path -Parent $script:InstallerLogPath)
        ).TrimEnd('\')
    }
    if (-not $currentDirectory.Equals(
        $resolvedDirectory,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        $script:InstallerLogPath = New-WinlamaTimestampedFile `
            -Directory $resolvedDirectory -Extension '.log'
    }
}
function Assert-InstallerDiagnosticPathContracts {
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
        'Winlama-Installed-Fixture'
    $fixture = [pscustomobject]@{
        Paths = [pscustomobject]@{
            Root = $fixtureRoot
            Logs = 'Logs'
            State = 'Data\state.json'
        }
    }
    $logs = Get-InstallerLogDirectory -Configuration $fixture
    $state = Resolve-InstallerDeploymentPath -Config $fixture `
        -Path ([string]$fixture.Paths.State)
    $temporaryLogs = Get-InstallerLogDirectory -Configuration $null
    if ($logs -ine (Join-Path $fixtureRoot 'Logs') -or
        $state -ine (Join-Path $fixtureRoot 'Data\state.json') -or
        $temporaryLogs -ine (Join-Path ([IO.Path]::GetTempPath()) `
            'Winlama-Logs') -or
        $temporaryLogs -ieq (Join-Path $PSScriptRoot 'Logs')) {
        throw 'Installer log ve state kok sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Installer.DiagnosticPaths'
    return $true
}
function Resolve-InstallerContainedPackagePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [scriptblock]$ReparseProbe
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match ':' -or
        $RelativePath -match '(^|[\\/])\.\.?([\\/]|$)' -or
        $RelativePath -match '[\\/]$') {
        throw [IO.InvalidDataException]::new(
            "Gecersiz paket yolu: $RelativePath"
        )
    }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $prefix = $rootPath
    if (-not $prefix.EndsWith(
        [IO.Path]::DirectorySeparatorChar.ToString(),
        [StringComparison]::Ordinal
    )) {
        $prefix += [IO.Path]::DirectorySeparatorChar
    }
    $path = [IO.Path]::GetFullPath(
        (Join-Path $rootPath $RelativePath)
    )
    if (-not $path.StartsWith(
        $prefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw [IO.InvalidDataException]::new(
            "Paket yolu kok disina cikiyor: $RelativePath"
        )
    }
    $safe = if ($null -eq $ReparseProbe) {
        Test-InstallerComfyUIReparseChain -Path $path
    }
    else {
        Test-InstallerComfyUIReparseChain -Path $path `
            -ReparseProbe $ReparseProbe
    }
    if (-not $safe) {
        throw [IO.InvalidDataException]::new(
            "Paket yolu reparse noktasi iceriyor: $RelativePath"
        )
    }
    return $path
}
function Test-InstallerPackageTreeReparseFree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    try {
        if (-not (Test-Path -LiteralPath $Root -PathType Container) -or
            -not (Test-InstallerComfyUIReparseChain -Path $Root)) {
            return $false
        }
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push([IO.Path]::GetFullPath($Root))
        while ($pending.Count -gt 0) {
            $current = $pending.Pop()
            foreach ($item in Get-ChildItem -LiteralPath $current `
                -Force -ErrorAction Stop) {
                if (($item.Attributes -band `
                    [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return $false
                }
                if ($item.PSIsContainer) {
                    $pending.Push($item.FullName)
                }
            }
        }
        return $true
    }
    catch {
        return $false
    }
}
function Get-InstallerReparseSafeTreeFiles {
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyCollection()][string[]]$ExcludedRelativeDirectories = @(),
        [AllowEmptyCollection()][string[]]$ExcludedDirectoryNames = @(),
        [AllowEmptyString()][string]$ProgressPhase = '',
        [ValidateRange(1, 300)]
        [int]$ProgressIntervalSeconds = 15
    )
    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    $trimmedRoot = $resolvedRoot.TrimEnd('\')
    $excluded = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($relativeDirectory in $ExcludedRelativeDirectories) {
        $normalized = ([string]$relativeDirectory).Replace('/', '\').
            Trim('\')
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            $null = $excluded.Add($normalized)
        }
    }
    $excludedNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($directoryName in $ExcludedDirectoryNames) {
        $normalized = ([string]$directoryName).Trim()
        if (-not [string]::IsNullOrWhiteSpace($normalized) -and
            $normalized.IndexOfAny([char[]]'\/') -lt 0) {
            $null = $excludedNames.Add($normalized)
        }
    }
    if (-not (Test-Path -LiteralPath $resolvedRoot `
        -PathType Container) -or
        -not (Test-InstallerComfyUIReparseChain -Path $resolvedRoot)) {
        throw [IO.InvalidDataException]::new(
            "Paket agaci guvenli degil: $resolvedRoot"
        )
    }
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $directoryCount = 0
    $fileCount = 0
    $byteCount = 0L
    $progressClock = [Diagnostics.Stopwatch]::StartNew()
    if (-not [string]::IsNullOrWhiteSpace($ProgressPhase)) {
        Write-InstallerLog -Level INFO `
            -Message 'Installer.ComfyUI.TreeScan.Starting' `
            -MessageArguments @($ProgressPhase)
    }
    $pending.Push($resolvedRoot)
    while ($pending.Count -gt 0) {
        $currentDirectory = $pending.Pop()
        $directoryCount++
        foreach ($item in Get-ChildItem -LiteralPath $currentDirectory `
            -Force -ErrorAction Stop) {
            if (($item.Attributes -band `
                    [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw [IO.InvalidDataException]::new(
                    "Paket agaci reparse noktasi iceriyor: $($item.FullName)"
                )
            }
            if ($item.PSIsContainer) {
                $relativeDirectory = $item.FullName.
                    Substring($trimmedRoot.Length).TrimStart('\')
                if ($excluded.Contains($relativeDirectory) -or
                    $excludedNames.Contains($item.Name)) {
                    continue
                }
                $pending.Push($item.FullName)
            }
            else {
                $files.Add($item)
                $fileCount++
                $byteCount += [long]$item.Length
            }
            if (-not [string]::IsNullOrWhiteSpace($ProgressPhase) -and
                $progressClock.Elapsed.TotalSeconds -ge
                    $ProgressIntervalSeconds) {
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.ComfyUI.TreeScan.Progress' `
                    -MessageArguments @(
                        $ProgressPhase,
                        $directoryCount,
                        $fileCount,
                        ($byteCount / 1GB)
                    )
                $progressClock.Restart()
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ProgressPhase)) {
        Write-InstallerLog -Level INFO `
            -Message 'Installer.ComfyUI.TreeScan.Completed' `
            -MessageArguments @(
                $ProgressPhase,
                $directoryCount,
                $fileCount,
                ($byteCount / 1GB)
            )
    }
    return $files.ToArray()
}
function Test-InstallerRuntimePackageRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [bool]$AllowDeploymentArtifacts = $false
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match ':' -or
        $RelativePath -match '(^|[\\/])\.\.?([\\/]|$)') {
        return $false
    }
    if ($RelativePath -match `
        '(^|[\\/])__pycache__([\\/]|$)') {
        return $AllowDeploymentArtifacts
    }
    $normalized = $RelativePath.Replace('/', '\')
    if ($normalized -ieq
            'ComfyUI\ComfyUI\extra_model_paths.yaml' -or
        [IO.Path]::GetExtension($normalized) -iin @('.pyc', '.pyo')) {
        return $AllowDeploymentArtifacts
    }
    return $true
}
function Test-InstallerRuntimePackageCleanliness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [bool]$AllowDeploymentArtifacts = $false,
        [ref]$RejectedPath
    )
    if ($null -ne $RejectedPath) {
        $RejectedPath.Value = ''
    }
    try {
        $root = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            if ($null -ne $RejectedPath) {
                $RejectedPath.Value = '[RUNTIME BULUNAMADI]'
            }
            return $false
        }
        foreach ($item in Get-ChildItem -LiteralPath $root -Recurse `
            -Force -ErrorAction Stop) {
            $relativePath = $item.FullName.Substring($root.Length + 1)
            if (-not (Test-InstallerRuntimePackageRelativePath `
                -RelativePath $relativePath `
                -AllowDeploymentArtifacts $AllowDeploymentArtifacts)) {
                if ($null -ne $RejectedPath) {
                    $RejectedPath.Value = $relativePath
                }
                return $false
            }
        }
        return $true
    }
    catch {
        if ($null -ne $RejectedPath) {
            $RejectedPath.Value = '[RUNTIME DENETIM HATASI] ' +
                $_.Exception.Message
        }
        return $false
    }
}
function Assert-InstallerLocalPayloadTree {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [switch]$FullTreeAudit,
        [bool]$AllowDeploymentArtifacts = $false,
        [scriptblock]$TreeReparseTester,
        [scriptblock]$RuntimeCleanlinessTester
    )
    $path = Resolve-InstallerContainedPackagePath `
        -Root $Root -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Yerel kaynak klasoru eksik: $RelativePath"
    }
    if (-not $FullTreeAudit) {
        return $path
    }
    $treeSafe = if ($null -ne $TreeReparseTester) {
        [bool](& $TreeReparseTester -Root $path)
    }
    else {
        Test-InstallerPackageTreeReparseFree -Root $path
    }
    if (-not $treeSafe) {
        throw "Paket agaci reparse iceriyor: $RelativePath"
    }
    if ($RelativePath -ine 'Runtime') {
        return $path
    }
    $rejectedPath = ''
    $clean = if ($null -ne $RuntimeCleanlinessTester) {
        [bool](& $RuntimeCleanlinessTester -RuntimeRoot $path `
            -AllowDeploymentArtifacts $AllowDeploymentArtifacts `
            -RejectedPath ([ref]$rejectedPath))
    }
    else {
        Test-InstallerRuntimePackageCleanliness -RuntimeRoot $path `
            -AllowDeploymentArtifacts $AllowDeploymentArtifacts `
            -RejectedPath ([ref]$rejectedPath)
    }
    if (-not $clean) {
        throw ('Runtime paket temizligi dogrulanamadi: ' +
            $rejectedPath)
    }
    return $path
}
function Assert-InstallerRuntimePackageCleanlinessContracts {
    foreach ($relativePath in @(
        '__pycache__',
        'ComfyUI\__pycache__\fixture.py',
        'python_embeded\Lib\fixture.pyc',
        'python_embeded\Lib\fixture.PYO',
        'ComfyUI\ComfyUI\extra_model_paths.yaml'
    )) {
        if (Test-InstallerRuntimePackageRelativePath `
            -RelativePath $relativePath) {
            throw "Kirli Runtime yolu kabul edildi: $relativePath"
        }
        if (-not (Test-InstallerRuntimePackageRelativePath `
            -RelativePath $relativePath `
            -AllowDeploymentArtifacts $true)) {
            throw "Kurulu Runtime artigi reddedildi: $relativePath"
        }
    }
    foreach ($relativePath in @(
        '..\escape.pyc',
        'C:\escape.pyc'
    )) {
        if (Test-InstallerRuntimePackageRelativePath `
            -RelativePath $relativePath `
            -AllowDeploymentArtifacts $true) {
            throw "Guvenli olmayan Runtime yolu kabul edildi: $relativePath"
        }
    }
    foreach ($relativePath in @(
        'ComfyUI\ComfyUI\tests\execution\extra_model_paths.yaml',
        'ComfyUI\python_embeded\python313.zip',
        'ComfyUI\wheelhouse\fixture.tar.gz',
        ('ComfyUI\python_embeded\Lib\site-packages\torch\_inductor\' +
            'autoheuristic\artifacts\fixture.json')
    )) {
        if (-not (Test-InstallerRuntimePackageRelativePath `
            -RelativePath $relativePath)) {
            throw "Gecerli Runtime yolu reddedildi: $relativePath"
        }
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.RuntimePackageCleanliness'
}
function Test-InstallerPackagePersistentRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [bool]$AllowDeploymentArtifacts = $false
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match ':' -or
        $RelativePath -match '(^|[\\/])\.\.?([\\/]|$)') {
        return $false
    }
    $normalized = $RelativePath.Replace('/', '\')
    $segments = @($normalized -split '\\')
    if ($segments[0] -iin @('Runtime', 'Models', '.git')) {
        return $true
    }
    if ($segments[0] -iin @('Logs', 'Reports')) {
        return $AllowDeploymentArtifacts
    }
    if ($segments[0] -iin @(
            'Artifacts', 'Guide', 'Guides', 'Rehber'
        ) -or
        $normalized -iin @(
            'Winlama-Rehberi.html', 'Winlama-Guide.html',
            'Rehber.html', 'Guide.html'
        ) -or
        [IO.Path]::GetExtension($normalized) -iin
            @('.7z', '.zip', '.rar')) {
        return $false
    }
    return $true
}
function Test-InstallerPackagePersistentCleanliness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [bool]$AllowDeploymentArtifacts = $false,
        [ref]$RejectedPath
    )
    if ($null -ne $RejectedPath) {
        $RejectedPath.Value = ''
    }
    try {
        $resolved = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $resolved `
            -PathType Container)) {
            if ($null -ne $RejectedPath) {
                $RejectedPath.Value = '[KOK BULUNAMADI]'
            }
            return $false
        }
        foreach ($topItem in Get-ChildItem -LiteralPath $resolved `
            -Force -ErrorAction Stop) {
            if (-not (Test-InstallerPackagePersistentRelativePath `
                -RelativePath $topItem.Name `
                -AllowDeploymentArtifacts $AllowDeploymentArtifacts)) {
                if ($null -ne $RejectedPath) {
                    $RejectedPath.Value = $topItem.Name
                }
                return $false
            }
        }
        return $true
    }
    catch {
        if ($null -ne $RejectedPath) {
            $RejectedPath.Value = '[DENETIM HATASI] ' +
                $_.Exception.Message
        }
        return $false
    }
}
function Assert-InstallerPackagePersistentCleanlinessContracts {
    foreach ($relativePath in @(
        'Winlama.7z',
        'Data\payload.ZIP',
        'Tools\payload.rar',
        'Logs\install.log',
        'Reports\summary.json',
        'Artifacts\payload.bin',
        'Guide\index.html',
        'Winlama-Rehberi.html'
    )) {
        if (Test-InstallerPackagePersistentRelativePath `
            -RelativePath $relativePath) {
            throw "Kalici paket artigi kabul edildi: $relativePath"
        }
    }
    foreach ($relativePath in @(
        'Logs\install.log',
        'Reports\summary.json'
    )) {
        if (-not (Test-InstallerPackagePersistentRelativePath `
            -RelativePath $relativePath `
            -AllowDeploymentArtifacts $true)) {
            throw "Kurulu hedef artigi reddedildi: $relativePath"
        }
    }
    foreach ($relativePath in @(
        'Artifacts\payload.bin',
        'Guide\index.html',
        'Winlama-Rehberi.html',
        'Winlama.7z'
    )) {
        if (Test-InstallerPackagePersistentRelativePath `
            -RelativePath $relativePath `
            -AllowDeploymentArtifacts $true) {
            throw "Kurulu hedefte paket artigi kabul edildi: $relativePath"
        }
    }
    foreach ($relativePath in @(
        'Runtime\ComfyUI\python_embeded\python313.zip',
        'Runtime\ComfyUI\wheelhouse\fixture.tar.gz',
        ('Runtime\ComfyUI\python_embeded\Lib\site-packages\torch\' +
            '_inductor\autoheuristic\artifacts\fixture.json'),
        'Models\ollama\blobs\fixture.zip',
        'README.md',
        'LICENSE'
    )) {
        if (-not (Test-InstallerPackagePersistentRelativePath `
            -RelativePath $relativePath)) {
            throw "Gecerli paket yolu reddedildi: $relativePath"
        }
    }
    $cleanlinessSource = (Get-Command `
        Test-InstallerPackagePersistentCleanliness `
        -ErrorAction Stop).Definition
    if ($cleanlinessSource -match '\b-Recurse\b' -or
        -not $cleanlinessSource.Contains('$topItem.Name')) {
        throw 'Bootstrap paket temizligi top-level kapsami gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.PackagePersistentCleanliness'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.PackagePersistentTopLevel'
}
function Get-InstallerDescriptorExpectedHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Descriptor)
    $offlineHash = $Descriptor.PSObject.Properties['OfflineSha256']
    if ($null -ne $offlineHash -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$offlineHash.Value
        )) {
        return [string]$offlineHash.Value
    }
    $hash = $Descriptor.PSObject.Properties['Sha256']
    if ($null -eq $hash) {
        return ''
    }
    return [string]$hash.Value
}
function Get-InstallerDescriptorPublisher {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Descriptor)
    foreach ($name in @('PublisherSubjectContains', 'Publisher')) {
        $property = $Descriptor.PSObject.Properties[$name]
        if ($null -ne $property -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$property.Value
            )) {
            return [string]$property.Value
        }
    }
    return ''
}
function Test-InstallerOfflineArtifactIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][pscustomobject]$Descriptor
    )
    try {
        $offlinePath = $Descriptor.PSObject.Properties['OfflinePath']
        if ($null -eq $offlinePath -or
            [string]::IsNullOrWhiteSpace(
                [string]$offlinePath.Value
            )) {
            return $false
        }
        $path = Resolve-InstallerContainedPackagePath -Root $Root `
            -RelativePath ([string]$offlinePath.Value)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        $expectedHash = Get-InstallerDescriptorExpectedHash `
            -Descriptor $Descriptor
        $publisher = Get-InstallerDescriptorPublisher `
            -Descriptor $Descriptor
        if ($item.Length -lt 1 -or
            $expectedHash -notmatch '^[a-fA-F0-9]{64}$' -or
            [string]::IsNullOrWhiteSpace($publisher) -or
            (Get-FileHash -LiteralPath $path `
                -Algorithm SHA256).Hash -ine $expectedHash) {
            return $false
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        return $signature.Status -eq 'Valid' -and
            $null -ne $signature.SignerCertificate -and
            ([string]$signature.SignerCertificate.Subject).IndexOf(
                $publisher,
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0
    }
    catch {
        Write-Verbose ('Offline kurucu kimligi dogrulanamadi: {0}' `
            -f $_.Exception.Message)
        return $false
    }
}
function Test-InstallerOllamaPackageMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][pscustomobject]$Metadata,
        [bool]$VerifyContentHash = $false
    )
    try {
        if ([string]$Metadata.Format -cne
                'ollama-portable-model' -or
            [int]$Metadata.FormatVersion -ne 1 -or
            [int]$Metadata.ManifestSchemaVersion -ne 2 -or
            [string]::IsNullOrWhiteSpace(
                [string]$Metadata.OllamaReference
            ) -or [string]::IsNullOrWhiteSpace(
                [string]$Metadata.ExactReference
            ) -or [string]$Metadata.ManifestSha256 -notmatch
                '^[a-fA-F0-9]{64}$') {
            return $false
        }
        $manifestRelative = 'manifests\' +
            ([string]$Metadata.ManifestRelativePath).Replace('/', '\')
        $manifestPath = Resolve-InstallerContainedPackagePath `
            -Root $PackagePath -RelativePath $manifestRelative
        if (-not (Test-Path -LiteralPath $manifestPath `
            -PathType Leaf) -or
            (Get-FileHash -LiteralPath $manifestPath `
                -Algorithm SHA256).Hash -ine
                [string]$Metadata.ManifestSha256) {
            return $false
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw `
            -Encoding UTF8 | ConvertFrom-InstallerJson
        $manifestEntries = @($manifest.config) + @($manifest.layers)
        $blobs = @($Metadata.Blobs)
        if ([int]$manifest.schemaVersion -ne 2 -or
            $manifestEntries.Count -eq 0 -or
            $manifestEntries.Count -ne $blobs.Count) {
            return $false
        }
        $metadataByDigest = @{}
        $totalSize = 0L
        foreach ($blob in $blobs) {
            $digest = [string]$blob.Digest
            $hash = $digest -replace '^sha256:', ''
            if ($digest -notmatch '^sha256:[a-fA-F0-9]{64}$' -or
                $metadataByDigest.ContainsKey($digest) -or
                [long]$blob.Size -lt 1) {
                return $false
            }
            $path = Resolve-InstallerContainedPackagePath `
                -Root $PackagePath `
                -RelativePath ([string]$blob.File).Replace('/', '\')
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return $false
            }
            $item = Get-Item -LiteralPath $path -Force `
                -ErrorAction Stop
            if ([IO.Path]::GetFileName($path) -cne "sha256-$hash" -or
                [long]$item.Length -ne [long]$blob.Size -or
                ($VerifyContentHash -and
                    (Get-InstallerFileSha256WithProgress `
                        -Path $path) -ine $hash)) {
                return $false
            }
            $metadataByDigest[$digest] = $blob
            $totalSize += [long]$blob.Size
        }
        foreach ($entry in $manifestEntries) {
            $digest = [string]$entry.digest
            if (-not $metadataByDigest.ContainsKey($digest)) {
                return $false
            }
            $blob = $metadataByDigest[$digest]
            if ([long]$entry.size -ne [long]$blob.Size -or
                [string]$entry.mediaType -cne
                    [string]$blob.MediaType) {
                return $false
            }
        }
        return $totalSize -eq [long]$Metadata.TotalSizeBytes
    }
    catch {
        Write-Verbose ('Ollama paket kimligi dogrulanamadi: {0}' `
            -f $_.Exception.Message)
        return $false
    }
}
function Test-InstallerRequestedOllamaPackageIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [bool]$VerifyContentHash = $false,
        [scriptblock]$PathProbe,
        [scriptblock]$ReparseProbe,
        [scriptblock]$MetadataReader,
        [scriptblock]$MetadataTester
    )
    try {
        $requested = @($Config.Models.Requested | ForEach-Object {
            [string]$_
        })
        if ($requested.Count -eq 0 -or
            @($requested | Sort-Object -Unique).Count -ne
                $requested.Count) {
            return $false
        }
        $modelsRoot = Resolve-InstallerContainedPackagePath `
            -Root $Root -RelativePath 'Models' `
            -ReparseProbe $ReparseProbe
        $testPath = {
            param([string]$Path, [string]$PathType)
            if ($null -ne $PathProbe) {
                return [bool](& $PathProbe -Path $Path `
                    -PathType $PathType)
            }
            return Test-Path -LiteralPath $Path -PathType $PathType
        }.GetNewClosure()
        if (-not (& $testPath $modelsRoot 'Container')) {
            return $false
        }
        $selectedPackages = @(
            $Config.Models.LocalPackageImport.SelectedPackages |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_)
                }
        )
        if ($selectedPackages.Count -ne $requested.Count) {
            return $false
        }
        $modelsPrefix = $modelsRoot.TrimEnd('\') + '\'
        $packagesByName = @{}
        foreach ($selectedPackage in $selectedPackages) {
            $packagePath = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables(
                    [string]$selectedPackage
                )
            ).TrimEnd('\')
            if (-not $packagePath.StartsWith(
                    $modelsPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or -not (& $testPath $packagePath 'Container')) {
                return $false
            }
            $reparseSafe = if ($null -ne $ReparseProbe) {
                Test-InstallerComfyUIReparseChain -Path $packagePath `
                    -ReparseProbe $ReparseProbe
            }
            else {
                Test-InstallerComfyUIReparseChain -Path $packagePath
            }
            if (-not $reparseSafe) {
                return $false
            }
            $metadataPath = Join-Path $packagePath 'package.json'
            $metadataReparseSafe = if ($null -ne $ReparseProbe) {
                Test-InstallerComfyUIReparseChain -Path $metadataPath `
                    -ReparseProbe $ReparseProbe
            }
            else {
                Test-InstallerComfyUIReparseChain -Path $metadataPath
            }
            if (-not (& $testPath $metadataPath 'Leaf') -or
                -not $metadataReparseSafe) {
                return $false
            }
            $metadata = if ($null -ne $MetadataReader) {
                & $MetadataReader -Path $metadataPath
            }
            else {
                Get-Content -LiteralPath $metadataPath -Raw `
                    -Encoding UTF8 | ConvertFrom-InstallerJson
            }
            $name = [string]$metadata.OllamaReference
            if ([string]::IsNullOrWhiteSpace($name)) {
                return $false
            }
            if ($packagesByName.ContainsKey($name)) {
                return $false
            }
            $packagesByName[$name] = [pscustomobject]@{
                Path = $packagePath
                Metadata = $metadata
            }
        }
        foreach ($name in $requested) {
            if (-not $packagesByName.ContainsKey($name)) {
                return $false
            }
            $package = $packagesByName[$name]
            $valid = if ($null -ne $MetadataTester) {
                [bool](& $MetadataTester `
                    -PackagePath $package.Path `
                    -Metadata $package.Metadata `
                    -VerifyContentHash $VerifyContentHash)
            }
            else {
                Test-InstallerOllamaPackageMetadata `
                    -PackagePath $package.Path `
                    -Metadata $package.Metadata `
                    -VerifyContentHash $VerifyContentHash
            }
            if (-not $valid) {
                return $false
            }
        }
        return $true
    }
    catch {
        Write-Verbose ('Istenen Ollama paketi dogrulanamadi: {0}' `
            -f $_.Exception.Message)
        return $false
    }
}
function Test-InstallerRequestedComfyModelIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [bool]$VerifyContentHash = $false
    )
    try {
        $requested = @($Config.ComfyUI.Requested | ForEach-Object {
            [string]$_
        })
        if ($requested.Count -eq 0 -or
            @($requested | Sort-Object -Unique).Count -ne
                $requested.Count) {
            return $false
        }
        $modelsRoot = Resolve-InstallerContainedPackagePath `
            -Root $Root -RelativePath 'Models'
        foreach ($name in $requested) {
            $matches = @($Config.ComfyUI.Catalog | Where-Object {
                [string]$_.Name -ceq $name
            })
            if ($matches.Count -ne 1 -or
                @($matches[0].Assets).Count -eq 0) {
                return $false
            }
            $seenPaths = `
                [Collections.Generic.HashSet[string]]::new(
                    [StringComparer]::OrdinalIgnoreCase
                )
            foreach ($asset in @($matches[0].Assets)) {
                $relativePath = [string]$asset.RelativePath
                $expectedHash = [string]$asset.Sha256
                if (-not $seenPaths.Add($relativePath) -or
                    $expectedHash -notmatch '^[a-fA-F0-9]{64}$' -or
                    [double]$asset.SizeGB -le 0) {
                    return $false
                }
                $path = Resolve-InstallerContainedPackagePath `
                    -Root $modelsRoot -RelativePath $relativePath
                if (-not (Test-Path -LiteralPath $path `
                    -PathType Leaf)) {
                    return $false
                }
                $item = Get-Item -LiteralPath $path -Force `
                    -ErrorAction Stop
                if (-not (Test-InstallerComfyUIAssetSize `
                        -Item $item -Asset $asset) -or
                    ($VerifyContentHash -and
                        (Get-InstallerFileSha256WithProgress `
                            -Path $path) -ine
                            $expectedHash)) {
                    return $false
                }
            }
        }
        return $true
    }
    catch {
        Write-Verbose ('Istenen ComfyUI modeli dogrulanamadi: {0}' `
            -f $_.Exception.Message)
        return $false
    }
}
function Test-InstallerPackageRootBootstrapIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [ref]$FailureReason
    )
    if ($null -ne $FailureReason) {
        $FailureReason.Value = ''
    }
    try {
        $resolved = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        $deploymentRoot = Resolve-InstallerPath `
            -Path ([string]$Config.Paths.Root)
        $allowDeploymentArtifacts = $resolved.Equals(
            $deploymentRoot.TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )
        if (-not (Test-Path -LiteralPath $resolved `
            -PathType Container)) {
            throw "Paket kok klasoru bulunamadi: $resolved"
        }
        if (-not (Test-InstallerComfyUIReparseChain -Path $resolved)) {
            throw "Paket kok reparse zinciri guvenli degil: $resolved"
        }
        $rejectedPath = ''
        if (-not (Test-InstallerPackagePersistentCleanliness `
            -Root $resolved `
            -AllowDeploymentArtifacts $allowDeploymentArtifacts `
            -RejectedPath ([ref]$rejectedPath))) {
            throw "Paket kokunde reddedilen oge: $rejectedPath"
        }
        $operationalFiles = @(
            Assert-ApplicationSourcePayload -SourceRoot $resolved
        )
        if ($operationalFiles.Count -ne 43) {
            throw ('Operasyonel payload dosya sayisi gecersiz: ' +
                $operationalFiles.Count)
        }
        $packageConfig = Get-Content -LiteralPath (Join-Path $resolved `
            'Data\Configs\config.json') -Raw -Encoding UTF8 |
            ConvertFrom-InstallerJson
        $null = Test-DeploymentConfiguration -Config $packageConfig
        if ([string]$packageConfig.ProjectName -cne
                [string]$Config.ProjectName -or
            [string]$packageConfig.EngineVersion -cne
                [string]$Config.EngineVersion) {
            throw 'Paket config kimligi gecersiz.'
        }
        return $true
    }
    catch {
        if ($null -ne $FailureReason) {
            $FailureReason.Value = $_.Exception.Message
        }
        Write-Verbose ('Hizli paket koku dogrulanamadi: {0} | {1}' -f `
            $Root, $_.Exception.Message)
        return $false
    }
}
function Test-InstallerPackageRootIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [bool]$VerifyModelContentHash = $false,
        [switch]$RequireSelfContainedLocalPayload,
        [ref]$FailureReason,
        [scriptblock]$ComfyRuntimeStateReader,
        [scriptblock]$MissingComfyModelsReader,
        [scriptblock]$ComfyRequirementsStateReader,
        [scriptblock]$ComfyAvailabilityReader
    )
    if ($null -ne $FailureReason) {
        $FailureReason.Value = ''
    }
    try {
        $bootstrapFailure = ''
        if (-not (Test-InstallerPackageRootBootstrapIdentity `
            -Root $Root -Config $Config `
            -FailureReason ([ref]$bootstrapFailure))) {
            throw $bootstrapFailure
        }
        $resolved = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        $deploymentRoot = Resolve-InstallerPath `
            -Path ([string]$Config.Paths.Root)
        $allowDeploymentArtifacts = $resolved.Equals(
            $deploymentRoot.TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )
        $localDescriptors = [Collections.Generic.List[object]]::new()
        $powerShellSource = $Config.Bootstrap.PowerShell.PSObject.
            Properties['InstallSource']
        if ($null -ne $powerShellSource -and
            [string]$powerShellSource.Value -ceq 'Local') {
            $localDescriptors.Add($Config.Bootstrap.PowerShell)
        }
        foreach ($descriptor in @($Config.Dependencies)) {
            $source = $descriptor.PSObject.Properties['InstallSource']
            if ([bool]$descriptor.Required -and $null -ne $source -and
                [string]$source.Value -ceq 'Local') {
                $localDescriptors.Add($descriptor)
            }
        }
        $modelSource = $Config.Models.PSObject.Properties[
            'InstallSource'
        ]
        $selectedPackages = @(
            $Config.Models.LocalPackageImport.SelectedPackages |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_)
                }
        )
        $localModels = $null -ne $modelSource -and
            [string]$modelSource.Value -ceq 'Local'
        if ($localModels -and $selectedPackages.Count -eq 0) {
            throw 'Yerel Ollama model paket secimi bos.'
        }
        $comfySource = $Config.ComfyUI.PSObject.Properties[
            'InstallSource'
        ]
        $localComfy = [bool]$Config.ComfyUI.Enabled -and
            $null -ne $comfySource -and
            [string]$comfySource.Value -ceq 'Local'
        $requestedComfyNames = @($Config.ComfyUI.Requested |
            ForEach-Object { [string]$_ } | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            })
        $nodeRequestProperty = $Config.ComfyUI.PSObject.Properties[
            'PendingRequiredNodeModels'
        ]
        $requiredComfyNodeNames = @(if ($null -ne
            $nodeRequestProperty) {
            $nodeRequestProperty.Value |
                ForEach-Object { [string]$_ } |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                }
        }
        else {
            $requestedComfyNames
        })
        $requestedComfyModels = @(Get-InstallerComfyUICatalog `
            -Config $Config -ProjectRoot $resolved | Where-Object {
                [string]$_.Name -iin $requestedComfyNames
            })
        if ($localComfy -and
            $requestedComfyModels.Count -ne $requestedComfyNames.Count) {
            throw 'Istenen yerel ComfyUI model katalogu gecersiz.'
        }
        $missingComfyModels = @()
        $comfyNodePayloadRequired = $false
        $localComfyRuntimeRequired = $localComfy
        if ($localComfy -and -not $RequireSelfContainedLocalPayload) {
            $comfyDestination = Resolve-InstallerDeploymentPath `
                -Config $Config -Path ([string]$Config.ComfyUI.InstallPath)
            $destinationState = if ($null -ne
                $ComfyRuntimeStateReader) {
                & $ComfyRuntimeStateReader `
                    -Path $comfyDestination `
                    -Config $Config `
                    -VerifyIdentity $VerifyModelContentHash
            }
            else {
                Get-InstallerComfyUIRuntimeState `
                    -Path $comfyDestination -Config $Config `
                    -VerifyIdentity $VerifyModelContentHash
            }
            $localComfyRuntimeRequired = -not [bool]$destinationState.Ready
            $missingComfyModels = @(if ($null -ne
                $MissingComfyModelsReader) {
                & $MissingComfyModelsReader `
                    -Models $requestedComfyModels `
                    -Config $Config -ProjectRoot $resolved `
                    -VerifyHash $VerifyModelContentHash
            }
            else {
                Get-InstallerMissingComfyUIModels `
                    -Models $requestedComfyModels -Config $Config `
                    -ProjectRoot $resolved `
                    -VerifyHash $VerifyModelContentHash
            })
            if ($destinationState.Ready) {
                $requiredNodes = @($Config.ComfyUI.CustomNodes |
                    Where-Object {
                        [string]$_.RequiredBy -iin
                            $requiredComfyNodeNames
                    })
                $destinationRequirements = if ($null -ne
                    $ComfyRequirementsStateReader) {
                    & $ComfyRequirementsStateReader `
                        -RuntimeRoot $comfyDestination `
                        -Nodes $requiredNodes `
                        -VerifyIdentity $VerifyModelContentHash `
                        -VerifyEnvironment $false
                }
                else {
                    Get-InstallerComfyUIRequirementsState `
                        -RuntimeRoot $comfyDestination `
                        -Nodes $requiredNodes `
                        -VerifyIdentity $VerifyModelContentHash `
                        -VerifyEnvironment $false `
                        -ExpectedBaseRequirementLines @(
                            Get-InstallerComfyUIBaseRequirements `
                                -Config $Config
                        )
                }
                $comfyNodePayloadRequired = `
                    Test-InstallerComfyUINodeFallbackReason `
                        -Result $destinationRequirements `
                        -NodeCount $requiredNodes.Count
                if (-not $destinationRequirements.Ready -and
                    -not $comfyNodePayloadRequired) {
                    $localComfyRuntimeRequired = $true
                }
            }
        }
        elseif ($localComfy) {
            $missingComfyModels = @($requestedComfyModels)
        }
        $requiredTrees = [Collections.Generic.List[string]]::new()
        if ($localDescriptors.Count -gt 0 -or
            $localComfyRuntimeRequired -or $comfyNodePayloadRequired) {
            $requiredTrees.Add('Runtime')
        }
        if ($localModels -or
            ($localComfy -and $missingComfyModels.Count -gt 0)) {
            $requiredTrees.Add('Models')
        }
        foreach ($relativePath in $requiredTrees) {
            $null = Assert-InstallerLocalPayloadTree `
                -Root $resolved -RelativePath $relativePath `
                -FullTreeAudit:$RequireSelfContainedLocalPayload `
                -AllowDeploymentArtifacts $allowDeploymentArtifacts
        }
        foreach ($descriptor in $localDescriptors) {
            if (-not (Test-InstallerOfflineArtifactIdentity `
                -Root $resolved -Descriptor $descriptor)) {
                $descriptorName = Get-InstallerDependencySourceName `
                    -Descriptor $descriptor
                throw ('Yerel kurucu kimligi gecersiz veya eksik: ' +
                    $descriptorName)
            }
        }
        if ($localModels) {
            $modelsRoot = Resolve-InstallerContainedPackagePath `
                -Root $resolved -RelativePath 'Models'
            $modelsPrefix = $modelsRoot.TrimEnd('\') + '\'
            $selectedModelNames = `
                [Collections.Generic.HashSet[string]]::new(
                    [StringComparer]::OrdinalIgnoreCase
                )
            foreach ($packagePath in $selectedPackages) {
                $package = [IO.Path]::GetFullPath(
                    [Environment]::ExpandEnvironmentVariables(
                        [string]$packagePath
                    )
                ).TrimEnd('\')
                if (-not $package.StartsWith(
                        $modelsPrefix,
                        [StringComparison]::OrdinalIgnoreCase
                    ) -or -not (Test-Path -LiteralPath $package `
                        -PathType Container) -or
                    -not (Test-InstallerComfyUIReparseChain `
                        -Path $package)) {
                    throw "Yerel model paket yolu gecersiz: $package"
                }
                $metadataPath = Join-Path $package 'package.json'
                if (-not (Test-Path -LiteralPath $metadataPath `
                        -PathType Leaf)) {
                    throw "Yerel model paket metadata eksik: $package"
                }
                $metadata = Get-Content -LiteralPath $metadataPath `
                    -Raw -Encoding UTF8 | ConvertFrom-InstallerJson
                $reference = [string]$metadata.OllamaReference
                if ([string]::IsNullOrWhiteSpace($reference) -or
                    -not $selectedModelNames.Add($reference)) {
                    throw "Yerel model paket secimi gecersiz: $package"
                }
            }
            $requestedModelNames = @($Config.Models.Requested |
                ForEach-Object { [string]$_ })
            if ($requestedModelNames.Count -gt 0 -and
                ($requestedModelNames.Count -ne $selectedModelNames.Count -or
                    @($requestedModelNames | Where-Object {
                        -not $selectedModelNames.Contains($_)
                    }).Count -gt 0)) {
                throw 'Yerel Ollama model paket secimi istekle uyusmuyor.'
            }
            $modelIdentityConfig = $Config |
                ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
            if ($requestedModelNames.Count -eq 0) {
                $modelIdentityConfig.Models.Requested = @(
                    $selectedModelNames
                )
            }
            if (-not (Test-InstallerRequestedOllamaPackageIdentity `
                -Root $resolved -Config $modelIdentityConfig `
                -VerifyContentHash $VerifyModelContentHash)) {
                throw 'Istenen yerel Ollama model paketi gecersiz.'
            }
        }
        if ($localComfy) {
            $availabilityConfig = $Config
            if ($RequireSelfContainedLocalPayload) {
                $availabilityConfig = $Config |
                    ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
                $availabilityConfig.ComfyUI.InstallPath = Join-Path `
                    ([IO.Path]::GetTempPath()) `
                    ('Winlama-ComfyUI-Absent-' + [guid]::NewGuid())
            }
            $availability = if ($null -ne $ComfyAvailabilityReader) {
                & $ComfyAvailabilityReader `
                    -Models $requestedComfyModels `
                    -Config $availabilityConfig `
                    -ProjectRoot $resolved `
                    -RequiredNodeModelNames $requiredComfyNodeNames `
                    -VerifyIdentity $VerifyModelContentHash
            }
            else {
                Get-InstallerComfyUISourceAvailability `
                    -Models $requestedComfyModels `
                    -Config $availabilityConfig `
                    -ProjectRoot $resolved `
                    -RequiredNodeModelNames $requiredComfyNodeNames `
                    -VerifyIdentity $VerifyModelContentHash
            }
            if (-not $availability.LocalReady) {
                throw ('Yerel ComfyUI payload kimligi gecersiz: ' +
                    ($availability.MissingRequirements -join ', '))
            }
        }
        return $true
    }
    catch {
        if ($null -ne $FailureReason) {
            $FailureReason.Value = $_.Exception.Message
        }
        Write-Verbose ('Paket koku dogrulanamadi: {0} | {1}' -f `
            $Root, $_.Exception.Message)
        return $false
    }
}
function Resolve-InstallerPackageRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$CurrentRoot,
        [switch]$PreferConfiguredSource,
        [scriptblock]$BootstrapTester
    )
    $candidates = [Collections.Generic.List[string]]::new()
    $sourceProperty = $Config.Installation.PSObject.Properties['Source']
    $configuredSource = if ($null -ne $sourceProperty) {
        [string]$sourceProperty.Value
    }
    else {
        ''
    }
    if ($PreferConfiguredSource -and
        -not [string]::IsNullOrWhiteSpace($configuredSource)) {
        $candidates.Add($configuredSource)
    }
    $candidates.Add($CurrentRoot)
    if (-not $PreferConfiguredSource -and
        -not [string]::IsNullOrWhiteSpace($configuredSource)) {
        $candidates.Add($configuredSource)
    }
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        try {
            $resolved = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($candidate)
            ).TrimEnd('\')
        }
        catch {
            $failures.Add("$candidate -> Gecersiz yol: " +
                $_.Exception.Message)
            continue
        }
        if (-not $seen.Add($resolved)) {
            continue
        }
        $failureReason = ''
        $valid = if ($null -ne $BootstrapTester) {
            [bool](& $BootstrapTester -Root $resolved -Config $Config `
                -FailureReason ([ref]$failureReason))
        }
        else {
            Test-InstallerPackageRootBootstrapIdentity `
                -Root $resolved -Config $Config `
                -FailureReason ([ref]$failureReason)
        }
        if ($valid) {
            return $resolved
        }
        if ([string]::IsNullOrWhiteSpace($failureReason)) {
            $failureReason = 'Kimlik dogrulamasi ayrinti uretmedi.'
        }
        $failures.Add("$resolved -> $failureReason")
    }
    throw [IO.InvalidDataException]::new(
        'Winlama paket koku dogrulanamadi. Denenen kokler: ' +
        ($failures -join ' | ')
    )
}
function New-InstallerPackageRootReentryArguments {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$EffectiveConfigPath
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath, '-ConfigPath', $EffectiveConfigPath,
        '-Resume', '-SessionId', $SessionId
    )
    foreach ($entry in @(
        @('OllamaSelection', $OllamaSelection, 'Prompt'),
        @('ModelSelection', $ModelSelection, ''),
        @('ComfyUISelection', $ComfyUISelection, ''),
        @('ComfyUIInstallSelection', $ComfyUIInstallSelection, 'Prompt'),
        @('OpenWebUISelection', $OpenWebUISelection, 'Prompt'),
        @('DefaultConfigSelection', $DefaultConfigSelection, 'Prompt'),
        @('VoiceSelection', $VoiceSelection, 'Prompt'),
        @('VoiceLanguageSelection', $VoiceLanguageSelection, 'Prompt'),
        @('OllamaSourceSelection', $OllamaSourceSelection, 'Prompt'),
        @('ModelSourceSelection', $ModelSourceSelection, 'Prompt'),
        @('ComfyUISourceSelection', $ComfyUISourceSelection, 'Prompt'),
        @('DependencySourceSelection', $DependencySourceSelection, 'Prompt'),
        @('OptionalErrorMode', $OptionalErrorMode, 'Prompt'),
        @(
            'LocalPayloadHashSelection',
            $LocalPayloadHashSelection,
            'Prompt'
        ),
        @('InitiatingUserSid', $InitiatingUserSid, ''),
        @('InitiatingUserProfile', $InitiatingUserProfile, '')
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry[1]) -and
            [string]$entry[1] -cne [string]$entry[2]) {
            $arguments += '-' + [string]$entry[0]
            $arguments += [string]$entry[1]
        }
    }
    foreach ($entry in @(
        @('ForceRepair', [bool]$ForceRepair),
        @('NoPause', [bool]$NoPause),
        @('GenerateReport', [bool]$GenerateReport),
        @('ElevatedHost', [bool]$ElevatedHost)
    )) {
        if ([bool]$entry[1]) {
            $arguments += '-' + [string]$entry[0]
        }
    }
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $arguments += '-Verbose'
    }
    return $arguments
}
function Assert-InstallerDeferredPackageIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    Write-InstallerLog -Level INFO `
        -Message 'Installer.PackageVerification.Starting'
    $failureReason = ''
    if (-not (Test-InstallerPackageRootIdentity `
        -Root $Root -Config $Config `
        -FailureReason ([ref]$failureReason))) {
        throw [IO.InvalidDataException]::new(
            'Winlama paket kimligi dogrulanamadi: ' + $failureReason
        )
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.PackageVerification.Completed'
}
function Assert-InstallerPackageRootSourceContracts {
    $automaticConfig = $script:InstallerConfiguration |
        ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
    $bootstrapFailure = ''
    if (-not (Test-InstallerPackageRootBootstrapIdentity `
            -Root $PSScriptRoot -Config $automaticConfig `
            -FailureReason ([ref]$bootstrapFailure)) -or
        -not (Test-InstallerPackageRootIdentity `
            -Root $PSScriptRoot -Config $automaticConfig)) {
        throw ('Script-only Automatic paket koku reddedildi: ' +
            $bootstrapFailure)
    }
    $onlineConfig = $automaticConfig |
        ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
    $onlineConfig.Bootstrap.PowerShell.InstallSource = 'Online'
    foreach ($descriptor in @($onlineConfig.Dependencies)) {
        $descriptor.InstallSource = 'Online'
    }
    $onlineConfig.Models.InstallSource = 'Online'
    $onlineConfig.Models.LocalPackageImport.SelectedPackages = @()
    $onlineConfig.ComfyUI.InstallSource = 'Online'
    $resolvedRoot = Resolve-InstallerPackageRoot `
        -Config $onlineConfig -CurrentRoot $PSScriptRoot
    $onlineFailure = ''
    if (-not $resolvedRoot.Equals(
            [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not (Test-InstallerPackageRootIdentity `
            -Root $PSScriptRoot -Config $onlineConfig `
            -FailureReason ([ref]$onlineFailure))) {
        throw ('Script-only Online paket koku reddedildi: ' +
            $onlineFailure)
    }
    $emptyPendingConfig = New-InstallerPendingPayloadConfiguration `
        -Config $onlineConfig -OllamaModelNames @() `
        -ComfyUIModels @() -RequiredNodeModels @()
    $emptyPendingConfig.ComfyUI.Enabled = $true
    $emptyPendingConfig.ComfyUI.InstallSource = 'Local'
    $emptyPendingState = [pscustomobject]@{
        RuntimeCalls = 0
        MissingModelCount = -1
        RequirementsNodeCount = -1
        AvailabilityModelCount = -1
        AvailabilityNodeCount = -1
    }
    $emptyPendingFailure = ''
    $emptyPendingReady = Test-InstallerPackageRootIdentity `
        -Root $PSScriptRoot -Config $emptyPendingConfig `
        -FailureReason ([ref]$emptyPendingFailure) `
        -ComfyRuntimeStateReader ({
            param($Path, $Config, $VerifyIdentity)
            $emptyPendingState.RuntimeCalls += 1
            return [pscustomobject]@{ Ready = $true }
        }.GetNewClosure()) `
        -MissingComfyModelsReader ({
            param($Models, $Config, $ProjectRoot, $VerifyHash)
            $emptyPendingState.MissingModelCount = @($Models).Count
            return @()
        }.GetNewClosure()) `
        -ComfyRequirementsStateReader ({
            param(
                $RuntimeRoot,
                $Nodes,
                $VerifyIdentity,
                $VerifyEnvironment
            )
            $emptyPendingState.RequirementsNodeCount = @($Nodes).Count
            return [pscustomobject]@{
                Ready = $true
                ReasonCode = 'READY'
                Detail = ''
            }
        }.GetNewClosure()) `
        -ComfyAvailabilityReader ({
            param(
                $Models,
                $Config,
                $ProjectRoot,
                $RequiredNodeModelNames,
                $VerifyIdentity
            )
            $emptyPendingState.AvailabilityModelCount = `
                @($Models).Count
            $emptyPendingState.AvailabilityNodeCount = `
                @($RequiredNodeModelNames).Count
            return [pscustomobject]@{
                LocalReady = $true
                MissingRequirements = @()
            }
        }.GetNewClosure())
    if (-not $emptyPendingReady -or
        $emptyPendingState.RuntimeCalls -ne 1 -or
        $emptyPendingState.MissingModelCount -ne 0 -or
        $emptyPendingState.RequirementsNodeCount -ne 0 -or
        $emptyPendingState.AvailabilityModelCount -ne 0 -or
        $emptyPendingState.AvailabilityNodeCount -ne 0) {
        throw (
            ('EmptyLocalComfy: f={0};r={1};rt={2};m={3};q={4};' +
            'a={5}/{6}') -f
                $emptyPendingFailure,
                $emptyPendingReady,
                $emptyPendingState.RuntimeCalls,
                $emptyPendingState.MissingModelCount,
                $emptyPendingState.RequirementsNodeCount,
                $emptyPendingState.AvailabilityModelCount,
                $emptyPendingState.AvailabilityNodeCount
        )
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.EmptyLocalComfyIdentity'
    $localConfig = $onlineConfig |
        ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
    $localConfig.Bootstrap.PowerShell.InstallSource = 'Local'
    $localConfig.Bootstrap.PowerShell.OfflinePath = `
        'Runtime\PowerShell\__validation_missing__.msi'
    $localFailure = ''
    if ((Test-InstallerPackageRootIdentity -Root $PSScriptRoot `
            -Config $localConfig `
            -FailureReason ([ref]$localFailure)) -or
        $localFailure -notmatch 'Runtime|PowerShell') {
        throw 'Eksik explicit Local payload fail-closed reddedilmedi.'
    }
    $localModelConfig = $onlineConfig |
        ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
    $localModelConfig.Models.InstallSource = 'Local'
    $localModelConfig.Models.LocalPackageImport.SelectedPackages = @()
    $localModelFailure = ''
    if ((Test-InstallerPackageRootIdentity -Root $PSScriptRoot `
            -Config $localModelConfig `
            -FailureReason ([ref]$localModelFailure)) -or
        $localModelFailure -notmatch 'model paket secimi bos') {
        throw 'Bos explicit Local model secimi fail-closed olmadi.'
    }
    $pendingTreeState = [pscustomobject]@{ RecursiveCalls = 0 }
    $pendingTreePath = Assert-InstallerLocalPayloadTree `
        -Root $PSScriptRoot -RelativePath 'Modules' `
        -TreeReparseTester ({
            param($Root)
            $pendingTreeState.RecursiveCalls++
            throw 'Pending payload ilgisiz alt agaci taradi.'
        }.GetNewClosure())
    $fullTreeState = [pscustomobject]@{ RecursiveCalls = 0 }
    $null = Assert-InstallerLocalPayloadTree `
        -Root $PSScriptRoot -RelativePath 'Modules' -FullTreeAudit `
        -TreeReparseTester ({
            param($Root)
            $fullTreeState.RecursiveCalls++
            return $true
        }.GetNewClosure())
    if ($pendingTreePath -ine (Join-Path $PSScriptRoot 'Modules') -or
        $pendingTreeState.RecursiveCalls -ne 0 -or
        $fullTreeState.RecursiveCalls -ne 1) {
        throw 'Pending ve full-offline paket agaci kapsami gecersiz.'
    }
    $selectedIdentityConfig = $onlineConfig |
        ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
    $selectedIdentityConfig.Models.Requested = @('fixture:latest')
    $selectedPackagePath = Join-Path $PSScriptRoot `
        'Models\Selected-Fixture'
    $selectedMetadataPath = Join-Path $selectedPackagePath 'package.json'
    $selectedIdentityConfig.Models.LocalPackageImport.SelectedPackages = @(
        $selectedPackagePath
    )
    $selectedIdentityState = [pscustomobject]@{
        MetadataPaths = [Collections.Generic.List[string]]::new()
        MetadataTests = 0
    }
    $selectedIdentityReady = `
        Test-InstallerRequestedOllamaPackageIdentity `
            -Root $PSScriptRoot -Config $selectedIdentityConfig `
            -PathProbe { param($Path, $PathType) return $true } `
            -ReparseProbe { param($Candidate) return $false } `
            -MetadataReader ({
                param($Path)
                $selectedIdentityState.MetadataPaths.Add($Path)
                return [pscustomobject]@{
                    OllamaReference = 'fixture:latest'
                }
            }.GetNewClosure()) -MetadataTester ({
                param($PackagePath, $Metadata, $VerifyContentHash)
                $selectedIdentityState.MetadataTests++
                return $true
            }.GetNewClosure())
    $selectedReparseRejected = -not (
        Test-InstallerRequestedOllamaPackageIdentity `
            -Root $PSScriptRoot -Config $selectedIdentityConfig `
            -PathProbe { param($Path, $PathType) return $true } `
            -ReparseProbe ({
                param($Candidate)
                return [IO.Path]::GetFullPath($Candidate).Equals(
                    $selectedPackagePath,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }.GetNewClosure()) `
            -MetadataReader { throw 'Reparse paket metadata okudu.' } `
            -MetadataTester { throw 'Reparse paket kimligi test edildi.' }
    )
    $ollamaIdentitySource = (Get-Command `
        Test-InstallerRequestedOllamaPackageIdentity `
        -ErrorAction Stop).Definition
    if (-not $selectedIdentityReady -or -not $selectedReparseRejected -or
        $selectedIdentityState.MetadataPaths.Count -ne 1 -or
        $selectedIdentityState.MetadataPaths[0] -ine $selectedMetadataPath -or
        $selectedIdentityState.MetadataTests -ne 1 -or
        $ollamaIdentitySource -match '\bGet-ChildItem\b') {
        throw 'Pending Ollama exact paket kapsami gecersiz.'
    }
    $selectionConfig = $onlineConfig |
        ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
    $currentFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
        'Winlama-Current-Root-Fixture'
    $configuredFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
        'Winlama-Configured-Root-Fixture'
    $selectionConfig.Installation.Source = $configuredFixtureRoot
    $bootstrapTester = {
        param($Root, $Config, [ref]$FailureReason)
        return $true
    }
    $initialRoot = Resolve-InstallerPackageRoot `
        -Config $selectionConfig -CurrentRoot $currentFixtureRoot `
        -BootstrapTester $bootstrapTester
    $resumeRoot = Resolve-InstallerPackageRoot `
        -Config $selectionConfig -CurrentRoot $currentFixtureRoot `
        -PreferConfiguredSource -BootstrapTester $bootstrapTester
    if ($initialRoot -ine [IO.Path]::GetFullPath($currentFixtureRoot) -or
        $resumeRoot -ine [IO.Path]::GetFullPath($configuredFixtureRoot)) {
        throw 'Initial ve resume paket kok sirasi gecersiz.'
    }
    $reentryScript = Join-Path $configuredFixtureRoot 'Install.ps1'
    $reentryConfig = Join-Path $currentFixtureRoot `
        'Data\Configs\config.json'
    $reentryArguments = @(New-InstallerPackageRootReentryArguments `
        -ScriptPath $reentryScript `
        -EffectiveConfigPath $reentryConfig)
    $fileIndex = [Array]::IndexOf($reentryArguments, '-File')
    $configIndex = [Array]::IndexOf($reentryArguments, '-ConfigPath')
    if ($fileIndex -lt 0 -or
        $reentryArguments[$fileIndex + 1] -cne $reentryScript -or
        $configIndex -lt 0 -or
        $reentryArguments[$configIndex + 1] -cne $reentryConfig -or
        $reentryArguments -inotcontains '-Resume' -or
        $reentryArguments -inotcontains '-SessionId') {
        throw 'Resume paket kok re-entry argumanlari gecersiz.'
    }
    $modelRoot = Join-Path ([IO.Path]::GetTempPath()) `
        'Winlama-USB-Source-Fixture'
    $resolvedModels = Resolve-InstallerModelImportRoot `
        -PackageRoot $modelRoot -ConfiguredPath 'Models' `
        -ReparseProbe { param($Path) return $false }
    $outsideRejected = $false
    try {
        $null = Resolve-InstallerModelImportRoot `
            -PackageRoot $modelRoot -ConfiguredPath '..\Outside' `
            -ReparseProbe { param($Path) return $false }
    }
    catch {
        $outsideRejected = $true
    }
    $reparseRejected = $false
    try {
        $null = Resolve-InstallerModelImportRoot `
            -PackageRoot $modelRoot -ConfiguredPath 'Models' `
            -ReparseProbe { param($Path) return $true }
    }
    catch {
        $reparseRejected = $true
    }
    if ($resolvedModels -ine (Join-Path $modelRoot 'Models') -or
        -not $outsideRejected -or -not $reparseRejected) {
        throw 'Resume model paket kok containment sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ScriptOnlyPackageRoot'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ConditionalLocalPayload'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.PendingLocalTreeScope'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.SelectedOllamaPackageScope'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ResumePackageRootPreference'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ResumePackageRootReentry'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ResumeModelPackageRoot'
}
function ConvertTo-InstallerSourceSelection {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
        [string]$Selection
    )
    switch ($Selection.ToLowerInvariant()) {
        'prompt' { return 'Prompt' }
        'local' { return 'Local' }
        'online' { return 'Online' }
        'automatic' { return 'Automatic' }
    }
}
function Write-InstallerRule {
    param([ValidateSet('-', '=')][string]$Character = '-')
    Write-WinlamaUIRule -Character $Character
}
function Write-InstallerLine {
    param(
        [AllowEmptyString()]
        [string]$Text = '',
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    Write-WinlamaUILine -Text $Text -Color $Color
}
function New-InstallerSourceTableColumns {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Local', 'Online')]
        [string]$Source,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Detail,
        [switch]$Available
    )
    $sourceKey = if ($Source -ceq 'Local') {
        'Common.Source.Local'
    }
    else {
        'Common.Source.Online'
    }
    $sourceColor = if (-not $Available) {
        [ConsoleColor]::Yellow
    }
    elseif ($Source -ceq 'Local') {
        [ConsoleColor]::Green
    }
    else {
        [ConsoleColor]::Cyan
    }
    return @(
        New-WinlamaUITableColumn `
            -Text (Get-LocalizedText -Key $sourceKey) `
            -Width 5 -Alignment Center -Color $sourceColor
        New-WinlamaUITableColumn -Text $Name -Width 32 -Color Cyan
        New-WinlamaUITableColumn -Text $Detail -Width 53 -Color Gray
    )
}
function Write-InstallerSourceTableRow {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Local', 'Online')]
        [string]$Source,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Detail,
        [switch]$Available
    )
    $columns = @(New-InstallerSourceTableColumns `
        -Source $Source -Name $Name -Detail $Detail `
        -Available:$Available)
    Write-WinlamaUITableRow -Columns $columns
}
function Assert-InstallerSourceTableContracts {
    $columns = @(New-InstallerSourceTableColumns `
        -Source Local -Name 'fixture-model' `
        -Detail ('C:\Winlama\Models\' +
            ('cok-uzun-model-klasoru\' * 6) +
            'model.safetensors') -Available)
    $rows = @(Format-WinlamaUITableRow -Columns $columns)
    if ($rows.Count -lt 2 -or
        @($rows | Where-Object { $_.Text.Length -ne 100 }).Count `
            -ne 0 -or
        $rows[0].Cells[0] -cne 'YEREL' -or
        -not [string]::IsNullOrWhiteSpace($rows[1].Cells[0]) -or
        -not [string]::IsNullOrWhiteSpace($rows[1].Cells[1]) -or
        $columns[0].Color -ne [ConsoleColor]::Green) {
        throw 'Kurulum kaynak tablosu UI sozlesmesi gecersiz.'
    }
    $onlineColumns = @(New-InstallerSourceTableColumns `
        -Source Online -Name 'fixture-model' -Detail 'Resmi kaynak' `
        -Available)
    $missingColumns = @(New-InstallerSourceTableColumns `
        -Source Local -Name 'fixture-model' -Detail 'Eksik')
    if ($onlineColumns[0].Color -ne [ConsoleColor]::Cyan -or
        $missingColumns[0].Color -ne [ConsoleColor]::Yellow) {
        throw 'Kurulum kaynak tablosu renk sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Install.SourceTable'
    return $true
}
function Write-InstallerBanner {
    Write-InstallerRule -Character '='
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Banner.Title') -Color Cyan
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Banner.Subtitle') -Color Cyan
    Write-InstallerRule -Character '='
}
function Write-InstallerSection {
    param(
        [Parameter(Mandatory)][string]$Title,
        [object[]]$TitleArguments = @()
    )
    Write-InstallerRule
    Write-InstallerLine -Text (' {0}' -f (
        Get-LocalizedText -Key $Title -Arguments $TitleArguments
    )) -Color Cyan
    Write-InstallerRule
}
function Assert-InstallerLocalizationCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Collections.Generic.HashSet[string]]$Keys
    )
    $referenceParameters = @{
        'Get-LocalizedText' = 'Key'
        'Get-UninstallText' = 'Key'
        'Get-RepairText' = 'Key'
        'Get-OpenWebUIText' = 'Key'
        'Get-ComfyUIText' = 'Key'
        'Get-InstallerBootstrapText' = 'Key'
        'Write-DeploymentLog' = 'Message'
        'Write-InstallerLog' = 'Message'
        'Write-ManagerLog' = 'Message'
        'Write-ManagerStatus' = 'Message'
        'Write-ManagerSection' = 'Title'
        'Write-InstallerSection' = 'Title'
    }
    $surfaceParameters = @{
        'Write-WinlamaUILine' = @('Text')
        'Write-WinlamaUIStatus' = @('Message')
        'Write-WinlamaUIError' = @('Context')
        'Write-InstallerLine' = @('Text')
        'Write-LauncherLine' = @('Text')
        'Write-ManagerLine' = @('Text')
        'Write-ManagerStatus' = @('Message')
        'Write-RepairLine' = @('Text')
        'Write-RepairStatus' = @('Message')
        'Write-UninstallBootstrapLine' = @('Text')
        'Write-UninstallBootstrapStatus' = @('Message')
        'Write-UninstallBootstrapError' = @('Context')
        'Write-EngineBootstrapLine' = @('Text')
        'Write-EngineBootstrapStatus' = @('Message')
        'Write-EngineBootstrapError' = @('Context')
        'Write-InstallerBootstrapLine' = @('Text')
        'Write-InstallerBootstrapStatus' = @('Message')
        'Write-InstallerBootstrapError' = @('Context')
        'Write-LauncherBootstrapLine' = @('Text')
        'Write-LauncherBootstrapStatus' = @('Message')
        'Write-LauncherBootstrapError' = @('Context')
        'Write-ManagerBootstrapLine' = @('Text')
        'Write-ManagerBootstrapStatus' = @('Message')
        'Write-ManagerBootstrapError' = @('Context')
        'Write-RepairBootstrapLine' = @('Text')
        'Write-RepairBootstrapStatus' = @('Message')
        'Write-RepairBootstrapError' = @('Context')
        'Write-StartBootstrapLine' = @('Text')
        'Write-StartBootstrapStatus' = @('Message')
        'Write-StartBootstrapError' = @('Context')
        'Write-OpenWebUIBootstrapLine' = @('Text')
        'Write-OpenWebUIBootstrapStatus' = @('Message')
        'Write-OpenWebUIBootstrapError' = @('Context')
        'Write-ComfyUIBootstrapLine' = @('Text')
        'Write-ComfyUIBootstrapStatus' = @('Message')
        'Write-ComfyUIBootstrapError' = @('Context')
        'Read-WinlamaUIInput' = @('Prompt', 'Label', 'Hint')
        'Read-UninstallInput' = @('Prompt', 'Label')
        'Read-UninstallExactConfirmation' = @('Prompt')
        'Read-RepairInput' = @('Prompt', 'Label', 'Hint')
        'Confirm-WinlamaUIAction' = @('Prompt')
        'Complete-WinlamaUIOperation' = @('Summary')
    }
    $bootstrapFallbacks = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($value in @(
        'ISLEM OZETI',
        'Oturumu kapatmak icin CIKIS yazin.',
        'Onarim oturumunu kapatmak icin CIKIS yazin.',
        'Yalniz tam olarak CIKIS yazin.',
        'Bos veya gecersiz komut kabul edilmedi.',
        'Beklenmeyen motor hatasi.',
        'Beklenmeyen hata.',
        'Beklenmeyen model yoneticisi hatasi.',
        'Onarim beklenmeyen bir hatayla durdu.',
        'Beklenmeyen baslatma hatasi.',
        'Open WebUI baslatilamadi.',
        'Beklenmeyen ComfyUI hatasi.'
    )) {
        $null = $bootstrapFallbacks.Add($value)
    }
    $surfaceFixtures = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($value in @(
        'Fixture',
        'Dogrulama secim istemi.',
        'Dogrulama menu secimi.',
        'Dogrulama kaldirma secimi.',
        'Dogrulama kesin HAYIR onayi.',
        'Dogrulama onayi.',
        'Dogrulama reddi.',
        'Dogrulama islemi tamamlandi.',
        'FarkliEtiket'
    )) {
        $null = $surfaceFixtures.Add($value)
    }
    $negativeFixtures = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $null = $negativeFixtures.Add(
        'Uninstall.Validation.MissingKey'
    )
    $null = $negativeFixtures.Add(
        'Uninstall.Validation.MissingFormattedKey'
    )
    $missing = [Collections.Generic.List[string]]::new()
    $rawSurface = [Collections.Generic.List[string]]::new()
    $sourceFiles = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($source in Get-ChildItem -LiteralPath $PSScriptRoot `
        -Filter '*.ps1' -File) {
        $sourceFiles.Add($source)
    }
    foreach ($source in Get-ChildItem `
        -LiteralPath (Join-Path $PSScriptRoot 'Modules') `
        -Recurse -File | Where-Object {
            $_.Extension -in @('.ps1', '.psm1')
        }) {
        $sourceFiles.Add($source)
    }
    foreach ($source in $sourceFiles) {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $source.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if (@($parseErrors).Count -ne 0) {
            throw "Yerellestirme AST taramasi basarisiz: $($source.Name)"
        }
        $relative = $source.FullName.Substring(
            $PSScriptRoot.Length
        ).TrimStart('\')
        foreach ($command in $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst]
        }, $true)) {
            $name = $command.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }
            $owner = $command.Parent
            while ($null -ne $owner -and $owner -isnot
                [Management.Automation.Language.FunctionDefinitionAst]) {
                $owner = $owner.Parent
            }
            $ownerName = if ($null -eq $owner) {
                ''
            }
            else {
                [string]$owner.Name
            }
            for ($index = 0; $index -lt
                $command.CommandElements.Count - 1; $index++) {
                $parameter = $command.CommandElements[$index]
                if ($parameter -isnot
                    [Management.Automation.Language.CommandParameterAst]) {
                    continue
                }
                $valueAst = $command.CommandElements[$index + 1]
                if ($valueAst -isnot
                    [Management.Automation.Language.StringConstantExpressionAst]) {
                    continue
                }
                $value = [string]$valueAst.Value
                if ($referenceParameters.ContainsKey($name) -and
                    $parameter.ParameterName -ieq
                        $referenceParameters[$name] -and
                    -not $Keys.Contains($value)) {
                    $allowed = $relative -ceq 'Uninstall.ps1' -and
                        $ownerName -ceq
                            'Assert-UninstallValidationContracts' -and
                        $negativeFixtures.Contains($value)
                    if (-not $allowed) {
                        $missing.Add(
                            "${relative}:$($valueAst.Extent.StartLineNumber):$value"
                        )
                    }
                }
                if (-not $surfaceParameters.ContainsKey($name) -or
                    $parameter.ParameterName -notin
                        @($surfaceParameters[$name]) -or
                    [string]::IsNullOrWhiteSpace($value) -or
                    $Keys.Contains($value)) {
                    continue
                }
                $fallback = $name -like '*Bootstrap*' -and
                    $bootstrapFallbacks.Contains($value)
                if (-not $fallback -and
                    -not $surfaceFixtures.Contains($value)) {
                    $rawSurface.Add(
                        "${relative}:$($valueAst.Extent.StartLineNumber):$name"
                    )
                }
            }
            $dynamic = @()
            if ($name -ieq 'Write-DeploymentLog') {
                $dynamic = @(
                    [pscustomobject]@{
                        Parameter = 'Module'
                        Prefix = 'Module.'
                    },
                    [pscustomobject]@{
                        Parameter = 'Recovery'
                        Prefix = 'Recovery.'
                    }
                )
            }
            elseif ($name -ieq 'Write-ManagerLog') {
                $dynamic = @(
                    [pscustomobject]@{
                        Parameter = 'Event'
                        Prefix = 'Manager.Event.'
                    }
                )
            }
            foreach ($specification in $dynamic) {
                for ($index = 0; $index -lt
                    $command.CommandElements.Count - 1; $index++) {
                    $parameter = $command.CommandElements[$index]
                    if ($parameter -isnot
                        [Management.Automation.Language.CommandParameterAst] `
                        -or $parameter.ParameterName -ine
                            $specification.Parameter) {
                        continue
                    }
                    $valueAst = $command.CommandElements[$index + 1]
                    if ($valueAst -isnot
                        [Management.Automation.Language.StringConstantExpressionAst] `
                        -or [string]::IsNullOrWhiteSpace($valueAst.Value)) {
                        continue
                    }
                    $key = $specification.Prefix + $valueAst.Value
                    $allowed = $key -ceq 'Manager.Event.VALIDATION' -and
                        $relative -ceq 'ModelManager.ps1'
                    if (-not $Keys.Contains($key) -and -not $allowed) {
                        $missing.Add(
                            "${relative}:$($valueAst.Extent.StartLineNumber):$key"
                        )
                    }
                }
            }
        }
    }
    $required = @(
        'Common.Level.Info', 'Common.Level.Step',
        'Common.Level.Ok', 'Common.Level.Warning',
        'Common.Level.Error', 'Common.Level.Detail',
        'Common.Level.Skip', 'Common.Operation.Summary',
        'Common.Prompt.Close', 'Common.Prompt.ExactCommand',
        'Common.Command.Invalid',
        'Common.Error.StandardInputClosed',
        'Engine.WindowTitle', 'Installer.WindowTitle',
        'Launcher.WindowTitle', 'Manager.WindowTitle',
        'Repair.WindowTitle', 'Startup.WindowTitle',
        'OpenWebUI.WindowTitle', 'ComfyUI.WindowTitle',
        'Uninstall.WindowTitle',
        'RunMe.Error.WindowsPowerShellMissing',
        'Stage.INITIALIZE', 'Stage.BOOTSTRAP',
        'Stage.SECURITY_BASELINE', 'Stage.DEPENDENCIES',
        'Stage.ENVIRONMENT', 'Stage.HARDWARE_ANALYSIS',
        'Stage.OLLAMA_CONFIGURATION', 'Stage.WEBUI_SETUP',
        'Stage.RUNTIME', 'Stage.MODEL_DOWNLOAD',
        'Stage.GPU_VALIDATION', 'Stage.SECURITY_HARDENING',
        'Stage.FINAL_VALIDATION', 'Stage.STARTUP_COMMIT',
        'State.Status.IDLE', 'State.Status.RECOVERING',
        'State.Status.RUNNING', 'State.Status.SUCCESS',
        'State.Status.FAILED', 'State.Status.ROLLBACK',
        'Reporting.Check.Runtime', 'Reporting.Check.Models',
        'Reporting.Check.Inference', 'Reporting.Check.Security',
        'Reporting.Check.Environment', 'Reporting.Check.Disk',
        'Repair.Report.Outcome.Success',
        'Repair.Report.Outcome.Incomplete',
        'Repair.Report.Outcome.Failed',
        'Repair.Report.Mode.RepairAll',
        'Repair.Report.Mode.PackageToInstalled',
        'Repair.Report.Mode.PublishPackage',
        'Repair.Outcome.Success', 'Repair.Outcome.Incomplete',
        'Repair.Outcome.Failed'
    )
    $ttsKeys = @(
        'Tts.Api.InternalError', 'Tts.Api.MethodNotAllowed',
        'Tts.Api.NotFound', 'Tts.Api.RequestInvalid',
        'Tts.Cli.Description', 'Tts.Cli.Help',
        'Tts.Cli.HostHelp', 'Tts.Cli.InvalidArguments',
        'Tts.Cli.PortHelp', 'Tts.Error.LanguageUnsupported',
        'Tts.Error.LoopbackOnly', 'Tts.Error.ModelNotReady',
        'Tts.Error.ModelUnsupported', 'Tts.Error.SynthesisFailed',
        'Tts.Error.VoiceUnsupported', 'Tts.Log.SynthesisFailed',
        'Tts.Log.UnexpectedFailure', 'Tts.Voice.en', 'Tts.Voice.tr'
    )
    $required += $ttsKeys
    foreach ($key in $required) {
        if (-not $Keys.Contains($key)) {
            $missing.Add("String\tr.ini:0:$key")
        }
    }
    $runMeSource = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot 'RunMe.bat')
    )
    foreach ($match in [regex]::Matches(
        $runMeSource,
        'call\s+:LOAD_LOCALIZED_TEXT\s+"([^"]+)"',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) {
        $key = [string]$match.Groups[1].Value
        if (-not $Keys.Contains($key)) {
            $missing.Add("RunMe.bat:0:$key")
        }
    }
    $ttsSource = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot 'Services\TtsServer.py')
    )
    $ttsSourceKeys = @([regex]::Matches(
        $ttsSource,
        '(?m)^\s+"(Tts\.[^"]+)",\s*$'
    ) | ForEach-Object {
        [string]$_.Groups[1].Value
    } | Select-Object -Unique)
    if ($ttsSourceKeys.Count -ne 19 -or
        @($ttsSourceKeys | Where-Object {
            $_ -notin $ttsKeys
        }).Count -ne 0 -or
        @($ttsKeys | Where-Object {
            $_ -notin $ttsSourceKeys
        }).Count -ne 0) {
        throw 'TTS yerellestirme kaynak semasi gecersiz.'
    }
    if ($missing.Count -ne 0) {
        throw ('Eksik yerellestirme anahtari: ' +
            (@($missing | Select-Object -Unique) -join ', '))
    }
    if ($rawSurface.Count -ne 0) {
        throw ('Ham kullanici arayuzu metni: ' +
            (@($rawSurface | Select-Object -Unique) -join ', '))
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.LocalizationKeyCoverage'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.LocalizationSurfaceGuard'
}
function Show-InstallerLocalizedInputValidation {
    $path = Join-Path $PSScriptRoot 'String\tr.ini'
    $selectionText = 'Se{0}iminiz' -f [char]0x00E7
    $selectionKeys = @(
        'Common.Prompt.Selection',
        'Uninstall.FullSelection.Prompt'
    )
    $entries = [Collections.Generic.List[object]]::new()
    $keys = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line) -or
            $line.StartsWith('#')) {
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            throw "Yerellestirme satiri gecersiz: $line"
        }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1)
        if (-not $keys.Add($key)) {
            throw "Yinelenen yerellestirme anahtari: $key"
        }
        if ($value -cmatch '[^\x00-\x7F]' -and
            ($key -notin $selectionKeys -or
                $value -cne $selectionText)) {
            throw "ASCII olmayan yerellestirme metni: $key"
        }
        $entries.Add([pscustomobject]@{ Key = $key; Value = $value })
    }
    $formatArguments = [object[]](0..63 | ForEach-Object {
        "Deger$_"
    })
    foreach ($entry in $entries) {
        try {
            $null = [string]::Format(
                [string]$entry.Value,
                $formatArguments
            )
        }
        catch {
            throw "Yerellestirme bicimi gecersiz: $($entry.Key)"
        }
    }
    $ui = @{
        'Common.UI.Pipe' = '|'
        'Common.UI.RuleEquals' = '='
        'Common.UI.RuleDash' = '-'
        'Common.UI.ConsoleWidth' = '100'
    }
    foreach ($item in $ui.GetEnumerator()) {
        $entry = $entries | Where-Object Key -EQ $item.Key |
            Select-Object -First 1
        if ($null -eq $entry -or $entry.Value -cne $item.Value) {
            throw "UI standardi gecersiz: $($item.Key)"
        }
    }
    Assert-InstallerLocalizationCoverage -Keys $keys
    Write-InstallerSection -Title 'Installer.Section.QuickSelection'
    foreach ($entry in @($entries | Where-Object {
        $_.Key -match '\.Prompt\.'
    })) {
        Write-InstallerLine -Text $entry.Value -Color White
    }
    Write-InstallerRule
}
function Test-IsWindowsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}
function Test-InstallerUserContextMatch {
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
function Assert-InstallerElevatedUserContext {
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
    if (-not (Test-InstallerUserContextMatch `
        -ExpectedSid $InitiatingUserSid `
        -ExpectedProfile $InitiatingUserProfile `
        -ActualSid $actualSid -ActualProfile $actualProfile)) {
        throw [UnauthorizedAccessException]::new(
            (Get-LocalizedText `
                -Key 'Installer.Error.ElevatedUserMismatch')
        )
    }
}
function Get-PowerShellExecutable {
    param(
        [version]$MinimumVersion,
        [switch]$MachineOnly
    )
    $candidates = @()
    $candidates += Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not $MachineOnly) {
        $command = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $candidates += $command.Source
        }
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }
        try {
            $versionText = & $candidate -NoLogo -NoProfile -Command `
                '$PSVersionTable.PSVersion.ToString()' 2>$null
            if ($LASTEXITCODE -eq 0 -and
                [version]$versionText.Trim() -ge $MinimumVersion) {
                return $candidate
            }
        }
        catch {
            Write-Verbose ('PowerShell adayi denetlenemedi: {0} | {1}' `
                -f $candidate, $_.Exception.Message)
            continue
        }
    }
    return $null
}
function Start-ElevatedInstaller {
    param(
        [scriptblock]$ProcessStarter,
        [switch]$SuppressUserError,
        [bool]$SuppressPause = [bool]$NoPause
    )
    $powershell = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($powershell)) {
        $executableName = if ($PSVersionTable.PSVersion.Major -ge 6) {
            'pwsh.exe'
        }
        else {
            'powershell.exe'
        }
        $powershell = Join-Path $PSHOME $executableName
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity.User) {
        throw (Get-LocalizedText -Key 'Common.Admin.Declined' `
            -Arguments @('Kullanici SID bilgisi okunamadi.'))
    }
    $initiatingSid = [string]$identity.User.Value
    $initiatingProfile = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-ConfigPath', ('"{0}"' -f $ConfigPath),
        '-InitiatingUserSid', $initiatingSid,
        '-InitiatingUserProfile',
        (ConvertTo-WindowsCommandLineArgument `
            -Argument $initiatingProfile),
        '-ElevatedHost',
        '-SessionId', $SessionId
    )
    if ($Resume) {
        $arguments += '-Resume'
    }
    if ($ForceRepair) {
        $arguments += '-ForceRepair'
    }
    if ($SuppressPause) {
        $arguments += '-NoPause'
    }
    if ($GenerateReport) {
        $arguments += '-GenerateReport'
    }
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $arguments += '-Verbose'
    }
    if ($OllamaSelection -ne 'Prompt') {
        $arguments += '-OllamaSelection'
        $arguments += $OllamaSelection
    }
    if (-not [string]::IsNullOrWhiteSpace($ModelSelection)) {
        $arguments += '-ModelSelection'
        $arguments += ('"{0}"' -f $ModelSelection)
    }
    if (-not [string]::IsNullOrWhiteSpace($ComfyUISelection)) {
        $arguments += '-ComfyUISelection'
        $arguments += ('"{0}"' -f $ComfyUISelection)
    }
    if ($ComfyUIInstallSelection -ne 'Prompt') {
        $arguments += '-ComfyUIInstallSelection'
        $arguments += $ComfyUIInstallSelection
    }
    if ($OpenWebUISelection -ne 'Prompt') {
        $arguments += '-OpenWebUISelection'
        $arguments += $OpenWebUISelection
    }
    if ($DefaultConfigSelection -ne 'Prompt') {
        $arguments += '-DefaultConfigSelection'
        $arguments += $DefaultConfigSelection
    }
    if ($VoiceSelection -ne 'Prompt') {
        $arguments += '-VoiceSelection'
        $arguments += $VoiceSelection
    }
    if ($VoiceLanguageSelection -ne 'Prompt') {
        $arguments += '-VoiceLanguageSelection'
        $arguments += $VoiceLanguageSelection
    }
    if ($OllamaSourceSelection -ne 'Prompt') {
        $arguments += '-OllamaSourceSelection'
        $arguments += $OllamaSourceSelection
    }
    if ($ModelSourceSelection -ne 'Prompt') {
        $arguments += '-ModelSourceSelection'
        $arguments += $ModelSourceSelection
    }
    if ($ComfyUISourceSelection -ne 'Prompt') {
        $arguments += '-ComfyUISourceSelection'
        $arguments += $ComfyUISourceSelection
    }
    if ($DependencySourceSelection -ne 'Prompt') {
        $arguments += '-DependencySourceSelection'
        $arguments += $DependencySourceSelection
    }
    if ($OptionalErrorMode -ne 'Prompt') {
        $arguments += '-OptionalErrorMode'
        $arguments += $OptionalErrorMode
    }
    if ($LocalPayloadHashSelection -ne 'Prompt') {
        $arguments += '-LocalPayloadHashSelection'
        $arguments += $LocalPayloadHashSelection
    }
    try {
        $startParameters = @{
            FilePath = $powershell
            ArgumentList = $arguments
            WorkingDirectory = $PSScriptRoot
            Verb = 'RunAs'
            WindowStyle = 'Normal'
            PassThru = $true
            ErrorAction = 'Stop'
        }
        $process = if ($null -eq $ProcessStarter) {
            Start-Process @startParameters
        }
        else {
            & $ProcessStarter $startParameters
        }
        if ($null -eq $process) {
            throw 'Yonetici sureci olusturulamadi.'
        }
        $exitCode = 0
        if ($SuppressPause) {
            if ($null -eq $process.PSObject.Methods['WaitForExit'] -or
                $null -eq $process.PSObject.Properties['ExitCode']) {
                throw 'Yonetici sureci bekleme sozlesmesini desteklemiyor.'
            }
            $process.WaitForExit()
            $exitCode = [int]$process.ExitCode
        }
        if ($null -ne $process.PSObject.Methods['Dispose']) {
            $process.Dispose()
        }
        return $exitCode
    }
    catch {
        if ($SuppressUserError) {
            return 1
        }
        $message = Get-LocalizedText -Key 'Common.Admin.Declined' `
            -Arguments @($_.Exception.Message)
        Write-WinlamaUIStatus -Level WARN -Message $message
        if (-not $NoPause -and [Environment]::UserInteractive) {
            Complete-WinlamaUIOperation `
                -Summary (Get-LocalizedText `
                    -Key 'Installer.Operation.AdminDenied') `
                -Level WARN -Command CIKIS
        }
        return 1
    }
}
function New-InstallerLogRecord {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [AllowEmptyString()][string]$ExceptionText = '',
        [AllowEmptyString()][string]$EventCode = '',
        [AllowEmptyString()][string]$LogSessionId = $SessionId,
        [int]$ProcessId = $PID
    )
    $displayLevel = switch ($Level) {
        'ERROR' { Get-LocalizedText -Key 'Common.Level.Error' }
        'WARN' { Get-LocalizedText -Key 'Common.Level.Warning' }
        default { Get-LocalizedText -Key 'Common.Level.Info' }
    }
    return [pscustomobject][ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('O')
        level = $Level
        displayLevel = $displayLevel
        module = Get-LocalizedText -Key 'Module.Installer'
        moduleCode = 'INSTALLER'
        eventCode = $EventCode
        message = $Message
        exception = $ExceptionText
        sessionId = $LogSessionId
        processId = $ProcessId
    }
}
function Assert-InstallerLogSchemaContracts {
    foreach ($level in @('INFO', 'WARN', 'ERROR')) {
        $record = New-InstallerLogRecord -Level $level `
            -Message 'fixture' -EventCode 'SCHEMA_FIXTURE' `
            -LogSessionId 'fixture-session' -ProcessId 42
        $parsed = $record | ConvertTo-Json -Compress |
            ConvertFrom-InstallerJson
        $timestamp = [DateTimeOffset]::MinValue
        if ([string]$parsed.level -cne $level -or
            [string]::IsNullOrWhiteSpace([string]$parsed.displayLevel) -or
            [string]$parsed.moduleCode -cne 'INSTALLER' -or
            [string]$parsed.eventCode -cne 'SCHEMA_FIXTURE' -or
            [string]$parsed.message -cne 'fixture' -or
            [string]$parsed.sessionId -cne 'fixture-session' -or
            [int]$parsed.processId -ne 42 -or
            -not [DateTimeOffset]::TryParse(
                [string]$parsed.timestamp,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$timestamp
            )) {
            throw "Installer JSONL semasi gecersiz: $level"
        }
    }
    if ((Get-InstallerLogEventCode `
        -MessageKey 'Installer.Started' -EventCode '') -cne
        'Installer.Started' -or
        (Get-InstallerLogEventCode `
            -MessageKey 'Installer.Started' `
            -EventCode 'INSTALL_STARTED') -cne 'INSTALL_STARTED') {
        throw 'Installer JSONL eventCode varsayimi gecersiz.'
    }
    $diagnosticSource = (Get-Command Get-InstallerDiagnostics `
        -ErrorAction Stop).Definition
    if (-not $diagnosticSource.Contains(
            'Installer.Diagnostics.PreviousStateHeader'
        ) -or -not $diagnosticSource.Contains(
            '[string]$state.InstallSessionID -ceq $SessionId'
        )) {
        throw 'Installer eski oturum tanilama etiketi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Installer.LogSchema'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.DiagnosticStateProvenance'
}
function Get-InstallerLogEventCode {
    param(
        [Parameter(Mandatory)][string]$MessageKey,
        [AllowEmptyString()][string]$EventCode = ''
    )
    if ([string]::IsNullOrWhiteSpace($EventCode)) {
        return $MessageKey
    }
    return $EventCode
}
function Write-InstallerLog {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'STEP', 'WARN', 'ERROR')]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Message,
        [object[]]$MessageArguments = @(),
        [Exception]$Exception,
        [AllowEmptyString()][string]$EventCode = ''
    )
    $messageKey = $Message
    $EventCode = Get-InstallerLogEventCode `
        -MessageKey $messageKey -EventCode $EventCode
    $Message = Get-LocalizedText -Key $messageKey `
        -Arguments $MessageArguments
    $exceptionText = ''
    if ($null -ne $Exception) {
        $exceptionText = ConvertTo-InstallerDiagnosticText `
            -Value $Exception.ToString() -MaximumLength 2048
    }
    $recordLevel = if ($Level -eq 'STEP') { 'INFO' } else { $Level }
    $entry = New-InstallerLogRecord -Level $recordLevel `
        -Message $Message -ExceptionText $exceptionText `
        -EventCode $EventCode
    $line = $entry | ConvertTo-Json -Compress
    $uiLevel = switch ($Level) {
        'ERROR' { 'ERROR' }
        'WARN' { 'WARN' }
        'STEP' { 'STEP' }
        default { 'INFO' }
    }
    if ($ValidateOnly) {
        Write-Verbose ('{0}: {1}' -f $Level, $Message)
        Write-WinlamaUIStatus -Level $uiLevel -Message $Message
        return
    }
    $logsPath = Get-InstallerLogDirectory `
        -Configuration $script:InstallerConfiguration
    Set-InstallerLogPathForDirectory -Directory $logsPath
    try {
        Add-WinlamaUtf8Line -Path $script:InstallerLogPath -Value $line
    }
    catch {
        Write-Verbose ('Installer logu yazilamadi: {0}' -f `
            $_.Exception.Message)
    }
    Write-WinlamaUIStatus -Level $uiLevel -Message $Message
}
function Get-InstallerLogPropertyValue {
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
function Get-InstallerDiagnosticDigest {
    param([AllowEmptyString()][string]$Value = '')
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($Value)
        )
        $hex = [BitConverter]::ToString($hash) -replace '-', ''
        return $hex.Substring(0, 16)
    }
    finally {
        $algorithm.Dispose()
    }
}
function ConvertTo-InstallerDiagnosticText {
    param(
        [AllowNull()][object]$Value,
        [ValidateRange(32, 8192)][int]$MaximumLength = 512
    )
    $original = [string]$Value
    $text = [regex]::Replace($original, '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = 'Ayrinti yok.'
    }
    if ($text.StartsWith('{') -or $text.StartsWith('[')) {
        $text = 'Yapilandirilmis alt gunluk ayrintisi gizlendi.'
    }
    if ($text.Length -gt $MaximumLength) {
        $text = $text.Substring(0, $MaximumLength - 3) + '...'
    }
    return $text
}
function Get-InstallerLastLogEvent {
    param([Parameter(Mandatory)][object[]]$Logs)
    foreach ($log in $Logs) {
        $tail = @(Get-Content -LiteralPath $log.FullName `
            -Tail 50 -Encoding UTF8 -ErrorAction SilentlyContinue)
        [array]::Reverse($tail)
        foreach ($line in $tail) {
            try {
                $entry = $line | ConvertFrom-InstallerJson
                $timestamp = [string](Get-InstallerLogPropertyValue `
                    -InputObject $entry `
                    -Names @('timestamp', 'Timestamp'))
                $level = [string](Get-InstallerLogPropertyValue `
                    -InputObject $entry -Names @('level', 'Level'))
                $module = [string](Get-InstallerLogPropertyValue `
                    -InputObject $entry `
                    -Names @('moduleCode', 'ModuleCode', 'module'))
                $event = [string](Get-InstallerLogPropertyValue `
                    -InputObject $entry `
                    -Names @('eventCode', 'EventCode', 'event'))
                $messageValue = Get-InstallerLogPropertyValue `
                    -InputObject $entry `
                    -Names @(
                        'message', 'Message', 'errorMessage',
                        'ErrorMessage', 'exception', 'Exception'
                    )
                $message = ConvertTo-InstallerDiagnosticText `
                    -Value $messageValue -MaximumLength 512
                $digest = Get-InstallerDiagnosticDigest -Value $line
                return (ConvertTo-InstallerDiagnosticText -Value (
                    '{0} | {1} | {2}/{3} | {4} | SHA256:{5}' -f @(
                        $timestamp,
                        $level,
                        $module,
                        $event,
                        $message,
                        $digest
                    )
                ) -MaximumLength 768)
            }
            catch {
                continue
            }
        }
    }
    return ''
}
function Get-InstallerDiagnostics {
    $lines = [Collections.Generic.List[string]]::new()
    try {
        $diagnosticConfig = Read-JsonFile -Path $ConfigPath
        $statePath = Resolve-InstallerDeploymentPath `
            -Config $diagnosticConfig `
            -Path ([string]$diagnosticConfig.Paths.State)
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $state = Read-JsonFile -Path $statePath
            $stateHeaderKey = if (
                [string]$state.InstallSessionID -ceq $SessionId
            ) {
                'Installer.Diagnostics.StateHeader'
            }
            else {
                'Installer.Diagnostics.PreviousStateHeader'
            }
            $lines.Add((Get-LocalizedText `
                -Key $stateHeaderKey))
            $lines.Add((Get-LocalizedText `
                -Key 'Installer.Diagnostics.Stage' `
                -Arguments @((Get-LocalizedText `
                    -Key "Stage.$($state.CurrentStage)"))))
            $lines.Add((Get-LocalizedText `
                -Key 'Installer.Diagnostics.Status' `
                -Arguments @((Get-LocalizedText `
                    -Key "State.Status.$($state.StageStatus)"))))
            $lines.Add((Get-LocalizedText `
                -Key 'Installer.Diagnostics.Recovery' `
                -Arguments @((Get-LocalizedText `
                    -Key "Recovery.$($state.RecoveryAction)"))))
            $lines.Add((Get-LocalizedText `
                -Key 'Installer.Diagnostics.LastException' `
                -Arguments @((ConvertTo-InstallerDiagnosticText `
                    -Value $state.LastException `
                    -MaximumLength 512))))
        }
        $diagnosticLogs = Resolve-InstallerDeploymentPath `
            -Config $diagnosticConfig `
            -Path ([string]$diagnosticConfig.Paths.Logs)
        $recentLogs = @(Get-ChildItem -LiteralPath $diagnosticLogs `
            -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 3)
        foreach ($recentLog in $recentLogs) {
            $lines.Add((Get-LocalizedText `
                -Key 'Installer.Diagnostics.DeploymentLogHeader'))
            $lines.Add($recentLog.FullName)
        }
        $lastEvent = Get-InstallerLastLogEvent -Logs $recentLogs
        if (-not [string]::IsNullOrWhiteSpace($lastEvent)) {
            $lines.Add('Son yapilandirilmis olay:')
            $lines.Add($lastEvent)
        }
    }
    catch {
        $lines.Add((Get-LocalizedText `
            -Key 'Installer.Diagnostics.ReadFailed' `
            -Arguments @($_.Exception.Message)))
    }
    return $lines -join [Environment]::NewLine
}
function Write-InstallerFailure {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $diagnostics = Get-InstallerDiagnostics
    $content = ConvertTo-InstallerDiagnosticText -Value (@(
        Get-LocalizedText -Key 'Installer.Diagnostics.Time' `
            -Arguments @([DateTimeOffset]::Now.ToString('O'))
        Get-LocalizedText -Key 'Installer.Diagnostics.PowerShell' `
            -Arguments @($PSVersionTable.PSVersion)
        Get-LocalizedText -Key 'Installer.Diagnostics.Message' `
            -Arguments @((ConvertTo-InstallerDiagnosticText `
                -Value $ErrorRecord.Exception.Message `
                -MaximumLength 768))
        Get-LocalizedText -Key 'Installer.Diagnostics.Position' `
            -Arguments @((ConvertTo-InstallerDiagnosticText `
                -Value $ErrorRecord.InvocationInfo.PositionMessage `
                -MaximumLength 512))
        Get-LocalizedText -Key 'Installer.Diagnostics.Stack' `
            -Arguments @((ConvertTo-InstallerDiagnosticText `
                -Value $ErrorRecord.ScriptStackTrace `
                -MaximumLength 512))
        Get-LocalizedText -Key 'Installer.Diagnostics.Exception' `
            -Arguments @((ConvertTo-InstallerDiagnosticText `
                -Value $ErrorRecord.Exception.GetType().FullName `
                -MaximumLength 256))
        $diagnostics
    ) -join [Environment]::NewLine) -MaximumLength 4096
    if ($ValidateOnly) {
        Write-WinlamaUIError -Context (Get-LocalizedText `
            -Key 'Installer.Operation.ValidationFailed') `
            -ErrorRecord $ErrorRecord
        return
    }
    $logsPath = Get-InstallerLogDirectory `
        -Configuration $script:InstallerConfiguration
    Set-InstallerLogPathForDirectory -Directory $logsPath
    $path = $script:InstallerLogPath
    $failure = [ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('O')
        level = 'ERROR'
        displayLevel = Get-LocalizedText -Key 'Common.Level.Error'
        moduleCode = 'INSTALLER'
        eventCode = 'INSTALL_FAILURE_DIAGNOSTICS'
        message = ConvertTo-InstallerDiagnosticText `
            -Value $ErrorRecord.Exception.Message -MaximumLength 768
        diagnostics = $content
        sessionId = $SessionId
        processId = $PID
    } | ConvertTo-Json -Compress -Depth 5
    try {
        Add-WinlamaUtf8Line -Path $path -Value $failure
    }
    catch {
        Write-WinlamaUIStatus -Level WARN -Message (
            Get-LocalizedText `
                -Key 'Installer.Warning.DiagnosticLogFailed' `
                -Arguments @($_.Exception.Message)
        )
        $fallbackDirectory = Join-Path $env:TEMP 'Winlama-Logs'
        $path = New-WinlamaTimestampedFile `
            -Directory $fallbackDirectory -Extension '.log'
        try {
            Add-WinlamaUtf8Line -Path $path -Value $failure
        }
        catch {
            Write-Verbose ('Yedek installer logu yazilamadi: {0}' -f `
                $_.Exception.Message)
        }
    }
    Write-InstallerLog -Level ERROR `
        -Message $ErrorRecord.Exception.Message `
        -Exception $ErrorRecord.Exception `
        -EventCode 'INSTALL_FAILED'
    Write-InstallerSection -Title 'Installer.Section.Stopped'
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Error.DetailPath' -Arguments @($path)) `
        -Color Red
}
function Wait-OnInstallerFailure {
    if ($NoPause) {
        return
    }
    Write-InstallerLog -Level ERROR `
        -Message 'Installer.Failure.WaitingForExit'
    Complete-WinlamaUIOperation `
        -Summary (Get-LocalizedText `
            -Key 'Installer.Operation.Failed') `
        -Level ERROR -Command CIKIS
}
function Assert-InstallerElevationContracts {
    $script:InstallerElevationFixture = $null
    $fixtureProcess = [pscustomobject]@{
        Id = 4242
        ExitCode = 0
        Waited = $false
    }
    $fixtureProcess | Add-Member -MemberType ScriptMethod `
        -Name WaitForExit -Value { $this.Waited = $true }
    $fixtureProcess | Add-Member -MemberType ScriptMethod `
        -Name Dispose -Value { }
    $result = Start-ElevatedInstaller -SuppressPause:$false `
        -ProcessStarter {
        param([hashtable]$Parameters)
        $script:InstallerElevationFixture = $Parameters
        return $fixtureProcess
    }
    $fixture = $script:InstallerElevationFixture
    $interactiveWaited = [bool]$fixtureProcess.Waited
    $script:InstallerElevationFixture = $null
    $automatedResult = Start-ElevatedInstaller -SuppressPause:$true `
        -ProcessStarter {
            param([hashtable]$Parameters)
            $script:InstallerElevationFixture = $Parameters
            return $fixtureProcess
        }
    $automatedFixture = $script:InstallerElevationFixture
    if ($result -ne 0 -or $null -eq $fixture -or
        $automatedResult -ne 0 -or $null -eq $automatedFixture -or
        $interactiveWaited -or
        -not $fixtureProcess.Waited -or
        $fixture.Verb -cne 'RunAs' -or
        $fixture.WindowStyle -cne 'Normal' -or
        -not [bool]$fixture.PassThru -or
        '-File' -notin @($fixture.ArgumentList) -or
        '-ConfigPath' -notin @($fixture.ArgumentList) -or
        '-InitiatingUserSid' -notin @($fixture.ArgumentList) -or
        '-InitiatingUserProfile' -notin @($fixture.ArgumentList) -or
        '-ElevatedHost' -notin @($fixture.ArgumentList) -or
        @($fixture.ArgumentList | Where-Object {
            $_ -ceq '-NoPause'
        }).Count -ne 0 -or
        @($automatedFixture.ArgumentList | Where-Object {
            $_ -ceq '-NoPause'
        }).Count -ne 1) {
        throw 'Kurulum yonetici aktarim sozlesmesi gecersiz.'
    }
    $denied = Start-ElevatedInstaller -SuppressUserError `
        -ProcessStarter {
            param([hashtable]$Parameters)
            throw [ComponentModel.Win32Exception]::new(
                'Dogrulama UAC reddi.'
            )
        }
    $waitSource = (Get-Command Wait-OnInstallerFailure `
        -ErrorAction Stop).Definition
    $elevationSource = (Get-Command Start-ElevatedInstaller `
        -ErrorAction Stop).Definition
    $boundedDiagnostic = ConvertTo-InstallerDiagnosticText `
        -Value ('{"level":"ERROR","message":"' +
            ('x' * 5000) + '"}') -MaximumLength 320
    if ($denied -ne 1 -or $waitSource -match '\$Resume' -or
        $elevationSource -notmatch 'Complete-WinlamaUIOperation' -or
        $elevationSource -notmatch '\$SuppressPause' -or
        $boundedDiagnostic.Length -gt 320 -or
        $boundedDiagnostic -match '\{\s*"(?:level|message)"') {
        throw 'Kurulum UAC reddi veya hata bekleme sozlesmesi gecersiz.'
    }
    $fixtureProfile = 'C:\Users\Validation User'
    if (-not (Test-InstallerUserContextMatch `
        -ExpectedSid 'S-1-5-21-100' -ExpectedProfile $fixtureProfile `
        -ActualSid 'S-1-5-21-100' -ActualProfile $fixtureProfile) -or
        (Test-InstallerUserContextMatch `
            -ExpectedSid 'S-1-5-21-100' -ExpectedProfile $fixtureProfile `
            -ActualSid 'S-1-5-21-200' -ActualProfile $fixtureProfile) -or
        (Test-InstallerUserContextMatch `
            -ExpectedSid 'S-1-5-21-100' -ExpectedProfile $fixtureProfile `
            -ActualSid 'S-1-5-21-100' `
            -ActualProfile 'C:\Users\Other') -or
        (Test-InstallerUserContextMatch `
            -ExpectedSid 'S-1-5-21-100' -ExpectedProfile '' `
            -ActualSid 'S-1-5-21-100' -ActualProfile $fixtureProfile) -or
        -not (Test-InstallerUserContextMatch)) {
        throw 'Kurulum farkli yonetici hesabi korumasi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ElevatedUserContext'
    Write-Verbose 'WINLAMA_UI_OK:Install.ElevationContracts'
    Write-Verbose 'WINLAMA_UI_OK:Install.ElevatedBufferClear'
}
function Exit-InstallerSelection {
    param([Parameter(Mandatory)][string]$Summary)
    Write-InstallerLog -Level INFO -EventCode 'INSTALL_CANCELLED' `
        -Message 'Installer.Log.SelectionCancelled' `
        -MessageArguments @($Summary)
    if (-not $NoPause) {
        Complete-WinlamaUIOperation -Summary $Summary `
            -Level SKIP -Command CIKIS
    }
    exit (Get-InstallerCancellationExitCode)
}
function Get-InstallerCancellationExitCode {
    return 2
}
function Test-InstallerOperatingSystemContract {
    param(
        [Parameter(Mandatory)][version]$Version,
        [Parameter(Mandatory)][string]$Architecture,
        [Parameter(Mandatory)][int]$ProductType
    )
    return Test-WinlamaClientOperatingSystemContract `
        -Version $Version -Architecture $Architecture `
        -ProductType $ProductType
}
function Assert-InstallerOperatingSystem {
    Assert-WinlamaClientOperatingSystem
}
function Test-InstallerNvidiaSmiResult {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyCollection()][object[]]$Rows
    )
    if ($ExitCode -ne 0) {
        return $false
    }
    foreach ($row in @($Rows)) {
        $columns = @([string]$row -split ',\s*')
        if ($columns.Count -lt 2 -or
            [string]::IsNullOrWhiteSpace($columns[0])) {
            continue
        }
        $memoryMiB = 0.0
        if ([double]::TryParse(
            $columns[1].Trim(),
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$memoryMiB
        ) -and $memoryMiB -gt 0) {
            return $true
        }
    }
    return $false
}
function Get-InstallerHardwareProfile {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $modelsPath = Resolve-InstallerPath -Path $Config.Paths.Models
    $driveRoot = [IO.Path]::GetPathRoot($modelsPath)
    $cpuName = [string]$env:PROCESSOR_IDENTIFIER
    $logicalCores = [Environment]::ProcessorCount
    $ramGB = 0.0
    $freeDiskGB = [math]::Round(
        [IO.DriveInfo]::new($driveRoot).AvailableFreeSpace / 1GB,
        2
    )
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem `
            -OperationTimeoutSec 3 -ErrorAction Stop
        $cpu = Get-CimInstance -ClassName Win32_Processor `
            -OperationTimeoutSec 3 -ErrorAction Stop |
            Select-Object -First 1
        $cpuName = $cpu.Name.Trim()
        $logicalCores = [int]$cpu.NumberOfLogicalProcessors
        $ramGB = [math]::Round(
            $computer.TotalPhysicalMemory / 1GB,
            2
        )
    }
    catch {
        Write-Verbose ('CIM donanim sorgusu kullanilamadi: {0}' -f `
            $_.Exception.Message)
        Add-Type -AssemblyName Microsoft.VisualBasic
        $computerInfo = `
            [Microsoft.VisualBasic.Devices.ComputerInfo]::new()
        $ramGB = [math]::Round(
            $computerInfo.TotalPhysicalMemory / 1GB,
            2
        )
    }
    $gpuName = Get-LocalizedText -Key 'Installer.Hardware.SharedMemory'
    $vramGB = 0.0
    $nvidiaDetected = $false
    $nvidiaSmiReady = $false
    $nvidiaSmi = Get-Command 'nvidia-smi.exe' `
        -ErrorAction SilentlyContinue
    if ($null -ne $nvidiaSmi) {
        $nvidiaDetected = $true
    }
    if ($null -ne $nvidiaSmi) {
        try {
            $nvidiaOutput = $null
            $nvidiaSmiExitCode = Invoke-BootstrapProcess `
                -FilePath $nvidiaSmi.Source -ArgumentList @(
                    '--query-gpu=name,memory.total',
                    '--format=csv,noheader,nounits'
                ) -TimeoutSeconds 5 -CaptureOutput `
                -WindowStyle Hidden `
                -CapturedOutput ([ref]$nvidiaOutput)
            $rows = @([string]$nvidiaOutput -split "`r?`n" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $nvidiaSmiReady = Test-InstallerNvidiaSmiResult `
                -ExitCode $nvidiaSmiExitCode -Rows $rows
            if ($nvidiaSmiReady) {
                foreach ($row in $rows) {
                    $columns = @([string]$row -split ',\s*')
                    $memoryMiB = 0.0
                    if ($columns.Count -lt 2 -or
                        -not [double]::TryParse(
                            $columns[1].Trim(),
                            [Globalization.NumberStyles]::Float,
                            [Globalization.CultureInfo]::InvariantCulture,
                            [ref]$memoryMiB
                        )) {
                        continue
                    }
                    $candidate = [math]::Round($memoryMiB / 1024, 2)
                    if ($candidate -gt $vramGB) {
                        $gpuName = $columns[0].Trim()
                        $vramGB = $candidate
                    }
                }
            }
        }
        catch {
            Write-Verbose ('nvidia-smi sorgusu basarisiz: {0}' -f `
                $_.Exception.Message)
            $nvidiaSmiReady = $false
        }
    }
    if ($vramGB -eq 0) {
        try {
            $videos = @(Get-CimInstance `
                -ClassName Win32_VideoController `
                -OperationTimeoutSec 3 -ErrorAction Stop)
            foreach ($video in $videos) {
                $videoName = [string]$video.Name
                if ($videoName -match 'NVIDIA') {
                    $nvidiaDetected = $true
                }
            }
            $video = $videos | Sort-Object AdapterRAM -Descending |
                Select-Object -First 1
            if ($null -ne $video) {
                $gpuName = [string]$video.Name
                $vramGB = [math]::Round(
                    [double]$video.AdapterRAM / 1GB,
                    2
                )
            }
        }
        catch {
            Write-Verbose ('GPU bilgisi okunamadi: {0}' -f `
                $_.Exception.Message)
        }
    }
    return [pscustomobject][ordered]@{
        Cpu = $cpuName
        LogicalCores = $logicalCores
        RamGB = $ramGB
        Gpu = $gpuName
        VramGB = $vramGB
        NvidiaDetected = $nvidiaDetected
        NvidiaSmiReady = $nvidiaSmiReady
        FreeDiskGB = $freeDiskGB
    }
}
function Get-InstallerModelAssessment {
    param(
        [Parameter(Mandatory)][pscustomobject]$Model,
        [Parameter(Mandatory)][pscustomobject]$Hardware,
        [Parameter(Mandatory)][pscustomobject]$Settings,
        [Parameter(Mandatory)][int]$ContextK
    )
    if ($ContextK -gt $Model.MaxContextK) {
        return [pscustomobject]@{
            Status = Get-LocalizedText `
                -Key 'Installer.Assessment.Unsupported'
            RequiredGB = 0
            Detail = Get-LocalizedText `
                -Key 'Installer.Assessment.ModelLimit' `
                -Arguments @($Model.MaxContextK)
            Rank = 0
        }
    }
    $modelMemory = $Model.DownloadSizeGB *
        (1 + ($Settings.ModelOverheadPercent / 100.0))
    $kvMemory = [math]::Sqrt([double]$Model.ParametersB) *
        $Settings.KvCacheCoefficient * $ContextK
    $required = $modelMemory + $kvMemory +
        $Settings.RuntimeOverheadGB
    $usableVram = [math]::Max(
        0,
        $Hardware.VramGB - $Settings.GpuReserveGB
    )
    $usableRam = [math]::Max(
        0,
        $Hardware.RamGB - $Settings.OsReserveGB
    )
    $rank = 0
    $status = Get-LocalizedText `
        -Key 'Installer.Assessment.Insufficient'
    $detail = Get-LocalizedText `
        -Key 'Installer.Assessment.InsufficientMemory'
    if ($required -le ($usableVram * 0.8)) {
        $status = Get-LocalizedText `
            -Key 'Installer.Assessment.Excellent'
        $detail = Get-LocalizedText `
            -Key 'Installer.Assessment.FullGpuSafe'
        $rank = 4
    }
    elseif ($required -le $usableVram) {
        $status = Get-LocalizedText -Key 'Installer.Assessment.Good'
        $detail = Get-LocalizedText `
            -Key 'Installer.Assessment.FullGpuLimited'
        $rank = 3
    }
    elseif ($required -le ($usableVram + $usableRam)) {
        $status = if ($usableVram -gt 0) {
            Get-LocalizedText -Key 'Installer.Assessment.Medium'
        }
        else {
            Get-LocalizedText -Key 'Installer.Assessment.Slow'
        }
        $detail = if ($usableVram -gt 0) {
            Get-LocalizedText `
                -Key 'Installer.Assessment.PartialGpu'
        }
        else {
            Get-LocalizedText -Key 'Installer.Assessment.CpuOnly'
        }
        $rank = if ($usableVram -gt 0) { 2 } else { 1 }
    }
    return [pscustomobject]@{
        Status = $status
        RequiredGB = [math]::Round($required, 1)
        Detail = $detail
        Rank = $rank
    }
}
function Show-InstallerHardware {
    param([Parameter(Mandatory)][pscustomobject]$Hardware)
    Write-InstallerSection -Title 'Installer.Section.SystemAnalysis'
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Hardware.Cpu' -Arguments @($Hardware.Cpu))
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Hardware.Cores' `
        -Arguments @($Hardware.LogicalCores))
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Hardware.Ram' -Arguments @($Hardware.RamGB))
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Hardware.Gpu' -Arguments @($Hardware.Gpu))
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Hardware.Vram' `
        -Arguments @($Hardware.VramGB))
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Hardware.Disk' `
        -Arguments @($Hardware.FreeDiskGB))
}
function Show-InstallerModelCatalog {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Hardware
    )
    $models = @($Config.Models.Catalog)
    $contexts = @($Config.Models.ContextSizesK)
    $settings = $Config.Models.MemoryEstimation
    Write-InstallerSection -Title 'Installer.Section.ModelCatalog'
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Catalog.EstimateNotice')
    $index = 0
    foreach ($model in $models) {
        $index++
        Write-InstallerRule
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.Catalog.ModelRow' `
            -Arguments @(
                $index,
                $model.Name,
                $model.DownloadSizeGB,
                $model.MaxContextK
            )) -Color Cyan
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.Catalog.Family' `
            -Arguments @($model.Family))
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.Catalog.Description' `
            -Arguments @($model.Description))
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.Catalog.Capabilities' `
            -Arguments @($model.Capabilities))
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.Catalog.Modalities' `
            -Arguments @($model.Modalities))
        foreach ($context in $contexts) {
            $assessment = Get-InstallerModelAssessment `
                -Model $model -Hardware $Hardware `
                -Settings $settings -ContextK $context
            $color = switch ($assessment.Rank) {
                4 { 'Green' }
                3 { 'Green' }
                2 { 'Yellow' }
                1 { 'Yellow' }
                default { 'Red' }
            }
            $memory = if ($assessment.RequiredGB -gt 0) {
                "$($assessment.RequiredGB) GB"
            }
            else {
                '-'
            }
            Write-InstallerLine -Text (Get-LocalizedText `
                -Key 'Installer.Catalog.ContextRow' `
                -Arguments @(
                    $context,
                    $assessment.Status,
                    $memory,
                    $assessment.Detail
                )) -Color $color
        }
    }
}
function Get-InstallerOllamaDependency {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $dependency = $Config.Dependencies |
        Where-Object Name -eq 'Ollama' |
        Select-Object -First 1
    if ($null -eq $dependency) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @('Dependencies.Ollama'))
    }
    return $dependency
}
function Get-InstallerOllamaCandidateRoots {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [scriptblock]$CommandResolver
    )
    $roots = [Collections.Generic.List[string]]::new()
    $installPath = [Environment]::ExpandEnvironmentVariables(
        [string]$Config.Ollama.InstallPath
    )
    if (-not [string]::IsNullOrWhiteSpace($installPath)) {
        $roots.Add($installPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs\Ollama'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $roots.Add((Join-Path $env:ProgramFiles 'Ollama'))
    }
    $programFilesX86 = [Environment]::GetEnvironmentVariable(
        'ProgramFiles(x86)'
    )
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $roots.Add((Join-Path $programFilesX86 'Ollama'))
    }
    $commands = if ($null -ne $CommandResolver) {
        @(& $CommandResolver)
    }
    else {
        @(Get-Command 'ollama.exe' -CommandType Application -All `
            -ErrorAction SilentlyContinue)
    }
    foreach ($command in $commands) {
        $source = [string]$command.Source
        if (-not [string]::IsNullOrWhiteSpace($source)) {
            $roots.Add((Split-Path -Parent $source))
        }
    }
    return @($roots | Select-Object -Unique)
}
function Test-InstallerOllamaProductPresent {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [scriptblock]$FileProbe,
        [scriptblock]$CommandResolver
    )
    foreach ($root in @(Get-InstallerOllamaCandidateRoots `
        -Config $Config -CommandResolver $CommandResolver)) {
        $cli = Join-Path $root 'ollama.exe'
        $application = Join-Path $root 'ollama app.exe'
        $cliExists = if ($null -ne $FileProbe) {
            [bool](& $FileProbe -Path $cli)
        }
        else {
            Test-Path -LiteralPath $cli -PathType Leaf
        }
        $applicationExists = if ($null -ne $FileProbe) {
            [bool](& $FileProbe -Path $application)
        }
        else {
            Test-Path -LiteralPath $application -PathType Leaf
        }
        if ($cliExists -and $applicationExists) {
            return $true
        }
    }
    return $false
}
function Test-InstallerOllamaInstalled {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $dependency = Get-InstallerOllamaDependency -Config $Config
    $minimumVersion = [version][string]$dependency.MinimumVersion
    foreach ($root in @(Get-InstallerOllamaCandidateRoots `
        -Config $Config)) {
        $cli = Join-Path $root 'ollama.exe'
        $application = Join-Path $root 'ollama app.exe'
        if (-not (Test-Path -LiteralPath $cli -PathType Leaf) -or
            -not (Test-Path -LiteralPath $application `
                -PathType Leaf)) {
            continue
        }
        try {
            $versionOutput = $null
            $exitCode = Invoke-BootstrapProcess -FilePath $cli `
                -ArgumentList @('--version') -TimeoutSeconds 5 `
                -CaptureOutput -WindowStyle Hidden `
                -CapturedOutput ([ref]$versionOutput)
            if ($exitCode -eq 0 -and
                (Get-VersionFromText -Text $versionOutput) -ge
                    $minimumVersion) {
                return $true
            }
        }
        catch {
            Write-Verbose ('Ollama kurulumu dogrulanamadi: {0}' -f `
                $root)
        }
    }
    return $false
}
function Read-InstallerOllamaInstallSource {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
        [string]$Selection = 'Prompt',
        [scriptblock]$InputReader,
        [scriptblock]$InstalledTester,
        [bool]$VerifyLocalIdentity = $true,
        [scriptblock]$ArtifactVerifier,
        [bool]$Interactive = [Environment]::UserInteractive
    )
    $Selection = ConvertTo-InstallerSourceSelection `
        -Selection $Selection
    $dependency = Get-InstallerOllamaDependency -Config $Config
    $localPath = Get-InstallerDescriptorOfflinePath `
        -Descriptor $dependency
    $localExists = Test-Path -LiteralPath $localPath -PathType Leaf
    $isInstalled = if ($null -ne $InstalledTester) {
        [bool](& $InstalledTester)
    }
    else {
        Test-InstallerOllamaInstalled -Config $Config
    }
    if ($isInstalled) {
        $dependency.InstallSource = 'Automatic'
        Write-InstallerLog -Level INFO `
            -Message 'Installer.Ollama.AlreadyInstalled'
        return 'Installed'
    }
    if ($Selection -eq 'Online') {
        $dependency.InstallSource = 'Online'
        Write-InstallerLog -Level INFO `
            -Message 'Installer.Ollama.SourceOnline'
        return 'Online'
    }
    $localVerified = Test-InstallerDescriptorLocalArtifact `
        -Descriptor $dependency -VerifyHash $VerifyLocalIdentity `
        -ArtifactVerifier $ArtifactVerifier
    if ($VerifyLocalIdentity -and $localExists -and
        -not $localVerified) {
        Write-InstallerLog -Level WARN `
            -Message 'Installer.Ollama.LocalInvalid' `
            -MessageArguments @($localPath)
    }
    if ($localVerified) {
        $sizeGB = [math]::Round(
            (Get-Item -LiteralPath $localPath).Length / 1GB,
            2
        )
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.Ollama.LocalDetected' `
            -Arguments @($localPath, $sizeGB)) -Color Green
    }
    else {
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.Ollama.LocalMissing' `
            -Arguments @($localPath)) -Color Yellow
    }
    if ($Selection -eq 'Prompt' -and $localVerified -and $Interactive) {
        Write-InstallerSection -Title 'Installer.Section.OllamaSource'
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.Ollama.Menu.Local') -Color Green
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.Ollama.Menu.Online') -Color Cyan
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.Ollama.Menu.Exit') -Color Yellow
        Write-InstallerRule
        while ($true) {
            $answer = (Read-WinlamaUIInput `
                -Prompt (Get-LocalizedText `
                    -Key 'Installer.Prompt.OllamaSource') `
                -Label (Get-LocalizedText `
                    -Key 'Common.Prompt.Selection') -NoLeadingRule `
                -InputReader $InputReader).Trim()
            if ($answer -eq '1') {
                $Selection = 'Local'
                break
            }
            if ($answer -eq '2') {
                $Selection = 'Online'
                break
            }
            if ($answer -eq '0') {
                return 'Exit'
            }
            Write-WinlamaUIStatus -Level WARN `
                -Message (Get-LocalizedText `
                    -Key 'Common.Selection.Invalid')
        }
    }
    elseif ($Selection -eq 'Prompt') {
        $Selection = if ($localVerified) { 'Automatic' } else { 'Online' }
    }
    if ($Selection -eq 'Local' -and -not $localVerified) {
        throw (New-NonRetryableException -Message (Get-LocalizedText `
            -Key 'Dependencies.Error.LocalSourceMissing' `
            -Arguments @($dependency.OfflinePath)))
    }
    $dependency.InstallSource = $Selection
    if ($Selection -eq 'Automatic' -and -not $localVerified) {
        $Selection = 'Online'
        $dependency.InstallSource = $Selection
    }
    elseif ($Selection -eq 'Automatic' -and $VerifyLocalIdentity) {
        $Selection = 'Local'
        $dependency.InstallSource = $Selection
    }
    if ($Selection -eq 'Local') {
        Write-InstallerLog -Level INFO `
            -Message 'Installer.Ollama.SourceLocal' `
            -MessageArguments @($localPath)
    }
    elseif ($Selection -eq 'Online') {
        Write-InstallerLog -Level INFO `
            -Message 'Installer.Ollama.SourceOnline'
    }
    else {
        Write-InstallerLog -Level INFO `
            -Message 'Installer.Ollama.SourceAutomatic'
    }
    return $Selection
}
function Get-InstallerRoleRecommendations {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Hardware
    )
    $settings = $Config.Models.MemoryEstimation
    $candidates = foreach ($model in @($Config.Models.Catalog)) {
        if ($model.MaxContextK -lt $Config.Models.DefaultContextK) {
            continue
        }
        $assessment = Get-InstallerModelAssessment `
            -Model $model -Hardware $Hardware `
            -Settings $settings `
            -ContextK $Config.Models.DefaultContextK
        $requiredDisk = $model.DownloadSizeGB +
            (($model.DownloadSizeGB + $model.WorkingSpaceGB) *
                (1 + ($Config.Models.SafetyBufferPercent / 100.0)))
        $cpuReady = $Config.Hardware.AllowCpuFallback -and
            $model.CpuFallback
        if ($assessment.Rank -le 0 -or
            $Hardware.FreeDiskGB -lt $requiredDisk -or
            ($Hardware.VramGB -le 0 -and -not $cpuReady)) {
            continue
        }
        [pscustomobject]@{
            Name = [string]$model.Name
            Capabilities = @($model.Capabilities) -join ' '
            Rank = $assessment.Rank
            Priority = $model.Priority
        }
    }
    foreach ($role in @(
        [pscustomobject]@{
            Name = 'Installer.Selection.Role.General'
            Pattern = 'reasoning|multilingual|vision|instruction'
        },
        [pscustomobject]@{
            Name = 'Installer.Selection.Role.Coding'
            Pattern = 'coding|programming|refactor|fill-in'
        },
        [pscustomobject]@{
            Name = 'Installer.Selection.Role.Agent'
            Pattern = 'agentic|function|tool'
        }
    )) {
        $selected = $candidates | Where-Object {
            $_.Capabilities -match $role.Pattern
        } | Sort-Object `
            @{ Expression = 'Rank'; Descending = $true },
            @{ Expression = 'Priority'; Descending = $true } |
            Select-Object -First 1
        if ($null -ne $selected) {
            [pscustomobject]@{
                Role = Get-LocalizedText -Key $role.Name
                Model = $selected.Name
            }
        }
    }
}
function Show-InstallerModelSelectionLayout {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Hardware
    )
    $models = @($Config.Models.Catalog)
    if ($models.Count -eq 0 -or
        @($models.Name | Sort-Object -Unique).Count -ne $models.Count) {
        throw 'Kurulum model listesi bos veya yinelenen model iceriyor.'
    }
    Show-InstallerHardware -Hardware $Hardware
    Show-InstallerModelCatalog -Config $Config -Hardware $Hardware
    Write-InstallerSection -Title 'Installer.Section.QuickSelection'
    $index = 0
    foreach ($model in $models) {
        $index++
        $row = Get-LocalizedText -Key 'Installer.Selection.ModelRow' `
            -Arguments @($index, $model.Name)
        if ($row -notmatch ('^\s*{0}\s+\|\s+\S' -f $index)) {
            throw "Kurulum model satiri gecersiz: $($model.Name)"
        }
        Write-InstallerLine -Text $row
    }
    $recommended = Get-InstallerSelectedModelNames `
        -Config $Config -Hardware $Hardware -Automatic |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($recommended)) {
        $recommended = Get-LocalizedText `
            -Key 'Installer.Selection.AutomaticUnavailable'
    }
    Write-InstallerSection -Title 'Installer.Section.ModelSelection'
    foreach ($role in @(Get-InstallerRoleRecommendations `
        -Config $Config -Hardware $Hardware)) {
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.Selection.RoleRecommendation' `
            -Arguments @($role.Role, $role.Model)) -Color Green
    }
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Selection.Automatic' -Arguments @(
            $Config.Models.DefaultContextK,
            $recommended
        )) -Color White
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Selection.Multiple') -Color White
    $installedCount = @(Get-InstallerInstalledModelNames `
        -Config $Config).Count
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Selection.AllInstalled' `
        -Arguments @($installedCount)) -Color Green
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Selection.AllSource' `
        -Arguments @('?')) -Color Cyan
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Selection.Skip') -Color Yellow
    $prompt = Get-LocalizedText -Key 'Installer.Prompt.Selection'
    if ($prompt -notmatch 'A' -or $prompt -notmatch 'L' -or
        $prompt -notmatch 'K' -or $prompt -notmatch 'S' -or
        $prompt -notmatch '0') {
        throw 'Kurulum model secim istemi gecersiz.'
    }
    Write-InstallerLine -Text $prompt -Color Cyan
    Write-InstallerRule
}
function Get-InstallerInstalledModelNames {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [switch]$VerifyHash,
        [AllowEmptyCollection()][string[]]$ModelNames,
        [hashtable]$HashCache
    )
    $catalogNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($model in @($Config.Models.Catalog)) {
        $null = $catalogNames.Add([string]$model.Name)
    }
    $requestedNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    if ($PSBoundParameters.ContainsKey('ModelNames')) {
        foreach ($modelName in @($ModelNames)) {
            $null = $requestedNames.Add([string]$modelName)
        }
    }
    if ($null -eq $HashCache) {
        $HashCache = @{}
    }
    $names = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($configuredRoot in @(
        $Config.ModelTransfer.NativeModelSearchDirectories
    )) {
        $root = Resolve-InstallerPath -Path ([string]$configuredRoot)
        $manifestRoot = Join-Path $root 'manifests'
        if (-not (Test-Path -LiteralPath $manifestRoot `
            -PathType Container)) {
            continue
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $manifestRoot `
            -Recurse -File -ErrorAction SilentlyContinue)) {
            $name = '{0}:{1}' -f $file.Directory.Name, $file.Name
            if (-not $catalogNames.Contains($name) -or
                ($PSBoundParameters.ContainsKey('ModelNames') -and
                    -not $requestedNames.Contains($name))) {
                continue
            }
            try {
                $document = Read-JsonFile -Path $file.FullName
                $descriptors = @($document.config) + @($document.layers)
                if ($descriptors.Count -eq 0 -or @($descriptors |
                    Where-Object {
                        [string]$_.digest -cnotmatch `
                            '^sha256:[a-f0-9]{64}$' -or
                        [long]$_.size -lt 1
                    }).Count -gt 0) {
                    continue
                }
                $blobRoot = Join-Path $root 'blobs'
                $missing = @($descriptors | Where-Object {
                    $digest = [string]$_.digest
                    $blob = Join-Path $blobRoot `
                        ($digest.Replace(':', '-'))
                    $item = Get-Item -LiteralPath $blob -Force `
                        -ErrorAction SilentlyContinue
                    if ($null -eq $item -or
                        $item.Length -ne [long]$_.size) {
                        return $true
                    }
                    if (-not $VerifyHash) {
                        return $false
                    }
                    if (-not $HashCache.ContainsKey($blob)) {
                        $HashCache[$blob] = `
                            Get-InstallerFileSha256WithProgress -Path $blob
                    }
                    return [string]$HashCache[$blob] -ine
                        $digest.Substring(7)
                })
                if ($missing.Count -eq 0) {
                    $null = $names.Add($name)
                }
            }
            catch {
                Write-Verbose ('Ollama manifesti dogrulanamadi: {0}' `
                    -f $file.FullName)
            }
        }
    }
    return @($names | Sort-Object)
}
function Test-InstallerAnyOllamaModelInstalled {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    foreach ($configuredRoot in @(
        $Config.ModelTransfer.NativeModelSearchDirectories
    )) {
        $root = Resolve-InstallerPath -Path ([string]$configuredRoot)
        $manifestRoot = Join-Path $root 'manifests'
        foreach ($manifest in @(Get-ChildItem -LiteralPath $manifestRoot `
            -Recurse -File -ErrorAction SilentlyContinue)) {
            try {
                $document = Read-JsonFile -Path $manifest.FullName
                $digests = @([string]$document.config.digest) + @(
                    $document.layers | ForEach-Object {
                        [string]$_.digest
                    }
                )
                if ($digests.Count -eq 0 -or @($digests |
                    Where-Object {
                        $_ -cnotmatch '^sha256:[a-f0-9]{64}$'
                    }).Count -gt 0) {
                    continue
                }
                $blobRoot = Join-Path $root 'blobs'
                $missing = @($digests | Where-Object {
                    $blob = Join-Path $blobRoot ($_.Replace(':', '-'))
                    $item = Get-Item -LiteralPath $blob -Force `
                        -ErrorAction SilentlyContinue
                    $null -eq $item -or $item.Length -lt 1
                })
                if ($missing.Count -eq 0) {
                    return $true
                }
            }
            catch {
                Write-Verbose ('Ollama manifesti okunamadi: {0}' -f `
                    $manifest.FullName)
            }
        }
    }
    return $false
}
function Get-InstallerSourceModelNames {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $catalogNames = @($Config.Models.Catalog | ForEach-Object {
        [string]$_.Name
    })
    $packages = @(Get-InstallerLocalModelPackages `
        -Config $Config -ModelNames $catalogNames)
    $names = foreach ($package in $packages) {
        if ($null -eq $package) {
            continue
        }
        [string]$package.Name
    }
    return @($names | Sort-Object -Unique)
}
function Read-InstallerModelSelection {
    param(
        [string]$Value,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Hardware,
        [scriptblock]$InputReader
    )
    $models = @($Config.Models.Catalog)
    $defaultSelection = if (@($Config.Models.Requested).Count -gt 0) {
        @($Config.Models.Requested) -join ','
    }
    else {
        'Automatic'
    }
    $promptForSelection = [string]::IsNullOrWhiteSpace($Value) -and
        [Environment]::UserInteractive
    if ([string]::IsNullOrWhiteSpace($Value) -and
        -not $promptForSelection) {
        return $defaultSelection
    }
    if ($promptForSelection) {
        Show-InstallerModelSelectionLayout -Config $Config `
            -Hardware $Hardware
    }
    while ($true) {
        if ($promptForSelection) {
            $Value = Read-WinlamaUIInput `
                -Prompt (Get-LocalizedText `
                    -Key 'Installer.Prompt.Selection') `
                -Label (Get-LocalizedText `
                    -Key 'Common.Prompt.Selection') -NoLeadingRule `
                -InputReader $InputReader
            if ([string]::IsNullOrWhiteSpace($Value)) {
                Write-InstallerLine -Text `
                    (Get-LocalizedText -Key 'Common.Selection.Invalid') `
                    -Color Yellow
                continue
            }
        }
        if ($Value -eq '0') {
            return 'Exit'
        }
        if ($Value -iin @('S', 'Skip')) {
            return 'Skip'
        }
        if ($Value -iin @('L', 'Local', 'Installed')) {
            $localNames = @(Get-InstallerInstalledModelNames `
                -Config $Config)
            if ($localNames.Count -gt 0) {
                return $localNames -join ','
            }
            if (-not $promptForSelection) {
                throw (Get-LocalizedText `
                    -Key 'Installer.Selection.NoInstalledModels')
            }
            Write-WinlamaUIStatus -Level WARN `
                -Message (Get-LocalizedText `
                    -Key 'Installer.Selection.NoInstalledModels')
            $Value = ''
            continue
        }
        if ($Value -iin @('K', 'Source', 'Package')) {
            $sourceNames = @(Get-InstallerSourceModelNames `
                -Config $Config)
            if ($sourceNames.Count -gt 0) {
                return $sourceNames -join ','
            }
            if (-not $promptForSelection) {
                throw (Get-LocalizedText `
                    -Key 'Installer.Selection.NoSourceModels')
            }
            Write-WinlamaUIStatus -Level WARN `
                -Message (Get-LocalizedText `
                    -Key 'Installer.Selection.NoSourceModels')
            $Value = ''
            continue
        }
        if ($Value -in @('A', 'a', 'Automatic', 'automatic')) {
            $recommended = Get-InstallerSelectedModelNames `
                -Config $Config -Hardware $Hardware -Automatic |
                Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($recommended)) {
                $recommended = Get-LocalizedText `
                    -Key 'Installer.Selection.AutomaticUnavailable'
            }
            Write-InstallerLog -Level INFO `
                -Message 'Installer.Selection.AutomaticChosen' `
                -MessageArguments @(
                    $Config.Models.DefaultContextK,
                    $recommended
                )
            return 'Automatic'
        }
        if ($Value.Trim().StartsWith('-')) {
            try {
                $indices = @(Resolve-WinlamaIndexSelection `
                    -Value $Value -Count $models.Count)
                return @($indices | ForEach-Object {
                    $models[$_ - 1].Name
                }) -join ','
            }
            catch {
                if (-not $promptForSelection) {
                    throw
                }
                Write-InstallerLine -Text (Get-LocalizedText `
                    -Key 'Common.Selection.Invalid') -Color Yellow
                $Value = ''
                continue
            }
        }
        $selected = [Collections.Generic.List[string]]::new()
        $invalidSelection = $false
        $invalidToken = ''
        foreach ($part in $Value.Split(',')) {
            $token = $part.Trim()
            $index = 0
            $model = $null
            if ([int]::TryParse($token, [ref]$index) -and
                $index -ge 1 -and $index -le $models.Count) {
                $model = $models[$index - 1]
            }
            else {
                $model = $models | Where-Object Name -eq $token |
                    Select-Object -First 1
            }
            if ($null -eq $model) {
                $invalidSelection = $true
                $invalidToken = $token
                break
            }
            if (-not $selected.Contains($model.Name)) {
                $selected.Add($model.Name)
            }
        }
        if ($invalidSelection -or $selected.Count -eq 0) {
            if ($promptForSelection) {
                Write-InstallerLog -Level WARN `
                    -Message 'Installer.Error.ModelSelectionInvalid' `
                    -MessageArguments @($invalidToken)
                Write-InstallerLine -Text (Get-LocalizedText `
                    -Key 'Installer.Error.ModelSelectionInvalid' `
                    -Arguments @($invalidToken)) -Color Yellow
                continue
            }
            throw (Get-LocalizedText `
                -Key 'Installer.Error.ModelSelectionInvalid' `
                -Arguments @($invalidToken))
        }
        return $selected -join ','
    }
}
function Set-InstallerModelSelection {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [string]$Selection
    )
    if ($Selection -eq 'Automatic') {
        $Config.Models.SelectionMode = 'Automatic'
        $Config.Models.Requested = @()
        return
    }
    if ($Selection -eq 'Skip') {
        $Config.Models.SelectionMode = 'Skip'
        $Config.Models.Requested = @()
        return
    }
    $Config.Models.SelectionMode = 'Manual'
    $Config.Models.Requested = @($Selection.Split(','))
}
function Get-InstallerSelectedModelNames {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Hardware,
        [switch]$Automatic
    )
    if ($Config.Models.SelectionMode -eq 'Skip') {
        return @()
    }
    if (-not $Automatic -and @($Config.Models.Requested).Count -gt 0) {
        return @($Config.Models.Requested)
    }
    $settings = $Config.Models.MemoryEstimation
    $candidates = foreach ($model in @($Config.Models.Catalog)) {
        $contextK = $Config.Models.DefaultContextK
        if ($model.MaxContextK -lt $contextK) {
            continue
        }
        $assessment = Get-InstallerModelAssessment `
            -Model $model -Hardware $Hardware `
            -Settings $settings -ContextK $contextK
        $buffer = 1 + (
            $Config.Models.SafetyBufferPercent / 100.0
        )
        $reservation = (
            $model.DownloadSizeGB + $model.WorkingSpaceGB
        ) * $buffer
        $requiredDisk = $model.DownloadSizeGB + $reservation
        $cpuReady = $Config.Hardware.AllowCpuFallback -and
            $model.CpuFallback
        if ($assessment.Rank -gt 0 -and
            $Hardware.FreeDiskGB -ge $requiredDisk -and
            ($Hardware.VramGB -gt 0 -or $cpuReady)) {
            [pscustomobject]@{
                Name = $model.Name
                Rank = $assessment.Rank
                Priority = $model.Priority
            }
        }
    }
    $selected = $candidates | Sort-Object `
        @{ Expression = 'Rank'; Descending = $true },
        @{ Expression = 'Priority'; Descending = $true } |
        Select-Object -First 1
    if ($null -eq $selected) {
        return @()
    }
    return @($selected.Name)
}
function Test-InstallerLocalModelPackage {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][pscustomobject]$Metadata,
        [switch]$VerifyHashes
    )
    $packageRoot = [IO.Path]::GetFullPath($PackagePath).TrimEnd('\')
    $packagePrefix = $packageRoot + '\'
    $manifestRelative = Join-Path 'manifests' `
        ([string]$Metadata.ManifestRelativePath)
    $manifestPath = [IO.Path]::GetFullPath(
        (Join-Path $packageRoot $manifestRelative)
    )
    if (-not $manifestPath.StartsWith(
        $packagePrefix,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }
    $expectedManifestHash = [string]$Metadata.ManifestSha256
    if ($expectedManifestHash -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-FileHash -LiteralPath $manifestPath `
            -Algorithm SHA256).Hash -ine $expectedManifestHash) {
        return $false
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw `
        -Encoding UTF8 | ConvertFrom-InstallerJson
    if ([int]$manifest.schemaVersion -ne
        [int]$Metadata.ManifestSchemaVersion -or
        @($Metadata.Blobs).Count -eq 0 -or
        [long]$Metadata.TotalSizeBytes -lt 1) {
        return $false
    }
    $manifestDigests = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($descriptor in @($manifest.config) + @($manifest.layers)) {
        if ($null -eq $descriptor -or
            -not $manifestDigests.Add([string]$descriptor.digest)) {
            return $false
        }
    }
    $metadataDigests = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $totalSize = 0L
    foreach ($blob in @($Metadata.Blobs)) {
        $digest = [string]$blob.Digest
        $relativePath = [string]$blob.File
        if ($digest -notmatch '^sha256:[a-fA-F0-9]{64}$' -or
            [string]::IsNullOrWhiteSpace($relativePath) -or
            -not $metadataDigests.Add($digest) -or
            -not $manifestDigests.Contains($digest) -or
            $relativePath.Replace('\', '/') -ine
                ('blobs/sha256-{0}' -f $digest.Substring(7))) {
            return $false
        }
        $blobPath = [IO.Path]::GetFullPath(
            (Join-Path $packageRoot $relativePath)
        )
        if (-not $blobPath.StartsWith(
            $packagePrefix,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not (Test-Path -LiteralPath $blobPath -PathType Leaf)) {
            return $false
        }
        $expectedSize = [long]$blob.Size
        $actualSize = (Get-Item -LiteralPath $blobPath).Length
        if ($expectedSize -lt 1 -or $actualSize -ne $expectedSize) {
            return $false
        }
        $totalSize += $actualSize
        if ($VerifyHashes -and
            (Get-InstallerFileSha256WithProgress `
                -Path $blobPath) -ine $digest.Substring(7)) {
            return $false
        }
    }
    return $totalSize -eq [long]$Metadata.TotalSizeBytes -and
        $metadataDigests.Count -eq $manifestDigests.Count
}
function Resolve-InstallerModelImportRoot {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$ConfiguredPath,
        [scriptblock]$ReparseProbe
    )
    $packagePath = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
    $resolved = Resolve-ConfigurationPath `
        -Path ([Environment]::ExpandEnvironmentVariables($ConfiguredPath)) `
        -BasePath $packagePath
    $resolved = [IO.Path]::GetFullPath($resolved).TrimEnd('\')
    $prefix = $packagePath + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith(
            $prefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw [IO.InvalidDataException]::new(
            "Model paket arama yolu kok disina cikiyor: $ConfiguredPath"
        )
    }
    $relative = $resolved.Substring($prefix.Length)
    $parameters = @{
        Root = $packagePath
        RelativePath = $relative
    }
    if ($null -ne $ReparseProbe) {
        $parameters.ReparseProbe = $ReparseProbe
    }
    return Resolve-InstallerContainedPackagePath @parameters
}
function Get-InstallerSafeModelMetadataFiles {
    param([Parameter(Mandatory)][string]$Root)
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($Root))
    while ($pending.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() `
            -Force -ErrorAction Stop) {
            if (($item.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw [IO.InvalidDataException]::new(
                    "Model paket agaci reparse noktasi iceriyor: $($item.FullName)"
                )
            }
            if ($item.PSIsContainer) {
                $pending.Push($item.FullName)
            }
            elseif ($item.Name -ceq 'package.json') {
                $files.Add($item)
            }
        }
    }
    return $files.ToArray()
}
function Get-InstallerLocalModelPackages {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string[]]$ModelNames,
        [switch]$VerifyHashes,
        [scriptblock]$PackageVerifier
    )
    $names = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in $ModelNames) {
        $null = $names.Add($name)
    }
    $matches = [Collections.Generic.List[object]]::new()
    foreach ($configuredRoot in @(
        $Config.ModelTransfer.ImportSearchDirectories
    )) {
        $root = Resolve-InstallerModelImportRoot `
            -PackageRoot $script:InstallerPackageRoot `
            -ConfiguredPath ([string]$configuredRoot)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        foreach ($file in @(Get-InstallerSafeModelMetadataFiles `
            -Root $root)) {
            try {
                $metadata = Get-Content -LiteralPath $file.FullName `
                    -Raw -Encoding UTF8 | ConvertFrom-InstallerJson
                $reference = [string]$metadata.OllamaReference
                if ($metadata.Format -ne 'ollama-portable-model' -or
                    [int]$metadata.FormatVersion -ne
                        [int]$Config.ModelTransfer.PackageFormatVersion -or
                    -not $names.Contains($reference)) {
                    continue
                }
                $packagePath = $file.Directory.FullName
                $packageValid = Test-InstallerLocalModelPackage `
                    -PackagePath $packagePath -Metadata $metadata
                if ($packageValid -and $VerifyHashes) {
                    $packageValid = if ($null -ne $PackageVerifier) {
                        [bool](& $PackageVerifier $packagePath $metadata)
                    }
                    else {
                        Test-InstallerLocalModelPackage `
                            -PackagePath $packagePath -Metadata $metadata `
                            -VerifyHashes
                    }
                }
                if (-not $packageValid) {
                    throw [IO.InvalidDataException]::new(
                        "Yerel model paketi dogrulanamadi: $packagePath"
                    )
                }
                $matches.Add([pscustomobject]@{
                    Name = $reference
                    PackagePath = $packagePath
                    ExportedAt = [string]$metadata.ExportedAt
                    Metadata = $metadata
                })
            }
            catch {
                Write-InstallerLog -Level WARN `
                    -Message 'Installer.LocalPackages.InvalidSkipped' `
                    -MessageArguments @($file.Directory.FullName) `
                    -Exception $_.Exception
            }
        }
    }
    $selected = foreach ($group in @($matches | Group-Object Name)) {
        $group.Group | Sort-Object ExportedAt -Descending |
            Select-Object -First 1
    }
    return @($selected)
}
function Set-InstallerLocalPackageSelection {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Hardware,
        [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
        [string]$SourceSelection = 'Prompt',
        [scriptblock]$InputReader,
        [bool]$VerifyLocalIdentity = $true,
        [bool]$VerifyLocalContentHash = $true,
        [scriptblock]$PackageVerifier,
        [scriptblock]$PackageReader,
        [AllowEmptyCollection()][string[]]$ModelNames
    )
    $SourceSelection = ConvertTo-InstallerSourceSelection `
        -Selection $SourceSelection
    $Config.Models.LocalPackageImport.SelectedPackages = @()
    $modelNames = @(if ($PSBoundParameters.ContainsKey('ModelNames')) {
        $ModelNames | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        }
    }
    else {
        Get-InstallerSelectedModelNames -Config $Config `
            -Hardware $Hardware
    })
    if ($modelNames.Count -eq 0) {
        $Config.Models | Add-Member -NotePropertyName InstallSource `
            -NotePropertyValue Online -Force
        return 'Online'
    }
    if ($SourceSelection -eq 'Online') {
        $Config.Models | Add-Member -NotePropertyName InstallSource `
            -NotePropertyValue Online -Force
        Write-InstallerLog -Level INFO `
            -Message 'Installer.LocalPackages.Declined'
        return 'Online'
    }
    if (-not $VerifyLocalIdentity) {
        $provisionalSource = if ($SourceSelection -eq 'Local') {
            'Local'
        }
        else {
            'Automatic'
        }
        $Config.Models | Add-Member -NotePropertyName InstallSource `
            -NotePropertyValue $provisionalSource -Force
        return $provisionalSource
    }
    $packages = @(if ($null -ne $PackageReader) {
        & $PackageReader -Config $Config -ModelNames $modelNames
    }
    else {
        Get-InstallerLocalModelPackages -Config $Config `
            -ModelNames $modelNames
    })
    $byName = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($package in $packages) {
        $byName[$package.Name] = $package
    }
    Write-InstallerSection -Title 'Installer.Section.LocalPackages'
    foreach ($modelName in $modelNames) {
        if ($byName.ContainsKey($modelName)) {
            Write-InstallerSourceTableRow -Source Local `
                -Name $modelName `
                -Detail $byName[$modelName].PackagePath -Available
        }
        else {
            Write-InstallerSourceTableRow -Source Online `
                -Name $modelName -Detail (Get-LocalizedText `
                    -Key 'Installer.LocalPackages.Missing')
        }
    }
    if ($packages.Count -eq 0) {
        Write-InstallerLog -Level INFO `
            -Message 'Installer.LocalPackages.NoneAvailable'
        if ($SourceSelection -eq 'Local') {
            throw (New-NonRetryableException -Message (
                Get-LocalizedText `
                    -Key 'Installer.LocalPackages.RequiredMissing' `
                    -Arguments @(($modelNames -join ', '))
            ))
        }
        $fallbackSource = if ($SourceSelection -eq 'Automatic' -and
            -not $VerifyLocalIdentity) { 'Automatic' } else { 'Online' }
        $Config.Models | Add-Member -NotePropertyName InstallSource `
            -NotePropertyValue $fallbackSource -Force
        return 'Online'
    }
    $resolvedSource = $SourceSelection
    if ($resolvedSource -eq 'Automatic') {
        $resolvedSource = 'Local'
    }
    elseif ($resolvedSource -eq 'Prompt') {
        if ([Environment]::UserInteractive -and
            $Config.Models.LocalPackageImport.PromptWhenAvailable) {
            $choice = Read-InstallerComponentSelection `
                -SectionKey 'Installer.Section.ModelSource' `
                -DescriptionKey 'Installer.ModelSource.Description' `
                -PromptKey 'Installer.Prompt.UseLocalPackages' `
                -DefaultEnabled $true -InputReader $InputReader
            if ($choice -eq 'Exit') {
                return 'Exit'
            }
            $resolvedSource = if ($choice -eq 'Install') {
                'Local'
            }
            else {
                'Online'
            }
        }
        else {
            $resolvedSource = if (
                $Config.Models.LocalPackageImport.UseLocalWhenNonInteractive
            ) {
                'Local'
            }
            else {
                'Online'
            }
        }
    }
    if ($resolvedSource -eq 'Online') {
        $Config.Models | Add-Member -NotePropertyName InstallSource `
            -NotePropertyValue Online -Force
        Write-InstallerLog -Level INFO `
            -Message 'Installer.LocalPackages.Declined'
        return 'Online'
    }
    $missingPackages = @($modelNames | Where-Object {
        -not $byName.ContainsKey($_)
    })
    if ($resolvedSource -eq 'Local' -and
        $SourceSelection -ne 'Automatic' -and
        $missingPackages.Count -gt 0) {
        throw (New-NonRetryableException -Message (
            Get-LocalizedText `
                -Key 'Installer.LocalPackages.RequiredMissing' `
                -Arguments @(($missingPackages -join ', '))
        ))
    }
    if ($SourceSelection -eq 'Automatic' -and
        $VerifyLocalIdentity -and $missingPackages.Count -gt 0) {
        $Config.Models.LocalPackageImport.SelectedPackages = @()
        $Config.Models | Add-Member -NotePropertyName InstallSource `
            -NotePropertyValue Online -Force
        Write-InstallerLog -Level INFO `
            -Message 'Installer.LocalPackages.Declined'
        return 'Online'
    }
    if ($VerifyLocalIdentity) {
        $verifiedPackages = [Collections.Generic.List[object]]::new()
        foreach ($package in $packages) {
            $packageValid = Test-InstallerLocalModelPackage `
                -PackagePath $package.PackagePath `
                -Metadata $package.Metadata
            if ($packageValid -and $VerifyLocalContentHash) {
                $packageValid = if ($null -ne $PackageVerifier) {
                    [bool](& $PackageVerifier `
                        $package.PackagePath $package.Metadata)
                }
                else {
                    Test-InstallerLocalModelPackage `
                        -PackagePath $package.PackagePath `
                        -Metadata $package.Metadata -VerifyHashes
                }
            }
            if ($packageValid) {
                $verifiedPackages.Add($package)
            }
        }
        if ($verifiedPackages.Count -ne $modelNames.Count) {
            if ($SourceSelection -eq 'Automatic') {
                $Config.Models.LocalPackageImport.SelectedPackages = @()
                $Config.Models | Add-Member `
                    -NotePropertyName InstallSource `
                    -NotePropertyValue Online -Force
                return 'Online'
            }
            throw (New-NonRetryableException -Message (
                Get-LocalizedText `
                    -Key 'Installer.LocalPackages.RequiredMissing' `
                    -Arguments @(($modelNames -join ', '))
            ))
        }
        $packages = @($verifiedPackages.ToArray())
    }
    $Config.Models.LocalPackageImport.SelectedPackages = @(
        $packages.PackagePath
    )
    $modelInstallSource = if ($SourceSelection -eq 'Automatic' -and
        $VerifyLocalIdentity) {
        'Local'
    }
    elseif ($SourceSelection -eq 'Automatic' -or
        ($SourceSelection -eq 'Prompt' -and
            -not [Environment]::UserInteractive)) {
        'Automatic'
    }
    else {
        $resolvedSource
    }
    $Config.Models | Add-Member -NotePropertyName InstallSource `
        -NotePropertyValue $modelInstallSource -Force
    Write-InstallerLog -Level INFO `
        -Message 'Installer.LocalPackages.Selected' `
        -MessageArguments @($packages.Count)
    return 'Local'
}
function Save-EffectiveInstallerConfig {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $Config.Paths.Root = Resolve-InstallerPath `
        -Path $Config.Paths.Root
    $Config.Paths.Models = Resolve-InstallerPath `
        -Path $Config.Paths.Models
    $Config.Paths.Temp = Resolve-InstallerPath `
        -Path $Config.Paths.Temp
    $Config.Ollama.InstallPath = Resolve-InstallerPath `
        -Path $Config.Ollama.InstallPath
    $Config.OpenWebUI.RootPath = Resolve-InstallerPath `
        -Path $Config.OpenWebUI.RootPath
    $Config.Startup.ShortcutPath = Resolve-InstallerPath `
        -Path $Config.Startup.ShortcutPath
    foreach ($name in @('InstallPath', 'ModelsPath')) {
        $Config.ComfyUI.$name = Resolve-InstallerPath `
            -Path $Config.ComfyUI.$name
    }
    $tempPath = Resolve-InstallerPath -Path $Config.Paths.Temp
    $path = Join-Path $tempPath 'effective-config.json'
    [IO.Directory]::CreateDirectory($tempPath) | Out-Null
    $temporary = "$path.$PID.tmp"
    $json = ConvertTo-StableJson -Value $Config -Depth 100
    [IO.File]::WriteAllText(
        $temporary,
        $json,
        [Text.UTF8Encoding]::new($false)
    )
    try {
        Move-Item -LiteralPath $temporary -Destination $path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
    }
    return $path
}
function Get-InstallerComfyUIModelsRoot {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    $path = [Environment]::ExpandEnvironmentVariables(
        $Config.ComfyUI.ModelsPath
    )
    if (-not [IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $ProjectRoot $path
    }
    return [IO.Path]::GetFullPath($path)
}
function Get-InstallerComfyUIEmbeddedModelsRoot {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $runtime = Resolve-InstallerPath `
        -Path ([string]$Config.ComfyUI.InstallPath)
    return [IO.Path]::GetFullPath(
        (Join-Path $runtime 'ComfyUI\models')
    )
}
function Get-InstallerComfyUIModelSearchRoots {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    $roots = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in @(
        (Get-InstallerComfyUIModelsRoot `
            -Config $Config -ProjectRoot $ProjectRoot),
        (Get-InstallerComfyUIEmbeddedModelsRoot -Config $Config)
    )) {
        $resolved = [IO.Path]::GetFullPath($path).TrimEnd('\')
        if ($seen.Add($resolved)) {
            $roots.Add($resolved)
        }
    }
    return $roots.ToArray()
}
function Test-InstallerComfyUIRuntimeLayout {
    param([Parameter(Mandatory)][string]$Path)
    return (Test-Path -LiteralPath (Join-Path $Path `
        'python_embeded\python.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path `
        'ComfyUI\main.py') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path `
        'run_nvidia_gpu_fast_fp16_accumulation.bat') -PathType Leaf)
}
function Test-InstallerComfyUIRuntimePresent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$LayoutVerifier,
        [scriptblock]$ReparseVerifier
    )
    $reparseSafe = if ($null -ne $ReparseVerifier) {
        [bool](& $ReparseVerifier -Path $Path)
    }
    else {
        Test-InstallerComfyUIReparseChain -Path $Path
    }
    if (-not $reparseSafe) {
        return $false
    }
    if ($null -ne $LayoutVerifier) {
        return [bool](& $LayoutVerifier -Path $Path)
    }
    return Test-InstallerComfyUIRuntimeLayout -Path $Path
}
function ConvertTo-InstallerComfyUILauncherArgumentContent {
    param([Parameter(Mandatory)][string]$Content)
    $content = ($Content -replace "`r?`n", "`r`n").TrimEnd(
        "`r", "`n"
    )
    $content = [regex]::Replace(
        $content,
        '(?im)^\s*@?pause\s*(?:\r\n|$)',
        ''
    ).TrimEnd("`r", "`n")
    if ($content -match
        '(?im)^\s*\.\\python_embeded\\python\.exe\b[^\r\n]*%\*\s*$') {
        return $content
    }
    $pattern =
        '(?im)^(\s*\.\\python_embeded\\python\.exe\b[^\r\n]*)\r?$'
    if ($content -notmatch $pattern) {
        throw (Get-LocalizedText `
            -Key 'Installer.ComfyUI.RuntimePackageInvalid')
    }
    $regex = [regex]::new($pattern)
    $content = $regex.Replace($content, '$1 %*', 1)
    return $content.TrimEnd("`r", "`n")
}
function Enable-InstallerComfyUILauncherArguments {
    param([Parameter(Mandatory)][string]$Path)
    $launcher = Join-Path $Path `
        'run_nvidia_gpu_fast_fp16_accumulation.bat'
    $source = [IO.File]::ReadAllText($launcher)
    $content = ConvertTo-InstallerComfyUILauncherArgumentContent `
        -Content $source
    if ($content -ceq $source) {
        return
    }
    [IO.File]::WriteAllText(
        $launcher,
        $content,
        [Text.UTF8Encoding]::new($false)
    )
}
function Update-InstallerComfyUILauncherContract {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $launcher = Join-Path $Path `
        'run_nvidia_gpu_fast_fp16_accumulation.bat'
    $source = [IO.File]::ReadAllText($launcher)
    $content = ConvertTo-InstallerComfyUILauncherArgumentContent `
        -Content $source
    if ($content -ceq $source) {
        return $true
    }
    $preState = Get-InstallerComfyUIRuntimeState `
        -Path $Path -Config $Config
    if (-not $preState.Ready) {
        throw ('ComfyUI baslatici gecisi icin runtime kimligi ' +
            "dogrulanamadi: $($preState.ReasonCode)")
    }
    $markerPath = Join-Path $Path '.winlama-runtime.json'
    $launcherBytes = [IO.File]::ReadAllBytes($launcher)
    $markerBytes = [IO.File]::ReadAllBytes($markerPath)
    try {
        Enable-InstallerComfyUILauncherArguments -Path $Path
        Write-InstallerComfyUIRuntimeMarker -Path $Path -Config $Config
        $postState = Get-InstallerComfyUIRuntimeState `
            -Path $Path -Config $Config
        if (-not $postState.Ready) {
            throw ('ComfyUI baslatici gecisi dogrulanamadi: ' +
                $postState.ReasonCode)
        }
    }
    catch {
        [IO.File]::WriteAllBytes($launcher, $launcherBytes)
        [IO.File]::WriteAllBytes($markerPath, $markerBytes)
        throw
    }
    return $true
}
function Get-InstallerComfyUICoreIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $phase = Get-LocalizedText `
        -Key 'Installer.ComfyUI.TreeHash.Core'
    Write-InstallerLog -Level INFO `
        -Message 'Installer.ComfyUI.TreeHash.Starting' `
        -MessageArguments @($phase)
    $excludedPrefixes = @(
        'ComfyUI\custom_nodes\',
        'ComfyUI\input\',
        'ComfyUI\output\',
        'ComfyUI\temp\',
        'ComfyUI\user\',
        'python_embeded\Lib\site-packages\',
        'python_embeded\Scripts\',
        'WinlamaLogs\'
    )
    $entries = [Collections.Generic.List[string]]::new()
    $processedBytes = 0L
    $progressClock = [Diagnostics.Stopwatch]::StartNew()
    $treeFiles = @(Get-InstallerReparseSafeTreeFiles -Root $root `
        -ExcludedRelativeDirectories @(
            '.winlama',
            'ComfyUI\custom_nodes',
            'ComfyUI\input',
            'ComfyUI\output',
            'ComfyUI\temp',
            'ComfyUI\user',
            'python_embeded\Lib\site-packages',
            'python_embeded\Scripts',
            'WinlamaLogs'
        ) -ExcludedDirectoryNames @('__pycache__') `
        -ProgressPhase $phase)
    foreach ($file in $treeFiles) {
        $relative = $file.FullName.Substring($root.Length).
            TrimStart('\')
        if ($relative -ieq '.winlama-runtime.json' -or
            $relative.StartsWith(
                '.winlama\',
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            $relative -ieq 'ComfyUI\extra_model_paths.yaml' -or
            $relative -match '(^|[\\/])__pycache__([\\/]|$)' -or
            $file.Extension -iin @('.pyc', '.pyo') -or
            $null -ne ($excludedPrefixes | Where-Object {
                $relative.StartsWith(
                    $_,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } | Select-Object -First 1)) {
            continue
        }
        $fileHash = (Get-InstallerFileSha256WithProgress `
            -Path $file.FullName).ToUpperInvariant()
        $entries.Add(('{0}|{1}|{2}' -f `
            $relative.Replace('\', '/'),
            [long]$file.Length,
            $fileHash
        ))
        $processedBytes += [long]$file.Length
        if ($progressClock.Elapsed.TotalSeconds -ge 15) {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.ComfyUI.TreeHash.Progress' `
                -MessageArguments @(
                    $phase,
                    $entries.Count,
                    ($processedBytes / 1GB)
                )
            $progressClock.Restart()
        }
    }
    $entries.Sort([StringComparer]::Ordinal)
    $builder = [Text.StringBuilder]::new()
    foreach ($entry in $entries) {
        $null = $builder.Append($entry)
        $null = $builder.Append("`n")
    }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($builder.ToString())
        )
    }
    finally {
        $algorithm.Dispose()
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.ComfyUI.TreeHash.Completed' `
        -MessageArguments @(
            $phase,
            $entries.Count,
            ($processedBytes / 1GB)
        )
    return [pscustomobject]@{
        FileCount = $entries.Count
        Sha256 = [BitConverter]::ToString($hash).Replace('-', '')
    }
}
function Get-InstallerComfyUILocalRuntimeIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $phase = Get-LocalizedText `
        -Key 'Installer.ComfyUI.TreeHash.Local'
    Write-InstallerLog -Level INFO `
        -Message 'Installer.ComfyUI.TreeHash.Starting' `
        -MessageArguments @($phase)
    $excludedPrefixes = @(
        '.winlama\',
        'ComfyUI\user\',
        'ComfyUI\input\',
        'ComfyUI\output\',
        'ComfyUI\temp\',
        'WinlamaLogs\'
    )
    $entries = [Collections.Generic.List[string]]::new()
    $bytes = 0L
    $progressClock = [Diagnostics.Stopwatch]::StartNew()
    $treeFiles = @(Get-InstallerReparseSafeTreeFiles -Root $root `
        -ExcludedRelativeDirectories @(
            '.winlama',
            'ComfyUI\user',
            'ComfyUI\input',
            'ComfyUI\output',
            'ComfyUI\temp',
            'WinlamaLogs'
        ) -ExcludedDirectoryNames @('__pycache__') `
        -ProgressPhase $phase)
    foreach ($file in $treeFiles) {
        $relative = $file.FullName.Substring($root.Length).
            TrimStart('\')
        if ($relative -ieq '.winlama-runtime.json' -or
            $relative -ieq 'ComfyUI\extra_model_paths.yaml' -or
            $relative -match '(^|[\\/])__pycache__([\\/]|$)' -or
            $file.Extension -iin @('.pyc', '.pyo') -or
            $null -ne ($excludedPrefixes | Where-Object {
                $relative.StartsWith(
                    $_,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } | Select-Object -First 1)) {
            continue
        }
        $fileHash = (Get-InstallerFileSha256WithProgress `
            -Path $file.FullName).ToUpperInvariant()
        $entries.Add(('{0}|{1}|{2}' -f
            $relative.Replace('\', '/'),
            [long]$file.Length,
            $fileHash
        ))
        $bytes += [long]$file.Length
        if ($progressClock.Elapsed.TotalSeconds -ge 15) {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.ComfyUI.TreeHash.Progress' `
                -MessageArguments @(
                    $phase,
                    $entries.Count,
                    ($bytes / 1GB)
                )
            $progressClock.Restart()
        }
    }
    $entries.Sort([StringComparer]::Ordinal)
    $builder = [Text.StringBuilder]::new()
    foreach ($entry in $entries) {
        $null = $builder.Append($entry)
        $null = $builder.Append("`n")
    }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash(
            [Text.UTF8Encoding]::new($false).GetBytes(
                $builder.ToString()
            )
        )
    }
    finally {
        $algorithm.Dispose()
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.ComfyUI.TreeHash.Completed' `
        -MessageArguments @(
            $phase,
            $entries.Count,
            ($bytes / 1GB)
        )
    return [pscustomobject]@{
        FileCount = $entries.Count
        Bytes = $bytes
        Sha256 = [BitConverter]::ToString($hash).Replace('-', '')
    }
}
function Test-InstallerComfyUILocalRuntimeIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [scriptblock]$IdentityReader
    )
    try {
        $property = $Config.ComfyUI.PSObject.Properties[
            'LocalRuntimeIdentity'
        ]
        if ($null -eq $property) {
            return $false
        }
        $expected = $property.Value
        if ([int]$expected.SchemaVersion -ne 1 -or
            [int]$expected.FileCount -lt 1 -or
            [long]$expected.Bytes -lt 1 -or
            [string]$expected.Sha256 -notmatch
                '^[a-fA-F0-9]{64}$') {
            return $false
        }
        $actual = if ($null -ne $IdentityReader) {
            & $IdentityReader -Path $Path
        }
        else {
            Get-InstallerComfyUILocalRuntimeIdentity -Path $Path
        }
        return [int]$actual.FileCount -eq
                [int]$expected.FileCount -and
            [long]$actual.Bytes -eq [long]$expected.Bytes -and
            [string]$actual.Sha256 -ieq [string]$expected.Sha256
    }
    catch {
        Write-Verbose ('ComfyUI local runtime kimligi ' +
            "dogrulanamadi: $($_.Exception.Message)")
        return $false
    }
}
function Test-InstallerComfyUIRuntimeMarker {
    param(
        [Parameter(Mandatory)][pscustomobject]$Marker,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$CoreIdentity
    )
    return [int]$Marker.SchemaVersion -eq 1 -and
        [string]$Marker.PortableVersion -ceq
            [string]$Config.ComfyUI.PortableVersion -and
        [string]$Marker.ArchiveSha256 -ieq
            [string]$Config.ComfyUI.PortableSha256 -and
        [long]$Marker.ArchiveSizeBytes -eq
            [long]$Config.ComfyUI.PortableSizeBytes -and
        [int]$Marker.CoreFileCount -eq
            [int]$CoreIdentity.FileCount -and
        [string]$Marker.CoreSha256 -ieq
            [string]$CoreIdentity.Sha256
}
function Test-InstallerComfyUIRuntimeMarkerProbe {
    param(
        [Parameter(Mandatory)][pscustomobject]$Marker,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    return [int]$Marker.SchemaVersion -eq 1 -and
        [string]$Marker.PortableVersion -ceq
            [string]$Config.ComfyUI.PortableVersion -and
        [string]$Marker.ArchiveSha256 -ieq
            [string]$Config.ComfyUI.PortableSha256 -and
        [long]$Marker.ArchiveSizeBytes -eq
            [long]$Config.ComfyUI.PortableSizeBytes -and
        [int]$Marker.CoreFileCount -gt 0 -and
        [string]$Marker.CoreSha256 -match '^[a-fA-F0-9]{64}$'
}
function Assert-InstallerComfyUIRuntimeContracts {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $identity = [pscustomobject]@{
        FileCount = 3
        Sha256 = 'A' * 64
    }
    $current = [pscustomobject]@{
        SchemaVersion = 1
        PortableVersion = [string]$Config.ComfyUI.PortableVersion
        ArchiveSha256 = [string]$Config.ComfyUI.PortableSha256
        ArchiveSizeBytes = [long]$Config.ComfyUI.PortableSizeBytes
        CoreFileCount = 3
        CoreSha256 = 'A' * 64
    }
    if (-not (Test-InstallerComfyUIRuntimeMarker `
        -Marker $current -Config $Config -CoreIdentity $identity)) {
        throw 'Guncel ComfyUI runtime kimligi reddedildi.'
    }
    $old = $current | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $old.PortableVersion = '0.0.0'
    if (Test-InstallerComfyUIRuntimeMarker `
        -Marker $old -Config $Config -CoreIdentity $identity) {
        throw 'Eski ComfyUI runtime kimligi kabul edildi.'
    }
    $corrupt = $current | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $corrupt.CoreSha256 = 'B' * 64
    if (Test-InstallerComfyUIRuntimeMarker `
        -Marker $corrupt -Config $Config -CoreIdentity $identity) {
        throw 'Bozuk ComfyUI runtime cekirdegi kabul edildi.'
    }
    $localExpected = $Config.ComfyUI.LocalRuntimeIdentity
    $localIdentity = [pscustomobject]@{
        FileCount = [int]$localExpected.FileCount
        Bytes = [long]$localExpected.Bytes
        Sha256 = [string]$localExpected.Sha256
    }
    if (-not (Test-InstallerComfyUILocalRuntimeIdentity `
        -Path 'C:\Fixture\Runtime' -Config $Config `
        -IdentityReader { $localIdentity }.GetNewClosure())) {
        throw 'ComfyUI local runtime kimligi reddedildi.'
    }
    $corruptLocalIdentity = [pscustomobject]@{
        FileCount = [int]$localExpected.FileCount
        Bytes = [long]$localExpected.Bytes
        Sha256 = 'C' * 64
    }
    if (Test-InstallerComfyUILocalRuntimeIdentity `
        -Path 'C:\Fixture\Runtime' -Config $Config `
        -IdentityReader {
            $corruptLocalIdentity
        }.GetNewClosure()) {
        throw 'Bozuk ComfyUI local runtime kimligi kabul edildi.'
    }
    $fixturePath = 'C:\Fixture\Runtime\ComfyUI'
    $layoutFailure = Get-InstallerComfyUIRuntimeState `
        -Path $fixturePath -Config $Config `
        -LayoutVerifier { $false }
    $markerFailure = Get-InstallerComfyUIRuntimeState `
        -Path $fixturePath -Config $Config `
        -LayoutVerifier { $true } `
        -MarkerReader { $old }.GetNewClosure()
    $hashFailure = Get-InstallerComfyUIRuntimeState `
        -Path $fixturePath -Config $Config `
        -LayoutVerifier { $true } `
        -MarkerReader { $current }.GetNewClosure() `
        -IdentityReader {
            [pscustomobject]@{
                FileCount = 3
                Sha256 = 'B' * 64
            }
        }
    $readyState = Get-InstallerComfyUIRuntimeState `
        -Path $fixturePath -Config $Config `
        -LayoutVerifier { $true } `
        -MarkerReader { $current }.GetNewClosure() `
        -IdentityReader { $identity }.GetNewClosure()
    $reparseProbe = [pscustomobject]@{
        Count = 0
        Root = ''
        IdentityCalls = 0
    }
    $reparseFailure = Get-InstallerComfyUIRuntimeState `
        -Path $fixturePath -Config $Config -VerifyIdentity $false `
        -LayoutVerifier { $true } `
        -TreeReparseVerifier {
            param([string]$Root)
            $reparseProbe.Count++
            $reparseProbe.Root = $Root
            return $false
        }.GetNewClosure() `
        -IdentityReader {
            $reparseProbe.IdentityCalls++
            throw 'Reparse reddinden sonra kimlik okundu.'
        }.GetNewClosure()
    $questionIdentityCalls = [pscustomobject]@{ Count = 0 }
    $questionState = Get-InstallerComfyUIRuntimeState `
        -Path $fixturePath -Config $Config -VerifyIdentity $false `
        -LayoutVerifier { $true } `
        -MarkerReader { $current }.GetNewClosure() `
        -IdentityReader {
            $questionIdentityCalls.Count++
            throw 'Soru asamasinda agir kimlik okundu.'
        }.GetNewClosure()
    if ($layoutFailure.ReasonCode -cne 'CORE_LAYOUT' -or
        $markerFailure.ReasonCode -cne 'CORE_MARKER' -or
        $hashFailure.ReasonCode -cne 'CORE_HASH' -or
        $reparseFailure.ReasonCode -cne 'CORE_REPARSE' -or
        $reparseProbe.Count -ne 1 -or
        $reparseProbe.Root -cne $fixturePath -or
        $reparseProbe.IdentityCalls -ne 0 -or
        -not $readyState.Ready -or
        $readyState.ReasonCode -cne 'READY' -or
        -not $questionState.Ready -or
        $questionIdentityCalls.Count -ne 0) {
        throw 'ComfyUI runtime reason-code sozlesmesi gecersiz.'
    }
    $launcherSource = '@echo off' + "`n" +
        '.\python_embeded\python.exe -s ComfyUI\main.py --fast ' +
        'fp16_accumulation' + "`n" +
        '@pause' + "`n"
    $launcherFirst = `
        ConvertTo-InstallerComfyUILauncherArgumentContent `
            -Content $launcherSource
    $launcherSecond = `
        ConvertTo-InstallerComfyUILauncherArgumentContent `
            -Content $launcherFirst
    $alreadyEnabled = `
        ConvertTo-InstallerComfyUILauncherArgumentContent `
            -Content ($launcherSource.Replace(
                'fp16_accumulation',
                'fp16_accumulation %*'
            ))
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $firstHash = [BitConverter]::ToString(
            $algorithm.ComputeHash(
                [Text.Encoding]::UTF8.GetBytes($launcherFirst)
            )
        ).Replace('-', '')
        $secondHash = [BitConverter]::ToString(
            $algorithm.ComputeHash(
                [Text.Encoding]::UTF8.GetBytes($launcherSecond)
            )
        ).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
    $launcherIdentity = [pscustomobject]@{
        FileCount = 1
        Sha256 = $firstHash
    }
    $launcherMarker = [pscustomobject]@{
        SchemaVersion = 1
        PortableVersion = [string]$Config.ComfyUI.PortableVersion
        ArchiveSha256 = [string]$Config.ComfyUI.PortableSha256
        ArchiveSizeBytes = [long]$Config.ComfyUI.PortableSizeBytes
        CoreFileCount = 1
        CoreSha256 = $firstHash
    }
    $secondIdentity = [pscustomobject]@{
        FileCount = 1
        Sha256 = $secondHash
    }
    if ($launcherFirst -cne $launcherSecond -or
        $launcherFirst -cne $alreadyEnabled -or
        ([regex]::Matches(
            $launcherFirst,
            '(?m)%\*\r?$'
        )).Count -ne 1 -or
        $launcherFirst -match '(?im)^\s*@?pause\s*$' -or
        $launcherFirst -match '(?<!\r)\n' -or
        $launcherFirst.EndsWith("`n") -or
        -not (Test-InstallerComfyUIRuntimeMarker `
            -Marker $launcherMarker -Config $Config `
            -CoreIdentity $launcherIdentity) -or
        -not (Test-InstallerComfyUIRuntimeMarker `
            -Marker $launcherMarker -Config $Config `
            -CoreIdentity $secondIdentity)) {
        throw 'ComfyUI baslatici kimlik kararliligi gecersiz.'
    }
    $transitionRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('Winlama-ComfyLauncher-' + [guid]::NewGuid().ToString('N'))
    try {
        $pythonPath = Join-Path $transitionRoot `
            'python_embeded\python.exe'
        $mainPath = Join-Path $transitionRoot 'ComfyUI\main.py'
        $launcherPath = Join-Path $transitionRoot `
            'run_nvidia_gpu_fast_fp16_accumulation.bat'
        [IO.Directory]::CreateDirectory(
            [IO.Path]::GetDirectoryName($pythonPath)
        ) | Out-Null
        [IO.Directory]::CreateDirectory(
            [IO.Path]::GetDirectoryName($mainPath)
        ) | Out-Null
        [IO.File]::WriteAllBytes($pythonPath, [byte[]](1, 2, 3))
        [IO.File]::WriteAllText(
            $mainPath,
            'fixture',
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            $launcherPath,
            $launcherSource,
            [Text.UTF8Encoding]::new($false)
        )
        Write-InstallerComfyUIRuntimeMarker `
            -Path $transitionRoot -Config $Config
        $legacyState = Get-InstallerComfyUIRuntimeState `
            -Path $transitionRoot -Config $Config
        $null = Update-InstallerComfyUILauncherContract `
            -Path $transitionRoot -Config $Config
        $updatedLauncher = [IO.File]::ReadAllText($launcherPath)
        $updatedState = Get-InstallerComfyUIRuntimeState `
            -Path $transitionRoot -Config $Config
        $firstMarker = [IO.File]::ReadAllBytes(
            (Join-Path $transitionRoot '.winlama-runtime.json')
        )
        $null = Update-InstallerComfyUILauncherContract `
            -Path $transitionRoot -Config $Config
        $secondMarker = [IO.File]::ReadAllBytes(
            (Join-Path $transitionRoot '.winlama-runtime.json')
        )
        [IO.File]::WriteAllText(
            $mainPath,
            'tampered',
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            $launcherPath,
            $launcherSource,
            [Text.UTF8Encoding]::new($false)
        )
        $rejectedLauncher = [IO.File]::ReadAllBytes($launcherPath)
        $rejectedMarker = [IO.File]::ReadAllBytes(
            (Join-Path $transitionRoot '.winlama-runtime.json')
        )
        $tamperRejected = $false
        try {
            $null = Update-InstallerComfyUILauncherContract `
                -Path $transitionRoot -Config $Config
        }
        catch {
            $tamperRejected = $true
        }
        if (-not $legacyState.Ready -or -not $updatedState.Ready -or
            $updatedLauncher -cne $launcherFirst -or
            [Convert]::ToBase64String($firstMarker) -cne
                [Convert]::ToBase64String($secondMarker) -or
            -not $tamperRejected -or
            [Convert]::ToBase64String($rejectedLauncher) -cne
                [Convert]::ToBase64String(
                    [IO.File]::ReadAllBytes($launcherPath)
                ) -or
            [Convert]::ToBase64String($rejectedMarker) -cne
                [Convert]::ToBase64String(
                    [IO.File]::ReadAllBytes(
                        (Join-Path $transitionRoot `
                            '.winlama-runtime.json')
                    )
                )) {
            throw 'ComfyUI baslatici gecis islemi sozlesmesi gecersiz.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $transitionRoot) {
            Remove-Item -LiteralPath $transitionRoot -Recurse -Force
        }
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:ComfyUI.LauncherRuntimeIdentity'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:ComfyUI.LauncherIdentityTransition'
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.RuntimeReasonCodes'
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.RuntimeIdentity'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:ComfyUI.LocalRuntimeIdentity'
}
function Write-InstallerComfyUIRuntimeMarker {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $identity = Get-InstallerComfyUICoreIdentity -Path $Path
    $marker = [pscustomobject][ordered]@{
        SchemaVersion = 1
        PortableVersion = [string]$Config.ComfyUI.PortableVersion
        ArchiveSha256 = [string]$Config.ComfyUI.PortableSha256
        ArchiveSizeBytes = [long]$Config.ComfyUI.PortableSizeBytes
        CoreFileCount = [int]$identity.FileCount
        CoreSha256 = [string]$identity.Sha256
    }
    Write-AtomicTextFile `
        -Path (Join-Path $Path '.winlama-runtime.json') `
        -Content (ConvertTo-StableJson -Value $marker -Depth 5)
}
function New-InstallerComfyUIDiagnosticResult {
    param(
        [Parameter(Mandatory)][bool]$Ready,
        [Parameter(Mandatory)][string]$ReasonCode,
        [string]$Detail = ''
    )
    return [pscustomobject][ordered]@{
        Ready = $Ready
        ReasonCode = if ($Ready) { 'READY' } else { $ReasonCode }
        Detail = $Detail
    }
}
function ConvertTo-InstallerComfyUIDiagnosticResult {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$FailureReasonCode,
        [string]$Detail = ''
    )
    if ($Value -is [bool]) {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $Value -ReasonCode $FailureReasonCode `
            -Detail $Detail
    }
    if ($null -ne $Value) {
        $readyProperty = $Value.PSObject.Properties['Ready']
        $reasonProperty = $Value.PSObject.Properties['ReasonCode']
        $detailProperty = $Value.PSObject.Properties['Detail']
        if ($null -ne $readyProperty -and
            $null -ne $reasonProperty) {
            return New-InstallerComfyUIDiagnosticResult `
                -Ready ([bool]$readyProperty.Value) `
                -ReasonCode ([string]$reasonProperty.Value) `
                -Detail $(if ($null -eq $detailProperty) {
                    $Detail
                }
                else {
                    [string]$detailProperty.Value
                })
        }
    }
    return New-InstallerComfyUIDiagnosticResult `
        -Ready $false -ReasonCode $FailureReasonCode `
        -Detail $Detail
}
function Format-InstallerComfyUIDiagnosticResult {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    return Get-LocalizedText `
        -Key 'Installer.ComfyUI.Diagnostic' `
        -Arguments @($Result.ReasonCode, $Result.Detail)
}
function Get-InstallerComfyUIRuntimeState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [bool]$VerifyIdentity = $true,
        [scriptblock]$LayoutVerifier,
        [scriptblock]$TreeReparseVerifier,
        [scriptblock]$MarkerReader,
        [scriptblock]$IdentityReader
    )
    if ($null -eq $LayoutVerifier -and
        -not (Test-InstallerComfyUIReparseChain -Path $Path)) {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'CORE_REPARSE' -Detail $Path
    }
    $layoutReady = if ($null -ne $LayoutVerifier) {
        [bool](& $LayoutVerifier -Path $Path)
    }
    else {
        Test-InstallerComfyUIRuntimeLayout -Path $Path
    }
    if (-not $layoutReady) {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'CORE_LAYOUT' -Detail $Path
    }
    $treeReparseReady = if ($null -ne $TreeReparseVerifier) {
        [bool](& $TreeReparseVerifier -Root $Path)
    }
    elseif ($null -eq $LayoutVerifier) {
        Test-InstallerPackageTreeReparseFree -Root $Path
    }
    else {
        $true
    }
    if (-not $treeReparseReady) {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'CORE_REPARSE' -Detail $Path
    }
    $markerPath = Join-Path $Path '.winlama-runtime.json'
    if ($null -eq $MarkerReader -and
        -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'CORE_MARKER' `
            -Detail $markerPath
    }
    try {
        $marker = if ($null -ne $MarkerReader) {
            & $MarkerReader -Path $markerPath
        }
        else {
            Get-Content -LiteralPath $markerPath -Raw `
                -Encoding UTF8 | ConvertFrom-InstallerJson
        }
        if ($null -eq $marker) {
            throw [IO.InvalidDataException]::new($markerPath)
        }
        if (-not (Test-InstallerComfyUIRuntimeMarkerProbe `
            -Marker $marker -Config $Config)) {
            return New-InstallerComfyUIDiagnosticResult `
                -Ready $false -ReasonCode 'CORE_MARKER' `
                -Detail $markerPath
        }
    }
    catch {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'CORE_MARKER' `
            -Detail $_.Exception.Message
    }
    if (-not $VerifyIdentity) {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $true -ReasonCode 'READY'
    }
    try {
        $identity = if ($null -ne $IdentityReader) {
            & $IdentityReader -Path $Path
        }
        else {
            Get-InstallerComfyUICoreIdentity -Path $Path
        }
        if (-not (Test-InstallerComfyUIRuntimeMarker `
            -Marker $marker -Config $Config `
            -CoreIdentity $identity)) {
            return New-InstallerComfyUIDiagnosticResult `
                -Ready $false -ReasonCode 'CORE_HASH' `
                -Detail $Path
        }
    }
    catch {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'CORE_HASH' `
            -Detail $_.Exception.Message
    }
    return New-InstallerComfyUIDiagnosticResult `
        -Ready $true -ReasonCode 'READY'
}
function Test-InstallerComfyUIRuntime {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [bool]$VerifyIdentity = $true
    )
    $result = Get-InstallerComfyUIRuntimeState `
        -Path $Path -Config $Config -VerifyIdentity $VerifyIdentity
    if (-not $result.Ready) {
        Write-Verbose (Format-InstallerComfyUIDiagnosticResult `
            -Result $result)
    }
    return [bool]$result.Ready
}
function Get-InstallerExtractedComfyUIRuntimeRoot {
    param([Parameter(Mandatory)][string]$Path)
    $candidates = [Collections.Generic.List[string]]::new()
    $candidates.Add($Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        foreach ($directory in Get-ChildItem -LiteralPath $Path `
            -Directory -Recurse -ErrorAction SilentlyContinue) {
            $candidates.Add($directory.FullName)
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-InstallerComfyUIRuntimeLayout -Path $candidate) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}
function Get-InstallerComfyUILocalRuntimePath {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [bool]$VerifyIdentity = $true
    )
    $path = Join-Path $script:InstallerPackageRoot 'Runtime\ComfyUI'
    if ((Test-InstallerComfyUIRuntime -Path $path -Config $Config `
            -VerifyIdentity $VerifyIdentity) -and
        (-not $VerifyIdentity -or
            (Test-InstallerComfyUILocalRuntimeIdentity `
                -Path $path -Config $Config))) {
        return [IO.Path]::GetFullPath($path)
    }
    return $null
}
function Test-InstallerComfyUIReparseChain {
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$ReparseProbe = {
            param([string]$Candidate)
            if (-not (Test-Path -LiteralPath $Candidate)) {
                return $false
            }
            $item = Get-Item -LiteralPath $Candidate -Force `
                -ErrorAction Stop
            return ($item.Attributes -band `
                [IO.FileAttributes]::ReparsePoint) -ne 0
        }
    )
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ([bool](& $ReparseProbe $current)) {
            return $false
        }
        $root = [IO.Path]::GetPathRoot($current)
        if ($current.TrimEnd('\').Equals(
                $root.TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase
            )) {
            break
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            break
        }
        $current = $parent.FullName
    }
    return $true
}
function Test-InstallerComfyUIRuntimeQuickReparseSafety {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($relativePath in @(
        '.winlama-runtime.json',
        'python_embeded\python.exe',
        'ComfyUI\main.py',
        'run_nvidia_gpu_fast_fp16_accumulation.bat'
    )) {
        $candidate = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
            -not (Test-InstallerComfyUIReparseChain -Path $candidate)) {
            return $false
        }
    }
    return $true
}
function Get-InstallerComfyUIRuntimeSwapPaths {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [AllowEmptyCollection()][string[]]$CandidateIds = @(),
        [scriptblock]$PathExistsProbe = {
            param([string]$Candidate)
            Test-Path -LiteralPath $Candidate
        },
        [scriptblock]$ReparseProbe
    )
    $destinationPath = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $parent = Split-Path -Parent $destinationPath
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw [IO.InvalidDataException]::new(
            'ComfyUI hedef parent yolu gecersiz.'
        )
    }
    $parent = [IO.Path]::GetFullPath($parent).TrimEnd('\')
    $chainParameters = @{ Path = $destinationPath }
    if ($null -ne $ReparseProbe) {
        $chainParameters.ReparseProbe = $ReparseProbe
    }
    if (-not (Test-InstallerComfyUIReparseChain @chainParameters)) {
        throw [IO.InvalidDataException]::new(
            'ComfyUI hedef yolu reparse point iceremez.'
        )
    }
    for ($attempt = 0; $attempt -lt 64; $attempt++) {
        $id = if ($CandidateIds.Count -gt 0) {
            if ($attempt -ge $CandidateIds.Count) {
                break
            }
            [string]$CandidateIds[$attempt]
        }
        else {
            [guid]::NewGuid().ToString('N').Substring(0, 8)
        }
        if ($id -notmatch '^[a-fA-F0-9]{8}$') {
            throw [IO.InvalidDataException]::new(
                'ComfyUI swap kimligi gecersiz.'
            )
        }
        $id = $id.ToLowerInvariant()
        $stage = [IO.Path]::GetFullPath(
            (Join-Path $parent "S$id")
        )
        $backup = [IO.Path]::GetFullPath(
            (Join-Path $parent "B$id")
        )
        $stageParent = [IO.Path]::GetFullPath(
            (Split-Path -Parent $stage)
        ).TrimEnd('\')
        $backupParent = [IO.Path]::GetFullPath(
            (Split-Path -Parent $backup)
        ).TrimEnd('\')
        if (-not $stageParent.Equals(
                $parent,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            -not $backupParent.Equals(
                $parent,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw [IO.InvalidDataException]::new(
                'ComfyUI swap yollari hedef parent disina cikti.'
            )
        }
        if ([bool](& $PathExistsProbe $stage) -or
            [bool](& $PathExistsProbe $backup)) {
            continue
        }
        return [pscustomobject]@{
            Backup = $backup
            Parent = $parent
            Stage = $stage
        }
    }
    throw [IO.IOException]::new(
        'Benzersiz ComfyUI swap yollari ayrilamadi.'
    )
}
function Assert-InstallerComfyUIRuntimeSwapPathContracts {
    $destination = 'C:\Fixture\Programs\ComfyUI'
    $collision = 'C:\Fixture\Programs\S00000000'
    $paths = Get-InstallerComfyUIRuntimeSwapPaths `
        -Destination $destination `
        -CandidateIds @('00000000', '01234567') `
        -PathExistsProbe {
            param([string]$Candidate)
            return $Candidate -ieq $collision
        }.GetNewClosure() `
        -ReparseProbe { return $false }
    if ([IO.Path]::GetFileName($paths.Stage) -cne 'S01234567' -or
        [IO.Path]::GetFileName($paths.Backup) -cne 'B01234567' -or
        $paths.Parent -cne 'C:\Fixture\Programs' -or
        $paths.Stage.Length -gt $destination.Length + 2 -or
        $paths.Backup.Length -gt $destination.Length + 2) {
        throw 'ComfyUI kisa swap yolu sozlesmesi gecersiz.'
    }
    $reparseFailure = $null
    try {
        $null = Get-InstallerComfyUIRuntimeSwapPaths `
            -Destination $destination -CandidateIds @('01234567') `
            -PathExistsProbe { return $false } `
            -ReparseProbe {
                param([string]$Candidate)
                return $Candidate -ieq 'C:\Fixture\Programs'
            }
    }
    catch {
        $reparseFailure = $_.Exception
    }
    if ($null -eq $reparseFailure) {
        throw 'ComfyUI swap reparse point siniri gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:ComfyUI.RuntimeSwapPaths'
    return $true
}
function Assert-InstallerComfyUIRuntimePowerShell {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [version]$CurrentVersion = $PSVersionTable.PSVersion
    )
    $minimumVersion = [version]$Config.MinimumPowerShellVersion
    if ($CurrentVersion -lt $minimumVersion) {
        throw [PlatformNotSupportedException]::new(
            'ComfyUI runtime mutasyonu PowerShell 7 child gerektirir.'
        )
    }
    return $true
}
function Assert-InstallerComfyUIRuntimePowerShellContracts {
    $config = [pscustomobject]@{
        MinimumPowerShellVersion = '7.6.0'
    }
    $legacyFailure = $null
    try {
        $null = Assert-InstallerComfyUIRuntimePowerShell `
            -Config $config -CurrentVersion ([version]'5.1.0')
    }
    catch {
        $legacyFailure = $_.Exception
    }
    if ($null -eq $legacyFailure -or
        -not (Assert-InstallerComfyUIRuntimePowerShell `
            -Config $config -CurrentVersion ([version]'7.6.0'))) {
        throw 'ComfyUI PowerShell mutation siniri gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:ComfyUI.PowerShellMutationBoundary'
    return $true
}
function Get-InstallerComfyUIDestinationAction {
    param(
        [Parameter(Mandatory)][pscustomobject]$DestinationState,
        [Parameter(Mandatory)][pscustomobject]$RequirementsState,
        [Parameter(Mandatory)][int]$RequiredNodeCount
    )
    if (-not $DestinationState.Ready) {
        return 'Replace'
    }
    if ($RequirementsState.Ready) {
        return 'Keep'
    }
    if (Test-InstallerComfyUINodeFallbackReason `
        -Result $RequirementsState -NodeCount $RequiredNodeCount) {
        return 'RepairNodes'
    }
    return 'Replace'
}
function Get-InstallerComfyUIStageNodes {
    param(
        [Parameter(Mandatory)][bool]$IncludeCustomNodes,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [object[]]$Nodes
    )
    if (-not $IncludeCustomNodes) {
        return ,([object[]]@())
    }
    return ,([object[]]@($Nodes))
}
function Assert-InstallerComfyUIDestinationActionContracts {
    $ready = New-InstallerComfyUIDiagnosticResult `
        -Ready $true -ReasonCode 'READY'
    $importFailure = New-InstallerComfyUIDiagnosticResult `
        -Ready $false -ReasonCode 'IMPORT_PROBE' -Detail 'fixture'
    $nodeFailure = New-InstallerComfyUIDiagnosticResult `
        -Ready $false -ReasonCode 'NODE_TREE' -Detail 'fixture'
    if ((Get-InstallerComfyUIDestinationAction `
            -DestinationState $ready -RequirementsState $ready `
            -RequiredNodeCount 0) -cne 'Keep' -or
        (Get-InstallerComfyUIDestinationAction `
            -DestinationState $ready -RequirementsState $importFailure `
            -RequiredNodeCount 0) -cne 'Replace' -or
        (Get-InstallerComfyUIDestinationAction `
            -DestinationState $ready -RequirementsState $nodeFailure `
            -RequiredNodeCount 1) -cne 'RepairNodes') {
        throw 'ComfyUI hedef runtime mutation plani gecersiz.'
    }
    $onlineStageNodes = Get-InstallerComfyUIStageNodes `
        -IncludeCustomNodes $false -Nodes @($ready)
    $localStageNodes = Get-InstallerComfyUIStageNodes `
        -IncludeCustomNodes $true -Nodes @($ready)
    if ($null -eq $onlineStageNodes -or
        $onlineStageNodes.Count -ne 0 -or
        $null -eq $localStageNodes -or
        $localStageNodes.Count -ne 1) {
        throw 'ComfyUI stage node dizisi sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIDestinationAction'
    return $true
}
function Remove-InstallerComfyUICleanupPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$PathExistsProbe = {
            param([string]$Candidate)
            Test-Path -LiteralPath $Candidate
        },
        [scriptblock]$RemoveProbe = {
            param([string]$Candidate)
            Remove-Item -LiteralPath $Candidate -Recurse -Force `
                -ErrorAction Stop
        }
    )
    if (-not [bool](& $PathExistsProbe $Path)) {
        return $false
    }
    & $RemoveProbe $Path
    if ([bool](& $PathExistsProbe $Path)) {
        throw [IO.IOException]::new(
            "ComfyUI cleanup yolu kaldirilamadi: $Path"
        )
    }
    return $true
}
function Assert-InstallerComfyUICleanupContracts {
    $state = [pscustomobject]@{ Exists = $true; Removed = $false }
    $existsProbe = { return [bool]$state.Exists }.GetNewClosure()
    $removeProbe = {
        param([string]$Path)
        $state.Removed = $true
        $state.Exists = $false
    }.GetNewClosure()
    $removed = Remove-InstallerComfyUICleanupPath `
        -Path 'C:\Fixture\ComfyUI.cleanup' `
        -PathExistsProbe $existsProbe -RemoveProbe $removeProbe
    $removeFailureRejected = $false
    try {
        $null = Remove-InstallerComfyUICleanupPath `
            -Path 'C:\Fixture\ComfyUI.cleanup' `
            -PathExistsProbe { return $true } `
            -RemoveProbe { throw 'fixture cleanup failure' }
    }
    catch {
        $removeFailureRejected = $true
    }
    $postconditionRejected = $false
    try {
        $null = Remove-InstallerComfyUICleanupPath `
            -Path 'C:\Fixture\ComfyUI.cleanup' `
            -PathExistsProbe { return $true } `
            -RemoveProbe { param([string]$Path) }
    }
    catch [IO.IOException] {
        $postconditionRejected = $true
    }
    $installSource = (Get-Command Install-InstallerComfyUIRuntime `
        -ErrorAction Stop).Definition
    $backupCleanupIndex = $installSource.IndexOf(
        'Remove-InstallerComfyUICleanupPath -Path $backup',
        [StringComparison]::Ordinal
    )
    $temporaryCleanupIndex = $installSource.IndexOf(
        'Remove-InstallerComfyUICleanupPath -Path $temporaryRoot',
        [StringComparison]::Ordinal
    )
    $readyIndex = $installSource.IndexOf(
        "-Key 'Installer.ComfyUI.RuntimeReady'",
        [StringComparison]::Ordinal
    )
    if (-not $removed -or -not $state.Removed -or
        -not $removeFailureRejected -or -not $postconditionRejected -or
        $backupCleanupIndex -lt 0 -or
        $temporaryCleanupIndex -le $backupCleanupIndex -or
        $readyIndex -le $temporaryCleanupIndex) {
        throw 'ComfyUI cleanup postcondition sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUICleanupPostcondition'
    return $true
}
function Test-InstallerPathOverlap {
    param(
        [Parameter(Mandatory)][string]$First,
        [Parameter(Mandatory)][string]$Second
    )
    $left = [IO.Path]::GetFullPath($First).TrimEnd('\')
    $right = [IO.Path]::GetFullPath($Second).TrimEnd('\')
    if ($left.Equals(
            $right,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        return $true
    }
    $separator = [IO.Path]::DirectorySeparatorChar
    return $left.StartsWith(
        $right + $separator,
        [StringComparison]::OrdinalIgnoreCase
    ) -or $right.StartsWith(
        $left + $separator,
        [StringComparison]::OrdinalIgnoreCase
    )
}
function Migrate-InstallerComfyUIEmbeddedModels {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [AllowEmptyCollection()][string[]]$RestrictedRoots = @(),
        [scriptblock]$TreeSafetyProbe = {
            param([string]$Path)
            Test-InstallerPackageTreeReparseFree -Root $Path
        },
        [scriptblock]$HashReader = {
            param([string]$Path)
            Get-InstallerFileSha256WithProgress -Path $Path
        },
        [scriptblock]$FileCopy = {
            param([string]$Source, [string]$Destination)
            Copy-Item -LiteralPath $Source -Destination $Destination `
                -ErrorAction Stop
        },
        [scriptblock]$FileMove = {
            param([string]$Source, [string]$Destination)
            Move-Item -LiteralPath $Source -Destination $Destination `
                -ErrorAction Stop
        }
    )
    $source = Get-InstallerComfyUIEmbeddedModelsRoot -Config $Config
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        return 0
    }
    if (-not [bool](& $TreeSafetyProbe -Path $source)) {
        throw (New-NonRetryableException -Message (Get-LocalizedText `
            -Key 'Installer.ComfyUI.LocalCopyFailed' `
            -Arguments @($source, -1)))
    }
    $sourceFiles = @(Get-InstallerReparseSafeTreeFiles -Root $source |
        Sort-Object FullName)
    if ($sourceFiles.Count -eq 0) {
        return 0
    }
    $target = Get-InstallerComfyUIModelsRoot -Config $Config `
        -ProjectRoot $ProjectRoot
    foreach ($restricted in $RestrictedRoots) {
        if (-not [string]::IsNullOrWhiteSpace($restricted) -and
            (Test-InstallerPathOverlap -First $target `
                -Second $restricted)) {
            throw (New-NonRetryableException -Message (Get-LocalizedText `
                -Key 'Installer.ComfyUI.LocalCopyFailed' `
                -Arguments @($target, -1)))
        }
    }
    if (Test-Path -LiteralPath $target) {
        if (-not (Test-Path -LiteralPath $target -PathType Container) -or
            -not [bool](& $TreeSafetyProbe -Path $target)) {
            throw (New-NonRetryableException -Message (Get-LocalizedText `
                -Key 'Installer.ComfyUI.LocalCopyFailed' `
                -Arguments @($target, -1)))
        }
    }
    elseif (-not (Test-InstallerComfyUIReparseChain -Path $target)) {
        throw (New-NonRetryableException -Message (Get-LocalizedText `
            -Key 'Installer.ComfyUI.LocalCopyFailed' `
            -Arguments @($target, -1)))
    }
    $sourceHashes = @{}
    $missing = [Collections.Generic.List[object]]::new()
    foreach ($file in $sourceFiles) {
        $relative = $file.FullName.Substring($source.Length).
            TrimStart('\')
        $targetPath = Resolve-InstallerContainedPackagePath `
            -Root $target -RelativePath $relative
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            $targetItem = Get-Item -LiteralPath $targetPath -Force
            if ([long]$targetItem.Length -ne [long]$file.Length) {
                throw (New-NonRetryableException -Message (
                    Get-LocalizedText `
                        -Key 'Installer.ComfyUI.LocalCopyFailed' `
                        -Arguments @($targetPath, -1)
                ))
            }
            $sourceHash = [string](& $HashReader -Path $file.FullName)
            $targetHash = [string](& $HashReader -Path $targetPath)
            if ($sourceHash -ine $targetHash) {
                throw (New-NonRetryableException -Message (
                    Get-LocalizedText `
                        -Key 'Installer.ComfyUI.LocalCopyFailed' `
                        -Arguments @($targetPath, -1)
                ))
            }
            $sourceHashes[$file.FullName] = $sourceHash
            continue
        }
        if (Test-Path -LiteralPath $targetPath) {
            throw (New-NonRetryableException -Message (Get-LocalizedText `
                -Key 'Installer.ComfyUI.LocalCopyFailed' `
                -Arguments @($targetPath, -1)))
        }
        $missing.Add([pscustomobject]@{
            Source = $file.FullName
            Target = $targetPath
        })
    }
    if ($missing.Count -eq 0) {
        return 0
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.ComfyUI.MutableCopying'
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.ComfyUI.MutableCopying') -Color Cyan
    [IO.Directory]::CreateDirectory($target) | Out-Null
    $copied = 0
    foreach ($record in $missing) {
        $parent = Split-Path -Parent $record.Target
        [IO.Directory]::CreateDirectory($parent) | Out-Null
        $targetRelative = $record.Target.Substring(
            $target.Length
        ).TrimStart('\')
        $null = Resolve-InstallerContainedPackagePath `
            -Root $target `
            -RelativePath $targetRelative
        $partial = Join-Path $parent (
            '.{0}.{1}.partial' -f `
                [IO.Path]::GetFileName($record.Target),
                [guid]::NewGuid().ToString('N')
        )
        $published = $false
        try {
            & $FileCopy -Source $record.Source -Destination $partial
            $sourceItem = Get-Item -LiteralPath $record.Source -Force
            $partialItem = Get-Item -LiteralPath $partial -Force
            if ([long]$sourceItem.Length -ne [long]$partialItem.Length) {
                throw [IO.InvalidDataException]::new($partial)
            }
            $sourceHash = if ($sourceHashes.ContainsKey(
                $record.Source
            )) {
                [string]$sourceHashes[$record.Source]
            }
            else {
                [string](& $HashReader -Path $record.Source)
            }
            $partialHash = [string](& $HashReader -Path $partial)
            if ($sourceHash -ine $partialHash) {
                throw [IO.InvalidDataException]::new($partial)
            }
            & $FileMove -Source $partial -Destination $record.Target
            $published = $true
            $targetItem = Get-Item -LiteralPath $record.Target -Force
            if ([long]$sourceItem.Length -ne [long]$targetItem.Length) {
                throw [IO.InvalidDataException]::new($record.Target)
            }
            $targetHash = [string](& $HashReader -Path $record.Target)
            if ($sourceHash -ine $targetHash) {
                throw [IO.InvalidDataException]::new($record.Target)
            }
            $copied++
        }
        catch {
            if ($published) {
                Remove-Item -LiteralPath $record.Target -Force `
                    -ErrorAction SilentlyContinue
            }
            throw (New-NonRetryableException -Message (Get-LocalizedText `
                -Key 'Installer.ComfyUI.LocalCopyFailed' `
                -Arguments @($record.Target, -1)))
        }
        finally {
            Remove-Item -LiteralPath $partial -Force `
                -ErrorAction SilentlyContinue
        }
    }
    return $copied
}
function Assert-InstallerComfyUIEmbeddedModelsPreserved {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [scriptblock]$HashReader = {
            param([string]$Path)
            Get-InstallerFileSha256WithProgress -Path $Path
        }
    )
    $source = Get-InstallerComfyUIEmbeddedModelsRoot -Config $Config
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        return $true
    }
    if (-not (Test-InstallerPackageTreeReparseFree -Root $source)) {
        throw (New-NonRetryableException -Message (Get-LocalizedText `
            -Key 'Installer.ComfyUI.LocalCopyFailed' `
            -Arguments @($source, -1)))
    }
    $target = Get-InstallerComfyUIModelsRoot -Config $Config `
        -ProjectRoot $ProjectRoot
    foreach ($file in @(Get-InstallerReparseSafeTreeFiles `
        -Root $source | Sort-Object FullName)) {
        $relative = $file.FullName.Substring(
            $source.Length
        ).TrimStart('\')
        $targetPath = Resolve-InstallerContainedPackagePath `
            -Root $target -RelativePath $relative
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            throw (New-NonRetryableException -Message (Get-LocalizedText `
                -Key 'Installer.ComfyUI.LocalCopyFailed' `
                -Arguments @($targetPath, -1)))
        }
        $sourceItem = Get-Item -LiteralPath $file.FullName -Force
        $targetItem = Get-Item -LiteralPath $targetPath -Force
        if ([long]$sourceItem.Length -ne [long]$targetItem.Length -or
            [string](& $HashReader -Path $file.FullName) -ine
                [string](& $HashReader -Path $targetPath)) {
            throw (New-NonRetryableException -Message (Get-LocalizedText `
                -Key 'Installer.ComfyUI.LocalCopyFailed' `
                -Arguments @($targetPath, -1)))
        }
    }
    return $true
}
function Assert-InstallerComfyUIEmbeddedModelMigrationContracts {
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'winlama-comfy-model-migration-' +
        [guid]::NewGuid().ToString('N')
    )
    $destination = Join-Path $fixtureRoot 'Runtime'
    $embedded = Join-Path $destination 'ComfyUI\models'
    $target = Join-Path $fixtureRoot 'Models'
    $sourceFile = Join-Path $embedded 'checkpoints\fixture.bin'
    $targetFile = Join-Path $target 'checkpoints\fixture.bin'
    try {
        $config = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
        $config.ComfyUI.InstallPath = $destination
        $config.ComfyUI.ModelsPath = $target
        $absentCopyCalls = 0
        $absentResult = Migrate-InstallerComfyUIEmbeddedModels `
            -Config $config -ProjectRoot $fixtureRoot `
            -RestrictedRoots @($destination) -FileCopy {
                $absentCopyCalls++
            }.GetNewClosure()
        if ($absentResult -ne 0 -or $absentCopyCalls -ne 0) {
            throw 'Bos ComfyUI embedded model migrasyonu mutation yapti.'
        }
        [IO.Directory]::CreateDirectory(
            (Split-Path -Parent $sourceFile)
        ) | Out-Null
        [IO.File]::WriteAllBytes($sourceFile, [byte[]](1, 2, 3, 4))
        $secondSource = Join-Path $embedded 'vae\second.bin'
        $secondTarget = Join-Path $target 'vae\second.bin'
        [IO.Directory]::CreateDirectory(
            (Split-Path -Parent $secondSource)
        ) | Out-Null
        [IO.File]::WriteAllBytes($secondSource, [byte[]](5, 6, 7))
        $model = [pscustomobject]@{
            Name = 'FixtureEmbedded'
            LocalDirectory = 'checkpoints'
            Assets = @(
                [pscustomobject]@{
                    RelativePath = 'checkpoints\fixture.bin'
                    Sha256 = '0' * 64
                    SizeGB = 4 / 1GB
                }
            )
        }
        $searchRoots = @(Get-InstallerComfyUIModelSearchRoots `
            -Config $config -ProjectRoot $fixtureRoot)
        $embeddedInstalled = Test-InstallerComfyUIModelInstalled `
            -Model $model -Config $config -ProjectRoot $fixtureRoot
        $hashState = [pscustomobject]@{ Calls = 0 }
        $migrationHashReader = {
            param([string]$Path)
            $hashState.Calls++
            return (Get-FileHash -LiteralPath $Path `
                -Algorithm SHA256).Hash
        }.GetNewClosure()
        $copied = Migrate-InstallerComfyUIEmbeddedModels `
            -Config $config -ProjectRoot $fixtureRoot `
            -RestrictedRoots @($destination) `
            -HashReader $migrationHashReader
        $copiedAgain = Migrate-InstallerComfyUIEmbeddedModels `
            -Config $config -ProjectRoot $fixtureRoot `
            -RestrictedRoots @($destination) `
            -HashReader $migrationHashReader
        if ($searchRoots.Count -ne 2 -or
            $searchRoots -inotcontains `
                ([IO.Path]::GetFullPath($embedded).TrimEnd('\')) -or
            -not $embeddedInstalled -or $copied -ne 2 -or
            $copiedAgain -ne 0 -or $hashState.Calls -lt 1 -or
            -not (Test-Path -LiteralPath $sourceFile -PathType Leaf) -or
            -not (Test-Path -LiteralPath $targetFile -PathType Leaf) -or
            -not (Test-Path -LiteralPath $secondTarget -PathType Leaf) -or
            ([IO.File]::ReadAllBytes($sourceFile) -join ',') -cne
                ([IO.File]::ReadAllBytes($targetFile) -join ',')) {
            throw 'ComfyUI embedded model migrasyonu korunamadi.'
        }
        $preserved = Assert-InstallerComfyUIEmbeddedModelsPreserved `
            -Config $config -ProjectRoot $fixtureRoot `
            -HashReader $migrationHashReader
        $lateSource = Join-Path $embedded 'loras\late.bin'
        [IO.Directory]::CreateDirectory(
            (Split-Path -Parent $lateSource)
        ) | Out-Null
        [IO.File]::WriteAllBytes($lateSource, [byte[]](21, 22))
        $lateMutationRejected = $false
        try {
            $null = Assert-InstallerComfyUIEmbeddedModelsPreserved `
                -Config $config -ProjectRoot $fixtureRoot `
                -HashReader $migrationHashReader
        }
        catch {
            $lateMutationRejected = $true
        }
        Remove-Item -LiteralPath $lateSource -Force
        [IO.File]::WriteAllBytes($sourceFile, [byte[]](4, 3, 2, 1))
        $changedMutationRejected = $false
        try {
            $null = Assert-InstallerComfyUIEmbeddedModelsPreserved `
                -Config $config -ProjectRoot $fixtureRoot `
                -HashReader $migrationHashReader
        }
        catch {
            $changedMutationRejected = $true
        }
        [IO.File]::WriteAllBytes($sourceFile, [byte[]](1, 2, 3, 4))
        $restoredPreserved = `
            Assert-InstallerComfyUIEmbeddedModelsPreserved `
                -Config $config -ProjectRoot $fixtureRoot `
                -HashReader $migrationHashReader
        if (-not $preserved -or -not $lateMutationRejected -or
            -not $changedMutationRejected -or -not $restoredPreserved) {
            throw 'ComfyUI model mutation denetimi fail-safe degil.'
        }
        $conflictSource = Join-Path $embedded 'vae\conflict.bin'
        $conflictTarget = Join-Path $target 'vae\conflict.bin'
        $missingSource = Join-Path $embedded 'loras\missing.bin'
        $missingTarget = Join-Path $target 'loras\missing.bin'
        [IO.Directory]::CreateDirectory(
            (Split-Path -Parent $conflictSource)
        ) | Out-Null
        [IO.Directory]::CreateDirectory(
            (Split-Path -Parent $conflictTarget)
        ) | Out-Null
        [IO.Directory]::CreateDirectory(
            (Split-Path -Parent $missingSource)
        ) | Out-Null
        [IO.File]::WriteAllText($conflictSource, 'source')
        [IO.File]::WriteAllText($conflictTarget, 'target')
        [IO.File]::WriteAllText($missingSource, 'missing')
        $conflictRejected = $false
        try {
            $null = Migrate-InstallerComfyUIEmbeddedModels `
                -Config $config -ProjectRoot $fixtureRoot `
                -RestrictedRoots @($destination)
        }
        catch {
            $conflictRejected = $true
        }
        if (-not $conflictRejected -or
            (Test-Path -LiteralPath $missingTarget)) {
            throw 'ComfyUI model cakisma preflight sozlesmesi gecersiz.'
        }
        Remove-Item -LiteralPath $conflictSource, $conflictTarget, `
            $missingSource -Force
        $corruptSource = Join-Path $embedded 'unet\corrupt.bin'
        $corruptTarget = Join-Path $target 'unet\corrupt.bin'
        [IO.Directory]::CreateDirectory(
            (Split-Path -Parent $corruptSource)
        ) | Out-Null
        [IO.File]::WriteAllBytes(
            $corruptSource,
            [byte[]](10, 11, 12, 13)
        )
        $corruptRejected = $false
        try {
            $null = Migrate-InstallerComfyUIEmbeddedModels `
                -Config $config -ProjectRoot $fixtureRoot `
                -RestrictedRoots @($destination) -FileCopy {
                    param([string]$Source, [string]$Destination)
                    [IO.File]::WriteAllBytes(
                        $Destination,
                        [byte[]](99)
                    )
                }
        }
        catch {
            $corruptRejected = $true
        }
        if (-not $corruptRejected -or
            -not (Test-Path -LiteralPath $corruptSource `
                -PathType Leaf) -or
            (Test-Path -LiteralPath $corruptTarget) -or
            @(Get-ChildItem -LiteralPath `
                (Split-Path -Parent $corruptTarget) `
                -Filter '*.partial' -File `
                -ErrorAction SilentlyContinue).Count -ne 0) {
            throw 'ComfyUI bozuk model kopyasi fail-safe degil.'
        }
        $publishedCorruptRejected = $false
        try {
            $null = Migrate-InstallerComfyUIEmbeddedModels `
                -Config $config -ProjectRoot $fixtureRoot `
                -RestrictedRoots @($destination) -FileMove {
                    param([string]$Source, [string]$Destination)
                    Move-Item -LiteralPath $Source `
                        -Destination $Destination -ErrorAction Stop
                    [IO.File]::WriteAllBytes(
                        $Destination,
                        [byte[]](88)
                    )
                }
        }
        catch {
            $publishedCorruptRejected = $true
        }
        if (-not $publishedCorruptRejected -or
            -not (Test-Path -LiteralPath $corruptSource `
                -PathType Leaf) -or
            (Test-Path -LiteralPath $corruptTarget) -or
            @(Get-ChildItem -LiteralPath `
                (Split-Path -Parent $corruptTarget) `
                -Filter '*.partial' -File `
                -ErrorAction SilentlyContinue).Count -ne 0) {
            throw 'ComfyUI bozuk final model kopyasi geri alinmadi.'
        }
        $overlapConfig = $config | ConvertTo-Json -Depth 100 |
            ConvertFrom-InstallerJson
        $overlapConfig.ComfyUI.ModelsPath = $embedded
        $overlapRejected = $false
        try {
            $null = Migrate-InstallerComfyUIEmbeddedModels `
                -Config $overlapConfig -ProjectRoot $fixtureRoot `
                -RestrictedRoots @($destination)
        }
        catch {
            $overlapRejected = $true
        }
        $copyCalls = 0
        $unsafeRejected = $false
        try {
            $null = Migrate-InstallerComfyUIEmbeddedModels `
                -Config $config -ProjectRoot $fixtureRoot `
                -RestrictedRoots @($destination) `
                -TreeSafetyProbe { return $false } `
                -FileCopy { $copyCalls++ }.GetNewClosure()
        }
        catch {
            $unsafeRejected = $true
        }
        $installSource = (Get-Command Install-InstallerComfyUIRuntime `
            -ErrorAction Stop).Definition
        $migrationIndex = $installSource.IndexOf(
            'Migrate-InstallerComfyUIEmbeddedModels',
            [StringComparison]::Ordinal
        )
        $preservationIndex = $installSource.IndexOf(
            'Assert-InstallerComfyUIEmbeddedModelsPreserved',
            [StringComparison]::Ordinal
        )
        $processStopIndex = $installSource.IndexOf(
            'Stop-ProcessesFromPath',
            [StringComparison]::Ordinal
        )
        $requirementsIndex = $installSource.IndexOf(
            'if (-not $stageRequirementsState.Ready)',
            [StringComparison]::Ordinal
        )
        $swapIndex = $installSource.IndexOf(
            'Move-Item -LiteralPath $destination',
            [StringComparison]::Ordinal
        )
        $finalVerifyIndex = $installSource.LastIndexOf(
            '-Path $destination -Config $Config',
            [StringComparison]::Ordinal
        )
        $backupCleanupIndex = $installSource.LastIndexOf(
            'Remove-InstallerComfyUICleanupPath -Path $backup',
            [StringComparison]::Ordinal
        )
        if (-not $overlapRejected -or -not $unsafeRejected -or
            $copyCalls -ne 0 -or $requirementsIndex -lt 0 -or
            $processStopIndex -lt 0 -or
            $processStopIndex -ge $migrationIndex -or
            $migrationIndex -le $requirementsIndex -or
            $preservationIndex -le $migrationIndex -or
            $swapIndex -le $preservationIndex -or
            $finalVerifyIndex -le $swapIndex -or
            $backupCleanupIndex -le $finalVerifyIndex) {
            throw 'ComfyUI model migrasyonu fail-safe degil.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $fixtureRoot) {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIEmbeddedModels'
    return $true
}
function Install-InstallerComfyUIRuntime {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
        [string]$SourceSelection = 'Automatic',
        [AllowNull()][pscustomobject]$VerifiedAvailability,
        [bool]$VerifyLocalPayloadHashes = $true
    )
    $SourceSelection = ConvertTo-InstallerSourceSelection `
        -Selection $SourceSelection
    if (-not $Config.ComfyUI.Enabled) {
        return $false
    }
    $null = Assert-InstallerComfyUIRuntimePowerShell -Config $Config
    if ($SourceSelection -in @('Prompt', 'Automatic')) {
        $SourceSelection = 'Automatic'
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.ComfyUI.SourceResolved' `
        -MessageArguments @($SourceSelection)
    $destination = Resolve-InstallerPath `
        -Path $Config.ComfyUI.InstallPath
    $selectedNames = @($Config.ComfyUI.Requested | ForEach-Object {
        [string]$_
    })
    $requiredNodes = @($Config.ComfyUI.CustomNodes | Where-Object {
        [string]$_.RequiredBy -iin $selectedNames
    })
    $baseRequirementLines = @(
        Get-InstallerComfyUIBaseRequirements -Config $Config
    )
    $useVerifiedDestination = $null -ne $VerifiedAvailability -and
        [bool]$VerifiedAvailability.RuntimeInstalled
    $destinationState = if ($useVerifiedDestination) {
        $VerifiedAvailability.RuntimeState
    }
    else {
        Get-InstallerComfyUIRuntimeState -Path $destination `
            -Config $Config `
            -VerifyIdentity:$VerifyLocalPayloadHashes
    }
    $destinationReady = [bool]$destinationState.Ready
    $verifiedRequirementsFromDestination = $useVerifiedDestination -and
        $null -ne $VerifiedAvailability.PSObject.Properties[
            'RequirementsFromDestination'
        ] -and [bool]$VerifiedAvailability.RequirementsFromDestination
    $verifiedDestinationRequirements = if ($useVerifiedDestination -and
        $null -ne $VerifiedAvailability.PSObject.Properties[
            'DestinationRequirementsState'
        ]) {
        $VerifiedAvailability.DestinationRequirementsState
    }
    else {
        $null
    }
    $destinationRequirementsState = if (
        $verifiedRequirementsFromDestination
    ) {
        $VerifiedAvailability.RequirementsState
    }
    elseif ($null -ne $verifiedDestinationRequirements) {
        $verifiedDestinationRequirements
    }
    elseif ($destinationReady) {
        Get-InstallerComfyUIRequirementsState `
            -RuntimeRoot $destination -Nodes $requiredNodes `
            -VerifyEnvironment $true `
            -ExpectedBaseRequirementLines $baseRequirementLines
    }
    else {
        $destinationState
    }
    $destinationAction = Get-InstallerComfyUIDestinationAction `
        -DestinationState $destinationState `
        -RequirementsState $destinationRequirementsState `
        -RequiredNodeCount $requiredNodes.Count
    if ($destinationAction -ceq 'Keep') {
        $null = Update-InstallerComfyUILauncherContract `
            -Path $destination -Config $Config
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.ComfyUI.RuntimeExisting' `
            -Arguments @($destination)) -Color Green
        return $true
    }
    if ($destinationAction -ceq 'RepairNodes') {
        $null = Update-InstallerComfyUILauncherContract `
            -Path $destination -Config $Config
        Write-InstallerLog -Level WARN `
            -Message 'Installer.ComfyUI.RequirementsFallback' `
            -MessageArguments @(
                $destinationRequirementsState.ReasonCode,
                $destinationRequirementsState.Detail
            )
        return $true
    }
    if ($destinationReady) {
        Write-InstallerLog -Level WARN `
            -Message 'Installer.ComfyUI.RuntimeFallback' `
            -MessageArguments @(
                $destinationRequirementsState.ReasonCode,
                $destinationRequirementsState.Detail
            )
    }
    $temporaryRoot = Join-Path (Resolve-InstallerPath `
        -Path $Config.Paths.Temp) 'ComfyUIInstall'
    $swapPaths = Get-InstallerComfyUIRuntimeSwapPaths `
        -Destination $destination
    $stage = $swapPaths.Stage
    $backup = $swapPaths.Backup
    try {
        $assetName = [string]$Config.ComfyUI.PortableAssetName
        $expectedHash = [string]$Config.ComfyUI.PortableSha256
        $expectedSize = [long]$Config.ComfyUI.PortableSizeBytes
        if ($expectedHash -notmatch '^[a-fA-F0-9]{64}$' -or
            $expectedSize -lt 1) {
            throw (Get-LocalizedText `
                -Key 'Installer.ComfyUI.RuntimeDigestMissing')
        }
        $source = $null
        $localPackageSource = $false
        $localRuntimeRoot = Join-Path $script:InstallerPackageRoot `
            'Runtime\ComfyUI'
        $localSource = $null
        $localRuntimeState = New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'CORE_LAYOUT' `
            -Detail $localRuntimeRoot
        $localRequirementsState = $localRuntimeState
        $useVerifiedLocalSource = $false
        if ($null -ne $VerifiedAvailability -and
            $null -ne $VerifiedAvailability.PSObject.Properties[
                'LocalRuntimeIdentityVerified'
            ] -and
            [bool]$VerifiedAvailability.LocalRuntimeIdentityVerified -and
            $null -ne $VerifiedAvailability.PSObject.Properties[
                'LocalRuntimePath'
            ] -and
            $null -ne $VerifiedAvailability.PSObject.Properties[
                'RequirementsCandidatePath'
            ]) {
            try {
                $useVerifiedLocalSource = [string]::Equals(
                    [IO.Path]::GetFullPath(
                        [string]$VerifiedAvailability.LocalRuntimePath
                    ),
                    [IO.Path]::GetFullPath($localRuntimeRoot),
                    [StringComparison]::OrdinalIgnoreCase
                ) -and [string]::Equals(
                    [IO.Path]::GetFullPath(
                        [string]$VerifiedAvailability.
                            RequirementsCandidatePath
                    ),
                    [IO.Path]::GetFullPath($localRuntimeRoot),
                    [StringComparison]::OrdinalIgnoreCase
                ) -and [bool]$VerifiedAvailability.RequirementsState.Ready
            }
            catch {
                $useVerifiedLocalSource = $false
            }
        }
        if ($SourceSelection -ne 'Online') {
            if ($useVerifiedLocalSource) {
                $localRuntimeState = New-InstallerComfyUIDiagnosticResult `
                    -Ready $true -ReasonCode 'READY'
                $localRequirementsState = `
                    $VerifiedAvailability.RequirementsState
                $localSource = [IO.Path]::GetFullPath($localRuntimeRoot)
            }
            else {
                $localRuntimeState = Get-InstallerComfyUIRuntimeState `
                    -Path $localRuntimeRoot -Config $Config `
                    -VerifyIdentity:$VerifyLocalPayloadHashes
                if ($VerifyLocalPayloadHashes -and
                    $localRuntimeState.Ready -and
                    -not (Test-InstallerComfyUILocalRuntimeIdentity `
                        -Path $localRuntimeRoot -Config $Config)) {
                    $localRuntimeState = `
                        New-InstallerComfyUIDiagnosticResult `
                            -Ready $false `
                            -ReasonCode 'LOCAL_RUNTIME_HASH' `
                            -Detail $localRuntimeRoot
                }
                $localRequirementsState = $localRuntimeState
                if ($localRuntimeState.Ready) {
                    $localSource = [IO.Path]::GetFullPath(
                        $localRuntimeRoot
                    )
                    $localRequirementsState = `
                        Get-InstallerComfyUIRequirementsState `
                            -RuntimeRoot $localSource `
                            -Nodes $requiredNodes `
                            -VerifyIdentity:$VerifyLocalPayloadHashes `
                            -VerifyEnvironment $false `
                            -AllowBaseRequirementsReplacement `
                            -BaseRequirementLines $baseRequirementLines `
                            -ExpectedBaseRequirementLines `
                                $baseRequirementLines
                    if (-not $localRequirementsState.Ready) {
                        $localSource = $null
                    }
                }
            }
        }
        if ($SourceSelection -eq 'Local' -and
            [string]::IsNullOrWhiteSpace($localSource)) {
            throw (New-NonRetryableException -Message (
                Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimeLocalInvalid' `
                    -Arguments @(
                        $localRequirementsState.ReasonCode,
                        $localRequirementsState.Detail
                    )
            ))
        }
        if (-not [string]::IsNullOrWhiteSpace($localSource)) {
            $source = $localSource
            $localPackageSource = $true
            Write-InstallerLog -Level INFO `
                -Message 'Installer.ComfyUI.RuntimeLocalDetected' `
                -MessageArguments @($source)
        }
        elseif ($SourceSelection -ne 'Online' -and
            (Test-Path -LiteralPath $localRuntimeRoot `
                -PathType Container)) {
            Write-InstallerLog -Level WARN `
                -Message 'Installer.ComfyUI.RuntimeFallback' `
                -MessageArguments @(
                    $localRequirementsState.ReasonCode,
                    $localRequirementsState.Detail
                )
        }
        $archive = $null
        if ([string]::IsNullOrWhiteSpace($source) -and
            [string]::IsNullOrWhiteSpace($archive)) {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.ComfyUI.RuntimeDownloading'
            Write-InstallerLine -Text (Get-LocalizedText `
                -Key 'Installer.ComfyUI.RuntimeDownloading') `
                -Color Cyan
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force `
                -ErrorAction SilentlyContinue
            [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
            [Net.ServicePointManager]::SecurityProtocol = `
                [Net.SecurityProtocolType]::Tls12
            $headers = @{
                Accept = 'application/vnd.github+json'
                'User-Agent' = 'Winlama-26.10.29'
                'X-GitHub-Api-Version' = '2022-11-28'
            }
            $timeout = [int]$Config.Network.DownloadTimeoutSeconds
            $downloadUri = [uri][string]$Config.ComfyUI.PortableUri
            if ($downloadUri.Scheme -ne 'https' -or
                $downloadUri.Host -ine 'github.com' -or
                $downloadUri.AbsolutePath -notlike `
                    '/Comfy-Org/ComfyUI/releases/download/*' -or
                [IO.Path]::GetFileName($downloadUri.AbsolutePath) -cne
                    $assetName) {
                throw (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimeDownloadInvalid')
            }
            $archive = Join-Path $temporaryRoot $assetName
            $downloadDelays = @($Config.Network.RetryBackoffSeconds)
            $downloaded = $false
            for ($attempt = 0; $attempt -le $downloadDelays.Count;
                $attempt++) {
                try {
                    Remove-Item -LiteralPath $archive -Force `
                        -ErrorAction SilentlyContinue
                    Save-WinlamaWebFile -Uri $downloadUri `
                        -Headers $headers -OutFile $archive `
                        -TimeoutSec $timeout
                    $downloaded = $true
                    break
                }
                catch {
                    if ($attempt -ge $downloadDelays.Count) {
                        throw
                    }
                    $delay = [int]$downloadDelays[$attempt]
                    Write-InstallerLog -Level WARN `
                        -Message 'Manager.Download.Retrying' `
                        -MessageArguments @($assetName, $delay) `
                        -Exception $_.Exception
                    Write-InstallerLine -Text (Get-LocalizedText `
                        -Key 'Manager.Download.Retrying' `
                        -Arguments @($assetName, $delay)) `
                        -Color Yellow
                    Start-Sleep -Seconds $delay
                }
            }
            if (-not $downloaded) {
                throw (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimeSkipped' `
                    -Arguments @($assetName))
            }
            if ((Get-Item -LiteralPath $archive).Length -ne
                $expectedSize) {
                throw (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimeHashInvalid')
            }
            $actualHash = Get-InstallerFileSha256WithProgress `
                -Path $archive
            if ($actualHash -ine $expectedHash) {
                throw (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimeHashInvalid')
            }
        }
        if ([string]::IsNullOrWhiteSpace($source)) {
            $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
            if ($null -eq $tar) {
                throw (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimeExtractorMissing')
            }
            $extractRoot = Join-Path $temporaryRoot 'Extracted'
            Remove-Item -LiteralPath $extractRoot -Recurse -Force `
                -ErrorAction SilentlyContinue
            [IO.Directory]::CreateDirectory($extractRoot) | Out-Null
            $extractExitCode = Invoke-BootstrapProcess `
                -FilePath $tar.Source `
                -ArgumentList @(
                    '-xf',
                    $archive,
                    '-C',
                    $extractRoot
                ) `
                -TimeoutSeconds 3600 -CaptureOutput `
                -WindowStyle Hidden `
                -Activity (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimeExtracting')
            if ($extractExitCode -ne 0) {
                throw (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimeExtractFailed' `
                    -Arguments @($extractExitCode))
            }
            $source = Get-InstallerExtractedComfyUIRuntimeRoot `
                -Path $extractRoot
            if ([string]::IsNullOrWhiteSpace($source)) {
                throw (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimePackageInvalid')
            }
            Enable-InstallerComfyUILauncherArguments -Path $source
            Write-InstallerComfyUIRuntimeMarker `
                -Path $source -Config $Config
            if (-not (Test-InstallerComfyUIRuntime -Path $source `
                -Config $Config -VerifyIdentity $false)) {
                throw (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimePackageInvalid')
            }
        }
        [IO.Directory]::CreateDirectory($swapPaths.Parent) | Out-Null
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        $stageItem = Get-Item -LiteralPath $stage -Force `
            -ErrorAction Stop
        if (($stageItem.Attributes -band `
                [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not ([IO.Path]::GetFullPath($stageItem.Parent.FullName).
                TrimEnd('\')).Equals(
                    $swapPaths.Parent,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
            throw [IO.InvalidDataException]::new(
                'ComfyUI stage yolu guvenli degil.'
            )
        }
        $arguments = @(
            $source,
            $stage,
            '/E',
            '/COPY:DAT',
            '/DCOPY:DAT',
            '/R:2',
            '/W:2',
            '/XJ',
            '/NP',
            '/NFL',
            '/NDL',
            '/NJH',
            '/NJS',
            '/XD',
            (Join-Path $source 'ComfyUI\user'),
            (Join-Path $source 'ComfyUI\input'),
            (Join-Path $source 'ComfyUI\output'),
            (Join-Path $source 'ComfyUI\temp'),
            (Join-Path $source 'WinlamaLogs'),
            (Join-Path $source '.winlama'),
            '__pycache__',
            '/XF',
            '*.pyc',
            '*.pyo',
            (Join-Path $source 'ComfyUI\extra_model_paths.yaml')
        )
        $robocopyExitCode = Invoke-BootstrapProcess `
            -FilePath 'robocopy.exe' -ArgumentList $arguments `
            -TimeoutSeconds 7200 -CaptureOutput `
            -WindowStyle Hidden `
            -Activity (Get-LocalizedText `
                -Key 'Installer.ComfyUI.RuntimeCopying')
        if ($robocopyExitCode -ge 8 -or
            -not (Test-InstallerComfyUIRuntimeLayout -Path $stage)) {
            throw (Get-LocalizedText `
                -Key 'Installer.ComfyUI.RuntimeCopyFailed' `
                -Arguments @($robocopyExitCode))
        }
        if ($localPackageSource -and $requiredNodes.Count -gt 0) {
            $sourceNodeState = Join-Path $source `
                '.winlama\custom-node-requirements.json'
            $stageNodeState = Join-Path $stage `
                '.winlama\custom-node-requirements.json'
            [IO.Directory]::CreateDirectory(
                [IO.Path]::GetDirectoryName($stageNodeState)
            ) | Out-Null
            Copy-Item -LiteralPath $sourceNodeState `
                -Destination $stageNodeState -Force -ErrorAction Stop
        }
        if ($localPackageSource -and
            -not (Test-InstallerComfyUILocalRuntimeIdentity `
                -Path $stage -Config $Config)) {
            if ($SourceSelection -ceq 'Automatic') {
                $null = Remove-InstallerComfyUICleanupPath -Path $stage
                Write-InstallerLog -Level WARN `
                    -Message 'Installer.ComfyUI.RuntimeFallback' `
                    -MessageArguments @('LOCAL_RUNTIME_HASH', $stage)
                Write-InstallerLine -Text (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimeFallback' `
                    -Arguments @('LOCAL_RUNTIME_HASH', $stage)) `
                    -Color Yellow
                return Install-InstallerComfyUIRuntime `
                    -Config $Config -SourceSelection Online `
                    -VerifiedAvailability $null `
                    -VerifyLocalPayloadHashes:$VerifyLocalPayloadHashes
            }
            throw (Get-LocalizedText `
                -Key 'Installer.ComfyUI.RuntimeCopyFailed' `
                -Arguments @($robocopyExitCode))
        }
        $null = Write-InstallerComfyUIBaseRequirements `
            -RuntimeRoot $stage -Config $Config
        Enable-InstallerComfyUILauncherArguments -Path $stage
        Write-InstallerComfyUIRuntimeMarker `
            -Path $stage -Config $Config
        if (-not (Test-InstallerComfyUIRuntime -Path $stage `
            -Config $Config -VerifyIdentity $false)) {
            throw (Get-LocalizedText `
                -Key 'Installer.ComfyUI.RuntimeCopyFailed' `
                -Arguments @($robocopyExitCode))
        }
        if (Test-Path -LiteralPath $destination -PathType Container) {
            Write-InstallerLog -Level STEP `
                -Message 'Installer.ComfyUI.RuntimeStopping'
            Stop-ProcessesFromPath -RootPath $destination
            foreach ($relativePath in @(
                'ComfyUI\custom_nodes', 'ComfyUI\user',
                'ComfyUI\input', 'ComfyUI\output',
                'ComfyUI\temp', 'WinlamaLogs'
            )) {
                $mutableSource = Join-Path $destination $relativePath
                if (-not (Test-Path -LiteralPath $mutableSource `
                    -PathType Container)) {
                    continue
                }
                $mutableTarget = Join-Path $stage $relativePath
                $mutableArguments = @(
                    $mutableSource, $mutableTarget,
                    '/E', '/COPY:DAT', '/DCOPY:DAT',
                    '/R:2', '/W:2', '/XJ', '/NP',
                    '/NFL', '/NDL', '/NJH', '/NJS',
                    '/XD', '__pycache__',
                    '/XF', '*.pyc', '*.pyo'
                )
                $mutableExitCode = Invoke-BootstrapProcess `
                    -FilePath 'robocopy.exe' `
                    -ArgumentList $mutableArguments `
                    -TimeoutSeconds 3600 -CaptureOutput `
                    -WindowStyle Hidden `
                    -Activity (Get-LocalizedText `
                        -Key 'Installer.ComfyUI.MutableCopying')
                if ($mutableExitCode -ge 8) {
                    throw (Get-LocalizedText `
                        -Key 'Installer.ComfyUI.RuntimeCopyFailed' `
                        -Arguments @($mutableExitCode))
                }
            }
            $extraModels = Join-Path $destination `
                'ComfyUI\extra_model_paths.yaml'
            if (Test-Path -LiteralPath $extraModels -PathType Leaf) {
                Copy-Item -LiteralPath $extraModels `
                    -Destination (Join-Path $stage `
                        'ComfyUI\extra_model_paths.yaml') -Force
            }
        }
        if (-not (Test-InstallerComfyUIRuntime -Path $stage `
            -Config $Config)) {
            throw (Get-LocalizedText `
                -Key 'Installer.ComfyUI.RuntimeCopyFailed' `
                -Arguments @(0))
        }
        $stageNodes = Get-InstallerComfyUIStageNodes `
            -IncludeCustomNodes $localPackageSource `
            -Nodes $requiredNodes
        $stageRequirementsState = `
            Get-InstallerComfyUIRequirementsState `
                -RuntimeRoot $stage -Nodes $stageNodes `
                -VerifyIdentity:$VerifyLocalPayloadHashes `
                -VerifyEnvironment $false `
                -ExpectedBaseRequirementLines $baseRequirementLines
        if (-not $stageRequirementsState.Ready) {
            throw [IO.InvalidDataException]::new(
                'ComfyUI stage ortam dogrulamasi basarisiz: ' +
                (Format-InstallerComfyUIDiagnosticResult `
                    -Result $stageRequirementsState)
            )
        }
        if (Test-Path -LiteralPath $backup) {
            throw [IO.IOException]::new(
                'ComfyUI backup yolu beklenmedik bicimde dolu.'
            )
        }
        if (-not (Test-InstallerComfyUIReparseChain `
            -Path $destination)) {
            throw [IO.InvalidDataException]::new(
                'ComfyUI hedef yolu reparse point iceremez.'
            )
        }
        $null = Migrate-InstallerComfyUIEmbeddedModels `
            -Config $Config `
            -ProjectRoot $script:InstallerPackageRoot `
            -RestrictedRoots @(
                $destination,
                $stage,
                $backup,
                $temporaryRoot
            )
        Write-InstallerLog -Level STEP `
            -Message 'Installer.ComfyUI.ModelPreservationVerifying'
        $null = Assert-InstallerComfyUIEmbeddedModelsPreserved `
            -Config $Config `
            -ProjectRoot $script:InstallerPackageRoot
        if (Test-Path -LiteralPath $destination) {
            Move-Item -LiteralPath $destination `
                -Destination $backup -ErrorAction Stop
        }
        try {
            Move-Item -LiteralPath $stage `
                -Destination $destination -ErrorAction Stop
            if (-not (Test-InstallerComfyUIRuntime `
                -Path $destination -Config $Config)) {
                throw (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimeCopyFailed' `
                    -Arguments @(0))
            }
        }
        catch {
            $swapFailure = $_.Exception
            try {
                $null = Remove-InstallerComfyUICleanupPath `
                    -Path $destination
                if (Test-Path -LiteralPath $backup) {
                    Move-Item -LiteralPath $backup `
                        -Destination $destination -ErrorAction Stop
                    if (-not (Test-Path -LiteralPath $destination `
                            -PathType Container) -or
                        (Test-Path -LiteralPath $backup)) {
                        throw [IO.IOException]::new(
                            'ComfyUI rollback son kosulu saglanamadi.'
                        )
                    }
                }
            }
            catch {
                throw [AggregateException]::new(
                    'ComfyUI swap ve rollback basarisiz oldu.',
                    [Exception[]]@($swapFailure, $_.Exception)
                )
            }
            throw $swapFailure
        }
        $null = Remove-InstallerComfyUICleanupPath -Path $backup
        $null = Remove-InstallerComfyUICleanupPath -Path $temporaryRoot
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.ComfyUI.RuntimeReady' `
            -Arguments @($destination)) -Color Green
        return $true
    }
    catch {
        Write-InstallerLog -Level WARN `
            -Message 'Installer.ComfyUI.RuntimeSkipped' `
            -MessageArguments @($_.Exception.Message) `
            -Exception $_.Exception
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.ComfyUI.RuntimeSkipped' `
            -Arguments @($_.Exception.Message)) -Color Yellow
        return $false
    }
    finally {
        foreach ($cleanupPath in @($stage, $temporaryRoot)) {
            try {
                $null = Remove-InstallerComfyUICleanupPath `
                    -Path $cleanupPath
            }
            catch {
                Write-Verbose ('ComfyUI cleanup hatasi: {0}' -f `
                    $_.Exception.Message)
                Write-InstallerLog -Level WARN `
                    -Message 'Installer.ComfyUI.RuntimeSkipped' `
                    -MessageArguments @($_.Exception.Message) `
                    -Exception $_.Exception
            }
        }
    }
}
function Get-InstallerComfyUIPreparationState {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][int]$ChildExitCode,
        [scriptblock]$RuntimeVerifier,
        [scriptblock]$RequirementsVerifier
    )
    if ($ChildExitCode -ne 0) {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'PREPARATION_EXIT' `
            -Detail ([string]$ChildExitCode)
    }
    $runtimeRoot = Resolve-InstallerPath `
        -Path $Config.ComfyUI.InstallPath
    $selectedNames = @($Config.ComfyUI.Requested | ForEach-Object {
        [string]$_
    })
    $requiredNodes = @($Config.ComfyUI.CustomNodes | Where-Object {
        [string]$_.RequiredBy -iin $selectedNames
    })
    $runtimeState = if ($null -ne $RuntimeVerifier) {
        $verified = & $RuntimeVerifier `
            -Path $runtimeRoot -Config $Config
        ConvertTo-InstallerComfyUIDiagnosticResult `
            -Value $verified -FailureReasonCode 'CORE_LAYOUT' `
            -Detail 'RuntimeVerifier'
    }
    else {
        Get-InstallerComfyUIRuntimeState `
            -Path $runtimeRoot -Config $Config
    }
    if (-not $runtimeState.Ready) {
        return $runtimeState
    }
    if ($null -ne $RequirementsVerifier) {
        $verified = & $RequirementsVerifier `
            -RuntimeRoot $runtimeRoot -Nodes $requiredNodes
        return ConvertTo-InstallerComfyUIDiagnosticResult `
            -Value $verified -FailureReasonCode 'IMPORT_PROBE' `
            -Detail 'RequirementsVerifier'
    }
    return Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot $runtimeRoot -Nodes $requiredNodes `
        -ExpectedBaseRequirementLines @(
            Get-InstallerComfyUIBaseRequirements -Config $Config
        )
}
function Test-InstallerComfyUIPreparationResult {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][int]$ChildExitCode,
        [scriptblock]$RuntimeVerifier,
        [scriptblock]$RequirementsVerifier
    )
    $result = Get-InstallerComfyUIPreparationState `
        -Config $Config -ChildExitCode $ChildExitCode `
        -RuntimeVerifier $RuntimeVerifier `
        -RequirementsVerifier $RequirementsVerifier
    return [bool]$result.Ready
}
function Prepare-InstallerComfyUIRuntime {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$EffectiveConfigPath
    )
    if (-not $Config.ComfyUI.Enabled) {
        return $false
    }
    $scriptPath = Join-Path $PSScriptRoot `
        'Modules\UI\ComfyUI.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.RequiredFileMissing' `
            -Arguments @($scriptPath))
    }
    $powershell = Get-PowerShellExecutable `
        -MinimumVersion ([version]$Config.MinimumPowerShellVersion) `
        -MachineOnly
    if ([string]::IsNullOrWhiteSpace($powershell)) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.PowerShellUnavailable' `
            -Arguments @($Config.MinimumPowerShellVersion))
    }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
        '-ConfigPath', $EffectiveConfigPath, '-PrepareOnly', '-NoPause'
    )
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $arguments += '-Verbose'
    }
    $childProcess = Invoke-InstallerSameConsoleProcess `
        -FilePath $powershell -ArgumentList $arguments
    if (@($childProcess).Count -ne 1 -or
        $null -eq $childProcess.PSObject.Properties['ExitCode']) {
        throw 'ComfyUI hazirlik alt sureci gecersiz sonuc dondurdu.'
    }
    $childExitCode = [int]$childProcess.ExitCode
    $preparationState = Get-InstallerComfyUIPreparationState `
        -Config $Config -ChildExitCode $childExitCode
    if (-not $preparationState.Ready) {
        if ($childExitCode -eq 0) {
            $message = Format-InstallerComfyUIDiagnosticResult `
                -Result $preparationState
            Write-InstallerLog -Level WARN `
                -Message 'Installer.ComfyUI.RuntimeSkipped' `
                -MessageArguments @($message)
            Write-WinlamaUIStatus -Level WARN -Message $message
            return $false
        }
        Write-InstallerLog -Level WARN `
            -Message 'Installer.ComfyUI.RuntimePreparationFailed' `
            -MessageArguments @($childExitCode)
        Write-WinlamaUIStatus -Level WARN -Message (
            Get-LocalizedText `
                -Key 'Installer.ComfyUI.RuntimePreparationFailed' `
                -Arguments @($childExitCode)
        )
        return $false
    }
    return $true
}
function Get-InstallerComfyUIModelAssets {
    param([Parameter(Mandatory)][pscustomobject]$Model)
    $property = $Model.PSObject.Properties['Assets']
    if ($null -eq $property) {
        return @()
    }
    return @($property.Value)
}
function Get-InstallerComfyUIAssetPath {
    param(
        [Parameter(Mandatory)][pscustomobject]$Asset,
        [Parameter(Mandatory)][string]$Root
    )
    $relativePath = [string]$Asset.RelativePath
    if ([IO.Path]::IsPathRooted($relativePath)) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.AbsoluteChildPath' `
            -Arguments @($relativePath))
    }
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath(
        (Join-Path $fullRoot $relativePath)
    )
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith(
        $prefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.PathEscapesRoot' `
            -Arguments @($relativePath))
    }
    return $fullPath
}
function Get-InstallerComfyUIAssetSizeTolerance {
    param([Parameter(Mandatory)][double]$ExpectedBytes)
    if ($ExpectedBytes -le 0) {
        throw [ArgumentOutOfRangeException]::new('ExpectedBytes')
    }
    return [Math]::Max([double]1MB, $ExpectedBytes * 0.02)
}
function Assert-InstallerComfyUIAssetSizeContracts {
    $smallTolerance = Get-InstallerComfyUIAssetSizeTolerance `
        -ExpectedBytes ([double]10MB)
    $largeTolerance = Get-InstallerComfyUIAssetSizeTolerance `
        -ExpectedBytes ([double]100GB)
    if ($smallTolerance -ne [double]1MB -or
        $largeTolerance -ne [double]2GB) {
        throw 'ComfyUI asset boyut toleransi sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Installer.ComfyUIAssetSize'
    return $true
}
function Test-InstallerComfyUIAssetSize {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$Item,
        [Parameter(Mandatory)][pscustomobject]$Asset
    )
    $expectedBytes = [double]$Asset.SizeGB * 1GB
    if ($Item.Length -lt 1 -or $expectedBytes -le 0) {
        return $false
    }
    $tolerance = Get-InstallerComfyUIAssetSizeTolerance `
        -ExpectedBytes $expectedBytes
    return [Math]::Abs(
        [double]$Item.Length - $expectedBytes
    ) -le $tolerance
}
function Assert-InstallerComfyUIAssetTargetSafety {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Target,
        [scriptblock]$ReparseProbe
    )
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $resolvedTarget = [IO.Path]::GetFullPath($Target)
    $prefix = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTarget.StartsWith(
            $prefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw [IO.InvalidDataException]::new(
            "ComfyUI model hedefi kok disina cikiyor: $resolvedTarget"
        )
    }
    $parent = Split-Path -Parent $resolvedTarget
    foreach ($candidate in @($resolvedRoot, $parent, $resolvedTarget)) {
        $parameters = @{ Path = $candidate }
        if ($null -ne $ReparseProbe) {
            $parameters.ReparseProbe = $ReparseProbe
        }
        if (-not (Test-InstallerComfyUIReparseChain @parameters)) {
            throw [IO.InvalidDataException]::new(
                "ComfyUI model hedefi reparse iceriyor: $candidate"
            )
        }
    }
    return [pscustomobject]@{
        Root = $resolvedRoot
        Parent = $parent
        Target = $resolvedTarget
    }
}
function Get-InstallerComfyUIModelDirectoryName {
    param([Parameter(Mandatory)][pscustomobject]$Model)
    $property = $Model.PSObject.Properties['LocalDirectory']
    $name = if ($null -ne $property) {
        [string]$property.Value
    }
    else {
        ''
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $asset = @(Get-InstallerComfyUIModelAssets -Model $Model) |
            Select-Object -First 1
        if ($null -ne $asset) {
            $name = @(([string]$asset.RelativePath) -split '[\\/]')[0]
        }
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [string]$Model.Name
    }
    if ([IO.Path]::IsPathRooted($name) -or
        $name -match '(^|[\\/])\.\.?([\\/]|$)' -or
        $name -match '[\\/]$') {
        throw (Get-LocalizedText -Key 'Manager.Error.AbsoluteChildPath' `
            -Arguments @($name))
    }
    return $name
}
function Get-InstallerComfyUIModelFiles {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return @()
    }
    $extensions = @(
        '.bin', '.ckpt', '.gguf', '.onnx', '.pt', '.pth',
        '.safetensors'
    )
    try {
        return @(Get-InstallerReparseSafeTreeFiles -Root $Path |
            Where-Object {
                $_.Extension -iin $extensions -and $_.Length -gt 0
            })
    }
    catch {
        Write-Verbose ('ComfyUI model agaci guvenli degil: {0}' -f `
            $_.Exception.Message)
        return @()
    }
}
function Get-InstallerComfyUILocalModelDirectory {
    param(
        [Parameter(Mandatory)][pscustomobject]$Model,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    if (@(Get-InstallerComfyUIModelAssets -Model $Model).Count -eq 0) {
        return $null
    }
    $modelsRoot = Join-Path $ProjectRoot 'Models'
    $name = Get-InstallerComfyUIModelDirectoryName -Model $Model
    $path = Join-Path $modelsRoot $name
    if (@(Get-InstallerComfyUIModelFiles -Path $path).Count -eq 0) {
        return $null
    }
    return [IO.Path]::GetFullPath($path)
}
function Get-InstallerComfyUICatalog {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    return @($Config.ComfyUI.Catalog | Where-Object {
        @(Get-InstallerComfyUIModelAssets -Model $_).Count -gt 0
    })
}
function Get-InstallerFileSha256WithProgress {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    $showProgress = $item.Length -ge 256MB
    if ($showProgress) {
        Write-InstallerLog -Level INFO `
            -Message 'Installer.FileHash.Starting' `
            -MessageArguments @($item.Name, ($item.Length / 1GB))
    }
    $stream = [IO.FileStream]::new(
        $resolved,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read,
        8MB,
        [IO.FileOptions]::SequentialScan
    )
    $algorithm = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try {
        $buffer = [byte[]]::new(8MB)
        $processed = 0L
        $progressClock = [Diagnostics.Stopwatch]::StartNew()
        while (($read = $stream.Read(
            $buffer,
            0,
            $buffer.Length
        )) -gt 0) {
            $algorithm.AppendData($buffer, 0, $read)
            $processed += $read
            if ($showProgress -and
                $progressClock.Elapsed.TotalSeconds -ge 15) {
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.FileHash.Progress' `
                    -MessageArguments @(
                        $item.Name,
                        ($processed / 1GB),
                        ($item.Length / 1GB)
                    )
                $progressClock.Restart()
            }
        }
        $hash = [BitConverter]::ToString(
            $algorithm.GetHashAndReset()
        ).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
    if ($showProgress) {
        Write-InstallerLog -Level INFO `
            -Message 'Installer.FileHash.Completed' `
            -MessageArguments @($item.Name)
    }
    return $hash
}
function Get-InstallerCachedFileSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$HashCache,
        [scriptblock]$HashReader
    )
    $resolved = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    $key = $resolved.ToUpperInvariant()
    if ($null -ne $HashCache -and $HashCache.ContainsKey($key)) {
        $cached = $HashCache[$key]
        if ([long]$cached.Length -eq [long]$item.Length -and
            [long]$cached.LastWriteTicks -eq
                [long]$item.LastWriteTimeUtc.Ticks) {
            return [string]$cached.Sha256
        }
    }
    $hash = if ($null -ne $HashReader) {
        [string](& $HashReader -Path $resolved)
    }
    else {
        Get-InstallerFileSha256WithProgress -Path $resolved
    }
    if ($null -ne $HashCache) {
        $HashCache[$key] = [pscustomobject]@{
            Length = [long]$item.Length
            LastWriteTicks = [long]$item.LastWriteTimeUtc.Ticks
            Sha256 = $hash
        }
    }
    return $hash
}
function Test-InstallerComfyUIModelInstalled {
    param(
        [Parameter(Mandatory)][pscustomobject]$Model,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$VerifyHash,
        [hashtable]$HashCache
    )
    $assets = @(Get-InstallerComfyUIModelAssets -Model $Model)
    if ($assets.Count -eq 0) {
        return $false
    }
    foreach ($root in @(Get-InstallerComfyUIModelSearchRoots `
        -Config $Config -ProjectRoot $ProjectRoot)) {
        $installed = $true
        foreach ($asset in $assets) {
            $path = Get-InstallerComfyUIAssetPath -Asset $asset `
                -Root $root
            if (-not (Test-InstallerComfyUIReparseChain -Path $path) -or
                -not (Test-Path -LiteralPath $path -PathType Leaf) -or
                -not (Test-InstallerComfyUIAssetSize `
                    -Item (Get-Item -LiteralPath $path -Force) `
                    -Asset $asset)) {
                $installed = $false
                break
            }
            if ($VerifyHash) {
                $expectedHash = [string]$asset.Sha256
                $actualHash = Get-InstallerCachedFileSha256 `
                    -Path $path -HashCache $HashCache
                if ($actualHash -ine $expectedHash) {
                    if ($null -ne $HashCache) {
                        $HashCache.Remove(
                            ([IO.Path]::GetFullPath(
                                $path
                            ).ToUpperInvariant())
                        )
                    }
                    $installed = $false
                    break
                }
            }
        }
        if ($installed) {
            return $true
        }
    }
    return $false
}
function Test-InstallerComfyUILocalModelCopied {
    param(
        [Parameter(Mandatory)][pscustomobject]$Model,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [bool]$VerifyHash = $true,
        [hashtable]$HashCache
    )
    if (@(Get-InstallerComfyUIModelAssets -Model $Model).Count -eq 0) {
        return $false
    }
    return Test-InstallerComfyUIModelInstalled -Model $Model `
        -Config $Config -ProjectRoot $ProjectRoot `
        -VerifyHash:$VerifyHash `
        -HashCache $HashCache
}
function Copy-InstallerComfyUILocalModel {
    param(
        [Parameter(Mandatory)][pscustomobject]$Model,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [ValidateSet('Local', 'Online', 'Automatic')]
        [string]$SourceSelection = 'Automatic',
        [bool]$VerifyLocalPayloadHashes = $true,
        [hashtable]$HashCache
    )
    if (@(Get-InstallerComfyUIModelAssets -Model $Model).Count -eq 0) {
        throw 'ComfyUI modeli canonical asset kimligi icermiyor.'
    }
    $null = Install-ComfyUIModelPayload -Model $Model `
        -Config $Config -ProjectRoot $ProjectRoot `
        -SourceSelection $SourceSelection `
        -VerifyLocalPayloadHashes:$VerifyLocalPayloadHashes `
        -HashCache $HashCache
    return Test-InstallerComfyUIModelInstalled -Model $Model `
        -Config $Config -ProjectRoot $ProjectRoot -VerifyHash `
        -HashCache $HashCache
}
function Test-InstallerComfyUILocalModelSource {
    param(
        [Parameter(Mandatory)][pscustomobject]$Model,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [bool]$VerifyHash = $true,
        [hashtable]$HashCache
    )
    $assets = @(Get-InstallerComfyUIModelAssets -Model $Model)
    if ($assets.Count -eq 0) {
        return $false
    }
    $packageRoot = Join-Path $ProjectRoot 'Models'
    foreach ($asset in $assets) {
        $path = Get-InstallerComfyUIAssetPath -Asset $asset `
            -Root $packageRoot
        if (-not (Test-InstallerComfyUIReparseChain -Path $path) -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
        $item = Get-Item -LiteralPath $path -Force
        if (-not (Test-InstallerComfyUIAssetSize `
                -Item $item -Asset $asset) -or
            [string]$asset.Sha256 -notmatch '^[a-fA-F0-9]{64}$') {
            return $false
        }
        if ($VerifyHash -and
            (Get-InstallerCachedFileSha256 -Path $path `
                -HashCache $HashCache) -ine [string]$asset.Sha256) {
            if ($null -ne $HashCache) {
                $HashCache.Remove(
                    ([IO.Path]::GetFullPath($path).ToUpperInvariant())
                )
            }
            return $false
        }
    }
    return $true
}
function Get-InstallerOrdinalTreeHash {
    param([Parameter(Mandatory)][string[]]$Lines)
    $ordered = [Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        $ordered.Add($line)
    }
    $ordered.Sort([StringComparer]::Ordinal)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($ordered -join "`n")
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash($bytes)
        )).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}
function Get-InstallerDirectoryTreeHash {
    param([Parameter(Mandatory)][string]$Root)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-InstallerReparseSafeTreeFiles `
        -Root $fullRoot | Where-Object {
            $_.FullName -notmatch '[\\/]\.git([\\/]|$)' -and
            $_.FullName -notmatch '[\\/]__pycache__([\\/]|$)' -and
            $_.Extension -notin @('.pyc', '.pyo')
        })) {
        $relative = $file.FullName.Substring($fullRoot.Length + 1).
            Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add("$relative|$($file.Length)|$hash")
    }
    return Get-InstallerOrdinalTreeHash -Lines $lines.ToArray()
}
function Test-InstallerComfyUICustomNodeTree {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][pscustomobject]$Descriptor,
        [bool]$VerifyHash = $true
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $false
    }
    foreach ($relativePath in @($Descriptor.RequiredFiles)) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root `
            ([string]$relativePath)) -PathType Leaf)) {
            return $false
        }
    }
    if (-not $VerifyHash) {
        return [string]$Descriptor.TreeSha256 -match
            '^[a-fA-F0-9]{64}$'
    }
    try {
        return (Get-InstallerDirectoryTreeHash -Root $Root) -ieq
            [string]$Descriptor.TreeSha256
    }
    catch {
        return $false
    }
}
function Test-InstallerComfyUIWheelhouse {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [bool]$VerifyHash = $true
    )
    $wheelhouse = Join-Path $ProjectRoot `
        'Runtime\ComfyUI\wheelhouse'
    $manifestPath = Join-Path $wheelhouse `
        '.winlama-wheelhouse.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw `
            -Encoding UTF8 | ConvertFrom-InstallerJson
        if ([int]$manifest.SchemaVersion -ne 1 -or
            @($manifest.Files).Count -eq 0) {
            return $false
        }
        $listed = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($record in @($manifest.Files)) {
            $name = [string]$record.Path
            $expectedHash = [string]$record.Sha256
            if ([string]::IsNullOrWhiteSpace($name) -or
                [IO.Path]::GetFileName($name) -cne $name -or
                [IO.Path]::GetExtension($name) -ine '.whl' -or
                $expectedHash -notmatch '^[a-fA-F0-9]{64}$' -or
                -not $listed.Add($name)) {
                return $false
            }
            $path = Join-Path $wheelhouse $name
            $item = Get-Item -LiteralPath $path -Force `
                -ErrorAction Stop
            if ($item.Length -lt 1 -or
                ($item.Attributes -band `
                    [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($VerifyHash -and
                    (Get-FileHash -LiteralPath $path `
                        -Algorithm SHA256).Hash -ine $expectedHash)) {
                return $false
            }
        }
        $actual = @(Get-ChildItem -LiteralPath $wheelhouse `
            -File -Filter '*.whl' -Force -ErrorAction Stop)
        return $actual.Count -eq $listed.Count -and
            @($actual | Where-Object {
                -not $listed.Contains($_.Name)
            }).Count -eq 0
    }
    catch {
        return $false
    }
}
function Invoke-InstallerComfyUIPythonProbe {
    param(
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [scriptblock]$ProcessRunner,
        [ref]$CapturedOutput
    )
    try {
        if ($null -ne $ProcessRunner) {
            $runnerOutput = @(& $ProcessRunner -Python $Python `
                -Arguments $Arguments `
                -WorkingDirectory $WorkingDirectory)
            if ($runnerOutput.Count -eq 0) {
                return -1
            }
            $outputLines = @()
            if ($runnerOutput.Count -gt 1) {
                $outputLines = @(
                    $runnerOutput[0..($runnerOutput.Count - 2)] |
                        ForEach-Object { [string]$_ }
                )
                $outputLines | Out-Host
            }
            if ($null -ne $CapturedOutput) {
                $CapturedOutput.Value = $outputLines -join `
                    [Environment]::NewLine
            }
            return [int]$runnerOutput[-1]
        }
        $parameters = @{
            FilePath = $Python
            ArgumentList = $Arguments
            TimeoutSeconds = 120
            CaptureOutput = $true
            WindowStyle = 'Hidden'
            WorkingDirectory = $WorkingDirectory
        }
        if ($null -ne $CapturedOutput) {
            $parameters.CapturedOutput = $CapturedOutput
        }
        return Invoke-BootstrapProcess @parameters
    }
    catch {
        Write-Verbose (Get-LocalizedText `
            -Key 'Installer.ComfyUI.EnvironmentProbe.Exception' `
            -Arguments @($_.Exception.Message))
        return -1
    }
}
function Get-InstallerComfyUIProbeDiagnosticText {
    param(
        [AllowEmptyString()][string]$Output,
        [ValidateRange(128, 16384)][int]$MaximumLength = 4096
    )
    if ([string]::IsNullOrWhiteSpace($Output)) {
        return Get-LocalizedText `
            -Key 'Installer.ComfyUI.EnvironmentProbe.NoOutput'
    }
    $value = ($Output -replace `
        '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]|\p{Cf}', '')
    $value = (($value -split '\r\n|\n|\r|\u0085|\u2028|\u2029') |
        ForEach-Object {
        $_.Trim()
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    }) -join ' | '
    if ([string]::IsNullOrWhiteSpace($value)) {
        return Get-LocalizedText `
            -Key 'Installer.ComfyUI.EnvironmentProbe.NoOutput'
    }
    if ($value.Length -le $MaximumLength) {
        return $value
    }
    $tail = $value.Substring($value.Length - $MaximumLength)
    return (Get-LocalizedText `
        -Key 'Installer.ComfyUI.EnvironmentProbe.OutputTruncated' `
        -Arguments @($MaximumLength, $tail))
}
function Write-InstallerComfyUIProbeDiagnostics {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$Output
    )
    $diagnostic = Get-InstallerComfyUIProbeDiagnosticText `
        -Output $Output
    Write-InstallerLog -Level WARN `
        -Message 'Installer.ComfyUI.EnvironmentProbe.Diagnostics' `
        -MessageArguments @($Phase, $ExitCode, $diagnostic)
    return $diagnostic
}
function Get-InstallerComfyUIImportFailureDetail {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$Output
    )
    $starts = [regex]::Matches(
        [string]$Output,
        '(?m)^WINLAMA_IMPORT_START:(?<module>[A-Za-z0-9_.-]+)\s*$'
    )
    $completed = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($match in [regex]::Matches(
        [string]$Output,
        '(?m)^WINLAMA_IMPORT_OK:(?<module>[A-Za-z0-9_.-]+)\s*$'
    )) {
        $null = $completed.Add($match.Groups['module'].Value)
    }
    for ($index = $starts.Count - 1; $index -ge 0; $index--) {
        $module = $starts[$index].Groups['module'].Value
        if ($completed.Contains($module)) {
            continue
        }
        return (Get-LocalizedText `
            -Key 'Installer.ComfyUI.EnvironmentProbe.ImportFailureDetail' `
            -Arguments @($module, $ExitCode))
    }
    return (Get-LocalizedText `
        -Key 'Installer.ComfyUI.EnvironmentProbe.FailureDetail' `
        -Arguments @($ExitCode))
}
function Test-InstallerComfyUIRequirementLinesContract {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [AllowEmptyString()][string[]]$Lines
    )
    $activeCount = 0
    foreach ($line in $Lines) {
        $value = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($value) -or
            $value.StartsWith('#')) {
            continue
        }
        if ($value -match '(?i)[a-z][a-z0-9+.-]*:' -or
            $value -match '(?i)(git|hg|svn|bzr)\+' -or
            $value.StartsWith('-') -or
            $value -match '(?i)(^|\s)--[a-z]' -or
            $value -match '\s@\s' -or
            $value -match '[\\/]' -or
            $value -match '^[a-zA-Z]:' -or
            $value -in @('.', '..') -or
            $value -match ('(?i)\.(?:whl|zip|tar|tar\.gz|' +
                'tar\.bz2|tar\.xz|tgz)(?:\s*(?:;.*)?$)')) {
            return $false
        }
        $activeCount++
    }
    return $activeCount -gt 0
}
function Test-InstallerComfyUIRequirementsSourceContract {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -lt 1 -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            return $false
        }
        return Test-InstallerComfyUIRequirementLinesContract `
            -Lines ([IO.File]::ReadAllLines($Path))
    }
    catch {
        return $false
    }
}
function Test-InstallerComfyUIBaseRequirementsIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [string[]]$ExpectedLines
    )
    if (-not (Test-InstallerComfyUIRequirementsSourceContract `
        -Path $Path)) {
        return $false
    }
    try {
        $actualLines = @([IO.File]::ReadAllLines($Path))
        if ($actualLines.Count -ne $ExpectedLines.Count) {
            return $false
        }
        for ($index = 0; $index -lt $ExpectedLines.Count; $index++) {
            if ([string]$actualLines[$index] -cne
                [string]$ExpectedLines[$index]) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}
function Get-InstallerComfyUIBaseRequirements {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $property = $Config.ComfyUI.PSObject.Properties[
        'BaseRequirements'
    ]
    $lines = if ($null -eq $property) {
        @()
    }
    else {
        @($property.Value | ForEach-Object { [string]$_ })
    }
    if (-not (Test-InstallerComfyUIRequirementLinesContract `
        -Lines $lines)) {
        throw 'ComfyUI temel requirements manifesti gecersiz.'
    }
    $content = ($lines -join "`n") + "`n"
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $actualHash = [BitConverter]::ToString(
            $algorithm.ComputeHash(
                [Text.Encoding]::UTF8.GetBytes($content)
            )
        ).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
    if ($actualHash -ine
        [string]$Config.ComfyUI.BaseRequirementsSha256) {
        throw 'ComfyUI temel requirements manifest kimligi gecersiz.'
    }
    return $lines
}
function Write-InstallerComfyUIBaseRequirements {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $path = Join-Path $RuntimeRoot 'ComfyUI\requirements.txt'
    $lines = @(Get-InstallerComfyUIBaseRequirements -Config $Config)
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if (-not (Test-InstallerComfyUIRequirementsSourceContract `
            -Path $path)) {
            throw "ComfyUI temel requirements kaynagi gecersiz: $path"
        }
        if (Test-InstallerComfyUIBaseRequirementsIdentity `
            -Path $path -ExpectedLines $lines) {
            return $path
        }
    }
    Write-AtomicTextFile -Path $path -Content ($lines -join "`r`n")
    if (-not (Test-InstallerComfyUIBaseRequirementsIdentity `
        -Path $path -ExpectedLines $lines)) {
        throw "ComfyUI temel requirements kaynagi yazilamadi: $path"
    }
    return $path
}
function Get-InstallerComfyUIPythonEnvironmentState {
    param(
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [AllowEmptyCollection()][string[]]$BaseRequirements = @(),
        [AllowEmptyCollection()][string[]]$NodeRequirements = @(),
        [switch]$IncludeCustomNodeImports,
        [scriptblock]$ProcessRunner,
        [scriptblock]$RequirementsSourceVerifier
    )
    $pythonItem = Get-Item -LiteralPath $Python -Force `
        -ErrorAction SilentlyContinue
    if ($null -eq $pythonItem -or $pythonItem.Length -lt 1 -or
        ($pythonItem.Attributes -band `
            [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not (Test-Path -LiteralPath $WorkingDirectory `
            -PathType Container)) {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'BASE_REQUIREMENTS_DRY_RUN' `
            -Detail $Python
    }
    $probeIndex = 0
    $probeCount = $BaseRequirements.Count +
        $NodeRequirements.Count + 2
    foreach ($entry in @(
        [pscustomobject]@{
            Paths = @($BaseRequirements)
            ReasonCode = 'BASE_REQUIREMENTS_DRY_RUN'
        },
        [pscustomobject]@{
            Paths = @($NodeRequirements)
            ReasonCode = 'NODE_REQUIREMENTS_DRY_RUN'
        }
    )) {
        foreach ($requirementsPath in $entry.Paths) {
            $probeIndex++
            $requirementsParent = Split-Path -Leaf (
                Split-Path -Parent $requirementsPath
            )
            $requirementsLabel = Join-Path $requirementsParent `
                ([IO.Path]::GetFileName($requirementsPath))
            $probePhase = Get-LocalizedText `
                -Key 'Installer.ComfyUI.EnvironmentProbe.Requirements' `
                -Arguments @($requirementsLabel)
            Write-InstallerLog -Level INFO `
                -Message 'Installer.ComfyUI.EnvironmentProbe.Starting' `
                -MessageArguments @(
                    $probeIndex,
                    $probeCount,
                    $probePhase
                )
            $sourceSafe = if ($null -ne $RequirementsSourceVerifier) {
                [bool](& $RequirementsSourceVerifier `
                    -Path $requirementsPath)
            }
            else {
                Test-InstallerComfyUIRequirementsSourceContract `
                    -Path $requirementsPath
            }
            if (-not (Test-Path -LiteralPath $requirementsPath `
                -PathType Leaf) -or -not $sourceSafe) {
                Write-InstallerLog -Level WARN `
                    -Message `
                        'Installer.ComfyUI.EnvironmentProbe.SourceInvalid' `
                    -MessageArguments @(
                        $probeIndex,
                        $probeCount,
                        $probePhase,
                        $requirementsPath
                    )
                return New-InstallerComfyUIDiagnosticResult `
                    -Ready $false -ReasonCode $entry.ReasonCode `
                    -Detail $requirementsPath
            }
            $arguments = @(
                '-B', '-I', '-s', '-X', 'utf8', '-m', 'pip',
                '--isolated', 'install',
                '--disable-pip-version-check', '--no-input',
                '--dry-run', '--no-index', '--requirement',
                $requirementsPath
            )
            $probeOutput = ''
            $exitCode = Invoke-InstallerComfyUIPythonProbe `
                -Python $Python -Arguments $arguments `
                -WorkingDirectory $WorkingDirectory `
                -ProcessRunner $ProcessRunner `
                -CapturedOutput ([ref]$probeOutput)
            if ($exitCode -ne 0) {
                $null = Write-InstallerComfyUIProbeDiagnostics `
                    -Phase $probePhase -ExitCode $exitCode `
                    -Output $probeOutput
                Write-InstallerLog -Level WARN `
                    -Message 'Installer.ComfyUI.EnvironmentProbe.Failed' `
                    -MessageArguments @(
                        $probeIndex,
                        $probeCount,
                        $probePhase,
                        $exitCode
                    )
                return New-InstallerComfyUIDiagnosticResult `
                    -Ready $false -ReasonCode $entry.ReasonCode `
                    -Detail "$requirementsPath ($exitCode)"
            }
            Write-InstallerLog -Level INFO `
                -Message 'Installer.ComfyUI.EnvironmentProbe.Completed' `
                -MessageArguments @(
                    $probeIndex,
                    $probeCount,
                    $probePhase
                )
        }
    }
    $probeIndex++
    $probePhase = Get-LocalizedText `
        -Key 'Installer.ComfyUI.EnvironmentProbe.PipCheck'
    Write-InstallerLog -Level INFO `
        -Message 'Installer.ComfyUI.EnvironmentProbe.Starting' `
        -MessageArguments @($probeIndex, $probeCount, $probePhase)
    $checkArguments = @(
        '-B', '-I', '-s', '-X', 'utf8', '-m', 'pip', '--isolated',
        '--disable-pip-version-check', 'check'
    )
    $checkOutput = ''
    $checkExitCode = Invoke-InstallerComfyUIPythonProbe `
        -Python $Python -Arguments $checkArguments `
        -WorkingDirectory $WorkingDirectory `
        -ProcessRunner $ProcessRunner `
        -CapturedOutput ([ref]$checkOutput)
    if ($checkExitCode -ne 0) {
        $null = Write-InstallerComfyUIProbeDiagnostics `
            -Phase $probePhase -ExitCode $checkExitCode `
            -Output $checkOutput
        Write-InstallerLog -Level WARN `
            -Message 'Installer.ComfyUI.EnvironmentProbe.Failed' `
            -MessageArguments @(
                $probeIndex,
                $probeCount,
                $probePhase,
                $checkExitCode
            )
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'PIP_CHECK' `
            -Detail ([string]$checkExitCode)
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.ComfyUI.EnvironmentProbe.Completed' `
        -MessageArguments @($probeIndex, $probeCount, $probePhase)
    $importCode = 'import importlib,os,sys;' +
        'sys.path.insert(0,os.getcwd()); modules=(' +
        "'torch','comfy','numpy','PIL','yaml','aiohttp'"
    if ($IncludeCustomNodeImports) {
        $importCode += ",'ftfy','accelerate','einops','diffusers'" +
            ",'peft','sentencepiece','google.protobuf'" +
            ",'pyloudnorm','gguf','cv2','scipy','imageio_ffmpeg'"
    }
    $importCode += ',);[(print(' +
        "'WINLAMA_IMPORT_START:'+name,flush=True)," +
        'importlib.import_module(name),print(' +
        "'WINLAMA_IMPORT_OK:'+name,flush=True))" +
        'for name in modules]'
    $importArguments = @(
        '-B', '-I', '-s', '-X', 'utf8', '-c', $importCode
    )
    $probeIndex++
    $probePhase = Get-LocalizedText `
        -Key 'Installer.ComfyUI.EnvironmentProbe.Imports'
    Write-InstallerLog -Level INFO `
        -Message 'Installer.ComfyUI.EnvironmentProbe.Starting' `
        -MessageArguments @($probeIndex, $probeCount, $probePhase)
    $importOutput = ''
    $importExitCode = Invoke-InstallerComfyUIPythonProbe `
        -Python $Python -Arguments $importArguments `
        -WorkingDirectory $WorkingDirectory `
        -ProcessRunner $ProcessRunner `
        -CapturedOutput ([ref]$importOutput)
    if ($importExitCode -ne 0) {
        $null = Write-InstallerComfyUIProbeDiagnostics `
            -Phase $probePhase -ExitCode $importExitCode `
            -Output $importOutput
        Write-InstallerLog -Level WARN `
            -Message 'Installer.ComfyUI.EnvironmentProbe.Failed' `
            -MessageArguments @(
                $probeIndex,
                $probeCount,
                $probePhase,
                $importExitCode
        )
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'IMPORT_PROBE' `
            -Detail (Get-InstallerComfyUIImportFailureDetail `
                -ExitCode $importExitCode -Output $importOutput)
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.ComfyUI.EnvironmentProbe.Completed' `
        -MessageArguments @($probeIndex, $probeCount, $probePhase)
    return New-InstallerComfyUIDiagnosticResult `
        -Ready $true -ReasonCode 'READY'
}
function Test-InstallerComfyUIPythonEnvironment {
    param(
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [AllowEmptyCollection()][string[]]$Requirements = @(),
        [switch]$IncludeCustomNodeImports,
        [scriptblock]$ProcessRunner,
        [scriptblock]$RequirementsSourceVerifier
    )
    $baseRequirements = @()
    $nodeRequirements = @()
    if ($Requirements.Count -gt 0) {
        $baseRequirements = @($Requirements[0])
    }
    if ($Requirements.Count -gt 1) {
        $nodeRequirements = @($Requirements[1..(
            $Requirements.Count - 1
        )])
    }
    $result = Get-InstallerComfyUIPythonEnvironmentState `
        -Python $Python -WorkingDirectory $WorkingDirectory `
        -BaseRequirements $baseRequirements `
        -NodeRequirements $nodeRequirements `
        -IncludeCustomNodeImports:$IncludeCustomNodeImports `
        -ProcessRunner $ProcessRunner `
        -RequirementsSourceVerifier $RequirementsSourceVerifier
    return [bool]$result.Ready
}
function Get-InstallerComfyUIEmbeddedPythonEnvironmentState {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [object[]]$Nodes,
        [scriptblock]$ProcessRunner
    )
    $python = Join-Path $RuntimeRoot 'python_embeded\python.exe'
    $workingDirectory = Join-Path $RuntimeRoot 'ComfyUI'
    $baseRequirementsPath = Join-Path $workingDirectory `
        'requirements.txt'
    if (-not (Test-Path -LiteralPath $baseRequirementsPath `
        -PathType Leaf)) {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'BASE_REQUIREMENTS_MISSING' `
            -Detail $baseRequirementsPath
    }
    $baseRequirements = @($baseRequirementsPath)
    $nodeRequirements = @($Nodes | ForEach-Object {
        Join-Path $workingDirectory `
            "custom_nodes\$($_.Name)\requirements.txt"
    })
    return Get-InstallerComfyUIPythonEnvironmentState `
        -Python $python -WorkingDirectory $workingDirectory `
        -BaseRequirements $baseRequirements `
        -NodeRequirements $nodeRequirements `
        -IncludeCustomNodeImports:($Nodes.Count -gt 0) `
        -ProcessRunner $ProcessRunner
}
function Test-InstallerComfyUIEmbeddedPythonEnvironment {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [object[]]$Nodes,
        [scriptblock]$ProcessRunner
    )
    $result = Get-InstallerComfyUIEmbeddedPythonEnvironmentState `
        -RuntimeRoot $RuntimeRoot -Nodes $Nodes `
        -ProcessRunner $ProcessRunner
    return [bool]$result.Ready
}
function Test-InstallerComfyUIRuntimeEnvironmentProbeRequired {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$PackageRuntimeRoot
    )
    try {
        $runtimePath = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')
        $packagePath = [IO.Path]::GetFullPath(
            $PackageRuntimeRoot
        ).TrimEnd('\')
        return -not $runtimePath.Equals(
            $packagePath,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $true
    }
}
function Get-InstallerComfyUIRequirementsState {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [object[]]$Nodes,
        [bool]$VerifyIdentity = $true,
        [bool]$VerifyEnvironment = $true,
        [scriptblock]$EnvironmentVerifier,
        [scriptblock]$StateReader,
        [scriptblock]$NodeTreeVerifier,
        [scriptblock]$RequirementsHashReader,
        [scriptblock]$BaseRequirementsPathTester,
        [scriptblock]$BaseRequirementsSourceVerifier,
        [scriptblock]$BaseRequirementsIdentityVerifier,
        [switch]$AllowBaseRequirementsReplacement,
        [AllowEmptyCollection()][string[]]$BaseRequirementLines = @(),
        [AllowEmptyCollection()]
        [string[]]$ExpectedBaseRequirementLines = @()
    )
    $reasonCode = 'BASE_REQUIREMENTS_SOURCE'
    try {
        $baseRequirementsPath = Join-Path $RuntimeRoot `
            'ComfyUI\requirements.txt'
        $baseRequirementsExists = if ($null -ne
            $BaseRequirementsPathTester) {
            [bool](& $BaseRequirementsPathTester `
                -Path $baseRequirementsPath)
        }
        else {
            Test-Path -LiteralPath $baseRequirementsPath -PathType Leaf
        }
        if (-not $baseRequirementsExists -and
            $BaseRequirementLines.Count -lt 1) {
            return New-InstallerComfyUIDiagnosticResult `
                -Ready $false -ReasonCode 'BASE_REQUIREMENTS_MISSING' `
                -Detail $baseRequirementsPath
        }
        $baseRequirementsSafe = if (-not $baseRequirementsExists) {
            Test-InstallerComfyUIRequirementLinesContract `
                -Lines $BaseRequirementLines
        }
        elseif ($null -ne $BaseRequirementsSourceVerifier) {
            [bool](& $BaseRequirementsSourceVerifier `
                -Path $baseRequirementsPath)
        }
        else {
            Test-InstallerComfyUIRequirementsSourceContract `
                -Path $baseRequirementsPath
        }
        if (-not $baseRequirementsSafe) {
            return New-InstallerComfyUIDiagnosticResult `
                -Ready $false -ReasonCode $reasonCode `
                -Detail $baseRequirementsPath
        }
        if ($baseRequirementsExists -and
            $ExpectedBaseRequirementLines.Count -gt 0) {
            $baseIdentityReady = if ($null -ne
                $BaseRequirementsIdentityVerifier) {
                [bool](& $BaseRequirementsIdentityVerifier `
                    -Path $baseRequirementsPath `
                    -ExpectedLines $ExpectedBaseRequirementLines)
            }
            else {
                Test-InstallerComfyUIBaseRequirementsIdentity `
                    -Path $baseRequirementsPath `
                    -ExpectedLines $ExpectedBaseRequirementLines
            }
            $replacementAllowed =
                $AllowBaseRequirementsReplacement -and
                -not $VerifyEnvironment
            if (-not $baseIdentityReady -and
                -not $replacementAllowed) {
                return New-InstallerComfyUIDiagnosticResult `
                    -Ready $false `
                    -ReasonCode 'BASE_REQUIREMENTS_IDENTITY' `
                    -Detail $baseRequirementsPath
            }
        }
        $reasonCode = 'NODE_STATE'
        if ($Nodes.Count -gt 0) {
            $statePath = Join-Path $RuntimeRoot `
                '.winlama\custom-node-requirements.json'
            if ($null -eq $StateReader -and
                -not (Test-Path -LiteralPath $statePath `
                -PathType Leaf)) {
                return New-InstallerComfyUIDiagnosticResult `
                    -Ready $false -ReasonCode $reasonCode `
                    -Detail $statePath
            }
            $state = if ($null -ne $StateReader) {
                & $StateReader -Path $statePath
            }
            else {
                Get-Content -LiteralPath $statePath -Raw `
                    -Encoding UTF8 | ConvertFrom-InstallerJson
            }
            if ($null -eq $state) {
                return New-InstallerComfyUIDiagnosticResult `
                    -Ready $false -ReasonCode $reasonCode `
                    -Detail $statePath
            }
            foreach ($descriptor in $Nodes) {
                $name = [string]$descriptor.Name
                $recordProperty = $state.PSObject.Properties[$name]
                if ($null -eq $recordProperty) {
                    return New-InstallerComfyUIDiagnosticResult `
                        -Ready $false -ReasonCode 'NODE_STATE' `
                        -Detail $name
                }
                $record = $recordProperty.Value
                if ([string]$record.Commit -cne
                        [string]$descriptor.Commit -or
                    [string]$record.TreeSha256 -ine
                        [string]$descriptor.TreeSha256) {
                    return New-InstallerComfyUIDiagnosticResult `
                        -Ready $false -ReasonCode 'NODE_STATE' `
                        -Detail $name
                }
                $nodeRoot = Join-Path $RuntimeRoot `
                    "ComfyUI\custom_nodes\$name"
                $reasonCode = 'NODE_TREE'
                $nodeTreeReady = if ($null -ne $NodeTreeVerifier) {
                    [bool](& $NodeTreeVerifier -Root $nodeRoot `
                        -Descriptor $descriptor `
                        -VerifyHash $VerifyIdentity)
                }
                else {
                    Test-InstallerComfyUICustomNodeTree `
                        -Root $nodeRoot -Descriptor $descriptor `
                        -VerifyHash $VerifyIdentity
                }
                if (-not $nodeTreeReady) {
                    return New-InstallerComfyUIDiagnosticResult `
                        -Ready $false -ReasonCode $reasonCode `
                        -Detail $name
                }
                $reasonCode = 'NODE_REQUIREMENTS_HASH'
                $requirementsPath = Join-Path $nodeRoot `
                    'requirements.txt'
                if ($null -eq $RequirementsHashReader -and
                    -not (Test-Path -LiteralPath $requirementsPath `
                    -PathType Leaf)) {
                    return New-InstallerComfyUIDiagnosticResult `
                        -Ready $false -ReasonCode $reasonCode `
                        -Detail $name
                }
                if ($null -eq $RequirementsHashReader -and
                    -not (Test-InstallerComfyUIRequirementsSourceContract `
                        -Path $requirementsPath)) {
                    return New-InstallerComfyUIDiagnosticResult `
                        -Ready $false `
                        -ReasonCode 'NODE_REQUIREMENTS_SOURCE' `
                        -Detail $name
                }
                $requirementsHash = if ($null -ne
                    $RequirementsHashReader) {
                    & $RequirementsHashReader `
                        -Path $requirementsPath `
                        -Descriptor $descriptor
                }
                else {
                    (Get-FileHash -LiteralPath $requirementsPath `
                        -Algorithm SHA256).Hash
                }
                if ([string]$record.RequirementsSha256 -ine
                    $requirementsHash) {
                    return New-InstallerComfyUIDiagnosticResult `
                        -Ready $false -ReasonCode $reasonCode `
                        -Detail $name
                }
                $reasonCode = 'NODE_STATE'
            }
        }
        if (-not $VerifyIdentity -or -not $VerifyEnvironment) {
            return New-InstallerComfyUIDiagnosticResult `
                -Ready $true -ReasonCode 'READY'
        }
        $reasonCode = 'IMPORT_PROBE'
        if ($null -ne $EnvironmentVerifier) {
            $verified = & $EnvironmentVerifier `
                -RuntimeRoot $RuntimeRoot -Nodes $Nodes
            return ConvertTo-InstallerComfyUIDiagnosticResult `
                -Value $verified `
                -FailureReasonCode 'IMPORT_PROBE' `
                -Detail 'EnvironmentVerifier'
        }
        if ($ValidateOnly) {
            return New-InstallerComfyUIDiagnosticResult `
                -Ready $false -ReasonCode 'IMPORT_PROBE' `
                -Detail 'ValidateOnly'
        }
        return Get-InstallerComfyUIEmbeddedPythonEnvironmentState `
            -RuntimeRoot $RuntimeRoot -Nodes $Nodes
    }
    catch {
        return New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode $reasonCode `
            -Detail $_.Exception.Message
    }
}
function Test-InstallerComfyUIRequirementsState {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [object[]]$Nodes,
        [bool]$VerifyIdentity = $true,
        [bool]$VerifyEnvironment = $true,
        [scriptblock]$EnvironmentVerifier
    )
    $result = Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot $RuntimeRoot -Nodes $Nodes `
        -VerifyIdentity $VerifyIdentity `
        -VerifyEnvironment $VerifyEnvironment `
        -EnvironmentVerifier $EnvironmentVerifier
    if (-not $result.Ready) {
        Write-Verbose (Format-InstallerComfyUIDiagnosticResult `
            -Result $result)
    }
    return [bool]$result.Ready
}
function Test-InstallerComfyUINodeFallbackReason {
    param(
        [Parameter(Mandatory)][pscustomobject]$Result,
        [Parameter(Mandatory)][int]$NodeCount
    )
    return -not $Result.Ready -and $NodeCount -gt 0 -and
        $Result.ReasonCode -in @(
            'NODE_STATE',
            'NODE_TREE',
            'NODE_REQUIREMENTS_HASH',
            'NODE_REQUIREMENTS_DRY_RUN'
        )
}
function Get-InstallerComfyUIRequirementsFallbackState {
    param(
        [Parameter(Mandatory)][pscustomobject]$Result,
        [Parameter(Mandatory)][int]$NodeCount,
        [Parameter(Mandatory)][bool]$NodeTreesReady,
        [Parameter(Mandatory)][bool]$NodeDependenciesReady,
        [Parameter(Mandatory)][bool]$WheelhouseReady
    )
    $requiresNodeRepair = Test-InstallerComfyUINodeFallbackReason `
        -Result $Result -NodeCount $NodeCount
    $requiresWheelhouse = $requiresNodeRepair -and
        -not $NodeDependenciesReady
    return [pscustomobject][ordered]@{
        Ready = [bool]$Result.Ready -or ($requiresNodeRepair -and
            $NodeTreesReady -and ($NodeDependenciesReady -or
                $WheelhouseReady))
        RequiresWheelhouse = $requiresWheelhouse
        ReasonCode = [string]$Result.ReasonCode
        Detail = [string]$Result.Detail
    }
}
function Get-InstallerComfyUISourceAvailability {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Models,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [AllowEmptyCollection()][string[]]$RequiredNodeModelNames,
        [bool]$VerifyIdentity = $true,
        [switch]$QuickProbe,
        [scriptblock]$IdentityVerifier,
        [scriptblock]$EnvironmentVerifier,
        [scriptblock]$RuntimeStateReader,
        [scriptblock]$RequirementsStateReader,
        [scriptblock]$LocalRuntimeIdentityTester,
        [scriptblock]$InstalledModelTester,
        [scriptblock]$LocalModelTester,
        [hashtable]$HashCache
    )
    if ($VerifyIdentity -and $null -ne $IdentityVerifier) {
        return & $IdentityVerifier $Models $Config $ProjectRoot
    }
    if ($QuickProbe -and $VerifyIdentity) {
        throw 'ComfyUI hizli probe kimlik dogrulamasi yapamaz.'
    }
    $destination = Resolve-InstallerPath -Path $Config.ComfyUI.InstallPath
    $localRuntimeRoot = Join-Path $ProjectRoot 'Runtime\ComfyUI'
    $expectedBaseRequirementLines = @(
        Get-InstallerComfyUIBaseRequirements -Config $Config
    )
    $getRuntimeState = {
        param([string]$Path)
        if ($null -ne $RuntimeStateReader) {
            return & $RuntimeStateReader -Path $Path `
                -Config $Config -VerifyIdentity $VerifyIdentity
        }
        if ($QuickProbe) {
            return Get-InstallerComfyUIRuntimeState `
                -Path $Path -Config $Config -VerifyIdentity $false `
                -TreeReparseVerifier {
                    param([string]$Root)
                    Test-InstallerComfyUIRuntimeQuickReparseSafety `
                        -Root $Root
                }
        }
        return Get-InstallerComfyUIRuntimeState `
            -Path $Path -Config $Config `
            -VerifyIdentity $VerifyIdentity
    }.GetNewClosure()
    $getRequirementsState = {
        param([string]$RuntimeRoot, [object[]]$Nodes)
        if ($null -ne $RequirementsStateReader) {
            return & $RequirementsStateReader `
                -RuntimeRoot $RuntimeRoot -Nodes $Nodes `
                -VerifyIdentity $VerifyIdentity
        }
        $candidateVerifyEnvironment = `
            Test-InstallerComfyUIRuntimeEnvironmentProbeRequired `
                -RuntimeRoot $RuntimeRoot `
                -PackageRuntimeRoot $localRuntimeRoot
        $baseRequirementLines = @()
        $isLocalPackageRuntime =
            [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\').Equals(
                [IO.Path]::GetFullPath($localRuntimeRoot).TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase
            )
        if ($isLocalPackageRuntime) {
            $baseRequirementLines = $expectedBaseRequirementLines
        }
        return Get-InstallerComfyUIRequirementsState `
            -RuntimeRoot $RuntimeRoot -Nodes $Nodes `
            -VerifyIdentity $VerifyIdentity `
            -VerifyEnvironment $candidateVerifyEnvironment `
            -EnvironmentVerifier $EnvironmentVerifier `
            -AllowBaseRequirementsReplacement:$isLocalPackageRuntime `
            -BaseRequirementLines $baseRequirementLines `
            -ExpectedBaseRequirementLines `
                $expectedBaseRequirementLines
    }.GetNewClosure()
    $destinationState = & $getRuntimeState $destination
    $runtimeInstalled = [bool]$destinationState.Ready
    $localRuntimeState = New-InstallerComfyUIDiagnosticResult `
        -Ready $false -ReasonCode 'CORE_LAYOUT' `
        -Detail $localRuntimeRoot
    $localRuntime = $null
    $readLocalRuntime = {
        $state = & $getRuntimeState $localRuntimeRoot
        $localIdentityReady = $true
        if ($state.Ready -and $VerifyIdentity) {
            $localIdentityReady = if (
                $null -ne $LocalRuntimeIdentityTester
            ) {
                [bool](& $LocalRuntimeIdentityTester `
                    -Path $localRuntimeRoot -Config $Config)
            }
            else {
                Test-InstallerComfyUILocalRuntimeIdentity `
                    -Path $localRuntimeRoot -Config $Config
            }
        }
        if ($state.Ready -and $VerifyIdentity -and
            -not $localIdentityReady) {
            $state = New-InstallerComfyUIDiagnosticResult `
                -Ready $false -ReasonCode 'LOCAL_RUNTIME_HASH' `
                -Detail $localRuntimeRoot
        }
        return [pscustomobject]@{
            State = $state
            Path = if ($state.Ready) {
                [IO.Path]::GetFullPath($localRuntimeRoot)
            }
            else {
                $null
            }
        }
    }.GetNewClosure()
    $modelSources = [Collections.Generic.List[string]]::new()
    $missing = [Collections.Generic.List[string]]::new()
    $localCandidates = [Collections.Generic.List[object]]::new()
    $testLocalModel = {
        param([pscustomobject]$Model, [bool]$VerifyHash)
        if ($null -ne $LocalModelTester) {
            return [bool](& $LocalModelTester -Model $Model `
                -ProjectRoot $ProjectRoot -VerifyHash $VerifyHash)
        }
        return Test-InstallerComfyUILocalModelSource -Model $Model `
            -ProjectRoot $ProjectRoot -VerifyHash $VerifyHash `
            -HashCache $HashCache
    }.GetNewClosure()
    foreach ($model in $Models) {
        $installed = if ($null -ne $InstalledModelTester) {
            [bool](& $InstalledModelTester -Model $model `
                -Config $Config -ProjectRoot $ProjectRoot `
                -VerifyHash $VerifyIdentity)
        }
        else {
            Test-InstallerComfyUIModelInstalled -Model $model `
                -Config $Config -ProjectRoot $ProjectRoot `
                -VerifyHash:$VerifyIdentity -HashCache $HashCache
        }
        if ($installed) {
            continue
        }
        $localModelReady = & $testLocalModel $model $false
        if ($localModelReady) {
            $localCandidates.Add($model)
        }
        else {
            $missing.Add([string]$model.Name)
        }
    }
    if ($VerifyIdentity -and $missing.Count -eq 0) {
        foreach ($model in $localCandidates) {
            if ([bool](& $testLocalModel $model $true)) {
                $modelSources.Add([string]$model.Name)
            }
            else {
                $missing.Add([string]$model.Name)
            }
        }
    }
    else {
        foreach ($model in $localCandidates) {
            $modelSources.Add([string]$model.Name)
        }
    }
    $selectedNames = if ($PSBoundParameters.ContainsKey(
        'RequiredNodeModelNames'
    )) {
        @($RequiredNodeModelNames)
    }
    else {
        @($Models | ForEach-Object { [string]$_.Name })
    }
    $requiredNodes = @($Config.ComfyUI.CustomNodes | Where-Object {
        [string]$_.RequiredBy -iin $selectedNames
    })
    if (-not $VerifyIdentity) {
        $localResult = & $readLocalRuntime
        $localRuntimeState = $localResult.State
        $localRuntime = $localResult.Path
        $quickState = New-InstallerComfyUIDiagnosticResult `
            -Ready $true -ReasonCode 'READY'
        $quickRuntimeReady = $runtimeInstalled -or
            -not [string]::IsNullOrWhiteSpace($localRuntime)
        return [pscustomobject]@{
            RuntimeInstalled = $runtimeInstalled
            LocalRuntimePath = $localRuntime
            LocalRuntimeIdentityVerified = $false
            LocalModelNames = $modelSources.ToArray()
            MissingRequirements = $missing.ToArray()
            RuntimeState = if ($runtimeInstalled) {
                $destinationState
            }
            else {
                $localRuntimeState
            }
            RequirementsState = $quickState
            RequirementsCandidatePath = $null
            RequirementsFromDestination = $false
            DestinationRequirementsState = $null
            FallbackState = [pscustomobject][ordered]@{
                Ready = $true
                RequiresWheelhouse = $false
                ReasonCode = 'READY'
                Detail = ''
            }
            AnyLocal = -not [string]::IsNullOrWhiteSpace($localRuntime) -or
                $modelSources.Count -gt 0
            LocalReady = $quickRuntimeReady -and $missing.Count -eq 0
        }
    }
    $runtimeCandidates = [Collections.Generic.List[string]]::new()
    if ($runtimeInstalled) {
        $runtimeCandidates.Add($destination)
    }
    $requirementsState = if ($runtimeCandidates.Count -gt 0) {
        New-InstallerComfyUIDiagnosticResult `
            -Ready $false -ReasonCode 'IMPORT_PROBE' `
            -Detail 'No candidate verified.'
    }
    else {
        $destinationState
    }
    $requirementsCandidatePath = $null
    $requirementsCandidateVerifyEnvironment = $false
    $destinationRequirementsState = $null
    $fallbackCandidateState = $null
    $fallbackCandidatePath = $null
    $fallbackCandidateVerifyEnvironment = $false
    $localRuntimeLoaded = $false
    while ($true) {
        foreach ($runtimeCandidate in $runtimeCandidates) {
            $candidateVerifyEnvironment = `
                Test-InstallerComfyUIRuntimeEnvironmentProbeRequired `
                    -RuntimeRoot $runtimeCandidate `
                    -PackageRuntimeRoot $localRuntimeRoot
            $candidateState = & $getRequirementsState `
                $runtimeCandidate $requiredNodes
            $requirementsState = $candidateState
            $requirementsCandidatePath = $runtimeCandidate
            $requirementsCandidateVerifyEnvironment = `
                $candidateVerifyEnvironment
            if ([string]::Equals(
                    [IO.Path]::GetFullPath($runtimeCandidate),
                    [IO.Path]::GetFullPath($destination),
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                $destinationRequirementsState = $candidateState
            }
            if ($candidateState.Ready) {
                break
            }
            if ($null -eq $fallbackCandidateState -and
                $candidateVerifyEnvironment -and
                (Test-InstallerComfyUINodeFallbackReason `
                    -Result $candidateState `
                    -NodeCount $requiredNodes.Count)) {
                $fallbackCandidateState = $candidateState
                $fallbackCandidatePath = $runtimeCandidate
                $fallbackCandidateVerifyEnvironment = `
                    $candidateVerifyEnvironment
            }
        }
        if ($requirementsState.Ready -or
            $null -ne $fallbackCandidateState -or
            $localRuntimeLoaded -or $missing.Count -gt 0) {
            break
        }
        $localRuntimeLoaded = $true
        $localResult = & $readLocalRuntime
        $localRuntimeState = $localResult.State
        $localRuntime = $localResult.Path
        if ([string]::IsNullOrWhiteSpace($localRuntime)) {
            if (-not $runtimeInstalled) {
                $requirementsState = $localRuntimeState
            }
            break
        }
        $runtimeCandidates.Clear()
        $runtimeCandidates.Add($localRuntime)
    }
    if (-not $requirementsState.Ready -and
        $null -ne $fallbackCandidateState) {
        $requirementsState = $fallbackCandidateState
        $requirementsCandidatePath = $fallbackCandidatePath
        $requirementsCandidateVerifyEnvironment = `
            $fallbackCandidateVerifyEnvironment
    }
    $requirementsReady = [bool]$requirementsState.Ready
    $localNodeTreesReady = $true
    $requiresNodeRepair = $requirementsCandidateVerifyEnvironment -and
        (Test-InstallerComfyUINodeFallbackReason `
            -Result $requirementsState -NodeCount $requiredNodes.Count)
    if ($requiresNodeRepair) {
        foreach ($descriptor in $requiredNodes) {
            $sourceRoot = Join-Path $ProjectRoot `
                ([string]$descriptor.OfflinePath)
            if (-not (Test-InstallerComfyUICustomNodeTree `
                -Root $sourceRoot -Descriptor $descriptor `
                -VerifyHash $VerifyIdentity)) {
                $missing.Add("ComfyUI node: $($descriptor.Name)")
                $localNodeTreesReady = $false
            }
        }
    }
    $nodeDependenciesReady = $false
    if ($requiresNodeRepair -and $localNodeTreesReady -and
        -not [string]::IsNullOrWhiteSpace(
            $requirementsCandidatePath
        )) {
        if ($null -ne $EnvironmentVerifier) {
            $dependencyVerification = & $EnvironmentVerifier `
                -RuntimeRoot $requirementsCandidatePath `
                -Nodes $requiredNodes
            $dependencyState = `
                ConvertTo-InstallerComfyUIDiagnosticResult `
                    -Value $dependencyVerification `
                    -FailureReasonCode 'NODE_REQUIREMENTS_DRY_RUN' `
                    -Detail 'EnvironmentVerifier'
            $nodeDependenciesReady = [bool]$dependencyState.Ready
        }
        elseif (-not $ValidateOnly) {
            $workingDirectory = Join-Path `
                $requirementsCandidatePath 'ComfyUI'
            $baseRequirementsPath = Join-Path $workingDirectory `
                'requirements.txt'
            $baseRequirements = if (Test-Path -LiteralPath `
                $baseRequirementsPath -PathType Leaf) {
                @($baseRequirementsPath)
            }
            else {
                @()
            }
            $nodeRequirements = @($requiredNodes | ForEach-Object {
                Join-Path (Join-Path $ProjectRoot `
                    ([string]$_.OfflinePath)) 'requirements.txt'
            })
            $dependencyState = `
                Get-InstallerComfyUIPythonEnvironmentState `
                    -Python (Join-Path $requirementsCandidatePath `
                        'python_embeded\python.exe') `
                    -WorkingDirectory $workingDirectory `
                    -BaseRequirements $baseRequirements `
                    -NodeRequirements $nodeRequirements
            $nodeDependenciesReady = [bool]$dependencyState.Ready
        }
    }
    $requiresWheelhouse = $requiresNodeRepair -and
        -not $nodeDependenciesReady
    $wheelhouseReady = $false
    if ($requiresWheelhouse) {
        $wheelhouseReady = Test-InstallerComfyUIWheelhouse `
            -ProjectRoot $ProjectRoot `
            -VerifyHash $VerifyIdentity
        if (-not $wheelhouseReady) {
            $missing.Add('ComfyUI wheelhouse')
        }
    }
    $fallbackState = Get-InstallerComfyUIRequirementsFallbackState `
        -Result $requirementsState `
        -NodeCount $requiredNodes.Count `
        -NodeTreesReady $localNodeTreesReady `
        -NodeDependenciesReady $nodeDependenciesReady `
        -WheelhouseReady $wheelhouseReady
    $runtimeReady = $runtimeInstalled -or
        -not [string]::IsNullOrWhiteSpace($localRuntime)
    $requirementsFromDestination =
        -not [string]::IsNullOrWhiteSpace($requirementsCandidatePath) -and
        [string]::Equals(
            [IO.Path]::GetFullPath($requirementsCandidatePath),
            [IO.Path]::GetFullPath($destination),
            [StringComparison]::OrdinalIgnoreCase
        )
    if (-not $runtimeReady) {
        $missing.Add((Format-InstallerComfyUIDiagnosticResult `
            -Result $requirementsState))
    }
    elseif (-not $fallbackState.Ready) {
        $missing.Add((Format-InstallerComfyUIDiagnosticResult `
            -Result $requirementsState))
    }
    return [pscustomobject]@{
        RuntimeInstalled = $runtimeInstalled
        LocalRuntimePath = $localRuntime
        LocalRuntimeIdentityVerified = $VerifyIdentity -and
            -not [string]::IsNullOrWhiteSpace($localRuntime)
        LocalModelNames = $modelSources.ToArray()
        MissingRequirements = $missing.ToArray()
        RuntimeState = if ($runtimeInstalled) {
            $destinationState
        }
        else {
            $localRuntimeState
        }
        RequirementsState = $requirementsState
        RequirementsCandidatePath = $requirementsCandidatePath
        RequirementsFromDestination = $requirementsFromDestination
        DestinationRequirementsState = $destinationRequirementsState
        FallbackState = $fallbackState
        AnyLocal = -not [string]::IsNullOrWhiteSpace($localRuntime) -or
            $modelSources.Count -gt 0 -or
            ($requiresNodeRepair -and $localNodeTreesReady)
        LocalReady = $runtimeReady -and $missing.Count -eq 0 -and
            $fallbackState.Ready
    }
}
function Test-InstallerComfyUIQuickProbeRequested {
    param(
        [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
        [string]$Selection,
        [Parameter(Mandatory)][bool]$VerifyLocalIdentity
    )
    return $Selection -eq 'Prompt' -and -not $VerifyLocalIdentity
}
function Read-InstallerComfyUISource {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Models,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [AllowEmptyCollection()][string[]]$RequiredNodeModelNames,
        [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
        [string]$Selection = 'Prompt',
        [scriptblock]$InputReader,
        [bool]$VerifyLocalIdentity = $true,
        [switch]$QuickProbe,
        [scriptblock]$IdentityVerifier,
        [scriptblock]$EnvironmentVerifier,
        [hashtable]$HashCache,
        [ref]$AvailabilityResult
    )
    $Selection = ConvertTo-InstallerSourceSelection `
        -Selection $Selection
    if ($QuickProbe -and
        -not (Test-InstallerComfyUIQuickProbeRequested `
            -Selection $Selection `
            -VerifyLocalIdentity $VerifyLocalIdentity)) {
        throw 'ComfyUI hizli probe yalniz soru asamasinda kullanilabilir.'
    }
    if ($Selection -eq 'Online' -or
        ($Selection -eq 'Automatic' -and -not $VerifyLocalIdentity)) {
        return $Selection
    }
    $availabilityParameters = @{
        Models = $Models
        Config = $Config
        ProjectRoot = $ProjectRoot
        VerifyIdentity = $VerifyLocalIdentity
        QuickProbe = $QuickProbe
        IdentityVerifier = $IdentityVerifier
        EnvironmentVerifier = $EnvironmentVerifier
        HashCache = $HashCache
    }
    if ($PSBoundParameters.ContainsKey('RequiredNodeModelNames')) {
        $availabilityParameters.RequiredNodeModelNames = `
            $RequiredNodeModelNames
    }
    $availability = Get-InstallerComfyUISourceAvailability `
        @availabilityParameters
    if ($null -ne $AvailabilityResult) {
        $AvailabilityResult.Value = $availability
    }
    $localMissing = @($availability.MissingRequirements)
    if (-not $availability.RuntimeInstalled -and
        [string]::IsNullOrWhiteSpace($availability.LocalRuntimePath)) {
        $localMissing = @('ComfyUI runtime') + $localMissing
    }
    if ($Selection -eq 'Automatic') {
        $requirementsFromDestination =
            $null -ne $availability.PSObject.Properties[
                'RequirementsFromDestination'
            ] -and [bool]$availability.RequirementsFromDestination
        if ($availability.RuntimeInstalled -and $Models.Count -eq 0 -and
            $availability.RequirementsState.Ready -and
            $requirementsFromDestination) {
            return 'Automatic'
        }
        return $(if ($availability.LocalReady) { 'Local' } else { 'Online' })
    }
    if ($Selection -eq 'Local') {
        if (-not $availability.LocalReady) {
            throw (New-NonRetryableException -Message (
                Get-LocalizedText `
                    -Key 'Installer.ComfyUI.SourceLocalUnavailable' `
                    -Arguments @(($localMissing -join ', '))
            ))
        }
        return 'Local'
    }
    if (-not $availability.AnyLocal) {
        Write-InstallerLog -Level INFO `
            -Message 'Installer.ComfyUI.SourceOnline'
        return 'Online'
    }
    if (-not [Environment]::UserInteractive) {
        return 'Automatic'
    }
    Write-InstallerSection -Title 'Installer.Section.ComfyUISource'
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.ComfyUI.SourceDescription') -Color White
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.ComfyUI.SourceMenuLocal') -Color Green
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.ComfyUI.SourceMenuOnline') -Color Cyan
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.ComfyUI.SourceMenuAutomatic') -Color Cyan
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.ComfyUI.SourceMenuExit') -Color Yellow
    Write-InstallerRule
    while ($true) {
        $answer = (Read-WinlamaUIInput `
            -Prompt (Get-LocalizedText `
                -Key 'Installer.Prompt.ComfyUISource') `
            -Label (Get-LocalizedText `
                -Key 'Common.Prompt.Selection') -NoLeadingRule `
            -InputReader $InputReader).Trim()
        if ($answer -eq '1') {
            if ($availability.LocalReady) {
                return 'Local'
            }
            Write-WinlamaUIStatus -Level WARN `
                -Message (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.SourceLocalUnavailable' `
                    -Arguments @(($localMissing -join ', ')))
            continue
        }
        if ($answer -eq '2') {
            return 'Online'
        }
        if ($answer -eq '3') {
            return 'Automatic'
        }
        if ($answer -eq '0') {
            return 'Exit'
        }
        Write-WinlamaUIStatus -Level WARN `
            -Message (Get-LocalizedText -Key 'Common.Selection.Invalid')
    }
}
function Get-ComfyUIModelAssessment {
    param(
        [Parameter(Mandatory)][pscustomobject]$Model,
        [Parameter(Mandatory)][pscustomobject]$Hardware
    )
    $usableVram = [math]::Max(0, $Hardware.VramGB - 1)
    $usableRam = [math]::Max(0, $Hardware.RamGB - 6)
    $reqVram = [double]$Model.WorkingSpaceGB
    $reqDisk = [double]$Model.DownloadSizeGB + $reqVram
    $rank = 0
    $status = Get-LocalizedText -Key 'Installer.Assessment.Insufficient'
    if ($reqVram -le ($usableVram * 0.8) -and $Hardware.FreeDiskGB -ge $reqDisk) {
        $status = Get-LocalizedText -Key 'Installer.Assessment.Excellent'
        $rank = 4
    } elseif ($reqVram -le $usableVram -and $Hardware.FreeDiskGB -ge $reqDisk) {
        $status = Get-LocalizedText -Key 'Installer.Assessment.Good'
        $rank = 3
    } elseif ($reqVram -le ($usableVram + $usableRam) -and $Hardware.FreeDiskGB -ge $reqDisk) {
        $status = Get-LocalizedText -Key 'Installer.Assessment.Medium'
        $rank = 2
    }
    return [pscustomobject]@{ Status = $status; Rank = $rank }
}
function Show-InstallerComfyUICatalog {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][pscustomobject]$Hardware
    )
    $comfyUI = $Config.ComfyUI
    if ($null -eq $comfyUI -or
        $null -eq $comfyUI.PSObject.Properties['Catalog']) {
        return @()
    }
    $catalog = @(Get-InstallerComfyUICatalog -Config $Config `
        -ProjectRoot $ProjectRoot | Where-Object {
            $property = $_.PSObject.Properties['InstallReady']
            $null -eq $property -or [bool]$property.Value
        })
    if ($catalog.Count -eq 0) {
        return @()
    }
    Write-InstallerSection -Title 'Installer.Section.ComfyUICatalog'
    for ($i = 0; $i -lt $catalog.Count; $i++) {
        $model = $catalog[$i]
        $tagKey = if ($model.Type -eq 'ImageGeneration') {
            'Manager.ComfyUI.TagImage'
        }
        elseif ($model.Type -eq 'VideoGeneration') {
            'Manager.ComfyUI.TagVideo'
        }
        else {
            'Manager.ComfyUI.TagLocal'
        }
        $tag = Get-LocalizedText -Key $tagKey
        $localSource = Get-InstallerComfyUILocalModelDirectory `
            -Model $model -ProjectRoot $ProjectRoot
        $isLocal = -not [string]::IsNullOrWhiteSpace($localSource) -or
            (Test-InstallerComfyUIModelInstalled -Model $model `
                -Config $Config -ProjectRoot $ProjectRoot)
        $localStatus = if ($isLocal) {
            Get-LocalizedText -Key 'Manager.ComfyUI.LocalAvailable'
        } else {
            Get-LocalizedText -Key 'Manager.ComfyUI.NotInstalled'
        }
        $assessment = Get-ComfyUIModelAssessment -Model $model -Hardware $Hardware
        $color = switch ($assessment.Rank) {
            4 { 'Green' }
            3 { 'Green' }
            2 { 'Yellow' }
            default { 'Red' }
        }
        $titleText = Get-LocalizedText `
            -Key 'Installer.ComfyUI.ModelRow' `
            -Arguments @(
                ($i + 1),
                $model.Name,
                $tag,
                $model.DownloadSizeGB,
                $model.WorkingSpaceGB
            )
        Write-InstallerLine -Text $titleText -Color Cyan
        $detailText = Get-LocalizedText `
            -Key 'Installer.ComfyUI.DetailRow' `
            -Arguments @(
                $assessment.Status,
                $localStatus,
                $model.Description
            )
        Write-InstallerLine -Text $detailText -Color $color
    }
    Write-InstallerRule
    return $catalog
}
function Show-InstallerComponentSelectionLayout {
    param(
        [Parameter(Mandatory)][string]$SectionKey,
        [Parameter(Mandatory)][string]$DescriptionKey,
        [Parameter(Mandatory)][string]$PromptKey
    )
    $description = Get-LocalizedText -Key $DescriptionKey
    $prompt = Get-LocalizedText -Key $PromptKey
    if ([string]::IsNullOrWhiteSpace($description) -or
        $description -eq $DescriptionKey -or
        [string]::IsNullOrWhiteSpace($prompt) -or
        $prompt -eq $PromptKey -or $prompt -notmatch '\[.+\]') {
        throw "Kurulum secim ekrani gecersiz: $SectionKey"
    }
    Write-InstallerSection -Title $SectionKey
    Write-InstallerLine -Text $description -Color White
    Write-InstallerLine -Text $prompt -Color Cyan
    Write-InstallerRule
}
function Read-InstallerComponentSelection {
    param(
        [Parameter(Mandatory)][string]$SectionKey,
        [Parameter(Mandatory)][string]$DescriptionKey,
        [Parameter(Mandatory)][string]$PromptKey,
        [ValidateSet('Prompt', 'Install', 'Skip')]
        [string]$Selection = 'Prompt',
        [bool]$DefaultEnabled = $true,
        [bool]$Interactive = [Environment]::UserInteractive,
        [scriptblock]$InputReader
    )
    if ($Selection -ne 'Prompt') {
        return $Selection
    }
    if (-not $Interactive) {
        return $(if ($DefaultEnabled) { 'Install' } else { 'Skip' })
    }
    Show-InstallerComponentSelectionLayout -SectionKey $SectionKey `
        -DescriptionKey $DescriptionKey -PromptKey $PromptKey
    while ($true) {
        $answer = Read-WinlamaUIInput `
            -Prompt (Get-LocalizedText -Key $PromptKey) `
            -Label (Get-LocalizedText `
                -Key 'Common.Prompt.Selection') -NoLeadingRule `
            -InputReader $InputReader
        if ($answer -ceq 'EVET') {
            return 'Install'
        }
        if ($answer -ceq 'HAYIR') {
            return 'Skip'
        }
        if ($answer -eq '0') {
            return 'Exit'
        }
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Common.Selection.Invalid') -Color Yellow
    }
}
function Test-InstallerShouldSkipComponentQuestion {
    param(
        [Parameter(Mandatory)][bool]$AlreadyInstalled,
        [Parameter(Mandatory)][string]$Selection
    )
    return $AlreadyInstalled -and $Selection -ceq 'Prompt'
}
function Read-InstallerInstalledModelPreference {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Ollama', 'ComfyUI')]
        [string]$Component,
        [Parameter(Mandatory)][bool]$AlreadyInstalled,
        [AllowEmptyString()][string]$SelectionValue = '',
        [bool]$Interactive = [Environment]::UserInteractive,
        [scriptblock]$InputReader
    )
    if (-not $AlreadyInstalled -or
        -not [string]::IsNullOrWhiteSpace($SelectionValue)) {
        return 'Select'
    }
    if (-not $Interactive) {
        return 'Keep'
    }
    $keys = if ($Component -ceq 'Ollama') {
        @(
            'Installer.Section.InstalledOllamaModels',
            'Installer.InstalledOllamaModels.Description',
            'Installer.Prompt.SelectInstalledOllamaModels'
        )
    }
    else {
        @(
            'Installer.Section.InstalledComfyUIModels',
            'Installer.InstalledComfyUIModels.Description',
            'Installer.Prompt.SelectInstalledComfyUIModels'
        )
    }
    $choice = Read-InstallerComponentSelection `
        -SectionKey $keys[0] -DescriptionKey $keys[1] `
        -PromptKey $keys[2] -DefaultEnabled $false `
        -Interactive $Interactive -InputReader $InputReader
    if ($choice -ceq 'Exit') {
        return 'Exit'
    }
    return $(if ($choice -ceq 'Install') { 'Select' } else { 'Keep' })
}
function Get-InstallerRetainedModelSelection {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [AllowEmptyCollection()][string[]]$InstalledNames = @(),
        [bool]$AnyInstalled = $false,
        [switch]$PreferInstalled
    )
    $requested = @($Config.Models.Requested | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($requested.Count -gt 0) {
        return $requested -join ','
    }
    if ($PreferInstalled -and $AnyInstalled -and
        $InstalledNames.Count -eq 0) {
        return 'Skip'
    }
    if ($PreferInstalled) {
        if ($InstalledNames.Count -gt 0) {
            return $InstalledNames -join ','
        }
        if ($AnyInstalled) {
            return 'Skip'
        }
    }
    if ([string]$Config.Models.SelectionMode -ceq 'Automatic') {
        return 'Automatic'
    }
    if ($InstalledNames.Count -gt 0) {
        return $InstalledNames -join ','
    }
    return 'Skip'
}
function Test-InstallerRequestedModelsInstalled {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [AllowEmptyCollection()][string[]]$InstalledNames = @()
    )
    $requested = @($Config.Models.Requested | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    return $requested.Count -gt 0 -and
        @($requested | Where-Object {
            $_ -inotin $InstalledNames
        }).Count -eq 0
}
function Get-InstallerDesiredOllamaModelNames {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Hardware
    )
    $requested = @($Config.Models.Requested | ForEach-Object {
        [string]$_
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if ($requested.Count -gt 0) {
        return $requested
    }
    if ([string]$Config.Models.SelectionMode -ceq 'Automatic') {
        return @(Get-InstallerSelectedModelNames -Config $Config `
            -Hardware $Hardware -Automatic)
    }
    return @()
}
function Get-InstallerMissingOllamaModelNames {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [AllowEmptyCollection()][string[]]$InstalledNames = @(),
        [AllowNull()][pscustomobject]$Hardware
    )
    if ($null -eq $Hardware) {
        throw 'Model eksik listesi icin donanim profili eksik.'
    }
    $desired = @(Get-InstallerDesiredOllamaModelNames `
        -Config $Config -Hardware $Hardware)
    return @($desired | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        $_ -inotin $InstalledNames
    })
}
function Get-InstallerMissingComfyUIModels {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [object[]]$Models,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [bool]$VerifyHash = $true,
        [hashtable]$HashCache
    )
    return @($Models | Where-Object {
        -not (Test-InstallerComfyUIModelInstalled -Model $_ `
            -Config $Config -ProjectRoot $ProjectRoot `
            -VerifyHash:$VerifyHash -HashCache $HashCache)
    })
}
function New-InstallerPendingPayloadConfiguration {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [AllowEmptyCollection()][string[]]$OllamaModelNames = @(),
        [AllowEmptyCollection()][object[]]$ComfyUIModels = @(),
        [AllowEmptyCollection()][object[]]$RequiredNodeModels
    )
    $pending = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-InstallerJson
    $pending.Models.Requested = @($OllamaModelNames | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if ($pending.Models.Requested.Count -eq 0) {
        $pending.Models.LocalPackageImport.SelectedPackages = @()
        $pending.Models | Add-Member -NotePropertyName InstallSource `
            -NotePropertyValue Automatic -Force
    }
    $pending.ComfyUI.Requested = @($ComfyUIModels | Where-Object {
        $null -ne $_
    } | ForEach-Object {
        [string]$_.Name
    })
    $nodeModels = if ($PSBoundParameters.ContainsKey(
        'RequiredNodeModels'
    )) {
        @($RequiredNodeModels)
    }
    else {
        @($ComfyUIModels)
    }
    $pending.ComfyUI | Add-Member `
        -NotePropertyName PendingRequiredNodeModels `
        -NotePropertyValue @($nodeModels | Where-Object {
            $null -ne $_
        } | ForEach-Object {
            [string]$_.Name
        }) -Force
    return $pending
}
function Get-InstallerRetainedComfyUIModels {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][object[]]$Catalog,
        [Parameter(Mandatory)][object[]]$Installed
    )
    $requested = @($Config.ComfyUI.Requested | ForEach-Object {
        [string]$_
    })
    $retained = @($Catalog | Where-Object {
        [string]$_.Name -iin $requested
    })
    if ($retained.Count -gt 0) {
        return $retained
    }
    if ($Installed.Count -gt 0) {
        return $Installed
    }
    return @()
}
. (Join-Path $PSScriptRoot 'Modules\Installer\Voice.ps1')
function Test-InstallerExistingFeature {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)]
        [ValidateSet('OpenWebUI', 'Voice')]
        [string]$Feature,
        [bool]$VerifyIdentity = $true,
        [scriptblock]$FileProbe
    )
    $webRoot = Resolve-InstallerPath `
        -Path ([string]$Config.OpenWebUI.RootPath)
    $python = Join-Path $webRoot 'venv\Scripts\python.exe'
    $testFile = {
        param([string]$Path)
        if ($null -ne $FileProbe) {
            return [bool](& $FileProbe $Path)
        }
        return Test-Path -LiteralPath $Path -PathType Leaf
    }.GetNewClosure()
    if (-not (& $testFile $python)) {
        return $false
    }
    if ($Feature -ceq 'OpenWebUI') {
        $executable = Join-Path $webRoot `
            'venv\Scripts\open-webui.exe'
        if (-not (& $testFile $executable)) {
            return $false
        }
        if (-not $VerifyIdentity) {
            return $true
        }
        try {
            $probe = 'import importlib.metadata as m;' +
                'print(m.version("open-webui"))'
            $output = @(& $python -I -c $probe 2>$null)
            return $LASTEXITCODE -eq 0 -and
                $output.Count -gt 0 -and
                [string]$output[-1] -ceq
                    [string]$Config.OpenWebUI.Version
        }
        catch {
            return $false
        }
    }
    if (-not $VerifyIdentity) {
        return Test-InstallerVoiceModelCache -Config $Config `
            -FileProbe $FileProbe
    }
    try {
        $probe = 'import importlib.util as u;' +
            'm=("soundfile","torch","uvicorn","fastapi",' +
            '"pydantic","transformers");' +
            'assert all(u.find_spec(x) is not None for x in m)'
        $null = & $python -I -c $probe 2>$null
        return $LASTEXITCODE -eq 0 -and
            (Test-InstallerVoiceModelCache -Config $Config `
                -FileProbe $FileProbe)
    }
    catch {
        return $false
    }
}
function Read-InstallerComfyUISelection {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][pscustomobject]$Hardware,
        [string]$Value,
        [scriptblock]$InputReader,
        [bool]$Interactive = [Environment]::UserInteractive
    )
    if ($null -eq $Config.ComfyUI -or
        $null -eq $Config.ComfyUI.PSObject.Properties['Catalog'] -or
        @($Config.ComfyUI.Catalog).Count -eq 0) {
        return @()
    }
    $configuredCatalog = @(Get-InstallerComfyUICatalog `
        -Config $Config -ProjectRoot $ProjectRoot | Where-Object {
            $property = $_.PSObject.Properties['InstallReady']
            $null -eq $property -or [bool]$property.Value
        })
    $requested = @($Config.ComfyUI.Requested)
    $defaults = @($configuredCatalog | Where-Object {
        $_.Name -iin $requested
    })
    $explicitSelection = -not [string]::IsNullOrWhiteSpace($Value)
    if (-not $Interactive -and
        [string]::IsNullOrWhiteSpace($Value)) {
        return $defaults
    }
    $catalog = @(Show-InstallerComfyUICatalog -Config $Config `
        -ProjectRoot $ProjectRoot -Hardware $Hardware)
    if ($catalog.Count -eq 0) {
        return @()
    }
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Manager.ComfyUI.RequiresComfyUI') -Color Yellow
    while ($true) {
        $selection = $Value
        if ([string]::IsNullOrWhiteSpace($selection)) {
            $selection = Read-WinlamaUIInput `
                -Prompt (Get-LocalizedText `
                    -Key 'Installer.Prompt.ComfyUISelection') `
                -Label (Get-LocalizedText `
                    -Key 'Common.Prompt.Selection') -NoLeadingRule `
                -InputReader $InputReader
        }
        if ([string]::IsNullOrWhiteSpace($selection)) {
            Write-InstallerLine -Text `
                (Get-LocalizedText -Key 'Common.Selection.Invalid') `
                -Color Yellow
            $Value = $null
            continue
        }
        if ($selection -eq '0') {
            return 'Exit'
        }
        if ($selection -iin @('S', 'Skip')) {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.ComfyUI.Skipped'
            return @()
        }
        if ($selection -iin @('L', 'Local', 'Installed')) {
            $installed = @($catalog | Where-Object {
                Test-InstallerComfyUIModelInstalled -Model $_ `
                    -Config $Config -ProjectRoot $ProjectRoot
            })
            if ($installed.Count -gt 0) {
                return $installed
            }
            if ($explicitSelection -or -not $Interactive) {
                throw (Get-LocalizedText `
                    -Key 'Installer.Selection.NoInstalledModels')
            }
            Write-WinlamaUIStatus -Level WARN `
                -Message (Get-LocalizedText `
                    -Key 'Installer.Selection.NoInstalledModels')
            $Value = ''
            continue
        }
        if ($selection -iin @('K', 'Source', 'Package')) {
            $sourceModels = @($catalog | Where-Object {
                -not [string]::IsNullOrWhiteSpace(
                    (Get-InstallerComfyUILocalModelDirectory `
                        -Model $_ -ProjectRoot $ProjectRoot)
                )
            })
            if ($sourceModels.Count -gt 0) {
                return $sourceModels
            }
            if ($explicitSelection -or -not $Interactive) {
                throw (Get-LocalizedText `
                    -Key 'Installer.Selection.NoSourceModels')
            }
            Write-WinlamaUIStatus -Level WARN `
                -Message (Get-LocalizedText `
                    -Key 'Installer.Selection.NoSourceModels')
            $Value = ''
            continue
        }
        try {
            $indices = @(Resolve-WinlamaIndexSelection `
                -Value $selection -Count $catalog.Count -AllowAll)
            $selected = [Collections.Generic.List[object]]::new()
            foreach ($index in $indices) {
                $selected.Add($catalog[$index - 1])
            }
            if ($selected.Count -gt 0) {
                return $selected.ToArray()
            }
        }
        catch {
            if ($explicitSelection -or -not $Interactive) {
                throw
            }
            Write-InstallerLog -Level WARN `
                -Message 'Common.Selection.Invalid'
            Write-InstallerLine -Text (Get-LocalizedText `
                -Key 'Common.Selection.Invalid') -Color Yellow
            $Value = ''
        }
    }
}
function Read-InstallerOpenWebUISelection {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [ValidateSet('Prompt', 'Install', 'Skip')]
        [string]$Selection = 'Prompt'
    )
    return Read-InstallerComponentSelection `
        -SectionKey 'Installer.Section.OpenWebUISelection' `
        -DescriptionKey 'Installer.OpenWebUI.Description' `
        -PromptKey 'Installer.Prompt.OpenWebUISelection' `
        -Selection $Selection `
        -DefaultEnabled ([bool]$Config.OpenWebUI.Enabled)
}
function Read-InstallerVoiceSelection {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [ValidateSet('Prompt', 'Install', 'Skip')]
        [string]$Selection = 'Prompt'
    )
    return Read-InstallerComponentSelection `
        -SectionKey 'Installer.Section.VoiceSelection' `
        -DescriptionKey 'Installer.Voice.Description' `
        -PromptKey 'Installer.Prompt.VoiceSelection' `
        -Selection $Selection `
        -DefaultEnabled ([bool]$Config.Voice.Enabled)
}
function Read-InstallerOptionalErrorMode {
    param(
        [ValidateSet('Prompt', 'Stop', 'Continue')]
        [string]$Selection = 'Prompt',
        [bool]$DefaultContinue = $false,
        [scriptblock]$InputReader
    )
    if ($Selection -eq 'Stop') {
        return 'Stop'
    }
    if ($Selection -eq 'Continue') {
        return 'Continue'
    }
    $choice = Read-InstallerComponentSelection `
        -SectionKey 'Installer.Section.OptionalErrorMode' `
        -DescriptionKey 'Installer.OptionalErrorMode.Description' `
        -PromptKey 'Installer.Prompt.OptionalErrorMode' `
        -DefaultEnabled $DefaultContinue -InputReader $InputReader
    if ($choice -eq 'Exit') {
        return 'Exit'
    }
    return $(if ($choice -eq 'Install') { 'Continue' } else { 'Stop' })
}
function Read-InstallerLocalPayloadHashSelection {
    param(
        [ValidateSet('Prompt', 'Verify', 'Skip')]
        [string]$Selection = 'Prompt',
        [bool]$DefaultVerify = $true,
        [bool]$Interactive = [Environment]::UserInteractive,
        [scriptblock]$InputReader
    )
    if ($Selection -eq 'Verify') {
        return 'Verify'
    }
    if ($Selection -eq 'Skip') {
        return 'Skip'
    }
    if (-not $Interactive) {
        return $(if ($DefaultVerify) { 'Verify' } else { 'Skip' })
    }
    Write-InstallerSection -Title 'Installer.Section.LocalPayloadHash'
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.LocalPayloadHash.Description') -Color Yellow
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.LocalPayloadHash.Safeguards') -Color Green
    Write-InstallerRule
    while ($true) {
        $answer = Read-WinlamaUIInput `
            -Prompt (Get-LocalizedText `
                -Key 'Installer.Prompt.VerifyLocalPayloadHashes') `
            -Label (Get-LocalizedText `
                -Key 'Common.Prompt.Selection') -NoLeadingRule `
            -InputReader $InputReader
        if ($answer -ceq 'EVET') {
            return 'Verify'
        }
        if ($answer -ceq 'HAYIR') {
            return 'Skip'
        }
        if ($answer -ceq '0') {
            return 'Exit'
        }
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Common.Selection.Invalid') -Color Yellow
    }
}
function Assert-InstallerLocalPayloadHashSelectionContracts {
    $verifyQueue = [Collections.Generic.Queue[string]]::new()
    foreach ($value in @('', 'evet', 'Evet', ' EVET ', 'EVET')) {
        $verifyQueue.Enqueue($value)
    }
    $verifyReader = {
        param([string]$Label)
        return $verifyQueue.Dequeue()
    }.GetNewClosure()
    $verify = Read-InstallerLocalPayloadHashSelection `
        -Interactive $true -InputReader $verifyReader
    $skipQueue = [Collections.Generic.Queue[string]]::new()
    $skipQueue.Enqueue('HAYIR')
    $skipReader = {
        param([string]$Label)
        return $skipQueue.Dequeue()
    }.GetNewClosure()
    $skip = Read-InstallerLocalPayloadHashSelection `
        -Interactive $true -InputReader $skipReader
    $exitQueue = [Collections.Generic.Queue[string]]::new()
    $exitQueue.Enqueue('0')
    $exitReader = {
        param([string]$Label)
        return $exitQueue.Dequeue()
    }.GetNewClosure()
    $exit = Read-InstallerLocalPayloadHashSelection `
        -Interactive $true -InputReader $exitReader
    $directVerify = Read-InstallerLocalPayloadHashSelection `
        -Selection Verify -Interactive $false
    $directSkip = Read-InstallerLocalPayloadHashSelection `
        -Selection Skip -Interactive $false
    $defaultVerify = Read-InstallerLocalPayloadHashSelection `
        -Interactive $false -DefaultVerify $true
    $defaultSkip = Read-InstallerLocalPayloadHashSelection `
        -Interactive $false -DefaultVerify $false
    $description = Get-LocalizedText `
        -Key 'Installer.LocalPayloadHash.Description'
    $safeguards = Get-LocalizedText `
        -Key 'Installer.LocalPayloadHash.Safeguards'
    $prompt = Get-LocalizedText `
        -Key 'Installer.Prompt.VerifyLocalPayloadHashes'
    if ($verify -cne 'Verify' -or $verifyQueue.Count -ne 0 -or
        $skip -cne 'Skip' -or $exit -cne 'Exit' -or
        $directVerify -cne 'Verify' -or $directSkip -cne 'Skip' -or
        $defaultVerify -cne 'Verify' -or $defaultSkip -cne 'Skip' -or
        $description -notmatch 'bozuk|degistirilmis' -or
        $safeguards -notmatch 'Indirilen' -or
        $safeguards -notmatch 'imza' -or
        $safeguards -notmatch 'reparse' -or
        $safeguards -notmatch 'son (kosul|dogrulama)' -or
        $prompt -notmatch 'dogrulamasi yapilsin mi') {
        throw 'Yerel payload SHA-256 secim sozlesmesi gecersiz.'
    }
    $policyConfig = $script:InstallerConfiguration |
        ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
    $policyConfig.Installation.VerifyLocalPayloadHashes = $false
    $restoredPolicy = $policyConfig | ConvertTo-Json -Depth 100 |
        ConvertFrom-InstallerJson
    if ($restoredPolicy.Installation.VerifyLocalPayloadHashes -isnot
            [bool] -or
        [bool]$restoredPolicy.Installation.VerifyLocalPayloadHashes) {
        throw 'Yerel payload SHA-256 config aktarimi gecersiz.'
    }
    foreach ($commandName in @(
        'New-InstallerPackageRootReentryArguments',
        'Start-ElevatedInstaller',
        'Invoke-InstallerPowerShellRuntimeHandoff'
    )) {
        $definition = (Get-Command $commandName `
            -ErrorAction Stop).Definition
        if ($definition -notmatch 'LocalPayloadHashSelection') {
            throw "SHA-256 secimi alt oturuma aktarilmiyor: $commandName"
        }
    }
    $scriptSource = [IO.File]::ReadAllText($PSCommandPath)
    $optionalIndex = $scriptSource.LastIndexOf(
        '$errorMode = Read-InstallerOptionalErrorMode'
    )
    $hashIndex = $scriptSource.LastIndexOf(
        '$hashSelection = Read-InstallerLocalPayloadHashSelection'
    )
    $saveIndex = $scriptSource.IndexOf(
        '$ConfigPath = Save-EffectiveInstallerConfig -Config $config',
        $hashIndex,
        [StringComparison]::Ordinal
    )
    $handoffIndex = $scriptSource.LastIndexOf(
        '$initialPowerShellHandoff ='
    )
    $verificationIndex = $scriptSource.LastIndexOf(
        'Invoke-InstallerDeferredSourceVerification'
    )
    $powerShellBootstrapSource = (Get-Command `
        Assert-PowerShellBootstrapPackage -ErrorAction Stop).Definition
    $comfyRuntimeSource = (Get-Command `
        Install-InstallerComfyUIRuntime -ErrorAction Stop).Definition
    $comfyModelSource = (Get-Command `
        Install-ComfyUIModelPayload -ErrorAction Stop).Definition
    $comfyModelCopySource = (Get-Command `
        Copy-InstallerComfyUILocalModel -ErrorAction Stop).Definition
    $comfyModelSetupSource = (Get-Command `
        Invoke-InstallerComfyUIModelSetup -ErrorAction Stop).Definition
    $runtimeChecks = @([regex]::Matches(
        $comfyRuntimeSource,
        'Test-InstallerComfyUIRuntime\b[\s\S]{0,180}?\)'
    ))
    $sourceLightCheck = @($runtimeChecks | Where-Object {
        $_.Value -match '-Path \$source' -and
        $_.Value -match '-VerifyIdentity \$false'
    })
    $stageLightCheck = @($runtimeChecks | Where-Object {
        $_.Value -match '-Path \$stage' -and
        $_.Value -match '-VerifyIdentity \$false'
    })
    $stageExactCheck = @($runtimeChecks | Where-Object {
        $_.Value -match '-Path \$stage' -and
        $_.Value -notmatch '-VerifyIdentity \$false'
    })
    $destinationExactCheck = @($runtimeChecks | Where-Object {
        $_.Value -match '-Path \$destination' -and
        $_.Value -notmatch '-VerifyIdentity \$false'
    })
    $parseTokens = $null
    $parseErrors = $null
    $scriptAst = [Management.Automation.Language.Parser]::ParseFile(
        $PSCommandPath,
        [ref]$parseTokens,
        [ref]$parseErrors
    )
    $payloadCalls = @($scriptAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ieq 'Install-ComfyUIModelPayload'
    }, $true))
    $uncachedPayloadCalls = @($payloadCalls | Where-Object {
        @($_.CommandElements | Where-Object {
            $_ -is `
                [Management.Automation.Language.CommandParameterAst] -and
            $_.ParameterName -ieq 'HashCache'
        }).Count -ne 1
    })
    $setupTokens = $null
    $setupErrors = $null
    $setupAst = [Management.Automation.Language.Parser]::ParseInput(
        $comfyModelSetupSource,
        [ref]$setupTokens,
        [ref]$setupErrors
    )
    $setupPayloadCalls = @($setupAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ieq 'Install-ComfyUIModelPayload'
    }, $true))
    $setupExactChecks = @($setupAst.FindAll({
        param($node)
        if ($node -isnot [Management.Automation.Language.CommandAst] -or
            $node.GetCommandName() -ine
                'Test-InstallerComfyUIModelInstalled') {
            return $false
        }
        $verifyParameters = @($node.CommandElements | Where-Object {
            $_ -is `
                [Management.Automation.Language.CommandParameterAst] -and
            $_.ParameterName -ieq 'VerifyHash'
        })
        $cacheParameters = @($node.CommandElements | Where-Object {
            $_ -is `
                [Management.Automation.Language.CommandParameterAst] -and
            $_.ParameterName -ieq 'HashCache'
        })
        return $verifyParameters.Count -eq 1 -and
            $null -eq $verifyParameters[0].Argument -and
            $cacheParameters.Count -eq 1
    }, $true))
    $setupExactOrderReady = $setupPayloadCalls.Count -eq 3 -and
        $setupExactChecks.Count -eq 3
    if ($setupExactOrderReady) {
        for ($index = 0; $index -lt 3; $index++) {
            if ($setupExactChecks[$index].Extent.StartOffset -le
                    $setupPayloadCalls[$index].Extent.StartOffset -or
                ($index -lt 2 -and
                    $setupExactChecks[$index].Extent.StartOffset -ge
                        $setupPayloadCalls[$index + 1].Extent.StartOffset)) {
                $setupExactOrderReady = $false
                break
            }
        }
    }
    if ($hashIndex -lt 0 -or $optionalIndex -le $hashIndex -or
        $saveIndex -le $optionalIndex -or
        $handoffIndex -le $saveIndex -or
        $verificationIndex -le $handoffIndex -or
        $powerShellBootstrapSource -notmatch 'Get-FileHash' -or
        $powerShellBootstrapSource -notmatch 'Get-AuthenticodeSignature' -or
        $comfyRuntimeSource -notmatch `
            'Get-InstallerFileSha256WithProgress[\s\S]*-Path \$archive' -or
        $comfyRuntimeSource -notmatch `
            'Test-InstallerComfyUILocalRuntimeIdentity[\s\S]*-Path \$stage' -or
        $comfyRuntimeSource -notmatch `
            '\$SourceSelection -ceq ''Automatic''[\s\S]*' +
            'Remove-InstallerComfyUICleanupPath -Path \$stage[\s\S]*' +
            '-SourceSelection Online' -or
        $comfyRuntimeSource -notmatch `
            'Test-InstallerComfyUIRuntime[\s\S]*-Path \$destination' -or
        $runtimeChecks.Count -ne 4 -or
        $sourceLightCheck.Count -ne 1 -or
        $stageLightCheck.Count -ne 1 -or
        $stageExactCheck.Count -ne 1 -or
        $destinationExactCheck.Count -ne 1 -or
        $sourceLightCheck[0].Index -ge $stageLightCheck[0].Index -or
        $stageLightCheck[0].Index -ge $stageExactCheck[0].Index -or
        $stageExactCheck[0].Index -ge $destinationExactCheck[0].Index -or
        $parseErrors.Count -ne 0 -or $payloadCalls.Count -ne 4 -or
        $uncachedPayloadCalls.Count -ne 0 -or
        $setupErrors.Count -ne 0 -or -not $setupExactOrderReady -or
        $comfyModelSource -notmatch `
            'Get-InstallerFileSha256WithProgress[\s\S]*-Path \$temporary' -or
        $comfyModelSource -notmatch '\[hashtable\]\$HashCache' -or
        $comfyModelSource -notmatch `
            'Get-InstallerCachedFileSha256[\s\S]*' +
            '-Path \$packageAsset[\s\S]*-HashCache \$HashCache' -or
        [regex]::Matches(
            $comfyModelSource,
            '\$HashCache\.Remove\('
        ).Count -lt 3 -or
        $comfyModelCopySource -notmatch `
            'Test-InstallerComfyUIModelInstalled[\s\S]*' +
            '-VerifyHash[\s\S]*-HashCache \$HashCache' -or
        $comfyModelSetupSource -notmatch `
            'Test-InstallerComfyUIModelInstalled[\s\S]*' +
            '-VerifyHash[\s\S]*-HashCache \$HashCache') {
        throw 'Yerel SHA atlama guvenlik siniri gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.LocalPayloadHashSelection'
    return $true
}
function Invoke-InstallerDeferredSourceVerification {
    param([Parameter(Mandatory)][scriptblock[]]$Verifiers)
    foreach ($verifier in $Verifiers) {
        $null = & $verifier
    }
}
function Assert-InstallerDeferredSourceVerificationContracts {
    $fixture = $script:InstallerConfiguration |
        ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $dependency = Get-InstallerOllamaDependency -Config $fixture
    $dependency.OfflinePath = 'Install.ps1'
    $dependency.OfflineSha256 = 'A' * 64
    $dependency.Sha256 = 'A' * 64
    $fixturePath = Get-InstallerDescriptorOfflinePath `
        -Descriptor $dependency
    $outsideRejected = $false
    try {
        $null = Resolve-InstallerContainedPackagePath `
            -Root $script:InstallerPackageRoot `
            -RelativePath '..\outside.bin'
    }
    catch [IO.InvalidDataException] {
        $outsideRejected = $true
    }
    $reparseRejected = $false
    try {
        $null = Resolve-InstallerContainedPackagePath `
            -Root $script:InstallerPackageRoot `
            -RelativePath 'Install.ps1' `
            -ReparseProbe { param($Candidate) return $true }
    }
    catch [IO.InvalidDataException] {
        $reparseRejected = $true
    }
    if ([IO.Path]::GetFullPath($fixturePath) -ine
            [IO.Path]::GetFullPath($PSCommandPath) -or
        -not $outsideRejected -or -not $reparseRejected) {
        throw 'Offline kurucu paket yolu sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.OfflinePathContainment'
    $inputQueue = [Collections.Generic.Queue[string]]::new()
    $inputQueue.Enqueue('1')
    $inputQueue.Enqueue('EVET')
    $inputQueue.Enqueue('HAYIR')
    $phaseState = [pscustomobject]@{ HeavyCallCount = 0 }
    $identityVerifier = {
        param([string]$Path, [string]$ExpectedHash)
        if ([string]::IsNullOrWhiteSpace($Path) -or
            $ExpectedHash -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Inject edilen exact kaynak dogrulayicisi gecersiz girdi aldi.'
        }
        $phaseState.HeavyCallCount++
        return $true
    }.GetNewClosure()
    $quickSource = Read-InstallerOllamaInstallSource `
        -Config $fixture -Selection Prompt `
        -InstalledTester { $false } -VerifyLocalIdentity $false `
        -ArtifactVerifier $identityVerifier -Interactive $true `
        -InputReader {
            if ($phaseState.HeavyCallCount -ne 0) {
                throw 'Kaynak sorusundan once agir dogrulama basladi.'
            }
            return $inputQueue.Dequeue()
        }.GetNewClosure()
    if ($quickSource -cne 'Local' -or $inputQueue.Count -ne 2 -or
        $phaseState.HeavyCallCount -ne 0) {
        throw 'Hizli kaynak secim probe sozlesmesi gecersiz.'
    }
    $hashSelection = Read-InstallerLocalPayloadHashSelection `
        -Selection Prompt -Interactive $true -InputReader {
            if ($phaseState.HeavyCallCount -ne 0) {
                throw 'SHA-256 sorusundan once agir dogrulama basladi.'
            }
            return $inputQueue.Dequeue()
        }.GetNewClosure()
    if ($hashSelection -cne 'Verify' -or
        $inputQueue.Count -ne 1 -or
        $phaseState.HeavyCallCount -ne 0) {
        throw 'SHA-256 soru sirasi gecersiz.'
    }
    $mode = Read-InstallerOptionalErrorMode -Selection Prompt `
        -DefaultContinue $true -InputReader {
            if ($phaseState.HeavyCallCount -ne 0) {
                throw 'Son soru tamamlanmadan agir dogrulama basladi.'
            }
            return $inputQueue.Dequeue()
        }.GetNewClosure()
    if ($mode -cne 'Stop' -or $inputQueue.Count -ne 0 -or
        $phaseState.HeavyCallCount -ne 0) {
        throw 'Son soru ve ertelenmis dogrulama siniri gecersiz.'
    }
    $verifiers = @({
            if ($inputQueue.Count -ne 0) {
                throw 'Dogrulama evresinde kullanici girdisi istendi.'
            }
            $verified = Read-InstallerOllamaInstallSource `
                -Config $fixture -Selection Local `
                -InstalledTester { $false } `
                -ArtifactVerifier $identityVerifier -Interactive $false
            if ($verified -cne 'Local') {
                throw 'Exact kaynak dogrulayicisi plani uygulayamadi.'
            }
        }.GetNewClosure())
    Invoke-InstallerDeferredSourceVerification -Verifiers $verifiers
    if ($phaseState.HeavyCallCount -ne 1 -or
        $inputQueue.Count -ne 0) {
        throw 'Ertelenmis kaynak dogrulama sozlesmesi gecersiz.'
    }
    if ((Get-InstallerCancellationExitCode) -ne 2) {
        throw 'Kurulum iptal cikis kodu basari veya hata kodundan ayrilmadi.'
    }
    $installerSource = [IO.File]::ReadAllText($PSCommandPath)
    foreach ($progressToken in @(
        'Installer.SourceVerification.Starting',
        'Installer.SourceVerification.StartingWithoutPayloadHashes',
        'Installer.SourceVerification.Dependencies',
        'Installer.SourceVerification.Ollama',
        'Installer.SourceVerification.Models',
        'Installer.SourceVerification.ComfyUI',
        'Installer.SourceVerification.Completed',
        'Installer.SourceVerification.CompletedWithoutPayloadHashes',
        'Installer.ComfyUI.EnvironmentProbe.Starting',
        'Installer.ComfyUI.EnvironmentProbe.Completed',
        'Installer.ComfyUI.EnvironmentProbe.SourceInvalid',
        'Installer.ComfyUI.EnvironmentProbe.Diagnostics',
        'Installer.ComfyUI.TreeScan.Starting',
        'Installer.ComfyUI.TreeScan.Progress',
        'Installer.ComfyUI.TreeScan.Completed',
        'Installer.ComfyUI.TreeHash.Progress',
        'Installer.FileHash.Progress',
        'Installer.Process.Waiting'
    )) {
        if (-not $installerSource.Contains($progressToken) -or
            [string]::IsNullOrWhiteSpace(
                (Get-LocalizedText -Key $progressToken)
            )) {
            throw "Kurulum ilerleme olayi eksik: $progressToken"
        }
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.DeferredSourceVerification'
    Write-Verbose 'WINLAMA_UI_OK:Install.PromptBeforeHeavyWork'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.SourceProgressVisibility'
}
function Assert-InstallerComfyUIEnvironmentVerificationContracts {
    if ((Test-InstallerComfyUIRequirementLinesContract `
            -Lines ([string[]]@())) -or
        (Test-InstallerComfyUIRequirementLinesContract `
            -Lines @('', '   ', '# comment'))) {
        throw 'Bos ComfyUI requirements satirlari kabul edildi.'
    }
    if (-not (Test-InstallerComfyUIRequirementLinesContract -Lines @(
        'torch>=2.0',
        'package[extra]~=1.2; python_version >= "3.10"',
        '# comment'
    ))) {
        throw 'Guvenli ComfyUI requirements satirlari reddedildi.'
    }
    foreach ($badLine in @(
        '--extra-index-url https://example.invalid/simple',
        'package @ https://example.invalid/package.whl',
        '-r nested.txt',
        'git+ssh://example.invalid/repository',
        'package @ file:///C:/fixture/package.whl',
        '..\fixture\package.whl',
        '.',
        '..',
        'local-package.zip',
        'local-package.tar.gz'
    )) {
        if (Test-InstallerComfyUIRequirementLinesContract `
            -Lines @($badLine)) {
            throw "Guvenli olmayan requirements satiri kabul edildi: $badLine"
        }
    }
    $staticSourceState = [pscustomobject]@{
        EnvironmentCalls = 0
        SourceCalls = 0
    }
    $missingStaticSource = Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot 'C:\Fixture\ComfyUIRuntime' -Nodes @() `
        -VerifyEnvironment $false `
        -BaseRequirementLines @('torch') `
        -BaseRequirementsPathTester { return $false } `
        -BaseRequirementsSourceVerifier {
            $staticSourceState.SourceCalls++
            throw 'Eksik requirements kaynagi okunmaya calisildi.'
        }.GetNewClosure() `
        -EnvironmentVerifier {
            $staticSourceState.EnvironmentCalls++
            throw 'Statik kaynak denetiminde Python calistirildi.'
        }.GetNewClosure()
    $missingRejectedSource = Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot 'C:\Fixture\ComfyUIRuntime' -Nodes @() `
        -VerifyEnvironment $false `
        -BaseRequirementsPathTester { return $false }
    $unsafeStaticSource = Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot 'C:\Fixture\ComfyUIRuntime' -Nodes @() `
        -VerifyEnvironment $false `
        -BaseRequirementsPathTester { return $true } `
        -BaseRequirementsSourceVerifier {
            $staticSourceState.SourceCalls++
            return $false
        }.GetNewClosure() `
        -EnvironmentVerifier {
            $staticSourceState.EnvironmentCalls++
            throw 'Statik kaynak denetiminde Python calistirildi.'
        }.GetNewClosure()
    if (-not $missingStaticSource.Ready -or
        $missingRejectedSource.Ready -or
        $missingRejectedSource.ReasonCode -cne `
            'BASE_REQUIREMENTS_MISSING' -or
        $unsafeStaticSource.Ready -or
        $unsafeStaticSource.ReasonCode -cne `
            'BASE_REQUIREMENTS_SOURCE' -or
        $staticSourceState.SourceCalls -ne 1 -or
        $staticSourceState.EnvironmentCalls -ne 0) {
        throw 'ComfyUI statik requirements kaynak siniri gecersiz.'
    }
    $baseFixtureRoot = Join-Path $env:TEMP (
        'Winlama-ComfyUI-Base-' + [guid]::NewGuid().ToString('N')
    )
    $baseFixtureConfig = [pscustomobject]@{
        ComfyUI = [pscustomobject]@{
            BaseRequirements = @('torch')
            BaseRequirementsSha256 = [string]::Concat(
                '6647B8314A965C8C1C888A358AD46DCD',
                '51955FDAD5BC439A26FE0EFD6ACA8933'
            )
        }
    }
    try {
        $baseFixtureDirectory = Join-Path $baseFixtureRoot 'ComfyUI'
        [IO.Directory]::CreateDirectory($baseFixtureDirectory) | Out-Null
        $baseFixturePath = Join-Path $baseFixtureDirectory `
            'requirements.txt'
        [IO.File]::WriteAllText(
            $baseFixturePath,
            'stale-package',
            [Text.UTF8Encoding]::new($false)
        )
        $staleBaseState = Get-InstallerComfyUIRequirementsState `
            -RuntimeRoot $baseFixtureRoot -Nodes @() `
            -VerifyEnvironment $false `
            -ExpectedBaseRequirementLines @('torch')
        $repairableBaseState = Get-InstallerComfyUIRequirementsState `
            -RuntimeRoot $baseFixtureRoot -Nodes @() `
            -VerifyEnvironment $false `
            -AllowBaseRequirementsReplacement `
            -ExpectedBaseRequirementLines @('torch')
        $unsafeReplacementState = `
            Get-InstallerComfyUIRequirementsState `
                -RuntimeRoot $baseFixtureRoot -Nodes @() `
                -AllowBaseRequirementsReplacement `
                -ExpectedBaseRequirementLines @('torch') `
                -EnvironmentVerifier {
                    throw 'Stale requirements Python ile okunmamali.'
                }
        $writtenBasePath = Write-InstallerComfyUIBaseRequirements `
            -RuntimeRoot $baseFixtureRoot -Config $baseFixtureConfig
        $writtenBaseLines = @([IO.File]::ReadAllLines($writtenBasePath))
        if ($staleBaseState.Ready -or
            $staleBaseState.ReasonCode -cne `
                'BASE_REQUIREMENTS_IDENTITY' -or
            -not $repairableBaseState.Ready -or
            $unsafeReplacementState.Ready -or
            $unsafeReplacementState.ReasonCode -cne `
                'BASE_REQUIREMENTS_IDENTITY' -or
            $writtenBasePath -cne $baseFixturePath -or
            $writtenBaseLines.Count -ne 1 -or
            $writtenBaseLines[0] -cne 'torch' -or
            -not (Test-InstallerComfyUIBaseRequirementsIdentity `
                -Path $writtenBasePath -ExpectedLines @('torch'))) {
            throw 'ComfyUI stale temel requirements normalize edilmedi.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $baseFixtureRoot) {
            [IO.Directory]::Delete($baseFixtureRoot, $true)
        }
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIBaseRequirementsPinned'
    $fixtureRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        [IO.Path]::GetFullPath((Get-Location).Path)
    }
    else {
        $PSScriptRoot
    }
    $fixturePath = Join-Path $fixtureRoot 'Install.ps1'
    $surrogateOutput = ''
    $surrogateResult = Invoke-InstallerComfyUIPythonProbe `
        -Python $fixturePath -Arguments @('-V') `
        -WorkingDirectory $fixtureRoot -ProcessRunner {
            'fixture native output'
            return 0
        } -CapturedOutput ([ref]$surrogateOutput)
    if ($surrogateResult -ne 0 -or
        $surrogateResult -is [array] -or
        $surrogateOutput -cne 'fixture native output') {
        throw 'ComfyUI native probe tek cikis kodu dondurmedi.'
    }
    $nativeHost = (Get-Process -Id $PID).Path
    $nativeArgumentOutput = ''
    $nativeArgumentResult = Invoke-InstallerComfyUIPythonProbe `
        -Python $nativeHost -Arguments @(
            '-NoLogo', '-NoProfile', '-Command',
            "Write-Output 'WINLAMA_ARGUMENT_QUOTING_OK'"
        ) -WorkingDirectory $fixtureRoot `
        -CapturedOutput ([ref]$nativeArgumentOutput)
    if ($nativeArgumentResult -ne 0 -or
        $nativeArgumentOutput.Trim() -cne `
            'WINLAMA_ARGUMENT_QUOTING_OK') {
        throw 'ComfyUI Python arguman tirnaklama sozlesmesi gecersiz.'
    }
    $nativeFailureOutput = ''
    $nativeFailureResult = Invoke-InstallerComfyUIPythonProbe `
        -Python $nativeHost -Arguments @(
            '-NoLogo', '-NoProfile', '-Command',
            "Write-Output 'WINLAMA_STDOUT_OK'; " +
                "[Console]::Error.WriteLine('WINLAMA_STDERR_OK'); exit 7"
        ) -WorkingDirectory $fixtureRoot `
        -CapturedOutput ([ref]$nativeFailureOutput)
    if ($nativeFailureResult -ne 7 -or
        $nativeFailureOutput -notmatch 'WINLAMA_STDOUT_OK' -or
        $nativeFailureOutput -notmatch 'WINLAMA_STDERR_OK') {
        throw 'ComfyUI Python cikti yakalama sozlesmesi gecersiz.'
    }
    $nativeLaunchOutput = ''
    $nativeLaunchFailed = $false
    try {
        $null = Invoke-BootstrapProcess `
            -FilePath $fixturePath -ArgumentList @('-V') `
            -WorkingDirectory $fixtureRoot -CaptureOutput `
            -CapturedOutput ([ref]$nativeLaunchOutput) `
            -ProcessStarter {
                param($StartParameters)
                throw 'WINLAMA_PROCESS_START_FAILURE'
            }
    }
    catch {
        $nativeLaunchFailed = $true
    }
    if (-not $nativeLaunchFailed -or
        $nativeLaunchOutput -notmatch 'WINLAMA_PROCESS_START_FAILURE') {
        throw 'Alt surec baslatma tanilama sozlesmesi gecersiz.'
    }
    $fallbackProcessId = [pscustomobject]@{ Value = 0 }
    $fallbackOutput = ''
    $fallbackFailure = $null
    $fallbackStillRunning = $false
    try {
        $null = Invoke-BootstrapProcess `
            -FilePath $nativeHost -ArgumentList @(
                '-NoLogo', '-NoProfile', '-Command',
                'Start-Sleep -Seconds 30'
            ) -WorkingDirectory $fixtureRoot -TimeoutSeconds 1 `
            -HeartbeatIntervalSeconds 1 -CaptureOutput `
            -WindowStyle Hidden `
            -CapturedOutput ([ref]$fallbackOutput) `
            -ProcessStarter ({
                param($StartParameters)
                $created = Start-Process @StartParameters
                $fallbackProcessId.Value = $created.Id
                return $created
            }.GetNewClosure()) `
            -TreeTerminator {
                throw 'WINLAMA_PRIMARY_TERMINATION_FAILURE'
            } -HeartbeatWriter { param($Heartbeat) }
    }
    catch {
        $fallbackFailure = $_.Exception
    }
    finally {
        if ($fallbackProcessId.Value -gt 0) {
            $remaining = Get-Process -Id $fallbackProcessId.Value `
                -ErrorAction SilentlyContinue
            $fallbackStillRunning = $null -ne $remaining
            if ($fallbackStillRunning) {
                Stop-Process -Id $fallbackProcessId.Value -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
    if ($fallbackFailure -isnot [TimeoutException] -or
        $fallbackStillRunning -or
        $fallbackOutput -notmatch `
            'WINLAMA_PRIMARY_TERMINATION_FAILURE') {
        throw 'Alt surec dogrudan sonlandirma sozlesmesi gecersiz.'
    }
    $boundedProcess = [pscustomobject]@{ Id = 4242 }
    $boundedProcess | Add-Member -MemberType ScriptMethod `
        -Name WaitForExit -Value { param([int]$Milliseconds) $false }
    $boundedTerminated = [pscustomobject]@{ Value = $false }
    $boundedHeartbeats = [Collections.Generic.List[object]]::new()
    $elapsedQueue = [Collections.Generic.Queue[TimeSpan]]::new()
    $elapsedQueue.Enqueue([TimeSpan]::FromSeconds(16))
    $elapsedQueue.Enqueue([TimeSpan]::FromSeconds(121))
    $boundedRejected = $false
    try {
        $null = Invoke-BootstrapProcess `
            -FilePath $fixturePath -ArgumentList @('-V') `
            -WorkingDirectory $fixtureRoot -TimeoutSeconds 120 `
            -WindowStyle Hidden `
            -ProcessStarter ({ return $boundedProcess }.GetNewClosure()) `
            -TreeTerminator ({
                $boundedTerminated.Value = $true
            }.GetNewClosure()) `
            -ElapsedProvider ({
                return $elapsedQueue.Dequeue()
            }.GetNewClosure()) `
            -HeartbeatWriter ({
                param($Heartbeat)
                $boundedHeartbeats.Add($Heartbeat)
            }.GetNewClosure())
    }
    catch {
        $boundedRejected = $true
    }
    $terminationFailure = $null
    $terminationOutput = ''
    try {
        $null = Invoke-BootstrapProcess `
            -FilePath $fixturePath -ArgumentList @('-V') `
            -WorkingDirectory $fixtureRoot -TimeoutSeconds 120 `
            -WindowStyle Hidden -CaptureOutput `
            -CapturedOutput ([ref]$terminationOutput) `
            -ProcessStarter ({ return $boundedProcess }.GetNewClosure()) `
            -TreeTerminator { throw 'fixture termination failure' } `
            -ElapsedProvider {
                return [TimeSpan]::FromSeconds(121)
            }
    }
    catch {
        $terminationFailure = $_.Exception
    }
    $probeDefinition = (Get-Command `
        Invoke-InstallerComfyUIPythonProbe -ErrorAction Stop).Definition
    $bootstrapDefinition = (Get-Command `
        Invoke-BootstrapProcess -ErrorAction Stop).Definition
    $outputDefinition = (Get-Command `
        Add-InstallerProcessOutputTail -ErrorAction Stop).Definition
    if (-not $boundedRejected -or -not $boundedTerminated.Value -or
        $boundedHeartbeats.Count -ne 1 -or
        $boundedHeartbeats[0].ElapsedSeconds -ne 16 -or
        $null -eq $terminationFailure -or
        [string]$terminationFailure.Data['TerminationError'] -notmatch
            'fixture termination failure' -or
        $terminationOutput -notmatch 'fixture termination failure' -or
        $probeDefinition -notmatch 'Invoke-BootstrapProcess' -or
        $probeDefinition -notmatch 'CapturedOutput' -or
        $probeDefinition -match '&\s*\$Python' -or
        $bootstrapDefinition -notmatch `
            'ConvertTo-WindowsCommandLineArgument' -or
        $bootstrapDefinition -notmatch `
            'Add-InstallerProcessOutputTail' -or
        $outputDefinition -notmatch `
            'Read-InstallerProcessOutputTail' -or
        $bootstrapDefinition -notmatch '\$process\.Handle' -or
        $bootstrapDefinition -notmatch '\$process\.Kill\(\)' -or
        $bootstrapDefinition -notmatch 'FallbackTerminationError') {
        throw 'ComfyUI embedded Python bounded process sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIPythonArgumentQuoting'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIBoundedPythonProbe'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIStaticSourceSafety'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ProcessHeartbeat'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ProcessTimeoutPrimary'
    $events = [Collections.Generic.List[object]]::new()
    $safeRequirementsVerifier = {
        param([string]$Path)
        return $true
    }
    $runner = {
        param(
            [string]$Python,
            [string[]]$Arguments,
            [string]$WorkingDirectory
        )
        $null = $events.Add([pscustomobject]@{
            Python = $Python
            Arguments = @($Arguments)
            WorkingDirectory = $WorkingDirectory
        })
        return 0
    }.GetNewClosure()
    $requirements = @($fixturePath, $fixturePath)
    if (-not (Test-InstallerComfyUIPythonEnvironment `
        -Python $fixturePath -WorkingDirectory $fixtureRoot `
        -Requirements $requirements -IncludeCustomNodeImports `
        -ProcessRunner $runner `
        -RequirementsSourceVerifier $safeRequirementsVerifier) -or
        $events.Count -ne 4) {
        throw 'ComfyUI embedded Python probe plani tamamlanmadi.'
    }
    foreach ($event in @($events[0], $events[1])) {
        if ('-B' -notin $event.Arguments -or
            '--isolated' -notin $event.Arguments -or
            '--dry-run' -notin $event.Arguments -or
            '--no-index' -notin $event.Arguments -or
            '--index-url' -in $event.Arguments) {
            throw 'ComfyUI requirements exact probe agsiz degil.'
        }
    }
    foreach ($event in $events) {
        if ('-X' -notin $event.Arguments -or
            'utf8' -notin $event.Arguments) {
            throw 'ComfyUI Python UTF-8 cikti sozlesmesi gecersiz.'
        }
    }
    if ('--isolated' -notin $events[2].Arguments -or
        'check' -notin $events[2].Arguments -or
        '-c' -notin $events[3].Arguments -or
        [string]$events[3].Arguments[-1] -notmatch 'google\.protobuf' -or
        [string]$events[3].Arguments[-1] -notmatch 'imageio_ffmpeg' -or
        [string]$events[3].Arguments[-1] -notmatch `
            'WINLAMA_IMPORT_START' -or
        [string]$events[3].Arguments[-1] -notmatch `
            'WINLAMA_IMPORT_OK' -or
        [string]$events[3].Arguments[-1] -notmatch
            'sys\.path\.insert\(0,os\.getcwd\(\)\)') {
        throw 'ComfyUI pip check veya import smoke probe eksik.'
    }
    $failureState = [pscustomobject]@{ Calls = 0 }
    $failingRunner = {
        param(
            [string]$Python,
            [string[]]$Arguments,
            [string]$WorkingDirectory
        )
        $failureState.Calls++
        if ('check' -in $Arguments) {
            return 1
        }
        return 0
    }.GetNewClosure()
    $pipFailure = Get-InstallerComfyUIPythonEnvironmentState `
        -Python $fixturePath -WorkingDirectory $fixtureRoot `
        -BaseRequirements @($requirements[0]) `
        -NodeRequirements @($requirements[1]) `
        -IncludeCustomNodeImports -ProcessRunner $failingRunner `
        -RequirementsSourceVerifier $safeRequirementsVerifier
    if ($pipFailure.Ready -or
        $pipFailure.ReasonCode -cne 'PIP_CHECK' -or
        $failureState.Calls -ne 3) {
        throw 'ComfyUI bozuk pip ortami reddedilmedi.'
    }
    $nodeFixturePath = Join-Path $fixtureRoot 'String\tr.ini'
    $baseFailure = Get-InstallerComfyUIPythonEnvironmentState `
        -Python $fixturePath -WorkingDirectory $fixtureRoot `
        -BaseRequirements @($fixturePath) `
        -NodeRequirements @($nodeFixturePath) `
        -RequirementsSourceVerifier $safeRequirementsVerifier `
        -ProcessRunner {
            param($Python, $Arguments, $WorkingDirectory)
            if ('--requirement' -in $Arguments -and
                [string]$Arguments[-1] -ceq $fixturePath) {
                return 4
            }
            return 0
        }.GetNewClosure()
    $nodeFailure = Get-InstallerComfyUIPythonEnvironmentState `
        -Python $fixturePath -WorkingDirectory $fixtureRoot `
        -BaseRequirements @($fixturePath) `
        -NodeRequirements @($nodeFixturePath) `
        -RequirementsSourceVerifier $safeRequirementsVerifier `
        -ProcessRunner {
            param($Python, $Arguments, $WorkingDirectory)
            if ('--requirement' -in $Arguments -and
                [string]$Arguments[-1] -ceq $nodeFixturePath) {
                return 5
            }
            return 0
        }.GetNewClosure()
    $importFailure = Get-InstallerComfyUIPythonEnvironmentState `
        -Python $fixturePath -WorkingDirectory $fixtureRoot `
        -BaseRequirements @($fixturePath) `
        -NodeRequirements @($nodeFixturePath) `
        -RequirementsSourceVerifier $safeRequirementsVerifier `
        -ProcessRunner {
            param($Python, $Arguments, $WorkingDirectory)
            if ('-c' -in $Arguments) {
                'WINLAMA_IMPORT_START:torch'
                'Traceback: fixture import failure'
                return 6
            }
            return 0
        }
    if ($baseFailure.ReasonCode -cne
            'BASE_REQUIREMENTS_DRY_RUN' -or
        $nodeFailure.ReasonCode -cne
            'NODE_REQUIREMENTS_DRY_RUN' -or
        $importFailure.ReasonCode -cne 'IMPORT_PROBE' -or
        $importFailure.Detail -notmatch 'torch' -or
        $importFailure.Detail -notmatch '6') {
        throw 'ComfyUI Python reason-code sozlesmesi gecersiz.'
    }
    $emptyDiagnostic = Get-InstallerComfyUIProbeDiagnosticText `
        -Output ''
    $controlDiagnostic = Get-InstallerComfyUIProbeDiagnosticText `
        -Output ([string][char]0)
    $lineDiagnostic = Get-InstallerComfyUIProbeDiagnosticText `
        -Output ("bir`riki" + [char]0x2028 + 'uc')
    $boundedDiagnostic = Get-InstallerComfyUIProbeDiagnosticText `
        -Output ('A' * 512) -MaximumLength 128
    $completedImportDetail = Get-InstallerComfyUIImportFailureDetail `
        -ExitCode 9 -Output (
            "WINLAMA_IMPORT_START:torch`r`n" +
            "WINLAMA_IMPORT_OK:torch`r`nfixture failure"
        )
    $genericImportDetail = Get-LocalizedText `
        -Key 'Installer.ComfyUI.EnvironmentProbe.FailureDetail' `
        -Arguments @(9)
    if ($emptyDiagnostic -cne (Get-LocalizedText `
            -Key 'Installer.ComfyUI.EnvironmentProbe.NoOutput') -or
        $controlDiagnostic -cne $emptyDiagnostic -or
        $lineDiagnostic -cne 'bir | iki | uc' -or
        $boundedDiagnostic -notmatch 'son 128 karakteri' -or
        -not $boundedDiagnostic.EndsWith('A' * 128) -or
        $completedImportDetail -cne $genericImportDetail) {
        throw 'ComfyUI Python tanilama siniri gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIProbeDiagnostics'
    $directState = New-InstallerComfyUIDiagnosticResult `
        -Ready $true -ReasonCode 'READY'
    $directFallback = `
        Get-InstallerComfyUIRequirementsFallbackState `
            -Result $directState -NodeCount 2 `
            -NodeTreesReady $true `
            -NodeDependenciesReady $false `
            -WheelhouseReady $false
    $nodeState = New-InstallerComfyUIDiagnosticResult `
        -Ready $false `
        -ReasonCode 'NODE_REQUIREMENTS_DRY_RUN' `
        -Detail 'FixtureNode'
    $missingFallback = `
        Get-InstallerComfyUIRequirementsFallbackState `
            -Result $nodeState -NodeCount 2 `
            -NodeTreesReady $true `
            -NodeDependenciesReady $false `
            -WheelhouseReady $false
    $readyFallback = Get-InstallerComfyUIRequirementsFallbackState `
        -Result $nodeState -NodeCount 2 `
        -NodeTreesReady $true `
        -NodeDependenciesReady $false `
        -WheelhouseReady $true
    $satisfiedFallback = `
        Get-InstallerComfyUIRequirementsFallbackState `
            -Result $nodeState -NodeCount 2 `
            -NodeTreesReady $true `
            -NodeDependenciesReady $true `
            -WheelhouseReady $false
    $baseFallback = Get-InstallerComfyUIRequirementsFallbackState `
        -Result $baseFailure -NodeCount 2 `
        -NodeTreesReady $true `
        -NodeDependenciesReady $false `
        -WheelhouseReady $true
    if (-not $directFallback.Ready -or
        $directFallback.RequiresWheelhouse -or
        $missingFallback.Ready -or
        -not $missingFallback.RequiresWheelhouse -or
        -not $readyFallback.Ready -or
        -not $satisfiedFallback.Ready -or
        $satisfiedFallback.RequiresWheelhouse -or
        $baseFallback.RequiresWheelhouse) {
        throw 'ComfyUI direct-runtime fallback sozlesmesi gecersiz.'
    }
    $environmentState = [pscustomobject]@{ Calls = 0 }
    $environmentVerifier = {
        param([string]$RuntimeRoot, [object[]]$Nodes)
        $environmentState.Calls++
        return $true
    }.GetNewClosure()
    $quickEnvironmentState = Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot $fixtureRoot -Nodes @() `
        -VerifyIdentity $false `
        -BaseRequirementLines @('torch') `
        -BaseRequirementsPathTester { return $false } `
        -EnvironmentVerifier $environmentVerifier
    if (-not $quickEnvironmentState.Ready -or
        $environmentState.Calls -ne 0) {
        throw 'ComfyUI hizli probe embedded Python baslatti.'
    }
    $exactEnvironmentState = Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot $fixtureRoot -Nodes @() `
        -BaseRequirementLines @('torch') `
        -BaseRequirementsPathTester { return $false } `
        -EnvironmentVerifier $environmentVerifier
    if (-not $exactEnvironmentState.Ready -or
        $environmentState.Calls -ne 1) {
        throw 'ComfyUI exact probe embedded Python calistirmadi.'
    }
    $nodeHash = 'A' * 64
    $nodeDescriptors = @(
        [pscustomobject]@{
            Name = 'FixtureNodeA'
            Commit = 'fixture-a'
            TreeSha256 = 'B' * 64
        },
        [pscustomobject]@{
            Name = 'FixtureNodeB'
            Commit = 'fixture-b'
            TreeSha256 = 'C' * 64
        }
    )
    $validNodeState = [pscustomobject]@{
        FixtureNodeA = [pscustomobject]@{
            Commit = 'fixture-a'
            TreeSha256 = 'B' * 64
            RequirementsSha256 = $nodeHash
        }
        FixtureNodeB = [pscustomobject]@{
            Commit = 'fixture-b'
            TreeSha256 = 'C' * 64
            RequirementsSha256 = $nodeHash
        }
    }
    $baseRequirementsFixture = @{
        BaseRequirementLines = @('torch')
        BaseRequirementsPathTester = { return $false }
    }
    $stateFailure = Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot 'C:\Fixture\Runtime\ComfyUI' `
        -Nodes @($nodeDescriptors[0]) `
        @baseRequirementsFixture `
        -StateReader { [pscustomobject]@{} }
    $treeFailure = Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot 'C:\Fixture\Runtime\ComfyUI' `
        -Nodes @($nodeDescriptors[0]) `
        @baseRequirementsFixture `
        -StateReader { $validNodeState }.GetNewClosure() `
        -NodeTreeVerifier { $false }
    $hashFailure = Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot 'C:\Fixture\Runtime\ComfyUI' `
        -Nodes @($nodeDescriptors[0]) `
        @baseRequirementsFixture `
        -StateReader { $validNodeState }.GetNewClosure() `
        -NodeTreeVerifier { $true } `
        -RequirementsHashReader { 'D' * 64 }
    $readyNodeState = Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot 'C:\Fixture\Runtime\ComfyUI' `
        -Nodes $nodeDescriptors `
        @baseRequirementsFixture `
        -StateReader { $validNodeState }.GetNewClosure() `
        -NodeTreeVerifier { $true } `
        -RequirementsHashReader { $nodeHash }.GetNewClosure() `
        -EnvironmentVerifier {
            New-InstallerComfyUIDiagnosticResult `
                -Ready $true -ReasonCode 'READY'
        }
    $staticNodeState = Get-InstallerComfyUIRequirementsState `
        -RuntimeRoot 'C:\Fixture\Runtime\ComfyUI' `
        -Nodes $nodeDescriptors -VerifyEnvironment $false `
        @baseRequirementsFixture `
        -StateReader { $validNodeState }.GetNewClosure() `
        -NodeTreeVerifier { $true } `
        -RequirementsHashReader { $nodeHash }.GetNewClosure() `
        -EnvironmentVerifier {
            throw 'Paket Runtime embedded Python probe baslatti.'
        }
    if ($stateFailure.ReasonCode -cne 'NODE_STATE' -or
        $treeFailure.ReasonCode -cne 'NODE_TREE' -or
        $hashFailure.ReasonCode -cne 'NODE_REQUIREMENTS_HASH' -or
        -not $readyNodeState.Ready -or -not $staticNodeState.Ready) {
        throw 'ComfyUI node reason-code sozlesmesi gecersiz.'
    }
    $unready = [pscustomobject]@{
        RuntimeInstalled = $false
        LocalRuntimePath = $null
        MissingRequirements = @('fixture')
        AnyLocal = $true
        LocalReady = $false
    }
    $availabilityState = [pscustomobject]@{ Calls = 0 }
    $availabilityVerifier = {
        param($Models, $Config, $ProjectRoot)
        $availabilityState.Calls++
        return $unready
    }.GetNewClosure()
    $model = [pscustomobject]@{ Name = 'Fixture' }
    $fixtureConfig = [pscustomobject]@{}
    $online = Read-InstallerComfyUISource -Models @($model) `
        -Config $fixtureConfig -ProjectRoot $fixtureRoot `
        -Selection Online -IdentityVerifier $availabilityVerifier `
        -EnvironmentVerifier { throw 'Online yerel probe calistirdi.' }
    $quickAutomatic = Read-InstallerComfyUISource `
        -Models @($model) -Config $fixtureConfig `
        -ProjectRoot $fixtureRoot -Selection Automatic `
        -VerifyLocalIdentity $false `
        -IdentityVerifier $availabilityVerifier `
        -EnvironmentVerifier {
            throw 'Hizli Automatic embedded Python baslatti.'
        }
    $exactAutomatic = Read-InstallerComfyUISource `
        -Models @($model) -Config $fixtureConfig `
        -ProjectRoot $fixtureRoot -Selection Automatic `
        -IdentityVerifier $availabilityVerifier
    $localError = $null
    try {
        $null = Read-InstallerComfyUISource -Models @($model) `
            -Config $fixtureConfig -ProjectRoot $fixtureRoot `
            -Selection Local -IdentityVerifier $availabilityVerifier
    }
    catch {
        $localError = $_.Exception
    }
    if ($online -cne 'Online' -or
        $quickAutomatic -cne 'Automatic' -or
        $exactAutomatic -cne 'Online' -or
        $null -eq $localError -or
        $localError.Data['Winlama.Retryable'] -ne $false -or
        $availabilityState.Calls -ne 2) {
        throw 'ComfyUI Local Automatic Online probe siniri gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIDirectRuntimeContract'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIReasonCodes'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIPythonEnvironment'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIRequirementSources'
}
function Assert-InstallerComfyUISourceProbeBoundaryContracts {
    $packageRuntime = 'C:\Fixture\Package\Runtime\ComfyUI'
    foreach ($runtimeRoot in @(
        'C:\Fixture\Installed\ComfyUI',
        'C:\Fixture\Temp\ComfyUI',
        'C:\Fixture\Package2\Runtime\ComfyUI'
    )) {
        if (-not (Test-InstallerComfyUIRuntimeEnvironmentProbeRequired `
            -RuntimeRoot $runtimeRoot `
            -PackageRuntimeRoot $packageRuntime)) {
            throw "ComfyUI ortam probe atlandi: $runtimeRoot"
        }
    }
    if (Test-InstallerComfyUIRuntimeEnvironmentProbeRequired `
        -RuntimeRoot $packageRuntime `
        -PackageRuntimeRoot $packageRuntime) {
        throw 'Paket Runtime ortam probe siniri gecersiz.'
    }
    $definition = (Get-Command Install-InstallerComfyUIRuntime `
        -ErrorAction Stop).Definition
    $availabilityDefinition = (Get-Command `
        Get-InstallerComfyUISourceAvailability `
        -ErrorAction Stop).Definition
    $readSourceDefinition = (Get-Command Read-InstallerComfyUISource `
        -ErrorAction Stop).Definition
    $quickSafetyDefinition = (Get-Command `
        Test-InstallerComfyUIRuntimeQuickReparseSafety `
        -ErrorAction Stop).Definition
    $installerSource = [IO.File]::ReadAllText($PSCommandPath)
    foreach ($token in @(
        'Test-InstallerComfyUIRuntimeEnvironmentProbeRequired',
        '-VerifyEnvironment $candidateVerifyEnvironment',
        '$requirementsCandidateVerifyEnvironment'
    )) {
        if (-not $availabilityDefinition.Contains($token)) {
            throw "ComfyUI kaynak probe siniri eksik: $token"
        }
    }
    $quickReturnIndex = $availabilityDefinition.IndexOf(
        'if (-not $VerifyIdentity)',
        [StringComparison]::Ordinal
    )
    $runtimeCandidatesIndex = $availabilityDefinition.IndexOf(
        '$runtimeCandidates =',
        [StringComparison]::Ordinal
    )
    if ($quickReturnIndex -lt 0 -or
        $runtimeCandidatesIndex -le $quickReturnIndex) {
        throw 'ComfyUI soru oncesi probe siniri gecersiz.'
    }
    if ($availabilityDefinition -notmatch `
            '\$QuickProbe[\s\S]*-TreeReparseVerifier' -or
        $availabilityDefinition -notmatch `
            'Test-InstallerComfyUIRuntimeQuickReparseSafety' -or
        $readSourceDefinition -notmatch `
            '\$QuickProbe[\s\S]*QuickProbe = \$QuickProbe' -or
        $quickSafetyDefinition -notmatch `
            'Test-InstallerComfyUIReparseChain' -or
        [regex]::Matches(
            $quickSafetyDefinition,
            "'[^']+'"
        ).Count -lt 4 -or
        [regex]::Matches(
            $installerSource,
            '(?s)-QuickProbe:\(\s*' +
                'Test-InstallerComfyUIQuickProbeRequested' +
                '.{0,240}-Selection\s+\$ComfyUISourceSelection'
        ).Count -ne 1 -or
        -not (Test-InstallerComfyUIQuickProbeRequested `
            -Selection Prompt -VerifyLocalIdentity $false) -or
        (Test-InstallerComfyUIQuickProbeRequested `
            -Selection Prompt -VerifyLocalIdentity $true) -or
        @('Local', 'Online', 'Automatic').Where({
            Test-InstallerComfyUIQuickProbeRequested `
                -Selection $_ -VerifyLocalIdentity $false
        }).Count -ne 0) {
        throw 'ComfyUI soru oncesi hizli probe sozlesmesi gecersiz.'
    }
    $catalogDefinition = (Get-Command Get-InstallerComfyUICatalog `
        -ErrorAction Stop).Definition
    $coreIdentityDefinition = (Get-Command `
        Get-InstallerComfyUICoreIdentity -ErrorAction Stop).Definition
    $localIdentityDefinition = (Get-Command `
        Get-InstallerComfyUILocalRuntimeIdentity `
        -ErrorAction Stop).Definition
    $treeReaderDefinition = (Get-Command `
        Get-InstallerReparseSafeTreeFiles `
        -ErrorAction Stop).Definition
    if ($catalogDefinition -match 'Get-ChildItem|LocalOnly' -or
        -not $coreIdentityDefinition.Contains(
            'Get-InstallerReparseSafeTreeFiles'
        ) -or -not $localIdentityDefinition.Contains(
            'Get-InstallerReparseSafeTreeFiles'
        ) -or -not $coreIdentityDefinition.Contains(
            '-ProgressPhase $phase'
        ) -or -not $localIdentityDefinition.Contains(
            '-ProgressPhase $phase'
        ) -or -not $coreIdentityDefinition.Contains(
            '-ExcludedDirectoryNames'
        ) -or -not $localIdentityDefinition.Contains(
            '-ExcludedRelativeDirectories'
        ) -or -not $localIdentityDefinition.Contains(
            "'ComfyUI\output'"
        ) -or -not $localIdentityDefinition.Contains(
            '-ExcludedDirectoryNames'
        ) -or -not $treeReaderDefinition.Contains(
            'Installer.ComfyUI.TreeScan.Progress'
        ) -or -not $treeReaderDefinition.Contains(
            '$ProgressIntervalSeconds'
        ) -or -not $treeReaderDefinition.Contains(
            '$excludedNames.Contains($item.Name)'
        )) {
        throw 'ComfyUI canonical ve reparse kaynak siniri gecersiz.'
    }
    if ($definition -notmatch
        '(?s)-RuntimeRoot\s+\$localSource.{0,300}-Nodes\s+' +
            '\$requiredNodes.{0,300}-VerifyEnvironment\s+\$false') {
        throw 'Paket Runtime statik probe plani eksik.'
    }
    $argumentsIndex = $definition.IndexOf(
        '$arguments = @(',
        [StringComparison]::Ordinal
    )
    $copyIndex = $definition.IndexOf(
        '$robocopyExitCode = Invoke-BootstrapProcess',
        [StringComparison]::Ordinal
    )
    $nodeStateIndex = $definition.IndexOf(
        '$sourceNodeState =',
        [StringComparison]::Ordinal
    )
    $mutableIndex = $definition.IndexOf(
        '$mutableArguments = @(',
        [StringComparison]::Ordinal
    )
    $stageProbeIndex = $definition.IndexOf(
        '-RuntimeRoot $stage -Nodes $stageNodes',
        [StringComparison]::Ordinal
    )
    $requirementsWriteIndex = $definition.IndexOf(
        'Write-InstallerComfyUIBaseRequirements',
        [StringComparison]::Ordinal
    )
    $stageIdentityIndex = $definition.IndexOf(
        'Test-InstallerComfyUILocalRuntimeIdentity',
        $copyIndex,
        [StringComparison]::Ordinal
    )
    $launcherPatchIndex = $definition.IndexOf(
        'Enable-InstallerComfyUILauncherArguments -Path $stage',
        [StringComparison]::Ordinal
    )
    $moveIndex = $definition.IndexOf(
        'Move-Item -LiteralPath $stage',
        [StringComparison]::Ordinal
    )
    if ($argumentsIndex -lt 0 -or $copyIndex -le $argumentsIndex -or
        $nodeStateIndex -le $copyIndex -or
        $mutableIndex -le $nodeStateIndex -or
        $stageIdentityIndex -le $copyIndex -or
        $requirementsWriteIndex -le $stageIdentityIndex -or
        $launcherPatchIndex -le $requirementsWriteIndex -or
        $stageProbeIndex -le $mutableIndex -or
        $moveIndex -le $stageProbeIndex) {
        throw 'ComfyUI local stage probe sirasi gecersiz.'
    }
    if (-not $definition.Contains(
            '$extractExitCode = Invoke-BootstrapProcess'
        ) -or -not $definition.Contains(
            '$mutableExitCode = Invoke-BootstrapProcess'
        ) -or $definition.Contains('& robocopy.exe') -or
        $definition.Contains('& $tar.Source')) {
        throw 'ComfyUI yerel surec siniri gecersiz.'
    }
    $primaryCopyBlock = $definition.Substring(
        $argumentsIndex,
        $copyIndex - $argumentsIndex
    )
    $mutableCopyBlock = $definition.Substring(
        $mutableIndex,
        $stageProbeIndex - $mutableIndex
    )
    foreach ($token in @(
        "'__pycache__'", "'*.pyc'", "'*.pyo'"
    )) {
        if (-not $primaryCopyBlock.Contains($token) -or
            -not $mutableCopyBlock.Contains($token)) {
            throw "ComfyUI robocopy filtresi eksik: $token"
        }
    }
    if (-not $primaryCopyBlock.Contains(
        '(Join-Path $source ''ComfyUI\extra_model_paths.yaml'')'
    )) {
        throw 'ComfyUI paket dynamic YAML filtresi eksik.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUISourceProbeBoundary'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUITreeScanProgress'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIPreQuestionNoProcess'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUILocalReparseGuard'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIStageProbePlan'
}
function Assert-InstallerComfyUIPostPreparationContracts {
    $fixtureRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        [IO.Path]::GetFullPath((Get-Location).Path)
    }
    else {
        $PSScriptRoot
    }
    $fixtureConfig = [pscustomobject]@{
        ComfyUI = [pscustomobject]@{
            InstallPath = $fixtureRoot
            Requested = @('FixtureModel')
            CustomNodes = @(
                [pscustomobject]@{
                    Name = 'FixtureNode'
                    RequiredBy = 'FixtureModel'
                },
                [pscustomobject]@{
                    Name = 'UnselectedNode'
                    RequiredBy = 'OtherModel'
                }
            )
        }
    }
    $runtimeState = [pscustomobject]@{ Calls = 0 }
    $runtimeVerifier = {
        param([string]$Path, [pscustomobject]$Config)
        $runtimeState.Calls++
        return $true
    }.GetNewClosure()
    $requirementsState = [pscustomobject]@{
        Calls = 0
        Ready = $false
    }
    $requirementsVerifier = {
        param([string]$RuntimeRoot, [object[]]$Nodes)
        $requirementsState.Calls++
        if ($Nodes.Count -ne 1 -or
            [string]$Nodes[0].Name -cne 'FixtureNode') {
            throw 'ComfyUI post probe node secimi gecersiz.'
        }
        return $requirementsState.Ready
    }.GetNewClosure()
    $failedChild = Test-InstallerComfyUIPreparationResult `
        -Config $fixtureConfig -ChildExitCode 7 `
        -RuntimeVerifier { throw 'Basarisiz child runtime probe acti.' } `
        -RequirementsVerifier {
            throw 'Basarisiz child requirements probe acti.'
        }
    $failedEnvironment = Test-InstallerComfyUIPreparationResult `
        -Config $fixtureConfig -ChildExitCode 0 `
        -RuntimeVerifier $runtimeVerifier `
        -RequirementsVerifier $requirementsVerifier
    $requirementsState.Ready = $true
    $readyEnvironment = Test-InstallerComfyUIPreparationResult `
        -Config $fixtureConfig -ChildExitCode 0 `
        -RuntimeVerifier $runtimeVerifier `
        -RequirementsVerifier $requirementsVerifier
    $prepareSource = (Get-Command Prepare-InstallerComfyUIRuntime `
        -ErrorAction Stop).Definition
    $installerSource = [IO.File]::ReadAllText($PSCommandPath)
    if ($failedChild -or $failedEnvironment -or
        -not $readyEnvironment -or $runtimeState.Calls -ne 2 -or
        $requirementsState.Calls -ne 2 -or
        $prepareSource -notmatch
            'Get-InstallerComfyUIPreparationState' -or
        $prepareSource -notmatch 'Invoke-InstallerSameConsoleProcess' -or
        $prepareSource -match '&\s*\$powershell\s+@arguments' -or
        $prepareSource -match '2>&1|Out-Host' -or
        $installerSource -notmatch
            '\$comfyPreparationResult\s+-isnot\s+\[bool\]' -or
        $installerSource -notmatch
            '-not\s+\[bool\]\$comfyPreparationResult') {
        throw 'ComfyUI child sonrasi exact dogrulama sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ComfyUIPostPreparation'
}
function Get-InstallerDeploymentLogSnapshot {
    param([Parameter(Mandatory)][string]$LogsPath)
    $snapshot = @{}
    if (-not (Test-Path -LiteralPath $LogsPath -PathType Container)) {
        return $snapshot
    }
    foreach ($file in Get-ChildItem -LiteralPath $LogsPath `
        -File -Filter '*.log' -ErrorAction SilentlyContinue) {
        $snapshot[$file.FullName] = [long]$file.Length
    }
    return $snapshot
}
function Get-InstallerOptionalDegradationEventCode {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    try {
        $entry = $Line | ConvertFrom-InstallerJson
        $recovery = [string](Get-InstallerLogPropertyValue `
            -InputObject $entry `
            -Names @('recoveryCode', 'RecoveryCode'))
        if ($recovery -cne 'OPTIONAL_COMPONENT_DEGRADED') {
            return $null
        }
        $eventCode = [string](Get-InstallerLogPropertyValue `
            -InputObject $entry `
            -Names @('eventCode', 'EventCode'))
        if ([string]::IsNullOrWhiteSpace($eventCode)) {
            return $recovery
        }
        return $eventCode
    }
    catch {
        return $null
    }
}
function Get-InstallerOptionalDegradationEvents {
    param(
        [Parameter(Mandatory)][string]$LogsPath,
        [Parameter(Mandatory)][hashtable]$Snapshot
    )
    $events = [Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $LogsPath -PathType Container)) {
        return @()
    }
    foreach ($file in Get-ChildItem -LiteralPath $LogsPath `
        -File -Filter '*.log' -ErrorAction SilentlyContinue) {
        $offset = 0L
        if ($Snapshot.ContainsKey($file.FullName)) {
            $offset = [long]$Snapshot[$file.FullName]
        }
        if ($offset -lt 0 -or $offset -gt $file.Length) {
            $offset = 0L
        }
        if ($offset -eq $file.Length) {
            continue
        }
        $stream = [IO.File]::Open(
            $file.FullName,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        )
        try {
            $null = $stream.Seek($offset, [IO.SeekOrigin]::Begin)
            $reader = [IO.StreamReader]::new(
                $stream,
                [Text.UTF8Encoding]::new($false),
                $true,
                4096,
                $true
            )
            try {
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if ([string]::IsNullOrWhiteSpace($line)) {
                        continue
                    }
                    $eventCode = `
                        Get-InstallerOptionalDegradationEventCode `
                            -Line $line
                    if ([string]::IsNullOrWhiteSpace($eventCode)) {
                        continue
                    }
                    $events.Add($eventCode)
                }
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    return @($events | Sort-Object -Unique)
}
function Test-InstallerConfigurationComponentEnabled {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$Name
    )
    $section = $Config.PSObject.Properties[$Name]
    if ($null -eq $section) {
        return $false
    }
    $enabled = $section.Value.PSObject.Properties['Enabled']
    return $null -ne $enabled -and [bool]$enabled.Value
}
function Get-InstallerConfigurationRequestedValues {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$SectionName
    )
    $section = $Config.PSObject.Properties[$SectionName]
    if ($null -eq $section) {
        return @()
    }
    $requested = $section.Value.PSObject.Properties['Requested']
    if ($null -eq $requested) {
        return @()
    }
    return @($requested.Value | ForEach-Object { [string]$_ })
}
function Get-InstallerHealthyEndpointComponents {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
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
            return $false
        }
    )
    $context = [pscustomobject]@{ Config = $Config }
    $healthy = [Collections.Generic.List[string]]::new()
    foreach ($name in @(
        'Ollama', 'OpenWebUI', 'Voice', 'ComfyUI'
    )) {
        if (-not (Test-InstallerConfigurationComponentEnabled `
            -Config $Config -Name $name)) {
            continue
        }
        try {
            if ([bool](& $ProbeInvoker $name $context)) {
                $healthy.Add($name)
            }
        }
        catch {
            Write-Verbose ('Kurulum sonu saglik denetimi basarisiz: ' +
                "${name}: $($_.Exception.Message)")
        }
    }
    return $healthy.ToArray()
}
function Get-InstallerCompletionAssessment {
    param(
        [Parameter(Mandatory)][pscustomobject]$BeforeConfig,
        [Parameter(Mandatory)][pscustomobject]$AfterConfig,
        [AllowEmptyCollection()][string[]]$HealthyComponents = @(),
        [AllowEmptyCollection()][string[]]$OptionalEvents = @()
    )
    $details = [Collections.Generic.List[string]]::new()
    foreach ($name in @(
        'Ollama', 'OpenWebUI', 'Voice', 'ComfyUI'
    )) {
        $wasEnabled = Test-InstallerConfigurationComponentEnabled `
            -Config $BeforeConfig -Name $name
        $isEnabled = Test-InstallerConfigurationComponentEnabled `
            -Config $AfterConfig -Name $name
        if ($wasEnabled -and -not $isEnabled) {
            $details.Add((Get-LocalizedText `
                -Key 'Installer.Completion.ComponentDisabled' `
                -Arguments @($name)))
            continue
        }
        if ($isEnabled -and $name -notin $HealthyComponents) {
            $details.Add((Get-LocalizedText `
                -Key 'Installer.Completion.ComponentUnhealthy' `
                -Arguments @($name)))
        }
    }
    foreach ($sectionName in @('Models', 'ComfyUI')) {
        $beforeRequested = @(Get-InstallerConfigurationRequestedValues `
            -Config $BeforeConfig -SectionName $sectionName)
        $afterRequested = @(Get-InstallerConfigurationRequestedValues `
            -Config $AfterConfig -SectionName $sectionName)
        foreach ($name in $beforeRequested) {
            if ($name -notin $afterRequested) {
                $details.Add((Get-LocalizedText `
                    -Key 'Installer.Completion.RequestedMissing' `
                    -Arguments @($sectionName, $name)))
            }
        }
    }
    foreach ($eventCode in $OptionalEvents) {
        if (-not [string]::IsNullOrWhiteSpace($eventCode)) {
            $details.Add((Get-LocalizedText `
                -Key 'Installer.Completion.OptionalEvent' `
                -Arguments @($eventCode)))
        }
    }
    $uniqueDetails = @($details | Sort-Object -Unique)
    $hasWarnings = $uniqueDetails.Count -gt 0
    return [pscustomobject][ordered]@{
        HasWarnings = $hasWarnings
        Level = if ($hasWarnings) { 'WARN' } else { 'INFO' }
        UiLevel = if ($hasWarnings) { 'WARN' } else { 'SUCCESS' }
        MessageKey = if ($hasWarnings) {
            'Installer.CompletedWithWarnings'
        }
        else {
            'Installer.Completed'
        }
        ExitCode = if ($hasWarnings) { 3 } else { 0 }
        Details = $uniqueDetails
        HealthyComponents = @($HealthyComponents)
    }
}
function Assert-InstallerCompletionContracts {
    $before = [pscustomobject]@{
        Ollama = [pscustomobject]@{ Enabled = $false }
        OpenWebUI = [pscustomobject]@{ Enabled = $false }
        Voice = [pscustomobject]@{ Enabled = $true }
        ComfyUI = [pscustomobject]@{
            Enabled = $true
            Requested = @('FixtureModel')
        }
        Models = [pscustomobject]@{ Requested = @() }
    }
    $after = $before | ConvertTo-Json -Depth 10 |
        ConvertFrom-InstallerJson
    $after.Voice.Enabled = $false
    $after.ComfyUI.Enabled = $false
    $after.ComfyUI.Requested = @()
    $probeCalls = [pscustomobject]@{ Count = 0 }
    $healthy = @(Get-InstallerHealthyEndpointComponents `
        -Config $after -ProbeInvoker {
            $probeCalls.Count++
            throw 'Devre disi endpoint probe edildi.'
        }.GetNewClosure())
    $assessment = Get-InstallerCompletionAssessment `
        -BeforeConfig $before -AfterConfig $after `
        -HealthyComponents $healthy `
        -OptionalEvents @('Runtime.Component.Failed')
    $optionalEvent = Get-InstallerOptionalDegradationEventCode `
        -Line (([pscustomobject][ordered]@{
            eventCode = 'Runtime.Component.Failed'
            recoveryCode = 'OPTIONAL_COMPONENT_DEGRADED'
        }) | ConvertTo-Json -Compress)
    $cleanAssessment = Get-InstallerCompletionAssessment `
        -BeforeConfig $after -AfterConfig $after `
        -HealthyComponents @() -OptionalEvents @()
    if (-not $assessment.HasWarnings -or
        [string]$assessment.Level -cne 'WARN' -or
        [string]$assessment.UiLevel -cne 'WARN' -or
        [string]$assessment.MessageKey -cne
            'Installer.CompletedWithWarnings' -or
        [int]$assessment.ExitCode -ne 3 -or
        @($assessment.HealthyComponents).Count -ne 0 -or
        $probeCalls.Count -ne 0 -or
        $optionalEvent -cne 'Runtime.Component.Failed' -or
        [string]$assessment.MessageKey -ceq 'Installer.Completed' -or
        $cleanAssessment.HasWarnings -or
        [string]$cleanAssessment.Level -cne 'INFO' -or
        [string]$cleanAssessment.UiLevel -cne 'SUCCESS' -or
        [string]$cleanAssessment.MessageKey -cne
            'Installer.Completed' -or
        [int]$cleanAssessment.ExitCode -ne 0) {
        throw 'Kurulum warning completion sozlesmesi gecersiz.'
    }
    $installerSource = [IO.File]::ReadAllText($PSCommandPath)
    $postEngineStart = [regex]::Match(
        $installerSource,
        '(?s)\$startupArguments\s*=\s*@\(.*?&\s*\$pwsh\s+' +
            '@startupArguments'
    ).Value
    if ([string]::IsNullOrWhiteSpace($postEngineStart) -or
        $postEngineStart -match "'Restart'" -or
        $postEngineStart -notmatch
            "'-OllamaMode',\s*'Keep'" -or
        $postEngineStart -notmatch
            "'-OpenWebUIMode',\s*'Keep'" -or
        $postEngineStart -notmatch
            "'-VoiceMode',\s*'Keep'" -or
        $postEngineStart -notmatch
            "'-ComfyUIMode',\s*'Keep'" -or
        $postEngineStart -notmatch "'-NoSupervise'") {
        throw 'Engine sonrasi tek runtime baslatma sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.CompletedWithWarnings'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.SingleRuntimeStartup'
}
function Get-InstallerDescriptorOfflinePath {
    param([Parameter(Mandatory)][pscustomobject]$Descriptor)
    $offlineProperty = $Descriptor.PSObject.Properties['OfflinePath']
    if ($null -eq $offlineProperty -or
        [string]::IsNullOrWhiteSpace([string]$offlineProperty.Value)) {
        return $null
    }
    return Resolve-InstallerContainedPackagePath `
        -Root $script:InstallerPackageRoot `
        -RelativePath ([string]$offlineProperty.Value)
}
function Test-InstallerDescriptorLocalArtifact {
    param(
        [Parameter(Mandatory)][pscustomobject]$Descriptor,
        [bool]$VerifyHash = $true,
        [scriptblock]$ArtifactVerifier
    )
    $path = Get-InstallerDescriptorOfflinePath -Descriptor $Descriptor
    if ([string]::IsNullOrWhiteSpace($path) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $false
    }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.Length -lt 1 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
    }
    $offlineHashProperty = $Descriptor.PSObject.Properties[
        'OfflineSha256'
    ]
    $hashProperty = $Descriptor.PSObject.Properties['Sha256']
    $expectedHash = if ($null -ne $offlineHashProperty -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$offlineHashProperty.Value
        )) {
        [string]$offlineHashProperty.Value
    }
    elseif ($null -ne $hashProperty) {
        [string]$hashProperty.Value
    }
    else {
        ''
    }
    if ($expectedHash -notmatch '^[a-fA-F0-9]{64}$') {
        return $false
    }
    if (-not $VerifyHash) {
        return $true
    }
    try {
        if ($null -ne $ArtifactVerifier) {
            return [bool](& $ArtifactVerifier $path $expectedHash)
        }
        return (Get-FileHash -LiteralPath $path `
            -Algorithm SHA256).Hash -ieq $expectedHash
    }
    catch {
        Write-Verbose ('Yerel kurulum paketi dogrulanamadi: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Get-InstallerCommonDependencyDescriptors {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $descriptors = [Collections.Generic.List[object]]::new()
    $descriptors.Add($Config.Bootstrap.PowerShell)
    foreach ($dependency in @($Config.Dependencies)) {
        if ([string]$dependency.Name -ine 'Ollama' -and
            [bool]$dependency.Required) {
            $descriptors.Add($dependency)
        }
    }
    return $descriptors.ToArray()
}
function Get-InstallerPythonMinorTags {
    param([Parameter(Mandatory)][pscustomobject]$Descriptor)
    $minimum = [version][string]$Descriptor.MinimumVersion
    $maximum = [version][string]$Descriptor.MaximumVersionExclusive
    $current = [version]::new($minimum.Major, $minimum.Minor, 0)
    $tags = [Collections.Generic.List[string]]::new()
    while ($current -lt $maximum -and $tags.Count -lt 16) {
        $tags.Add(('{0}.{1}' -f $current.Major, $current.Minor))
        $current = [version]::new(
            $current.Major,
            $current.Minor + 1,
            0
        )
    }
    if ($tags.Count -eq 0 -or $current -lt $maximum) {
        throw 'Python surum araligi aday uretmeye uygun degil.'
    }
    return $tags.ToArray()
}
function Get-InstallerPythonExecutableCandidates {
    param([Parameter(Mandatory)][pscustomobject]$Descriptor)
    $paths = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $add = {
        param([AllowEmptyString()][string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }
        try {
            $full = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($Path)
            )
            if ($full.IndexOf('\Microsoft\WindowsApps\',
                    [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return
            }
            if ($seen.Add($full)) {
                $paths.Add($full)
            }
        }
        catch {
            Write-Verbose ('Python adayi gecersiz: {0}' -f $Path)
        }
    }.GetNewClosure()
    $ownedRoot = Resolve-InstallerPath `
        -Path ([string]$Descriptor.InstallPath)
    & $add (Join-Path $ownedRoot 'python.exe')
    $minorTags = @(Get-InstallerPythonMinorTags `
        -Descriptor $Descriptor)
    foreach ($tag in $minorTags) {
        $directory = 'Python{0}' -f $tag.Replace('.', '')
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            & $add (Join-Path $env:ProgramFiles `
                "$directory\python.exe")
        }
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            & $add (Join-Path $env:LOCALAPPDATA `
                "Programs\Python\$directory\python.exe")
        }
        if (-not [string]::IsNullOrWhiteSpace(
            $InitiatingUserProfile
        )) {
            & $add (Join-Path $InitiatingUserProfile `
                "AppData\Local\Programs\Python\$directory\python.exe")
        }
        foreach ($keyPath in @(
            "HKCU:\Software\Python\PythonCore\$tag\InstallPath",
            "HKLM:\Software\Python\PythonCore\$tag\InstallPath",
            ("HKLM:\SOFTWARE\WOW6432Node\Python\" +
                "PythonCore\$tag\InstallPath")
        )) {
            try {
                $key = Get-Item -LiteralPath $keyPath `
                    -ErrorAction SilentlyContinue
                if ($null -ne $key) {
                    & $add (Join-Path ([string]$key.GetValue('')) `
                        'python.exe')
                }
            }
            catch {
                Write-Verbose (
                    'Python registry adayi okunamadi: {0}' -f $keyPath
                )
            }
        }
    }
    $commandNames = @('python.exe', 'python3.exe') + @(
        $minorTags | ForEach-Object { "python$_.exe" }
    )
    foreach ($name in $commandNames) {
        foreach ($command in @(Get-Command $name `
            -CommandType Application -All `
            -ErrorAction SilentlyContinue)) {
            & $add ([string]$command.Source)
        }
    }
    return $paths.ToArray()
}
function Test-InstallerPythonVersionCompatible {
    param(
        [Parameter(Mandatory)][version]$Version,
        [Parameter(Mandatory)][pscustomobject]$Descriptor
    )
    if ($Version -lt [version][string]$Descriptor.MinimumVersion) {
        return $false
    }
    $maximum = $Descriptor.PSObject.Properties[
        'MaximumVersionExclusive'
    ]
    return $null -eq $maximum -or
        [string]::IsNullOrWhiteSpace([string]$maximum.Value) -or
        $Version -lt [version][string]$maximum.Value
}
function Test-InstallerDependencyDescriptorInstalled {
    param(
        [Parameter(Mandatory)][pscustomobject]$Descriptor,
        [scriptblock]$PythonCandidateProvider,
        [scriptblock]$PythonVersionReader
    )
    $name = Get-InstallerDependencySourceName -Descriptor $Descriptor
    if ($name -ceq 'PowerShell') {
        $minimum = [version][string]$Descriptor.Version
        return -not [string]::IsNullOrWhiteSpace(
            (Get-PowerShellExecutable -MinimumVersion $minimum `
                -MachineOnly)
        )
    }
    if ($name -ceq 'Visual C++ Runtime') {
        foreach ($path in @(
            'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
            ('HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\' +
                '14.0\VC\Runtimes\x64')
        )) {
            $value = Get-ItemProperty -LiteralPath $path `
                -ErrorAction SilentlyContinue
            $match = if ($null -ne $value) {
                [regex]::Match(
                    [string]$value.Version,
                    '\d+(?:\.\d+){1,3}'
                )
            }
            else {
                $null
            }
            if ($null -ne $value -and $value.Installed -eq 1 -and
                $null -ne $match -and $match.Success -and
                [version]$match.Value -ge
                    [version][string]$Descriptor.MinimumVersion) {
                return $true
            }
        }
        return $false
    }
    if ($name -cne 'Python') {
        return $false
    }
    $candidates = if ($null -ne $PythonCandidateProvider) {
        @(& $PythonCandidateProvider $Descriptor)
    }
    else {
        @(Get-InstallerPythonExecutableCandidates `
            -Descriptor $Descriptor)
    }
    foreach ($python in $candidates) {
        if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
            continue
        }
        try {
            $version = if ($null -ne $PythonVersionReader) {
                & $PythonVersionReader $python
            }
            else {
                $output = @(& $python -I -c `
                    ('import struct,sys;' +
                        'assert struct.calcsize("P")==8;' +
                        'print(".".join(map(str,' +
                        'sys.version_info[:3])))') 2>$null)
                if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
                    $null
                }
                else {
                    [version][string]$output[-1]
                }
            }
            if ($null -ne $version -and
                (Test-InstallerPythonVersionCompatible `
                    -Version ([version]$version) `
                    -Descriptor $Descriptor)) {
                return $true
            }
        }
        catch {
            Write-Verbose ('Python adayi dogrulanamadi: {0}' -f `
                $python)
        }
    }
    return $false
}
function Set-InstallerInstalledDependencySource {
    param(
        [Parameter(Mandatory)][pscustomobject]$Descriptor,
        [scriptblock]$InstalledTester
    )
    $installed = if ($null -ne $InstalledTester) {
        [bool](& $InstalledTester $Descriptor)
    }
    else {
        Test-InstallerDependencyDescriptorInstalled `
            -Descriptor $Descriptor
    }
    if (-not $installed) {
        return $false
    }
    $Descriptor | Add-Member -NotePropertyName InstallSource `
        -NotePropertyValue Automatic -Force
    $name = Get-InstallerDependencySourceName -Descriptor $Descriptor
    Write-InstallerLog -Level INFO `
        -Message 'Installer.Dependency.AlreadyInstalled' `
        -MessageArguments @($name)
    Write-WinlamaUIStatus -Level SKIP -Message (Get-LocalizedText `
        -Key 'Installer.Dependency.AlreadyInstalled' `
        -Arguments @($name))
    return $true
}
function Assert-InstallerPythonDetectionContracts {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $python = $Config.Dependencies | Where-Object Name -EQ 'Python' |
        Select-Object -First 1
    if ($null -eq $python) {
        throw 'Python algilama fixture bagimliligi bulunamadi.'
    }
    $candidate = $PSCommandPath
    $provider = { param($Descriptor) @($candidate) }.GetNewClosure()
    $compatibleReader = { param($Path) [version]'3.11.8' }
    $oldReader = { param($Path) [version]'3.10.14' }
    $newReader = { param($Path) [version]'3.13.0' }
    $discovered = @(Get-InstallerPythonExecutableCandidates `
        -Descriptor $python)
    if (@($discovered | Where-Object {
            $_ -like '*\Python312\python.exe'
        }).Count -eq 0 -or
        @($discovered | Where-Object {
            $_ -like '*\Microsoft\WindowsApps\*'
        }).Count -gt 0 -or
        -not (Test-InstallerDependencyDescriptorInstalled `
            -Descriptor $python `
            -PythonCandidateProvider $provider `
            -PythonVersionReader $compatibleReader) -or
        (Test-InstallerDependencyDescriptorInstalled `
            -Descriptor $python `
            -PythonCandidateProvider $provider `
            -PythonVersionReader $oldReader) -or
        (Test-InstallerDependencyDescriptorInstalled `
            -Descriptor $python `
            -PythonCandidateProvider $provider `
            -PythonVersionReader $newReader) -or
        -not (Test-InstallerPythonVersionCompatible `
            -Version ([version]'3.12.9') -Descriptor $python) -or
        (Test-InstallerPythonVersionCompatible `
            -Version ([version]'3.13.0') -Descriptor $python)) {
        throw 'Python uyumlu kurulum algilama sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.PythonExistingInstall'
    return $true
}
function Get-InstallerDependencySourceName {
    param([Parameter(Mandatory)][pscustomobject]$Descriptor)
    $nameProperty = $Descriptor.PSObject.Properties['Name']
    if ($null -ne $nameProperty -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$nameProperty.Value
        )) {
        return [string]$nameProperty.Value
    }
    return 'PowerShell'
}
function Read-InstallerDependencySource {
    param(
        [Parameter(Mandatory)][pscustomobject]$Descriptor,
        [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
        [string]$Selection = 'Prompt',
        [scriptblock]$InputReader,
        [bool]$Interactive = [Environment]::UserInteractive,
        [bool]$VerifyLocalIdentity = $true,
        [scriptblock]$ArtifactVerifier
    )
    $Selection = ConvertTo-InstallerSourceSelection `
        -Selection $Selection
    if ($Selection -eq 'Online' -or
        ($Selection -eq 'Automatic' -and -not $VerifyLocalIdentity)) {
        return $Selection
    }
    $displayName = Get-InstallerDependencySourceName `
        -Descriptor $Descriptor
    $offlinePath = [string]$Descriptor.OfflinePath
    $localVerified = Test-InstallerDescriptorLocalArtifact `
        -Descriptor $Descriptor `
        -VerifyHash $VerifyLocalIdentity `
        -ArtifactVerifier $ArtifactVerifier
    if ($Selection -eq 'Automatic') {
        return $(if ($localVerified) { 'Local' } else { 'Online' })
    }
    if ($Selection -eq 'Local') {
        if (-not $localVerified) {
            throw (New-NonRetryableException -Message (
                Get-LocalizedText `
                    -Key 'Dependencies.Error.LocalSourceMissing' `
                    -Arguments @($offlinePath)
            ))
        }
        return 'Local'
    }
    if ($Selection -eq 'Prompt' -and -not $localVerified) {
        Write-InstallerLog -Level INFO `
            -Message 'Installer.DependencySource.LocalUnavailable' `
            -MessageArguments @($offlinePath)
        return $(if ($VerifyLocalIdentity) { 'Online' } else {
            'Automatic'
        })
    }
    if (-not $Interactive) {
        return $(if ($VerifyLocalIdentity) {
            if ($localVerified) { 'Local' } else { 'Online' }
        }
        else {
            'Automatic'
        })
    }
    Write-InstallerSection -Title 'Installer.Section.DependencySource'
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.DependencySource.Description' `
        -Arguments @($displayName, $offlinePath)) -Color White
    if ($localVerified) {
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.DependencySource.LocalAvailable' `
            -Arguments @($displayName)) -Color Green
    }
    else {
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Installer.DependencySource.LocalUnavailable' `
            -Arguments @($offlinePath)) `
            -Color Yellow
    }
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.DependencySource.MenuLocal') -Color Green
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.DependencySource.MenuOnline') -Color Cyan
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.DependencySource.MenuAutomatic') `
        -Color Cyan
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.DependencySource.MenuExit') -Color Yellow
    Write-InstallerRule
    while ($true) {
        $answer = (Read-WinlamaUIInput `
            -Prompt (Get-LocalizedText `
                -Key 'Installer.Prompt.DependencySource' `
                -Arguments @($displayName)) `
            -Label (Get-LocalizedText `
                -Key 'Common.Prompt.Selection') -NoLeadingRule `
            -InputReader $InputReader).Trim()
        if ($answer -eq '1') {
            if (-not $localVerified) {
                Write-WinlamaUIStatus -Level WARN `
                    -Message (Get-LocalizedText `
                        -Key 'Installer.DependencySource.LocalUnavailable' `
                        -Arguments @($offlinePath))
                continue
            }
            return 'Local'
        }
        if ($answer -eq '2') {
            return 'Online'
        }
        if ($answer -eq '3') {
            return $(if ($VerifyLocalIdentity) {
                if ($localVerified) { 'Local' } else { 'Online' }
            }
            else {
                'Automatic'
            })
        }
        if ($answer -eq '0') {
            return 'Exit'
        }
        Write-WinlamaUIStatus -Level WARN `
            -Message (Get-LocalizedText -Key 'Common.Selection.Invalid')
    }
}
function Read-InstallerDependencySources {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
        [string]$Selection = 'Prompt',
        [scriptblock]$InputReader,
        [bool]$Interactive = [Environment]::UserInteractive,
        [bool]$VerifyLocalIdentity = $true,
        [scriptblock]$ArtifactVerifier,
        [scriptblock]$InstalledTester
    )
    $Selection = ConvertTo-InstallerSourceSelection `
        -Selection $Selection
    foreach ($descriptor in @(Get-InstallerCommonDependencyDescriptors `
        -Config $Config)) {
        if (Set-InstallerInstalledDependencySource `
            -Descriptor $descriptor -InstalledTester $InstalledTester) {
            continue
        }
        $resolved = Read-InstallerDependencySource `
            -Descriptor $descriptor -Selection $Selection `
            -InputReader $InputReader -Interactive $Interactive `
            -VerifyLocalIdentity $VerifyLocalIdentity `
            -ArtifactVerifier $ArtifactVerifier
        if ($resolved -eq 'Exit') {
            return 'Exit'
        }
        $descriptor | Add-Member -NotePropertyName InstallSource `
            -NotePropertyValue $resolved -Force
    }
    return 'Configured'
}
function Set-InstallerResumeDependencySources {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
        [string]$Selection = 'Prompt',
        [scriptblock]$ArtifactVerifier,
        [scriptblock]$InstalledTester
    )
    $Selection = ConvertTo-InstallerSourceSelection `
        -Selection $Selection
    if ($Selection -ne 'Prompt') {
        return Read-InstallerDependencySources -Config $Config `
            -Selection $Selection -ArtifactVerifier $ArtifactVerifier `
            -InstalledTester $InstalledTester
    }
    foreach ($descriptor in @(
        Get-InstallerCommonDependencyDescriptors -Config $Config
    )) {
        if (Set-InstallerInstalledDependencySource `
            -Descriptor $descriptor -InstalledTester $InstalledTester) {
            continue
        }
        $property = $descriptor.PSObject.Properties['InstallSource']
        $savedSelection = if ($null -ne $property -and
            [string]$property.Value -in @(
                'Local', 'Online', 'Automatic'
            )) {
            ConvertTo-InstallerSourceSelection `
                -Selection ([string]$property.Value)
        }
        else {
            'Automatic'
        }
        $resolved = Read-InstallerDependencySource `
            -Descriptor $descriptor -Selection $savedSelection `
            -ArtifactVerifier $ArtifactVerifier
        $descriptor | Add-Member -NotePropertyName InstallSource `
            -NotePropertyValue $resolved -Force
    }
    return 'Configured'
}
function Test-InstallerContinueOptionalErrors {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $property = $Config.Installation.PSObject.Properties[
        'ContinueOnOptionalError'
    ]
    return $null -ne $property -and [bool]$property.Value
}
function Assert-InstallerComfyUIDriverPreflight {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Hardware
    )
    if (-not $Config.ComfyUI.Enabled -or $Hardware.NvidiaSmiReady) {
        return $true
    }
    $message = Get-LocalizedText `
        -Key 'Installer.ComfyUI.NvidiaDriverUnavailable'
    if (-not (Test-InstallerContinueOptionalErrors -Config $Config)) {
        throw (New-NonRetryableException -Message $message)
    }
    Write-InstallerLog -Level WARN `
        -Message 'Installer.ComfyUI.NvidiaDriverSkipped'
    Write-WinlamaUIStatus -Level SKIP -Message $message
    $Config.ComfyUI.Enabled = $false
    $Config.ComfyUI.Requested = @()
    return $false
}
function Set-InstallerOptionalComponents {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][bool]$InstallOpenWebUI,
        [Parameter(Mandatory)][bool]$InstallVoice
    )
    $Config.OpenWebUI.Enabled = $InstallOpenWebUI
    $Config.Voice.Enabled = $InstallVoice
    $python = $Config.Dependencies |
        Where-Object Name -eq 'Python' |
        Select-Object -First 1
    if ($null -eq $python) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @('Dependencies.Python'))
    }
    $python.Required = [bool](
        $Config.OpenWebUI.Enabled -or $Config.Voice.Enabled
    )
}
function Install-ComfyUIModelPayload {
    param(
        [Parameter(Mandatory)][pscustomobject]$Model,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [ValidateSet('Local', 'Online', 'Automatic')]
        [string]$SourceSelection = 'Automatic',
        [bool]$VerifyLocalPayloadHashes = $true,
        [hashtable]$HashCache
    )
    $SourceSelection = ConvertTo-InstallerSourceSelection `
        -Selection $SourceSelection
    $root = Get-InstallerComfyUIModelsRoot -Config $Config `
        -ProjectRoot $ProjectRoot
    $downloaded = 0
    $assets = @(Get-InstallerComfyUIModelAssets -Model $Model)
    if ($assets.Count -eq 0) {
        throw 'ComfyUI modeli canonical asset kimligi icermiyor.'
    }
    foreach ($asset in $assets) {
        $target = Get-InstallerComfyUIAssetPath -Asset $asset `
            -Root $root
        $targetSafety = Assert-InstallerComfyUIAssetTargetSafety `
            -Root $root -Target $target
        $target = $targetSafety.Target
        $expectedHash = [string]$asset.Sha256
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $targetItem = Get-Item -LiteralPath $target -Force
            $targetReady = Test-InstallerComfyUIAssetSize `
                -Item $targetItem -Asset $asset
            if ($targetReady -and $VerifyLocalPayloadHashes) {
                $targetReady =
                    (Get-InstallerCachedFileSha256 -Path $target `
                        -HashCache $HashCache) -ieq $expectedHash
            }
            if ($targetReady) {
                continue
            }
            if ($null -ne $HashCache) {
                $HashCache.Remove(
                    ([IO.Path]::GetFullPath($target).ToUpperInvariant())
                )
            }
        }
        $packageAsset = $null
        if ($SourceSelection -ne 'Online') {
            $packageRoot = Join-Path $ProjectRoot 'Models'
            $packageAsset = Get-InstallerComfyUIAssetPath `
                -Asset $asset -Root $packageRoot
            if ((Test-InstallerComfyUIReparseChain `
                    -Path $packageAsset) -and
                (Test-Path -LiteralPath $packageAsset `
                    -PathType Leaf)) {
                $packageReady = Test-InstallerComfyUIAssetSize `
                    -Item (Get-Item -LiteralPath $packageAsset -Force) `
                    -Asset $asset
                if ($packageReady -and $VerifyLocalPayloadHashes) {
                    $packageReady =
                        (Get-InstallerCachedFileSha256 `
                            -Path $packageAsset `
                            -HashCache $HashCache) -ieq $expectedHash
                }
                if ($packageReady) {
                    [IO.Directory]::CreateDirectory(
                        $targetSafety.Parent
                    ) | Out-Null
                    $targetSafety = `
                        Assert-InstallerComfyUIAssetTargetSafety `
                            -Root $root -Target $target
                    $temporary = Join-Path $targetSafety.Parent `
                        ('{0}.{1}.copy' -f `
                            [IO.Path]::GetFileName($target), $PID)
                    $null = Assert-InstallerComfyUIAssetTargetSafety `
                        -Root $root -Target $temporary
                    try {
                        Remove-Item -LiteralPath $temporary -Force `
                            -ErrorAction SilentlyContinue
                        Copy-Item -LiteralPath $packageAsset `
                            -Destination $temporary -Force
                        $null = Assert-InstallerComfyUIAssetTargetSafety `
                            -Root $root -Target $temporary
                        $null = Assert-InstallerComfyUIAssetTargetSafety `
                            -Root $root -Target $target
                        Move-Item -LiteralPath $temporary `
                            -Destination $target -Force
                        if ($null -ne $HashCache) {
                            $HashCache.Remove(
                                ([IO.Path]::GetFullPath($target).
                                    ToUpperInvariant())
                            )
                        }
                        $downloaded++
                        continue
                    }
                    finally {
                        Remove-Item -LiteralPath $temporary -Force `
                            -ErrorAction SilentlyContinue
                    }
                }
                Write-InstallerLog -Level WARN `
                    -Message 'Manager.ComfyUI.HashMismatch' `
                    -MessageArguments @(
                        $Model.Name,
                        $asset.RelativePath
                    )
                Write-InstallerLine -Text (Get-LocalizedText `
                    -Key 'Manager.ComfyUI.HashMismatch' `
                    -Arguments @(
                        $Model.Name,
                        $asset.RelativePath
                    )) -Color Yellow
            }
        }
        if ($SourceSelection -eq 'Local') {
            throw (New-NonRetryableException -Message (
                Get-LocalizedText `
                    -Key 'Installer.ComfyUI.SourceLocalModelRequired' `
                    -Arguments @($Model.Name, $asset.RelativePath)
            ))
        }
        $uri = [uri]$asset.Uri
        if ($uri.Scheme -ne 'https') {
            throw (Get-LocalizedText `
                -Key 'Manager.ComfyUI.InsecureUri' `
                -Arguments @($uri.AbsoluteUri))
        }
        $requiredGB = [double]$asset.SizeGB * 1.1
        $driveRoot = [IO.Path]::GetPathRoot($target)
        $freeGB = [IO.DriveInfo]::new(
            $driveRoot
        ).AvailableFreeSpace / 1GB
        if ($freeGB -lt $requiredGB) {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.DownloadDiskInsufficient' `
                -Arguments @(
                    $Model.Name,
                    [math]::Ceiling($requiredGB),
                    [math]::Round($freeGB, 2)
                ))
        }
        [IO.Directory]::CreateDirectory($targetSafety.Parent) | Out-Null
        $targetSafety = Assert-InstallerComfyUIAssetTargetSafety `
            -Root $root -Target $target
        $temporary = Join-Path $targetSafety.Parent `
            ('{0}.{1}.download' -f `
                [IO.Path]::GetFileName($target), $PID)
        $null = Assert-InstallerComfyUIAssetTargetSafety `
            -Root $root -Target $temporary
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
        try {
            $downloadDelays = @($Config.Network.RetryBackoffSeconds)
            $downloadedAsset = $false
            for ($attempt = 0; $attempt -le $downloadDelays.Count;
                $attempt++) {
                try {
                    Remove-Item -LiteralPath $temporary -Force `
                        -ErrorAction SilentlyContinue
                    Save-WinlamaWebFile -Uri $uri -OutFile $temporary `
                        -TimeoutSec ([int]$Config.Network.
                            DownloadTimeoutSeconds)
                    $actualHash = `
                        Get-InstallerFileSha256WithProgress `
                            -Path $temporary
                    if ($actualHash -ine $expectedHash) {
                        throw (Get-LocalizedText `
                            -Key 'Manager.ComfyUI.HashMismatch' `
                            -Arguments @(
                                $Model.Name,
                                $asset.RelativePath
                            ))
                    }
                    $downloadedAsset = $true
                    break
                }
                catch {
                    if ($attempt -ge $downloadDelays.Count) {
                        throw
                    }
                    $delay = [int]$downloadDelays[$attempt]
                    Write-InstallerLog -Level WARN `
                        -Message 'Manager.Download.Retrying' `
                        -MessageArguments @($Model.Name, $delay) `
                        -Exception $_.Exception
                    Write-InstallerLine -Text (Get-LocalizedText `
                        -Key 'Manager.Download.Retrying' `
                        -Arguments @($Model.Name, $delay)) `
                        -Color Yellow
                    Start-Sleep -Seconds $delay
                }
            }
            if (-not $downloadedAsset) {
                throw (Get-LocalizedText `
                    -Key 'Manager.ComfyUI.VerificationFailed' `
                    -Arguments @($Model.Name))
            }
            $null = Assert-InstallerComfyUIAssetTargetSafety `
                -Root $root -Target $temporary
            $null = Assert-InstallerComfyUIAssetTargetSafety `
                -Root $root -Target $target
            Move-Item -LiteralPath $temporary `
                -Destination $target -Force
            if ($null -ne $HashCache) {
                $HashCache.Remove(
                    ([IO.Path]::GetFullPath($target).ToUpperInvariant())
                )
            }
            $downloaded++
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force `
                -ErrorAction SilentlyContinue
        }
    }
    return $downloaded
}
function Invoke-InstallerComfyUIModelSetup {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [object[]]$Models,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [ValidateSet('Local', 'Online', 'Automatic')]
        [string]$SourceSelection = 'Automatic',
        [bool]$VerifyLocalPayloadHashes = $true,
        [hashtable]$HashCache
    )
    if ($Models.Count -eq 0) {
        return
    }
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.ComfyUI.RequiresNotice') -Color Yellow
    foreach ($model in $Models) {
        if (Test-InstallerComfyUIModelInstalled -Model $model `
            -Config $Config -ProjectRoot $ProjectRoot `
            -VerifyHash:$VerifyLocalPayloadHashes `
            -HashCache $HashCache) {
            $modelsRoot = Get-InstallerComfyUIModelsRoot `
                -Config $Config -ProjectRoot $ProjectRoot
            Write-InstallerSourceTableRow -Source Local `
                -Name $model.Name -Detail $modelsRoot -Available
            continue
        }
        $localSource = if ($SourceSelection -ne 'Online') {
            Get-InstallerComfyUILocalModelDirectory `
                -Model $model -ProjectRoot $ProjectRoot
        }
        else {
            $null
        }
        if (-not [string]::IsNullOrWhiteSpace($localSource)) {
            $modelsRoot = Get-InstallerComfyUIModelsRoot `
                -Config $Config -ProjectRoot $ProjectRoot
            if (-not (Test-InstallerComfyUILocalModelCopied `
                -Model $model -Config $Config `
                -ProjectRoot $ProjectRoot `
                -VerifyHash:$VerifyLocalPayloadHashes `
                -HashCache $HashCache)) {
                Write-InstallerLine -Text (Get-LocalizedText `
                    -Key 'Manager.ComfyUI.LocalCopying' `
                    -Arguments @($model.Name)) -Color Cyan
                Write-InstallerLog -Level INFO `
                    -Message 'Manager.ComfyUI.LocalCopying' `
                    -MessageArguments @($model.Name)
                $localCopyReady = Copy-InstallerComfyUILocalModel `
                    -Model $model -Config $Config `
                    -ProjectRoot $ProjectRoot `
                    -SourceSelection $SourceSelection `
                    -VerifyLocalPayloadHashes:$VerifyLocalPayloadHashes `
                    -HashCache $HashCache
                if (-not $localCopyReady) {
                    if ($SourceSelection -eq 'Local') {
                        throw (Get-LocalizedText `
                            -Key 'Manager.ComfyUI.VerificationFailed' `
                            -Arguments @($model.Name))
                    }
                    Write-InstallerLog -Level WARN `
                        -Message 'Manager.ComfyUI.VerificationFailed' `
                        -MessageArguments @($model.Name)
                    foreach ($asset in @(
                        Get-InstallerComfyUIModelAssets -Model $model
                    )) {
                        $invalidTarget = Get-InstallerComfyUIAssetPath `
                            -Asset $asset -Root $modelsRoot
                        $invalidSafety = `
                            Assert-InstallerComfyUIAssetTargetSafety `
                                -Root $modelsRoot -Target $invalidTarget
                        Remove-Item -LiteralPath $invalidSafety.Target `
                            -Force -ErrorAction SilentlyContinue
                    }
                    Write-InstallerLine -Text (Get-LocalizedText `
                        -Key 'Manager.ComfyUI.DownloadStarting' `
                        -Arguments @($model.Name)) -Color Cyan
                    Write-InstallerLog -Level INFO `
                        -Message 'Manager.ComfyUI.DownloadStarting' `
                        -MessageArguments @($model.Name)
                    try {
                        $null = Install-ComfyUIModelPayload `
                            -Model $model -Config $Config `
                            -ProjectRoot $ProjectRoot `
                            -SourceSelection Online `
                            -VerifyLocalPayloadHashes $true `
                            -HashCache $HashCache
                    }
                    catch {
                        if (-not (Test-InstallerContinueOptionalErrors `
                                -Config $Config)) {
                            throw
                        }
                        Write-InstallerLog -Level WARN `
                            -Message 'Installer.ComfyUI.ModelSkipped' `
                            -MessageArguments @(
                                $model.Name,
                                $_.Exception.Message
                            ) -Exception $_.Exception
                        Write-InstallerLine -Text (Get-LocalizedText `
                            -Key 'Installer.ComfyUI.ModelSkipped' `
                            -Arguments @(
                                $model.Name,
                                $_.Exception.Message
                            )) -Color Yellow
                        continue
                    }
                    if (-not (Test-InstallerComfyUIModelInstalled `
                            -Model $model -Config $Config `
                            -ProjectRoot $ProjectRoot -VerifyHash `
                            -HashCache $HashCache)) {
                        throw (Get-LocalizedText `
                            -Key 'Manager.ComfyUI.VerificationFailed' `
                            -Arguments @($model.Name))
                    }
                    Write-InstallerLine -Text (Get-LocalizedText `
                        -Key 'Manager.ComfyUI.DownloadCompleted' `
                        -Arguments @($model.Name)) -Color Green
                    continue
                }
                Write-InstallerLine -Text (Get-LocalizedText `
                    -Key 'Manager.ComfyUI.LocalCopyCompleted' `
                    -Arguments @($model.Name)) -Color Green
                Write-InstallerLog -Level INFO `
                    -Message 'Manager.ComfyUI.LocalCopyCompleted' `
                    -MessageArguments @($model.Name)
            }
            if (Test-InstallerComfyUIModelInstalled `
                -Model $model -Config $Config `
                -ProjectRoot $ProjectRoot) {
                Write-InstallerSourceTableRow -Source Local `
                    -Name $model.Name -Detail $modelsRoot -Available
                continue
            }
            Write-InstallerLine -Text (Get-LocalizedText `
                -Key 'Installer.ComfyUI.LocalIncomplete' `
                -Arguments @($model.Name)) -Color Cyan
            Write-InstallerLog -Level INFO `
                -Message 'Installer.ComfyUI.LocalIncomplete' `
                -MessageArguments @($model.Name)
            try {
                $null = Install-ComfyUIModelPayload `
                    -Model $model -Config $Config `
                    -ProjectRoot $ProjectRoot `
                    -SourceSelection $SourceSelection `
                    -VerifyLocalPayloadHashes:$VerifyLocalPayloadHashes `
                    -HashCache $HashCache
            }
            catch {
                if (-not (Test-InstallerContinueOptionalErrors `
                    -Config $Config)) {
                    throw
                }
                Write-InstallerLog -Level WARN `
                    -Message 'Installer.ComfyUI.ModelSkipped' `
                    -MessageArguments @(
                        $model.Name,
                        $_.Exception.Message
                    ) -Exception $_.Exception
                Write-InstallerLine -Text (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.ModelSkipped' `
                    -Arguments @(
                        $model.Name,
                        $_.Exception.Message
                    )) -Color Yellow
                continue
            }
            if (-not (Test-InstallerComfyUIModelInstalled `
                -Model $model -Config $Config `
                -ProjectRoot $ProjectRoot -VerifyHash `
                -HashCache $HashCache)) {
                throw (Get-LocalizedText `
                    -Key 'Manager.ComfyUI.VerificationFailed' `
                    -Arguments @($model.Name))
            }
            continue
        }
        $localOnlyProperty = $model.PSObject.Properties['LocalOnly']
        if ($null -ne $localOnlyProperty -and
            [bool]$localOnlyProperty.Value) {
            if (-not (Test-InstallerContinueOptionalErrors `
                -Config $Config)) {
                throw (New-NonRetryableException -Message (
                    Get-LocalizedText `
                        -Key 'Installer.ComfyUI.LocalOnlyMissing' `
                        -Arguments @($model.Name)
                ))
            }
            Write-InstallerLine -Text (Get-LocalizedText `
                -Key 'Installer.ComfyUI.LocalOnlyMissing' `
                -Arguments @($model.Name)) -Color Yellow
            continue
        }
        if (Test-InstallerComfyUIModelInstalled `
            -Model $model -Config $Config `
            -ProjectRoot $ProjectRoot `
            -VerifyHash:$VerifyLocalPayloadHashes `
            -HashCache $HashCache) {
            $modelsRoot = Get-InstallerComfyUIModelsRoot `
                -Config $Config -ProjectRoot $ProjectRoot
            Write-InstallerSourceTableRow -Source Local `
                -Name $model.Name -Detail $modelsRoot -Available
        }
        else {
            Write-InstallerSourceTableRow -Source Online `
                -Name $model.Name -Detail (Get-LocalizedText `
                    -Key 'Installer.LocalPackages.Missing')
            Write-InstallerLine -Text (Get-LocalizedText `
                -Key 'Manager.ComfyUI.DownloadStarting' `
                -Arguments @($model.Name)) -Color Cyan
            Write-InstallerLog -Level INFO `
                -Message 'Manager.ComfyUI.DownloadStarting' `
                -MessageArguments @($model.Name)
            try {
                $null = Install-ComfyUIModelPayload -Model $model `
                    -Config $Config -ProjectRoot $ProjectRoot `
                    -SourceSelection $SourceSelection `
                    -VerifyLocalPayloadHashes:$VerifyLocalPayloadHashes `
                    -HashCache $HashCache
            }
            catch {
                if (-not (Test-InstallerContinueOptionalErrors `
                    -Config $Config)) {
                    throw
                }
                Write-InstallerLog -Level WARN `
                    -Message 'Installer.ComfyUI.ModelSkipped' `
                    -MessageArguments @(
                        $model.Name,
                        $_.Exception.Message
                    ) -Exception $_.Exception
                Write-InstallerLine -Text (Get-LocalizedText `
                    -Key 'Installer.ComfyUI.ModelSkipped' `
                    -Arguments @(
                        $model.Name,
                        $_.Exception.Message
                    )) -Color Yellow
                continue
            }
            if (Test-InstallerComfyUIModelInstalled `
                -Model $model -Config $Config `
                -ProjectRoot $ProjectRoot -VerifyHash `
                -HashCache $HashCache) {
                Write-InstallerLine -Text (Get-LocalizedText `
                    -Key 'Manager.ComfyUI.DownloadCompleted' `
                    -Arguments @($model.Name)) -Color Green
            }
            elseif (-not (Test-InstallerContinueOptionalErrors `
                -Config $Config)) {
                throw (Get-LocalizedText `
                    -Key 'Manager.ComfyUI.VerificationFailed' `
                    -Arguments @($model.Name))
            }
        }
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.ComfyUI.Selected' `
        -MessageArguments @($Models.Count)
}
function Sync-InstallerComfyUIRequestedModels {
    param(
        [Parameter(Mandatory)][object[]]$Models,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [bool]$VerifyHash = $true,
        [hashtable]$HashCache
    )
    $available = @($Models | Where-Object {
        Test-InstallerComfyUIModelInstalled -Model $_ `
            -Config $Config -ProjectRoot $ProjectRoot `
            -VerifyHash:$VerifyHash `
            -HashCache $HashCache
    })
    $Config.ComfyUI.Requested = @($available | ForEach-Object {
        [string]$_.Name
    })
    return $available.Count
}
function Add-InstallerComfyUISelectionToCatalog {
    param(
        [Parameter(Mandatory)][object[]]$Models,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $catalog = [Collections.Generic.List[object]]::new()
    foreach ($model in @($Config.ComfyUI.Catalog)) {
        $catalog.Add($model)
    }
    foreach ($model in $Models) {
        if (@(Get-InstallerComfyUIModelAssets -Model $model).Count -eq 0) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldInvalid' `
                -Arguments @('ComfyUI.Catalog.Assets'))
        }
        if ($null -ne ($catalog | Where-Object {
            [string]$_.Name -ieq [string]$model.Name
        } | Select-Object -First 1)) {
            continue
        }
        $catalog.Add($model)
    }
    $Config.ComfyUI.Catalog = $catalog.ToArray()
}
function Set-InstallerOllamaComponent {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $Config.Ollama.Enabled = $Enabled
    $dependency = Get-InstallerOllamaDependency -Config $Config
    $dependency.Required = $Enabled
    if (-not $Enabled) {
        $Config.Models.SelectionMode = 'Skip'
        $Config.Models.Requested = @()
        $Config.Models.LocalPackageImport.SelectedPackages = @()
    }
}
function Get-InstallerValidationSnapshot {
    $snapshot = [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $excluded = @('.agents', '.codex', '.git')
    foreach ($item in Get-ChildItem -LiteralPath $PSScriptRoot `
        -Recurse -Force -ErrorAction Stop) {
        $relativePath = $item.FullName.Substring(
            $PSScriptRoot.Length
        ).TrimStart('\')
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }
        $topDirectory = @($relativePath -split '[\\/]')[0]
        if ($topDirectory -in $excluded) {
            continue
        }
        if ($item.PSIsContainer) {
            $snapshot[$relativePath] = 'D'
            continue
        }
        if ($topDirectory -in @('Models', 'Runtime')) {
            $snapshot[$relativePath] = 'F|{0}|{1}' -f `
                $item.Length, $item.LastWriteTimeUtc.Ticks
            continue
        }
        $hash = (Get-FileHash -LiteralPath $item.FullName `
            -Algorithm SHA256).Hash
        $snapshot[$relativePath] = 'F|{0}|{1}' -f `
            $item.Length, $hash
    }
    return ,$snapshot
}
function Get-InstallerValidationChanges {
    param(
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, string]]$Before,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, string]]$After
    )
    $paths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in $Before.Keys) {
        $null = $paths.Add($path)
    }
    foreach ($path in $After.Keys) {
        $null = $paths.Add($path)
    }
    return @($paths | Where-Object {
        -not $Before.ContainsKey($_) -or
        -not $After.ContainsKey($_) -or
        $Before[$_] -cne $After[$_]
    } | Sort-Object)
}
function Invoke-InstallerChildValidations {
    param([Parameter(Mandatory)][version]$MinimumVersion)
    $executables = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $null = $executables.Add((Get-Process -Id $PID).Path)
    $pwsh = Get-PowerShellExecutable `
        -MinimumVersion $MinimumVersion -MachineOnly
    if (-not [string]::IsNullOrWhiteSpace($pwsh)) {
        $null = $executables.Add($pwsh)
    }
    $scripts = @(
        'Launcher.ps1',
        'Engine.ps1',
        'Start.ps1',
        'ModelManager.ps1',
        'Repair.ps1',
        'Uninstall.ps1',
        'Modules\UI\OpenWebUI.ps1',
        'Modules\UI\ComfyUI.ps1'
    )
    $uiMarkers = @{
        'Launcher.ps1' = @('Launcher.Main')
        'Engine.ps1' = @('Engine.Status')
        'Start.ps1' = @('Start.Status')
        'ModelManager.ps1' = @(
            'ModelManager.Main', 'ModelManager.Computer',
            'ModelManager.Packages', 'ModelManager.ComfyUI',
            'ModelManager.Prompts'
        )
        'Repair.ps1' = @(
            'Repair.Main', 'Repair.SourceSelection',
            'Repair.DestinationPrompt'
        )
        'Uninstall.ps1' = @(
            'Uninstall.Main', 'Uninstall.FullSelection',
            'Uninstall.RuntimeContracts'
        )
        'Modules\UI\OpenWebUI.ps1' = @('OpenWebUI.Status')
        'Modules\UI\ComfyUI.ps1' = @('ComfyUI.Status')
    }
    $contractMarkers = @{
        'Start.ps1' = @(
            'TTS.RuntimeContracts',
            'ComfyUI.ObjectInfoContract',
            'Runtime.HealthMatrix',
            'Runtime.ChildArgumentQuoting',
            'Runtime.OptionalFailurePolicy',
            'Runtime.OptionalFailureDurable',
            'Runtime.AggregateContracts',
            'Start.EffectiveModeMatrix'
        )
        'Modules\UI\ComfyUI.ps1' = @(
            'ComfyUI.RuntimeIdentity',
            'ComfyUI.RuntimeIdentityExport',
            'ComfyUI.ObjectInfoContract',
            'ComfyUI.LauncherArguments',
            'ComfyUI.TreeHashOrdinal',
            'ComfyUI.SourcePolicy',
            'ComfyUI.RequirementsContracts',
            'ComfyUI.StaticWorkflows'
        )
    }
    $before = Get-InstallerValidationSnapshot
    foreach ($executable in $executables) {
        $runtimeVersion = & $executable -NoLogo -NoProfile `
            -Command '$PSVersionTable.PSVersion.ToString()'
        if ($LASTEXITCODE -ne 0) {
            throw (Get-LocalizedText `
                -Key 'Installer.Error.ChildRuntimeInvalid' `
                -Arguments @($executable))
        }
        foreach ($relativePath in $scripts) {
            Write-Verbose (Get-LocalizedText `
                -Key 'Installer.Validation.ChildStarted' `
                -Arguments @(
                    $relativePath,
                    $runtimeVersion.Trim()
                ))
            $arguments = @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                (Join-Path $PSScriptRoot $relativePath),
                '-ValidateOnly',
                '-NoPause',
                '-Verbose'
            )
            $output = @(& $executable @arguments 2>&1)
            $childExitCode = $LASTEXITCODE
            $errorRecords = @($output | Where-Object {
                $_ -is [Management.Automation.ErrorRecord]
            })
            $lines = @($output | ForEach-Object {
                ($_ | Out-String).TrimEnd("`r", "`n")
            })
            foreach ($line in $lines) {
                Write-Verbose ('{0} | {1}' -f $relativePath, $line)
            }
            $failureLines = @($lines | Where-Object {
                $_ -match '(?i)^(BEKLENMEYEN HATA|HATA|ERROR)\s*[:|]' -or
                $_ -match '(?i)^(Onarim|Kurulum|Kaldirma) ' +
                    '(tamamlanamadi|basarisiz)\s*:' -or
                $_ -match '(?i)^.+ baslatilamadi\s*:'
            })
            if ($childExitCode -ne 0 -or
                $errorRecords.Count -gt 0 -or
                $failureLines.Count -gt 0) {
                $detail = (
                    @($errorRecords | ForEach-Object { $_.ToString() }) +
                    $failureLines +
                    @($lines | Select-Object -Last 40)
                ) -join [Environment]::NewLine
                throw (Get-LocalizedText `
                    -Key 'Installer.Error.ChildValidationFailed' `
                    -Arguments @(
                        $relativePath,
                        $runtimeVersion.Trim(),
                        $childExitCode,
                        $detail
                    ))
            }
            $marker = 'WINLAMA_VALIDATION_OK:{0}' -f `
                [IO.Path]::GetFileName($relativePath)
            if (($lines -join [Environment]::NewLine) `
                -notlike "*$marker*") {
                throw (Get-LocalizedText `
                    -Key 'Installer.Error.ChildValidationIncomplete' `
                    -Arguments @(
                        $relativePath,
                        $runtimeVersion.Trim()
                    ))
            }
            $joinedOutput = $lines -join [Environment]::NewLine
            foreach ($uiMarker in @($uiMarkers[$relativePath])) {
                $requiredMarker = "WINLAMA_UI_OK:$uiMarker"
                if ($joinedOutput -notlike "*$requiredMarker*") {
                    throw (Get-LocalizedText `
                        -Key 'Installer.Error.ChildValidationIncomplete' `
                        -Arguments @(
                            "$relativePath ($requiredMarker)",
                            $runtimeVersion.Trim()
                        ))
                }
            }
            foreach ($contractMarker in @(
                $contractMarkers[$relativePath]
            )) {
                $requiredMarker = `
                    "WINLAMA_VALIDATION_OK:$contractMarker"
                if ($joinedOutput -notlike "*$requiredMarker*") {
                    throw (Get-LocalizedText `
                        -Key 'Installer.Error.ChildValidationIncomplete' `
                        -Arguments @(
                            "$relativePath ($requiredMarker)",
                            $runtimeVersion.Trim()
                        ))
                }
            }
            if ($relativePath -eq 'Launcher.ps1') {
                $menuMarker = 'WINLAMA_UI_RENDERED:Uninstall.Main'
                $promptMarker = `
                    'WINLAMA_UI_PROMPT_OK:Uninstall.Selection'
                $completeMarker = 'WINLAMA_UI_OK:Uninstall.Main'
                $flowMarker = `
                    'WINLAMA_UI_FLOW_OK:Launcher.UninstallChild'
                $menuPosition = $joinedOutput.IndexOf($menuMarker)
                $promptPosition = $joinedOutput.IndexOf($promptMarker)
                $completePosition = $joinedOutput.IndexOf($completeMarker)
                $flowPosition = $joinedOutput.IndexOf($flowMarker)
                if ($menuPosition -lt 0 -or $promptPosition -lt 0 -or
                    $completePosition -lt 0 -or $flowPosition -lt 0 -or
                    $menuPosition -gt $promptPosition -or
                    $promptPosition -gt $completePosition -or
                    $completePosition -gt $flowPosition) {
                    throw [IO.InvalidDataException]::new(
                        'Launcher kaldirma menusu gorunurluk sirasi gecersiz.'
                    )
                }
            }
            Write-Verbose (Get-LocalizedText `
                -Key 'Installer.Validation.ChildCompleted' `
                -Arguments @(
                    $relativePath,
                    $runtimeVersion.Trim()
                ))
        }
    }
    $after = Get-InstallerValidationSnapshot
    $changed = @(Get-InstallerValidationChanges `
        -Before $before -After $after)
    if ($changed.Count -gt 0) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.ValidationCreatedFiles' `
            -Arguments @(($changed -join ', ')))
    }
}
function Invoke-SourceValidation {
    Assert-InstallerPackagePersistentCleanlinessContracts
    if (-not (Test-InstallerPackagePersistentCleanliness `
        -Root $PSScriptRoot)) {
        throw [IO.InvalidDataException]::new(
            'Kaynak kokunde kalici paket artigi bulundu.'
        )
    }
    $fixtureHash = Get-InstallerFileSha256WithProgress `
        -Path $PSCommandPath
    $expectedFixtureHash = (Get-FileHash `
        -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    if ($fixtureHash -cne $expectedFixtureHash) {
        throw 'Ilerlemeli SHA-256 dogrulamasi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ProgressiveSha256'
    $artifactsPath = Join-Path $PSScriptRoot 'Artifacts'
    if (Test-Path -LiteralPath $artifactsPath) {
        throw [IO.InvalidDataException]::new(
            'Artifacts klasoru kaynak paketinde bulunamaz.'
        )
    }
    Assert-ApplicationPayloadContracts
    $operationalFiles = @(
        Assert-ApplicationSourcePayload -SourceRoot $PSScriptRoot
    )
    if ($operationalFiles.Count -ne 43) {
        throw [IO.InvalidDataException]::new(
            'Canonical operasyonel payload kimligi gecersiz.'
        )
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.OperationalPayload43'
    Assert-InstallerRuntimePackageCleanlinessContracts
    Assert-InstallerComfyUIRuntimeContracts `
        -Config $script:InstallerConfiguration
    Assert-InstallerComfyUIRuntimeSwapPathContracts
    $requiredPaths = @(
        'Install.ps1',
        'Engine.ps1',
        'ModelManager.ps1',
        'Uninstall.ps1',
        'Launcher.ps1',
        'Repair.ps1',
        'Start.ps1',
        'RunMe.bat',
        'Data\Configs\config.json',
        'Modules\Localization\LocalizationManager.psm1',
        'Modules\UI\ConsoleUI.psm1',
        'String\tr.ini',
        'Modules\Dashboard\template.html',
        'Modules\UI\OpenWebUI.ps1',
        'Modules\UI\ComfyUI.ps1',
        'Data\Workflows\Wan2.1_T2V_Workflow.json',
        'Data\Workflows\Flux1_Schnell_API.json',
        'Modules\ComfyUI\DefaultWorkflow\__init__.py',
        ('Modules\ComfyUI\DefaultWorkflow\web\' +
            'default_workflow.js'),
        'Modules\ComfyUI\DefaultWorkflow\LICENSE',
        'Services\TtsServer.py'
    )
    $requiredPaths += @(
        0..13 | ForEach-Object {
            $prefix = $_.ToString('00')
            $module = @(Get-ChildItem `
                -LiteralPath (Join-Path $PSScriptRoot 'Modules') `
                -Filter "$prefix`_*.psm1")
            if ($module.Count -ne 1) {
                throw (Get-LocalizedText `
                    -Key 'Installer.Error.ModuleCountInvalid' `
                    -Arguments @($prefix))
            }
            "Modules\$($module[0].Name)"
        }
    )
    foreach ($relativePath in $requiredPaths) {
        $path = Join-Path $PSScriptRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw (Get-LocalizedText `
                -Key 'Installer.Error.RequiredFileMissing' `
                -Arguments @($relativePath))
        }
    }
    $sourceExtensions = @(
        '.bat', '.html', '.ini', '.js', '.json', '.md',
        '.ps1', '.psm1', '.py', '.yaml', '.yml'
    )
    $sourceNames = @('.gitattributes', '.gitignore', 'LICENSE')
    $excludedFiles = @('Winlama-Rehberi.html')
    $excludedDirectories = @(
        '.git', 'Artifacts', 'Logs', 'Models',
        'Reports', 'Runtime', 'Temp'
    )
    $defaultConfigRelativePath = [string](
        $script:InstallerConfiguration.OpenWebUI.DefaultConfig.Path
    )
    $sourceFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot `
        -Recurse -File | Where-Object {
            if ($_.Extension -notin $sourceExtensions -and
                $_.Name -notin $sourceNames) {
                return $false
            }
            $relativePath = $_.FullName.Substring(
                $PSScriptRoot.Length
            ).TrimStart('\')
            if ($relativePath -iin $excludedFiles) {
                return $false
            }
            $pathParts = @($relativePath -split '[\\/]')
            $topDirectory = $pathParts[0]
            if ($pathParts.Count -gt 1 -and
                $topDirectory.StartsWith('.')) {
                return $false
            }
            return $topDirectory -notin $excludedDirectories
        })
    foreach ($sourceFile in $sourceFiles) {
        $relativePath = $sourceFile.FullName.Substring(
            $PSScriptRoot.Length
        ).TrimStart('\')
        $content = [IO.File]::ReadAllText($sourceFile.FullName)
        $compactFormatRequired = $sourceFile.Name -cne 'LICENSE'
        $turkishUnicode = '[\u00E7\u00C7\u011F\u011E\u0131\u0130' +
            '\u00F6\u00D6\u015F\u015E\u00FC\u00DC]'
        if ($sourceFile.Extension -in @('.ps1', '.psm1') -and
            [regex]::IsMatch($content, $turkishUnicode)) {
            throw [IO.InvalidDataException]::new(
                "Turkce Unicode karakter bulundu: $relativePath"
            )
        }
        if ([regex]::IsMatch(
            $content,
            '[\t ]+(?=\r?$)',
            [Text.RegularExpressions.RegexOptions]::Multiline
        )) {
            throw (Get-LocalizedText `
                -Key 'Installer.Error.SourceTrailingWhitespace' `
                -Arguments @($relativePath))
        }
        if ($compactFormatRequired -and [regex]::IsMatch(
            $content,
            '^[\t ]*\r?$',
            [Text.RegularExpressions.RegexOptions]::Multiline
        )) {
            throw (Get-LocalizedText `
                -Key 'Installer.Error.SourceBlankLine' `
                -Arguments @($relativePath))
        }
        if ($compactFormatRequired -and $content -match '[\r\n]\z') {
            throw (Get-LocalizedText `
                -Key 'Installer.Error.SourceTrailingNewline' `
                -Arguments @($relativePath))
        }
    }
    $defaultConfigPath = Join-Path $PSScriptRoot `
        $defaultConfigRelativePath
    if (Test-Path -LiteralPath $defaultConfigPath -PathType Leaf) {
        try {
            $defaultConfig = Get-Content -LiteralPath $defaultConfigPath `
                -Raw -Encoding UTF8 | ConvertFrom-InstallerJson
            if ($defaultConfig -isnot [pscustomobject] -and
                $defaultConfig -isnot [Collections.IDictionary]) {
                throw [IO.InvalidDataException]::new(
                    (Get-LocalizedText `
                        -Key 'WebUI.Error.DefaultConfigObjectRequired')
                )
            }
            $requiredSettings = [ordered]@{
                'direct.enable' = $false
                'openai.enable' = $false
                'ui.enable_community_sharing' = $false
                'ui.default_user_role' = 'pending'
                'auth.enable_api_keys' = $false
                'ui.default_models' = 'qwen3.5:4b'
                'ui.default_pinned_models' = 'qwen3.5:4b'
                'user.permissions.chat.temporary_enforced' = $true
                'audio.stt.whisper_model' = 'base'
                'audio.tts.engine' = 'openai'
                'audio.tts.model' = 'facebook/mms-tts-tur'
                'audio.tts.voice' = 'tr'
                'audio.tts.openai.api_base_url' = `
                    'http://127.0.0.1:8880/v1'
                'web.search.enable' = $true
                'web.search.engine' = 'duckduckgo'
                'image_generation.enable' = $true
                'image_generation.engine' = 'comfyui'
                'image_generation.model' = `
                    'flux1-schnell-fp8.safetensors'
                'image_generation.steps' = 4
                'image_generation.comfyui.base_url' = `
                    'http://127.0.0.1:8188'
                'images.edit.enable' = $false
            }
            foreach ($setting in $requiredSettings.GetEnumerator()) {
                $property = $defaultConfig.PSObject.Properties[
                    $setting.Key
                ]
                if ($null -eq $property -or
                    $property.Value -ne $setting.Value) {
                    throw [IO.InvalidDataException]::new(
                        (Get-LocalizedText `
                            -Key 'Installer.Error.OpenWebUISettingInvalid' `
                            -Arguments @($setting.Key))
                    )
                }
            }
            foreach ($property in $defaultConfig.PSObject.Properties) {
                if ($property.Name -match `
                    '(?i)(?:^|\.)(?:api_key|access_token|secret|password)$' `
                    -and $property.Value -is [string] -and
                    -not [string]::IsNullOrWhiteSpace($property.Value)) {
                    throw [IO.InvalidDataException]::new(
                        (Get-LocalizedText `
                            -Key 'Installer.Error.OpenWebUISecretPresent' `
                            -Arguments @($property.Name))
                    )
                }
            }
            $embeddedWorkflow = [string]$defaultConfig.PSObject.Properties[
                'image_generation.comfyui.workflow'
            ].Value | ConvertFrom-InstallerJson
            $workflowNodes = @($defaultConfig.PSObject.Properties[
                'image_generation.comfyui.nodes'
            ].Value)
            if ([string]$embeddedWorkflow.'1'.class_type -ne `
                    'CheckpointLoaderSimple' -or
                [string]$embeddedWorkflow.'1'.inputs.ckpt_name -ne `
                    'flux1-schnell-fp8.safetensors' -or
                $workflowNodes.Count -ne 7) {
                throw [IO.InvalidDataException]::new(
                    (Get-LocalizedText `
                        -Key 'Installer.Error.OpenWebUIWorkflowInvalid')
                )
            }
            $nodeTypes = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal
            )
            foreach ($mapping in $workflowNodes) {
                $type = [string]$mapping.type
                $key = [string]$mapping.key
                if ([string]::IsNullOrWhiteSpace($type) -or
                    -not $nodeTypes.Add($type) -or
                    [string]::IsNullOrWhiteSpace($key) -or
                    @($mapping.node_ids).Count -eq 0) {
                    throw [IO.InvalidDataException]::new(
                        (Get-LocalizedText `
                            -Key 'Installer.Error.OpenWebUIWorkflowInvalid')
                    )
                }
                foreach ($nodeId in @($mapping.node_ids)) {
                    $workflowNode = $embeddedWorkflow.PSObject.Properties[
                        [string]$nodeId
                    ]
                    if ($null -eq $workflowNode -or
                        $null -eq $workflowNode.Value.inputs.
                            PSObject.Properties[$key]) {
                        throw [IO.InvalidDataException]::new(
                            (Get-LocalizedText `
                                -Key `
                                'Installer.Error.OpenWebUIWorkflowInvalid')
                        )
                    }
                }
            }
            foreach ($requiredType in @(
                'model', 'prompt', 'width', 'height',
                'n', 'steps', 'seed'
            )) {
                if (-not $nodeTypes.Contains($requiredType)) {
                    throw [IO.InvalidDataException]::new(
                        (Get-LocalizedText `
                            -Key 'Installer.Error.OpenWebUIWorkflowInvalid')
                    )
                }
            }
        }
        catch {
            throw (Get-LocalizedText `
                -Key 'WebUI.Error.DefaultConfigInvalid' `
                -Arguments @(
                    $defaultConfigPath,
                    $_.Exception.Message
                ))
        }
    }
    $runMePath = Join-Path $PSScriptRoot 'RunMe.bat'
    $runMeContent = [IO.File]::ReadAllText(
        $runMePath,
        [Text.UTF8Encoding]::new($false)
    )
    if ($runMeContent -match '(?<!\r)\n') {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.BatchLineEndings')
    }
    if ($runMeContent -notmatch `
            ('(?im)^set\s+"WINLAMA_POWERSHELL=%SystemRoot%' +
                '\\System32\\WindowsPowerShell\\v1\.0' +
                '\\powershell\.exe"\s*$') -or
        $runMeContent -notmatch `
            ('(?im)^"%WINLAMA_POWERSHELL%"\s+.+-File\s+' +
                '"%~dp0Launcher\.ps1"') -or
        $runMeContent -notmatch `
            ('(?im)^\s*call\s+:LOAD_LOCALIZED_TEXT\s+' +
                '"Common\.Operation\.Summary"\s+' +
                '"WINLAMA_OPERATION_SUMMARY"\s*$') -or
        $runMeContent -notmatch `
            ('(?im)^\s*set\s+"WINLAMA_LINE=' +
                '!WINLAMA_OPERATION_SUMMARY!!WINLAMA_PADDING!"\s*$') -or
        $runMeContent -notmatch `
            'if "!WINLAMA_CLOSE!"=="CIKIS" exit /b 0' -or
        $runMeContent -match `
            'if /I "!WINLAMA_CLOSE!"=="CIKIS" exit /b 0') {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.BatchMenuInvalid')
    }
    if ([regex]::Matches(
        $runMeContent,
        '(?im)^\s*(?:start\s+|"%WINLAMA_POWERSHELL%"\s+)'
    ).Count -ne 1 -or $runMeContent -match '(?im)^\s*start\s+') {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.BatchNestedWindow')
    }
    $launcherPath = Join-Path $PSScriptRoot 'Launcher.ps1'
    $launcherContent = [IO.File]::ReadAllText($launcherPath)
    if ($launcherContent -match `
        '(?im)&\s+\$FilePath\s+@ArgumentList' -or
        $launcherContent -match '(?im)\|\s+Out-Host') {
        throw [IO.InvalidDataException]::new(
            'Launcher alt betik ciktisi borudan gecirilemez.'
        )
    }
    if ($launcherContent -notmatch `
            '(?s)function Invoke-LauncherProcess.*?' +
            'ProcessStartInfo\]::new\(\).*?' +
            'UseShellExecute\s*=\s*\$false.*?' +
            'CreateNoWindow\s*=\s*\$false.*?' +
            'RedirectStandardOutput\s*=\s*\$false.*?' +
            'RedirectStandardError\s*=\s*\$false.*?' +
            'RedirectStandardInput\s*=\s*\$false.*?' +
            '\[Diagnostics\.Process\]::new\(\).*?' +
            '\.Start\(\).*?' +
            '\.WaitForExit\(' -or
        $launcherContent -match 'Wait\s*=\s*\$true' -or
        $launcherContent -notmatch `
            'WINLAMA_UI_OK:Launcher\.ChildProcessContracts' -or
        $launcherContent -notmatch `
            'WINLAMA_PROCESS_OK:Launcher\.DirectChildExit' -or
        $launcherContent -notmatch `
            'WINLAMA_PROCESS_OK:Launcher\.RawProcessHandle' -or
        $launcherContent -notmatch `
            'WINLAMA_PROCESS_OK:Launcher\.ExitCodeRequired' -or
        $launcherContent -notmatch `
            'WINLAMA_UI_OK:Launcher\.LiveChildOutput' -or
        $launcherContent -notmatch `
            'WINLAMA_UI_FLOW_OK:Launcher\.LiveChildStage' -or
        $launcherContent -match 'SCRIPT_HEARTBEAT' -or
        $launcherContent -match 'Alt betik calisiyor') {
        throw [IO.InvalidDataException]::new(
            'Launcher renk koruyan alt betik baslatma sozlesmesi eksik.'
        )
    }
    $configResolverNames = @{
        'Install.ps1' = 'Resolve-InstallerConfigPath'
        'Launcher.ps1' = 'Resolve-LauncherConfigPath'
        'ModelManager.ps1' = 'Resolve-ManagerConfigPath'
        'Uninstall.ps1' = 'Resolve-UninstallConfigPath'
        'Repair.ps1' = 'Resolve-RepairConfigPath'
        'Start.ps1' = 'Resolve-WinlamaConfigPath'
        'Modules\UI\OpenWebUI.ps1' = `
            'Resolve-OpenWebUIConfigPath'
        'Modules\UI\ComfyUI.ps1' = 'Resolve-ComfyUIConfigPath'
    }
    $validatedConfigResolvers = `
        [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
    $scripts = @($sourceFiles | Where-Object {
            $_.Extension -in @('.ps1', '.psm1')
        })
    foreach ($script in $scripts) {
        $tokens = $null
        $errors = $null
        $scriptAst = `
            [Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$errors
        )
        if (@($errors).Count -gt 0) {
            $error = @($errors)[0]
            throw (Get-LocalizedText `
                -Key 'Installer.Error.PowerShellSyntax' `
                -Arguments @(
                    $script.FullName,
                    $error.Extent.StartLineNumber,
                    $error.Message
                ))
        }
        $scriptContent = [IO.File]::ReadAllText($script.FullName)
        $darkPrefix = 'Da' + 'rk'
        if ($scriptContent -match (
            '\b{0}(?:Blue|Green|Cyan|Red|Magenta|Yellow|Gray)\b' -f
                $darkPrefix
        )) {
            throw [IO.InvalidDataException]::new(
                "Dusuk kontrastli UI rengi: $($script.FullName)"
            )
        }
        $relativeScriptPath = $script.FullName.Substring(
            $PSScriptRoot.Length
        ).TrimStart('\')
        if ($relativeScriptPath -ceq 'Engine.ps1' -or
            $configResolverNames.ContainsKey($relativeScriptPath)) {
            if ($scriptContent -notmatch '(?i)\[CmdletBinding\(' -and
                $scriptContent -notmatch '(?i)\[CmdletBinding\(\)\]') {
                throw (Get-LocalizedText `
                    -Key 'Installer.Error.CmdletBindingMissing' `
                    -Arguments @($script.FullName))
            }
            if ($scriptContent -cnotmatch `
                    'WINLAMA_UI_OK:[A-Za-z]+\.BootstrapExactExit' -or
                $scriptContent -notmatch "'ISLEM OZETI'") {
                throw [IO.InvalidDataException]::new(
                    "Kesin kapanis/ozet sozlesmesi eksik: $($script.FullName)"
                )
            }
            if ($scriptContent -notmatch `
                '(?i)\[switch\]\s*\$ValidateOnly') {
                throw (Get-LocalizedText `
                    -Key 'Installer.Error.ValidateOnlyMissing' `
                    -Arguments @($script.FullName))
            }
            if ($scriptContent -notmatch `
                '(?i)Modules[\\/]UI[\\/]ConsoleUI\.psm1') {
                throw [IO.InvalidDataException]::new(
                    "UI standard modulu eksik: $($script.FullName)"
                )
            }
        }
        if ($configResolverNames.ContainsKey($relativeScriptPath)) {
            $resolverName = $configResolverNames[
                $relativeScriptPath
            ]
            $resolver = $scriptAst.Find({
                param($node)
                return $node -is
                    [Management.Automation.Language.FunctionDefinitionAst] `
                    -and $node.Name -ceq $resolverName
            }, $true)
            if ($null -eq $resolver) {
                throw [IO.InvalidDataException]::new(
                    "Config cozumleyici eksik: $relativeScriptPath"
                )
            }
            $resolverStrings = @($resolver.FindAll({
                param($node)
                return $node -is
                    [Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | ForEach-Object { $_.Value })
            if ($resolverStrings -inotcontains `
                    'Data\Configs\config.json' -or
                @($resolverStrings | Where-Object {
                    $_ -iin @(
                        'Configs\config.json',
                        'Data\config.json',
                        'config.json'
                    )
                }).Count -gt 0) {
                throw [IO.InvalidDataException]::new(
                    "Legacy config cozumleyici: $relativeScriptPath"
                )
            }
            $null = $validatedConfigResolvers.Add(
                $relativeScriptPath
            )
        }
        if ($relativeScriptPath -ine 'Modules\UI\ConsoleUI.psm1') {
            if ($scriptContent -match `
                '(?i)Write-Host\s+\(\s*[''\"][-=][''\"]\s*\*' -or
                $scriptContent -match `
                '(?i)Write-Host\s+\(\s*[''\"]\|') {
                throw [IO.InvalidDataException]::new(
                    "Standart disi UI cizimi: $relativeScriptPath"
                )
            }
        }
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.HighContrastPalette'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.ExactInteractiveCommands'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.BootstrapSummaries'
    if ($validatedConfigResolvers.Count -ne
        $configResolverNames.Count) {
        throw [IO.InvalidDataException]::new(
            'Tum giris config cozumleyicileri dogrulanamadi.'
        )
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.NoLegacyConfigResolvers'
    foreach ($jsonRel in @(
        'Data\Configs\config.json',
        'Data\Configs\openui-config.json',
        'Data\Workflows\Flux1_Schnell_API.json',
        'Data\Workflows\Wan2.1_T2V_Workflow.json'
    )) {
        $path = Join-Path $PSScriptRoot $jsonRel
        try {
            $null = Get-Content -LiteralPath $path -Raw `
                -Encoding UTF8 | ConvertFrom-InstallerJson
        }
        catch {
            throw (Get-LocalizedText `
                -Key 'Installer.Error.JsonInvalid' `
                -Arguments @($jsonRel)), $_.Exception
        }
    }
    foreach ($modulePath in @(
        Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Modules') `
            -Filter '*.psm1' | Sort-Object Name
    )) {
        Import-Module $modulePath.FullName -Force -ErrorAction Stop
    }
    $validationConfig = Get-Content -LiteralPath $ConfigPath `
        -Raw -Encoding UTF8 | ConvertFrom-InstallerJson
    $null = Test-DeploymentConfiguration -Config $validationConfig
    $invalidRequirementsConfig = $validationConfig |
        ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
    $invalidRequirementsConfig.ComfyUI.BaseRequirements[0] += '.invalid'
    $requirementsIdentityRejected = $false
    try {
        $null = Test-DeploymentConfiguration `
            -Config $invalidRequirementsConfig
    }
    catch {
        $requirementsIdentityRejected = $true
    }
    $commonModuleSource = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot 'Modules\00_Common.psm1')
    )
    if (-not $requirementsIdentityRejected -or
        $commonModuleSource -notmatch
            'baseRequirementsAlgorithm[\s\S]*SHA256\]::Create\(\)' -or
        $commonModuleSource -match 'SHA256\]::HashData') {
        throw [IO.InvalidDataException]::new(
            'ComfyUI temel requirements kimlik sozlesmesi gecersiz.'
        )
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Common.ComfyUIBaseRequirementsIdentity'
    $runtimePresent = Test-Path -LiteralPath `
        (Join-Path $PSScriptRoot 'Runtime')
    $modelsPresent = Test-Path -LiteralPath `
        (Join-Path $PSScriptRoot 'Models')
    if ($runtimePresent -xor $modelsPresent) {
        throw [IO.InvalidDataException]::new(
            'Runtime ve Models yalniz birlikte bulunabilir.'
        )
    }
    if ($runtimePresent) {
        $fullPackageConfig = $validationConfig |
            ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
        $fullPackageConfig.Bootstrap.PowerShell.InstallSource = 'Local'
        foreach ($descriptor in @($fullPackageConfig.Dependencies)) {
            if ([bool]$descriptor.Required) {
                $descriptor.InstallSource = 'Local'
            }
        }
        $fullPackageConfig.Models.InstallSource = 'Local'
        $fullPackageConfig.Models.LocalPackageImport.SelectedPackages = @(
            Get-InstallerLocalModelPackages `
                -Config $fullPackageConfig `
                -ModelNames @($fullPackageConfig.Models.Requested)
        ).PackagePath
        if (@($fullPackageConfig.Models.Requested).Count -gt 0 -and
            @($fullPackageConfig.Models.LocalPackageImport.
                SelectedPackages).Count -eq 0) {
            throw [IO.InvalidDataException]::new(
                'Tam paket yerel Ollama model secimi bos.'
            )
        }
        if ($fullPackageConfig.ComfyUI.Enabled) {
            $fullPackageConfig.ComfyUI.InstallSource = 'Local'
        }
        if (-not (Test-InstallerPackageRootIdentity `
            -Root $PSScriptRoot -Config $fullPackageConfig `
            -VerifyModelContentHash $true `
            -RequireSelfContainedLocalPayload)) {
            throw [IO.InvalidDataException]::new(
                'Tam Winlama paket kimligi dogrulanamadi.'
            )
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.PackageRootFull'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.RequestedModelContent'
    }
    else {
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.SourceOnlyRepository'
    }
    $null = Assert-ReportingEndpointProjectionContracts
    $webUIConfigPath = Join-Path $PSScriptRoot `
        ([string]$validationConfig.OpenWebUI.DefaultConfig.Path)
    $portConfig = $validationConfig | ConvertTo-Json -Depth 100 |
        ConvertFrom-Json
    $portContext = [pscustomobject]@{
        PackageRoot = $PSScriptRoot
        AppPath = $PSScriptRoot
        Config = $portConfig
    }
    $defaultPortHash = Get-OpenWebUIDefaultConfigurationHash `
        -Path $webUIConfigPath -Context $portContext
    $portConfig.Voice.Port = [int]$portConfig.Voice.Port + 1
    $voicePortHash = Get-OpenWebUIDefaultConfigurationHash `
        -Path $webUIConfigPath -Context $portContext
    $portConfig.Voice.Port = [int]$validationConfig.Voice.Port
    $portConfig.ComfyUI.Port = [int]$portConfig.ComfyUI.Port + 1
    $comfyPortHash = Get-OpenWebUIDefaultConfigurationHash `
        -Path $webUIConfigPath -Context $portContext
    if ($defaultPortHash -eq $voicePortHash -or
        $defaultPortHash -eq $comfyPortHash -or
        $voicePortHash -eq $comfyPortHash) {
        throw [IO.InvalidDataException]::new(
            'Open WebUI servis portlari yapilandirma kimligine bagli degil.'
        )
    }
    Write-Verbose 'WINLAMA_OPENWEBUI_OK:DynamicServicePorts'
    $localFixturePath = Join-Path $PSScriptRoot 'Install.ps1'
    $localFixtureHash = (Get-FileHash -LiteralPath $localFixturePath `
        -Algorithm SHA256).Hash
    $localFixtureDescriptor = [pscustomobject]@{
        Name = 'Validation fixture'
        InstallSource = 'Automatic'
        OfflinePath = 'Install.ps1'
        OfflineSha256 = ''
        Sha256 = $localFixtureHash
        Uri = 'https://www.python.org/fixture'
        PublisherSubjectContains = ''
    }
    $localFixtureContext = [pscustomobject]@{
        PackageRoot = $PSScriptRoot
        TempPath = Join-Path $env:TEMP 'WinlamaValidation'
        Config = [pscustomobject]@{
            Network = $validationConfig.Network
            Security = $validationConfig.Security
        }
    }
    $verifiedLocalFixture = Get-VerifiedArtifact `
        -Descriptor $localFixtureDescriptor `
        -Context $localFixtureContext `
        -DestinationFileName 'unused.fixture' -SuppressLog
    if ([IO.Path]::GetFullPath($verifiedLocalFixture) -ine
        [IO.Path]::GetFullPath($localFixturePath)) {
        throw [IO.InvalidDataException]::new(
            'Bos OfflineSha256 resmi SHA-256 degerini gecersiz kildi.'
        )
    }
    Write-Verbose 'WINLAMA_DEPENDENCY_OK:OfflineHashFallback'
    $pythonDependency = $validationConfig.Dependencies |
        Where-Object Name -eq 'Python' |
        Select-Object -First 1
    $pythonArguments = @($pythonDependency.InstallerArguments)
    $expectedPythonPath = Join-Path $env:LOCALAPPDATA `
        'Programs\Winlama\Dependencies\Python311'
    $configuredPythonPath = [Environment]::ExpandEnvironmentVariables(
        [string]$pythonDependency.InstallPath
    )
    if ($null -eq $pythonDependency -or
        [string]$pythonDependency.Uri -notlike `
            'https://www.python.org/ftp/python/*' -or
        [string]$pythonDependency.Sha256 -notmatch `
            '^[a-fA-F0-9]{64}$' -or
        [string]$pythonDependency.Scope -cne 'user' -or
        [IO.Path]::GetFullPath($configuredPythonPath) -ine
            [IO.Path]::GetFullPath($expectedPythonPath) -or
        '/quiet' -notin $pythonArguments -or
        'InstallAllUsers=0' -notin $pythonArguments -or
        'PrependPath=0' -notin $pythonArguments -or
        'AppendPath=0' -notin $pythonArguments -or
        'Include_launcher=0' -notin $pythonArguments -or
        'InstallLauncherAllUsers=0' -notin $pythonArguments -or
        'AssociateFiles=0' -notin $pythonArguments -or
        'Include_test=0' -notin $pythonArguments -or
        'Include_pip=1' -notin $pythonArguments -or
        'InstallAllUsers=1' -in $pythonArguments -or
        'PrependPath=1' -in $pythonArguments -or
        'AppendPath=1' -in $pythonArguments) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Dependencies.Python.SilentInstaller'))
    }
    Assert-DependencyOwnershipContracts -Config $validationConfig
    $portableUri = [uri][string]$validationConfig.ComfyUI.PortableUri
    if ([string]$validationConfig.ComfyUI.PortableVersion -ne `
            '0.32.0' -or
        $portableUri.AbsoluteUri -cne `
            'https://github.com/Comfy-Org/ComfyUI/releases/download/v0.32.0/ComfyUI_windows_portable_nvidia.7z' -or
        [string]$validationConfig.ComfyUI.PortableSha256 -ine `
            '642ba5e91c5f6310b11797acf79484d2248df5e09c6bb27696a25c99e68bdb72' -or
        [long]$validationConfig.ComfyUI.PortableSizeBytes -ne `
            2132254184) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('ComfyUI.PortablePackage'))
    }
    $dependencyContracts = @{
        'Visual C++ Runtime' = @(
            'Microsoft.VCRedist.2015+.x64',
            'https://download.visualstudio.microsoft.com/'
        )
        Python = @(
            'Python.Python.3.11',
            'https://www.python.org/ftp/python/3.11.9/'
        )
        Ollama = @(
            'Ollama.Ollama',
            'https://github.com/ollama/ollama/releases/download/'
        )
    }
    foreach ($name in $dependencyContracts.Keys) {
        $dependency = $validationConfig.Dependencies |
            Where-Object Name -eq $name | Select-Object -First 1
        $contract = $dependencyContracts[$name]
        if ($null -eq $dependency -or
            [string]$dependency.WingetId -cne $contract[0] -or
            [string]$dependency.Uri -notlike ($contract[1] + '*') -or
            [string]$dependency.Sha256 -notmatch `
                '^[a-fA-F0-9]{64}$' -or
            @($dependency.InstallerArguments).Count -eq 0) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldInvalid' `
                -Arguments @("Dependencies.$name.OfficialSource"))
        }
    }
    $powerShellPackage = $validationConfig.Bootstrap.PowerShell
    if ([string]$powerShellPackage.WingetId -cne `
            'Microsoft.PowerShell' -or
        [string]$powerShellPackage.Uri -notlike `
            'https://github.com/PowerShell/PowerShell/releases/*' -or
        [string]$powerShellPackage.Sha256 -notmatch `
            '^[a-fA-F0-9]{64}$') {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Bootstrap.PowerShell.OfficialSource'))
    }
    $skipConfig = $validationConfig | ConvertTo-Json -Depth 100 |
        ConvertFrom-Json
    Set-InstallerOptionalComponents -Config $skipConfig `
        -InstallOpenWebUI $false -InstallVoice $false
    $skipPython = $skipConfig.Dependencies |
        Where-Object Name -eq 'Python' | Select-Object -First 1
    if ($skipConfig.OpenWebUI.Enabled -or $skipConfig.Voice.Enabled -or
        $skipPython.Required) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Installer.OptionalComponents.Skip'))
    }
    $installConfig = $validationConfig | ConvertTo-Json -Depth 100 |
        ConvertFrom-Json
    Set-InstallerOptionalComponents -Config $installConfig `
        -InstallOpenWebUI $true -InstallVoice $true
    $installPython = $installConfig.Dependencies |
        Where-Object Name -eq 'Python' | Select-Object -First 1
    if (-not $installConfig.OpenWebUI.Enabled -or
        -not $installConfig.Voice.Enabled -or
        -not $installPython.Required) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Installer.OptionalComponents.Install'))
    }
    $ollamaSkipConfig = $validationConfig |
        ConvertTo-Json -Depth 100 | ConvertFrom-Json
    Set-InstallerOllamaComponent -Config $ollamaSkipConfig `
        -Enabled $false
    $ollamaSkipDependency = Get-InstallerOllamaDependency `
        -Config $ollamaSkipConfig
    if ($ollamaSkipConfig.Ollama.Enabled -or
        $ollamaSkipDependency.Required -or
        $ollamaSkipConfig.Models.SelectionMode -ne 'Skip' -or
        @($ollamaSkipConfig.Models.Requested).Count -ne 0) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Installer.OllamaComponent.Skip'))
    }
    $ollamaInstallConfig = $validationConfig |
        ConvertTo-Json -Depth 100 | ConvertFrom-Json
    Set-InstallerOllamaComponent -Config $ollamaInstallConfig `
        -Enabled $true
    $ollamaInstallDependency = Get-InstallerOllamaDependency `
        -Config $ollamaInstallConfig
    if (-not $ollamaInstallConfig.Ollama.Enabled -or
        -not $ollamaInstallDependency.Required) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Installer.OllamaComponent.Install'))
    }
    $webUIModuleContent = Get-Content -LiteralPath (Join-Path `
        $PSScriptRoot 'Modules\09_WebUI.psm1') -Raw -Encoding UTF8
    $installerContent = [IO.File]::ReadAllText($PSCommandPath)
    $packageIdentitySource = (Get-Command `
        Test-InstallerPackageRootIdentity -ErrorAction Stop).Definition
    $localPayloadTreeSource = (Get-Command `
        Assert-InstallerLocalPayloadTree -ErrorAction Stop).Definition
    $packageBootstrapSource = (Get-Command `
        Test-InstallerPackageRootBootstrapIdentity `
        -ErrorAction Stop).Definition
    $packageResolverSource = (Get-Command `
        Resolve-InstallerPackageRoot -ErrorAction Stop).Definition
    $sourceValidationSource = (Get-Command Invoke-SourceValidation `
        -ErrorAction Stop).Definition
    foreach ($requiredCall in @(
        'Test-InstallerPackageRootBootstrapIdentity',
        'Assert-InstallerLocalPayloadTree',
        'Test-InstallerRequestedOllamaPackageIdentity',
        'Get-InstallerComfyUISourceAvailability',
        'Test-InstallerOfflineArtifactIdentity'
    )) {
        if (-not $packageIdentitySource.Contains($requiredCall)) {
            throw [IO.InvalidDataException]::new(
                "Paket kimlik cagrisi eksik: $requiredCall"
            )
        }
    }
    foreach ($requiredCall in @(
        'Test-InstallerPackageTreeReparseFree',
        'Test-InstallerRuntimePackageCleanliness'
    )) {
        if (-not $localPayloadTreeSource.Contains($requiredCall)) {
            throw [IO.InvalidDataException]::new(
                "Tam paket agac cagrisi eksik: $requiredCall"
            )
        }
    }
    if (-not $localPayloadTreeSource.Contains(
            'if (-not $FullTreeAudit)'
        )) {
        throw [IO.InvalidDataException]::new(
            'Pending paket agaci lazy kapsami eksik.'
        )
    }
    if (-not $sourceValidationSource.Contains(
        '-VerifyModelContentHash $true'
    )) {
        throw [IO.InvalidDataException]::new(
            'Tam paket model icerik hash dogrulamasi eksik.'
        )
    }
    foreach ($requiredCall in @(
        'Assert-ApplicationSourcePayload',
        'Test-InstallerPackagePersistentCleanliness'
    )) {
        if (-not $packageBootstrapSource.Contains($requiredCall)) {
            throw [IO.InvalidDataException]::new(
                "Hizli paket kok cagrisi eksik: $requiredCall"
            )
        }
    }
    if ($packageBootstrapSource.Contains(
        'Test-InstallerComfyUIRuntimeLayout'
    ) -or $packageBootstrapSource.Contains(
        "-RelativePath 'Runtime'"
    ) -or $packageBootstrapSource.Contains(
        "-RelativePath 'Models'"
    )) {
        throw [IO.InvalidDataException]::new(
            'Hizli paket kok denetimi offline payload istiyor.'
        )
    }
    if (-not $packageResolverSource.Contains(
            'Test-InstallerPackageRootBootstrapIdentity'
        ) -or $packageResolverSource -match
            'Test-InstallerPackageRootIdentity\b') {
        throw [IO.InvalidDataException]::new(
            'Paket kok cozumlemesi agir dogrulama baslatiyor.'
        )
    }
    if (-not $packageIdentitySource.Contains(
        '-VerifyIdentity $VerifyModelContentHash'
    )) {
        throw [IO.InvalidDataException]::new(
            'Paket Runtime statik node kimligi eksik.'
        )
    }
    if (-not $packageBootstrapSource.Contains(
            '-RejectedPath ([ref]$rejectedPath)'
        ) -or -not $localPayloadTreeSource.Contains(
            '-RejectedPath ([ref]$rejectedPath)'
        ) -or -not $packageResolverSource.Contains(
            '-FailureReason ([ref]$failureReason)'
        ) -or -not $packageResolverSource.Contains(
            'Denenen kokler:'
        )) {
        throw [IO.InvalidDataException]::new(
            'Paket kok ret nedeni tanilamasi eksik.'
        )
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.PackageIdentityContracts'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.PackageRootFailureReason'
    $bootstrapIndex = $installerContent.LastIndexOf(
        '$initialPowerShellHandoff =',
        [StringComparison]::Ordinal
    )
    $prepareIndex = $installerContent.LastIndexOf(
        'Prepare-InstallerComfyUIRuntime -Config $config',
        [StringComparison]::Ordinal
    )
    if ($bootstrapIndex -lt 0 -or $prepareIndex -lt 0 -or
        $bootstrapIndex -gt $prepareIndex) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Installer.ZeroPcBootstrapOrdering'))
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Installer.ZeroPcBootstrapOrdering'
    if ($webUIModuleContent -notmatch `
            "--index-url', 'https://pypi.org/simple" -or
        $webUIModuleContent -notmatch `
            '\$Context\.Config\.Voice\.Port' -or
        $webUIModuleContent -notmatch `
            '\$Context\.Config\.ComfyUI\.Port' -or
        [string]$validationConfig.OpenWebUI.Version -ne '0.11.0') {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('OpenWebUI.OfficialPackageSource'))
    }
    Import-Module (Join-Path $PSScriptRoot `
        'Modules\09_WebUI.psm1') -Force -ErrorAction Stop `
        -Verbose:$false
    Assert-OpenWebUIFeatureProjectionContracts
    Write-Verbose 'WINLAMA_VALIDATION_OK:Startup.IndependentComponents'
    $imageModel = $validationConfig.ComfyUI.Catalog |
        Where-Object Name -eq 'FLUX.1-schnell' |
        Select-Object -First 1
    if ($null -eq $imageModel -or
        @($imageModel.Assets).Count -ne 1 -or
        [string]$imageModel.Assets[0].Uri -notlike `
            'https://huggingface.co/Comfy-Org/flux1-schnell/*' -or
        [string]$imageModel.Assets[0].Sha256 -ne
            'ead426278b49030e9da5df862994f25ce94ab2ee4df38b556ddddb3db093bf72' -or
        @($validationConfig.ComfyUI.Catalog | Where-Object {
            $_.Name -eq 'FLUX.1-dev'
        }).Count -ne 0) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('ComfyUI.Catalog.PublicImageModel'))
    }
    $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot `
        'Data\Workflows\Flux1_Schnell_API.json') -Raw `
        -Encoding UTF8 | ConvertFrom-InstallerJson
    if ([string]$workflow.'1'.class_type -ne `
            'CheckpointLoaderSimple' -or
        [string]$workflow.'1'.inputs.ckpt_name -ne `
            'flux1-schnell-fp8.safetensors' -or
        [int]$workflow.'5'.inputs.steps -ne 4 -or
        [double]$workflow.'5'.inputs.cfg -ne 1) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Data.Workflows.Flux1Schnell'))
    }
    Invoke-InstallerChildValidations `
        -MinimumVersion ([version](
            $validationConfig.MinimumPowerShellVersion
        ))
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Validation.SourceCompleted' `
        -Arguments @($scripts.Count)) `
        -Color Green
}
function Stop-InstallerBoundedProcessTree {
    param([Parameter(Mandatory)][object]$Process)
    $taskkillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    if (-not (Test-Path -LiteralPath $taskkillPath -PathType Leaf)) {
        throw [IO.FileNotFoundException]::new(
            'Guvenilir taskkill.exe bulunamadi.',
            $taskkillPath
        )
    }
    $killer = $null
    try {
        $killer = Start-Process -FilePath $taskkillPath `
            -ArgumentList @('/PID', [string]$Process.Id, '/T', '/F') `
            -WindowStyle Hidden -PassThru
        if (-not $killer.WaitForExit(10000)) {
            Stop-Process -Id $killer.Id -Force `
                -ErrorAction SilentlyContinue
            $null = $killer.WaitForExit(2000)
            throw [TimeoutException]::new(
                'taskkill sureci 10 saniyede tamamlanmadi.'
            )
        }
        if ($killer.ExitCode -ne 0) {
            throw [InvalidOperationException]::new(
                "taskkill sureci basarisiz oldu: $($killer.ExitCode)"
            )
        }
        if (-not $Process.WaitForExit(5000)) {
            throw [TimeoutException]::new(
                'Alt surec agaci sonlandirma sonrasi kapanmadi.'
            )
        }
    }
    finally {
        if ($null -ne $killer) {
            $killer.Dispose()
        }
    }
}
function Read-InstallerProcessOutputTail {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1024, 1048576)][int]$MaximumBytes = 65536
    )
    $stream = $null
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return ''
        }
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            $share
        )
        $length = [long]$stream.Length
        if ($length -lt 1) {
            return ''
        }
        $count = [int][Math]::Min([long]$MaximumBytes, $length)
        $offset = $length - $count
        $null = $stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $buffer = [byte[]]::new($count)
        $read = 0
        while ($read -lt $count) {
            $block = $stream.Read($buffer, $read, $count - $read)
            if ($block -lt 1) {
                break
            }
            $read += $block
        }
        if ($read -lt 1) {
            return ''
        }
        if ($offset -eq 0 -and $read -ge 3 -and
            $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and
            $buffer[2] -eq 0xBF) {
            return [Text.Encoding]::UTF8.GetString(
                $buffer,
                3,
                $read - 3
            )
        }
        if ($offset -eq 0 -and $read -ge 2 -and
            $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) {
            return [Text.Encoding]::Unicode.GetString(
                $buffer,
                2,
                $read - 2
            )
        }
        if ($offset -eq 0 -and $read -ge 2 -and
            $buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF) {
            return [Text.Encoding]::BigEndianUnicode.GetString(
                $buffer,
                2,
                $read - 2
            )
        }
        $start = 0
        if ($offset -gt 0) {
            while ($start -lt $read -and
                ($buffer[$start] -band 0xC0) -eq 0x80) {
                $start++
            }
        }
        try {
            $encoding = [Text.UTF8Encoding]::new($false, $true)
            return $encoding.GetString(
                $buffer,
                $start,
                $read - $start
            )
        }
        catch [Text.DecoderFallbackException] {
            return [Text.Encoding]::Default.GetString(
                $buffer,
                $start,
                $read - $start
            )
        }
    }
    catch {
        return ''
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}
function Add-InstallerProcessOutputTail {
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Destination,
        [ValidateRange(1024, 65536)]
        [int]$MaximumCharacters = 16384
    )
    foreach ($path in $Paths) {
        $value = Read-InstallerProcessOutputTail -Path $path
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        $value = $value.Trim()
        if ($value.Length -gt $MaximumCharacters) {
            $value = $value.Substring(
                $value.Length - $MaximumCharacters
            )
        }
        $Destination.Add($value)
        Write-Verbose $value
    }
}
function Invoke-BootstrapProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 1800,
        [switch]$CaptureOutput,
        [ValidateSet('Normal', 'Hidden')][string]$WindowStyle = 'Normal',
        [ref]$CapturedOutput,
        [string]$Activity = '',
        [ValidateRange(1, 60)]
        [int]$HeartbeatIntervalSeconds = 15,
        [scriptblock]$ProcessStarter,
        [scriptblock]$TreeTerminator,
        [scriptblock]$ElapsedProvider,
        [scriptblock]$HeartbeatWriter
    )
    $stdoutPath = $null
    $stderrPath = $null
    $captured = [Collections.Generic.List[string]]::new()
    $nativeArguments = @($ArgumentList | ForEach-Object {
        ConvertTo-WindowsCommandLineArgument -Argument ([string]$_)
    })
    $start = @{
        FilePath = $FilePath
        ArgumentList = $nativeArguments
        PassThru = $true
        WindowStyle = $WindowStyle
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $start.WorkingDirectory = $WorkingDirectory
    }
    if ($CaptureOutput) {
        $captureId = [guid]::NewGuid().ToString('N')
        $stdoutPath = Join-Path $env:TEMP "winlama-$captureId.out"
        $stderrPath = Join-Path $env:TEMP "winlama-$captureId.err"
        $start.RedirectStandardOutput = $stdoutPath
        $start.RedirectStandardError = $stderrPath
    }
    $process = $null
    $outputCollected = $false
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    if ($null -eq $ElapsedProvider) {
        $ElapsedProvider = { $stopwatch.Elapsed }.GetNewClosure()
    }
    if ([string]::IsNullOrWhiteSpace($Activity)) {
        $Activity = [IO.Path]::GetFileName($FilePath)
    }
    try {
        $process = if ($null -ne $ProcessStarter) {
            & $ProcessStarter -StartParameters $start
        }
        else {
            Start-Process @start
        }
        if ($process -is [Diagnostics.Process]) {
            $null = $process.Handle
        }
        $nextHeartbeat = [double]$HeartbeatIntervalSeconds
        while (-not $process.WaitForExit(500)) {
            $elapsedValues = @(& $ElapsedProvider)
            if ($elapsedValues.Count -ne 1 -or
                $elapsedValues[0] -isnot [TimeSpan]) {
                throw 'Alt surec sure saglayicisi gecersiz.'
            }
            $elapsed = [TimeSpan]$elapsedValues[0]
            if ($elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timeoutException = [TimeoutException]::new(
                    (Get-LocalizedText `
                        -Key 'Common.Error.ProcessTimeout' `
                        -Arguments @($FilePath))
                )
                try {
                    if ($null -ne $TreeTerminator) {
                        & $TreeTerminator -Process $process
                    }
                    else {
                        Stop-InstallerBoundedProcessTree `
                            -Process $process
                    }
                }
                catch {
                    $timeoutException.Data['TerminationError'] =
                        $_.Exception.ToString()
                }
                if ($process -is [Diagnostics.Process]) {
                    try {
                        if (-not $process.HasExited) {
                            $process.Kill()
                            if (-not $process.WaitForExit(10000)) {
                                throw 'Alt surec dogrudan sonlandirilamadi.'
                            }
                        }
                    }
                    catch {
                        $timeoutException.Data[
                            'FallbackTerminationError'
                        ] = $_.Exception.ToString()
                    }
                }
                throw $timeoutException
            }
            if ($elapsed.TotalSeconds -lt $nextHeartbeat) {
                continue
            }
            $heartbeat = [pscustomobject]@{
                Activity = $Activity
                FilePath = $FilePath
                ProcessId = [int]$process.Id
                ElapsedSeconds = [int][Math]::Floor(
                    $elapsed.TotalSeconds
                )
            }
            if ($null -eq $HeartbeatWriter) {
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.Process.Waiting' `
                    -MessageArguments @(
                        $heartbeat.Activity,
                        $heartbeat.ElapsedSeconds
                    )
            }
            else {
                & $HeartbeatWriter $heartbeat
            }
            $nextHeartbeat = $elapsed.TotalSeconds +
                $HeartbeatIntervalSeconds
        }
        if ($CaptureOutput) {
            Add-InstallerProcessOutputTail `
                -Paths @($stdoutPath, $stderrPath) `
                -Destination $captured
            $outputCollected = $true
        }
        if ($null -ne $CapturedOutput) {
            $CapturedOutput.Value = $captured.ToArray() -join `
                [Environment]::NewLine
        }
        return $process.ExitCode
    }
    catch {
        if ($CaptureOutput -and -not $outputCollected) {
            Add-InstallerProcessOutputTail `
                -Paths @($stdoutPath, $stderrPath) `
                -Destination $captured
        }
        $exceptionText = $_.Exception.ToString()
        foreach ($key in $_.Exception.Data.Keys) {
            $exceptionText += [Environment]::NewLine +
                ('{0}: {1}' -f $key, $_.Exception.Data[$key])
        }
        if ($exceptionText.Length -gt 16384) {
            $exceptionText = $exceptionText.Substring(
                $exceptionText.Length - 16384
            )
        }
        if (-not [string]::IsNullOrWhiteSpace($exceptionText)) {
            $captured.Add($exceptionText)
        }
        if ($null -ne $CapturedOutput) {
            $CapturedOutput.Value = $captured.ToArray() -join `
                [Environment]::NewLine
        }
        throw
    }
    finally {
        $stopwatch.Stop()
        if ($null -ne $process -and $process -is [IDisposable]) {
            $process.Dispose()
        }
        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                Remove-Item -LiteralPath $path -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}
function Assert-PowerShellBootstrapPackage {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Package,
        [Parameter(Mandatory)][string]$ExpectedHash
    )
    $actualHash = (Get-FileHash -LiteralPath $Path `
        -Algorithm SHA256).Hash
    if ($actualHash -ine $ExpectedHash) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.PowerShellHashInvalid')
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.PowerShellSignatureInvalid')
    }
    if ($signature.SignerCertificate.Subject -cne $Package.Publisher) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.PowerShellPublisherInvalid')
    }
}
function Install-PowerShellBootstrapMsi {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Package,
        [Parameter(Mandatory)][string]$ExpectedHash
    )
    Assert-PowerShellBootstrapPackage -Path $Path `
        -Package $Package -ExpectedHash $ExpectedHash
    $arguments = @(
        '/i', $Path, '/qn', '/norestart',
        'ALLUSERS=1', 'ADD_PATH=1', 'REGISTER_MANIFEST=1',
        'ENABLE_PSREMOTING=0', 'USE_MU=0'
    )
    $exitCode = Invoke-BootstrapProcess -FilePath 'msiexec.exe' `
        -ArgumentList $arguments -CaptureOutput
    if ($exitCode -notin @(0, 3010)) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.PowerShellInstallFailed' `
            -Arguments @($exitCode))
    }
    $installed = Get-PowerShellExecutable `
        -MinimumVersion ([version]$Package.Version) -MachineOnly
    if ($null -eq $installed) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.PowerShellUnavailable' `
            -Arguments @($Package.Version))
    }
}
function Install-PowerShellBootstrap {
    param(
        [pscustomobject]$Config,
        [ValidateSet('Prompt', 'Local', 'Online', 'Automatic')]
        [string]$SourceSelection = 'Prompt'
    )
    $SourceSelection = ConvertTo-InstallerSourceSelection `
        -Selection $SourceSelection
    $package = $Config.Bootstrap.PowerShell
    if ($SourceSelection -eq 'Prompt') {
        $sourceProperty = $package.PSObject.Properties['InstallSource']
        $SourceSelection = if ($null -ne $sourceProperty -and
            [string]$sourceProperty.Value -in @(
                'Local', 'Online', 'Automatic'
            )) {
            [string]$sourceProperty.Value
        }
        else {
            'Automatic'
        }
    }
    $localPath = Join-Path $script:InstallerPackageRoot `
        ([string]$package.OfflinePath)
    if ($SourceSelection -ne 'Online' -and
        (Test-Path -LiteralPath $localPath -PathType Leaf)) {
        try {
            Write-WinlamaUIStatus -Level STEP `
                -Message (Get-LocalizedText `
                    -Key 'Installer.PowerShell.LocalVerifying')
            Install-PowerShellBootstrapMsi -Path $localPath `
                -Package $package `
                -ExpectedHash ([string]$package.OfflineSha256)
            Write-InstallerLog -Level INFO `
                -Message 'Installer.PowerShell.LocalVerified'
            Write-WinlamaUIStatus -Level SUCCESS `
                -Message (Get-LocalizedText `
                    -Key 'Installer.PowerShell.LocalInstalled')
            return
        }
        catch {
            if ($SourceSelection -eq 'Local') {
                throw
            }
            Write-InstallerLog -Level WARN `
                -Message 'Installer.PowerShell.LocalFallback' `
                -Exception $_.Exception
            Write-WinlamaUIStatus -Level WARN -Message (
                Get-LocalizedText `
                    -Key 'Installer.PowerShell.LocalOnlineFallback'
            )
        }
    }
    elseif ($SourceSelection -eq 'Local') {
        throw (New-NonRetryableException -Message (
            Get-LocalizedText `
                -Key 'Dependencies.Error.LocalSourceMissing' `
                -Arguments @($package.OfflinePath)
        ))
    }
    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($null -ne $winget) {
        try {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.PowerShell.WingetInstalling'
            $arguments = @(
                'install', '--exact', '--id', $package.WingetId,
                '--version', [string]$package.WingetVersion,
                '--source', 'winget',
                '--silent', '--scope', 'machine',
                '--accept-package-agreements',
                '--accept-source-agreements',
                '--disable-interactivity'
            )
            $exitCode = Invoke-BootstrapProcess `
                -FilePath $winget.Source -ArgumentList $arguments `
                -CaptureOutput
            $installed = Get-PowerShellExecutable `
                -MinimumVersion ([version]$package.Version) `
                -MachineOnly
            if ($exitCode -in @(0, -1978335189) -and
                $null -ne $installed) {
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.PowerShell.WingetVerified'
                return
            }
        }
        catch {
            Write-InstallerLog -Level WARN `
                -Message 'Installer.PowerShell.WingetFallback' `
                -Exception $_.Exception
        }
    }
    $root = Resolve-InstallerPath -Path $Config.Paths.Root
    $bootstrapPath = Join-Path $root 'temp\bootstrap'
    [IO.Directory]::CreateDirectory($bootstrapPath) | Out-Null
    $installerPath = Join-Path $bootstrapPath 'PowerShell-x64.msi'
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12
    $downloadDelays = @(15, 60)
    $downloadAttempts = $downloadDelays.Count + 1
    $downloadTimeout = [Math]::Max(
        30,
        [Math]::Min(
            300,
            [int]$Config.Network.OperationTimeoutSeconds
        )
    )
    $downloaded = $false
    $ProgressPreference = 'SilentlyContinue'
    Write-InstallerLog -Level INFO `
        -Message 'Installer.PowerShell.DownloadingMsi'
    try {
        for ($attempt = 0; $attempt -le $downloadDelays.Count; $attempt++) {
            try {
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.PowerShell.DownloadAttempt' `
                    -MessageArguments @(
                        ($attempt + 1),
                        $downloadAttempts,
                        $downloadTimeout
                    )
                Remove-Item -LiteralPath $installerPath -Force `
                    -ErrorAction SilentlyContinue
                Invoke-WebRequest -Uri $package.Uri `
                    -OutFile $installerPath -UseBasicParsing `
                    -TimeoutSec $downloadTimeout
                $downloaded = $true
                break
            }
            catch {
                if ($attempt -ge $downloadDelays.Count) {
                    throw
                }
                Write-InstallerLog -Level WARN `
                    -Message 'Installer.PowerShell.DownloadRetry' `
                    -MessageArguments @($downloadDelays[$attempt]) `
                    -Exception $_.Exception
                Start-Sleep -Seconds $downloadDelays[$attempt]
            }
        }
        if (-not $downloaded) {
            throw (Get-LocalizedText `
                -Key 'Installer.Error.PowerShellDownloadFailed')
        }
        Install-PowerShellBootstrapMsi -Path $installerPath `
            -Package $package -ExpectedHash ([string]$package.Sha256)
    }
    finally {
        Remove-Item -LiteralPath $installerPath -Force `
            -ErrorAction SilentlyContinue
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.PowerShell.MsiInstalled'
}
function Test-InstallerPowerShellHandoffRequired {
    param(
        [Parameter(Mandatory)][version]$CurrentVersion,
        [Parameter(Mandatory)][version]$MinimumVersion
    )
    return $CurrentVersion -lt $MinimumVersion
}
function Get-InstallerCurrentPowerShellExecutable {
    $path = $null
    try {
        $path = (Get-Process -Id $PID -ErrorAction Stop).Path
    }
    catch {
        Write-Verbose ('Gecerli PowerShell yolu okunamadi: {0}' -f `
            $_.Exception.Message)
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        $name = if ($PSVersionTable.PSVersion.Major -ge 6) {
            'pwsh.exe'
        }
        else {
            'powershell.exe'
        }
        $path = Join-Path $PSHOME $name
    }
    return [IO.Path]::GetFullPath($path)
}
function Invoke-InstallerSameConsoleProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [ValidateRange(100, 5000)]
        [int]$PollIntervalMilliseconds = 500,
        [scriptblock]$ProcessStarter
    )
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        throw [ArgumentException]::new(
            'Alt PowerShell calistirilabilir yolu bos olamaz.'
        )
    }
    $commandLine = @($ArgumentList | ForEach-Object {
        ConvertTo-WindowsCommandLineArgument -Argument ([string]$_)
    }) -join ' '
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $commandLine
    $startInfo.WorkingDirectory = $script:InstallerPackageRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $startInfo.RedirectStandardInput = $false
    $process = $null
    try {
        $process = if ($null -eq $ProcessStarter) {
            $createdProcess = [Diagnostics.Process]::new()
            $createdProcess.StartInfo = $startInfo
            try {
                if (-not $createdProcess.Start()) {
                    throw 'Alt PowerShell sureci baslatilamadi.'
                }
                $createdProcess
            }
            catch {
                $createdProcess.Dispose()
                throw
            }
        }
        else {
            & $ProcessStarter $startInfo
        }
        if ($null -eq $process) {
            throw 'Alt PowerShell sureci olusturulamadi.'
        }
        try {
            $processId = [int]$process.Id
        }
        catch {
            throw [InvalidOperationException]::new(
                'Alt PowerShell surec kimligi okunamadi.',
                $_.Exception
            )
        }
        if ($processId -le 0 -or
            $null -eq $process.PSObject.Methods['WaitForExit'] -or
            $null -eq $process.PSObject.Properties['HasExited'] -or
            $null -eq $process.PSObject.Properties['ExitCode']) {
            throw [InvalidOperationException]::new(
                'Alt PowerShell surec taniticisi gecersiz.'
            )
        }
        while ($true) {
            try {
                $waitResult = $process.WaitForExit(
                    $PollIntervalMilliseconds
                )
            }
            catch {
                throw [InvalidOperationException]::new(
                    'Alt PowerShell sureci beklenemedi.',
                    $_.Exception
                )
            }
            if ($waitResult -isnot [bool]) {
                throw [InvalidOperationException]::new(
                    'Alt PowerShell bekleme sonucu gecersiz.'
                )
            }
            if ([bool]$waitResult) {
                break
            }
        }
        try {
            if (-not [bool]$process.HasExited) {
                throw [InvalidOperationException]::new(
                    'Alt PowerShell cikisi dogrulanamadi.'
                )
            }
            if ($null -ne $process.PSObject.Methods['Refresh']) {
                $process.Refresh()
            }
            $exitCodeValue = $process.ExitCode
            if ($null -eq $exitCodeValue) {
                throw [InvalidOperationException]::new(
                    'Alt PowerShell cikis kodu bos dondu.'
                )
            }
            $exitCode = [int]$exitCodeValue
        }
        catch {
            throw [InvalidOperationException]::new(
                'Alt PowerShell cikis kodu okunamadi.',
                $_.Exception
            )
        }
        return [pscustomobject]@{
            ProcessId = $processId
            ExitCode = $exitCode
        }
    }
    finally {
        if ($null -ne $process -and
            $null -ne $process.PSObject.Methods['Dispose']) {
            $process.Dispose()
        }
    }
}
function Invoke-InstallerPowerShellRuntimeHandoff {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [ValidateSet('Initial', 'Resume')]
        [string]$Reason
    )
    $minimumVersion = [version]$Config.MinimumPowerShellVersion
    if (-not (Test-InstallerPowerShellHandoffRequired `
        -CurrentVersion $PSVersionTable.PSVersion `
        -MinimumVersion $minimumVersion)) {
        $current = Get-InstallerCurrentPowerShellExecutable
        $Config.Installation.PowerShellPath = $current
        return [pscustomobject]@{
            ExitCode = 0
            HandedOff = $false
            Path = $current
        }
    }
    $pwsh = Get-PowerShellExecutable -MinimumVersion $minimumVersion `
        -MachineOnly
    if ([string]::IsNullOrWhiteSpace($pwsh)) {
        Write-InstallerLog -Level INFO `
            -Message 'Installer.PowerShell.Required' `
            -MessageArguments @($minimumVersion)
        $sourceProperty = $Config.Bootstrap.PowerShell.PSObject.
            Properties['InstallSource']
        $sourceSelection = if ($null -ne $sourceProperty -and
            [string]$sourceProperty.Value -in @(
                'Local', 'Online', 'Automatic'
            )) {
            [string]$sourceProperty.Value
        }
        else {
            'Automatic'
        }
        Install-PowerShellBootstrap -Config $Config `
            -SourceSelection $sourceSelection
        $pwsh = Get-PowerShellExecutable `
            -MinimumVersion $minimumVersion -MachineOnly
    }
    if ([string]::IsNullOrWhiteSpace($pwsh)) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.PowerShellUnavailable' `
            -Arguments @($minimumVersion))
    }
    $Config.Installation.PowerShellPath = $pwsh
    $effectiveConfigPath = Save-EffectiveInstallerConfig -Config $Config
    Write-Verbose ('WINLAMA_POWERSHELL_HANDOFF:{0}:{1}' -f `
        $Reason, $pwsh)
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath, '-ConfigPath', $effectiveConfigPath,
        '-Resume'
    )
    if ($ForceRepair) {
        $arguments += '-ForceRepair'
    }
    $arguments += '-NoPause'
    if ($GenerateReport) {
        $arguments += '-GenerateReport'
    }
    if ($VoiceLanguageSelection -ne 'Prompt') {
        $arguments += '-VoiceLanguageSelection'
        $arguments += $VoiceLanguageSelection
    }
    if ($LocalPayloadHashSelection -ne 'Prompt') {
        $arguments += '-LocalPayloadHashSelection'
        $arguments += $LocalPayloadHashSelection
    }
    $arguments += '-SessionId'
    $arguments += $SessionId
    if (-not [string]::IsNullOrWhiteSpace($InitiatingUserSid)) {
        $arguments += '-InitiatingUserSid'
        $arguments += $InitiatingUserSid
    }
    if (-not [string]::IsNullOrWhiteSpace($InitiatingUserProfile)) {
        $arguments += '-InitiatingUserProfile'
        $arguments += $InitiatingUserProfile
    }
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $arguments += '-Verbose'
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.PowerShell.HandoffStarting' `
        -MessageArguments @($minimumVersion)
    $childProcess = Invoke-InstallerSameConsoleProcess `
        -FilePath $pwsh -ArgumentList $arguments
    if (@($childProcess).Count -ne 1 -or
        $null -eq $childProcess.PSObject.Properties['ExitCode']) {
        throw 'Alt PowerShell sonucu tek ve gecerli degil.'
    }
    $exitCode = [int]$childProcess.ExitCode
    Write-InstallerLog -Level INFO `
        -Message 'Installer.PowerShell.HandoffCompleted' `
        -MessageArguments @($exitCode)
    return [pscustomobject]@{
        ExitCode = $exitCode
        HandedOff = $true
        Path = $pwsh
    }
}
function Complete-InstallerPowerShellHandoff {
    param([Parameter(Mandatory)][int]$ExitCode)
    if ($NoPause) {
        return
    }
    $completion = switch ($ExitCode) {
        0 {
            [pscustomobject]@{
                Key = 'Installer.Operation.Completed'
                Level = 'SUCCESS'
            }
        }
        2 {
            [pscustomobject]@{
                Key = 'Installer.Operation.HandoffCancelled'
                Level = 'SKIP'
            }
        }
        3 {
            [pscustomobject]@{
                Key = 'Installer.Operation.HandoffIncomplete'
                Level = 'WARN'
            }
        }
        default {
            [pscustomobject]@{
                Key = 'Installer.Operation.Failed'
                Level = 'ERROR'
            }
        }
    }
    Complete-WinlamaUIOperation `
        -Summary (Get-LocalizedText -Key $completion.Key) `
        -Level $completion.Level -Command CIKIS
}
function Assert-InstallerSameConsoleProcessContracts {
    $script:InstallerConsoleProcessFixture = $null
    $fixtureProcess = [pscustomobject]@{
        Id = 4545
        ExitCode = 17
        HasExited = $false
        WaitCalls = 0
        WaitTimeouts = [Collections.Generic.List[int]]::new()
        Refreshed = $false
        Disposed = $false
    }
    $fixtureProcess | Add-Member -MemberType ScriptMethod `
        -Name WaitForExit -Value {
            param([int]$Milliseconds)
            $this.WaitCalls++
            $this.WaitTimeouts.Add($Milliseconds)
            if ($this.WaitCalls -ge 3) {
                $this.HasExited = $true
                return $true
            }
            return $false
        }
    $fixtureProcess | Add-Member -MemberType ScriptMethod `
        -Name Refresh -Value { $this.Refreshed = $true }
    $fixtureProcess | Add-Member -MemberType ScriptMethod `
        -Name Dispose -Value { $this.Disposed = $true }
    $fixtureArguments = @(
        '-NoProfile', '-File', 'C:\Fixture Path\Install.ps1',
        '-ConfigPath', 'C:\Fixture Path\effective config.json',
        '-NoPause'
    )
    $expectedCommandLine = @($fixtureArguments | ForEach-Object {
        ConvertTo-WindowsCommandLineArgument -Argument $_
    }) -join ' '
    $result = Invoke-InstallerSameConsoleProcess `
        -FilePath 'C:\Program Files\PowerShell\7\pwsh.exe' `
        -ArgumentList $fixtureArguments -ProcessStarter {
            param([Diagnostics.ProcessStartInfo]$StartInfo)
            $script:InstallerConsoleProcessFixture = $StartInfo
            return $fixtureProcess
        }
    $fixture = $script:InstallerConsoleProcessFixture
    if (@($result).Count -ne 1 -or $result.ExitCode -ne 17 -or
        $result.ProcessId -ne 4545 -or
        $null -eq $fixture -or [bool]$fixture.UseShellExecute -or
        [bool]$fixture.CreateNoWindow -or
        [bool]$fixture.RedirectStandardOutput -or
        [bool]$fixture.RedirectStandardError -or
        [bool]$fixture.RedirectStandardInput -or
        $fixture.WorkingDirectory -cne $script:InstallerPackageRoot -or
        $fixture.FileName -cne `
            'C:\Program Files\PowerShell\7\pwsh.exe' -or
        [string]$fixture.Arguments -cne $expectedCommandLine -or
        [string]$fixture.Arguments -match 'Out-Host|2>&1' -or
        $fixtureProcess.WaitCalls -ne 3 -or
        @($fixtureProcess.WaitTimeouts | Where-Object {
            $_ -ne 500
        }).Count -ne 0 -or -not $fixtureProcess.HasExited -or
        -not $fixtureProcess.Refreshed -or
        -not $fixtureProcess.Disposed) {
        throw 'Installer alt PowerShell konsol/renk sozlesmesi gecersiz.'
    }
    $invalidHandleRejected = $false
    $invalidProcess = [pscustomobject]@{
        Id = 4646
        HasExited = $false
        ExitCode = 0
        Disposed = $false
    }
    $invalidProcess | Add-Member -MemberType ScriptMethod `
        -Name Dispose -Value { $this.Disposed = $true }
    try {
        $null = Invoke-InstallerSameConsoleProcess `
            -FilePath 'pwsh.exe' -ArgumentList @('-NoProfile') `
            -ProcessStarter { $invalidProcess }
    }
    catch [InvalidOperationException] {
        $invalidHandleRejected = $true
    }
    if (-not $invalidHandleRejected -or -not $invalidProcess.Disposed) {
        throw 'Installer gecersiz surec taniticisi sozlesmesi gecersiz.'
    }
    $nullExitRejected = $false
    $nullExitProcess = [pscustomobject]@{
        Id = 4747
        HasExited = $true
        ExitCode = $null
        Disposed = $false
    }
    $nullExitProcess | Add-Member -MemberType ScriptMethod `
        -Name WaitForExit -Value { param([int]$Milliseconds) $true }
    $nullExitProcess | Add-Member -MemberType ScriptMethod `
        -Name Dispose -Value { $this.Disposed = $true }
    try {
        $null = Invoke-InstallerSameConsoleProcess `
            -FilePath 'pwsh.exe' -ArgumentList @('-NoProfile') `
            -ProcessStarter { $nullExitProcess }
    }
    catch [InvalidOperationException] {
        $nullExitRejected = $true
    }
    if (-not $nullExitRejected -or -not $nullExitProcess.Disposed) {
        throw 'Installer bos cikis kodu sozlesmesi gecersiz.'
    }
    $liveCommand =
        "[Console]::WriteLine('WINLAMA_INSTALLER_HANDOFF_STAGE_FIXTURE'); exit 9"
    $liveCommandBytes = [Text.Encoding]::Unicode.GetBytes($liveCommand)
    $liveArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-EncodedCommand',
        [Convert]::ToBase64String($liveCommandBytes)
    )
    $liveResult = Invoke-InstallerSameConsoleProcess `
        -FilePath (Get-InstallerCurrentPowerShellExecutable) `
        -ArgumentList $liveArguments
    if (@($liveResult).Count -ne 1 -or $liveResult.ExitCode -ne 9 -or
        $liveResult.ProcessId -le 0) {
        throw 'Installer canli alt PowerShell cikis sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_PROCESS_OK:Installer.HandoffRawProcess'
    Write-Verbose 'WINLAMA_PROCESS_OK:Installer.HandoffExitCode'
    Write-Verbose 'WINLAMA_PROCESS_OK:Installer.HandoffSingleResult'
    Write-Verbose 'WINLAMA_UI_OK:Install.HandoffLiveChildOutput'
    Write-Verbose 'WINLAMA_UI_FLOW_OK:Install.HandoffLiveChildStage'
    return $true
}
function Assert-InstallerPowerShellHandoffContracts {
    $null = Assert-InstallerSameConsoleProcessContracts
    $minimum = [version]'7.6.0'
    if (-not (Test-InstallerPowerShellHandoffRequired `
            -CurrentVersion ([version]'5.1.0') `
            -MinimumVersion $minimum) -or
        (Test-InstallerPowerShellHandoffRequired `
            -CurrentVersion $minimum -MinimumVersion $minimum) -or
        (Test-InstallerPowerShellHandoffRequired `
            -CurrentVersion ([version]'7.7.0') `
            -MinimumVersion $minimum)) {
        throw 'PowerShell handoff surum siniri gecersiz.'
    }
    $source = (Get-Command `
        Invoke-InstallerPowerShellRuntimeHandoff `
        -ErrorAction Stop).Definition
    $completionSource = (Get-Command `
        Complete-InstallerPowerShellHandoff `
        -ErrorAction Stop).Definition
    $bootstrapSource = (Get-Command Install-PowerShellBootstrap `
        -ErrorAction Stop).Definition
    $processSource = (Get-Command Invoke-InstallerSameConsoleProcess `
        -ErrorAction Stop).Definition
    $scriptSource = [IO.File]::ReadAllText($PSCommandPath)
    if ($source -match '2>&1|\|\s*Out-Host' -or
        $source -match "'-ElevatedHost'" -or
        $source -match 'if\s*\(\s*\$NoPause\s*\)' -or
        $source -match '&\s*\$pwsh\s+@arguments' -or
        $source -notmatch 'Invoke-InstallerSameConsoleProcess' -or
        $source -notmatch '@\(\$childProcess\)\.Count\s*-ne\s*1' -or
        $source -notmatch '\$childProcess\.ExitCode' -or
        $processSource -notmatch 'ProcessStartInfo\]::new\(\)' -or
        $processSource -notmatch 'UseShellExecute\s*=\s*\$false' -or
        $processSource -notmatch 'CreateNoWindow\s*=\s*\$false' -or
        $processSource -notmatch `
            'RedirectStandardOutput\s*=\s*\$false' -or
        $processSource -notmatch `
            'RedirectStandardError\s*=\s*\$false' -or
        $processSource -notmatch `
            'RedirectStandardInput\s*=\s*\$false' -or
        $processSource -match 'Start-Process|Out-Host|2>&1' -or
        $processSource -notmatch '\.WaitForExit\(' -or
        $source -notmatch '\$arguments\s*\+=\s*''-NoPause''' -or
        $source -notmatch "'-VoiceLanguageSelection'" -or
        $completionSource -notmatch 'Complete-WinlamaUIOperation' -or
        $completionSource -notmatch '\$NoPause' -or
        $completionSource -match 'UserInteractive' -or
        $bootstrapSource -match 'TimeoutSec\s+1800' -or
        $bootstrapSource -notmatch
            'Installer\.PowerShell\.DownloadAttempt' -or
        $bootstrapSource -notmatch
            'Installer\.PowerShell\.DownloadRetry' -or
        $scriptSource -notmatch (
            '(?s)\$initialPowerShellHandoff\.HandedOff\)\s*\{\s*' +
            'Complete-InstallerPowerShellHandoff'
        ) -or $scriptSource -notmatch (
            '(?s)\$resumePowerShellHandoff\.HandedOff\)\s*\{\s*' +
            'Complete-InstallerPowerShellHandoff'
        ) -or
        (Get-LocalizedText -Key 'Installer.Unattended.Ready') -notmatch
            'CIKIS' -or
        (Get-LocalizedText -Key 'Installer.Unattended.ReadyNoPause') -match
            'CIKIS') {
        throw 'PowerShell handoff konsol devri gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.PowerShellEarlyHandoff'
    Write-Verbose 'WINLAMA_UI_OK:Install.HandoffConsoleInherited'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Installer.SingleInputOwner'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.PowerShellDownloadBounded'
    return $true
}
try {
    Write-InstallerBanner
    Write-InstallerLog -Level INFO `
        -Message 'Installer.Started'
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        throw (Get-LocalizedText -Key 'Common.Error.WindowsOnly')
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw (Get-LocalizedText -Key 'Common.Error.Windows64Only')
    }
    if ($ValidateOnly) {
        $null = Assert-WinlamaUIStandard
        $null = Assert-InstallerBootstrapInputContracts
        $null = Assert-InstallerSourceTableContracts
        $null = Assert-WinlamaUIInputFormatter -Formatter {
            param([string]$Value)
            Format-InstallerBootstrapInputLine -Value $Value
        }
        Assert-InstallerElevationContracts
        Assert-InstallerLogSchemaContracts
        Write-InstallerLog -Level STEP `
            -Message 'Installer.ComfyUI.ModelPreservationVerifying'
        $null = Assert-InstallerDiagnosticPathContracts
        Import-Module (Join-Path $PSScriptRoot `
            'Modules\01_Logging.psm1') -Force -ErrorAction Stop
        $null = Assert-DeploymentLogSchemaContracts
        Import-Module (Join-Path $PSScriptRoot `
            'Modules\07_Ollama.psm1') -Force -ErrorAction Stop
        $null = Assert-OllamaApplicationContracts
        $null = Assert-StopProcessesFromPathContracts
        $validationSnapshot = Get-InstallerValidationSnapshot
        Write-Verbose (Get-LocalizedText `
            -Key 'Verbose.Validation.Started' `
            -Arguments @('Install.ps1'))
        Write-InstallerLog -Level INFO `
            -Message 'Installer.Validation.SourceStarted'
        Assert-InstallerPackageRootSourceContracts
        Invoke-SourceValidation
        Assert-EngineStateJsonContracts
        Assert-HardwarePolicyContracts
        Assert-GpuValidationContracts
        Assert-ModelInstallSourceContracts
        Assert-DeploymentSecurityContracts
        Show-InstallerLocalizedInputValidation
        Write-Verbose 'WINLAMA_UI_OK:Install.AllPrompts'
        $null = Assert-InstallerLocalPayloadHashSelectionContracts
        Assert-InstallerDeferredSourceVerificationContracts
        Assert-InstallerPowerShellHandoffContracts
        $null = Assert-InstallerPythonDetectionContracts `
            -Config $script:InstallerConfiguration
        Assert-InstallerComfyUIRuntimePowerShellContracts
        Assert-InstallerComfyUIAssetSizeContracts
        Assert-InstallerComfyUIDestinationActionContracts
        Assert-InstallerComfyUIEmbeddedModelMigrationContracts
        Assert-InstallerComfyUICleanupContracts
        Assert-InstallerComfyUIEnvironmentVerificationContracts
        Assert-InstallerComfyUISourceProbeBoundaryContracts
        Assert-InstallerComfyUIPostPreparationContracts
        Assert-InstallerCompletionContracts
        $validationHardware = [pscustomobject]@{
            Cpu = 'Validation CPU'
            LogicalCores = 16
            RamGB = 32
            Gpu = 'Validation GPU'
            VramGB = 8
            NvidiaDetected = $true
            NvidiaSmiReady = $true
            FreeDiskGB = 256
        }
        if (-not (Test-InstallerOperatingSystemContract `
            -Version ([version]'10.0.19045') -Architecture X64 `
            -ProductType 1) -or
            -not (Test-InstallerOperatingSystemContract `
                -Version ([version]'10.0.22631') -Architecture X64 `
                -ProductType 1) -or
            (Test-InstallerOperatingSystemContract `
                -Version ([version]'10.0.20348') -Architecture X64 `
                -ProductType 3) -or
            (Test-InstallerOperatingSystemContract `
                -Version ([version]'10.0.26100') -Architecture X64 `
                -ProductType 3) -or
            (Test-InstallerOperatingSystemContract `
                -Version ([version]'10.0.19044') -Architecture X64 `
                -ProductType 1) -or
            (Test-InstallerOperatingSystemContract `
                -Version ([version]'10.0.22631') -Architecture X86 `
                -ProductType 1) -or
            (Test-InstallerOperatingSystemContract `
                -Version ([version]'10.0.22631') -Architecture X64 `
                -ProductType 2)) {
            throw 'Windows istemci ortami sozlesmesi gecersiz.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.OperatingSystemContract'
        if (-not (Test-InstallerNvidiaSmiResult -ExitCode 0 `
            -Rows @('NVIDIA RTX Validation, 8192')) -or
            (Test-InstallerNvidiaSmiResult -ExitCode 1 `
                -Rows @('NVIDIA RTX Validation, 8192')) -or
            (Test-InstallerNvidiaSmiResult -ExitCode 0 -Rows @()) -or
            (Test-InstallerNvidiaSmiResult -ExitCode 0 `
                -Rows @('name, memory.total'))) {
            throw 'nvidia-smi saglik kaniti sozlesmesi gecersiz.'
        }
        $hardwareDefinition = (Get-Command Get-InstallerHardwareProfile `
            -ErrorAction Stop).Definition
        $ollamaProbeDefinition = (Get-Command `
            Test-InstallerOllamaInstalled -ErrorAction Stop).Definition
        if ($hardwareDefinition -notmatch 'OperationTimeoutSec\s+3' -or
            $hardwareDefinition -notmatch 'Invoke-BootstrapProcess' -or
            $hardwareDefinition -match '&\s*\$nvidiaSmi' -or
            $ollamaProbeDefinition -notmatch 'Invoke-BootstrapProcess' -or
            $ollamaProbeDefinition -match '&\s*\$cli') {
            throw 'Donanim probe timeout sozlesmesi gecersiz.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.NvidiaSmiEvidence'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.BoundedHardwareProbe'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.BoundedOllamaProbe'
        $componentQueue = [Collections.Generic.Queue[string]]::new()
        $componentQueue.Enqueue('')
        $componentQueue.Enqueue('E')
        $componentQueue.Enqueue('evet')
        $componentQueue.Enqueue(' EVET ')
        $componentQueue.Enqueue('EVET')
        $componentChoice = Read-InstallerComponentSelection `
            -SectionKey 'Installer.Section.OllamaSelection' `
            -DescriptionKey 'Installer.Ollama.Description' `
            -PromptKey 'Installer.Prompt.OllamaSelection' `
            -InputReader { $componentQueue.Dequeue() }.GetNewClosure()
        if ($componentChoice -cne 'Install') {
            throw 'Kurulum kesin bilesen secimi fiksturu basarisiz.'
        }
        $componentNoQueue = [Collections.Generic.Queue[string]]::new()
        foreach ($value in @('', 'H', 'hayir', ' HAYIR ', 'HAYIR')) {
            $componentNoQueue.Enqueue($value)
        }
        $componentNoChoice = Read-InstallerComponentSelection `
            -SectionKey 'Installer.Section.OllamaSelection' `
            -DescriptionKey 'Installer.Ollama.Description' `
            -PromptKey 'Installer.Prompt.OllamaSelection' `
            -InputReader {
                $componentNoQueue.Dequeue()
            }.GetNewClosure()
        if ($componentNoChoice -cne 'Skip') {
            throw 'Kurulum kesin HAYIR secimi fiksturu basarisiz.'
        }
        Write-Verbose 'WINLAMA_UI_OK:Install.ExactTokens'
        $modelQueue = [Collections.Generic.Queue[string]]::new()
        $modelQueue.Enqueue('')
        $modelQueue.Enqueue('0')
        $modelChoice = Read-InstallerModelSelection `
            -Config $script:InstallerConfiguration `
            -Hardware $validationHardware `
            -InputReader { $modelQueue.Dequeue() }.GetNewClosure()
        if ($modelChoice -cne 'Exit') {
            throw 'Kurulum bos model secimi fiksturu basarisiz.'
        }
        Write-Verbose 'WINLAMA_UI_OK:Install.StrictInput'
        Show-InstallerModelSelectionLayout `
            -Config $script:InstallerConfiguration `
            -Hardware $validationHardware
        if ((Get-Command Show-InstallerModelSelectionLayout `
                -ErrorAction Stop).Definition -match
            'Get-InstallerSourceModelNames') {
            throw 'Model sorusu kaynak paket agacini erken taradi.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.LazySourceModelCount'
        $emptySourceFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $emptySourceFixture.ModelTransfer.ImportSearchDirectories = @(
            '_validation_missing\Models'
        )
        $emptySourceNames = @(Get-InstallerSourceModelNames `
            -Config $emptySourceFixture)
        if ($emptySourceNames.Count -ne 0) {
            throw 'Bos yerel model paket listesi reddedilemedi.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.EmptySourceModelNames'
        Write-Verbose 'WINLAMA_UI_OK:Install.Models'
        $comfyCatalog = @(Show-InstallerComfyUICatalog `
            -Config $script:InstallerConfiguration `
            -ProjectRoot $PSScriptRoot -Hardware $validationHardware)
        if ($comfyCatalog.Count -eq 0) {
            throw 'ComfyUI kurulum model ekrani bos.'
        }
        $comfyQueue = [Collections.Generic.Queue[string]]::new()
        $comfyQueue.Enqueue('')
        $comfyQueue.Enqueue('S')
        $skippedComfy = @(Read-InstallerComfyUISelection `
            -Config $script:InstallerConfiguration `
            -ProjectRoot $PSScriptRoot -Hardware $validationHardware `
            -InputReader { $comfyQueue.Dequeue() }.GetNewClosure())
        if ($skippedComfy.Count -ne 0) {
            throw 'Kurulum bos ComfyUI secimi fiksturu basarisiz.'
        }
        $comfyPrompt = Get-LocalizedText `
            -Key 'Installer.Prompt.ComfyUISelection'
        if ($comfyPrompt -notmatch 'A' -or $comfyPrompt -notmatch 'S' -or
            $comfyPrompt -notmatch '0') {
            throw 'ComfyUI model secim istemi gecersiz.'
        }
        Write-InstallerLine -Text $comfyPrompt -Color Cyan
        Write-InstallerRule
        Write-Verbose 'WINLAMA_UI_OK:Install.ComfyUIModels'
        $disabledComfyConfig = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $disabledComfyConfig.ComfyUI.Enabled = $false
        $disabledSelection = @(Read-InstallerComfyUISelection `
            -Config $disabledComfyConfig -ProjectRoot $PSScriptRoot `
            -Hardware $validationHardware -Value '1')
        if ($disabledSelection.Count -ne 1) {
            throw 'Disabled ComfyUI explicit install selection failed.'
        }
        $failFastComfyConfig = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
        $failFastComfyConfig.ComfyUI.InstallPath = `
            'C:\Fixture\MissingComfyUI'
        $failFastComfyConfig.ComfyUI.ModelsPath = `
            'C:\Fixture\MissingComfyModels'
        $failFastCases = @(
            [pscustomobject]@{
                Interactive = $true
                Key = 'Installer.Selection.NoInstalledModels'
                Value = 'L'
            },
            [pscustomobject]@{
                Interactive = $false
                Key = 'Installer.Selection.NoInstalledModels'
                Value = 'L'
            },
            [pscustomobject]@{
                Interactive = $true
                Key = 'Installer.Selection.NoSourceModels'
                Value = 'K'
            },
            [pscustomobject]@{
                Interactive = $false
                Key = 'Installer.Selection.NoSourceModels'
                Value = 'K'
            }
        )
        foreach ($case in $failFastCases) {
            $failure = $null
            try {
                $null = Read-InstallerComfyUISelection `
                    -Config $failFastComfyConfig `
                    -ProjectRoot 'C:\Fixture\MissingProject' `
                    -Hardware $validationHardware -Value $case.Value `
                    -Interactive $case.Interactive -InputReader {
                        throw 'Explicit ComfyUI secimi prompt acti.'
                    }
            }
            catch {
                $failure = $_.Exception
            }
            if ($null -eq $failure -or
                $failure.Message -cne (Get-LocalizedText -Key $case.Key)) {
                throw 'ComfyUI explicit L/K fail-fast sozlesmesi gecersiz.'
            }
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ComfyUIExplicitFailFast'
        $localValidationModel = [pscustomobject][ordered]@{
            Name = 'Validation-Local-Model'
            LocalDirectory = 'Validation\LocalModel'
            Type = 'LocalModel'
            Format = 'local-directory'
            DownloadSizeGB = 1.0
            WorkingSpaceGB = 0.0
            License = ''
            Description = 'Validation local model'
            LocalOnly = $true
            Assets = @()
        }
        $emptyComfySyncConfig = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $emptyComfySyncConfig.ComfyUI.ModelsPath = `
            '_validation_missing\ComfyUI'
        $emptyMissingComfyModels = @(
            Get-InstallerMissingComfyUIModels -Models @() `
                -Config $emptyComfySyncConfig `
                -ProjectRoot $PSScriptRoot -VerifyHash:$false
        )
        Invoke-InstallerComfyUIModelSetup -Models @() `
            -Config $emptyComfySyncConfig `
            -ProjectRoot $PSScriptRoot
        if ($emptyMissingComfyModels.Count -ne 0) {
            throw 'Bos ComfyUI bekleyen model listesi reddedildi.'
        }
        $emptyComfySyncCount = Sync-InstallerComfyUIRequestedModels `
            -Models @($localValidationModel) `
            -Config $emptyComfySyncConfig -ProjectRoot $PSScriptRoot
        if ($emptyComfySyncCount -ne 0 -or
            @($emptyComfySyncConfig.ComfyUI.Requested).Count -ne 0) {
            throw 'Bos ComfyUI kurulum sonucu temizlenemedi.'
        }
        $assetlessCatalogConfig = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $assetlessCatalogConfig.ComfyUI.Catalog += $localValidationModel
        $assetlessCatalog = @(Get-InstallerComfyUICatalog `
            -Config $assetlessCatalogConfig -ProjectRoot $PSScriptRoot)
        $assetlessAddRejected = $false
        try {
            Add-InstallerComfyUISelectionToCatalog `
                -Models @($localValidationModel) `
                -Config $disabledComfyConfig
        }
        catch {
            $assetlessAddRejected = $true
        }
        if ($assetlessCatalog.Name -icontains
                $localValidationModel.Name -or
            -not $assetlessAddRejected -or
            (Test-InstallerComfyUIModelInstalled `
                -Model $localValidationModel `
                -Config $assetlessCatalogConfig `
                -ProjectRoot $PSScriptRoot) -or
            (Test-InstallerComfyUILocalModelSource `
                -Model $localValidationModel `
                -ProjectRoot $PSScriptRoot)) {
            throw 'Assetless ComfyUI modeli canonical kabul edildi.'
        }
        $targetFixtureRoot = 'C:\Fixture\ComfyModels'
        $targetFixtureParent = Join-Path $targetFixtureRoot 'FLUX'
        $targetFixturePath = Join-Path $targetFixtureParent `
            'model.safetensors'
        $safeTargetFixture = `
            Assert-InstallerComfyUIAssetTargetSafety `
                -Root $targetFixtureRoot -Target $targetFixturePath `
                -ReparseProbe { param($Candidate) return $false }
        $targetReparseRejected = $false
        try {
            $null = Assert-InstallerComfyUIAssetTargetSafety `
                -Root $targetFixtureRoot -Target $targetFixturePath `
                -ReparseProbe {
                    param($Candidate)
                    return [IO.Path]::GetFullPath($Candidate).Equals(
                        $targetFixtureParent,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }.GetNewClosure()
        }
        catch {
            $targetReparseRejected = $true
        }
        if ($safeTargetFixture.Parent -ine $targetFixtureParent -or
            $safeTargetFixture.Target -ine $targetFixturePath -or
            -not $targetReparseRejected) {
            throw 'ComfyUI model hedef reparse korumasi gecersiz.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.EmptyComfyUISync'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.EmptyPendingComfyModels'
        $disabledComfyConfig.ComfyUI.Requested = `
            @($disabledSelection.Name)
        $null = Test-DeploymentConfiguration `
            -Config $disabledComfyConfig
        Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUIExplicitInstall'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ComfyUIAssetlessRejected'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ComfyUIAssetTargetSafety'
        foreach ($surface in @(
            @('Installer.Section.OllamaSelection',
                'Installer.Ollama.Description',
                'Installer.Prompt.OllamaSelection'),
            @('Installer.Section.ComfyUISelection',
                'Installer.ComfyUI.Description',
                'Installer.Prompt.ComfyUIInstallSelection'),
            @('Installer.Section.OpenWebUISelection',
                'Installer.OpenWebUI.Description',
                'Installer.Prompt.OpenWebUISelection'),
            @('Installer.Section.VoiceSelection',
                'Installer.Voice.Description',
                'Installer.Prompt.VoiceSelection'),
            @('Installer.Section.DefaultConfigSelection',
                'Installer.DefaultConfig.Description',
                'Installer.Prompt.DefaultConfigSelection'),
            @('Installer.Section.OptionalErrorMode',
                'Installer.OptionalErrorMode.Description',
                'Installer.Prompt.OptionalErrorMode')
        )) {
            Show-InstallerComponentSelectionLayout `
                -SectionKey $surface[0] `
                -DescriptionKey $surface[1] -PromptKey $surface[2]
        }
        if ((Read-InstallerVoiceSelection `
            -Config $script:InstallerConfiguration `
            -Selection Install) -cne 'Install' -or
            (Read-InstallerOptionalErrorMode `
                -Selection Continue) -cne 'Continue' -or
            (Read-InstallerOptionalErrorMode `
                -Selection Stop) -cne 'Stop') {
            throw 'Ses veya istege bagli hata modu sozlesmesi gecersiz.'
        }
        $null = Assert-InstallerVoiceLanguageContracts `
            -Config $script:InstallerConfiguration
        $installerSourceText = [IO.File]::ReadAllText($PSCommandPath)
        $dependencyPromptIndex = $installerSourceText.LastIndexOf(
            '$dependencySourceResult = Read-InstallerDependencySources',
            [StringComparison]::Ordinal
        )
        $hashPromptIndex = $installerSourceText.LastIndexOf(
            '$hashSelection = Read-InstallerLocalPayloadHashSelection',
            [StringComparison]::Ordinal
        )
        $optionalPromptIndex = $installerSourceText.LastIndexOf(
            '$errorMode = Read-InstallerOptionalErrorMode',
            [StringComparison]::Ordinal
        )
        $sourceVerificationStartText =
            "'Installer.SourceVerification." + "Starting'"
        $initialHandoffIndex = $installerSourceText.LastIndexOf(
            '$initialPowerShellHandoff =',
            [StringComparison]::Ordinal
        )
        $sourceVerificationStartIndex =
            $installerSourceText.IndexOf(
                $sourceVerificationStartText,
                $initialHandoffIndex,
                [StringComparison]::Ordinal
            )
        $deferredPackageCall =
            '$null = Assert-InstallerDeferredPackageIdentity'
        $deferredPackageIndex = $installerSourceText.IndexOf(
            $deferredPackageCall,
            $initialHandoffIndex,
            [StringComparison]::Ordinal
        )
        $sourceVerificationIndex = $installerSourceText.IndexOf(
            'Invoke-InstallerDeferredSourceVerification',
            $sourceVerificationStartIndex,
            [StringComparison]::Ordinal
        )
        $sourceVerificationCompletedText =
            "'Installer.SourceVerification." + "Completed'"
        $sourceVerificationCompletedIndex =
            $installerSourceText.IndexOf(
                $sourceVerificationCompletedText,
                $deferredPackageIndex,
                [StringComparison]::Ordinal
            )
        $comfyMutationIndex = $installerSourceText.IndexOf(
            '$comfyRuntimeReady = Install-InstallerComfyUIRuntime',
            $sourceVerificationCompletedIndex,
            [StringComparison]::Ordinal
        )
        if ($dependencyPromptIndex -lt 0 -or
            $hashPromptIndex -le $dependencyPromptIndex -or
            $optionalPromptIndex -le $hashPromptIndex -or
            $initialHandoffIndex -le $optionalPromptIndex -or
            $deferredPackageIndex -le $initialHandoffIndex -or
            $sourceVerificationStartIndex -le $optionalPromptIndex -or
            $sourceVerificationStartIndex -le $initialHandoffIndex -or
            $sourceVerificationIndex -le
                $sourceVerificationStartIndex -or
            $deferredPackageIndex -le $sourceVerificationIndex -or
            $sourceVerificationCompletedIndex -le
                $deferredPackageIndex -or
            $comfyMutationIndex -le
                $sourceVerificationCompletedIndex) {
            throw 'SHA-256 ve istege bagli hata soru sirasi gecersiz.'
        }
        $resumeHandoffIndex = $installerSourceText.LastIndexOf(
            '$resumePowerShellHandoff =',
            [StringComparison]::Ordinal
        )
        $resumeSourceVerificationStartIndex =
            $installerSourceText.IndexOf(
                $sourceVerificationStartText,
                $resumeHandoffIndex,
                [StringComparison]::Ordinal
            )
        $resumePackageIndex = $installerSourceText.LastIndexOf(
            $deferredPackageCall,
            [StringComparison]::Ordinal
        )
        $resumeSourceIndex = $installerSourceText.LastIndexOf(
            '$dependencySourceResult = ' +
                'Set-InstallerResumeDependencySources',
            [StringComparison]::Ordinal
        )
        $resumeComfyMutationIndex = $installerSourceText.LastIndexOf(
            '$comfyRuntimeReady = Install-InstallerComfyUIRuntime',
            [StringComparison]::Ordinal
        )
        $resumeSourceVerificationCompletedIndex =
            $installerSourceText.IndexOf(
                $sourceVerificationCompletedText,
                $resumePackageIndex,
                [StringComparison]::Ordinal
            )
        if ($resumeHandoffIndex -lt 0 -or
            $resumeSourceVerificationStartIndex -le
                $resumeHandoffIndex -or
            $resumeSourceIndex -le
                $resumeSourceVerificationStartIndex -or
            $resumePackageIndex -le $resumeSourceIndex -or
            $resumeSourceVerificationCompletedIndex -le
                $resumePackageIndex -or
            $resumeComfyMutationIndex -le
                $resumeSourceVerificationCompletedIndex) {
            throw 'Resume agir paket dogrulamasi sirasi gecersiz.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.OptionalPromptLast'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.HashPromptBeforeOptional'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.PackageVerificationDeferred'
        $componentFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        Set-InstallerOptionalComponents -Config $componentFixture `
            -InstallOpenWebUI $true -InstallVoice $false
        $pythonFixture = $componentFixture.Dependencies |
            Where-Object Name -eq 'Python' | Select-Object -First 1
        if ($componentFixture.Voice.Enabled -or
            -not $componentFixture.OpenWebUI.Enabled -or
            -not $pythonFixture.Required) {
            throw 'Open WebUI ve ses bagimsiz secim sozlesmesi gecersiz.'
        }
        Set-InstallerOptionalComponents -Config $componentFixture `
            -InstallOpenWebUI $true -InstallVoice $true
        if (-not $componentFixture.Voice.Enabled) {
            throw 'Ses kurulum secimi uygulanamadi.'
        }
        Set-InstallerOptionalComponents -Config $componentFixture `
            -InstallOpenWebUI $false -InstallVoice $true
        if ($componentFixture.OpenWebUI.Enabled -or
            -not $componentFixture.Voice.Enabled -or
            -not $pythonFixture.Required) {
            throw 'Ses servisi Open WebUI secimine bagli kaldi.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.VoiceIndependent'
        $voiceSourceNotice = Get-LocalizedText `
            -Key 'Installer.Voice.OnlineRequired'
        if ($voiceSourceNotice -notmatch 'Hugging Face' -or
            $installerSourceText -notmatch
                "-Message 'Installer\.Voice\.OnlineRequired'") {
            throw 'Ses resmi cevrimici kaynak bildirimi eksik.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.VoiceOfficialOnline'
        $dependencySourceFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $dependencyDescriptors = @(
            Get-InstallerCommonDependencyDescriptors `
                -Config $dependencySourceFixture
        )
        $missingPromptReader = { throw 'Gereksiz kaynak sorusu soruldu.' }
        $quickMissingPrompt = Read-InstallerDependencySource `
            -Descriptor $dependencyDescriptors[0] -Selection Prompt `
            -Interactive $true -VerifyLocalIdentity $false `
            -ArtifactVerifier { return $false } `
            -InputReader $missingPromptReader
        $exactMissingPrompt = Read-InstallerDependencySource `
            -Descriptor $dependencyDescriptors[0] -Selection Prompt `
            -Interactive $true -VerifyLocalIdentity $true `
            -ArtifactVerifier { return $false } `
            -InputReader $missingPromptReader
        if ($dependencyDescriptors.Count -lt 2 -or
            $quickMissingPrompt -cne 'Automatic' -or
            $exactMissingPrompt -cne 'Online' -or
            (Read-InstallerDependencySource `
                -Descriptor $dependencyDescriptors[0] `
                -Selection online) -cne 'Online' -or
            (Read-InstallerDependencySource `
                -Descriptor $dependencyDescriptors[0] `
                -Selection automatic) -cne 'Online' -or
            (Read-InstallerDependencySource `
                -Descriptor $dependencyDescriptors[0] `
                -Selection automatic `
                -VerifyLocalIdentity $false) -cne 'Automatic') {
            throw 'Ortak bagimlilik kaynak secim sozlesmesi gecersiz.'
        }
        $missingDependencySourceFixture = $dependencySourceFixture |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        foreach ($descriptor in @(
            Get-InstallerCommonDependencyDescriptors `
                -Config $missingDependencySourceFixture
        )) {
            $descriptor.OfflinePath = `
                '_validation_missing\dependency-installer.bin'
        }
        $dependencyLocalFailed = $false
        try {
            $null = Read-InstallerDependencySources `
                -Config $missingDependencySourceFixture -Selection local `
                -InstalledTester { param($Descriptor) $false }
        }
        catch {
            $dependencyLocalFailed = $true
        }
        if (-not $dependencyLocalFailed) {
            throw 'Eksik ortak yerel kaynak kati modda reddedilmedi.'
        }
        $ollamaBeforeCommonSource = [string](
            Get-InstallerOllamaDependency `
                -Config $dependencySourceFixture
        ).InstallSource
        if ((Read-InstallerDependencySources `
            -Config $dependencySourceFixture -Selection automatic `
            -InstalledTester { param($Descriptor) $false }) -cne
            'Configured') {
            throw 'Ortak kaynak toplu projeksiyonu basarisiz.'
        }
        $commonSourceInvalid = @(
            Get-InstallerCommonDependencyDescriptors `
                -Config $dependencySourceFixture | Where-Object {
                [string]$_.InstallSource -cne 'Online'
            }
        ).Count -gt 0
        if ($commonSourceInvalid -or
            [string](Get-InstallerOllamaDependency `
                -Config $dependencySourceFixture).InstallSource -cne
                $ollamaBeforeCommonSource) {
            throw 'Ortak kaynak projeksiyon sozlesmesi gecersiz.'
        }
        $individualSourceFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $individualDescriptors = @(
            Get-InstallerCommonDependencyDescriptors `
                -Config $individualSourceFixture
        )
        $individualPromptState = [pscustomobject]@{ Count = 0 }
        $individualResult = Read-InstallerDependencySources `
            -Config $individualSourceFixture -Selection Prompt `
            -InstalledTester { param($Descriptor) $false } `
            -ArtifactVerifier { return $true } `
            -Interactive $true -InputReader {
                $individualPromptState.Count++
                throw 'Olmayan yerel paket icin soru soruldu.'
            }.GetNewClosure()
        $individualValues = @($individualDescriptors.InstallSource)
        if ($individualResult -cne 'Configured' -or
            $individualPromptState.Count -ne 0 -or @(
                $individualValues | Where-Object { $_ -cne 'Online' }
            ).Count -gt 0) {
            throw 'Bagimlilik basina kaynak secimi uygulanamadi.'
        }
        $null = Test-DeploymentConfiguration `
            -Config $individualSourceFixture
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.DependencySourcePerTool'
        $installedDependencyFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $installedDependencyResult = Read-InstallerDependencySources `
            -Config $installedDependencyFixture -Selection Prompt `
            -Interactive $true `
            -InstalledTester { param($Descriptor) $true } `
            -InputReader { throw 'Kurulu bagimlilik icin soru soruldu.' }
        if ($installedDependencyResult -cne 'Configured' -or @(
                Get-InstallerCommonDependencyDescriptors `
                    -Config $installedDependencyFixture | Where-Object {
                    [string]$_.InstallSource -cnotin @(
                        'Local', 'Online', 'Automatic'
                    )
                }
            ).Count -gt 0) {
            throw 'Kurulu bagimlilik kaynak atlama sozlesmesi gecersiz.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.InstalledDependencySkip'
        $resumeDependencyFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        foreach ($descriptor in @(
            Get-InstallerCommonDependencyDescriptors `
                -Config $resumeDependencyFixture
        )) {
            $descriptor.InstallSource = 'online'
        }
        if ((Set-InstallerResumeDependencySources `
            -Config $resumeDependencyFixture -Selection Prompt `
            -InstalledTester { param($Descriptor) $false }) -cne
            'Configured' -or @(
                Get-InstallerCommonDependencyDescriptors `
                    -Config $resumeDependencyFixture | Where-Object {
                    [string]$_.InstallSource -cne 'Online'
                }
            ).Count -gt 0) {
            throw 'Resume kaynak degerleri canonical yapilmadi.'
        }
        $null = Test-DeploymentConfiguration `
            -Config $resumeDependencyFixture
        Assert-InstallerResumeConfigHandoff `
            -ResumeRequested $false -ConfigPathWasExplicit $false
        Assert-InstallerResumeConfigHandoff `
            -ResumeRequested $true -ConfigPathWasExplicit $true `
            -RequestedConfigPath $PSCommandPath
        $missingResumeConfigRejected = $false
        try {
            Assert-InstallerResumeConfigHandoff `
                -ResumeRequested $true -ConfigPathWasExplicit $false
        }
        catch [IO.InvalidDataException] {
            $missingResumeConfigRejected = $true
        }
        if (-not $missingResumeConfigRejected) {
            throw 'Resume etkin config yolu olmadan kabul edildi.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ResumeConfigHandoff'
        $bootstrapSourceFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $bootstrapSourceFixture.Bootstrap.PowerShell.OfflinePath = `
            '_validation_missing\PowerShell-x64.msi'
        $bootstrapLocalFailed = $false
        try {
            Install-PowerShellBootstrap `
                -Config $bootstrapSourceFixture `
                -SourceSelection Local
        }
        catch {
            $bootstrapLocalFailed = $true
        }
        if (-not $bootstrapLocalFailed) {
            throw 'PowerShell yerel kaynak kati modu agsiz durmadi.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.DependencySourceContracts'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.MissingSourcePromptSkip'
        $ollamaSourceFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $ollamaDependencyFixture = Get-InstallerOllamaDependency `
            -Config $ollamaSourceFixture
        $ollamaDependencyFixture.OfflinePath = `
            '_validation_missing\OllamaSetup.exe'
        if ((Read-InstallerOllamaInstallSource `
            -Config $ollamaSourceFixture -Selection online `
            -InstalledTester { $false }) -cne
            'Online' -or
            (Read-InstallerOllamaInstallSource `
                -Config $ollamaSourceFixture -Selection automatic `
                -InstalledTester { $false }) -cne
            'Online' -or
            [string]$ollamaDependencyFixture.InstallSource -cne
                'Online') {
            throw 'Ollama resmi kaynak secim sozlesmesi gecersiz.'
        }
        $installedOllamaFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $installedOllamaDependency = Get-InstallerOllamaDependency `
            -Config $installedOllamaFixture
        $installedOllamaDependency.InstallSource = 'Automatic'
        if ((Read-InstallerOllamaInstallSource `
            -Config $installedOllamaFixture -Selection Prompt `
            -InstalledTester { $true }) -cne 'Installed' -or
            [string]$installedOllamaDependency.InstallSource -cne
                'Automatic') {
            throw 'Kurulu Ollama kaynak degeri canonical kalmadi.'
        }
        $null = Test-DeploymentConfiguration `
            -Config $installedOllamaFixture
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.OllamaInstalledSource'
        $ollamaLocalFailed = $false
        try {
            $null = Read-InstallerOllamaInstallSource `
                -Config $ollamaSourceFixture -Selection Local `
                -InstalledTester { $false }
        }
        catch {
            $ollamaLocalFailed = $true
        }
        if (-not $ollamaLocalFailed) {
            throw 'Eksik yerel Ollama kaynagi kati modda reddedilmedi.'
        }
        $modelSourceFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $modelSourceFixture.Models.SelectionMode = 'Selected'
        $modelSourceFixture.Models.Requested = @(
            [string]$modelSourceFixture.Models.Catalog[0].Name
        )
        $modelSourceFixture.ModelTransfer.ImportSearchDirectories = @(
            '_validation_missing\Models'
        )
        if ((Set-InstallerLocalPackageSelection `
            -Config $modelSourceFixture -Hardware $validationHardware `
            -SourceSelection automatic) -cne 'Online' -or
            [string]$modelSourceFixture.Models.InstallSource -cne
                'Online') {
            throw 'Eksik yerel model paketi resmi kaynaga yonelmedi.'
        }
        $modelLocalFailed = $false
        try {
            $null = Set-InstallerLocalPackageSelection `
                -Config $modelSourceFixture -Hardware $validationHardware `
                -SourceSelection local
        }
        catch {
            $modelLocalFailed = $true
        }
        if (-not $modelLocalFailed) {
            throw 'Eksik yerel model paketi kati modda reddedilmedi.'
        }
        $automaticModelFixture = $modelSourceFixture |
            ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
        $automaticModelFixture.Models.SelectionMode = 'Automatic'
        $automaticModelFixture.Models.Requested = @()
        $quickPackageState = [pscustomobject]@{ Calls = 0 }
        $quickPackageSource = Set-InstallerLocalPackageSelection `
            -Config $automaticModelFixture `
            -Hardware $validationHardware `
            -SourceSelection Prompt -VerifyLocalIdentity:$false `
            -ModelNames @('qwen2.5-coder:1.5b') `
            -PackageReader ({
                $quickPackageState.Calls++
                throw 'Soru evresinde model paket agaci tarandi.'
            }.GetNewClosure())
        if ($quickPackageSource -cne 'Automatic' -or
            $quickPackageState.Calls -ne 0) {
            throw 'Model paket quick kaynak sozlesmesi gecersiz.'
        }
        $automaticDesiredNames = @(
            Get-InstallerMissingOllamaModelNames `
                -Config $automaticModelFixture `
                -Hardware $validationHardware
        )
        $automaticLocalFailed = $false
        try {
            $null = Set-InstallerLocalPackageSelection `
                -Config $automaticModelFixture `
                -Hardware $validationHardware `
                -SourceSelection Local `
                -ModelNames $automaticDesiredNames
        }
        catch {
            $automaticLocalFailed = $true
        }
        if ($automaticDesiredNames.Count -eq 0 -or
            -not $automaticLocalFailed) {
            throw 'Automatic explicit Local model fail-closed olmadi.'
        }
        $localSelectionDefinition = (Get-Command `
            Set-InstallerLocalPackageSelection -ErrorAction Stop).Definition
        $localDiscoveryIndex = $localSelectionDefinition.IndexOf(
            'Get-InstallerLocalModelPackages',
            [StringComparison]::Ordinal
        )
        $localMissingIndex = $localSelectionDefinition.IndexOf(
            '$missingPackages =',
            [StringComparison]::Ordinal
        )
        $localHashIndex = $localSelectionDefinition.IndexOf(
            'Test-InstallerLocalModelPackage',
            [StringComparison]::Ordinal
        )
        if ($localDiscoveryIndex -lt 0 -or
            $localMissingIndex -le $localDiscoveryIndex -or
            $localHashIndex -le $localMissingIndex -or
            $localSelectionDefinition.Substring(
                $localDiscoveryIndex,
                $localMissingIndex - $localDiscoveryIndex
            ) -match 'VerifyHashes') {
            throw 'Ollama yerel paket iki asamali SHA plani gecersiz.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.AutomaticModelMaterialization'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.PrePromptModelPackageLazy'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.OllamaTwoPhasePackageHash'
        $missingComfyPackageRoot = Join-Path $PSScriptRoot `
            '_validation_missing\PackageRoot'
        if (Test-Path -LiteralPath $missingComfyPackageRoot) {
            throw 'ComfyUI eksik paket fixture yolu mevcut.'
        }
        $missingComfyConfig = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $missingComfyConfig.ComfyUI.InstallPath = Join-Path `
            $missingComfyPackageRoot 'InstalledComfyUI'
        $satisfiedComfyRequirements = `
            New-InstallerComfyUIDiagnosticResult `
                -Ready $true -ReasonCode 'READY'
        $satisfiedComfyAvailability = [pscustomobject]@{
            RuntimeInstalled = $true
            LocalRuntimePath = $null
            MissingRequirements = @()
            RequirementsState = $satisfiedComfyRequirements
            RequirementsCandidatePath = `
                $missingComfyConfig.ComfyUI.InstallPath
            RequirementsFromDestination = $true
            DestinationRequirementsState = $satisfiedComfyRequirements
            LocalReady = $true
            AnyLocal = $true
        }
        $corruptComfyAvailability = [pscustomobject]@{
            RuntimeInstalled = $false
            LocalRuntimePath = $null
            MissingRequirements = @('ComfyUI runtime')
            RequirementsState = New-InstallerComfyUIDiagnosticResult `
                -Ready $false -ReasonCode 'CORE_HASH' -Detail 'fixture'
            RequirementsCandidatePath = $null
            RequirementsFromDestination = $false
            DestinationRequirementsState = $null
            LocalReady = $false
            AnyLocal = $false
        }
        $satisfiedAutomaticSource = Read-InstallerComfyUISource `
            -Models @() -Config $missingComfyConfig `
            -ProjectRoot $missingComfyPackageRoot -Selection Automatic `
            -IdentityVerifier {
                return $satisfiedComfyAvailability
            }.GetNewClosure()
        $corruptAutomaticSource = Read-InstallerComfyUISource `
            -Models @() -Config $missingComfyConfig `
            -ProjectRoot $missingComfyPackageRoot -Selection Automatic `
            -IdentityVerifier {
                return $corruptComfyAvailability
            }.GetNewClosure()
        if ($satisfiedAutomaticSource -cne 'Automatic' -or
            $corruptAutomaticSource -cne 'Online') {
            throw 'ComfyUI Automatic kaynak niyeti korunamadi.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ComfyUIAutomaticIntent'
        $originalPackageRoot = $script:InstallerPackageRoot
        try {
            $script:InstallerPackageRoot = $missingComfyPackageRoot
        $missingComfyModel = [pscustomobject]@{
            Name = 'Validation-Missing-ComfyUI-Model'
            LocalDirectory = '_validation_missing\ComfyUI'
            Assets = @([pscustomobject]@{
                RelativePath = ('_validation_missing\ComfyUI\' +
                    'missing.safetensors')
                Sha256 = '0' * 64
                SizeGB = 0.001
                Uri = 'https://huggingface.co/fixture'
            })
        }
        if ((Read-InstallerComfyUISource `
            -Models @($missingComfyModel) `
            -Config $missingComfyConfig `
            -ProjectRoot $missingComfyPackageRoot `
            -Selection online) -cne
            'Online' -or
            (Read-InstallerComfyUISource `
                -Models @($missingComfyModel) `
                -Config $missingComfyConfig `
                -ProjectRoot $missingComfyPackageRoot `
                -Selection automatic) -cne
            'Online') {
            throw 'ComfyUI kaynak secim sozlesmesi gecersiz.'
        }
        $comfyLocalFailed = $false
        try {
            $null = Read-InstallerComfyUISource `
                -Models @($missingComfyModel) `
                -Config $missingComfyConfig `
                -ProjectRoot $missingComfyPackageRoot `
                -Selection local
        }
        catch {
            $comfyLocalFailed = $true
        }
        if (-not $comfyLocalFailed) {
            throw 'Eksik ComfyUI yerel kaynagi kati modda reddedilmedi.'
        }
        $requiredNodeDescriptor = @(
            $missingComfyConfig.ComfyUI.CustomNodes |
                Where-Object { @($_.RequiredBy).Count -gt 0 }
        ) | Select-Object -First 1
        if ($null -ne $requiredNodeDescriptor) {
            $nodeModelName = [string]@(
                $requiredNodeDescriptor.RequiredBy
            )[0]
            $nodeModelFixture = [pscustomobject]@{
                Name = $nodeModelName
                LocalDirectory = '_validation_missing\ComfyUI'
                Assets = @([pscustomobject]@{
                    RelativePath = ('_validation_missing\ComfyUI\' +
                        'missing.safetensors')
                    Sha256 = '0' * 64
                    SizeGB = 0.001
                    Uri = 'https://huggingface.co/fixture'
                })
            }
            $nodeAvailability = Get-InstallerComfyUISourceAvailability `
                -Models @($nodeModelFixture) `
                -Config $missingComfyConfig `
                -ProjectRoot $missingComfyPackageRoot
            if ($nodeAvailability.LocalReady -or
                $nodeAvailability.RequirementsState.ReasonCode -cne
                    'CORE_LAYOUT' -or
                @($nodeAvailability.MissingRequirements) -icontains
                    'ComfyUI wheelhouse') {
                throw 'ComfyUI gereksiz wheelhouse fallback olustu.'
            }
            Write-Verbose `
                'WINLAMA_VALIDATION_OK:Installer.ComfyUISourceReadiness'
        }
        $lazyComfyState = [pscustomobject]@{
            DestinationCalls = 0
            LocalRuntimeCalls = 0
            RequirementCalls = 0
        }
        $readyComfyState = New-InstallerComfyUIDiagnosticResult `
            -Ready $true -ReasonCode 'READY'
        $lazyComfyAvailability = Get-InstallerComfyUISourceAvailability `
            -Models @($missingComfyModel) `
            -Config $missingComfyConfig `
            -ProjectRoot $missingComfyPackageRoot `
            -RequiredNodeModelNames @() `
            -RuntimeStateReader ({
                param($Path, $Config, $VerifyIdentity)
                if ($Path -ieq (Join-Path $missingComfyPackageRoot `
                    'Runtime\ComfyUI')) {
                    $lazyComfyState.LocalRuntimeCalls++
                    throw 'Hazir hedef varken local runtime kimligi okundu.'
                }
                $lazyComfyState.DestinationCalls++
                return $readyComfyState
            }.GetNewClosure()) -RequirementsStateReader ({
                param($RuntimeRoot, $Nodes, $VerifyIdentity)
                $lazyComfyState.RequirementCalls++
                return $readyComfyState
            }.GetNewClosure()) `
            -InstalledModelTester { return $false } `
            -LocalModelTester { return $true }
        if (-not $lazyComfyAvailability.LocalReady -or
            -not $lazyComfyAvailability.RequirementsFromDestination -or
            $lazyComfyState.DestinationCalls -ne 1 -or
            $lazyComfyState.LocalRuntimeCalls -ne 0 -or
            $lazyComfyState.RequirementCalls -ne 1 -or
            @($lazyComfyAvailability.LocalModelNames).Count -ne 1) {
            throw 'ComfyUI local runtime lazy kimlik sozlesmesi gecersiz.'
        }
        $comfyHashPhase = [pscustomobject]@{
            HashCalls = 0
            RuntimeCalls = 0
        }
        $partialRequirementFailure = `
            New-InstallerComfyUIDiagnosticResult `
                -Ready $false -ReasonCode 'IMPORT_PROBE' `
                -Detail 'fixture partial source'
        $partialComfyModels = @(
            [pscustomobject]@{ Name = 'Fixture.Local.Present' },
            [pscustomobject]@{ Name = 'Fixture.Local.Missing' }
        )
        $partialComfyAvailability = `
            Get-InstallerComfyUISourceAvailability `
                -Models $partialComfyModels `
                -Config $missingComfyConfig `
                -ProjectRoot $missingComfyPackageRoot `
                -RequiredNodeModelNames @() `
                -RuntimeStateReader ({
                    $comfyHashPhase.RuntimeCalls++
                    if ($comfyHashPhase.RuntimeCalls -gt 1) {
                        throw 'Eksik modelde local runtime kimligi okundu.'
                    }
                    return $readyComfyState
                }.GetNewClosure()) `
                -RequirementsStateReader ({
                    return $partialRequirementFailure
                }.GetNewClosure()) `
                -InstalledModelTester { return $false } `
                -LocalModelTester ({
                    param($Model, $ProjectRoot, $VerifyHash)
                    if ($VerifyHash) {
                        $comfyHashPhase.HashCalls++
                    }
                    return [string]$Model.Name -ceq `
                        'Fixture.Local.Present'
                }.GetNewClosure())
        if ($comfyHashPhase.HashCalls -ne 0 -or
            $comfyHashPhase.RuntimeCalls -ne 1 -or
            $partialComfyAvailability.LocalReady -or
            @($partialComfyAvailability.MissingRequirements) `
                -notcontains 'Fixture.Local.Missing') {
            throw 'Eksik ComfyUI kaynakta gereksiz model SHA okundu.'
        }
        $destinationImportFailure = `
            New-InstallerComfyUIDiagnosticResult `
                -Ready $false -ReasonCode 'IMPORT_PROBE' `
                -Detail 'fixture destination import failure'
        $provenanceAvailability = `
            Get-InstallerComfyUISourceAvailability `
                -Models @() -Config $missingComfyConfig `
                -ProjectRoot $missingComfyPackageRoot `
                -RequiredNodeModelNames @() `
                -RuntimeStateReader ({
                    return $readyComfyState
                }.GetNewClosure()) `
                -RequirementsStateReader ({
                    param($RuntimeRoot, $Nodes, $VerifyIdentity)
                    if ([string]::Equals(
                            [IO.Path]::GetFullPath($RuntimeRoot),
                            [IO.Path]::GetFullPath(
                                $missingComfyConfig.ComfyUI.InstallPath
                            ),
                            [StringComparison]::OrdinalIgnoreCase
                        )) {
                        return $destinationImportFailure
                    }
                    return $readyComfyState
                }.GetNewClosure()) `
                -LocalRuntimeIdentityTester { return $true }
        $expectedLocalCandidate = Join-Path $missingComfyPackageRoot `
            'Runtime\ComfyUI'
        $provenanceAction = Get-InstallerComfyUIDestinationAction `
            -DestinationState $provenanceAvailability.RuntimeState `
            -RequirementsState `
                $provenanceAvailability.DestinationRequirementsState `
            -RequiredNodeCount 0
        if ($provenanceAvailability.RequirementsFromDestination -or
            -not $provenanceAvailability.LocalRuntimeIdentityVerified -or
            -not [string]::Equals(
                [IO.Path]::GetFullPath(
                    $provenanceAvailability.RequirementsCandidatePath
                ),
                [IO.Path]::GetFullPath($expectedLocalCandidate),
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            $provenanceAvailability.DestinationRequirementsState.ReasonCode `
                -cne 'IMPORT_PROBE' -or $provenanceAction -cne 'Replace') {
            throw 'ComfyUI requirements aday kokeni korunamadi.'
        }
        $missingLocalPayloadAvailability = `
            Get-InstallerComfyUISourceAvailability `
                -Models @($missingComfyModel) `
                -Config $missingComfyConfig `
                -ProjectRoot $missingComfyPackageRoot `
                -RequiredNodeModelNames @() `
                -RuntimeStateReader ({
                    param($Path, $Config, $VerifyIdentity)
                    if ($Path -ieq (Join-Path $missingComfyPackageRoot `
                        'Runtime\ComfyUI')) {
                        throw 'Gereksiz local runtime kimligi okundu.'
                    }
                    return $readyComfyState
                }.GetNewClosure()) `
                -RequirementsStateReader {
                    return $readyComfyState
                }.GetNewClosure() `
                -InstalledModelTester { return $false } `
                -LocalModelTester { return $false }
        $missingLocalPromptResult = Read-InstallerComfyUISource `
            -Models @($missingComfyModel) `
            -Config $missingComfyConfig `
            -ProjectRoot $missingComfyPackageRoot -Selection Prompt `
            -IdentityVerifier {
                return $missingLocalPayloadAvailability
            }.GetNewClosure() `
            -InputReader { throw 'Olmayan local ComfyUI kaynagi soruldu.' }
        if ($missingLocalPayloadAvailability.AnyLocal -or
            $missingLocalPayloadAvailability.LocalReady -or
            $missingLocalPromptResult -cne 'Online') {
            throw 'Kurulu ComfyUI hedefi local kaynak gibi gosterildi.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ComfyUILazyLocalRuntime'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ComfyUITwoPhaseModelHash'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ComfyUIRequirementsProvenance'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ComfyUIActualLocalPayload'
        }
        finally {
            $script:InstallerPackageRoot = $originalPackageRoot
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ComfyUIMissingPackageFixture'
        $resumeDependencyIndex = $installerSourceText.LastIndexOf(
            '$dependencySourceResult = Set-InstallerResumeDependencySources',
            [StringComparison]::Ordinal
        )
        $resumeHandoffIndex = $installerSourceText.LastIndexOf(
            '$resumePowerShellHandoff =',
            [StringComparison]::Ordinal
        )
        $resumeOllamaIndex = $installerSourceText.LastIndexOf(
            '$resolvedOllamaSource = Read-InstallerOllamaInstallSource',
            [StringComparison]::Ordinal
        )
        $resumeModelIndex = $installerSourceText.LastIndexOf(
            '$resolvedModelSource = Set-InstallerLocalPackageSelection',
            [StringComparison]::Ordinal
        )
        $resumeComfyIndex = $installerSourceText.LastIndexOf(
            '$resolvedComfySource = Read-InstallerComfyUISource',
            [StringComparison]::Ordinal
        )
        $resumeMutationIndex = $installerSourceText.LastIndexOf(
            '$comfyRuntimeReady = Install-InstallerComfyUIRuntime',
            [StringComparison]::Ordinal
        )
        if ($resumeHandoffIndex -lt 0 -or
            $resumeDependencyIndex -le $resumeHandoffIndex -or
            $resumeOllamaIndex -le $resumeDependencyIndex -or
            $resumeModelIndex -le $resumeOllamaIndex -or
            $resumeComfyIndex -le $resumeModelIndex -or
            $resumeMutationIndex -le $resumeComfyIndex) {
            throw 'Resume kaynak dogrulama sirasi gecersiz.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ResumeSourceHandoff'
        $disabledHealthContext = [pscustomobject]@{
            Config = [pscustomobject]@{
                Ollama = [pscustomobject]@{ Enabled = $false }
                OpenWebUI = [pscustomobject]@{ Enabled = $false }
                Voice = [pscustomobject]@{ Enabled = $false }
                ComfyUI = [pscustomobject]@{ Enabled = $false }
            }
        }
        if (-not (Test-AiRuntime -Context $disabledHealthContext)) {
            throw 'Devre disi bilesen saglik aktarimi basarisiz.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.SourceSelectionContracts'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.SourceCanonicalization'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.CleanPcSourcePaths'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.DisabledHealthHandoff'
        $driverFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $driverFixture.ComfyUI.Enabled = $true
        $driverFixture.Installation.ContinueOnOptionalError = $true
        $driverHardware = [pscustomobject]@{
            NvidiaDetected = $true
            NvidiaSmiReady = $false
        }
        if ((Assert-InstallerComfyUIDriverPreflight `
            -Config $driverFixture -Hardware $driverHardware) -or
            $driverFixture.ComfyUI.Enabled -or
            @($driverFixture.ComfyUI.Requested).Count -ne 0) {
            throw 'ComfyUI NVIDIA preflight devam sozlesmesi gecersiz.'
        }
        $strictDriverFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $strictDriverFixture.ComfyUI.Enabled = $true
        $strictDriverFixture.Installation.ContinueOnOptionalError = $false
        $strictDriverFailed = $false
        try {
            $null = Assert-InstallerComfyUIDriverPreflight `
                -Config $strictDriverFixture -Hardware $driverHardware
        }
        catch {
            $strictDriverFailed = $true
        }
        if (-not $strictDriverFailed) {
            throw 'ComfyUI NVIDIA preflight kati modda durmadi.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.OptionalErrorContracts'
        $retainedFixture = $script:InstallerConfiguration |
            ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
        $retainedFixture.Models.SelectionMode = 'Manual'
        $retainedFixture.Models.Requested = @('qwen3.5:4b')
        $retainedModelSelection = Get-InstallerRetainedModelSelection `
            -Config $retainedFixture `
            -InstalledNames @('deepseek-coder:1.3b') `
            -AnyInstalled $true -PreferInstalled
        $uncataloguedModelSelection = `
            Get-InstallerRetainedModelSelection `
                -Config $retainedFixture -AnyInstalled $true `
                -PreferInstalled
        $resumeModelSelection = Get-InstallerRetainedModelSelection `
            -Config $retainedFixture `
            -InstalledNames @('deepseek-coder:1.3b')
        $partialModelsInstalled = `
            Test-InstallerRequestedModelsInstalled `
                -Config $retainedFixture `
                -InstalledNames @('deepseek-coder:1.3b')
        $allModelsInstalled = `
            Test-InstallerRequestedModelsInstalled `
                -Config $retainedFixture `
                -InstalledNames @('qwen3.5:4b')
        $retainedComfyModels = @(
            Get-InstallerRetainedComfyUIModels `
                -Config $retainedFixture `
                -Catalog @($retainedFixture.ComfyUI.Catalog) `
                -Installed @($retainedFixture.ComfyUI.Catalog[0])
        )
        $pendingFixture = $retainedFixture |
            ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
        $pendingFixture.Models.Requested = @(
            'qwen3.5:4b',
            'deepseek-coder:1.3b'
        )
        $missingFixtureNames = @(
            Get-InstallerMissingOllamaModelNames `
                -Config $pendingFixture `
                -InstalledNames @('qwen3.5:4b') `
                -Hardware $validationHardware
        )
        $pendingPayloadFixture = `
            New-InstallerPendingPayloadConfiguration `
                -Config $pendingFixture `
                -OllamaModelNames $missingFixtureNames `
                -ComfyUIModels @($pendingFixture.ComfyUI.Catalog[0])
        $comfyOnlyPayloadFixture = `
            New-InstallerPendingPayloadConfiguration `
                -Config $pendingFixture -OllamaModelNames $null `
                -ComfyUIModels @($pendingFixture.ComfyUI.Catalog[0])
        if ($retainedModelSelection -cne 'qwen3.5:4b' -or
            $uncataloguedModelSelection -cne 'qwen3.5:4b' -or
            $resumeModelSelection -cne 'qwen3.5:4b' -or
            $partialModelsInstalled -or -not $allModelsInstalled -or
            $missingFixtureNames.Count -ne 1 -or
            $missingFixtureNames[0] -cne 'deepseek-coder:1.3b' -or
            @($pendingFixture.Models.Requested).Count -ne 2 -or
            @($pendingPayloadFixture.Models.Requested).Count -ne 1 -or
            [string]$pendingPayloadFixture.Models.Requested[0] -cne
                'deepseek-coder:1.3b' -or
            @($pendingPayloadFixture.ComfyUI.Requested).Count -ne 1 -or
            @($comfyOnlyPayloadFixture.Models.Requested).Count -ne 0 -or
            @($comfyOnlyPayloadFixture.ComfyUI.Requested).Count -ne 1 -or
            $retainedComfyModels.Count -ne
                @($retainedFixture.ComfyUI.Requested).Count -or
            @($retainedFixture.ComfyUI.Requested | Where-Object {
                $_ -inotin @($retainedComfyModels.Name)
            }).Count -gt 0) {
            throw 'Yarim kurulum model secimi korunamadi.'
        }
        $installedModelYesQueue = `
            [Collections.Generic.Queue[string]]::new()
        foreach ($value in @('', 'evet', 'EVET')) {
            $installedModelYesQueue.Enqueue($value)
        }
        $installedModelYes = Read-InstallerInstalledModelPreference `
            -Component Ollama -AlreadyInstalled $true `
            -Interactive $true -InputReader {
                return $installedModelYesQueue.Dequeue()
            }.GetNewClosure()
        $installedModelNoQueue = `
            [Collections.Generic.Queue[string]]::new()
        $installedModelNoQueue.Enqueue('HAYIR')
        $installedModelNo = Read-InstallerInstalledModelPreference `
            -Component ComfyUI -AlreadyInstalled $true `
            -Interactive $true -InputReader {
                return $installedModelNoQueue.Dequeue()
            }.GetNewClosure()
        $installedModelExitQueue = `
            [Collections.Generic.Queue[string]]::new()
        $installedModelExitQueue.Enqueue('0')
        $installedModelExit = Read-InstallerInstalledModelPreference `
            -Component Ollama -AlreadyInstalled $true `
            -Interactive $true -InputReader {
                return $installedModelExitQueue.Dequeue()
            }.GetNewClosure()
        $unexpectedModelPrompt = {
            throw 'Acik model seciminde ek soru soruldu.'
        }
        $explicitModelPreference = `
            Read-InstallerInstalledModelPreference `
                -Component Ollama -AlreadyInstalled $true `
                -SelectionValue 'qwen3.5:4b' -Interactive $true `
                -InputReader $unexpectedModelPrompt
        $newModelPreference = Read-InstallerInstalledModelPreference `
            -Component ComfyUI -AlreadyInstalled $false `
            -Interactive $true -InputReader $unexpectedModelPrompt
        $unattendedModelPreference = `
            Read-InstallerInstalledModelPreference `
                -Component Ollama -AlreadyInstalled $true `
                -Interactive $false
        $ollamaRoot = [Environment]::ExpandEnvironmentVariables(
            [string]$script:InstallerConfiguration.Ollama.InstallPath
        )
        $ollamaCli = Join-Path $ollamaRoot 'ollama.exe'
        $ollamaApplication = Join-Path $ollamaRoot 'ollama app.exe'
        $ollamaCliOnlyPresent = Test-InstallerOllamaProductPresent `
            -Config $script:InstallerConfiguration -FileProbe {
                param($Path)
                return $Path -ieq $ollamaCli
            }.GetNewClosure()
        $ollamaApplicationOnlyPresent = `
            Test-InstallerOllamaProductPresent `
            -Config $script:InstallerConfiguration -FileProbe {
                param($Path)
                return $Path -ieq $ollamaApplication
            }.GetNewClosure()
        $ollamaProductPresent = Test-InstallerOllamaProductPresent `
            -Config $script:InstallerConfiguration -FileProbe {
                param($Path)
                return $Path -iin @($ollamaCli, $ollamaApplication)
            }.GetNewClosure()
        $ollamaMissing = Test-InstallerOllamaProductPresent `
            -Config $script:InstallerConfiguration `
            -FileProbe { param($Path) return $false }
        $stalePathRoot = 'C:\Fixture\Ollama-Stale'
        $completePathRoot = 'C:\Fixture\Ollama-Complete'
        $pathCommands = @(
            [pscustomobject]@{
                Source = Join-Path $stalePathRoot 'ollama.exe'
            },
            [pscustomobject]@{
                Source = Join-Path $completePathRoot 'ollama.exe'
            }
        )
        $pathFiles = @(
            (Join-Path $stalePathRoot 'ollama.exe'),
            (Join-Path $completePathRoot 'ollama.exe'),
            (Join-Path $completePathRoot 'ollama app.exe')
        )
        $pathCommandResolver = {
            return $pathCommands
        }.GetNewClosure()
        $pathFileProbe = {
            param($Path)
            return $Path -iin $pathFiles
        }.GetNewClosure()
        $laterPathProductPresent = `
            Test-InstallerOllamaProductPresent `
                -Config $script:InstallerConfiguration `
                -FileProbe $pathFileProbe `
                -CommandResolver $pathCommandResolver
        $comfyRuntimePresent = Test-InstallerComfyUIRuntimePresent `
            -Path 'C:\Fixture\ComfyUI' `
            -LayoutVerifier { param($Path) return $true } `
            -ReparseVerifier { param($Path) return $true }
        $comfyRuntimeLayoutMissing = `
            Test-InstallerComfyUIRuntimePresent `
                -Path 'C:\Fixture\ComfyUI' `
                -LayoutVerifier { param($Path) return $false } `
                -ReparseVerifier { param($Path) return $true }
        $comfyRuntimeReparseUnsafe = `
            Test-InstallerComfyUIRuntimePresent `
                -Path 'C:\Fixture\ComfyUI' `
                -LayoutVerifier { param($Path) return $true } `
                -ReparseVerifier { param($Path) return $false }
        $installerMainSource = [IO.File]::ReadAllText($PSCommandPath)
        if (-not (Test-InstallerShouldSkipComponentQuestion `
                -AlreadyInstalled $true -Selection Prompt) -or
            (Test-InstallerShouldSkipComponentQuestion `
                -AlreadyInstalled $true -Selection Skip) -or
            (Test-InstallerShouldSkipComponentQuestion `
                -AlreadyInstalled $false -Selection Prompt) -or
            $installedModelYes -cne 'Select' -or
            $installedModelYesQueue.Count -ne 0 -or
            $installedModelNo -cne 'Keep' -or
            $installedModelExit -cne 'Exit' -or
            $explicitModelPreference -cne 'Select' -or
            $newModelPreference -cne 'Select' -or
            $unattendedModelPreference -cne 'Keep' -or
            $ollamaCliOnlyPresent -or
            $ollamaApplicationOnlyPresent -or
            -not $ollamaProductPresent -or $ollamaMissing -or
            -not $laterPathProductPresent -or
            -not $comfyRuntimePresent -or
            $comfyRuntimeLayoutMissing -or
            $comfyRuntimeReparseUnsafe -or
            $installerMainSource -notmatch
                '\$ollamaProductPresent\s*=\s*' +
                'Test-InstallerOllamaProductPresent' -or
            $installerMainSource -notmatch
                'Read-InstallerInstalledModelPreference' -or
            (Get-Command Get-InstallerOllamaCandidateRoots `
                -ErrorAction Stop).Definition -notmatch
                    "Get-Command 'ollama\.exe'.*-All") {
            throw 'Kurulu bilesen soru atlama sozlesmesi gecersiz.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.InstalledQuestionSkip'
        Write-Verbose `
            'WINLAMA_UI_OK:Install.InstalledModelPreference'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.OllamaPresence'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.ComfyUIPresence'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.PartialModelRetention'
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:Installer.PendingPayloadSelection'
        Write-Verbose 'WINLAMA_UI_OK:Install.Components'
        Write-InstallerLog -Level INFO `
            -Message 'Installer.Validation.SourceFinished'
        $validationAfter = Get-InstallerValidationSnapshot
        $validationChanges = @(Get-InstallerValidationChanges `
            -Before $validationSnapshot -After $validationAfter)
        if ($validationChanges.Count -gt 0) {
            throw (Get-LocalizedText `
                -Key 'Installer.Error.ValidationCreatedFiles' `
                -Arguments @(($validationChanges -join ', ')))
        }
        Write-Verbose 'WINLAMA_VALIDATION_OK:RepositoryMutationFree'
        Write-Verbose (Get-LocalizedText `
            -Key 'Verbose.Validation.Completed' `
            -Arguments @('Install.ps1'))
        Write-Verbose 'WINLAMA_VALIDATION_OK:Install.ps1'
        exit 0
    }
    if (-not (Test-IsWindowsAdministrator)) {
        Write-InstallerLog -Level INFO `
            -Message 'Common.Admin.Requesting'
        exit (Start-ElevatedInstaller)
    }
    Assert-InstallerElevatedUserContext
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw (Get-LocalizedText -Key 'Common.Error.ConfigMissing' `
            -Arguments @($ConfigPath))
    }
    try {
        $config = Read-JsonFile -Path $ConfigPath
    }
    catch {
        throw (Get-LocalizedText -Key 'Common.Error.ConfigUnreadable' `
            -Arguments @($ConfigPath)), $_.Exception
    }
    $script:InstallerPackageRoot = Resolve-InstallerPackageRoot `
        -Config $config -CurrentRoot $PSScriptRoot `
        -PreferConfiguredSource:$Resume
    $currentScriptRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    if ($Resume -and -not $script:InstallerPackageRoot.Equals(
            $currentScriptRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        $packageInstaller = Resolve-InstallerContainedPackagePath `
            -Root $script:InstallerPackageRoot `
            -RelativePath 'Install.ps1'
        if (-not (Test-Path -LiteralPath $packageInstaller `
            -PathType Leaf)) {
            throw 'Dogrulanmis paket kokunde Install.ps1 eksik.'
        }
        $reentryArguments = New-InstallerPackageRootReentryArguments `
            -ScriptPath $packageInstaller `
            -EffectiveConfigPath $ConfigPath
        $currentPowerShell = Get-InstallerCurrentPowerShellExecutable
        & $currentPowerShell @reentryArguments
        exit ([int]$LASTEXITCODE)
    }
    $config.Installation | Add-Member `
        -NotePropertyName SessionId `
        -NotePropertyValue $SessionId -Force
    $config.Installation.Source = $script:InstallerPackageRoot
    $script:InstallerConfiguration = $config
    $completionBaselineConfig = $config |
        ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
    $comfyHashCache = @{}
    $verifiedComfyAvailability = $null
    $null = Test-DeploymentConfiguration -Config $config
    $verifyLocalPayloadHashes =
        [bool]$config.Installation.VerifyLocalPayloadHashes
    if ($Resume) {
        if ($LocalPayloadHashSelection -ne 'Prompt') {
            $verifyLocalPayloadHashes =
                $LocalPayloadHashSelection -eq 'Verify'
            $config.Installation.VerifyLocalPayloadHashes =
                $verifyLocalPayloadHashes
        }
        $LocalPayloadHashSelection = if ($verifyLocalPayloadHashes) {
            'Verify'
        }
        else {
            'Skip'
        }
        $completionBaselineConfig = $config |
            ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
    }
    Assert-InstallerOperatingSystem
    if (Set-WinlamaProcessPriority `
        -Priority $config.Runtime.ProcessPriority) {
        Write-InstallerLog -Level INFO `
            -Message 'Common.Priority.Applied'
    }
    else {
        Write-InstallerLog -Level WARN `
            -Message 'Common.Priority.Failed'
    }
    if (-not $Resume) {
        $ollamaProductPresent = Test-InstallerOllamaProductPresent `
            -Config $config
        $ollamaChoice = if (
            Test-InstallerShouldSkipComponentQuestion `
                -AlreadyInstalled $ollamaProductPresent `
                -Selection $OllamaSelection
        ) {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.Ollama.Detected'
            Write-WinlamaUIStatus -Level SKIP -Message (
                Get-LocalizedText `
                    -Key 'Installer.Ollama.Detected'
            )
            'Install'
        }
        else {
            Read-InstallerComponentSelection `
                -SectionKey 'Installer.Section.OllamaSelection' `
                -DescriptionKey 'Installer.Ollama.Description' `
                -PromptKey 'Installer.Prompt.OllamaSelection' `
                -Selection $OllamaSelection `
                -DefaultEnabled ([bool]$config.Ollama.Enabled)
        }
        if ($ollamaChoice -eq 'Exit') {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.Ollama.SelectionExited'
            Exit-InstallerSelection `
                -Summary (Get-LocalizedText `
                    -Key 'Installer.Operation.ComponentSelectionCancelled')
        }
        $installOllama = $ollamaChoice -eq 'Install'
        Set-InstallerOllamaComponent -Config $config `
            -Enabled $installOllama
        $hardware = Get-InstallerHardwareProfile -Config $config
        $modelsAlreadyInstalled = $false
        $uncataloguedModelAlreadyInstalled = $false
        $pendingOllamaModelNames = @()
        if ($installOllama) {
            $ollamaSource = Read-InstallerOllamaInstallSource `
                -Config $config -Selection $OllamaSourceSelection `
                -VerifyLocalIdentity $false
            if ($ollamaSource -eq 'Exit') {
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.Ollama.SelectionExited'
                Exit-InstallerSelection `
                    -Summary (Get-LocalizedText `
                        -Key 'Installer.Operation.OllamaSourceCancelled')
            }
            $installedModelNames = @(Get-InstallerInstalledModelNames `
                -Config $config)
            $anyModelInstalled = $installedModelNames.Count -gt 0 -or
                (Test-InstallerAnyOllamaModelInstalled -Config $config)
            $installedModelPreference = `
                Read-InstallerInstalledModelPreference `
                    -Component Ollama `
                    -AlreadyInstalled $ollamaProductPresent `
                    -SelectionValue $ModelSelection
            if ($installedModelPreference -ceq 'Exit') {
                Exit-InstallerSelection `
                    -Summary (Get-LocalizedText `
                        -Key 'Installer.Operation.ModelSelectionCancelled')
            }
            if ($installedModelPreference -ceq 'Keep') {
                $ModelSelection = if ($installedModelNames.Count -gt 0) {
                    $installedModelNames -join ','
                }
                else {
                    'Skip'
                }
                Write-WinlamaUIStatus -Level SKIP -Message (
                    Get-LocalizedText `
                        -Key 'Installer.Models.ExistingKept'
                )
            }
            else {
                $ModelSelection = Read-InstallerModelSelection `
                    -Value $ModelSelection -Config $config `
                    -Hardware $hardware
            }
            if ($ModelSelection -eq 'Exit') {
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.Selection.Exited'
                Exit-InstallerSelection `
                    -Summary (Get-LocalizedText `
                        -Key 'Installer.Operation.ModelSelectionCancelled')
            }
            Set-InstallerModelSelection -Config $config `
                -Selection $ModelSelection
            $pendingOllamaModelNames = @(
                Get-InstallerMissingOllamaModelNames -Config $config `
                    -InstalledNames $installedModelNames `
                    -Hardware $hardware
            )
            if ($ModelSelection -eq 'Skip') {
                $modelsAlreadyInstalled = $true
                $uncataloguedModelAlreadyInstalled = `
                    $anyModelInstalled -and
                    $installedModelNames.Count -eq 0
            }
            elseif (Test-InstallerRequestedModelsInstalled `
                -Config $config `
                -InstalledNames $installedModelNames) {
                $modelsAlreadyInstalled = $true
            }
            if ($ModelSelection -eq 'Skip') {
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.Selection.SkipChosen'
            }
            else {
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.Model.Selection' `
                    -MessageArguments @($ModelSelection)
            }
            $modelSource = if ($modelsAlreadyInstalled) {
                $config.Models.LocalPackageImport.SelectedPackages = @()
                $config.Models | Add-Member `
                    -NotePropertyName InstallSource `
                    -NotePropertyValue Automatic -Force
                'Installed'
            }
            else {
                Set-InstallerLocalPackageSelection `
                    -Config $config -Hardware $hardware `
                    -SourceSelection $ModelSourceSelection `
                    -VerifyLocalIdentity $false `
                    -ModelNames $pendingOllamaModelNames
            }
            if ($modelSource -eq 'Exit') {
                Exit-InstallerSelection `
                    -Summary (Get-LocalizedText `
                        -Key 'Installer.Operation.ModelSourceCancelled')
            }
        }
        else {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.Ollama.Skipped'
        }
        $comfyDestination = Resolve-InstallerPath `
            -Path ([string]$config.ComfyUI.InstallPath)
        $comfyRuntimeState = Get-InstallerComfyUIRuntimeState `
            -Path $comfyDestination -Config $config `
            -VerifyIdentity $false
        $comfyRuntimeInstalled = [bool]$comfyRuntimeState.Ready
        $comfyRuntimePresent = Test-InstallerComfyUIRuntimePresent `
            -Path $comfyDestination
        $comfyComponent = if (
            Test-InstallerShouldSkipComponentQuestion `
                -AlreadyInstalled $comfyRuntimePresent `
                -Selection $ComfyUIInstallSelection
        ) {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.ComfyUI.Detected'
            Write-WinlamaUIStatus -Level SKIP -Message (
                Get-LocalizedText `
                    -Key 'Installer.ComfyUI.Detected'
            )
            'Install'
        }
        else {
            Read-InstallerComponentSelection `
                -SectionKey 'Installer.Section.ComfyUISelection' `
                -DescriptionKey 'Installer.ComfyUI.Description' `
                -PromptKey 'Installer.Prompt.ComfyUIInstallSelection' `
                -Selection $ComfyUIInstallSelection `
                -DefaultEnabled ([bool]$config.ComfyUI.Enabled)
        }
        if ($comfyComponent -eq 'Exit') {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.ComfyUI.SelectionExited'
            Exit-InstallerSelection `
                -Summary (Get-LocalizedText `
                    -Key 'Installer.Operation.ComfyUISelectionCancelled')
        }
        $config.ComfyUI.Enabled = $comfyComponent -eq 'Install'
        $comfyUIModels = @()
        $comfyModelsAlreadyInstalled = $false
        if ($comfyComponent -eq 'Install') {
            $configuredComfyModels = @(Get-InstallerComfyUICatalog `
                -Config $config `
                -ProjectRoot $script:InstallerPackageRoot)
            $installedComfyModels = @($configuredComfyModels |
                Where-Object {
                    Test-InstallerComfyUIModelInstalled -Model $_ `
                        -Config $config `
                        -ProjectRoot $script:InstallerPackageRoot
                })
            $installedComfyModelPreference = `
                Read-InstallerInstalledModelPreference `
                    -Component ComfyUI `
                    -AlreadyInstalled $comfyRuntimePresent `
                    -SelectionValue $ComfyUISelection
            if ($installedComfyModelPreference -ceq 'Exit') {
                Exit-InstallerSelection `
                    -Summary (Get-LocalizedText `
                        -Key `
                            'Installer.Operation.ComfyUIModelSelectionCancelled')
            }
            if ($installedComfyModelPreference -ceq 'Keep') {
                $comfyUIModels = @($installedComfyModels)
                $comfyModelsAlreadyInstalled =
                    $installedComfyModels.Count -gt 0
                Write-WinlamaUIStatus -Level SKIP -Message (
                    Get-LocalizedText `
                        -Key 'Installer.ComfyUI.ModelsExistingKept'
                )
            }
            else {
                $comfyUIModels = @(Read-InstallerComfyUISelection `
                    -Config $config `
                    -ProjectRoot $script:InstallerPackageRoot `
                    -Hardware $hardware -Value $ComfyUISelection)
            }
            if (-not $comfyModelsAlreadyInstalled -and
                $comfyUIModels.Count -gt 0 -and
                @($comfyUIModels | Where-Object {
                    -not (Test-InstallerComfyUIModelInstalled `
                        -Model $_ -Config $config `
                        -ProjectRoot $script:InstallerPackageRoot)
                }).Count -eq 0) {
                $comfyModelsAlreadyInstalled = $true
            }
        }
        if ($comfyUIModels.Count -eq 1 -and
            $comfyUIModels[0] -is [string] -and
            $comfyUIModels[0] -eq 'Exit') {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.ComfyUI.SelectionExited'
            Exit-InstallerSelection `
                -Summary (Get-LocalizedText `
                    -Key 'Installer.Operation.ComfyUIModelSelectionCancelled')
        }
        if ($comfyComponent -ne 'Install') {
            $config.ComfyUI.Enabled = $false
            $config.ComfyUI.Requested = @()
        }
        else {
            $config.ComfyUI.Enabled = $true
            if ($comfyUIModels.Count -gt 0) {
                Add-InstallerComfyUISelectionToCatalog `
                    -Models $comfyUIModels -Config $config
            }
            $config.ComfyUI.Requested = @(
                $comfyUIModels | ForEach-Object { $_.Name }
            )
        }
        $comfyModelSelectionSkipped = $comfyUIModels.Count -eq 0
        $comfySourceAlreadySatisfied = $config.ComfyUI.Enabled -and
            $comfyRuntimeInstalled -and (
                $comfyModelsAlreadyInstalled -or
                $comfyModelSelectionSkipped
            )
        $resolvedComfySource = if ($comfySourceAlreadySatisfied) {
            'Automatic'
        }
        elseif ($config.ComfyUI.Enabled) {
            Read-InstallerComfyUISource -Models $comfyUIModels `
                -Config $config `
                -ProjectRoot $script:InstallerPackageRoot `
                -Selection $ComfyUISourceSelection `
                -VerifyLocalIdentity $false `
                -QuickProbe:(
                    Test-InstallerComfyUIQuickProbeRequested `
                        -Selection $ComfyUISourceSelection `
                        -VerifyLocalIdentity $false
                )
        }
        else {
            'Online'
        }
        if ($resolvedComfySource -eq 'Exit') {
            Exit-InstallerSelection `
                -Summary (Get-LocalizedText `
                    -Key 'Installer.Operation.ComfyUISourceCancelled')
        }
        $config.ComfyUI | Add-Member -NotePropertyName InstallSource `
            -NotePropertyValue $resolvedComfySource -Force
        $openWebUIAlreadyInstalled = Test-InstallerExistingFeature `
            -Config $config -Feature OpenWebUI -VerifyIdentity $false
        $openWebUIChoice = if (
            Test-InstallerShouldSkipComponentQuestion `
                -AlreadyInstalled $openWebUIAlreadyInstalled `
                -Selection $OpenWebUISelection
        ) {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.OpenWebUI.AlreadyInstalled'
            Write-WinlamaUIStatus -Level SKIP -Message (
                Get-LocalizedText `
                    -Key 'Installer.OpenWebUI.AlreadyInstalled'
            )
            'Install'
        }
        else {
            Read-InstallerOpenWebUISelection `
                -Config $config -Selection $OpenWebUISelection
        }
        if ($openWebUIChoice -eq 'Exit') {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.OpenWebUI.SelectionExited'
            Exit-InstallerSelection `
                -Summary (Get-LocalizedText `
                    -Key 'Installer.Operation.OpenWebUISelectionCancelled')
        }
        $installOpenWebUI = $openWebUIChoice -eq 'Install'
        $voiceProfileImported = $false
        if ($VoiceSelection -ne 'Skip' -and
            $VoiceLanguageSelection -eq 'Prompt') {
            $voiceProfileImported = `
                Import-InstallerExistingVoiceProfile -Config $config
        }
        $voiceAlreadyInstalled = if ($voiceProfileImported) {
            $true
        }
        else {
            Test-InstallerExistingFeature -Config $config -Feature Voice `
                -VerifyIdentity $false
        }
        $voiceChoice = if (
            Test-InstallerShouldSkipComponentQuestion `
                -AlreadyInstalled $voiceAlreadyInstalled `
                -Selection $VoiceSelection
        ) {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.Voice.AlreadyInstalled'
            Write-WinlamaUIStatus -Level SKIP -Message (
                Get-LocalizedText `
                    -Key 'Installer.Voice.AlreadyInstalled'
            )
            'Install'
        }
        else {
            Read-InstallerVoiceSelection -Config $config `
                -Selection $VoiceSelection
        }
        if ($voiceChoice -eq 'Exit') {
            Exit-InstallerSelection `
                -Summary (Get-LocalizedText `
                    -Key 'Installer.Operation.VoiceSelectionCancelled')
        }
        Set-InstallerOptionalComponents -Config $config `
            -InstallOpenWebUI $installOpenWebUI `
            -InstallVoice ($voiceChoice -eq 'Install')
        if ($voiceChoice -eq 'Install') {
            if (-not $voiceAlreadyInstalled -or
                $VoiceLanguageSelection -ne 'Prompt') {
                $voiceLanguage = `
                    Read-InstallerVoiceLanguageSelection `
                        -Config $config `
                        -Selection $VoiceLanguageSelection
                if ($voiceLanguage -eq 'Exit') {
                    Exit-InstallerSelection `
                        -Summary (Get-LocalizedText `
                            -Key `
                                'Installer.Operation.VoiceSelectionCancelled')
                }
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.Voice.LanguageSelected' `
                    -MessageArguments @($config.Voice.Language)
            }
            Write-InstallerLog -Level INFO `
                -Message 'Installer.Voice.Selected'
            Write-InstallerLog -Level INFO `
                -Message 'Installer.Voice.OnlineRequired'
            Write-InstallerLine -Text (Get-LocalizedText `
                -Key 'Installer.Voice.OnlineRequired') `
                -Color Cyan
        }
        else {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.Voice.Skipped'
        }
        if ($installOpenWebUI) {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.OpenWebUI.Selected'
        }
        else {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.OpenWebUI.Skipped'
        }
        if ($installOpenWebUI) {
            $defaultSelection = if (
                $DefaultConfigSelection -eq 'Apply'
            ) {
                'Install'
            }
            else {
                $DefaultConfigSelection
            }
            $defaultChoice = Read-InstallerComponentSelection `
                -SectionKey 'Installer.Section.DefaultConfigSelection' `
                -DescriptionKey 'Installer.DefaultConfig.Description' `
                -PromptKey 'Installer.Prompt.DefaultConfigSelection' `
                -Selection $defaultSelection `
                -DefaultEnabled ([bool]$config.OpenWebUI.
                    DefaultConfig.ApplyOnFirstStart)
            if ($defaultChoice -eq 'Exit') {
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.DefaultConfig.SelectionExited'
                Exit-InstallerSelection `
                    -Summary (Get-LocalizedText `
                        -Key 'Installer.Operation.ConfigurationSelectionCancelled')
            }
            $config.OpenWebUI.DefaultConfig.ApplyOnFirstStart = `
                $defaultChoice -eq 'Install'
        }
        $dependencySourceResult = Read-InstallerDependencySources `
            -Config $config -Selection $DependencySourceSelection `
            -VerifyLocalIdentity $false
        if ($dependencySourceResult -eq 'Exit') {
            Exit-InstallerSelection `
                -Summary (Get-LocalizedText `
                    -Key 'Installer.Operation.DependencySourceCancelled')
        }
        if ($dependencySourceResult -cne 'Configured') {
            throw 'Ortak kurulum kaynaklari yapilandirilamadi.'
        }
        $hashSelection = Read-InstallerLocalPayloadHashSelection `
            -Selection $LocalPayloadHashSelection `
            -DefaultVerify ([bool]$config.Installation.
                VerifyLocalPayloadHashes)
        if ($hashSelection -ceq 'Exit') {
            Exit-InstallerSelection `
                -Summary (Get-LocalizedText `
                    -Key 'Installer.Operation.LocalPayloadHashCancelled')
        }
        $verifyLocalPayloadHashes = $hashSelection -ceq 'Verify'
        $LocalPayloadHashSelection = $hashSelection
        $config.Installation.VerifyLocalPayloadHashes =
            $verifyLocalPayloadHashes
        $hashStatusKey = if ($verifyLocalPayloadHashes) {
            'Installer.LocalPayloadHash.VerifySelected'
        }
        else {
            'Installer.LocalPayloadHash.SkipSelected'
        }
        $hashStatusLevel = if ($verifyLocalPayloadHashes) {
            'INFO'
        }
        else {
            'WARN'
        }
        Write-InstallerLog -Level $hashStatusLevel `
            -Message $hashStatusKey
        $errorMode = Read-InstallerOptionalErrorMode `
            -Selection $OptionalErrorMode `
            -DefaultContinue ([bool]$config.Installation.
                ContinueOnOptionalError)
        if ($errorMode -eq 'Exit') {
            Exit-InstallerSelection `
                -Summary (Get-LocalizedText `
                    -Key 'Installer.Operation.ErrorModeCancelled')
        }
        $config.Installation.ContinueOnOptionalError = `
            $errorMode -eq 'Continue'
        $ConfigPath = Save-EffectiveInstallerConfig -Config $config
        $completionBaselineConfig = $config |
            ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
        Write-InstallerSection -Title 'Installer.Section.Unattended'
        $readyMessage = if ($NoPause) {
            Get-LocalizedText -Key 'Installer.Unattended.ReadyNoPause'
        }
        else {
            Get-LocalizedText -Key 'Installer.Unattended.Ready'
        }
        Write-InstallerLine -Text $readyMessage -Color Green
        Write-InstallerRule
        $initialPowerShellHandoff = `
            Invoke-InstallerPowerShellRuntimeHandoff `
                -Config $config -Reason Initial
        if ($initialPowerShellHandoff.HandedOff) {
            Complete-InstallerPowerShellHandoff `
                -ExitCode ([int]$initialPowerShellHandoff.ExitCode)
            exit ([int]$initialPowerShellHandoff.ExitCode)
        }
        $exactModelState = [pscustomobject]@{
            Desired = @()
            Installed = @()
            Missing = @()
            HashCache = @{}
        }
        $exactComfyState = [pscustomobject]@{
            Missing = @()
            Availability = $null
        }
        $sourceVerifiers = [Collections.Generic.List[scriptblock]]::new()
        $sourceVerifiers.Add({
            Write-InstallerLog -Level INFO `
                -Message 'Installer.SourceVerification.Dependencies'
            $result = Set-InstallerResumeDependencySources `
                -Config $config -Selection Prompt
            if ($result -cne 'Configured') {
                throw 'Ortak kaynaklar exact dogrulanamadi.'
            }
        }.GetNewClosure())
        if ($installOllama) {
            $sourceVerifiers.Add({
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.SourceVerification.Ollama'
                if ($ollamaSource -cne 'Installed') {
                    $dependency = Get-InstallerOllamaDependency `
                        -Config $config
                    $verified = Read-InstallerOllamaInstallSource `
                        -Config $config `
                        -Selection ([string]$dependency.InstallSource)
                    if ($verified -ceq 'Exit') {
                        throw 'Ollama kaynak dogrulamasi iptal dondu.'
                    }
                }
            }.GetNewClosure())
            if ([string]$config.Models.SelectionMode -cne 'Skip') {
                $sourceVerifiers.Add({
                    Write-InstallerLog -Level INFO `
                        -Message 'Installer.SourceVerification.Models'
                    $property = $config.Models.PSObject.Properties[
                        'InstallSource'
                    ]
                    $selection = if ($ModelSourceSelection -ne 'Prompt') {
                        $ModelSourceSelection
                    }
                    elseif ($null -ne $property) {
                        [string]$property.Value
                    }
                    else {
                        'Automatic'
                    }
                    $desiredModelNames = @(
                        Get-InstallerDesiredOllamaModelNames `
                            -Config $config -Hardware $hardware
                    )
                    $exactInstalledNames = @(
                        Get-InstallerInstalledModelNames -Config $config `
                            -VerifyHash:$verifyLocalPayloadHashes `
                            -ModelNames $desiredModelNames `
                            -HashCache $exactModelState.HashCache
                    )
                    $missingModelNames = @(
                        Get-InstallerMissingOllamaModelNames `
                            -Config $config `
                            -InstalledNames $exactInstalledNames `
                            -Hardware $hardware
                    )
                    $exactModelState.Desired = $desiredModelNames
                    $exactModelState.Installed = $exactInstalledNames
                    $exactModelState.Missing = $missingModelNames
                    if ($missingModelNames.Count -eq 0) {
                        $config.Models.LocalPackageImport.
                            SelectedPackages = @()
                        $config.Models | Add-Member `
                            -NotePropertyName InstallSource `
                            -NotePropertyValue Automatic -Force
                    }
                    else {
                        $verified = Set-InstallerLocalPackageSelection `
                            -Config $config -Hardware $hardware `
                            -SourceSelection $selection `
                            -ModelNames $missingModelNames `
                            -VerifyLocalContentHash:$verifyLocalPayloadHashes
                        if ($verified -ceq 'Exit') {
                            throw 'Model kaynak dogrulamasi iptal dondu.'
                        }
                    }
                }.GetNewClosure())
            }
            elseif ($uncataloguedModelAlreadyInstalled) {
                $sourceVerifiers.Add({
                    if (-not (Test-InstallerAnyOllamaModelInstalled `
                        -Config $config)) {
                        throw 'Kurulu Ollama modeli yeniden dogrulanamadi.'
                    }
                }.GetNewClosure())
            }
        }
        if ($config.ComfyUI.Enabled) {
            $sourceVerifiers.Add({
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.SourceVerification.ComfyUI'
                $property = $config.ComfyUI.PSObject.Properties[
                    'InstallSource'
                ]
                $selection = if ($null -ne $property) {
                    [string]$property.Value
                }
                else {
                    'Automatic'
                }
                $missingComfyModels = @(
                    Get-InstallerMissingComfyUIModels `
                        -Models $comfyUIModels -Config $config `
                        -ProjectRoot $script:InstallerPackageRoot `
                        -VerifyHash:$verifyLocalPayloadHashes `
                        -HashCache $comfyHashCache
                )
                $availability = $null
                $verified = Read-InstallerComfyUISource `
                    -Models $missingComfyModels -Config $config `
                    -ProjectRoot $script:InstallerPackageRoot `
                    -RequiredNodeModelNames @($config.ComfyUI.Requested) `
                    -Selection $selection -HashCache $comfyHashCache `
                    -VerifyLocalIdentity $verifyLocalPayloadHashes `
                    -AvailabilityResult ([ref]$availability)
                $exactComfyState.Missing = $missingComfyModels
                $exactComfyState.Availability = $availability
                $config.ComfyUI | Add-Member `
                    -NotePropertyName InstallSource `
                    -NotePropertyValue $verified -Force
            }.GetNewClosure())
        }
        $verificationStartKey = if ($verifyLocalPayloadHashes) {
            'Installer.SourceVerification.Starting'
        }
        else {
            'Installer.SourceVerification.StartingWithoutPayloadHashes'
        }
        Write-InstallerLog -Level INFO -Message $verificationStartKey
        Invoke-InstallerDeferredSourceVerification `
            -Verifiers $sourceVerifiers.ToArray()
        $pendingOllamaModelNames = @(
            if ($installOllama) { $exactModelState.Missing }
        )
        $pendingComfyUIModels = @(
            if ($config.ComfyUI.Enabled) { $exactComfyState.Missing }
        )
        $verifiedComfyAvailability = $exactComfyState.Availability
        $identityConfig = New-InstallerPendingPayloadConfiguration `
            -Config $config `
            -OllamaModelNames $pendingOllamaModelNames `
            -ComfyUIModels $pendingComfyUIModels `
            -RequiredNodeModels $comfyUIModels
        $null = Assert-InstallerDeferredPackageIdentity `
            -Root $script:InstallerPackageRoot -Config $identityConfig
        $verificationCompletedKey = if ($verifyLocalPayloadHashes) {
            'Installer.SourceVerification.Completed'
        }
        else {
            'Installer.SourceVerification.CompletedWithoutPayloadHashes'
        }
        Write-InstallerLog -Level INFO -Message $verificationCompletedKey
        $resolvedComfySource = if ($config.ComfyUI.Enabled) {
            [string]$config.ComfyUI.InstallSource
        }
        else {
            'Online'
        }
        $null = Assert-InstallerComfyUIDriverPreflight `
            -Config $config -Hardware $hardware
        $null = Test-DeploymentConfiguration -Config $config
        $comfyRuntimeReady = $false
        if ($config.ComfyUI.Enabled) {
            $comfyRuntimeReady = Install-InstallerComfyUIRuntime `
                -Config $config -SourceSelection $resolvedComfySource `
                -VerifiedAvailability $exactComfyState.Availability `
                -VerifyLocalPayloadHashes:$verifyLocalPayloadHashes
            if (-not $comfyRuntimeReady -and
                -not (Test-InstallerContinueOptionalErrors `
                    -Config $config)) {
                throw (New-NonRetryableException -Message (
                    Get-LocalizedText `
                        -Key 'Installer.ComfyUI.RuntimeInstallFailed'
                ))
            }
        }
        if ($config.ComfyUI.Enabled -and $comfyRuntimeReady) {
            if ($pendingComfyUIModels.Count -gt 0) {
                try {
                    Invoke-InstallerComfyUIModelSetup `
                        -Models $pendingComfyUIModels `
                        -Config $config `
                        -ProjectRoot $script:InstallerPackageRoot `
                        -SourceSelection $resolvedComfySource `
                        -VerifyLocalPayloadHashes:$verifyLocalPayloadHashes `
                        -HashCache $comfyHashCache
                }
                catch {
                    if (-not (Test-InstallerContinueOptionalErrors `
                        -Config $config)) {
                        throw
                    }
                    Write-InstallerLog -Level WARN `
                        -Message 'Installer.ComfyUI.ModelsSkipped' `
                        -MessageArguments @($_.Exception.Message) `
                        -Exception $_.Exception
                    Write-InstallerLine -Text (Get-LocalizedText `
                        -Key 'Installer.ComfyUI.ModelsSkipped' `
                        -Arguments @($_.Exception.Message)) -Color Yellow
                }
            }
            else {
                Write-InstallerLog -Level INFO `
                    -Message 'Installer.ComfyUI.ModelsAlreadyInstalled' `
                    -MessageArguments @($comfyUIModels.Count)
            }
            $null = Sync-InstallerComfyUIRequestedModels `
                -Models $comfyUIModels -Config $config `
                -ProjectRoot $script:InstallerPackageRoot `
                -VerifyHash:$verifyLocalPayloadHashes `
                -HashCache $comfyHashCache
        }
        else {
            $config.ComfyUI.Enabled = $false
            $config.ComfyUI.Requested = @()
        }
        $ConfigPath = Save-EffectiveInstallerConfig -Config $config
    }
    else {
        Set-InstallerOptionalComponents -Config $config `
            -InstallOpenWebUI ([bool]$config.OpenWebUI.Enabled) `
            -InstallVoice ([bool]$config.Voice.Enabled)
        $ollamaDependency = Get-InstallerOllamaDependency -Config $config
        $ollamaDependency.Required = [bool]$config.Ollama.Enabled
        $resumePowerShellHandoff = `
            Invoke-InstallerPowerShellRuntimeHandoff `
                -Config $config -Reason Resume
        if ($resumePowerShellHandoff.HandedOff) {
            Complete-InstallerPowerShellHandoff `
                -ExitCode ([int]$resumePowerShellHandoff.ExitCode)
            exit ([int]$resumePowerShellHandoff.ExitCode)
        }
        $verificationStartKey = if ($verifyLocalPayloadHashes) {
            'Installer.SourceVerification.Starting'
        }
        else {
            'Installer.SourceVerification.StartingWithoutPayloadHashes'
        }
        Write-InstallerLog -Level INFO -Message $verificationStartKey
        if ($OptionalErrorMode -ne 'Prompt') {
            $config.Installation.ContinueOnOptionalError = `
                $OptionalErrorMode -eq 'Continue'
        }
        Write-InstallerLog -Level INFO `
            -Message 'Installer.SourceVerification.Dependencies'
        $dependencySourceResult = Set-InstallerResumeDependencySources `
            -Config $config -Selection $DependencySourceSelection
        if ($dependencySourceResult -cne 'Configured') {
            throw 'Resume kurulum kaynaklari yapilandirilamadi.'
        }
        $hardware = Get-InstallerHardwareProfile -Config $config
        if ($config.Ollama.Enabled) {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.SourceVerification.Ollama'
            $savedOllamaSource = [string]$ollamaDependency.InstallSource
            $resumeOllamaSource = if (
                $OllamaSourceSelection -ne 'Prompt'
            ) {
                $OllamaSourceSelection
            }
            elseif ($savedOllamaSource -in @(
                'Local', 'Online', 'Automatic'
            )) {
                $savedOllamaSource
            }
            else {
                'Automatic'
            }
            $resolvedOllamaSource = Read-InstallerOllamaInstallSource `
                -Config $config -Selection $resumeOllamaSource
            if ($resolvedOllamaSource -eq 'Exit') {
                Exit-InstallerSelection `
                    -Summary (Get-LocalizedText `
                        -Key 'Installer.Operation.OllamaSourceCancelled')
            }
            $resumeDesiredModelNames = @(
                Get-InstallerDesiredOllamaModelNames `
                    -Config $config -Hardware $hardware
            )
            $resumeModelHashCache = @{}
            Write-InstallerLog -Level INFO `
                -Message 'Installer.SourceVerification.Models'
            $resumeInstalledModelNames = @(
                Get-InstallerInstalledModelNames -Config $config `
                    -VerifyHash:$verifyLocalPayloadHashes `
                    -ModelNames $resumeDesiredModelNames `
                    -HashCache $resumeModelHashCache
            )
            $resumeAnyModelInstalled =
                $resumeInstalledModelNames.Count -gt 0 -or
                (Test-InstallerAnyOllamaModelInstalled -Config $config)
            $resumeModelsAlreadyInstalled = $false
            if ($resumeAnyModelInstalled) {
                $resumeModelSelection = `
                    Get-InstallerRetainedModelSelection `
                        -Config $config `
                        -InstalledNames $resumeInstalledModelNames `
                        -AnyInstalled $resumeAnyModelInstalled `
                        -PreferInstalled
                Set-InstallerModelSelection -Config $config `
                    -Selection $resumeModelSelection
                $resumeModelsAlreadyInstalled =
                    $resumeModelSelection -eq 'Skip' -or
                    (Test-InstallerRequestedModelsInstalled `
                        -Config $config `
                        -InstalledNames $resumeInstalledModelNames)
            }
            $resumePendingOllamaModelNames = @(
                Get-InstallerMissingOllamaModelNames -Config $config `
                    -InstalledNames $resumeInstalledModelNames `
                    -Hardware $hardware
            )
            if ($resumeModelsAlreadyInstalled) {
                $config.Models.LocalPackageImport.SelectedPackages = @()
                $config.Models | Add-Member `
                    -NotePropertyName InstallSource `
                    -NotePropertyValue Automatic -Force
            }
            else {
                $savedModelSource = $config.Models.PSObject.Properties[
                    'InstallSource'
                ]
                $resumeModelSource = if (
                    $ModelSourceSelection -ne 'Prompt'
                ) {
                    $ModelSourceSelection
                }
                elseif ($null -ne $savedModelSource -and
                    [string]$savedModelSource.Value -in @(
                        'Local', 'Online', 'Automatic'
                    )) {
                    [string]$savedModelSource.Value
                }
                else {
                    'Automatic'
                }
                $resolvedModelSource = Set-InstallerLocalPackageSelection `
                    -Config $config -Hardware $hardware `
                    -SourceSelection $resumeModelSource `
                    -ModelNames $resumePendingOllamaModelNames `
                    -VerifyLocalContentHash:$verifyLocalPayloadHashes
                if ($resolvedModelSource -eq 'Exit') {
                    Exit-InstallerSelection `
                        -Summary (Get-LocalizedText `
                            -Key 'Installer.Operation.ModelSourceCancelled')
                }
            }
        }
        else {
            $config.Models.LocalPackageImport.SelectedPackages = @()
            $resumePendingOllamaModelNames = @()
        }
        if ($config.ComfyUI.Enabled) {
            $null = Assert-InstallerComfyUIDriverPreflight `
                -Config $config -Hardware $hardware
        }
        if ($config.ComfyUI.Enabled) {
            Write-InstallerLog -Level INFO `
                -Message 'Installer.SourceVerification.ComfyUI'
            $requestedModels = @(Get-InstallerComfyUICatalog `
                -Config $config `
                -ProjectRoot $script:InstallerPackageRoot |
                Where-Object {
                    $_.Name -iin @($config.ComfyUI.Requested)
                })
            $resumeRequestedNames = @($config.ComfyUI.Requested |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_)
                })
            if ($requestedModels.Count -ne
                $resumeRequestedNames.Count) {
                throw 'Resume ComfyUI model katalogu canonical degil.'
            }
            $savedComfySource = $config.ComfyUI.PSObject.Properties[
                'InstallSource'
            ]
            $resumeSourceSelection = if (
                $ComfyUISourceSelection -ne 'Prompt'
            ) {
                $ComfyUISourceSelection
            }
            elseif ($null -ne $savedComfySource -and
                [string]$savedComfySource.Value -in @(
                    'Local', 'Online', 'Automatic'
                )) {
                [string]$savedComfySource.Value
            }
            else {
                'Automatic'
            }
            $resumePendingComfyModels = @(
                Get-InstallerMissingComfyUIModels `
                    -Models $requestedModels -Config $config `
                    -ProjectRoot $script:InstallerPackageRoot `
                    -VerifyHash:$verifyLocalPayloadHashes `
                    -HashCache $comfyHashCache
            )
            $resumeAvailability = $null
            $resolvedComfySource = Read-InstallerComfyUISource `
                -Models $resumePendingComfyModels -Config $config `
                -ProjectRoot $script:InstallerPackageRoot `
                -RequiredNodeModelNames $resumeRequestedNames `
                -Selection $resumeSourceSelection `
                -VerifyLocalIdentity $verifyLocalPayloadHashes `
                -HashCache $comfyHashCache `
                -AvailabilityResult ([ref]$resumeAvailability)
            $verifiedComfyAvailability = $resumeAvailability
            $config.ComfyUI | Add-Member `
                -NotePropertyName InstallSource `
                -NotePropertyValue $resolvedComfySource -Force
        }
        else {
            $requestedModels = @()
            $resumePendingComfyModels = @()
        }
        $resumeIdentityConfig = `
            New-InstallerPendingPayloadConfiguration `
                -Config $config `
                -OllamaModelNames $resumePendingOllamaModelNames `
                -ComfyUIModels $resumePendingComfyModels `
                -RequiredNodeModels $requestedModels
        $null = Assert-InstallerDeferredPackageIdentity `
            -Root $script:InstallerPackageRoot `
            -Config $resumeIdentityConfig
        $verificationCompletedKey = if ($verifyLocalPayloadHashes) {
            'Installer.SourceVerification.Completed'
        }
        else {
            'Installer.SourceVerification.CompletedWithoutPayloadHashes'
        }
        Write-InstallerLog -Level INFO -Message $verificationCompletedKey
        if ($config.ComfyUI.Enabled) {
            $comfyRuntimeReady = Install-InstallerComfyUIRuntime `
                -Config $config -SourceSelection $resolvedComfySource `
                -VerifiedAvailability $verifiedComfyAvailability `
                -VerifyLocalPayloadHashes:$verifyLocalPayloadHashes
            if (-not $comfyRuntimeReady) {
                if (-not (Test-InstallerContinueOptionalErrors `
                    -Config $config)) {
                    throw (New-NonRetryableException -Message (
                        Get-LocalizedText `
                            -Key 'Installer.ComfyUI.RuntimeInstallFailed'
                    ))
                }
                $config.ComfyUI.Enabled = $false
                $config.ComfyUI.Requested = @()
            }
            elseif ($requestedModels.Count -gt 0) {
                if ($resumePendingComfyModels.Count -gt 0) {
                    try {
                        Invoke-InstallerComfyUIModelSetup `
                            -Models $resumePendingComfyModels `
                            -Config $config `
                            -ProjectRoot $script:InstallerPackageRoot `
                            -SourceSelection $resolvedComfySource `
                            -VerifyLocalPayloadHashes:$verifyLocalPayloadHashes `
                            -HashCache $comfyHashCache
                    }
                    catch {
                        if (-not (Test-InstallerContinueOptionalErrors `
                            -Config $config)) {
                            throw
                        }
                        Write-InstallerLog -Level WARN `
                            -Message 'Installer.ComfyUI.ModelsSkipped' `
                            -MessageArguments @($_.Exception.Message) `
                            -Exception $_.Exception
                        Write-InstallerLine -Text (Get-LocalizedText `
                            -Key 'Installer.ComfyUI.ModelsSkipped' `
                            -Arguments @($_.Exception.Message)) `
                            -Color Yellow
                    }
                }
                else {
                    Write-InstallerLog -Level INFO `
                        -Message 'Installer.ComfyUI.ModelsAlreadyInstalled' `
                        -MessageArguments @($requestedModels.Count)
                }
                $null = Sync-InstallerComfyUIRequestedModels `
                    -Models $requestedModels -Config $config `
                    -ProjectRoot $script:InstallerPackageRoot `
                    -VerifyHash:$verifyLocalPayloadHashes `
                    -HashCache $comfyHashCache
            }
        }
        $ConfigPath = Save-EffectiveInstallerConfig -Config $config
    }
    $minimumVersion = [version]$config.MinimumPowerShellVersion
    if ($PSVersionTable.PSVersion -lt $minimumVersion) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.PowerShellUnavailable' `
            -Arguments @($minimumVersion))
    }
    $pwsh = Get-InstallerCurrentPowerShellExecutable
    $config.Installation.PowerShellPath = $pwsh
    $ConfigPath = Save-EffectiveInstallerConfig -Config $config
    if ($config.ComfyUI.Enabled) {
        $comfyPreparationResult = `
            Prepare-InstallerComfyUIRuntime -Config $config `
                -EffectiveConfigPath $ConfigPath
        if ($comfyPreparationResult -isnot [bool]) {
            throw [IO.InvalidDataException]::new(
                'ComfyUI hazirlik sonucu Boolean degil.'
            )
        }
    }
    if ($config.ComfyUI.Enabled -and
        -not [bool]$comfyPreparationResult) {
        if (-not (Test-InstallerContinueOptionalErrors -Config $config)) {
            throw (New-NonRetryableException -Message (
                Get-LocalizedText `
                    -Key 'Installer.ComfyUI.RuntimeInstallFailed'
            ))
        }
        $config.ComfyUI.Enabled = $false
        $config.ComfyUI.Requested = @()
        $ConfigPath = Save-EffectiveInstallerConfig -Config $config
    }
    $enginePath = Join-Path $PSScriptRoot 'Engine.ps1'
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
        throw (Get-LocalizedText -Key 'Installer.Error.EngineMissing' `
            -Arguments @($enginePath))
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.Engine.Starting' `
        -MessageArguments @($pwsh)
    $engineArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-File', $enginePath,
        '-ConfigPath', $ConfigPath,
        '-PackageRoot', $script:InstallerPackageRoot,
        '-SessionId', $SessionId
    )
    if ($Resume) {
        $engineArguments += '-Resume'
    }
    if ($ForceRepair) {
        $engineArguments += '-ForceRepair'
    }
    if ($GenerateReport) {
        $engineArguments += '-GenerateReport'
    }
    $engineArguments += '-NoPause'
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $engineArguments += '-Verbose'
    }
    & $pwsh $engineArguments
    $engineExitCode = $LASTEXITCODE
    if ($engineExitCode -ne 0) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.EngineExitCode' `
            -Arguments @($engineExitCode))
    }
    $installedRoot = Resolve-InstallerPath -Path $config.Paths.Root
    $startupScript = Join-Path $installedRoot 'Start.ps1'
    $installedConfigPath = Join-Path $installedRoot `
        'Data\Configs\config.json'
    if (-not (Test-Path -LiteralPath $startupScript -PathType Leaf)) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.RequiredFileMissing' `
            -Arguments @($startupScript))
    }
    if (-not (Test-Path -LiteralPath $installedConfigPath `
        -PathType Leaf)) {
        throw (Get-LocalizedText `
            -Key 'Installer.Error.RequiredFileMissing' `
            -Arguments @($installedConfigPath))
    }
    $preStartInstalledConfig = Read-JsonFile `
        -Path $installedConfigPath
    $null = Test-DeploymentConfiguration `
        -Config $preStartInstalledConfig
    $installedLogsPath = Resolve-ConfigurationPath `
        -Path ([string]$preStartInstalledConfig.Paths.Logs) `
        -BasePath $installedRoot
    $startupLogSnapshot = Get-InstallerDeploymentLogSnapshot `
        -LogsPath $installedLogsPath
    $startupArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $startupScript,
        '-ConfigPath', $installedConfigPath,
        '-OllamaMode', 'Keep',
        '-OpenWebUIMode', 'Keep',
        '-VoiceMode', 'Keep',
        '-ComfyUIMode', 'Keep',
        '-NoSupervise',
        '-NoPause'
    )
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $startupArguments += '-Verbose'
    }
    & $pwsh @startupArguments
    $startupExitCode = [int]$LASTEXITCODE
    if ($startupExitCode -ne 0) {
        throw (Get-LocalizedText `
            -Key 'Launcher.Error.ScriptExitCode' `
            -Arguments @('Start.ps1', $startupExitCode))
    }
    $installedConfig = Read-JsonFile -Path $installedConfigPath
    $null = Test-DeploymentConfiguration -Config $installedConfig
    $optionalEvents = @(Get-InstallerOptionalDegradationEvents `
        -LogsPath $installedLogsPath -Snapshot $startupLogSnapshot)
    foreach ($moduleName in @(
        '07_Ollama.psm1', '09_WebUI.psm1', '10_Runtime.psm1'
    )) {
        $modulePath = Join-Path $installedRoot "Modules\$moduleName"
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw (Get-LocalizedText `
                -Key 'Installer.Error.RequiredFileMissing' `
                -Arguments @($modulePath))
        }
        Import-Module $modulePath -Force -ErrorAction Stop `
            -Verbose:$false
    }
    $config = $installedConfig
    $script:InstallerConfiguration = $config
    $healthyComponents = @(Get-InstallerHealthyEndpointComponents `
        -Config $config)
    $completion = Get-InstallerCompletionAssessment `
        -BeforeConfig $completionBaselineConfig `
        -AfterConfig $config `
        -HealthyComponents $healthyComponents `
        -OptionalEvents $optionalEvents
    $uris = Get-WinlamaServiceUris -Config $config
    if ('Ollama' -in $healthyComponents) {
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Startup.Endpoint.OllamaLocal' `
            -Arguments @($uris.OllamaLocal)) `
            -Color Cyan
    }
    if ('OpenWebUI' -in $healthyComponents) {
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Startup.Endpoint.OpenWebUILocal' `
            -Arguments @($uris.OpenWebUILocal)) -Color Cyan
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Startup.Endpoint.OpenWebUITemporary' `
            -Arguments @($uris.OpenWebUITemporary)) `
            -Color Green
    }
    if ('Voice' -in $healthyComponents) {
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Startup.Endpoint.VoiceLocal' `
            -Arguments @($uris.VoiceLocal)) -Color Cyan
    }
    if ('ComfyUI' -in $healthyComponents) {
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Startup.Endpoint.ComfyUILocal' `
            -Arguments @($uris.ComfyUILocal)) -Color Cyan
    }
    if ('Ollama' -in $healthyComponents -and
        -not [string]::IsNullOrWhiteSpace($uris.OllamaLan)) {
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Startup.Endpoint.OllamaLan' `
            -Arguments @($uris.OllamaLan)) `
            -Color Cyan
    }
    if ('OpenWebUI' -in $healthyComponents -and
        -not [string]::IsNullOrWhiteSpace($uris.OpenWebUILan)) {
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Startup.Endpoint.OpenWebUILan' `
            -Arguments @($uris.OpenWebUILan)) `
            -Color Cyan
    }
    if ($completion.HasWarnings) {
        $completionDetails = $completion.Details -join ', '
        Write-InstallerLog -Level WARN `
            -Message 'Installer.CompletedWithWarnings' `
            -MessageArguments @($completionDetails)
        if (-not $NoPause) {
            Complete-WinlamaUIOperation `
                -Summary (Get-LocalizedText `
                    -Key 'Installer.CompletedWithWarnings' `
                    -Arguments @($completionDetails)) `
                -Level WARN -Command CIKIS
        }
        exit ([int]$completion.ExitCode)
    }
    Write-InstallerLog -Level INFO `
        -Message 'Installer.Completed'
    if (-not $NoPause) {
        Complete-WinlamaUIOperation `
            -Summary (Get-LocalizedText `
                -Key 'Installer.Operation.Completed') `
            -Level SUCCESS -Command CIKIS
    }
    exit 0
}
catch {
    Write-InstallerFailure -ErrorRecord $_
    Wait-OnInstallerFailure
    exit 1
}