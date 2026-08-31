[CmdletBinding()]
param(
    [ValidateSet('None', 'Install', 'Uninstall', 'Repair')]
    [string]$InitialAction = 'None',
    [switch]$ValidateOnly,
    [switch]$NoPause,
    [switch]$RunMeHost,
    [string]$InitiatingUserSid = '',
    [string]$InitiatingUserProfile = '',
    [string]$SessionId = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$parsedSessionId = [guid]::Empty
if ([string]::IsNullOrWhiteSpace($SessionId)) {
    $SessionId = [guid]::NewGuid().ToString('D')
}
elseif (-not [guid]::TryParseExact(
    $SessionId,
    'D',
    [ref]$parsedSessionId
) -or $parsedSessionId -eq [guid]::Empty) {
    throw [IO.InvalidDataException]::new(
        'Launcher oturum kimligi gecersiz.'
    )
}
function ConvertFrom-LauncherJson {
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
function Write-LauncherBootstrapRule {
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
function Write-LauncherBootstrapLine {
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
            $Host.UI.WriteLine(
                $Color,
                [ConsoleColor]::Black,
                ('| {0} |' -f $part.PadRight(96))
            )
            $remaining = if ($remaining.Length -le $length) {
                ''
            }
            else {
                $remaining.Substring($length)
            }
        } while ($remaining.Length -gt 0)
    }
}
function Get-LauncherBootstrapStatusStyle {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL',
            'SKIP'
        )]
        [string]$Level
    )
    $style = switch ($Level) {
        'INFO' {
            [pscustomobject]@{ Label = 'BILGI'; Color = 'Cyan' }
        }
        'STEP' { [pscustomobject]@{ Label = 'ADIM'; Color = 'Blue' } }
        'SUCCESS' { [pscustomobject]@{ Label = 'TAMAM'; Color = 'Green' } }
        'WARN' { [pscustomobject]@{ Label = 'UYARI'; Color = 'Yellow' } }
        'ERROR' { [pscustomobject]@{ Label = 'HATA'; Color = 'Red' } }
        'DETAIL' { [pscustomobject]@{ Label = 'DETAY'; Color = 'Gray' } }
        'SKIP' { [pscustomobject]@{ Label = 'ATLA'; Color = 'Magenta' } }
    }
    return $style
}
function Get-LauncherBootstrapStatusWidth {
    $width = 0
    foreach ($level in @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    )) {
        $style = Get-LauncherBootstrapStatusStyle -Level $level
        $width = [Math]::Max($width, $style.Label.Length)
    }
    return $width
}
function Write-LauncherBootstrapStatus {
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
        & $command -Level $Level -Message $Message
        return
    }
    $style = Get-LauncherBootstrapStatusStyle -Level $Level
    $width = Get-LauncherBootstrapStatusWidth
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
function Write-LauncherBootstrapError {
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
    Write-LauncherBootstrapRule -Character '='
    Write-LauncherBootstrapLine -Text 'ISLEM OZETI' -Color Cyan
    Write-LauncherBootstrapStatus -Level ERROR `
        -Message $Context
    Write-LauncherBootstrapStatus -Level ERROR `
        -Message $ErrorRecord.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace(
        $ErrorRecord.InvocationInfo.PositionMessage
    )) {
        Write-LauncherBootstrapStatus -Level DETAIL -Message (
            $ErrorRecord.InvocationInfo.PositionMessage.Trim()
        )
    }
    Write-LauncherBootstrapRule -Character '='
}
function Format-LauncherBootstrapInputLine {
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
function ConvertFrom-LauncherBootstrapReadValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    if ($null -eq $Value) {
        throw [IO.EndOfStreamException]::new(
            'Standart girdi kapali; zorunlu komut okunamadi.'
        )
    }
    return [string]$Value
}
function Test-LauncherBootstrapExactExit {
    param([AllowNull()][string]$Value)
    return $null -ne $Value -and $Value -ceq 'CIKIS'
}
function Assert-LauncherBootstrapInputContracts {
    $eofRejected = $false
    try {
        $null = ConvertFrom-LauncherBootstrapReadValue -Value $null
    }
    catch [IO.EndOfStreamException] {
        $eofRejected = $true
    }
    if (-not $eofRejected -or
        (ConvertFrom-LauncherBootstrapReadValue -Value '') -cne '') {
        throw 'Launcher bootstrap EOF girdi sozlesmesi gecersiz.'
    }
    foreach ($invalid in @('', 'C', 'cikis', 'Cikis', ' CIKIS ')) {
        if (Test-LauncherBootstrapExactExit -Value $invalid) {
            throw 'Launcher bootstrap kesin CIKIS sozlesmesi gecersiz.'
        }
    }
    if (-not (Test-LauncherBootstrapExactExit -Value 'CIKIS')) {
        throw 'Launcher bootstrap kesin CIKIS sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Launcher.BootstrapEOF'
    Write-Verbose 'WINLAMA_UI_OK:Launcher.BootstrapExactExit'
    return $true
}
function Read-LauncherBootstrapRawInput {
    if ([Console]::IsInputRedirected) {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-LauncherBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine(
            [ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-LauncherBootstrapInputLine -Value $value)
        )
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
            $Host.UI.Write(
                [ConsoleColor]::White,
                [ConsoleColor]::Black,
                (Format-LauncherBootstrapInputLine -Value $value)
            )
            [Console]::SetCursorPosition(
                [Math]::Min(98, 13 + $display.Length),
                $row
            )
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
        $Host.UI.WriteLine(
            [ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-LauncherBootstrapInputLine -Value $value)
        )
        return $value
    }
    catch {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-LauncherBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine(
            [ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-LauncherBootstrapInputLine -Value $value)
        )
        return $value
    }
}
function Read-LauncherBootstrapInput {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Label = ('Se{0}iminiz' -f [char]0x00E7)
    )
    $command = Get-Command Read-WinlamaUIInput `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return & $command -Prompt $Prompt -Label $Label `
            -Hint 'Yalniz tam olarak CIKIS yazin.'
    }
    Write-LauncherBootstrapRule
    Write-LauncherBootstrapStatus -Level INFO `
        -Message $Prompt
    Write-LauncherBootstrapStatus -Level DETAIL `
        -Message 'Yalniz tam olarak CIKIS yazin.'
    Write-LauncherBootstrapRule
    $value = Read-LauncherBootstrapRawInput
    Write-LauncherBootstrapRule
    return $value
}
trap {
    Write-LauncherBootstrapError -Context 'Beklenmeyen hata.' `
        -ErrorRecord $_
    if (-not $ValidateOnly -and -not $NoPause) {
        do {
            $answer = Read-LauncherBootstrapInput `
                -Prompt 'Oturumu kapatmak icin CIKIS yazin.'
            if (-not (Test-LauncherBootstrapExactExit -Value $answer)) {
                Write-LauncherBootstrapStatus -Level WARN `
                    -Message 'Bos veya gecersiz komut kabul edilmedi.'
            }
        } while (-not (Test-LauncherBootstrapExactExit -Value $answer))
    }
    exit 1
}
$localizationModule = Join-Path $PSScriptRoot `
    'Modules\Localization\LocalizationManager.psm1'
function Resolve-LauncherConfigPath {
    param([string]$BasePath)
    foreach ($cand in @(
        (Join-Path $BasePath 'Data\Configs\config.json'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Winlama\Data\Configs\config.json')
    )) {
        if (Test-Path -LiteralPath $cand -PathType Leaf) {
            return [IO.Path]::GetFullPath($cand)
        }
    }
    throw [IO.FileNotFoundException]::new(
        'Canonical yapilandirma dosyasi bulunamadi.'
    )
}
if (Test-Path -LiteralPath $localizationModule -PathType Leaf) {
    try {
        Import-Module $localizationModule -Force -ErrorAction Stop
        $configPath = Resolve-LauncherConfigPath -BasePath $PSScriptRoot
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $config = Get-Content -LiteralPath $configPath -Raw `
                -Encoding UTF8 | ConvertFrom-LauncherJson
            $null = Initialize-Localization -ProjectRoot $PSScriptRoot -Configuration $config.Localization
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
$configPath = Resolve-LauncherConfigPath -BasePath $PSScriptRoot
$config = Get-Content -LiteralPath $configPath -Raw `
    -Encoding UTF8 | ConvertFrom-LauncherJson
Import-Module (Join-Path $PSScriptRoot `
    'Modules\00_Common.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot `
    'Modules\UI\ConsoleUI.psm1') -Force -ErrorAction Stop
try {
    $host.UI.RawUI.WindowTitle = Get-WinlamaUIString `
        -Key 'Launcher.WindowTitle' `
        -Fallback 'Winlama - Baslatici'
}
catch {
    Write-Verbose ('Pencere basligi ayarlanamadi: {0}' -f `
        $_.Exception.Message)
}
function Test-LauncherElevatedBufferClear {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('None', 'Install', 'Uninstall', 'Repair')]
        [string]$Action,
        [AllowEmptyString()][string]$UserSid,
        [AllowEmptyString()][string]$UserProfile,
        [bool]$ValidationMode
    )
    return -not $ValidationMode -and $Action -ne 'None' -and
        -not [string]::IsNullOrWhiteSpace($UserSid) -and
        -not [string]::IsNullOrWhiteSpace($UserProfile)
}
function Initialize-LauncherConsoleBuffer {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('None', 'Install', 'Uninstall', 'Repair')]
        [string]$Action,
        [AllowEmptyString()][string]$UserSid,
        [AllowEmptyString()][string]$UserProfile,
        [bool]$ValidationMode,
        [scriptblock]$Initializer
    )
    if (-not (Test-LauncherElevatedBufferClear -Action $Action `
        -UserSid $UserSid -UserProfile $UserProfile `
        -ValidationMode $ValidationMode)) {
        return $false
    }
    if ($null -eq $Initializer) {
        Initialize-WinlamaConsole -ClearBuffer
    }
    else {
        & $Initializer
    }
    return $true
}
$null = Initialize-LauncherConsoleBuffer -Action $InitialAction `
    -UserSid $InitiatingUserSid -UserProfile $InitiatingUserProfile `
    -ValidationMode ([bool]$ValidateOnly)
$script:LauncherLogPath = $null
function Write-LauncherLog {
    param(
        [Parameter(Mandatory)][string]$Event,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',
        [string]$ErrorText = '',
        [int]$ChildProcessId = 0
    )
    if ($ValidateOnly) {
        $childProcessText = if ($ChildProcessId -gt 0) {
            "|CHILD_PID=$ChildProcessId"
        }
        else {
            ''
        }
        Write-Verbose (
            "LAUNCHER_LOG|$Level|$Event|$Script|$Message" +
                $childProcessText
        )
        return
    }
    try {
        if ([string]::IsNullOrWhiteSpace($script:LauncherLogPath)) {
            $script:LauncherLogPath = New-WinlamaTimestampedFile `
                -Directory (Join-Path ([IO.Path]::GetTempPath()) `
                    'Winlama-Logs') `
                -Extension '.log'
        }
        $displayLevel = switch ($Level) {
            'ERROR' { Get-LocalizedText -Key 'Common.Level.Error' }
            'WARN' { Get-LocalizedText -Key 'Common.Level.Warning' }
            default { Get-LocalizedText -Key 'Common.Level.Info' }
        }
        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            level = $Level
            displayLevel = $displayLevel
            moduleCode = 'LAUNCHER'
            eventCode = $Event
            script = $Script
            message = $Message
            error = $ErrorText
            sessionId = $SessionId
            processId = $PID
            childProcessId = if ($ChildProcessId -gt 0) {
                $ChildProcessId
            }
            else {
                $null
            }
        } | ConvertTo-Json -Compress -Depth 5
        $stream = [IO.File]::Open(
            $script:LauncherLogPath,
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
                $writer.WriteLine($entry)
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
    catch {
        Write-LauncherBootstrapStatus -Level WARN -Message (
            "Launcher gunlugu yazilamadi: $($_.Exception.Message)"
        )
    }
}
function Get-LauncherPowerShellPath {
    param([Parameter(Mandatory)][version]$MinimumVersion)
    $candidates = [Collections.Generic.List[string]]::new()
    if ($null -ne $config.Installation -and
        -not [string]::IsNullOrWhiteSpace(
            $config.Installation.PowerShellPath
        )) {
        $candidates.Add(
            [Environment]::ExpandEnvironmentVariables(
                $config.Installation.PowerShellPath
            )
        )
    }
    $candidates.Add((Join-Path $env:ProgramFiles `
        'PowerShell\7\pwsh.exe'))
    $command = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $candidates.Add($command.Source)
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        try {
            $versionText = & $candidate -NoLogo -NoProfile `
                -Command '$PSVersionTable.PSVersion.ToString()' `
                2>$null
            if ($LASTEXITCODE -eq 0 -and
                [version]$versionText.Trim() -ge $MinimumVersion) {
                return [IO.Path]::GetFullPath($candidate)
            }
        }
        catch {
            Write-Verbose ('PowerShell adayi kullanilamadi: {0} | {1}' `
                -f $candidate, $_.Exception.Message)
        }
    }
    return $null
}
function Get-LauncherRequiredPowerShellVersion {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($line in Get-Content -LiteralPath $Path `
        -TotalCount 20 -Encoding UTF8) {
        if ($line -match `
            '^\s*#requires\s+-version\s+(?<Version>\d+(?:\.\d+){1,3})') {
            return [version]$Matches['Version']
        }
    }
    return [version]'5.1'
}
function Get-LauncherDiagnosticRoots {
    param(
        [AllowNull()][object]$Configuration = $config,
        [string]$PackageRoot = $PSScriptRoot
    )
    $candidates = [Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path ([IO.Path]::GetTempPath()) `
        'Winlama-Logs'))
    if ($null -ne $Configuration) {
        $pathsProperty = $Configuration.PSObject.Properties['Paths']
        if ($null -ne $pathsProperty) {
            $logsBase = $PackageRoot
            $rootProperty = $pathsProperty.Value.PSObject.Properties['Root']
            if ($null -ne $rootProperty -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$rootProperty.Value
                )) {
                $logsBase = Resolve-ConfigurationPath `
                    -Path ([string]$rootProperty.Value) `
                    -BasePath $PackageRoot
            }
            $logsProperty = $pathsProperty.Value.PSObject.Properties['Logs']
            if ($null -ne $logsProperty -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$logsProperty.Value
                )) {
                $candidates.Add((Resolve-ConfigurationPath `
                    -Path ([string]$logsProperty.Value) `
                    -BasePath $logsBase))
            }
        }
    }
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $roots = [Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        $resolved = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        if ($seen.Add($resolved)) {
            $roots.Add($resolved)
        }
    }
    return $roots.ToArray()
}
function Get-LauncherLogFiles {
    param(
        [Parameter(Mandatory)][string[]]$Directories,
        [scriptblock]$FileProvider
    )
    if ($null -eq $FileProvider) {
        $FileProvider = {
            param([string]$Directory)
            if (-not (Test-Path -LiteralPath $Directory `
                -PathType Container)) {
                return @()
            }
            return @(Get-ChildItem -LiteralPath $Directory `
                -File -Filter '*.log' -ErrorAction SilentlyContinue)
        }
    }
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $files = [Collections.Generic.List[object]]::new()
    foreach ($directory in $Directories) {
        foreach ($file in @(& $FileProvider $directory)) {
            if ($null -eq $file -or
                [string]::IsNullOrWhiteSpace([string]$file.FullName)) {
                continue
            }
            $path = [IO.Path]::GetFullPath([string]$file.FullName)
            if ($seen.Add($path)) {
                $files.Add($file)
            }
        }
    }
    return $files.ToArray()
}
function Get-LauncherLogSnapshot {
    param(
        [string[]]$Directories = @(Get-LauncherDiagnosticRoots),
        [scriptblock]$FileProvider
    )
    $snapshot = @{}
    foreach ($file in @(Get-LauncherLogFiles `
        -Directories $Directories -FileProvider $FileProvider)) {
        $snapshot[$file.FullName] = $file.Length
    }
    return $snapshot
}
function Read-LauncherLogTail {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Offset
    )
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        )
        if ($Offset -lt 0 -or $Offset -gt $stream.Length) {
            $Offset = 0
        }
        $null = $stream.Seek($Offset, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new(
            $stream,
            [Text.UTF8Encoding]::new($false),
            $true
        )
        $content = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($content)) {
            return @()
        }
        return @([regex]::Split($content, '\r\n|\n|\r') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        elseif ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}
function Test-LauncherTerminalExit {
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][int]$ErrorCount
    )
    return $ScriptName -eq 'Uninstall.ps1' -and
        $ExitCode -eq 10 -and $ErrorCount -eq 0
}
function Test-LauncherCancelledExit {
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][int]$ErrorCount
    )
    return $ScriptName -in @(
        'Install.ps1', 'Repair.ps1', 'Uninstall.ps1'
    ) -and
        $ExitCode -eq 2 -and $ErrorCount -eq 0
}
function Test-LauncherIncompleteExit {
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][int]$ErrorCount
    )
    return $ScriptName -in @('Install.ps1', 'Repair.ps1') -and
        $ExitCode -eq 3 -and $ErrorCount -eq 0
}
function New-LauncherActionResult {
    param(
        [Parameter(Mandatory)][bool]$Terminal,
        [Parameter(Mandatory)][int]$ExitCode
    )
    return [pscustomobject][ordered]@{
        Terminal = $Terminal
        ExitCode = $ExitCode
    }
}
function Get-LauncherHostedCompletionCommand {
    param(
        [ValidateSet(
            'None', 'Install', 'Start', 'Manager', 'OpenWebUI',
            'ComfyUI', 'Uninstall', 'Repair'
        )]
        [string]$Action = $InitialAction,
        [bool]$PauseSuppressed = [bool]$NoPause
    )
    if ($PauseSuppressed -or $Action -ne 'None') {
        return 'CIKIS'
    }
    return 'DEVAM'
}
function Invoke-LauncherHandledExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][int]$ErrorCount,
        [bool]$ShowSummary = (-not [bool]$NoPause),
        [ValidateSet('DEVAM', 'CIKIS')]
        [string]$CompletionCommand = 'DEVAM',
        [scriptblock]$LogWriter,
        [scriptblock]$StatusWriter,
        [scriptblock]$SummaryWriter
    )
    if (Test-LauncherTerminalExit -ScriptName $ScriptName `
        -ExitCode $ExitCode -ErrorCount $ErrorCount) {
        return $true
    }
    $outcome = if (Test-LauncherCancelledExit `
        -ScriptName $ScriptName -ExitCode $ExitCode `
        -ErrorCount $ErrorCount) {
        [pscustomobject]@{
            Event = 'SCRIPT_CANCELLED'
            LogLevel = 'WARN'
            StatusLevel = 'SKIP'
            LogKey = 'Launcher.Log.ScriptCancelled'
            SummaryKey = 'Launcher.Operation.ScriptCancelled'
        }
    }
    elseif (Test-LauncherIncompleteExit `
        -ScriptName $ScriptName -ExitCode $ExitCode `
        -ErrorCount $ErrorCount) {
        [pscustomobject]@{
            Event = 'SCRIPT_INCOMPLETE'
            LogLevel = 'WARN'
            StatusLevel = 'WARN'
            LogKey = 'Launcher.Log.ScriptIncomplete'
            SummaryKey = 'Launcher.Operation.ScriptIncomplete'
        }
    }
    else {
        $null
    }
    if ($null -eq $outcome) {
        return $null
    }
    $logMessage = Get-LocalizedText -Key $outcome.LogKey
    if ($null -eq $LogWriter) {
        Write-LauncherLog -Event $outcome.Event `
            -Script $ScriptName -Message $logMessage `
            -Level $outcome.LogLevel
    }
    else {
        $null = & $LogWriter $outcome.Event $ScriptName `
            $logMessage $outcome.LogLevel
    }
    $summary = Get-LocalizedText -Key $outcome.SummaryKey `
        -Arguments @($ScriptName)
    if ($null -eq $StatusWriter) {
        Write-LauncherBootstrapStatus `
            -Level $outcome.StatusLevel -Message $summary
    }
    else {
        $null = & $StatusWriter $outcome.StatusLevel $summary
    }
    if ($ShowSummary) {
        if ($null -eq $SummaryWriter) {
            Complete-WinlamaUIOperation -Summary $summary `
                -Level $outcome.StatusLevel `
                -Command $CompletionCommand
        }
        else {
            $null = & $SummaryWriter $summary `
                $outcome.StatusLevel $CompletionCommand
        }
    }
    return $false
}
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
function Assert-LauncherRuntimeContracts {
    if (-not (Test-LauncherCancelledExit `
        -ScriptName 'Install.ps1' -ExitCode 2 -ErrorCount 0) -or
        -not (Test-LauncherCancelledExit `
            -ScriptName 'Repair.ps1' -ExitCode 2 -ErrorCount 0) -or
        -not (Test-LauncherCancelledExit `
            -ScriptName 'Uninstall.ps1' -ExitCode 2 -ErrorCount 0) -or
        (Test-LauncherCancelledExit `
            -ScriptName 'Install.ps1' -ExitCode 2 -ErrorCount 1) -or
        (Test-LauncherCancelledExit `
            -ScriptName 'ModelManager.ps1' -ExitCode 2 -ErrorCount 0)) {
        throw 'Launcher iptal cikis testi basarisiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Launcher.CancelledExit'
    if (-not (Test-LauncherIncompleteExit `
        -ScriptName 'Repair.ps1' -ExitCode 3 -ErrorCount 0) -or
        (Test-LauncherIncompleteExit `
            -ScriptName 'Repair.ps1' -ExitCode 3 -ErrorCount 1) -or
        -not (Test-LauncherIncompleteExit `
            -ScriptName 'Install.ps1' -ExitCode 3 -ErrorCount 0) -or
        (Test-LauncherIncompleteExit `
            -ScriptName 'Uninstall.ps1' -ExitCode 3 -ErrorCount 0)) {
        throw 'Launcher eksik cikis testi basarisiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Launcher.IncompleteExit'
    $handledEvents = [Collections.Generic.List[string]]::new()
    $handledWriters = @{
        LogWriter = {
            param($Event, $Script, $Message, $Level)
            $handledEvents.Add(
                "LOG|$Event|$Script|$Level|$Message"
            ) | Out-Null
        }.GetNewClosure()
        StatusWriter = {
            param($Level, $Message)
            $handledEvents.Add(
                "STATUS|$Level|$Message"
            ) | Out-Null
        }.GetNewClosure()
        SummaryWriter = {
            param($Summary, $Level, $Command)
            $handledEvents.Add(
                "SUMMARY|$Level|$Command|$Summary"
            ) | Out-Null
        }.GetNewClosure()
    }
    $cancelledResult = Invoke-LauncherHandledExit `
        -ScriptName 'Install.ps1' -ExitCode 2 -ErrorCount 0 `
        -ShowSummary $true @handledWriters
    $cancelledEvents = @($handledEvents.ToArray())
    $handledEvents.Clear()
    $uninstallCancelledResult = Invoke-LauncherHandledExit `
        -ScriptName 'Uninstall.ps1' -ExitCode 2 -ErrorCount 0 `
        -ShowSummary $true @handledWriters
    $uninstallCancelledEvents = @($handledEvents.ToArray())
    $handledEvents.Clear()
    $incompleteResult = Invoke-LauncherHandledExit `
        -ScriptName 'Repair.ps1' -ExitCode 3 -ErrorCount 0 `
        -ShowSummary $true @handledWriters
    $incompleteEvents = @($handledEvents.ToArray())
    $handledEvents.Clear()
    $installIncompleteResult = Invoke-LauncherHandledExit `
        -ScriptName 'Install.ps1' -ExitCode 3 -ErrorCount 0 `
        -ShowSummary $true @handledWriters
    $installIncompleteEvents = @($handledEvents.ToArray())
    $handledEvents.Clear()
    $initialIncompleteResult = Invoke-LauncherHandledExit `
        -ScriptName 'Install.ps1' -ExitCode 3 -ErrorCount 0 `
        -ShowSummary $true -CompletionCommand CIKIS @handledWriters
    $initialIncompleteEvents = @($handledEvents.ToArray())
    $handledEvents.Clear()
    $terminalResult = Invoke-LauncherHandledExit `
        -ScriptName 'Uninstall.ps1' -ExitCode 10 -ErrorCount 0 `
        -ShowSummary $true @handledWriters
    $terminalEvents = @($handledEvents.ToArray())
    $handledEvents.Clear()
    $normalResult = Invoke-LauncherHandledExit `
        -ScriptName 'Install.ps1' -ExitCode 0 -ErrorCount 0 `
        -ShowSummary $true @handledWriters
    if ($null -eq $cancelledResult -or [bool]$cancelledResult -or
        $cancelledEvents.Count -ne 3 -or
        $cancelledEvents[0] -notlike
            'LOG|SCRIPT_CANCELLED|Install.ps1|WARN|*' -or
        $cancelledEvents[1] -notlike 'STATUS|SKIP|*' -or
        $cancelledEvents[2] -notlike 'SUMMARY|SKIP|DEVAM|*' -or
        @($cancelledEvents | Where-Object {
            $_ -match 'SCRIPT_(?:COMPLETED|FAILED)'
        }).Count -ne 0 -or
        $null -eq $uninstallCancelledResult -or
        [bool]$uninstallCancelledResult -or
        $uninstallCancelledEvents.Count -ne 3 -or
        $uninstallCancelledEvents[0] -notlike
            'LOG|SCRIPT_CANCELLED|Uninstall.ps1|WARN|*' -or
        $uninstallCancelledEvents[1] -notlike 'STATUS|SKIP|*' -or
        $uninstallCancelledEvents[2] -notlike
            'SUMMARY|SKIP|DEVAM|*' -or
        @($uninstallCancelledEvents | Where-Object {
            $_ -match 'SCRIPT_(?:COMPLETED|FAILED)'
        }).Count -ne 0 -or
        $null -eq $incompleteResult -or [bool]$incompleteResult -or
        $incompleteEvents.Count -ne 3 -or
        $incompleteEvents[0] -notlike
            'LOG|SCRIPT_INCOMPLETE|Repair.ps1|WARN|*' -or
        $incompleteEvents[1] -notlike 'STATUS|WARN|*' -or
        $incompleteEvents[2] -notlike 'SUMMARY|WARN|DEVAM|*' -or
        @($incompleteEvents | Where-Object {
            $_ -match 'SCRIPT_(?:COMPLETED|FAILED)'
        }).Count -ne 0 -or
        $null -eq $installIncompleteResult -or
        [bool]$installIncompleteResult -or
        $installIncompleteEvents.Count -ne 3 -or
        $installIncompleteEvents[0] -notlike
            'LOG|SCRIPT_INCOMPLETE|Install.ps1|WARN|*' -or
        $installIncompleteEvents[1] -notlike 'STATUS|WARN|*' -or
        $installIncompleteEvents[2] -notlike
            'SUMMARY|WARN|DEVAM|*' -or
        @($installIncompleteEvents | Where-Object {
            $_ -match 'SCRIPT_(?:COMPLETED|FAILED)'
        }).Count -ne 0 -or
        $null -eq $initialIncompleteResult -or
        [bool]$initialIncompleteResult -or
        $initialIncompleteEvents.Count -ne 3 -or
        $initialIncompleteEvents[2] -notlike
            'SUMMARY|WARN|CIKIS|*' -or
        -not [bool]$terminalResult -or $terminalEvents.Count -ne 0 -or
        $null -ne $normalResult -or $handledEvents.Count -ne 0) {
        throw 'Launcher ozel alt cikis runtime fiksturu basarisiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Launcher.HandledExitRuntime'
    if ((Get-LauncherHostedCompletionCommand `
            -Action None -PauseSuppressed $false) -cne 'DEVAM' -or
        (Get-LauncherHostedCompletionCommand `
            -Action Install -PauseSuppressed $false) -cne 'CIKIS' -or
        (Get-LauncherHostedCompletionCommand `
            -Action None -PauseSuppressed $true) -cne 'CIKIS') {
        throw 'Launcher terminal sahipligi komut matrisi gecersiz.'
    }
    $actionResult = New-LauncherActionResult `
        -Terminal $true -ExitCode 3
    if (-not $actionResult.Terminal -or
        $actionResult.ExitCode -ne 3) {
        throw 'Launcher terminal sonuc nesnesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Launcher.SingleCompletionOwner'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Launcher.ExitCodePropagation'
    if (-not (Test-LauncherTerminalExit `
        -ScriptName 'Uninstall.ps1' -ExitCode 10 -ErrorCount 0)) {
        throw 'Kaldirma terminal cikis testi basarisiz.'
    }
    if ((Test-LauncherTerminalExit `
        -ScriptName 'Uninstall.ps1' -ExitCode 0 -ErrorCount 0) -or
        (Test-LauncherTerminalExit `
            -ScriptName 'Uninstall.ps1' -ExitCode 10 -ErrorCount 1) -or
        (Test-LauncherTerminalExit `
            -ScriptName 'Repair.ps1' -ExitCode 10 -ErrorCount 0)) {
        throw 'Launcher hiyerarsi cikis testi basarisiz.'
    }
    $launcherPath = Join-Path $PSScriptRoot 'Launcher.ps1'
    $length = (Get-Item -LiteralPath $launcherPath `
        -ErrorAction Stop).Length
    if (@(Read-LauncherLogTail -Path $launcherPath `
        -Offset $length).Count -ne 0) {
        throw 'Launcher log kuyruk testi basarisiz.'
    }
    $startedAt = [DateTimeOffset]::Now
    $snapshot = @{ 'C:\Fixture\existing.log' = 10L }
    if ((Get-LauncherLogReadOffset `
        -Path 'C:\Fixture\existing.log' -Length 15 `
        -LastWriteTimeUtc $startedAt.UtcDateTime `
        -StartedAt $startedAt -Snapshot $snapshot) -ne 10 -or
        (Get-LauncherLogReadOffset `
            -Path 'C:\Fixture\existing.log' -Length 10 `
            -LastWriteTimeUtc $startedAt.UtcDateTime `
            -StartedAt $startedAt -Snapshot $snapshot) -ne -1 -or
        (Get-LauncherLogReadOffset `
            -Path 'C:\Fixture\new.log' -Length 10 `
            -LastWriteTimeUtc $startedAt.UtcDateTime `
            -StartedAt $startedAt -Snapshot $snapshot) -ne 0) {
        throw 'Launcher log ofset sozlesmesi basarisiz.'
    }
    $inputLine = Format-LauncherBootstrapInputLine `
        -Value ('0123456789' * 12)
    $selection = 'Se{0}iminiz' -f [char]0x00E7
    if ($inputLine.Length -ne 100 -or
        -not $inputLine.StartsWith(
            ('| {0}: ...' -f $selection)
        ) -or
        -not $inputLine.EndsWith(' |')) {
        throw 'Launcher bootstrap secim geometrisi gecersiz.'
    }
    $fixtureTime = [DateTimeOffset]::Now
    $nestedMessage = [ordered]@{
        level = 'ERROR'
        message = ('x' * 600)
    } | ConvertTo-Json -Compress
    $foreignLine = [ordered]@{
        timestamp = $fixtureTime.ToString('o')
        level = 'ERROR'
        moduleCode = 'INSTALLER'
        eventCode = 'FIXTURE'
        message = 'Eszamanli ilgisiz hata.'
        processId = 41
    } | ConvertTo-Json -Compress
    $matchingLine = [ordered]@{
        timestamp = $fixtureTime.ToString('o')
        level = 'ERROR'
        moduleCode = 'INSTALLER'
        eventCode = 'FIXTURE'
        message = $nestedMessage
        processId = 42
    } | ConvertTo-Json -Compress
    $fatalLine = [ordered]@{
        timestamp = $fixtureTime.ToString('o')
        level = 'FATAL'
        moduleCode = 'ENGINE'
        eventCode = 'FIXTURE_FATAL'
        message = 'Canonical fatal fixture.'
        processId = 42
    } | ConvertTo-Json -Compress
    $fixtureSessionId = [guid]::NewGuid().ToString('D')
    $descendantLine = [ordered]@{
        timestamp = $fixtureTime.ToString('o')
        level = 'ERROR'
        moduleCode = 'ENGINE'
        eventCode = 'FIXTURE_DESCENDANT'
        message = 'Ayni oturumdaki alt surec hatasi.'
        processId = 99
        sessionId = $fixtureSessionId
    } | ConvertTo-Json -Compress
    $foreignSessionLine = [ordered]@{
        timestamp = $fixtureTime.ToString('o')
        level = 'ERROR'
        moduleCode = 'ENGINE'
        eventCode = 'FIXTURE_FOREIGN_SESSION'
        message = 'Baska oturumdaki hata.'
        processId = 42
        sessionId = [guid]::NewGuid().ToString('D')
    } | ConvertTo-Json -Compress
    $foreignFailure = ConvertFrom-LauncherChildLogLine `
        -Line $foreignLine -Path 'C:\Fixture\child.log' `
        -Offset 10 -TailLine 1 -StartedAt $fixtureTime `
        -ExpectedProcessId 42 -ExpectedScriptName 'Install.ps1'
    $matchingFailure = ConvertFrom-LauncherChildLogLine `
        -Line $matchingLine -Path 'C:\Fixture\child.log' `
        -Offset 10 -TailLine 2 -StartedAt $fixtureTime `
        -ExpectedProcessId 42 -ExpectedScriptName 'Install.ps1'
    $fatalFailure = ConvertFrom-LauncherChildLogLine `
        -Line $fatalLine -Path 'C:\Fixture\child.log' `
        -Offset 10 -TailLine 3 -StartedAt $fixtureTime `
        -ExpectedProcessId 42 -ExpectedScriptName 'Install.ps1'
    $descendantFailure = ConvertFrom-LauncherChildLogLine `
        -Line $descendantLine -Path 'C:\Fixture\child.log' `
        -Offset 10 -TailLine 6 -StartedAt $fixtureTime `
        -ExpectedProcessId 42 -ExpectedScriptName 'Install.ps1' `
        -ExpectedSessionId $fixtureSessionId
    $foreignSessionFailure = ConvertFrom-LauncherChildLogLine `
        -Line $foreignSessionLine -Path 'C:\Fixture\child.log' `
        -Offset 10 -TailLine 7 -StartedAt $fixtureTime `
        -ExpectedProcessId 42 -ExpectedScriptName 'Install.ps1' `
        -ExpectedSessionId $fixtureSessionId
    $diagnosticFixtureConfig = [pscustomobject]@{
        Paths = [pscustomobject]@{
            Root = '..\Installed'
            Logs = 'Logs'
        }
    }
    $diagnosticFixtureRoots = @(Get-LauncherDiagnosticRoots `
        -Configuration $diagnosticFixtureConfig `
        -PackageRoot 'C:\Fixture\Package')
    $diagnosticFixtureFiles = @{}
    foreach ($root in $diagnosticFixtureRoots) {
        $diagnosticFixtureFiles[$root] = [pscustomobject]@{
            FullName = Join-Path $root 'shared.log'
            Length = 100L
            LastWriteTimeUtc = $fixtureTime.UtcDateTime
        }
    }
    $diagnosticFileProvider = {
        param([string]$Directory)
        return @($diagnosticFixtureFiles[$Directory])
    }.GetNewClosure()
    $diagnosticSnapshot = Get-LauncherLogSnapshot `
        -Directories $diagnosticFixtureRoots `
        -FileProvider $diagnosticFileProvider
    $expectedDiagnosticRoots = @(
        [IO.Path]::GetFullPath((Join-Path `
            ([IO.Path]::GetTempPath()) 'Winlama-Logs')),
        [IO.Path]::GetFullPath('C:\Fixture\Installed\Logs')
    )
    $diagnosticFailures = @(Get-LauncherChildLogFailures `
        -StartedAt $fixtureTime -Snapshot @{} `
        -ExpectedProcessId 42 -ExpectedScriptName 'Install.ps1' `
        -Directories $diagnosticFixtureRoots `
        -FileProvider $diagnosticFileProvider `
        -TailReader {
            param([string]$Path, [long]$Offset)
            return @($matchingLine)
        }.GetNewClosure())
    $matchingSummary = if ($null -eq $matchingFailure) {
        ''
    }
    else {
        Format-LauncherChildLogFailure -Failure $matchingFailure
    }
    $emptyFailures = [Collections.Generic.List[object]]::new()
    $mixedFailures = [Collections.Generic.List[object]]::new()
    $mixedFailures.Add([pscustomobject]@{ Message = 'Path yok.' })
    $mixedFailures.Add([pscustomobject]@{ Path = 'C:\Fixture\b.log' })
    $mixedFailures.Add([pscustomobject]@{ Path = 'C:\Fixture\a.log' })
    $mixedFailures.Add([pscustomobject]@{ Path = 'C:\Fixture\b.log' })
    $emptyFailurePaths = @(Get-LauncherChildFailurePaths `
        -Failures $emptyFailures)
    $mixedFailurePaths = @(Get-LauncherChildFailurePaths `
        -Failures $mixedFailures)
    $launcherScriptSource = (Get-Command Invoke-LauncherScript `
        -ErrorAction Stop).Definition
    if ($null -ne $foreignFailure -or $null -eq $matchingFailure -or
        $null -eq $fatalFailure -or
        $fatalFailure.Level -cne 'FATAL' -or
        $null -eq $descendantFailure -or
        $descendantFailure.ProcessId -ne 99 -or
        $descendantFailure.SessionId -cne $fixtureSessionId -or
        $null -ne $foreignSessionFailure -or
        $diagnosticFixtureRoots.Count -ne 2 -or
        @($expectedDiagnosticRoots | Where-Object {
            $_ -notin $diagnosticFixtureRoots
        }).Count -ne 0 -or
        $diagnosticSnapshot.Count -ne 2 -or
        $diagnosticFailures.Count -ne 2 -or
        @($diagnosticFailures.Path | Sort-Object -Unique).Count -ne 2 -or
        @($diagnosticFailures | Where-Object {
            $_.ProcessId -ne 42 -or $_.Level -cne 'ERROR'
        }).Count -ne 0 -or
        $matchingFailure.ProcessId -ne 42 -or
        $matchingFailure.Message.Length -gt 320 -or
        $matchingFailure.ErrorHash -notmatch '^[A-F0-9]{16}$' -or
        $matchingSummary.Length -gt 1024 -or
        $matchingSummary -match '\{\s*"(?:level|message)"' -or
        $emptyFailurePaths.Count -ne 0 -or
        $mixedFailurePaths.Count -ne 2 -or
        $mixedFailurePaths[0] -cne 'C:\Fixture\a.log' -or
        $mixedFailurePaths[1] -cne 'C:\Fixture\b.log' -or
        $launcherScriptSource -notmatch `
            'Get-LauncherChildFailurePaths') {
        throw 'Launcher alt gunluk iliskilendirme/ozet sozlesmesi gecersiz.'
    }
    $launcherFileSource = [IO.File]::ReadAllText($PSCommandPath)
    $childInvokeIndex = $launcherScriptSource.IndexOf(
        '$childProcess = Invoke-LauncherProcess',
        [StringComparison]::Ordinal
    )
    $completionIndex = $launcherScriptSource.IndexOf(
        '$completionCommand = Get-LauncherHostedCompletionCommand',
        [StringComparison]::Ordinal
    )
    if ($childInvokeIndex -lt 0 -or $completionIndex -lt 0 -or
        $completionIndex -ge $childInvokeIndex -or
        $launcherScriptSource -notmatch '-SuppressPause\)' -or
        $launcherScriptSource -match '-SuppressPause:\$NoPause' -or
        $launcherScriptSource -notmatch
            '-ShowSummary:\(-not \[bool\]\$NoPause\)' -or
        $launcherScriptSource -match '-ShowSummary:\$false' -or
        $launcherScriptSource -notmatch 'Complete-WinlamaUIOperation' -or
        $launcherScriptSource -notmatch
            'New-LauncherActionResult' -or
        $launcherFileSource -notmatch `
            '(?ms)\$initialResult = Invoke-LauncherAction -Action ' +
                '\$InitialAction\s*if \(\$initialResult\.Terminal\) ' +
                '\{\s*exit \$initialResult\.ExitCode') {
        throw 'Launcher alt surec terminal sahiplik sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_FLOW_OK:Launcher.ChildTerminalOwnership'
    Write-Verbose 'WINLAMA_UI_OK:Launcher.RuntimeContracts'
}
function Assert-LauncherRunMeContracts {
    $path = Join-Path $PSScriptRoot 'RunMe.bat'
    $content = [IO.File]::ReadAllText($path)
    $noPauseIndex = $content.IndexOf('set "WINLAMA_NO_PAUSE="')
    $missingIndex = $content.IndexOf(
        'if not exist "%WINLAMA_POWERSHELL%"'
    )
    $echoLines = @($content -split '\r\n|\n|\r' |
        Where-Object { $_ -match '^\s*echo (?:\^\||[-=])' })
    $selectionPattern = [regex]::Escape(
        ('Se{0}iminiz' -f [char]0x00E7)
    )
    foreach ($sourceLine in $echoLines) {
        if ($sourceLine.Trim() -ceq
            'echo ^| !WINLAMA_LINE:~0,96! ^|') {
            continue
        }
        $runtimeLine = $sourceLine.Trim().Substring(5)
        $runtimeLine = $runtimeLine.Replace('^|', '|')
        if ($runtimeLine.Length -ne 100) {
            throw "RunMe.bat UI geometrisi gecersiz: $runtimeLine"
        }
    }
    if ($noPauseIndex -lt 0 -or $missingIndex -lt 0 -or
        $noPauseIndex -gt $missingIndex -or
        $content -notmatch `
            'if not defined WINLAMA_NO_PAUSE call :WAIT_EXIT' -or
        $content -notmatch (
            '(?im)^\s*call\s+:LOAD_LOCALIZED_TEXT\s+' +
            '"Common\.Prompt\.Selection"\s+' +
            '"WINLAMA_PROMPT_SELECTION"\s*$'
        ) -or
        $content -notmatch `
            ('(?im)^\s*set\s+"WINLAMA_LINE=' +
                '!WINLAMA_PROMPT_DISPLAY!:!WINLAMA_PADDING!"\s*$') -or
        $content -notmatch `
            ('<nul set /p "=!WINLAMA_ESC!\[1A!WINLAMA_ESC!' +
                '\[!WINLAMA_PROMPT_COLUMN!C"') -or
        $content -notmatch `
            'set /A WINLAMA_PROMPT_COLUMN=WINLAMA_PROMPT_LENGTH\+4' -or
        $content -notmatch `
            'if "!WINLAMA_CLOSE!"=="CIKIS" exit /b 0' -or
        $content -match `
            'if /I "!WINLAMA_CLOSE!"=="CIKIS" exit /b 0' -or
        $content -match (
            'set /p\s+"[^\r\n"]*=\| ' + $selectionPattern + ':'
        )) {
        throw 'RunMe.bat kapali girdi/NoPause sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Launcher.RunMeContracts'
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
function Test-LauncherAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}
function Test-LauncherUserContextMatch {
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
function Assert-LauncherElevatedUserContext {
    [CmdletBinding()]
    param()
    if ($InitialAction -eq 'None' -or
        ([string]::IsNullOrWhiteSpace($InitiatingUserSid) -and
            [string]::IsNullOrWhiteSpace($InitiatingUserProfile))) {
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
    if (-not (Test-LauncherUserContextMatch `
        -ExpectedSid $InitiatingUserSid `
        -ExpectedProfile $InitiatingUserProfile `
        -ActualSid $actualSid -ActualProfile $actualProfile)) {
        throw [UnauthorizedAccessException]::new(
            (Get-LocalizedText `
                -Key 'Launcher.Error.ElevatedUserMismatch')
        )
    }
}
function Start-ElevatedLauncherAction {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Uninstall', 'Repair')]
        [string]$Action,
        [scriptblock]$ProcessStarter,
        [switch]$SuppressUserError,
        [bool]$SuppressPause = [bool]$NoPause
    )
    try {
        Write-LauncherLog -Event 'ELEVATION_STARTED' `
            -Script 'Launcher.ps1' `
            -Message (Get-LocalizedText `
                -Key 'Launcher.Log.ElevationStarting' `
                -Arguments @($Action))
        $powershell = (Get-Process -Id $PID).Path
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -eq $identity.User) {
            throw (Get-LocalizedText `
                -Key 'Launcher.Error.ElevationFailed')
        }
        $initiatingSid = [string]$identity.User.Value
        $initiatingProfile = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::UserProfile
        )
        $arguments = @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath),
            '-InitialAction', $Action,
            '-SessionId', $SessionId,
            '-InitiatingUserSid', $initiatingSid,
            '-InitiatingUserProfile',
            (ConvertTo-WindowsCommandLineArgument `
                -Argument $initiatingProfile)
        )
        if ($VerbosePreference -ne 'SilentlyContinue') {
            $arguments += '-Verbose'
        }
        if ($SuppressPause) {
            $arguments += '-NoPause'
        }
        $startParameters = @{
            FilePath = $powershell
            ArgumentList = $arguments
            WorkingDirectory = $PSScriptRoot
            WindowStyle = 'Normal'
            Verb = 'RunAs'
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
            throw (Get-LocalizedText `
                -Key 'Launcher.Error.ElevationFailed')
        }
        Write-LauncherLog -Event 'ELEVATION_LAUNCHED' `
            -Script 'Launcher.ps1' `
            -Message (Get-LocalizedText `
                -Key 'Launcher.Log.ElevationStarted' `
                -Arguments @($Action))
        $exitCode = 0
        if ($SuppressPause) {
            if ($null -eq $process.PSObject.Methods['WaitForExit'] -or
                $null -eq $process.PSObject.Properties['ExitCode']) {
                throw 'Yonetici sureci bekleme sozlesmesini desteklemiyor.'
            }
            $process.WaitForExit()
            $exitCode = [int]$process.ExitCode
        }
        $process.Dispose()
        return New-LauncherActionResult `
            -Terminal $true -ExitCode $exitCode
    }
    catch {
        $completionCommand = Get-LauncherHostedCompletionCommand `
            -Action $InitialAction -PauseSuppressed $SuppressPause
        if (-not $SuppressUserError) {
            Write-LauncherLog -Event 'ELEVATION_FAILED' `
                -Script 'Launcher.ps1' `
                -Message (Get-LocalizedText `
                    -Key 'Launcher.Log.ElevationFailed' `
                    -Arguments @($Action)) `
                -Level ERROR -ErrorText $_.Exception.ToString()
        }
        if (-not $SuppressUserError) {
            Write-LauncherBootstrapError -Context (Get-LocalizedText `
                -Key 'Launcher.Error.AdminDenied' `
                -Arguments @($_.Exception.Message)) -ErrorRecord $_
            if (-not $ValidateOnly -and -not $SuppressPause) {
                Complete-WinlamaUIOperation `
                    -Summary (Get-LocalizedText `
                        -Key 'Launcher.Operation.AdminDenied') `
                    -Level WARN -Command $completionCommand
            }
        }
        return New-LauncherActionResult `
            -Terminal ($completionCommand -ceq 'CIKIS') -ExitCode 1
    }
}
function Assert-LauncherElevationContracts {
    $process = [pscustomobject]@{
        ExitCode = 7
        Waited = $false
    }
    $process | Add-Member -MemberType ScriptMethod `
        -Name WaitForExit -Value { $this.Waited = $true }
    $process | Add-Member -MemberType ScriptMethod `
        -Name Dispose -Value { }
    foreach ($action in @('Install', 'Uninstall')) {
        $process.Waited = $false
        $script:LauncherElevationFixture = $null
        $accepted = Start-ElevatedLauncherAction -Action $action `
            -SuppressPause:$false `
            -ProcessStarter {
                param([hashtable]$Parameters)
                $script:LauncherElevationFixture = $Parameters
                return $process
            }
        $arguments = @(
            $script:LauncherElevationFixture.ArgumentList
        )
        $actionIndex = [array]::IndexOf(
            $arguments,
            '-InitialAction'
        )
        $sidIndex = [array]::IndexOf(
            $arguments,
            '-InitiatingUserSid'
        )
        $profileIndex = [array]::IndexOf(
            $arguments,
            '-InitiatingUserProfile'
        )
        $sessionIndex = [array]::IndexOf(
            $arguments,
            '-SessionId'
        )
        $interactiveWaited = [bool]$process.Waited
        $process.Waited = $false
        $script:LauncherElevationAutomatedFixture = $null
        $automated = Start-ElevatedLauncherAction -Action $action `
            -SuppressPause:$true `
            -ProcessStarter {
                param([hashtable]$Parameters)
                $script:LauncherElevationAutomatedFixture = $Parameters
                return $process
            }
        $automatedArguments = @(
            $script:LauncherElevationAutomatedFixture.ArgumentList
        )
        if (-not $accepted.Terminal -or $accepted.ExitCode -ne 0 -or
            $interactiveWaited -or -not $automated.Terminal -or
            $automated.ExitCode -ne 7 -or -not $process.Waited -or
            $script:LauncherElevationFixture.Verb -ne 'RunAs' -or
            $script:LauncherElevationFixture.WindowStyle -ne 'Normal' -or
            $actionIndex -lt 0 -or
            $actionIndex + 1 -ge $arguments.Count -or
            $arguments[$actionIndex + 1] -cne $action -or
            $sessionIndex -lt 0 -or
            $sessionIndex + 1 -ge $arguments.Count -or
            $arguments[$sessionIndex + 1] -cne $SessionId -or
            $sidIndex -lt 0 -or $sidIndex + 1 -ge $arguments.Count -or
            [string]::IsNullOrWhiteSpace(
                [string]$arguments[$sidIndex + 1]
            ) -or $profileIndex -lt 0 -or
            $profileIndex + 1 -ge $arguments.Count -or
            [string]::IsNullOrWhiteSpace(
                [string]$arguments[$profileIndex + 1]
            ) -or '-NoPause' -in $arguments -or
            @($automatedArguments | Where-Object {
                $_ -ceq '-NoPause'
            }).Count -ne 1) {
            throw "Launcher $action yonetici aktarim sozlesmesi gecersiz."
        }
        $declineStarter = {
            param([hashtable]$Parameters)
            throw [ComponentModel.Win32Exception]::new(
                'Dogrulama UAC reddi.'
            )
        }
        $originalInitialAction = $InitialAction
        try {
            $InitialAction = 'None'
            $menuDeclined = Start-ElevatedLauncherAction `
                -Action $action -SuppressUserError `
                -SuppressPause:$false -ProcessStarter $declineStarter
            $automatedDeclined = Start-ElevatedLauncherAction `
                -Action $action -SuppressUserError `
                -SuppressPause:$true -ProcessStarter $declineStarter
            $InitialAction = $action
            $initialDeclined = Start-ElevatedLauncherAction `
                -Action $action -SuppressUserError `
                -SuppressPause:$false -ProcessStarter $declineStarter
        }
        finally {
            $InitialAction = $originalInitialAction
        }
        if ($menuDeclined.Terminal -or
            $menuDeclined.ExitCode -ne 1 -or
            -not $automatedDeclined.Terminal -or
            $automatedDeclined.ExitCode -ne 1 -or
            -not $initialDeclined.Terminal -or
            $initialDeclined.ExitCode -ne 1) {
            throw "Launcher $action UAC reddini basarili saydi."
        }
    }
    $fixtureProfile = 'C:\Users\Validation User'
    if (-not (Test-LauncherUserContextMatch `
        -ExpectedSid 'S-1-5-21-100' -ExpectedProfile $fixtureProfile `
        -ActualSid 'S-1-5-21-100' -ActualProfile $fixtureProfile) -or
        (Test-LauncherUserContextMatch `
            -ExpectedSid 'S-1-5-21-100' -ExpectedProfile $fixtureProfile `
            -ActualSid 'S-1-5-21-200' -ActualProfile $fixtureProfile) -or
        (Test-LauncherUserContextMatch `
            -ExpectedSid 'S-1-5-21-100' -ExpectedProfile $fixtureProfile `
            -ActualSid 'S-1-5-21-100' `
            -ActualProfile 'C:\Users\Other') -or
        (Test-LauncherUserContextMatch `
            -ExpectedSid 'S-1-5-21-100' -ExpectedProfile '' `
            -ActualSid 'S-1-5-21-100' -ActualProfile $fixtureProfile) -or
        -not (Test-LauncherUserContextMatch)) {
        throw 'Launcher farkli yonetici hesabi korumasi gecersiz.'
    }
    $bufferFixture = [pscustomobject]@{ Calls = 0 }
    $initializer = {
        $bufferFixture.Calls++
    }.GetNewClosure()
    $elevatedCleared = Initialize-LauncherConsoleBuffer `
        -Action Install -UserSid 'S-1-5-21-100' `
        -UserProfile $fixtureProfile -ValidationMode $false `
        -Initializer $initializer
    $sameConsoleCleared = Initialize-LauncherConsoleBuffer `
        -Action None -UserSid '' -UserProfile '' `
        -ValidationMode $false -Initializer $initializer
    $validationCleared = Initialize-LauncherConsoleBuffer `
        -Action Install -UserSid 'S-1-5-21-100' `
        -UserProfile $fixtureProfile -ValidationMode $true `
        -Initializer $initializer
    if (-not $elevatedCleared -or $sameConsoleCleared -or
        $validationCleared -or $bufferFixture.Calls -ne 1) {
        throw 'Launcher yonetici konsol arka plan sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Launcher.ElevatedUserContext'
    Write-Verbose 'WINLAMA_UI_OK:Launcher.ElevationContracts'
    Write-Verbose 'WINLAMA_UI_OK:Launcher.ElevatedBufferClear'
    Write-Verbose 'WINLAMA_UI_OK:Launcher.SameConsoleBufferPreserved'
}
function Write-LauncherRule {
    param([ValidateSet('-', '=')][string]$Character = '-')
    Write-WinlamaUIRule -Character $Character
}
function Write-LauncherLine {
    param(
        [Parameter(Mandatory)][string]$Text,
        [ConsoleColor]$Color = 'White'
    )
    Write-WinlamaUILine -Text $Text -Color $Color
}
function Get-LauncherMenuItems {
    return @(
        [pscustomobject]@{ Choice = '1'; Key = 'Launcher.Menu.Install';
            Color = 'Green' }
        [pscustomobject]@{ Choice = '2'; Key = 'Launcher.Menu.StartAll';
            Color = 'Cyan' }
        [pscustomobject]@{ Choice = '3'; Key = 'Launcher.Menu.Manager';
            Color = 'White' }
        [pscustomobject]@{ Choice = '4'; Key = 'Launcher.Menu.OpenWebUI';
            Color = 'Cyan' }
        [pscustomobject]@{ Choice = '5'; Key = 'Launcher.Menu.ComfyUI';
            Color = 'Magenta' }
        [pscustomobject]@{ Choice = '6'; Key = 'Launcher.Menu.Repair';
            Color = 'Yellow' }
        [pscustomobject]@{ Choice = '7'; Key = 'Launcher.Menu.Uninstall';
            Color = 'Red' }
        [pscustomobject]@{ Choice = '0'; Key = 'Launcher.Menu.Exit';
            Color = 'Gray' }
    )
}
function Assert-LauncherMenuContract {
    $items = @(Get-LauncherMenuItems)
    $expected = @('1', '2', '3', '4', '5', '6', '7', '0')
    if (($items.Choice -join ',') -ne ($expected -join ',')) {
        throw 'Launcher menu numaralari veya sirasi gecersiz.'
    }
    $expectedColors = @(
        'Green', 'Cyan', 'White', 'Cyan',
        'Magenta', 'Yellow', 'Red', 'Gray'
    )
    if (($items.Color -join ',') -ne ($expectedColors -join ',')) {
        throw 'Launcher menu renk sirasi gecersiz.'
    }
    $texts = @()
    foreach ($item in $items) {
        $text = Get-LocalizedText -Key $item.Key
        if ($text -notmatch ('^\s*\[{0}\]\s+\S' -f $item.Choice)) {
            throw "Launcher menu etiketi gecersiz: $($item.Key)"
        }
        $texts += $text.Trim()
    }
    if (@($texts | Sort-Object -Unique).Count -ne $items.Count) {
        throw 'Launcher menusunde yinelenen etiket var.'
    }
    if ([string]::IsNullOrWhiteSpace((Get-LocalizedText `
        -Key 'Common.Prompt.Selection'))) {
        throw 'Launcher secim istemi bos.'
    }
}
function Show-LauncherMenu {
    Write-LauncherRule -Character '='
    Write-LauncherLine -Text (Get-LocalizedText `
        -Key 'Launcher.Banner.Title') -Color Cyan
    Write-LauncherLine -Text (Get-LocalizedText `
        -Key 'Launcher.Banner.Summary') -Color Cyan
    Write-LauncherRule -Character '='
    foreach ($item in @(Get-LauncherMenuItems)) {
        Write-LauncherLine -Text (Get-LocalizedText -Key $item.Key) `
            -Color $item.Color
    }
    Write-LauncherRule
}
function ConvertTo-LauncherCommandLineArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
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
function Invoke-LauncherProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$ScriptName = '',
        [ValidateRange(100, 5000)]
        [int]$PollIntervalMilliseconds = 500,
        [scriptblock]$ProcessStarter
    )
    if ([string]::IsNullOrWhiteSpace($ScriptName)) {
        $ScriptName = [IO.Path]::GetFileName($FilePath)
    }
    $commandLine = @($ArgumentList | ForEach-Object {
        ConvertTo-LauncherCommandLineArgument -Value $_
    }) -join ' '
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $commandLine
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $startInfo.RedirectStandardInput = $false
    $process = if ($null -eq $ProcessStarter) {
        $createdProcess = [Diagnostics.Process]::new()
        $createdProcess.StartInfo = $startInfo
        try {
            if (-not $createdProcess.Start()) {
                throw 'Alt betik sureci baslatilamadi.'
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
        throw 'Alt betik sureci olusturulamadi.'
    }
    try {
        try {
            $processId = [int]$process.Id
        }
        catch {
            throw [InvalidOperationException]::new(
                'Alt betik surec kimligi okunamadi.',
                $_.Exception
            )
        }
        if ($processId -le 0 -or
            $null -eq $process.PSObject.Methods['WaitForExit'] -or
            $null -eq $process.PSObject.Properties['HasExited'] -or
            $null -eq $process.PSObject.Properties['ExitCode']) {
            throw [InvalidOperationException]::new(
                'Alt betik surec taniticisi gecersiz.'
            )
        }
        Write-LauncherLog -Event 'SCRIPT_PROCESS_STARTED' `
            -Script $ScriptName `
            -Message (Get-LocalizedText `
                -Key 'Launcher.Log.ChildProcessStarted' `
                -Arguments @($processId)) `
            -ChildProcessId $processId
        while ($true) {
            try {
                $waitResult = $process.WaitForExit(
                    $PollIntervalMilliseconds
                )
            }
            catch {
                throw [InvalidOperationException]::new(
                    'Alt betik surec taniticisi beklenemedi.',
                    $_.Exception
                )
            }
            if ($waitResult -isnot [bool]) {
                throw [InvalidOperationException]::new(
                    'Alt betik bekleme sonucu gecersiz.'
                )
            }
            if ([bool]$waitResult) {
                break
            }
        }
        try {
            if (-not [bool]$process.HasExited) {
                throw [InvalidOperationException]::new(
                    'Alt betik cikisi dogrulanamadi.'
                )
            }
            if ($null -ne $process.PSObject.Methods['Refresh']) {
                $process.Refresh()
            }
            $exitCodeValue = $process.ExitCode
            if ($null -eq $exitCodeValue) {
                throw [InvalidOperationException]::new(
                    'Alt betik cikis kodu bos dondu.'
                )
            }
            $exitCode = [int]$exitCodeValue
        }
        catch {
            throw [InvalidOperationException]::new(
                'Alt betik cikis kodu okunamadi.',
                $_.Exception
            )
        }
        return [pscustomobject]@{
            ProcessId = $processId
            ExitCode = $exitCode
        }
    }
    finally {
        if ($null -ne $process.PSObject.Methods['Dispose']) {
            $process.Dispose()
        }
    }
}
function Assert-LauncherChildProcessContracts {
    $script:LauncherChildProcessFixture = $null
    $fixtureProcess = [pscustomobject]@{
        Id = 4242
        ExitCode = 7
        HasExited = $false
        WaitCalls = 0
        WaitTimeouts = [Collections.Generic.List[int]]::new()
        DescendantRunning = $true
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
        -Name Dispose -Value { $this.Disposed = $true }
    $result = Invoke-LauncherProcess `
        -FilePath 'C:\Program Files\PowerShell\7\pwsh.exe' `
        -ScriptName 'Child.ps1' `
        -ArgumentList @(
            '-NoProfile', '-File', 'C:\Fixture Path\Child.ps1', '-NoPause'
        ) -ProcessStarter {
            param([Diagnostics.ProcessStartInfo]$StartInfo)
            $script:LauncherChildProcessFixture = $StartInfo
            return $fixtureProcess
        }
    $fixture = $script:LauncherChildProcessFixture
    if ($result.ExitCode -ne 7 -or $result.ProcessId -ne 4242 -or
        $null -eq $fixture -or
        [bool]$fixture.UseShellExecute -or
        [bool]$fixture.CreateNoWindow -or
        [bool]$fixture.RedirectStandardOutput -or
        [bool]$fixture.RedirectStandardError -or
        [bool]$fixture.RedirectStandardInput -or
        $fixture.WorkingDirectory -cne $PSScriptRoot -or
        $fixture.FileName -cne `
            'C:\Program Files\PowerShell\7\pwsh.exe' -or
        [string]$fixture.Arguments -notmatch `
            '"C:\\Fixture Path\\Child\.ps1"' -or
        [string]$fixture.Arguments -match 'Out-Host' -or
        $fixtureProcess.WaitCalls -ne 3 -or
        @($fixtureProcess.WaitTimeouts | Where-Object {
            $_ -ne 500
        }).Count -ne 0 -or
        -not $fixtureProcess.HasExited -or
        -not $fixtureProcess.DescendantRunning -or
        -not $fixtureProcess.Disposed) {
        throw 'Launcher alt betik konsol/renk sozlesmesi gecersiz.'
    }
    $invalidHandleRejected = $false
    $invalidProcess = [pscustomobject]@{
        Id = 4343
        HasExited = $false
        ExitCode = 0
        Disposed = $false
    }
    $invalidProcess | Add-Member -MemberType ScriptMethod `
        -Name Dispose -Value { $this.Disposed = $true }
    try {
        $null = Invoke-LauncherProcess -FilePath 'pwsh.exe' `
            -ArgumentList @('-NoProfile') `
            -ProcessStarter { $invalidProcess }
    }
    catch [InvalidOperationException] {
        $invalidHandleRejected = $true
    }
    if (-not $invalidHandleRejected -or
        -not $invalidProcess.Disposed) {
        throw 'Launcher gecersiz surec taniticisi sozlesmesi gecersiz.'
    }
    $nullExitRejected = $false
    $nullExitProcess = [pscustomobject]@{
        Id = 4444
        HasExited = $true
        ExitCode = $null
        Disposed = $false
    }
    $nullExitProcess | Add-Member -MemberType ScriptMethod `
        -Name WaitForExit -Value { param([int]$Milliseconds) $true }
    $nullExitProcess | Add-Member -MemberType ScriptMethod `
        -Name Dispose -Value { $this.Disposed = $true }
    try {
        $null = Invoke-LauncherProcess -FilePath 'pwsh.exe' `
            -ArgumentList @('-NoProfile') `
            -ProcessStarter { $nullExitProcess }
    }
    catch [InvalidOperationException] {
        $nullExitRejected = $true
    }
    if (-not $nullExitRejected -or -not $nullExitProcess.Disposed) {
        throw 'Launcher bos cikis kodu sozlesmesi gecersiz.'
    }
    $liveCommand =
        "[Console]::WriteLine('WINLAMA_LIVE_CHILD_STAGE_FIXTURE'); exit 9"
    $liveCommandBytes = [Text.Encoding]::Unicode.GetBytes($liveCommand)
    $liveArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-EncodedCommand',
        [Convert]::ToBase64String($liveCommandBytes)
    )
    $liveResult = Invoke-LauncherProcess `
        -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList $liveArguments -ScriptName 'LiveChildFixture.ps1'
    if ($liveResult.ExitCode -ne 9 -or $liveResult.ProcessId -le 0) {
        throw 'Launcher canli alt betik cikis sozlesmesi gecersiz.'
    }
    $interactiveArguments = @(Get-LauncherScriptArguments `
        -Path 'C:\Fixture Path\Child.ps1' `
        -Name 'Uninstall.ps1')
    $automatedArguments = @(Get-LauncherScriptArguments `
        -Path 'C:\Fixture Path\Child.ps1' `
        -Name 'Uninstall.ps1' -SuppressPause)
    $repairArguments = @(Get-LauncherScriptArguments `
        -Path 'C:\Fixture Path\Repair.ps1' `
        -Name 'Repair.ps1')
    $sessionIndex = [array]::IndexOf($repairArguments, '-SessionId')
    if ('-NoPause' -in $interactiveArguments -or
        @($automatedArguments | Where-Object {
            $_ -ceq '-NoPause'
        }).Count -ne 1 -or
        $sessionIndex -lt 0 -or
        $sessionIndex + 1 -ge $repairArguments.Count -or
        $repairArguments[$sessionIndex + 1] -cne $SessionId) {
        throw 'Launcher alt betik bekleme/oturum sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_PROCESS_OK:Launcher.DirectChildExit'
    Write-Verbose 'WINLAMA_PROCESS_OK:Launcher.RawProcessHandle'
    Write-Verbose 'WINLAMA_PROCESS_OK:Launcher.ExitCodeRequired'
    Write-Verbose 'WINLAMA_UI_OK:Launcher.LiveChildOutput'
    Write-Verbose 'WINLAMA_UI_FLOW_OK:Launcher.LiveChildStage'
    Write-Verbose 'WINLAMA_UI_OK:Launcher.ChildProcessContracts'
}
function Get-LauncherScriptArguments {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [switch]$SuppressPause
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $Path
    )
    if ($SuppressPause) {
        $arguments += '-NoPause'
    }
    if ($Name -in @('Install.ps1', 'Repair.ps1')) {
        $arguments += @('-SessionId', $SessionId)
    }
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $arguments += '-Verbose'
    }
    return $arguments
}
function Invoke-LauncherScript {
    param([Parameter(Mandatory)][string]$Name)
    $completionCommand = Get-LauncherHostedCompletionCommand
    $terminalAfterAction = $completionCommand -ceq 'CIKIS'
    $path = Join-Path $PSScriptRoot $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-LauncherLog -Event 'SCRIPT_FAILED' -Script $Name `
            -Message (Get-LocalizedText `
                -Key 'Launcher.Log.ScriptMissing') -Level ERROR `
            -ErrorText $path
        Write-LauncherBootstrapStatus -Level ERROR `
            -Message (Get-LocalizedText `
                -Key 'Launcher.Error.ScriptMissing' `
                -Arguments @($Name))
        if (-not $NoPause) {
            Complete-WinlamaUIOperation `
                -Summary (Get-LocalizedText `
                    -Key 'Launcher.Operation.ScriptMissing' `
                    -Arguments @($Name)) `
                -Level ERROR -Command $completionCommand
        }
        return New-LauncherActionResult `
            -Terminal $terminalAfterAction -ExitCode 1
    }
    $childErrors = [Collections.Generic.List[object]]::new()
    $scriptExitCode = 1
    try {
        $startedAt = [DateTimeOffset]::UtcNow
        $diagnosticRoots = @(Get-LauncherDiagnosticRoots)
        $logSnapshot = Get-LauncherLogSnapshot `
            -Directories $diagnosticRoots
        Write-LauncherLog -Event 'SCRIPT_STARTED' -Script $Name `
            -Message (Get-LocalizedText `
                -Key 'Launcher.Log.ScriptStarted')
        $requiredVersion = Get-LauncherRequiredPowerShellVersion `
            -Path $path
        if ($PSVersionTable.PSVersion -ge $requiredVersion) {
            $powershell = (Get-Process -Id $PID).Path
        }
        else {
            $powershell = Get-LauncherPowerShellPath `
                -MinimumVersion $requiredVersion
        }
        if ([string]::IsNullOrWhiteSpace($powershell)) {
            throw (Get-LocalizedText `
                -Key 'Launcher.Error.PowerShellUnavailable' `
                -Arguments @($requiredVersion))
        }
        $arguments = @(Get-LauncherScriptArguments -Path $path `
            -Name $Name -SuppressPause)
        $expectedSessionId = if ($Name -in @(
            'Install.ps1', 'Repair.ps1'
        )) {
            $SessionId
        }
        else {
            ''
        }
        $childProcess = Invoke-LauncherProcess `
            -FilePath $powershell -ArgumentList $arguments `
            -ScriptName $Name
        $scriptExitCode = $childProcess.ExitCode
        foreach ($failure in @(Get-LauncherChildLogFailures `
            -StartedAt $startedAt -Snapshot $logSnapshot `
            -ExpectedProcessId $childProcess.ProcessId `
            -ExpectedScriptName $Name `
            -ExpectedSessionId $expectedSessionId `
            -Directories $diagnosticRoots)) {
            $childErrors.Add($failure)
        }
        $handledExit = Invoke-LauncherHandledExit `
            -ScriptName $Name -ExitCode $scriptExitCode `
            -ErrorCount $childErrors.Count `
            -ShowSummary:(-not [bool]$NoPause) `
            -CompletionCommand $completionCommand
        if ($null -ne $handledExit) {
            return New-LauncherActionResult `
                -Terminal ([bool]$handledExit -or $terminalAfterAction) `
                -ExitCode $scriptExitCode
        }
        if ($scriptExitCode -ne 0 -or $childErrors.Count -gt 0) {
            $message = Get-LocalizedText `
                -Key 'Launcher.Error.ScriptExitCode' `
                -Arguments @($Name, $scriptExitCode)
            throw [InvalidOperationException]::new(
                (ConvertTo-LauncherBoundedLogText `
                    -Value $message -MaximumLength 1536).Text
            )
        }
        Write-LauncherLog -Event 'SCRIPT_COMPLETED' -Script $Name `
            -Message (Get-LocalizedText `
                -Key 'Launcher.Log.ScriptCompleted')
        if (-not $NoPause) {
            Complete-WinlamaUIOperation `
                -Summary (Get-LocalizedText `
                    -Key 'Launcher.Operation.ScriptCompleted' `
                    -Arguments @($Name)) `
                -Level SUCCESS -Command $completionCommand
        }
    }
    catch {
        $childLogPaths = @(Get-LauncherChildFailurePaths `
            -Failures $childErrors)
        $details = [Collections.Generic.List[string]]::new()
        $details.Add((ConvertTo-LauncherBoundedLogText `
            -Value $_.Exception.Message -MaximumLength 768).Text)
        if ($childLogPaths.Count -gt 0) {
            $details.Add((Get-LocalizedText `
                -Key 'Launcher.Error.ChildLogs' `
                -Arguments @(($childLogPaths -join ' | '))))
        }
        foreach ($failure in @($childErrors | Select-Object -First 3)) {
            $details.Add((Format-LauncherChildLogFailure `
                -Failure $failure))
        }
        $errorDetail = (ConvertTo-LauncherBoundedLogText `
            -Value ($details -join [Environment]::NewLine) `
            -MaximumLength 2048).Text
        Write-LauncherLog -Event 'SCRIPT_FAILED' -Script $Name `
            -Message (ConvertTo-LauncherBoundedLogText `
                -Value $_.Exception.Message -MaximumLength 512).Text `
            -Level ERROR `
            -ErrorText $errorDetail
        Write-LauncherBootstrapError -Context (Get-LocalizedText `
            -Key 'Launcher.Error.ScriptFailed' `
            -Arguments @($_.Exception.Message)) -ErrorRecord $_
        if (-not $NoPause) {
            Complete-WinlamaUIOperation `
                -Summary (Get-LocalizedText `
                    -Key 'Launcher.Operation.ScriptFailed' `
                    -Arguments @($Name)) `
                -Level ERROR -Command $completionCommand
        }
        $failureExitCode = if ($scriptExitCode -ne 0) {
            $scriptExitCode
        }
        else {
            1
        }
        return New-LauncherActionResult `
            -Terminal $terminalAfterAction `
            -ExitCode $failureExitCode
    }
    return New-LauncherActionResult `
        -Terminal $terminalAfterAction -ExitCode 0
}
function Invoke-LauncherAction {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'Install', 'Start', 'Manager', 'OpenWebUI',
            'ComfyUI', 'Uninstall', 'Repair'
        )]
        [string]$Action
    )
    $scripts = @{
        Install = 'Install.ps1'
        Start = 'Start.ps1'
        Manager = 'ModelManager.ps1'
        OpenWebUI = 'Modules\UI\OpenWebUI.ps1'
        ComfyUI = 'Modules\UI\ComfyUI.ps1'
        Uninstall = 'Uninstall.ps1'
        Repair = 'Repair.ps1'
    }
    if ($Action -in @('Install', 'Uninstall', 'Repair') -and
        -not (Test-LauncherAdministrator)) {
        return Start-ElevatedLauncherAction -Action $Action
    }
    return Invoke-LauncherScript -Name $scripts[$Action]
}
Assert-LauncherElevatedUserContext
Write-Verbose (Get-LocalizedText -Key 'Verbose.Validation.Started' `
    -Arguments @('Launcher.ps1'))
if ($ValidateOnly) {
    $null = Assert-WinlamaUIStandard
    $null = Assert-LauncherBootstrapInputContracts
    foreach ($relativePath in @(
        'Install.ps1', 'Start.ps1', 'ModelManager.ps1',
        'Modules\UI\OpenWebUI.ps1',
        'Modules\UI\ComfyUI.ps1',
        'Modules\UI\ConsoleUI.psm1',
        'Uninstall.ps1', 'Repair.ps1'
    )) {
        if (-not (Test-Path -LiteralPath `
            (Join-Path $PSScriptRoot $relativePath) -PathType Leaf)) {
            throw (Get-LocalizedText -Key 'Launcher.Error.ScriptMissing' `
                -Arguments @($relativePath))
        }
    }
    Assert-LauncherMenuContract
    Assert-LauncherRuntimeContracts
    Assert-LauncherRunMeContracts
    Assert-LauncherElevationContracts
    Assert-LauncherChildProcessContracts
    Show-LauncherMenu
    $fixtureChoice = Read-WinlamaUIInput `
        -Prompt 'Dogrulama menu secimi.' -Label 'FarkliEtiket' `
        -InputReader { '0' } -NoLeadingRule
    if ($fixtureChoice -cne '0') {
        throw 'Launcher gercek secim istemi fiksturu basarisiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Launcher.Main'
    $flowArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'Uninstall.ps1'),
        '-ValidateOnly', '-NoPause', '-Verbose'
    )
    $flowResult = Invoke-LauncherProcess `
        -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList $flowArguments -ScriptName 'Uninstall.ps1'
    if ($flowResult.ExitCode -ne 0) {
        throw ('Launcher kaldirma UI zinciri basarisiz: {0}' -f `
            $flowResult.ExitCode)
    }
    Write-Verbose 'WINLAMA_UI_FLOW_OK:Launcher.UninstallChild'
    Write-Verbose (Get-LocalizedText `
        -Key 'Verbose.Validation.Completed' `
        -Arguments @('Launcher.ps1'))
    Write-Verbose 'WINLAMA_VALIDATION_OK:Launcher.ps1'
    exit 0
}
if (-not (Set-WinlamaProcessPriority `
    -Priority $config.Runtime.ProcessPriority)) {
    Write-LauncherBootstrapStatus -Level WARN `
        -Message (Get-LocalizedText -Key 'Common.Priority.Failed')
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
if ($InitialAction -ne 'None') {
    $initialResult = Invoke-LauncherAction -Action $InitialAction
    if ($initialResult.Terminal) {
        exit $initialResult.ExitCode
    }
    $InitialAction = 'None'
}
while ($true) {
    Clear-Host
    $host.UI.RawUI.WindowTitle = Get-LocalizedText `
        -Key 'Launcher.WindowTitle'
    Show-LauncherMenu
    $choice = Read-WinlamaUIInput `
        -Prompt (Get-LocalizedText `
            -Key 'Launcher.Prompt.Action') `
        -Label (Get-LocalizedText -Key 'Common.Prompt.Selection') `
        -NoLeadingRule
    $choice = ([string]$choice).Trim()
    switch ($choice) {
        '0' {
            if (-not $NoPause) {
                Complete-WinlamaUIOperation `
                    -Summary (Get-LocalizedText `
                        -Key 'Launcher.Operation.Completed') `
                    -Level SUCCESS -Command CIKIS
            }
            exit 0
        }
        '1' {
            $result = Invoke-LauncherAction -Action Install
            if ($result.Terminal) {
                exit $result.ExitCode
            }
        }
        '2' {
            $result = Invoke-LauncherAction -Action Start
            if ($result.Terminal) {
                exit $result.ExitCode
            }
        }
        '3' {
            $result = Invoke-LauncherAction -Action Manager
            if ($result.Terminal) {
                exit $result.ExitCode
            }
        }
        '4' {
            $result = Invoke-LauncherAction -Action OpenWebUI
            if ($result.Terminal) {
                exit $result.ExitCode
            }
        }
        '5' {
            $result = Invoke-LauncherAction -Action ComfyUI
            if ($result.Terminal) {
                exit $result.ExitCode
            }
        }
        '6' {
            $result = Invoke-LauncherAction -Action Repair
            if ($result.Terminal) {
                exit $result.ExitCode
            }
        }
        '7' {
            $result = Invoke-LauncherAction -Action Uninstall
            if ($result.Terminal) {
                exit $result.ExitCode
            }
        }
        default {
            Write-LauncherBootstrapStatus -Level WARN `
                -Message (Get-LocalizedText `
                    -Key 'Common.Selection.Invalid')
            Start-Sleep -Seconds 1
        }
    }
}