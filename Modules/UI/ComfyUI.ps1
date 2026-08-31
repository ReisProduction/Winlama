[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Background,
    [switch]$PrepareOnly,
    [switch]$ValidateOnly,
    [switch]$NoPause
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertFrom-ComfyUIJson {
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
function Write-ComfyUIBootstrapRule {
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
function Write-ComfyUIBootstrapLine {
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
function Get-ComfyUIBootstrapStatusStyle {
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
function Get-ComfyUIBootstrapStatusWidth {
    $width = 0
    foreach ($level in @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    )) {
        $style = Get-ComfyUIBootstrapStatusStyle -Level $level
        $width = [Math]::Max($width, $style.Label.Length)
    }
    return $width
}
function Write-ComfyUIBootstrapStatus {
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
    $style = Get-ComfyUIBootstrapStatusStyle -Level $Level
    $width = Get-ComfyUIBootstrapStatusWidth
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
function Format-ComfyUIBootstrapInputLine {
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
function ConvertFrom-ComfyUIBootstrapReadValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    if ($null -eq $Value) {
        throw [IO.EndOfStreamException]::new(
            'Standart girdi kapali; zorunlu komut okunamadi.'
        )
    }
    return [string]$Value
}
function Test-ComfyUIBootstrapExactExit {
    param([AllowNull()][string]$Value)
    return $null -ne $Value -and $Value -ceq 'CIKIS'
}
function Assert-ComfyUIBootstrapInputContracts {
    $eofRejected = $false
    try {
        $null = ConvertFrom-ComfyUIBootstrapReadValue -Value $null
    }
    catch [IO.EndOfStreamException] {
        $eofRejected = $true
    }
    if (-not $eofRejected -or
        (ConvertFrom-ComfyUIBootstrapReadValue -Value '') -cne '') {
        throw 'ComfyUI bootstrap EOF girdi sozlesmesi gecersiz.'
    }
    foreach ($invalid in @('', 'C', 'cikis', 'Cikis', ' CIKIS ')) {
        if (Test-ComfyUIBootstrapExactExit -Value $invalid) {
            throw 'ComfyUI bootstrap kesin CIKIS sozlesmesi gecersiz.'
        }
    }
    if (-not (Test-ComfyUIBootstrapExactExit -Value 'CIKIS')) {
        throw 'ComfyUI bootstrap kesin CIKIS sozlesmesi gecersiz.'
    }
    $inputSource = (Get-Command Read-ComfyUIBootstrapRawInput `
        -ErrorAction Stop).Definition
    if ($inputSource.IndexOf(
            '[Console]::IsOutputRedirected',
            [StringComparison]::Ordinal
        ) -ge 0) {
        throw 'ComfyUI cikti hatti girdiyi gizleyemez.'
    }
    Write-Verbose 'WINLAMA_UI_OK:ComfyUI.BootstrapEOF'
    Write-Verbose 'WINLAMA_UI_OK:ComfyUI.BootstrapExactExit'
    Write-Verbose 'WINLAMA_UI_OK:ComfyUI.OutputPipelineInput'
    return $true
}
function Read-ComfyUIBootstrapRawInput {
    if ([Console]::IsInputRedirected) {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-ComfyUIBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-ComfyUIBootstrapInputLine -Value $value))
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
                (Format-ComfyUIBootstrapInputLine -Value $value))
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
            (Format-ComfyUIBootstrapInputLine -Value $value))
        return $value
    }
    catch {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-ComfyUIBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-ComfyUIBootstrapInputLine -Value $value))
        return $value
    }
}
function Write-ComfyUIBootstrapError {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $command = Get-Command Write-WinlamaUIError `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $Context = Get-WinlamaUIString `
            -Key 'ComfyUI.Operation.FailedContext' -Fallback $Context
        & $command -Context $Context -ErrorRecord $ErrorRecord
        return
    }
    Write-ComfyUIBootstrapRule -Character '='
    Write-ComfyUIBootstrapLine -Text 'ISLEM OZETI' -Color Cyan
    Write-ComfyUIBootstrapStatus -Level ERROR -Message $Context
    Write-ComfyUIBootstrapStatus -Level ERROR `
        -Message $ErrorRecord.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace(
        $ErrorRecord.InvocationInfo.PositionMessage
    )) {
        Write-ComfyUIBootstrapStatus -Level DETAIL `
            -Message $ErrorRecord.InvocationInfo.PositionMessage.Trim()
    }
    Write-ComfyUIBootstrapRule -Character '='
}
function ConvertTo-ComfyUIErrorLogText {
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
function New-ComfyUIErrorLogRecord {
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
        moduleCode = 'COMFYUI'
        eventCode = 'COMFYUI_FAILED'
        script = 'ComfyUI.ps1'
        message = ConvertTo-ComfyUIErrorLogText -Value $Message
        error = ConvertTo-ComfyUIErrorLogText -Value $ErrorText `
            -MaximumLength 1536 -AllowEmpty
        errorType = $ErrorType
        processId = $ProcessId
    }
}
function Assert-ComfyUIErrorLogSchemaContracts {
    $record = New-ComfyUIErrorLogRecord -Message Fixture `
        -ErrorText '{"level":"ERROR"}' `
        -ErrorType FixtureException -ProcessId 42
    $parsed = $record | ConvertTo-Json -Compress -Depth 5 |
        ConvertFrom-ComfyUIJson
    $timestamp = [DateTimeOffset]::MinValue
    if ([string]$parsed.level -cne 'ERROR' -or
        [string]$parsed.displayLevel -cne 'HATA' -or
        [string]$parsed.moduleCode -cne 'COMFYUI' -or
        [string]$parsed.eventCode -cne 'COMFYUI_FAILED' -or
        [string]$parsed.script -cne 'ComfyUI.ps1' -or
        [int]$parsed.processId -ne 42 -or
        [string]$parsed.error -match '^\s*[\{\[]' -or
        -not [DateTimeOffset]::TryParse(
            [string]$parsed.timestamp,
            [ref]$timestamp
        )) {
        throw 'ComfyUI hata JSONL semasi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.ErrorLogSchema'
    return $true
}
function Read-ComfyUIBootstrapInput {
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
    Write-ComfyUIBootstrapRule
    Write-ComfyUIBootstrapStatus -Level INFO -Message $Prompt
    Write-ComfyUIBootstrapStatus -Level DETAIL `
        -Message 'Yalniz tam olarak CIKIS yazin.'
    Write-ComfyUIBootstrapRule
    $value = Read-ComfyUIBootstrapRawInput
    Write-ComfyUIBootstrapRule
    return $value
}
trap {
    Write-ComfyUIBootstrapError `
        -Context 'Beklenmeyen ComfyUI hatasi.' -ErrorRecord $_
    if (-not $ValidateOnly -and -not $NoPause) {
        do {
            $answer = Read-ComfyUIBootstrapInput `
                -Prompt 'Oturumu kapatmak icin CIKIS yazin.'
            if (-not (Test-ComfyUIBootstrapExactExit -Value $answer)) {
                Write-ComfyUIBootstrapStatus -Level WARN `
                    -Message 'Bos veya gecersiz komut kabul edilmedi.'
            }
        } while (-not (Test-ComfyUIBootstrapExactExit -Value $answer))
    }
    exit 1
}
Import-Module (Join-Path $projectRoot `
    'Modules\UI\ConsoleUI.psm1') -Force -ErrorAction Stop `
    -Verbose:$false
try {
    $host.UI.RawUI.WindowTitle = Get-WinlamaUIString `
        -Key 'ComfyUI.WindowTitle' `
        -Fallback 'Winlama - ComfyUI'
}
catch {
    Write-Verbose ('Pencere basligi ayarlanamadi: {0}' -f `
        $_.Exception.Message)
}
function Get-ComfyUIText {
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
function Complete-ComfyUIOperation {
    param(
        [Parameter(Mandatory)][string]$Summary,
        [ValidateSet('SUCCESS', 'WARN', 'ERROR', 'SKIP')]
        [string]$Level = 'SUCCESS'
    )
    if (-not $NoPause) {
        Complete-WinlamaUIOperation -Summary $Summary `
            -Level $Level -Command CIKIS
    }
}
function Resolve-ComfyUIConfigPath {
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
    throw [IO.FileNotFoundException]::new(
        'Canonical yapilandirma dosyasi bulunamadi.'
    )
}
function Expand-ComfyUIPath {
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $projectRoot $expanded
    }
    return [IO.Path]::GetFullPath($expanded)
}
function ConvertTo-ComfyUIProcessArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"{0}"' -f $escaped
}
function Test-ComfyUIPort {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    try {
        $parameters = @{
            Uri = "http://127.0.0.1:$Port/object_info"
            Method = 'Get'
            TimeoutSec = 5
        }
        if ($PSVersionTable.PSVersion.Major -le 5) {
            $parameters.UseBasicParsing = $true
        }
        $response = Invoke-RestMethod @parameters
        return Test-ComfyUIObjectInfoContract `
            -Config $Config -ObjectInfo $response
    }
    catch {
        return $false
    }
}
function Invoke-ComfyUIPortPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$IsPrepareOnly,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [scriptblock]$ReadyProbe = {
            param($CandidatePort, $CandidateConfig)
            Test-ComfyUIPort -Port $CandidatePort `
                -Config $CandidateConfig
        },
        [scriptblock]$OccupiedProbe = {
            param($CandidatePort)
            Test-TcpEndpoint -HostName '127.0.0.1' `
                -Port $CandidatePort -TimeoutMilliseconds 500
        }
    )
    if ($IsPrepareOnly) {
        return 'Prepare'
    }
    if ([bool](& $ReadyProbe $Port $Config)) {
        return 'AlreadyReady'
    }
    if ([bool](& $OccupiedProbe $Port)) {
        throw (
            'ComfyUI portunda uyumsuz veya eksik runtime var: ' +
            $Port
        )
    }
    return 'Continue'
}
function Assert-ComfyUIPrepareRuntimeAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$IsPrepareOnly,
        [Parameter(Mandatory)]
        [AllowNull()][AllowEmptyString()][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$InstallPath
    )
    if (-not $IsPrepareOnly -or
        -not [string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        return $true
    }
    $message = Get-ComfyUIText `
        -Key 'ComfyUI.Error.PrepareRuntimeUnavailable' `
        -Fallback ('ComfyUI hazirlik runtime kaynagi gecersiz ' +
            'veya eksik: {0}') `
        -Arguments @($InstallPath)
    throw (New-NonRetryableException -Message $message)
}
function Assert-ComfyUIPrepareOnlyContracts {
    [CmdletBinding()]
    param()
    $events = [Collections.Generic.List[string]]::new()
    $portState = Invoke-ComfyUIPortPreflight `
        -IsPrepareOnly $true -Port 8188 `
        -Config ([pscustomobject]@{}) `
        -ReadyProbe {
            param($CandidatePort, $CandidateConfig)
            $null = $events.Add('Ready')
            return $false
        }.GetNewClosure() `
        -OccupiedProbe {
            param($CandidatePort)
            $null = $events.Add('Occupied')
            return $true
        }.GetNewClosure()
    if ($portState -cne 'Prepare' -or $events.Count -ne 0) {
        throw 'ComfyUI PrepareOnly port atlama sozlesmesi gecersiz.'
    }
    $failure = $null
    try {
        $null = Assert-ComfyUIPrepareRuntimeAvailable `
            -IsPrepareOnly $true -RuntimeRoot $null `
            -InstallPath 'C:\Fixture\MissingRuntime'
    }
    catch {
        $failure = $_.Exception
    }
    if ($null -eq $failure -or
        $failure.Data['Winlama.Retryable'] -ne $false) {
        throw (
            'ComfyUI PrepareOnly eksik runtime hata ' +
            'sozlesmesi gecersiz.'
        )
    }
    $null = Assert-ComfyUIPrepareRuntimeAvailable `
        -IsPrepareOnly $true `
        -RuntimeRoot 'C:\Fixture\Runtime' `
        -InstallPath 'C:\Fixture\Runtime'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:ComfyUI.PrepareOnlyPreflight'
    return $true
}
function Get-ComfyUIRuntimeRoot {
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $runtimeRoot = [IO.Path]::GetFullPath($InstallPath)
    $python = Join-Path $runtimeRoot 'python_embeded\python.exe'
    $main = Join-Path $runtimeRoot 'ComfyUI\main.py'
    if ((Test-Path -LiteralPath $python -PathType Leaf) -and
        (Test-Path -LiteralPath $main -PathType Leaf) -and
        (Test-ComfyUIRuntimeIdentity -Path $runtimeRoot `
            -Config $Config)) {
        return $runtimeRoot
    }
    return $null
}
function Get-ComfyUIModelDirectoryIndex {
    param(
        [Parameter(Mandatory)][string]$ModelsRoot,
        [scriptblock]$DirectoryReader = {
            param($RootPath)
            Get-ChildItem -LiteralPath $RootPath -Directory `
                -Recurse -Force -ErrorAction Stop
        }
    )
    $rootItem = Get-Item -LiteralPath $ModelsRoot -Force `
        -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        $rootItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) {
        throw 'ComfyUI model koku guvenli bir dizin degil.'
    }
    $root = [IO.Path]::GetFullPath($rootItem.FullName).
        TrimEnd('\')
    $rootPrefix = $root + '\'
    $index = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($directory in @(& $DirectoryReader $root)) {
        if ($null -eq $directory -or
            -not [bool]$directory.PSIsContainer) {
            throw 'ComfyUI model dizin kaydi gecersiz.'
        }
        $fullPath = [IO.Path]::GetFullPath(
            [string]$directory.FullName
        )
        if (-not $fullPath.StartsWith(
                $rootPrefix,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            [IO.FileAttributes]$directory.Attributes -band
                [IO.FileAttributes]::ReparsePoint) {
            throw "ComfyUI model dizini guvenli degil: $fullPath"
        }
        $name = [IO.Path]::GetFileName($fullPath.TrimEnd('\'))
        $relative = $fullPath.Substring($rootPrefix.Length).
            Replace('\', '/')
        if (-not $index.ContainsKey($name)) {
            $index[$name] = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
        }
        $null = $index[$name].Add($relative)
    }
    return $index
}
function Write-ComfyUIModelConfiguration {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$ModelsRoot
    )
    $comfyRoot = Join-Path $RuntimeRoot 'ComfyUI'
    [IO.Directory]::CreateDirectory($ModelsRoot) | Out-Null
    $lines = [Collections.Generic.List[string]]::new()
    $basePath = $ModelsRoot.Replace('\', '/').Replace("'", "''")
    $lines.Add('winlama:')
    $lines.Add("    base_path: '$basePath'")
    $directoryIndex = Get-ComfyUIModelDirectoryIndex `
        -ModelsRoot $ModelsRoot
    foreach ($entry in ([ordered]@{
        checkpoints = @('checkpoints')
        diffusion_models = @('diffusion_models', 'unet')
        text_encoders = @('text_encoders', 'clip')
        clip = @('clip', 'text_encoders')
        clip_vision = @('clip_vision')
        vae = @('vae')
        loras = @('loras')
        controlnet = @('controlnet')
    }).GetEnumerator()) {
        $names = @($entry.Value)
        $matchingPaths = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($name in $names) {
            if (-not $directoryIndex.ContainsKey($name)) {
                continue
            }
            foreach ($relative in $directoryIndex[$name]) {
                $null = $matchingPaths.Add($relative)
            }
        }
        $paths = @($matchingPaths | Sort-Object)
        if ($paths.Count -eq 1) {
            $lines.Add("    $($entry.Key): $($paths[0])")
        }
        elseif ($paths.Count -gt 1) {
            $lines.Add("    $($entry.Key): |")
            foreach ($relative in $paths) {
                $lines.Add("        $relative")
            }
        }
    }
    $content = $lines -join "`n"
    $path = Join-Path $comfyRoot 'extra_model_paths.yaml'
    [IO.File]::WriteAllText(
        $path,
        $content,
        [Text.UTF8Encoding]::new($false)
    )
    return $path
}
function Assert-ComfyUIModelDirectoryIndexContracts {
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('winlama-comfy-models-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    try {
        $state = @{ Calls = 0 }
        $reader = {
            param($RootPath)
            $state.Calls++
            foreach ($relative in @(
                'Flux\checkpoints',
                'Wan\diffusion_models',
                'Shared\clip',
                'Shared\text_encoders',
                'Shared\vae',
                'Shared\loras',
                'Shared\controlnet',
                'Shared\clip_vision'
            )) {
                $path = Join-Path $RootPath $relative
                [pscustomobject]@{
                    FullName = $path
                    PSIsContainer = $true
                    Attributes = [IO.FileAttributes]::Directory
                }
            }
        }.GetNewClosure()
        $index = Get-ComfyUIModelDirectoryIndex `
            -ModelsRoot $fixtureRoot -DirectoryReader $reader
        if ($state.Calls -ne 1 -or
            -not $index.ContainsKey('checkpoints') -or
            -not $index.ContainsKey('diffusion_models') -or
            -not $index.ContainsKey('text_encoders') -or
            -not $index.ContainsKey('clip') -or
            -not $index.ContainsKey('clip_vision') -or
            -not $index.ContainsKey('vae') -or
            -not $index.ContainsKey('loras') -or
            -not $index.ContainsKey('controlnet')) {
            throw 'ComfyUI model tek tarama sozlesmesi gecersiz.'
        }
    }
    finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.SingleModelTraversal'
    return $true
}
function ConvertTo-ComfyUILauncherArgumentContent {
    param([Parameter(Mandatory)][string]$Content)
    $content = ($Content -replace "`r?`n", "`r`n").TrimEnd(
        "`r", "`n"
    )
    $content = [regex]::Replace(
        $content,
        '(?im)^\s*@?pause\s*(?:\r\n|$)',
        ''
    ).TrimEnd("`r", "`n")
    if ($content -match `
        '(?im)^\s*\.\\python_embeded\\python\.exe\b[^\r\n]*%\*\s*$') {
        return $content
    }
    $pattern = `
        '(?im)^(\s*\.\\python_embeded\\python\.exe\b[^\r\n]*)\r?$'
    if ($content -notmatch $pattern) {
        throw 'ComfyUI hizli baslaticisi gecersiz.'
    }
    $regex = [regex]::new($pattern)
    $content = $regex.Replace($content, '$1 %*', 1)
    return $content.TrimEnd("`r", "`n")
}
function Assert-ComfyUILauncherArguments {
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$ContentReader
    )
    $source = if ($null -eq $ContentReader) {
        [IO.File]::ReadAllText($Path)
    }
    else {
        & $ContentReader $Path
    }
    $content = ConvertTo-ComfyUILauncherArgumentContent `
        -Content $source
    if ($content -cne $source) {
        throw ('ComfyUI baslaticisi canonical degil. ' +
            'Winlama kurulum veya onarim islemini calistirin.')
    }
    return $true
}
function Assert-ComfyUILauncherArgumentContracts {
    $source = '@echo off' + "`r`n" +
        '.\python_embeded\python.exe -s ComfyUI\main.py --fast ' +
        'fp16_accumulation' + "`r`n" +
        'pause' + "`r`n"
    $first = ConvertTo-ComfyUILauncherArgumentContent `
        -Content $source
    $second = ConvertTo-ComfyUILauncherArgumentContent `
        -Content $first
    $canonicalAccepted = Assert-ComfyUILauncherArguments `
        -Path 'C:\Fixture\Launcher.bat' `
        -ContentReader { param($Path) $first }.GetNewClosure()
    $legacyRejected = $false
    try {
        $null = Assert-ComfyUILauncherArguments `
            -Path 'C:\Fixture\Launcher.bat' `
            -ContentReader { param($Path) $source }.GetNewClosure()
    }
    catch {
        $legacyRejected = $true
    }
    $assertionSource = (Get-Command `
        Assert-ComfyUILauncherArguments -ErrorAction Stop).Definition
    if ($first -cne $second -or
        -not $canonicalAccepted -or -not $legacyRejected -or
        $assertionSource -match 'WriteAllText|WriteAllBytes' -or
        ([regex]::Matches($first, '(?m)%\*\r?$')).Count -ne 1 -or
        $first -notmatch '(?m)fp16_accumulation %\*\r?$' -or
        $first -match '(?im)^\s*@?pause\s*$' -or
        $first -match '(?<!\r)\n' -or $first.EndsWith("`n") -or
        $source -notmatch '(?m)fp16_accumulation\r$') {
        throw 'ComfyUI baslatici arguman sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.LauncherArguments'
    return $true
}
function Get-ComfyUILaunchArguments {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($value in @(
        '--listen', [string]$Config.ComfyUI.Host,
        '--port', [string]$Config.ComfyUI.Port,
        '--output-directory',
            (Expand-ComfyUIPath -Path $Config.ComfyUI.OutputPath),
        '--input-directory',
            (Expand-ComfyUIPath -Path $Config.ComfyUI.InputPath),
        '--temp-directory',
            (Expand-ComfyUIPath -Path $Config.ComfyUI.TempPath),
        '--disable-auto-launch'
    )) {
        $arguments.Add([string]$value)
    }
    foreach ($value in @($Config.ComfyUI.LaunchArguments)) {
        if ([string]$value -in @('--fast', 'fp16_accumulation')) {
            continue
        }
        $arguments.Add([string]$value)
    }
    return $arguments.ToArray()
}
function Test-ComfyUICustomNode {
    param(
        [Parameter(Mandatory)][string]$CustomNodesRoot,
        [Parameter(Mandatory)][pscustomobject]$Descriptor
    )
    $root = Join-Path $CustomNodesRoot ([string]$Descriptor.Name)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return $false
    }
    foreach ($relativePath in @($Descriptor.RequiredFiles)) {
        if (-not (Test-Path -LiteralPath `
            (Join-Path $root ([string]$relativePath)) -PathType Leaf)) {
            return $false
        }
    }
    return $true
}
function Get-ComfyUIOrdinalTreeLinesHash {
    param([Parameter(Mandatory)][string[]]$Lines)
    $ordered = [Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        $ordered.Add($line)
    }
    $ordered.Sort([StringComparer]::Ordinal)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(
            ($ordered -join "`n")
        )
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash($bytes)
        )).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}
function Assert-ComfyUICustomNodeTreeHashContracts {
    $first = @('b|2|bb', 'A|1|aa', 'a|1|cc')
    $second = @('a|1|cc', 'b|2|bb', 'A|1|aa')
    $expected = '9EDDB654201D90F84AB37386D02EE06B' +
        '60EAF7556A702381967F342A4FDFD61C'
    $firstBefore = $first -join '|'
    $firstHash = Get-ComfyUIOrdinalTreeLinesHash -Lines $first
    $secondHash = Get-ComfyUIOrdinalTreeLinesHash -Lines $second
    if ($firstHash -cne $expected -or $secondHash -cne $expected -or
        ($first -join '|') -cne $firstBefore) {
        throw 'ComfyUI custom node Ordinal agac hash sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.TreeHashOrdinal'
    return $true
}
function Get-ComfyUICustomNodeTreeHash {
    param([Parameter(Mandatory)][string]$Root)
    $lines = [Collections.Generic.List[string]]::new()
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File `
        -Force -ErrorAction Stop | Where-Object {
            $_.FullName -notmatch '[\\/]\.git([\\/]|$)' -and
            $_.FullName -notmatch '[\\/]__pycache__([\\/]|$)' -and
            $_.Extension -notin @('.pyc', '.pyo')
        })
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Root.Length + 1).
            Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add("$relative|$($file.Length)|$hash")
    }
    return Get-ComfyUIOrdinalTreeLinesHash -Lines $lines.ToArray()
}
function Invoke-ComfyUISourcePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Local', 'Online', 'Automatic')]
        [string]$SourceSelection,
        [Parameter(Mandatory)][string]$Resource,
        [Parameter(Mandatory)][string]$LocalUnavailableMessage,
        [Parameter(Mandatory)][scriptblock]$ReadyProbe,
        [Parameter(Mandatory)][scriptblock]$LocalProbe,
        [Parameter(Mandatory)][scriptblock]$LocalInstaller,
        [Parameter(Mandatory)][scriptblock]$OnlineInstaller,
        [scriptblock]$FallbackNotifier
    )
    if ([bool](& $ReadyProbe)) {
        return 'Ready'
    }
    if ($SourceSelection -ceq 'Online') {
        $null = & $OnlineInstaller
        return 'Online'
    }
    if ([bool](& $LocalProbe)) {
        if ([bool](& $LocalInstaller)) {
            return 'Local'
        }
    }
    if ($SourceSelection -ceq 'Local') {
        throw (New-NonRetryableException `
            -Message $LocalUnavailableMessage)
    }
    $marker = "WINLAMA_SOURCE_FALLBACK:$Resource"
    if ($null -ne $FallbackNotifier) {
        $null = & $FallbackNotifier $marker
    }
    else {
        Write-Verbose $marker
    }
    $null = & $OnlineInstaller
    return 'Online'
}
function Assert-ComfyUISourcePolicyContracts {
    $localEvents = [Collections.Generic.List[string]]::new()
    $localResult = Invoke-ComfyUISourcePolicy `
        -SourceSelection Local -Resource 'Fixture.Local' `
        -LocalUnavailableMessage 'Local source unavailable.' `
        -ReadyProbe {
            $null = $localEvents.Add('Ready')
            return $false
        }.GetNewClosure() `
        -LocalProbe {
            $null = $localEvents.Add('LocalProbe')
            return $true
        }.GetNewClosure() `
        -LocalInstaller {
            $null = $localEvents.Add('Local')
            return $true
        }.GetNewClosure() `
        -OnlineInstaller {
            throw 'Local kip ag cagrisi yapti.'
        }.GetNewClosure()
    if ($localResult -cne 'Local' -or
        ($localEvents -join ',') -cne 'Ready,LocalProbe,Local') {
        throw 'ComfyUI Local kaynak yonlendirmesi gecersiz.'
    }
    $missingEvents = [Collections.Generic.List[string]]::new()
    $localFailure = $null
    try {
        $null = Invoke-ComfyUISourcePolicy `
            -SourceSelection Local -Resource 'Fixture.Missing' `
            -LocalUnavailableMessage 'Local source unavailable.' `
            -ReadyProbe { return $false } `
            -LocalProbe {
                $null = $missingEvents.Add('LocalProbe')
                return $false
            }.GetNewClosure() `
            -LocalInstaller {
                throw 'Eksik yerel kaynak kuruldu.'
            } `
            -OnlineInstaller {
                $null = $missingEvents.Add('Online')
                return $true
            }.GetNewClosure()
    }
    catch {
        $localFailure = $_.Exception
    }
    if ($null -eq $localFailure -or
        $localFailure.Data['Winlama.Retryable'] -ne $false -or
        ($missingEvents -join ',') -cne 'LocalProbe') {
        throw 'ComfyUI Local eksik kaynak siniri gecersiz.'
    }
    $onlineEvents = [Collections.Generic.List[string]]::new()
    $onlineResult = Invoke-ComfyUISourcePolicy `
        -SourceSelection Online -Resource 'Fixture.Online' `
        -LocalUnavailableMessage 'Local source unavailable.' `
        -ReadyProbe {
            $null = $onlineEvents.Add('Ready')
            return $false
        }.GetNewClosure() `
        -LocalProbe {
            throw 'Online kip yerel kaynak taradi.'
        } `
        -LocalInstaller {
            throw 'Online kip yerel kaynak kurdu.'
        } `
        -OnlineInstaller {
            $null = $onlineEvents.Add('Online')
            return $true
        }.GetNewClosure()
    if ($onlineResult -cne 'Online' -or
        ($onlineEvents -join ',') -cne 'Ready,Online') {
        throw 'ComfyUI Online kaynak yonlendirmesi gecersiz.'
    }
    $automaticEvents = [Collections.Generic.List[string]]::new()
    $automaticResult = Invoke-ComfyUISourcePolicy `
        -SourceSelection Automatic -Resource 'Fixture.Automatic' `
        -LocalUnavailableMessage 'Local source unavailable.' `
        -ReadyProbe {
            $null = $automaticEvents.Add('Ready')
            return $false
        }.GetNewClosure() `
        -LocalProbe {
            $null = $automaticEvents.Add('LocalProbe')
            return $false
        }.GetNewClosure() `
        -LocalInstaller {
            throw 'Eksik yerel kaynak kuruldu.'
        } `
        -OnlineInstaller {
            $null = $automaticEvents.Add('Online')
            return $true
        }.GetNewClosure() `
        -FallbackNotifier {
            param([string]$Marker)
            $null = $automaticEvents.Add($Marker)
        }.GetNewClosure()
    $expectedAutomatic = 'Ready,LocalProbe,' +
        'WINLAMA_SOURCE_FALLBACK:Fixture.Automatic,Online'
    if ($automaticResult -cne 'Online' -or
        ($automaticEvents -join ',') -cne $expectedAutomatic) {
        throw 'ComfyUI Automatic geri donus siniri gecersiz.'
    }
    $readyEvents = [Collections.Generic.List[string]]::new()
    $readyResult = Invoke-ComfyUISourcePolicy `
        -SourceSelection Local -Resource 'Fixture.Ready' `
        -LocalUnavailableMessage 'Local source unavailable.' `
        -ReadyProbe {
            $null = $readyEvents.Add('Ready')
            return $true
        }.GetNewClosure() `
        -LocalProbe { throw 'Hazir hedef yerel kaynak taradi.' } `
        -LocalInstaller { throw 'Hazir hedef yeniden kuruldu.' } `
        -OnlineInstaller { throw 'Hazir hedef ag cagrisi yapti.' }
    if ($readyResult -cne 'Ready' -or
        ($readyEvents -join ',') -cne 'Ready') {
        throw 'ComfyUI hazir hedef no-op siniri gecersiz.'
    }
    $archiveSource = (Get-Command Install-ComfyUICustomNodeArchive `
        -ErrorAction Stop).Definition
    $requirementsSource = (Get-Command `
        Install-ComfyUICustomNodeRequirements `
        -ErrorAction Stop).Definition
    $callSiteSource = (Get-Command Install-ComfyUICustomNodes `
        -ErrorAction Stop).Definition
    if ($archiveSource -notmatch 'Invoke-ComfyUISourcePolicy' -or
        $archiveSource -notmatch `
            '\$Config\.ComfyUI\.InstallSource' -or
        $requirementsSource -notmatch `
            'Invoke-ComfyUISourcePolicy' -or
        $callSiteSource -notmatch `
            '-SourceSelection\s+\(\[string\]\$Config\.ComfyUI\.InstallSource\)') {
        throw 'ComfyUI kaynak politikasi gercek cagrilara bagli degil.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.SourcePolicy'
    return $true
}
function Test-ComfyUIExactCustomNode {
    param(
        [Parameter(Mandatory)][string]$CustomNodesRoot,
        [Parameter(Mandatory)][pscustomobject]$Descriptor
    )
    $target = Join-Path $CustomNodesRoot ([string]$Descriptor.Name)
    return (Test-ComfyUICustomNode `
        -CustomNodesRoot $CustomNodesRoot -Descriptor $Descriptor) -and
        (Get-ComfyUICustomNodeTreeHash -Root $target) -ieq
            [string]$Descriptor.TreeSha256
}
function Install-ComfyUILocalCustomNode {
    param(
        [Parameter(Mandatory)][string]$CustomNodesRoot,
        [Parameter(Mandatory)][string]$PackageNodeRoot,
        [Parameter(Mandatory)][pscustomobject]$Descriptor
    )
    $target = Join-Path $CustomNodesRoot ([string]$Descriptor.Name)
    $packageCustomNodesRoot = Split-Path -Parent $PackageNodeRoot
    if (-not (Test-ComfyUIExactCustomNode `
        -CustomNodesRoot $packageCustomNodesRoot `
        -Descriptor $Descriptor)) {
        return $false
    }
    $stage = Join-Path $CustomNodesRoot (
        '.winlama-stage-' + [guid]::NewGuid().ToString('N')
    )
    $backup = Join-Path $CustomNodesRoot (
        '.winlama-backup-' + [guid]::NewGuid().ToString('N')
    )
    try {
        Copy-Item -LiteralPath $PackageNodeRoot -Destination $stage `
            -Recurse -Force
        if ((Get-ComfyUICustomNodeTreeHash -Root $stage) -ine
            [string]$Descriptor.TreeSha256) {
            throw (
                'ComfyUI yerel custom node kopyasi bozuk: ' +
                $Descriptor.Name
            )
        }
        if (Test-Path -LiteralPath $target) {
            Move-Item -LiteralPath $target -Destination $backup
        }
        try {
            Move-Item -LiteralPath $stage -Destination $target
        }
        catch {
            if ((Test-Path -LiteralPath $backup) -and
                -not (Test-Path -LiteralPath $target)) {
                Move-Item -LiteralPath $backup -Destination $target
            }
            throw
        }
        Remove-Item -LiteralPath $backup -Recurse -Force `
            -ErrorAction SilentlyContinue
        Write-WinlamaUIStatus -Level SUCCESS -Message (
            Get-ComfyUIText `
                -Key 'ComfyUI.CustomNode.LocalReady' `
                -Fallback 'Yerel ComfyUI custom node hazir: {0}' `
                -Arguments @($Descriptor.Name)
        )
        return $true
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force `
            -ErrorAction SilentlyContinue
        if ((Test-Path -LiteralPath $backup) -and
            -not (Test-Path -LiteralPath $target)) {
            Move-Item -LiteralPath $backup -Destination $target `
                -ErrorAction SilentlyContinue
        }
    }
}
function Install-ComfyUIOnlineCustomNode {
    param(
        [Parameter(Mandatory)][string]$CustomNodesRoot,
        [Parameter(Mandatory)][pscustomobject]$Descriptor,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $target = Join-Path $CustomNodesRoot ([string]$Descriptor.Name)
    $repository = [string]$Descriptor.Repository
    $commit = [string]$Descriptor.Commit
    $expectedUri = "$repository/archive/$commit.zip"
    if ([string]$Descriptor.ArchiveUri -cne $expectedUri) {
        throw "ComfyUI custom node resmi adresi gecersiz: $target"
    }
    $temporaryRoot = Join-Path (
        Expand-ComfyUIPath -Path ([string]$Config.Paths.Temp)
    ) ('ComfyUICustomNodes\' + [guid]::NewGuid().ToString('N'))
    $archive = Join-Path $temporaryRoot 'source.zip'
    $extractRoot = Join-Path $temporaryRoot 'extract'
    $stage = Join-Path $CustomNodesRoot (
        '.winlama-stage-' + [guid]::NewGuid().ToString('N')
    )
    $backup = Join-Path $CustomNodesRoot (
        '.winlama-backup-' + [guid]::NewGuid().ToString('N')
    )
    try {
        [IO.Directory]::CreateDirectory($extractRoot) | Out-Null
        Write-WinlamaUIStatus -Level STEP -Message (
            Get-ComfyUIText `
                -Key 'ComfyUI.CustomNode.Downloading' `
                -Fallback 'Resmi ComfyUI custom node indiriliyor: {0}' `
                -Arguments @($Descriptor.Name)
        )
        Invoke-WebRequest -Uri $expectedUri -OutFile $archive `
            -UseBasicParsing -TimeoutSec `
            ([int]$Config.Network.DownloadTimeoutSeconds)
        Expand-Archive -LiteralPath $archive `
            -DestinationPath $extractRoot -Force
        $source = @(Get-ChildItem -LiteralPath $extractRoot `
            -Directory -ErrorAction Stop | Where-Object {
                foreach ($relativePath in @($Descriptor.RequiredFiles)) {
                    if (-not (Test-Path -LiteralPath `
                        (Join-Path $_.FullName $relativePath) `
                        -PathType Leaf)) {
                        return $false
                    }
                }
                return $true
            }) | Select-Object -First 1 -ExpandProperty FullName
        if ([string]::IsNullOrWhiteSpace($source) -or
            (Get-ComfyUICustomNodeTreeHash -Root $source) -ine
                [string]$Descriptor.TreeSha256) {
            throw (
                'ComfyUI custom node icerik dogrulamasi basarisiz: ' +
                $Descriptor.Name
            )
        }
        Copy-Item -LiteralPath $source -Destination $stage `
            -Recurse -Force
        if ((Get-ComfyUICustomNodeTreeHash -Root $stage) -ine
            [string]$Descriptor.TreeSha256) {
            throw (
                'ComfyUI custom node kopya dogrulamasi basarisiz: ' +
                $Descriptor.Name
            )
        }
        $targetMoved = $false
        if (Test-Path -LiteralPath $target) {
            Move-Item -LiteralPath $target -Destination $backup
            $targetMoved = $true
        }
        try {
            Move-Item -LiteralPath $stage -Destination $target
        }
        catch {
            if ($targetMoved -and
                -not (Test-Path -LiteralPath $target)) {
                Move-Item -LiteralPath $backup -Destination $target
            }
            throw
        }
        Remove-Item -LiteralPath $backup -Recurse -Force `
            -ErrorAction SilentlyContinue
        Write-WinlamaUIStatus -Level SUCCESS -Message (
            Get-ComfyUIText `
                -Key 'ComfyUI.CustomNode.Ready' `
                -Fallback 'ComfyUI custom node hazir: {0}' `
                -Arguments @($Descriptor.Name)
        )
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force `
            -ErrorAction SilentlyContinue
        if ((Test-Path -LiteralPath $backup) -and
            -not (Test-Path -LiteralPath $target)) {
            Move-Item -LiteralPath $backup -Destination $target `
                -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}
function Install-ComfyUICustomNodeArchive {
    param(
        [Parameter(Mandatory)][string]$CustomNodesRoot,
        [Parameter(Mandatory)][pscustomobject]$Descriptor,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $sourceSelection = [string]$Config.ComfyUI.InstallSource
    $localState = @{ PackageNodeRoot = '' }
    $resource = 'ComfyUI.CustomNode.{0}' -f `
        [string]$Descriptor.Name
    $localUnavailable = Get-LocalizedText `
        -Key 'ComfyUI.Error.LocalCustomNodeUnavailable' `
        -Arguments @([string]$Descriptor.Name)
    $null = Invoke-ComfyUISourcePolicy `
        -SourceSelection $sourceSelection -Resource $resource `
        -LocalUnavailableMessage $localUnavailable `
        -ReadyProbe {
            Test-ComfyUIExactCustomNode `
                -CustomNodesRoot $CustomNodesRoot `
                -Descriptor $Descriptor
        }.GetNewClosure() `
        -LocalProbe {
            $expectedOffline = 'Runtime\ComfyUICustomNodes\{0}' -f `
                [string]$Descriptor.Name
            $offlineRelative = [string]$Descriptor.OfflinePath
            if ($offlineRelative -cne $expectedOffline) {
                throw (
                    'ComfyUI yerel custom node yolu gecersiz: ' +
                    $offlineRelative
                )
            }
            $localState.PackageNodeRoot = [IO.Path]::GetFullPath(
                (Join-Path $projectRoot $offlineRelative)
            )
            Test-ComfyUIExactCustomNode `
                -CustomNodesRoot (Split-Path -Parent `
                    $localState.PackageNodeRoot) `
                -Descriptor $Descriptor
        }.GetNewClosure() `
        -LocalInstaller {
            Install-ComfyUILocalCustomNode `
                -CustomNodesRoot $CustomNodesRoot `
                -PackageNodeRoot $localState.PackageNodeRoot `
                -Descriptor $Descriptor
        }.GetNewClosure() `
        -OnlineInstaller {
            Install-ComfyUIOnlineCustomNode `
                -CustomNodesRoot $CustomNodesRoot `
                -Descriptor $Descriptor -Config $Config
        }.GetNewClosure()
}
function Test-ComfyUIRequirementLinesContract {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
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
function Test-ComfyUIRequirementsSourceContract {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -lt 1 -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            return $false
        }
        return Test-ComfyUIRequirementLinesContract `
            -Lines ([IO.File]::ReadAllLines($Path))
    }
    catch {
        return $false
    }
}
function Test-ComfyUIBaseRequirementsIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    if (-not (Test-ComfyUIRequirementsSourceContract -Path $Path)) {
        return $false
    }
    try {
        $expectedLines = @($Config.ComfyUI.BaseRequirements |
            ForEach-Object { [string]$_ })
        $actualLines = @([IO.File]::ReadAllLines($Path))
        if ($expectedLines.Count -lt 1 -or
            $actualLines.Count -ne $expectedLines.Count) {
            return $false
        }
        for ($index = 0; $index -lt $expectedLines.Count; $index++) {
            if ([string]$actualLines[$index] -cne
                [string]$expectedLines[$index]) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}
function Get-ComfyUIPipRequirementArguments {
    param(
        [Parameter(Mandatory)][string]$Requirements,
        [Parameter(Mandatory)]
        [ValidateSet('Verify', 'Wheelhouse', 'PyPI')]
        [string]$Mode,
        [string]$WheelhouseRoot
    )
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($value in @(
        '-B', '-I', '-s', '-m', 'pip', '--isolated', 'install',
        '--disable-pip-version-check', '--no-input',
        '--no-warn-script-location'
    )) {
        $arguments.Add($value)
    }
    switch ($Mode) {
        'Verify' {
            $arguments.Add('--dry-run')
            $arguments.Add('--no-index')
        }
        'Wheelhouse' {
            if ([string]::IsNullOrWhiteSpace($WheelhouseRoot)) {
                throw 'ComfyUI wheelhouse yolu bos olamaz.'
            }
            $arguments.Add('--no-index')
            $arguments.Add('--find-links')
            $arguments.Add($WheelhouseRoot)
            $arguments.Add('--only-binary=:all:')
        }
        'PyPI' {
            $arguments.Add('--index-url')
            $arguments.Add('https://pypi.org/simple')
            $arguments.Add('--no-cache-dir')
        }
    }
    $arguments.Add('--requirement')
    $arguments.Add($Requirements)
    return $arguments.ToArray()
}
function Stop-ComfyUIPipProcessTree {
    param(
        [Parameter(Mandatory)][object]$Process,
        [ValidateRange(1000, 60000)]
        [int]$WaitMilliseconds = 5000,
        [scriptblock]$LegacyTreeKiller = {
            param($TargetProcessId, $TimeoutMilliseconds)
            $system32 = [Environment]::GetFolderPath(
                [Environment+SpecialFolder]::System
            )
            if ([string]::IsNullOrWhiteSpace($system32)) {
                throw 'Windows System32 dizini bulunamadi.'
            }
            $system32 = [IO.Path]::GetFullPath($system32).
                TrimEnd('\')
            $taskkill = Join-Path $system32 'taskkill.exe'
            $taskkillItem = Get-Item -LiteralPath $taskkill -Force `
                -ErrorAction Stop
            if ($taskkillItem.Attributes -band
                [IO.FileAttributes]::ReparsePoint -or
                [IO.Path]::GetFullPath(
                    $taskkillItem.DirectoryName
                ) -ine $system32) {
                throw 'Guvenilir taskkill.exe bulunamadi.'
            }
            $signature = Get-AuthenticodeSignature `
                -LiteralPath $taskkill -ErrorAction Stop
            if ($signature.Status -isnot
                [Management.Automation.SignatureStatus] -or
                $signature.Status -ne
                    [Management.Automation.SignatureStatus]::Valid -or
                $signature.SignerCertificate.Subject -notmatch
                    'Microsoft (Corporation|Windows)') {
                throw 'taskkill.exe imzasi dogrulanamadi.'
            }
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
                        $null = $killer.WaitForExit(2000)
                    }
                    catch {
                    }
                    throw 'taskkill.exe zaman asimina ugradi.'
                }
                try {
                    $outputComplete = [Threading.Tasks.Task]::WaitAll(
                        [Threading.Tasks.Task[]]@(
                            $stdoutTask,
                            $stderrTask
                        ),
                        2000
                    )
                }
                catch {
                    $outputComplete = $false
                }
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
    if ([bool]$Process.HasExited) {
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
            Write-Verbose ('ComfyUI Kill(true) basarisiz: {0}' -f `
                $_.Exception.Message)
        }
    }
    if ($treeKillInvoked -and
        $Process.WaitForExit($WaitMilliseconds)) {
        return
    }
    if (-not [bool]$Process.HasExited) {
        $null = & $LegacyTreeKiller `
            $Process.Id $WaitMilliseconds
    }
    if (-not [bool]$Process.HasExited -and
        -not $Process.WaitForExit($WaitMilliseconds)) {
        throw "ComfyUI surec agaci durdurulamadi: $($Process.Id)"
    }
}
function Invoke-ComfyUIPipRequirements {
    param(
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string]$Requirements,
        [Parameter(Mandatory)]
        [ValidateSet('Verify', 'Wheelhouse', 'PyPI')]
        [string]$Mode,
        [string]$WheelhouseRoot,
        [ValidateRange(0, 86400)]
        [int]$TimeoutSeconds = 0,
        [scriptblock]$ProcessStarter = {
            param($StartParameters)
            Start-Process @StartParameters
        },
        [scriptblock]$TreeKiller = {
            param($TargetProcess, $WaitMilliseconds)
            Stop-ComfyUIPipProcessTree -Process $TargetProcess `
                -WaitMilliseconds $WaitMilliseconds
        }
    )
    $effectiveTimeout = if ($TimeoutSeconds -gt 0) {
        $TimeoutSeconds
    }
    elseif ($Mode -ceq 'Verify') {
        120
    }
    else {
        900
    }
    $arguments = @(Get-ComfyUIPipRequirementArguments `
        -Requirements $Requirements -Mode $Mode `
        -WheelhouseRoot $WheelhouseRoot)
    $processArguments = @($arguments | ForEach-Object {
        ConvertTo-ComfyUIProcessArgument -Value ([string]$_)
    })
    $redirectedPaths = [Collections.Generic.List[string]]::new()
    $process = $null
    $cleanupFailure = $null
    try {
        $startParameters = @{
            FilePath = $Python
            ArgumentList = $processArguments
            WorkingDirectory = Split-Path -Parent $Requirements
            PassThru = $true
            NoNewWindow = $true
        }
        if ($Mode -ceq 'Verify') {
            $token = [guid]::NewGuid().ToString('N')
            $temporaryRoot = [IO.Path]::GetTempPath()
            $standardOutput = Join-Path $temporaryRoot `
                "winlama-comfy-pip-$token.stdout"
            $standardError = Join-Path $temporaryRoot `
                "winlama-comfy-pip-$token.stderr"
            $redirectedPaths.Add($standardOutput)
            $redirectedPaths.Add($standardError)
            $startParameters.RedirectStandardOutput = $standardOutput
            $startParameters.RedirectStandardError = $standardError
        }
        $process = & $ProcessStarter $startParameters
        if ($null -eq $process) {
            throw 'ComfyUI pip sureci baslatilamadi.'
        }
        if (-not $process.WaitForExit($effectiveTimeout * 1000)) {
            $terminationError = ''
            try {
                $null = & $TreeKiller $process 5000
            }
            catch {
                $terminationError = $_.Exception.Message
            }
            $message = (('ComfyUI pip {0} sureci {1} saniyede ' +
                'zaman asimina ugradi.') -f $Mode, $effectiveTimeout)
            if (-not [string]::IsNullOrWhiteSpace(
                    $terminationError
                )) {
                $message += " Surec agaci hatasi: $terminationError"
            }
            throw [TimeoutException]::new($message)
        }
        return [int]$process.ExitCode
    }
    catch [TimeoutException] {
        Write-Verbose $_.Exception.Message
        throw
    }
    catch {
        Write-Verbose ('ComfyUI pip {0} cagrisi basarisiz: {1}' -f `
            $Mode, $_.Exception.Message)
        return -1
    }
    finally {
        if ($null -ne $process) {
            try {
                if (-not [bool]$process.HasExited) {
                    $null = & $TreeKiller $process 5000
                }
            }
            catch {
                $cleanupFailure = $_.Exception
            }
            try {
                $process.Dispose()
            }
            catch {
                if ($null -eq $cleanupFailure) {
                    $cleanupFailure = $_.Exception
                }
            }
        }
        foreach ($path in $redirectedPaths) {
            Remove-Item -LiteralPath $path -Force `
                -ErrorAction SilentlyContinue
        }
        if ($null -ne $cleanupFailure) {
            throw [InvalidOperationException]::new(
                'ComfyUI pip sureci temizlenemedi.',
                $cleanupFailure
            )
        }
    }
}
function Get-ComfyUIValidatedWheelhouse {
    $wheelhouse = Join-Path $projectRoot `
        'Runtime\ComfyUI\wheelhouse'
    if (-not (Test-Path -LiteralPath $wheelhouse `
        -PathType Container)) {
        return $null
    }
    $manifestPath = Join-Path $wheelhouse `
        '.winlama-wheelhouse.json'
    try {
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw 'Wheelhouse SHA-256 manifesti yok.'
        }
        $manifest = [IO.File]::ReadAllText($manifestPath) |
            ConvertFrom-ComfyUIJson
        if ([int]$manifest.SchemaVersion -ne 1 -or
            @($manifest.Files).Count -eq 0) {
            throw 'Wheelhouse manifest bicimi gecersiz.'
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
                throw 'Wheelhouse manifest kaydi gecersiz.'
            }
            $path = Join-Path $wheelhouse $name
            $file = Get-Item -LiteralPath $path -Force `
                -ErrorAction Stop
            if ($file.Attributes -band
                [IO.FileAttributes]::ReparsePoint -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash `
                    -ine $expectedHash) {
                throw "Wheelhouse dosyasi dogrulanamadi: $name"
            }
        }
        $actual = @(Get-ChildItem -LiteralPath $wheelhouse `
            -File -Filter '*.whl' -Force -ErrorAction Stop)
        if ($actual.Count -ne $listed.Count -or
            @($actual | Where-Object {
                -not $listed.Contains($_.Name)
            }).Count -ne 0) {
            throw 'Wheelhouse dosya kumesi manifest ile uyusmuyor.'
        }
        return $wheelhouse
    }
    catch {
        Write-WinlamaUIStatus -Level WARN -Message (
            Get-ComfyUIText `
                -Key 'ComfyUI.Warning.WheelhouseSkipped' `
                -Fallback 'Yerel ComfyUI wheelhouse atlandi: {0}' `
                -Arguments @($_.Exception.Message)
        )
        return $null
    }
}
function Install-ComfyUIBaseRequirements {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $requirements = Join-Path $RuntimeRoot `
        'ComfyUI\requirements.txt'
    if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) {
        throw "ComfyUI temel requirements kaynagi eksik: $requirements"
    }
    if (-not (Test-ComfyUIRequirementsSourceContract `
        -Path $requirements)) {
        throw "ComfyUI temel requirements kaynagi gecersiz: $requirements"
    }
    if (-not (Test-ComfyUIBaseRequirementsIdentity `
        -Path $requirements -Config $Config)) {
        throw "ComfyUI temel requirements kimligi gecersiz: $requirements"
    }
    $python = Join-Path $RuntimeRoot 'python_embeded\python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw "ComfyUI gomulu Python bulunamadi: $python"
    }
    $state = @{ Wheelhouse = '' }
    $localUnavailable = Get-LocalizedText `
        -Key 'ComfyUI.Error.LocalRequirementsUnavailable' `
        -Arguments @('temel ComfyUI paketleri')
    return Invoke-ComfyUISourcePolicy `
        -SourceSelection ([string]$Config.ComfyUI.InstallSource) `
        -Resource 'ComfyUI.Requirements.Base' `
        -LocalUnavailableMessage $localUnavailable `
        -ReadyProbe {
            (Invoke-ComfyUIPipRequirements -Python $python `
                -Requirements $requirements -Mode Verify) -eq 0
        }.GetNewClosure() `
        -LocalProbe {
            $state.Wheelhouse = Get-ComfyUIValidatedWheelhouse
            -not [string]::IsNullOrWhiteSpace($state.Wheelhouse)
        }.GetNewClosure() `
        -LocalInstaller {
            $wheelhouseExit = Invoke-ComfyUIPipRequirements `
                -Python $python -Requirements $requirements `
                -Mode Wheelhouse -WheelhouseRoot $state.Wheelhouse
            return $wheelhouseExit -eq 0 -and
                (Invoke-ComfyUIPipRequirements -Python $python `
                    -Requirements $requirements -Mode Verify) -eq 0
        }.GetNewClosure() `
        -OnlineInstaller {
            $onlineExit = Invoke-ComfyUIPipRequirements `
                -Python $python -Requirements $requirements -Mode PyPI
            if ($onlineExit -ne 0 -or
                (Invoke-ComfyUIPipRequirements -Python $python `
                    -Requirements $requirements -Mode Verify) -ne 0) {
                throw 'ComfyUI temel gereksinimleri kurulamadi.'
            }
            return $true
        }.GetNewClosure()
}
function Install-ComfyUICustomNodeRequirements {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$NodeRoot,
        [Parameter(Mandatory)]
        [ValidateSet('Local', 'Online', 'Automatic')]
        [string]$SourceSelection
    )
    $requirements = Join-Path $NodeRoot 'requirements.txt'
    if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) {
        return 'NotRequired'
    }
    if (-not (Test-ComfyUIRequirementsSourceContract `
        -Path $requirements)) {
        throw "ComfyUI requirements kaynagi guvenli degil: $NodeRoot"
    }
    $python = Join-Path $RuntimeRoot 'python_embeded\python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw "ComfyUI gomulu Python bulunamadi: $python"
    }
    $nodeName = [IO.Path]::GetFileName($NodeRoot)
    $state = @{ Wheelhouse = '' }
    $localUnavailable = Get-LocalizedText `
        -Key 'ComfyUI.Error.LocalRequirementsUnavailable' `
        -Arguments @($nodeName)
    $result = Invoke-ComfyUISourcePolicy `
        -SourceSelection $SourceSelection `
        -Resource "ComfyUI.Requirements.$nodeName" `
        -LocalUnavailableMessage $localUnavailable `
        -ReadyProbe {
            (Invoke-ComfyUIPipRequirements -Python $python `
                -Requirements $requirements -Mode Verify) -eq 0
        }.GetNewClosure() `
        -LocalProbe {
            $state.Wheelhouse = Get-ComfyUIValidatedWheelhouse
            -not [string]::IsNullOrWhiteSpace($state.Wheelhouse)
        }.GetNewClosure() `
        -LocalInstaller {
            $wheelhouseExit = Invoke-ComfyUIPipRequirements `
                -Python $python -Requirements $requirements `
                -Mode Wheelhouse -WheelhouseRoot $state.Wheelhouse
            if ($wheelhouseExit -eq 0 -and
                (Invoke-ComfyUIPipRequirements -Python $python `
                    -Requirements $requirements -Mode Verify) -eq 0) {
                return $true
            }
            Write-WinlamaUIStatus -Level WARN -Message (
                Get-ComfyUIText `
                    -Key 'ComfyUI.Warning.WheelhouseIncomplete' `
                    -Fallback ('Yerel ComfyUI wheelhouse gereksinimleri ' +
                        'karsilamadi: {0}') `
                    -Arguments @($nodeName)
            )
            return $false
        }.GetNewClosure() `
        -OnlineInstaller {
            $onlineExit = Invoke-ComfyUIPipRequirements `
                -Python $python -Requirements $requirements `
                -Mode PyPI
            if ($onlineExit -ne 0 -or
                (Invoke-ComfyUIPipRequirements -Python $python `
                    -Requirements $requirements -Mode Verify) -ne 0) {
                throw "ComfyUI dugum gereksinimi kurulamadi: $NodeRoot"
            }
            return $true
        }.GetNewClosure()
    $installedFrom = switch ($result) {
        'Ready' { 'Installed' }
        'Local' { 'Wheelhouse' }
        default { 'PyPI' }
    }
    return $installedFrom
}
function Get-ComfyUIRequirementsStatePath {
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    return Join-Path $RuntimeRoot `
        '.winlama\custom-node-requirements.json'
}
function Assert-ComfyUIRequirementsContracts {
    $requirements = 'C:\Fixture\Node\requirements.txt'
    $wheelhouse = 'C:\Fixture\Runtime\wheelhouse'
    $verify = @(Get-ComfyUIPipRequirementArguments `
        -Requirements $requirements -Mode Verify)
    $local = @(Get-ComfyUIPipRequirementArguments `
        -Requirements $requirements -Mode Wheelhouse `
        -WheelhouseRoot $wheelhouse)
    $online = @(Get-ComfyUIPipRequirementArguments `
        -Requirements $requirements -Mode PyPI)
    if ('-B' -notin $verify -or
        '-B' -notin $local -or '-B' -notin $online -or
        '--isolated' -notin $verify -or
        '--isolated' -notin $local -or
        '--isolated' -notin $online -or
        '--no-warn-script-location' -notin $verify -or
        '--no-warn-script-location' -notin $local -or
        '--no-warn-script-location' -notin $online -or
        '--dry-run' -notin $verify -or '--no-index' -notin $verify -or
        '--index-url' -in $verify -or '--no-index' -notin $local -or
        '--find-links' -notin $local -or
        'https://pypi.org/simple' -in $local -or
        'https://pypi.org/simple' -notin $online -or
        '--no-index' -in $online) {
        throw 'ComfyUI requirements pip kaynak sozlesmesi gecersiz.'
    }
    if ((Test-ComfyUIRequirementLinesContract `
            -Lines ([string[]]@())) -or
        (Test-ComfyUIRequirementLinesContract -Lines @(
            '', '   ', '# yalniz aciklama'
        ))) {
        throw 'Bos ComfyUI requirements fixture kabul edildi.'
    }
    if (-not (Test-ComfyUIRequirementLinesContract -Lines @(
        '# pinned custom node requirements',
        'numpy>=1.25; python_version < "3.13"',
        'opencv-python'
    ))) {
        throw 'Guvenli ComfyUI requirements fixture reddedildi.'
    }
    foreach ($badLine in @(
        '--extra-index-url https://example.invalid/simple',
        'package @ https://example.invalid/package.whl',
        'package==1.0 --trusted-host example.invalid',
        'package @ local-artifact',
        '.\local-package',
        'C:\local-package',
        'folder/package',
        '-r nested.txt',
        '.',
        '..',
        'local-package.zip',
        'local-package.tar.gz'
    )) {
        if (Test-ComfyUIRequirementLinesContract -Lines @($badLine)) {
            throw 'Guvenli olmayan ComfyUI requirements fixture kabul edildi.'
        }
    }
    $state = Get-ComfyUIRequirementsStatePath `
        -RuntimeRoot 'C:\Fixture\Runtime'
    if ($state -cne ('C:\Fixture\Runtime\.winlama\' +
        'custom-node-requirements.json') -or
        $state -match '(?i)[\\/]ComfyUI[\\/]user[\\/]') {
        throw 'ComfyUI requirements durum yolu gecersiz.'
    }
    if ($requirements -cne 'C:\Fixture\Node\requirements.txt' -or
        $wheelhouse -cne 'C:\Fixture\Runtime\wheelhouse') {
        throw 'ComfyUI requirements fixture girdisi degisti.'
    }
    $missingRuntime = Join-Path $env:TEMP (
        'Winlama-Missing-ComfyUI-' + [guid]::NewGuid().ToString('N')
    )
    $missingBaseRejected = $false
    try {
        $null = Install-ComfyUIBaseRequirements `
            -RuntimeRoot $missingRuntime `
            -Config ([pscustomobject]@{})
    }
    catch {
        $missingBaseRejected = $true
    }
    if (-not $missingBaseRejected) {
        throw 'Eksik temel requirements kaynagi kabul edildi.'
    }
    $baseIdentityRoot = Join-Path $env:TEMP (
        'Winlama-ComfyUI-Identity-' + [guid]::NewGuid().ToString('N')
    )
    $baseIdentityConfig = [pscustomobject]@{
        ComfyUI = [pscustomobject]@{
            BaseRequirements = @('torch')
        }
    }
    try {
        [IO.Directory]::CreateDirectory($baseIdentityRoot) | Out-Null
        $baseIdentityPath = Join-Path $baseIdentityRoot `
            'requirements.txt'
        [IO.File]::WriteAllText(
            $baseIdentityPath,
            'torch',
            [Text.UTF8Encoding]::new($false)
        )
        $validBaseIdentity = Test-ComfyUIBaseRequirementsIdentity `
            -Path $baseIdentityPath -Config $baseIdentityConfig
        [IO.File]::WriteAllText(
            $baseIdentityPath,
            'stale-package',
            [Text.UTF8Encoding]::new($false)
        )
        if (-not $validBaseIdentity -or
            (Test-ComfyUIBaseRequirementsIdentity `
                -Path $baseIdentityPath -Config $baseIdentityConfig)) {
            throw 'ComfyUI temel requirements kimlik siniri gecersiz.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $baseIdentityRoot) {
            [IO.Directory]::Delete($baseIdentityRoot, $true)
        }
    }
    $baseSource = (Get-Command Install-ComfyUIBaseRequirements `
        -ErrorAction Stop).Definition
    if ($baseSource -notmatch 'ComfyUI\\requirements\.txt' -or
        $baseSource -notmatch 'ComfyUI\.Requirements\.Base' -or
        $baseSource -notmatch 'Get-ComfyUIValidatedWheelhouse' -or
        $baseSource -notmatch 'Test-ComfyUIBaseRequirementsIdentity' -or
        $baseSource -notmatch '-Mode PyPI') {
        throw 'ComfyUI temel requirements onarim yolu eksik.'
    }
    $processState = @{
        Starts = 0
        Kills = 0
        Parameters = $null
        DescendantRunning = $true
        KilledProcessId = 0
    }
    $fakeProcess = [pscustomobject]@{
        Id = 4242
        HasExited = $false
        ExitCode = 0
        Disposed = $false
        WaitMilliseconds = 0
    }
    $fakeProcess | Add-Member -MemberType ScriptMethod `
        -Name WaitForExit -Value {
            param($Milliseconds)
            $this.WaitMilliseconds = $Milliseconds
            return $false
        }
    $fakeProcess | Add-Member -MemberType ScriptMethod `
        -Name Dispose -Value {
            $this.Disposed = $true
        }
    $starter = {
        param($StartParameters)
        $processState.Starts++
        $processState.Parameters = $StartParameters
        return $fakeProcess
    }.GetNewClosure()
    $legacyTreeKiller = {
        param($TargetProcessId, $WaitMilliseconds)
        $processState.Kills++
        $processState.KilledProcessId = $TargetProcessId
        $processState.DescendantRunning = $false
        $fakeProcess.HasExited = $true
    }.GetNewClosure()
    $treeKiller = {
        param($TargetProcess, $WaitMilliseconds)
        Stop-ComfyUIPipProcessTree -Process $TargetProcess `
            -WaitMilliseconds $WaitMilliseconds `
            -LegacyTreeKiller $legacyTreeKiller
    }.GetNewClosure()
    $timeoutCaught = $false
    try {
        $null = Invoke-ComfyUIPipRequirements `
            -Python 'C:\Fixture\python.exe' `
            -Requirements $requirements -Mode Verify `
            -TimeoutSeconds 1 -ProcessStarter $starter `
            -TreeKiller $treeKiller
    }
    catch [TimeoutException] {
        $timeoutCaught = $true
    }
    if (-not $timeoutCaught -or
        $processState.Starts -ne 1 -or
        $processState.Kills -ne 1 -or
        $processState.DescendantRunning -or
        $processState.KilledProcessId -ne $fakeProcess.Id -or
        $fakeProcess.WaitMilliseconds -ne 1000 -or
        -not $fakeProcess.HasExited -or
        -not $fakeProcess.Disposed -or
        $processState.Parameters.ContainsKey('Wait')) {
        throw 'ComfyUI pip zaman asimi ve surec agaci sozlesmesi gecersiz.'
    }
    $terminationSource = (Get-Command `
        Stop-ComfyUIPipProcessTree -ErrorAction Stop).Definition
    if ($terminationSource -notmatch 'taskkill\.exe' -or
        $terminationSource -notmatch '/T /F' -or
        $terminationSource -notmatch '\[bool\]') {
        throw 'ComfyUI pip surec agaci sonlandirma yolu eksik.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.EmptyRequirementsLines'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:ComfyUI.RequiredBaseRequirements'
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.RequirementsContracts'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:ComfyUI.BoundedPipProcessTree'
    return $true
}
function Install-ComfyUICustomNodes {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $obsoleteRequirementsState = Join-Path $RuntimeRoot `
        'ComfyUI\user\default\winlama-custom-nodes.json'
    Remove-Item -LiteralPath $obsoleteRequirementsState -Force `
        -ErrorAction SilentlyContinue
    if ('Wan2.1-T2V-1.3B' -notin @(
        $Config.ComfyUI.Requested
    )) {
        return
    }
    $customNodesRoot = Join-Path $RuntimeRoot 'ComfyUI\custom_nodes'
    [IO.Directory]::CreateDirectory($customNodesRoot) | Out-Null
    $requirementsState = Get-ComfyUIRequirementsStatePath `
        -RuntimeRoot $RuntimeRoot
    $expectedState = [ordered]@{}
    $nodes = @($Config.ComfyUI.CustomNodes | Where-Object {
        $_.RequiredBy -ieq 'Wan2.1-T2V-1.3B'
    })
    foreach ($descriptor in $nodes) {
        Install-ComfyUICustomNodeArchive `
            -CustomNodesRoot $customNodesRoot `
            -Descriptor $descriptor -Config $Config
        $expectedState[[string]$descriptor.Name] = [ordered]@{
            Commit = [string]$descriptor.Commit
            TreeSha256 = [string]$descriptor.TreeSha256
            RequirementsSha256 = if (Test-Path -LiteralPath `
                (Join-Path $customNodesRoot `
                    "$($descriptor.Name)\requirements.txt") `
                -PathType Leaf) {
                (Get-FileHash -LiteralPath (Join-Path $customNodesRoot `
                    "$($descriptor.Name)\requirements.txt") `
                    -Algorithm SHA256).Hash
            }
            else {
                ''
            }
        }
    }
    foreach ($descriptor in $nodes) {
        $null = Install-ComfyUICustomNodeRequirements `
            -RuntimeRoot $RuntimeRoot `
            -NodeRoot (Join-Path $customNodesRoot $descriptor.Name) `
            -SourceSelection ([string]$Config.ComfyUI.InstallSource)
    }
    $stateJson = $expectedState | ConvertTo-Json -Compress
    [IO.Directory]::CreateDirectory(
        (Split-Path -Parent $requirementsState)
    ) | Out-Null
    $temporaryState = "$requirementsState.$PID.tmp"
    try {
        [IO.File]::WriteAllText(
            $temporaryState,
            $stateJson,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryState `
            -Destination $requirementsState -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryState -Force `
            -ErrorAction SilentlyContinue
    }
}
function Install-ComfyUIDefaultWorkflow {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $wanRequested = 'Wan2.1-T2V-1.3B' -iin @(
        $Config.ComfyUI.Requested
    )
    $comfyRoot = Join-Path $RuntimeRoot 'ComfyUI'
    $extensionDestination = Join-Path $comfyRoot `
        'custom_nodes\WinlamaDefaultWorkflow'
    if (-not $wanRequested) {
        if (Test-Path -LiteralPath $extensionDestination `
            -PathType Container) {
            Remove-Item -LiteralPath $extensionDestination `
                -Recurse -Force
        }
        return $null
    }
    $source = Join-Path $projectRoot `
        'Data\Workflows\Wan2.1_T2V_Workflow.json'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Varsayilan ComfyUI workflow bulunamadi: $source"
    }
    $workflow = Get-Content -LiteralPath $source -Raw `
        -Encoding UTF8 | ConvertFrom-ComfyUIJson
    if (@($workflow.nodes).Count -eq 0 -or
        @($workflow.links).Count -eq 0) {
        throw 'Varsayilan ComfyUI workflow bicimi gecersiz.'
    }
    $userRoot = Join-Path $comfyRoot 'user\default'
    $workflowsRoot = Join-Path $userRoot 'workflows'
    [IO.Directory]::CreateDirectory($workflowsRoot) | Out-Null
    $destination = Join-Path $workflowsRoot `
        'Wan2.1_T2V_Workflow.json'
    $temporary = "$destination.$PID.tmp"
    try {
        [IO.File]::Copy($source, $temporary, $true)
        Move-Item -LiteralPath $temporary `
            -Destination $destination -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
    }
    $sourceHash = (Get-FileHash -LiteralPath $source `
        -Algorithm SHA256).Hash
    foreach ($obsoletePath in @(
        (Join-Path $userRoot 'default_graph.json'),
        (Join-Path $userRoot 'default_workflow.json'),
        (Join-Path $userRoot 'Wan2.1_T2V_Workflow.json'),
        (Join-Path $workflowsRoot 'default_graph.json'),
        (Join-Path $workflowsRoot 'default_workflow.json')
    )) {
        if ((Test-Path -LiteralPath $obsoletePath -PathType Leaf) -and
            (Get-FileHash -LiteralPath $obsoletePath `
                -Algorithm SHA256).Hash -eq $sourceHash) {
            Remove-Item -LiteralPath $obsoletePath -Force
        }
    }
    $extensionSource = Join-Path $projectRoot `
        'Modules\ComfyUI\DefaultWorkflow'
    if (-not (Test-Path -LiteralPath $extensionSource `
        -PathType Container)) {
        throw "ComfyUI varsayilan workflow uzantisi yok: $extensionSource"
    }
    $customNodesRoot = Join-Path $comfyRoot 'custom_nodes'
    [IO.Directory]::CreateDirectory($customNodesRoot) | Out-Null
    foreach ($obsoleteName in @(
        'DefaultWorkflow',
        'Winlama-Default-Workflow'
    )) {
        $obsoleteExtension = Join-Path $customNodesRoot $obsoleteName
        if (Test-Path -LiteralPath $obsoleteExtension `
            -PathType Container) {
            Remove-Item -LiteralPath $obsoleteExtension `
                -Recurse -Force
        }
    }
    if (Test-Path -LiteralPath $extensionDestination `
        -PathType Container) {
        Remove-Item -LiteralPath $extensionDestination `
            -Recurse -Force
    }
    Copy-Item -LiteralPath $extensionSource `
        -Destination $extensionDestination -Recurse -Force
    return $destination
}
function Clear-ComfyUITemporaryMedia {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $expectedLeaves = [ordered]@{
        OutputPath = 'output'
        InputPath = 'input'
        TempPath = 'temp'
    }
    $temporaryRoot = $null
    foreach ($entry in $expectedLeaves.GetEnumerator()) {
        $name = [string]$entry.Key
        $path = Expand-ComfyUIPath -Path ([string]$Config.ComfyUI.$name)
        $trimmed = $path.TrimEnd('\')
        $root = Split-Path -Parent $trimmed
        $parent = Split-Path -Parent $root
        if ([IO.Path]::GetFileName($trimmed) -ine $entry.Value -or
            [IO.Path]::GetFileName($root) -ine 'ComfyUI' -or
            [IO.Path]::GetFileName($parent) -ine 'Winlama') {
            throw "Gecici ComfyUI yolu Winlama duzenine uymuyor: $path"
        }
        if ($null -eq $temporaryRoot) {
            $temporaryRoot = $root
        }
        elseif ($root -ine $temporaryRoot) {
            throw "ComfyUI gecici yollari ayni kokte olmali: $path"
        }
        if ($Config.ComfyUI.CleanupTemporaryMediaOnStart -and
            (Test-Path -LiteralPath $path -PathType Container)) {
            Get-ChildItem -LiteralPath $path -Force |
                Remove-Item -Recurse -Force -ErrorAction Stop
        }
        [IO.Directory]::CreateDirectory($path) | Out-Null
    }
}
function Get-ComfyUIWorkflowStrings {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return
    }
    if ($Value -is [string]) {
        Write-Output -NoEnumerate ([string]$Value)
        return
    }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            Get-ComfyUIWorkflowStrings -Value $Value[$key]
        }
        return
    }
    if ($Value -is [Collections.IEnumerable]) {
        foreach ($item in $Value) {
            Get-ComfyUIWorkflowStrings -Value $item
        }
        return
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        Get-ComfyUIWorkflowStrings -Value $property.Value
    }
}
function Get-ComfyUIWorkflowNode {
    param(
        [Parameter(Mandatory)][object[]]$Nodes,
        [Parameter(Mandatory)][string]$Type
    )
    $matches = @($Nodes | Where-Object {
        [string]$_.type -ceq $Type
    })
    if ($matches.Count -ne 1) {
        throw "ComfyUI workflow dugum sayisi gecersiz: $Type"
    }
    return $matches[0]
}
function Assert-ComfyUIStaticWorkflowContracts {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $fluxPath = Join-Path $projectRoot `
        'Data\Workflows\Flux1_Schnell_API.json'
    $wanPath = Join-Path $projectRoot `
        'Data\Workflows\Wan2.1_T2V_Workflow.json'
    $fluxHash = (Get-FileHash -LiteralPath $fluxPath `
        -Algorithm SHA256).Hash
    $wanHash = (Get-FileHash -LiteralPath $wanPath `
        -Algorithm SHA256).Hash
    $flux = [IO.File]::ReadAllText($fluxPath) |
        ConvertFrom-ComfyUIJson
    $wan = [IO.File]::ReadAllText($wanPath) |
        ConvertFrom-ComfyUIJson
    $fluxTypes = [ordered]@{
        '1' = 'CheckpointLoaderSimple'
        '2' = 'CLIPTextEncode'
        '3' = 'CLIPTextEncode'
        '4' = 'EmptySD3LatentImage'
        '5' = 'KSampler'
        '6' = 'VAEDecode'
        '7' = 'SaveImage'
    }
    foreach ($entry in $fluxTypes.GetEnumerator()) {
        $node = $flux.PSObject.Properties[[string]$entry.Key]
        if ($null -eq $node -or
            [string]$node.Value.class_type -cne $entry.Value) {
            throw "FLUX workflow dugumu gecersiz: $($entry.Key)"
        }
    }
    $fluxModel = @($Config.ComfyUI.Catalog | Where-Object {
        [string]$_.Name -ieq 'FLUX.1-schnell'
    })
    if ($fluxModel.Count -ne 1 -or
        @($fluxModel[0].Assets).Count -ne 1) {
        throw 'FLUX model katalog sozlesmesi gecersiz.'
    }
    $fluxFile = [IO.Path]::GetFileName(
        [string]$fluxModel[0].Assets[0].RelativePath
    )
    if ([string]$flux.'1'.inputs.ckpt_name -cne $fluxFile -or
        [int]$flux.'4'.inputs.width -lt 64 -or
        [int]$flux.'4'.inputs.height -lt 64 -or
        [int]$flux.'4'.inputs.batch_size -lt 1 -or
        [int]$flux.'5'.inputs.steps -ne 4 -or
        [double]$flux.'5'.inputs.cfg -ne 1) {
        throw 'FLUX workflow girdi sozlesmesi gecersiz.'
    }
    foreach ($value in @(Get-ComfyUIWorkflowStrings -Value $wan)) {
        if ([string]$value -match
            '(?i)(?<![a-z])(?:[a-z]:[\\/]|\\\\|/(?:home|users)/)') {
            throw 'Wan workflow kisisele ozel mutlak yol iceriyor.'
        }
    }
    foreach ($descriptor in @($Config.ComfyUI.CustomNodes)) {
        $expectedOffline = 'Runtime\ComfyUICustomNodes\{0}' -f `
            [string]$descriptor.Name
        if ([string]$descriptor.RequiredBy -ine 'Wan2.1-T2V-1.3B' -or
            [string]$descriptor.OfflinePath -cne $expectedOffline) {
            throw (
                'ComfyUI custom node model baglantisi gecersiz: ' +
                $descriptor.Name
            )
        }
        $version = $wan.extra.node_versions.PSObject.Properties[
            [string]$descriptor.Name
        ]
        if ($null -eq $version -or
            [string]$version.Value -cne [string]$descriptor.Commit) {
            throw (
                'Wan workflow custom node surumu gecersiz: ' +
                $descriptor.Name
            )
        }
    }
    $wanNodes = @($wan.nodes)
    $expectedCustomTypes = @(
        'LoadWanVideoT5TextEncoder', 'VHS_VideoCombine',
        'WanVideoBlockSwap', 'WanVideoDecode',
        'WanVideoEmptyEmbeds', 'WanVideoEnhanceAVideo',
        'WanVideoLoraSelectMulti', 'WanVideoModelLoader',
        'WanVideoSampler', 'WanVideoSetBlockSwap',
        'WanVideoSetLoRAs', 'WanVideoTextEmbedBridge',
        'WanVideoTextEncode', 'WanVideoTorchCompileSettings',
        'WanVideoVAELoader'
    ) | Sort-Object
    $actualCustomTypes = @($wanNodes | Where-Object {
        [string]$_.type -like 'WanVideo*' -or
        [string]$_.type -eq 'LoadWanVideoT5TextEncoder' -or
        [string]$_.type -eq 'VHS_VideoCombine'
    } | Select-Object -ExpandProperty type -Unique | Sort-Object)
    if (@(Compare-Object $expectedCustomTypes `
        $actualCustomTypes -CaseSensitive).Count -ne 0) {
        throw 'Wan workflow custom node sinif sozlesmesi gecersiz.'
    }
    $t5 = Get-ComfyUIWorkflowNode -Nodes $wanNodes `
        -Type 'LoadWanVideoT5TextEncoder'
    $model = Get-ComfyUIWorkflowNode -Nodes $wanNodes `
        -Type 'WanVideoModelLoader'
    $vae = Get-ComfyUIWorkflowNode -Nodes $wanNodes `
        -Type 'WanVideoVAELoader'
    $video = Get-ComfyUIWorkflowNode -Nodes $wanNodes `
        -Type 'VHS_VideoCombine'
    if ([string]$t5.widgets_values[0] -cne
            'models_t5_umt5-xxl-enc-bf16.pth' -or
        [string]$model.widgets_values[0] -cne
            'Wan2.1_T2V_1.3B.safetensors' -or
        [string]$vae.widgets_values[0] -cne 'Wan2.1_VAE.pth' -or
        [bool]$video.widgets_values.save_output -or
        -not [string]::IsNullOrWhiteSpace(
            [string]$video.widgets_values.videopreview.params.fullpath
        )) {
        throw 'Wan workflow model veya gecici medya sozlesmesi gecersiz.'
    }
    if ((Get-FileHash -LiteralPath $fluxPath -Algorithm SHA256).Hash `
            -cne $fluxHash -or
        (Get-FileHash -LiteralPath $wanPath -Algorithm SHA256).Hash `
            -cne $wanHash) {
        throw 'ComfyUI workflow denetimi kaynak dosyayi degistirdi.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.StaticWorkflows'
    return $true
}
function Write-ComfyUIErrorLog {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$Record)
    try {
    $logsPath = Join-Path ([IO.Path]::GetTempPath()) 'Winlama-Logs'
        [IO.Directory]::CreateDirectory($logsPath) | Out-Null
        $name = 'comfyui-error-{0}-{1}.log' -f @(
            [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff'),
            [guid]::NewGuid().ToString('N')
        )
        $path = Join-Path $logsPath $name
        $entry = New-ComfyUIErrorLogRecord `
            -Message $Record.Exception.Message `
            -ErrorText $Record.InvocationInfo.PositionMessage `
            -ErrorType $Record.Exception.GetType().FullName
        $line = $entry | ConvertTo-Json -Compress -Depth 5
        [IO.File]::WriteAllText(
            $path,
            $line + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
    }
    catch {
        Write-WinlamaUIStatus -Level WARN -Message (
            Get-ComfyUIText `
                -Key 'ComfyUI.Warning.ErrorLogFailed' `
                -Fallback 'ComfyUI hata gunlugu yazilamadi: {0}' `
                -Arguments @($_.Exception.Message)
        )
    }
}
try {
    $ConfigPath = Resolve-ComfyUIConfigPath -Path $ConfigPath
    $config = Get-Content -LiteralPath $ConfigPath -Raw `
        -Encoding UTF8 | ConvertFrom-ComfyUIJson
    $localizationModule = Join-Path $projectRoot `
        'Modules\Localization\LocalizationManager.psm1'
    if (Test-Path -LiteralPath $localizationModule -PathType Leaf) {
        Import-Module $localizationModule -Force -ErrorAction Stop
        $null = Initialize-Localization -ProjectRoot $projectRoot `
            -Configuration $config.Localization
        try {
            $host.UI.RawUI.WindowTitle = Get-LocalizedText `
                -Key 'ComfyUI.WindowTitle'
        }
        catch {
            Write-Verbose (Get-LocalizedText `
                -Key 'Common.Verbose.WindowTitleUnavailable' `
                -Arguments @($_.Exception.Message))
        }
    }
    Import-Module (Join-Path $projectRoot `
        'Modules\00_Common.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $projectRoot `
        'Modules\10_Runtime.psm1') -Force -ErrorAction Stop
    Write-Verbose (Get-LocalizedText `
        -Key 'Verbose.Validation.Started' `
        -Arguments @('ComfyUI.ps1'))
    if ($ValidateOnly) {
        $null = Assert-WinlamaUIStandard
        $null = Assert-ComfyUIBootstrapInputContracts
        $null = Assert-WinlamaUIInputFormatter -Formatter {
            param([string]$Value)
            Format-ComfyUIBootstrapInputLine -Value $Value
        }
        $null = Assert-ComfyUIErrorLogSchemaContracts
        $null = Test-DeploymentConfiguration -Config $config
        $null = Assert-WinlamaTtsRuntimeContracts
        $null = Assert-ComfyUIRuntimeIdentityContracts
        $runtimeIdentityCommand = Get-Command `
            Test-ComfyUIRuntimeIdentity -ErrorAction Stop
        if ($runtimeIdentityCommand.CommandType -ne 'Function' -or
            (Test-ComfyUIRuntimeIdentity `
                -Path (Join-Path $env:TEMP 'Winlama-Missing-ComfyUI') `
                -Config $config)) {
            throw [IO.InvalidDataException]::new(
                'ComfyUI runtime kimlik siniri dogrulanamadi.'
            )
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:ComfyUI.RuntimeIdentityExport'
        $null = Assert-ComfyUIObjectInfoContracts
        $null = Assert-ComfyUIPrepareOnlyContracts
        $null = Assert-ComfyUILauncherArgumentContracts
        $null = Assert-ComfyUIModelDirectoryIndexContracts
        $null = Assert-ComfyUICustomNodeTreeHashContracts
        $null = Assert-ComfyUISourcePolicyContracts
        $null = Assert-ComfyUIRequirementsContracts
        $null = Assert-ComfyUIStaticWorkflowContracts -Config $config
        foreach ($property in @(
            'Enabled', 'Host', 'Port', 'InstallPath',
            'ModelsPath', 'LaunchArguments', 'BaseRequirements',
            'BaseRequirementsSha256', 'Catalog'
        )) {
            if ($null -eq $config.ComfyUI.PSObject.Properties[$property]) {
                throw (Get-LocalizedText `
                    -Key 'ComfyUI.Error.ConfigFieldMissing' `
                    -Arguments @($property))
            }
        }
        foreach ($relativePath in @(
            'Data\Workflows\Flux1_Schnell_API.json',
            'Data\Workflows\Wan2.1_T2V_Workflow.json',
            'Modules\ComfyUI\DefaultWorkflow\__init__.py',
            ('Modules\ComfyUI\DefaultWorkflow\web\' +
                'default_workflow.js'),
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
            -Arguments @('ComfyUI.ps1'))
        Write-WinlamaUIRule -Character '='
        Write-WinlamaUILine -Text (Get-LocalizedText `
            -Key 'ComfyUI.Status.Title') -Color Cyan
        Write-WinlamaUIRule -Character '='
        Write-Verbose 'WINLAMA_UI_OK:ComfyUI.Status'
        Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.ps1'
        exit 0
    }
    if (-not $config.ComfyUI.Enabled) {
        Write-WinlamaUILine -Text (Get-ComfyUIText `
            -Key 'ComfyUI.Status.Disabled' `
            -Fallback 'ComfyUI devre disi.') -Color Yellow
        Complete-ComfyUIOperation `
            -Summary (Get-ComfyUIText `
                -Key 'ComfyUI.Operation.Disabled' `
                -Fallback 'ComfyUI devre disi oldugu icin baslatilmadi.') `
            -Level SKIP
        exit 0
    }
    $portState = Invoke-ComfyUIPortPreflight `
        -IsPrepareOnly ([bool]$PrepareOnly) `
        -Port ([int]$config.ComfyUI.Port) -Config $config
    if ($portState -ceq 'AlreadyReady') {
        Write-WinlamaUILine -Text (
            Get-ComfyUIText -Key 'ComfyUI.Status.AlreadyReady' `
                -Fallback 'ComfyUI zaten hazir: http://127.0.0.1:{0}' `
                -Arguments @($config.ComfyUI.Port)
        ) -Color Cyan
        Complete-ComfyUIOperation `
            -Summary (Get-ComfyUIText `
                -Key 'ComfyUI.Operation.AlreadyReady' `
                -Fallback 'ComfyUI zaten hazir ve saglikli.')
        exit 0
    }
    $installPath = Expand-ComfyUIPath `
        -Path $config.ComfyUI.InstallPath
    $runtimeRoot = Get-ComfyUIRuntimeRoot -InstallPath $installPath `
        -Config $config
    $null = Assert-ComfyUIPrepareRuntimeAvailable `
        -IsPrepareOnly ([bool]$PrepareOnly) `
        -RuntimeRoot $runtimeRoot -InstallPath $installPath
    if ([string]::IsNullOrWhiteSpace($runtimeRoot)) {
        Write-WinlamaUILine -Text (Get-ComfyUIText `
            -Key 'ComfyUI.Status.NotInstalled' `
            -Fallback 'ComfyUI kurulu degil: {0}' `
            -Arguments @($installPath)) `
            -Color Yellow
        Complete-ComfyUIOperation `
            -Summary (Get-ComfyUIText `
                -Key 'ComfyUI.Operation.NotInstalled' `
                -Fallback 'ComfyUI kurulumu bulunamadi.') -Level WARN
        exit 0
    }
    Clear-ComfyUITemporaryMedia -Config $config
    $modelsRoot = Expand-ComfyUIPath `
        -Path $config.ComfyUI.ModelsPath
    $null = Write-ComfyUIModelConfiguration `
        -RuntimeRoot $runtimeRoot -ModelsRoot $modelsRoot
    $null = Install-ComfyUIBaseRequirements `
        -RuntimeRoot $runtimeRoot -Config $config
    Install-ComfyUICustomNodes -RuntimeRoot $runtimeRoot `
        -Config $config
    $null = Install-ComfyUIDefaultWorkflow `
        -RuntimeRoot $runtimeRoot -Config $config
    $launcher = Join-Path $runtimeRoot `
        'run_nvidia_gpu_fast_fp16_accumulation.bat'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "ComfyUI hizli baslaticisi bulunamadi: $launcher"
    }
    $null = Assert-ComfyUILauncherArguments -Path $launcher
    $arguments = Get-ComfyUILaunchArguments -Config $config
    if ($PrepareOnly) {
        Write-WinlamaUILine -Text (Get-LocalizedText `
            -Key 'ComfyUI.Prepared') -Color Green
        Complete-ComfyUIOperation `
            -Summary (Get-ComfyUIText `
                -Key 'ComfyUI.Operation.Prepared' `
                -Fallback 'ComfyUI hazirlik islemleri tamamlandi.')
        exit 0
    }
    Write-WinlamaUILine -Text (Get-LocalizedText `
        -Key 'ComfyUI.Launching' `
        -Arguments @([IO.Path]::GetFileName($launcher))) `
        -Color Green
    if ($Background) {
        $processArguments = @($arguments | ForEach-Object {
            ConvertTo-ComfyUIProcessArgument -Value ([string]$_)
        })
        $process = Start-Process -FilePath $launcher `
            -ArgumentList $processArguments `
            -WorkingDirectory $runtimeRoot `
            -NoNewWindow -PassThru
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(120)
        do {
            if ($process.HasExited) {
                throw "ComfyUI erken kapandi: $($process.ExitCode)"
            }
            if (Test-ComfyUIPort -Port ([int]$config.ComfyUI.Port) `
                -Config $config) {
                Write-WinlamaUILine -Text (
                    Get-ComfyUIText -Key 'ComfyUI.Endpoint.Local' `
                        -Fallback 'ComfyUI: http://127.0.0.1:{0}' `
                        -Arguments @($config.ComfyUI.Port)
                ) -Color Cyan
                $process.Dispose()
                Complete-ComfyUIOperation `
                    -Summary (Get-ComfyUIText `
                        -Key 'ComfyUI.Operation.Started' `
                        -Fallback 'ComfyUI baslatildi ve API dogrulandi.')
                exit 0
            }
            Start-Sleep -Seconds 2
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        throw 'ComfyUI 120 saniyede hazir olmadi.'
    }
    & $launcher @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "ComfyUI cikis kodu: $LASTEXITCODE"
    }
    Complete-ComfyUIOperation `
        -Summary (Get-ComfyUIText `
            -Key 'ComfyUI.Operation.Completed' `
            -Fallback 'ComfyUI calisma oturumu tamamlandi.')
    exit 0
}
catch {
    if (-not $ValidateOnly) {
        Write-ComfyUIErrorLog -Record $_
    }
    Write-WinlamaUIError -Context (Get-ComfyUIText `
        -Key 'ComfyUI.Operation.FailedContext' `
        -Fallback 'ComfyUI baslatilamadi.') `
        -ErrorRecord $_
    if (-not $NoPause) {
        try {
            Complete-WinlamaUIOperation `
                -Summary (Get-ComfyUIText `
                    -Key 'ComfyUI.Operation.Failed' `
                    -Fallback 'ComfyUI islemi hatayla durdu.') `
                -Level ERROR -Command CIKIS
        }
        catch {
            Write-Verbose ('Kapanis beklemesi atlandi: {0}' -f `
                $_.Exception.Message)
        }
    }
    exit 1
}